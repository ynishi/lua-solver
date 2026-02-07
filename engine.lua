-- lua_solver/engine.lua
-- Solver engine: one-turn-one-loop + structural state retention

local S = require("lua_solver.structure")

local M = {}
M.__index = M

function M.new(config)
    config = config or {}
    local self = setmetatable({}, M)

    local strat = require("lua_solver.strategy")

    -- Strategy (swappable)
    self.strategies = {
        gap_detection        = config.gap_detection        or strat.gap_detection.LLM,
        gap_resolution       = config.gap_resolution       or strat.gap_resolution.ConfidenceAware,
        decompose            = config.decompose            or strat.decompose.Threshold,
        hypothesis_gen       = config.hypothesis_gen       or strat.hypothesis_gen.LLM,
        evidence_eval        = config.evidence_eval        or strat.evidence_eval.IndependenceWeighted,
        constraint_verify    = config.constraint_verify    or strat.constraint_verify.LLM,
        synthesize           = config.synthesize           or strat.synthesize.LLM,
        merge                = config.merge                or strat.merge.WeakestLink,
        continuation         = config.continuation         or strat.continuation.ExpectedValue,
        re_evaluate          = config.re_evaluate          or strat.re_evaluate.DeltaEval,
        hypothesis_selection = config.hypothesis_selection or nil,
    }

    -- Policy (thresholds)
    self.policy = {
        -- Confidence judgment
        confidence_threshold = config.confidence_threshold or 0.7,
        volatility_threshold = config.volatility_threshold or 0.4,

        -- Hypothesis / decomposition
        max_hypotheses       = config.max_hypotheses       or 5,
        decompose_threshold  = config.decompose_threshold  or 3,
        max_sub_depth        = config.max_sub_depth        or 3,

        -- Gap management
        max_gap_rounds       = config.max_gap_rounds       or 2,
        min_evidence         = config.min_evidence         or 2,

        -- Evidence independence
        same_group_weight    = config.same_group_weight    or 0.3,

        -- Continuation judgment
        continuation_threshold = config.continuation_threshold or 0.1,

        -- KnownFact confidence
        low_confidence_bound = config.low_confidence_bound or 0.5,

        -- ReEvaluate
        hypothesis_decay_rate = config.hypothesis_decay_rate or 0.9,
        supersede_threshold   = config.supersede_threshold   or 0.2,

        -- Accumulated hypothesis limit
        max_accumulated_hypotheses = config.max_accumulated_hypotheses
            or (config.max_hypotheses or 5) * 3,

        -- DynGapInject
        max_mid_turn_gaps       = config.max_mid_turn_gaps       or 3,
        inferred_confidence     = config.inferred_confidence     or 0.3,

        -- HypothesisSelection
        eval_budget             = config.eval_budget             or nil,
        exploration_constant    = config.exploration_constant    or 1.41,
    }

    return self
end

--- Execute one turn
function M:turn(problem)
    problem.turn_count = (problem.turn_count or 0) + 1
    problem.gap_rounds = problem.gap_rounds or 0
    local turn_id = problem.turn_count

    -- Detect known changes (compare against previous turn snapshot)
    local changed_keys = problem:changed_known_keys()
    problem:snapshot_known()

    -- ReEvaluate Strategy
    local re_eval_result = { updated = 0, superseded = 0, delta = 0 }
    if #changed_keys > 0 and #problem.hypotheses > 0 then
        re_eval_result = self.strategies.re_evaluate.re_evaluate(
            problem, self.policy, changed_keys)
    end

    -- Phase 1: Gap detection
    if problem.gap_rounds < self.policy.max_gap_rounds then
        local gaps = self.strategies.gap_detection.detect(problem)
        if #gaps > 0 then
            problem.gap_rounds = problem.gap_rounds + 1
            return { type = "gaps", gaps = gaps, problem = problem }
        end
    end

    -- Phase 2: Decomposition check
    if #problem.sub_problems == 0 then
        local ds = self.strategies.decompose
        if ds.should(problem, self.policy) then
            local subs = ds.decompose(problem)
            if #subs > 0 then
                problem.sub_problems = subs
                local sub_solutions = {}
                for _, sp in ipairs(subs) do
                    sub_solutions[#sub_solutions + 1] = self:_solve_sub(sp, 1)
                end
                local merged = self.strategies.merge.merge(sub_solutions, problem)
                if merged then
                    merged.turn_id = turn_id
                    merged.constraint_results = self.strategies.constraint_verify.verify(
                        merged, problem.constraints, problem
                    )
                    problem.solutions[#problem.solutions + 1] = merged

                    local continuation = self.strategies.continuation.judge(
                        merged, problem, self.policy)
                    return {
                        type = "solution",
                        solution = merged,
                        sub_solutions = sub_solutions,
                        problem = problem,
                        continuation = continuation,
                    }
                end
            end
        end
    end

    -- Phase 3: Hypothesis generation (pass existing)
    local existing = problem:active_hypotheses()
    local new_hypotheses = self.strategies.hypothesis_gen.generate(
        problem, self.policy, existing)

    -- Assign turn_id
    for _, h in ipairs(new_hypotheses) do
        h.turn_id = turn_id
        h.status = "active"
    end

    -- Continue if existing active hypotheses even when no new ones generated
    if #new_hypotheses == 0 then
        if #existing == 0 then
            return { type = "error", message = "failed to generate hypotheses", problem = problem }
        end
    end

    -- evaluate_batch (extensible for MCT Selective)
    local eval_result = self.strategies.evidence_eval.evaluate_batch(
        new_hypotheses, problem, self.policy)

    -- Accumulate
    for _, h in ipairs(new_hypotheses) do
        problem.hypotheses[#problem.hypotheses + 1] = h
    end

    -- Process discovered_gaps (DynGapInject)
    local injected_gaps = {}
    if eval_result.discovered_gaps and #eval_result.discovered_gaps > 0 then
        local injected = 0
        for _, gap in ipairs(eval_result.discovered_gaps) do
            if injected >= self.policy.max_mid_turn_gaps then break end

            -- Deduplicate against existing gaps
            local exists = false
            for _, g in ipairs(problem.gaps) do
                if g.key == gap.key then exists = true; break end
            end
            if not exists and not problem.known[gap.key] then
                problem:add_gap(gap)
                injected_gaps[#injected_gaps + 1] = gap

                -- If auto_resolve available: inject as inferred KnownFact
                if gap.auto_resolve then
                    problem:fill(gap.key, gap.auto_resolve.value,
                        gap.auto_resolve.confidence or self.policy.inferred_confidence,
                        "inferred")
                end
                injected = injected + 1
            end
        end
    end

    -- Hypothesis accumulation limit
    local pruned = problem:prune_hypotheses(self.policy.max_accumulated_hypotheses)

    -- Rank active hypotheses for synthesize (selection-aware ordering)
    local all_active = problem:active_hypotheses()
    if self.strategies.hypothesis_selection then
        all_active = self.strategies.hypothesis_selection.rank(
            all_active, self.policy)
    else
        table.sort(all_active, function(a, b)
            return a.confidence.value > b.confidence.value
        end)
    end

    -- Synthesize
    local solution = self.strategies.synthesize.synthesize(all_active, problem)
    solution.turn_id = turn_id

    -- Constraint check
    solution.constraint_results = self.strategies.constraint_verify.verify(
        solution, problem.constraints, problem
    )

    -- Accumulate solution
    problem.solutions[#problem.solutions + 1] = solution

    -- Continuation judgment
    local continuation = self.strategies.continuation.judge(
        solution, problem, self.policy)

    return {
        type = "solution",
        solution = solution,
        hypotheses = all_active,
        new_hypotheses = new_hypotheses,
        pruned_count = pruned,
        changed_keys = changed_keys,
        re_eval_result = re_eval_result,
        eval_result = eval_result,
        discovered_gaps = injected_gaps,
        problem = problem,
        continuation = continuation,
    }
end

--- Internal auto-loop (for sub_problems)
function M:_solve_sub(problem, depth)
    if depth > self.policy.max_sub_depth then
        return S.Solution {
            content = "depth limit: " .. problem.statement,
            confidence = S.Confidence { value = 0.3, volatility = 0.8, basis = "depth_limit" },
        }
    end

    local hypotheses = self.strategies.hypothesis_gen.generate(problem, self.policy, {})

    self.strategies.evidence_eval.evaluate_batch(hypotheses, problem, self.policy)

    table.sort(hypotheses, function(a, b)
        return a.confidence.value > b.confidence.value
    end)

    if #hypotheses == 0 then
        return S.Solution {
            content = "no hypotheses for: " .. problem.statement,
            confidence = S.Confidence { value = 0.1, volatility = 1.0, basis = "empty" },
        }
    end

    return self.strategies.synthesize.synthesize(hypotheses, problem)
end

return M

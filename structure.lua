-- lua_solver/structure.lua
-- Core data structures (DSL constructors)
-- Structure layer: immutable skeleton independent of Strategy/Policy

local M = {}

--- Confidence: quantitative uncertainty tracking
function M.Confidence(t)
    t = t or {}
    return {
        value = t.value or 0.0,
        volatility = t.volatility or 1.0,
        basis = t.basis or "initial",
        settled = function(self, threshold, vol_threshold)
            return self.value >= (threshold or 0.7)
               and self.volatility < (vol_threshold or 0.4)
        end,
    }
end

--- KnownFact: known fact with confidence
function M.KnownFact(t)
    if type(t) == "string" then
        return { value = t, confidence = 0.9, source = "user" }
    end
    return {
        value = t.value or t[1] or "",
        confidence = t.confidence or 0.9,
        source = t.source or "user",
    }
end

--- Gap: knowledge hole
function M.Gap(t)
    if type(t) == "string" then
        return { key = t, question = t .. "?", required = true, status = "open" }
    end
    return {
        key = t.key or t[1],
        question = t.question or t[2] or ((t.key or t[1]) .. "?"),
        required = t.required ~= false,
        status = t.status or "open",
        auto_resolve = t.auto_resolve or nil,
    }
end

--- Constraint: condition the solution must satisfy
function M.Constraint(t)
    if type(t) == "string" then
        return { description = t, verify = nil }
    end
    return {
        description = t.description or t[1],
        verify = t.verify,
    }
end

--- Evidence: supporting/contradicting basis for a hypothesis
function M.Evidence(t)
    return {
        content = t.content or t[1] or "",
        supports = (t.supports == nil) and true or t.supports,
        confidence = t.confidence or M.Confidence { value = 0.5, basis = "default" },
        source_id = t.source_id or "unknown",
        independence_group = t.independence_group or "default",
    }
end

--- Hypothesis: solution candidate with accumulated evidence
function M.Hypothesis(t)
    local self = {
        claim = t.claim or t[1] or "",
        evidence = t.evidence or {},
        confidence = t.confidence or M.Confidence(),
        turn_id = t.turn_id or 0,
        status = t.status or "active",
    }

    function self:add_evidence(e)
        self.evidence[#self.evidence + 1] = e
    end

    function self:update_confidence(policy)
        if #self.evidence == 0 then
            self.confidence = M.Confidence { value = 0.0, volatility = 1.0, basis = "no evidence" }
            return
        end

        policy = policy or {}
        local same_group_weight = policy.same_group_weight or 1.0

        local group_counts = {}
        local sup, ag = 0, 0
        local sup_n, ag_n = 0, 0

        for _, e in ipairs(self.evidence) do
            local grp = e.independence_group or "default"
            group_counts[grp] = (group_counts[grp] or 0) + 1
            local weight = (group_counts[grp] == 1) and 1.0 or same_group_weight

            local w_conf = e.confidence.value * weight
            if e.supports then
                sup = sup + w_conf
                sup_n = sup_n + 1
            else
                ag = ag + w_conf
                ag_n = ag_n + 1
            end
        end

        local total = sup + ag
        self.confidence = M.Confidence {
            value = total > 0 and (sup / total) or 0.0,
            volatility = math.max(0, 1.0 - #self.evidence / (#self.evidence + 5)),
            basis = string.format("%d sup %d contra", sup_n, ag_n),
        }
    end

    return self
end

--- Solution: synthesized answer with constraint results
function M.Solution(t)
    local self = {
        content = t.content or "",
        confidence = t.confidence or M.Confidence(),
        basis = t.basis or {},
        constraint_results = t.constraint_results or {},
        turn_id = t.turn_id or 0,
    }
    function self:satisfies_all()
        for _, v in pairs(self.constraint_results) do
            if not v then return false end
        end
        return true
    end
    return self
end

--- Problem: core DSL entry point
function M.Problem(t)
    local gaps = {}
    for _, g in ipairs(t.gaps or {}) do
        gaps[#gaps + 1] = g.key and g or M.Gap(g)
    end

    local constraints = {}
    for _, c in ipairs(t.constraints or {}) do
        if type(c) == "string" then
            constraints[#constraints + 1] = M.Constraint(c)
        else
            constraints[#constraints + 1] = c.description and c or M.Constraint(c)
        end
    end

    local known = {}
    if t.known then
        for k, v in pairs(t.known) do
            if type(v) == "table" and v.value then
                known[k] = v
            else
                known[k] = M.KnownFact { value = tostring(v), confidence = 0.9, source = "given" }
            end
        end
    end

    local self = {
        statement = t.statement or t[1] or "",
        known = known,
        gaps = gaps,
        constraints = constraints,
        sub_problems = t.sub_problems or {},
        hypotheses = {},
        solutions = {},
        turn_count = 0,
        gap_rounds = 0,
        known_snapshot = nil,
    }

    function self:open_gaps()
        local open = {}
        for _, g in ipairs(self.gaps) do
            if g.status == "open" and g.required then
                open[#open + 1] = g
            end
        end
        return open
    end

    function self:has_gaps()
        return #self:open_gaps() > 0
    end

    function self:complexity()
        return #self.gaps + #self.constraints + #self.sub_problems
    end

    function self:fill(key, value, confidence, source)
        if type(value) == "table" and value.value then
            self.known[key] = value
        else
            self.known[key] = M.KnownFact {
                value = tostring(value),
                confidence = confidence or 0.9,
                source = source or "user",
            }
        end
        for _, g in ipairs(self.gaps) do
            if g.key == key and g.status == "open" then
                g.status = "answered"
            end
        end
    end

    function self:known_value(key)
        local fact = self.known[key]
        if not fact then return nil end
        return fact.value
    end

    function self:known_confidence(key)
        local fact = self.known[key]
        if not fact then return nil end
        return fact.confidence
    end

    function self:add_gap(g)
        local gap = g.key and g or M.Gap(g)
        gap.status = gap.status or "open"
        self.gaps[#self.gaps + 1] = gap
    end

    function self:set_gap_status(key, status)
        for _, g in ipairs(self.gaps) do
            if g.key == key then
                g.status = status
            end
        end
    end

    function self:gap_stats()
        local unanswerable, skipped, low_conf = 0, 0, 0
        for _, g in ipairs(self.gaps) do
            if g.status == "unanswerable" then unanswerable = unanswerable + 1
            elseif g.status == "skipped" then skipped = skipped + 1
            end
        end
        for _, fact in pairs(self.known) do
            if fact.confidence and fact.confidence < 0.6 then
                low_conf = low_conf + 1
            end
        end
        return {
            unanswerable = unanswerable,
            skipped = skipped,
            low_confidence_known = low_conf,
        }
    end

    function self:active_hypotheses()
        local active = {}
        for _, h in ipairs(self.hypotheses) do
            if h.status == "active" or h.status == "revised" then
                active[#active + 1] = h
            end
        end
        return active
    end

    function self:snapshot_known()
        local snap = {}
        for k, v in pairs(self.known) do
            snap[k] = { value = v.value, confidence = v.confidence, source = v.source }
        end
        self.known_snapshot = snap
    end

    function self:changed_known_keys()
        if not self.known_snapshot then return {} end
        local changed = {}
        for k, v in pairs(self.known) do
            local prev = self.known_snapshot[k]
            if not prev then
                changed[#changed + 1] = k
            elseif prev.value ~= v.value or prev.confidence ~= v.confidence then
                changed[#changed + 1] = k
            end
        end
        return changed
    end

    function self:prune_hypotheses(max_count)
        if #self.hypotheses <= max_count then return 0 end
        local sorted = {}
        for i, h in ipairs(self.hypotheses) do
            sorted[#sorted + 1] = { idx = i, h = h }
        end
        table.sort(sorted, function(a, b)
            return a.h.confidence.value > b.h.confidence.value
        end)
        local pruned = 0
        for i = max_count + 1, #sorted do
            if sorted[i].h.status ~= "superseded" then
                sorted[i].h.status = "superseded"
                pruned = pruned + 1
            end
        end
        return pruned
    end

    return self
end

return M

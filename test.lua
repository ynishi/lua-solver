#!/usr/bin/env lua
-- lua_solver/test.lua: Unit tests (no LLM required)

-- Package path: add lua_solver's parent directory to path
local script_dir = arg[0]:match("(.*/)")
if script_dir then
    package.path = script_dir .. "../?.lua"
        .. ";" .. script_dir .. "../?/init.lua"
        .. ";" .. package.path
end

local S = require("lua_solver.structure")

local pass, fail = 0, 0
local function check(name, cond)
    if cond then
        pass = pass + 1
        io.write(string.format("  OK  %s\n", name))
    else
        fail = fail + 1
        io.write(string.format("  FAIL  %s\n", name))
    end
end

io.write("=== lua_solver unit tests ===\n\n")

-- =============================================
-- Structure tests
-- =============================================

-- KnownFact
io.write("[KnownFact]\n")
local kf1 = S.KnownFact("simple string")
check("string shorthand: value", kf1.value == "simple string")
check("string shorthand: confidence", kf1.confidence == 0.9)
check("string shorthand: source", kf1.source == "user")

local kf2 = S.KnownFact { value = "Docker", confidence = 0.5, source = "user" }
check("explicit: value", kf2.value == "Docker")
check("explicit: confidence", kf2.confidence == 0.5)

-- Gap with status
io.write("\n[Gap.status]\n")
local g1 = S.Gap { key = "env", question = "?" }
check("default status = open", g1.status == "open")
g1.status = "answered"
check("status mutable", g1.status == "answered")

local g2 = S.Gap { key = "x", question = "?", status = "skipped" }
check("explicit status", g2.status == "skipped")

-- Evidence with source_id + independence_group
io.write("\n[Evidence]\n")
local e1 = S.Evidence {
    content = "test",
    supports = true,
    source_id = "llm-call-1",
    independence_group = "llm-call-1",
}
check("source_id", e1.source_id == "llm-call-1")
check("independence_group", e1.independence_group == "llm-call-1")

local e2 = S.Evidence { content = "default" }
check("default source_id", e2.source_id == "unknown")
check("default independence_group", e2.independence_group == "default")

-- Hypothesis update_confidence with independence weighting
io.write("\n[Hypothesis: IndependenceWeighted confidence]\n")
local h = S.Hypothesis { claim = "test" }
h:add_evidence(S.Evidence { content = "a", supports = true,
    confidence = S.Confidence { value = 0.8 }, independence_group = "grp-A" })
h:add_evidence(S.Evidence { content = "b", supports = true,
    confidence = S.Confidence { value = 0.7 }, independence_group = "grp-A" })
h:add_evidence(S.Evidence { content = "c", supports = true,
    confidence = S.Confidence { value = 0.6 }, independence_group = "grp-A" })
h:add_evidence(S.Evidence { content = "d", supports = false,
    confidence = S.Confidence { value = 0.8 }, independence_group = "grp-B" })
h:add_evidence(S.Evidence { content = "e", supports = false,
    confidence = S.Confidence { value = 0.7 }, independence_group = "grp-C" })

h:update_confidence()
local no_weight = h.confidence.value
io.write(string.format("  no weighting: %.3f\n", no_weight))
check("no weighting: sup > 0.5", no_weight > 0.5)

h:update_confidence({ same_group_weight = 0.3 })
local weighted = h.confidence.value
io.write(string.format("  weighted:     %.3f\n", weighted))
check("weighted < no_weight (discount same-group)", weighted < no_weight)

local expected_weighted = 1.19 / (1.19 + 1.5)
check("weighted ~ 0.442", math.abs(weighted - expected_weighted) < 0.001)

-- Problem with KnownFact
io.write("\n[Problem]\n")
local p = S.Problem {
    statement = "test problem",
    known = {
        a = "plain string",
        b = S.KnownFact { value = "explicit", confidence = 0.5, source = "user" },
    },
    gaps = { { "env", "?" } },
    constraints = { "C1" },
}

check("plain string -> KnownFact", p.known["a"].value == "plain string")
check("plain string -> confidence 0.9", p.known["a"].confidence == 0.9)
check("explicit KnownFact preserved", p.known["b"].confidence == 0.5)
check("known_value helper", p:known_value("a") == "plain string")
check("known_confidence helper", p:known_confidence("b") == 0.5)

-- Gap status tracking via fill
io.write("\n[Problem:fill with confidence]\n")
check("1 open gap before fill", #p:open_gaps() == 1)
p:fill("env", "Docker", 0.5, "user")
check("fill: known stored", p:known_value("env") == "Docker")
check("fill: confidence stored", p:known_confidence("env") == 0.5)
check("fill: gap status = answered", p.gaps[1].status == "answered")
check("0 open gaps after fill", #p:open_gaps() == 0)

-- Gap stats
io.write("\n[Problem:gap_stats]\n")
p:add_gap(S.Gap { key = "x", question = "?", status = "unanswerable" })
p:add_gap(S.Gap { key = "y", question = "?", status = "skipped" })
local stats = p:gap_stats()
check("unanswerable = 1", stats.unanswerable == 1)
check("skipped = 1", stats.skipped == 1)
check("low_confidence_known = 2", stats.low_confidence_known == 2)

-- GapResolution ConfidenceAware
io.write("\n[GapResolution.ConfidenceAware]\n")
local strat = require("lua_solver.strategy")
local ca = strat.gap_resolution.ConfidenceAware

local r1 = ca.resolve(nil, "Docker", nil)
check("plain answer: conf=0.9", r1.known_fact.confidence == 0.9)

local r2 = ca.resolve(nil, "とりあえずDocker", nil)
check("とりあえず: conf=0.5", r2.known_fact.confidence == 0.5)

local r3 = ca.resolve(nil, "たぶんDocker", nil)
check("たぶん: conf=0.7", r3.known_fact.confidence == 0.7)

local r4 = ca.resolve(nil, "0.6: Docker", nil)
check("explicit 0.6: conf=0.6", r4.known_fact.confidence == 0.6)
check("explicit 0.6: value=Docker", r4.known_fact.value:match("Docker") ~= nil)

local r5 = ca.resolve(nil, "Docker (0.4)", nil)
check("explicit (0.4): conf=0.4", r5.known_fact.confidence == 0.4)

local r6 = ca.resolve(nil, "わからないけどDocker", nil)
check("わからないけど: conf=0.3", r6.known_fact.confidence == 0.3)

-- ContinuationJudge
io.write("\n[ContinuationJudge.ExpectedValue]\n")
local ev = strat.continuation.ExpectedValue
local sol = S.Solution {
    content = "test",
    confidence = S.Confidence { value = 0.55, volatility = 0.35 },
}
local advice = ev.judge(sol, p, { continuation_threshold = 0.1, volatility_threshold = 0.4 })
io.write(string.format("  expected_improvement: %.3f\n", advice.expected_improvement))
check("expected_improvement ~ 0.19", math.abs(advice.expected_improvement - 0.19) < 0.01)
check("recommend = true", advice.recommend == true)

local stop_advice = strat.continuation.AlwaysStop.judge(sol, p, {})
check("AlwaysStop: recommend=false", stop_advice.recommend == false)

-- =============================================
-- Hypothesis: turn_id + status
-- =============================================
io.write("\n[Hypothesis turn_id + status]\n")
local h3 = S.Hypothesis { claim = "v3 hyp", turn_id = 2, status = "revised" }
check("turn_id = 2", h3.turn_id == 2)
check("status = revised", h3.status == "revised")

local h3_default = S.Hypothesis { claim = "default" }
check("default turn_id = 0", h3_default.turn_id == 0)
check("default status = active", h3_default.status == "active")

-- Solution: turn_id
io.write("\n[Solution turn_id]\n")
local sol3 = S.Solution { content = "v3 sol", turn_id = 3 }
check("solution turn_id = 3", sol3.turn_id == 3)

-- Problem: solutions, known_snapshot
io.write("\n[Problem solutions + known_snapshot]\n")
local p3 = S.Problem {
    statement = "v3 problem",
    known = { a = "hello", b = S.KnownFact { value = "world", confidence = 0.7 } },
    gaps = {},
    constraints = {},
}
check("solutions initialized", type(p3.solutions) == "table" and #p3.solutions == 0)
check("known_snapshot nil initially", p3.known_snapshot == nil)

-- active_hypotheses
io.write("\n[active_hypotheses]\n")
p3.hypotheses[1] = S.Hypothesis { claim = "A", status = "active", turn_id = 1 }
p3.hypotheses[2] = S.Hypothesis { claim = "B", status = "superseded", turn_id = 1 }
p3.hypotheses[3] = S.Hypothesis { claim = "C", status = "revised", turn_id = 2 }
p3.hypotheses[4] = S.Hypothesis { claim = "D", status = "active", turn_id = 2 }
local active = p3:active_hypotheses()
check("active_hypotheses returns 3 (active+revised)", #active == 3)
local active_claims = {}
for _, ah in ipairs(active) do active_claims[ah.claim] = true end
check("A is active", active_claims["A"] == true)
check("B is superseded (excluded)", active_claims["B"] == nil)
check("C is revised (included)", active_claims["C"] == true)
check("D is active", active_claims["D"] == true)

-- snapshot_known + changed_known_keys
io.write("\n[snapshot_known + changed_known_keys]\n")
p3:snapshot_known()
check("snapshot saved", p3.known_snapshot ~= nil)
check("snapshot a.value", p3.known_snapshot["a"].value == "hello")
check("snapshot b.confidence", p3.known_snapshot["b"].confidence == 0.7)

local changed0 = p3:changed_known_keys()
check("no changes yet", #changed0 == 0)

p3:fill("a", "changed_hello", 0.8, "user")
p3:fill("c", "new_key", 0.9, "user")
local changed = p3:changed_known_keys()
check("2 changed keys (a modified, c new)", #changed == 2)
local changed_set = {}
for _, k in ipairs(changed) do changed_set[k] = true end
check("a is changed", changed_set["a"] == true)
check("c is new", changed_set["c"] == true)

-- prune_hypotheses
io.write("\n[prune_hypotheses]\n")
local p4 = S.Problem { statement = "prune test" }
for i = 1, 6 do
    local hyp = S.Hypothesis { claim = "H" .. i }
    hyp.confidence = S.Confidence { value = i * 0.1 }
    p4.hypotheses[i] = hyp
end
check("6 hypotheses before prune", #p4.hypotheses == 6)
local pruned = p4:prune_hypotheses(3)
check("pruned 3", pruned == 3)
local active_after = p4:active_hypotheses()
check("3 active after prune", #active_after == 3)
local superseded_count = 0
for _, hyp in ipairs(p4.hypotheses) do
    if hyp.status == "superseded" then superseded_count = superseded_count + 1 end
end
check("3 superseded after prune", superseded_count == 3)

local pruned2 = p4:prune_hypotheses(3)
check("re-prune = 0 (already pruned)", pruned2 == 0)

-- =============================================
-- ReEvaluate Strategy tests
-- =============================================

-- ReEvaluate Strategy: NoOp
io.write("\n[ReEvaluate.NoOp]\n")
local re_noop = strat.re_evaluate.NoOp
local noop_result = re_noop.re_evaluate(p3, {}, { "a" })
check("NoOp: updated=0", noop_result.updated == 0)
check("NoOp: superseded=0", noop_result.superseded == 0)

-- ReEvaluate Strategy: DeltaEval
io.write("\n[ReEvaluate.DeltaEval]\n")
local p_re = S.Problem {
    statement = "re-eval test",
    known = { tech = S.KnownFact { value = "Docker", confidence = 0.8 } },
}
local h_re1 = S.Hypothesis { claim = "Docker適用", turn_id = 1, status = "active" }
h_re1:add_evidence(S.Evidence {
    content = "Docker is lightweight",
    supports = true,
    confidence = S.Confidence { value = 0.7, basis = "llm_eval" },
})
h_re1:add_evidence(S.Evidence {
    content = "Requires orchestration",
    supports = false,
    confidence = S.Confidence { value = 0.5, basis = "llm_eval" },
})
h_re1:update_confidence()

local h_re2 = S.Hypothesis { claim = "全く無関係", turn_id = 1, status = "active" }
h_re2:add_evidence(S.Evidence {
    content = "Python is popular",
    supports = true,
    confidence = S.Confidence { value = 0.6, basis = "llm_eval" },
})
h_re2:update_confidence()

p_re.hypotheses = { h_re1, h_re2 }

local delta_result = strat.re_evaluate.DeltaEval.re_evaluate(
    p_re, { low_confidence_bound = 0.5, same_group_weight = 0.3 }, { "tech" })
check("DeltaEval: updated >= 1", delta_result.updated >= 1)
check("DeltaEval: h_re1 status = revised", h_re1.status == "revised")
check("DeltaEval: h_re2 status = active (unchanged)", h_re2.status == "active")

-- ReEvaluate Strategy: DecayBased
io.write("\n[ReEvaluate.DecayBased]\n")
local p_decay = S.Problem { statement = "decay test" }
p_decay.turn_count = 3
local h_old = S.Hypothesis { claim = "old hyp", turn_id = 1, status = "active" }
h_old.confidence = S.Confidence { value = 0.8, basis = "test" }
local h_new = S.Hypothesis { claim = "new hyp", turn_id = 3, status = "active" }
h_new.confidence = S.Confidence { value = 0.6, basis = "test" }
p_decay.hypotheses = { h_old, h_new }

local decay_result = strat.re_evaluate.DecayBased.re_evaluate(
    p_decay, { hypothesis_decay_rate = 0.9, supersede_threshold = 0.2 }, {})
check("DecayBased: old hyp decayed", h_old.confidence.value < 0.8)
check("DecayBased: old conf ~ 0.648", math.abs(h_old.confidence.value - 0.648) < 0.01)
check("DecayBased: new hyp unchanged (age=0)", h_new.confidence.value == 0.6)

-- evaluate_batch
io.write("\n[evaluate_batch default]\n")
check("IndependenceWeighted has evaluate_batch",
    type(strat.evidence_eval.IndependenceWeighted.evaluate_batch) == "function")
check("SimpleCount has evaluate_batch",
    type(strat.evidence_eval.SimpleCount.evaluate_batch) == "function")
check("LLM has evaluate_batch",
    type(strat.evidence_eval.LLM.evaluate_batch) == "function")

local p_batch = S.Problem { statement = "batch test", known = {} }
local batch_result = strat.evidence_eval.SimpleCount.evaluate_batch({}, p_batch, {})
check("evaluate_batch returns discovered_gaps", type(batch_result.discovered_gaps) == "table")
check("evaluate_batch: empty discovered_gaps", #batch_result.discovered_gaps == 0)

-- Gap with auto_resolve
io.write("\n[Gap.auto_resolve]\n")
local g_auto = S.Gap {
    key = "rw_ratio",
    question = "Read/Write比率は？",
    auto_resolve = { value = "7:3 (推定)", confidence = 0.3 },
}
check("gap has auto_resolve", g_auto.auto_resolve ~= nil)
check("auto_resolve value", g_auto.auto_resolve.value == "7:3 (推定)")
check("auto_resolve confidence", g_auto.auto_resolve.confidence == 0.3)

-- Engine strategies config
io.write("\n[Engine strategies config]\n")
local engine = require("lua_solver.engine")
local eng = engine.new({})
check("engine has re_evaluate strategy", eng.strategies.re_evaluate ~= nil)
check("engine default re_evaluate = DeltaEval",
    eng.strategies.re_evaluate == strat.re_evaluate.DeltaEval)

local eng_noop = engine.new({ re_evaluate = strat.re_evaluate.NoOp })
check("engine re_evaluate swap to NoOp",
    eng_noop.strategies.re_evaluate == strat.re_evaluate.NoOp)

local eng_decay = engine.new({ re_evaluate = strat.re_evaluate.DecayBased })
check("engine re_evaluate swap to DecayBased",
    eng_decay.strategies.re_evaluate == strat.re_evaluate.DecayBased)

-- Engine policy fields
io.write("\n[Engine policy fields]\n")
check("policy has max_mid_turn_gaps", eng.policy.max_mid_turn_gaps == 3)
check("policy has inferred_confidence", eng.policy.inferred_confidence == 0.3)
check("policy has supersede_threshold", eng.policy.supersede_threshold == 0.2)
check("policy has hypothesis_decay_rate", eng.policy.hypothesis_decay_rate == 0.9)

-- HypothesisGen existing param
io.write("\n[HypothesisGen existing param]\n")
check("DeltaAware exists", strat.hypothesis_gen.DeltaAware ~= nil)
check("DeltaAware has generate", type(strat.hypothesis_gen.DeltaAware.generate) == "function")
check("Adversarial exists", strat.hypothesis_gen.Adversarial ~= nil)
check("Adversarial has generate", type(strat.hypothesis_gen.Adversarial.generate) == "function")
check("Adversarial has inner field", strat.hypothesis_gen.Adversarial.inner == nil)

-- Strategy implementations exist
io.write("\n[ReEvaluate Strategy implementations]\n")
check("NoOp exists", strat.re_evaluate.NoOp ~= nil)
check("DeltaEval exists", strat.re_evaluate.DeltaEval ~= nil)
check("DecayBased exists", strat.re_evaluate.DecayBased ~= nil)

-- =============================================
-- Fix verification tests
-- =============================================

-- _apply_known_confidence: prevent cumulative multiplication
io.write("\n[_apply_known_confidence idempotent]\n")
local p_kc = S.Problem {
    statement = "kc test",
    known = { tech = S.KnownFact { value = "Docker", confidence = 0.4 } },
}
local h_kc = S.Hypothesis { claim = "kc hyp" }
h_kc:add_evidence(S.Evidence {
    content = "Docker is lightweight",
    supports = true,
    confidence = S.Confidence { value = 0.8, basis = "llm_eval" },
})
strat._apply_known_confidence(h_kc, p_kc, { low_confidence_bound = 0.5 })
local after_first = h_kc.evidence[1].confidence.value
io.write(string.format("  after 1st apply: %.3f\n", after_first))
check("1st apply: 0.8 * 0.4 = 0.32", math.abs(after_first - 0.32) < 0.001)

strat._apply_known_confidence(h_kc, p_kc, { low_confidence_bound = 0.5 })
local after_second = h_kc.evidence[1].confidence.value
io.write(string.format("  after 2nd apply: %.3f\n", after_second))
check("2nd apply: still 0.32 (not 0.128)", math.abs(after_second - 0.32) < 0.001)

-- DecayBased basis stability
io.write("\n[DecayBased basis stability]\n")
local p_basis = S.Problem { statement = "basis test" }
p_basis.turn_count = 3
local h_basis = S.Hypothesis { claim = "basis hyp", turn_id = 1, status = "active" }
h_basis.confidence = S.Confidence { value = 0.8, basis = "2 sup 1 contra" }
p_basis.hypotheses = { h_basis }

strat.re_evaluate.DecayBased.re_evaluate(
    p_basis, { hypothesis_decay_rate = 0.9, supersede_threshold = 0.2 }, {})
local basis_len1 = #h_basis.confidence.basis

p_basis.turn_count = 4
strat.re_evaluate.DecayBased.re_evaluate(
    p_basis, { hypothesis_decay_rate = 0.9, supersede_threshold = 0.2 }, {})
local basis_len2 = #h_basis.confidence.basis

io.write(string.format("  basis len after turn3: %d, turn4: %d\n", basis_len1, basis_len2))
check("basis not growing unbounded", basis_len2 < basis_len1 * 2)

-- Problem.gap_rounds
io.write("\n[Problem.gap_rounds initialized]\n")
local p_gr = S.Problem { statement = "gap_rounds test" }
check("gap_rounds initialized to 0", p_gr.gap_rounds == 0)

-- DeltaEval precise assertion
io.write("\n[DeltaEval precise assertion]\n")
local p_precise = S.Problem {
    statement = "precise test",
    known = { tech = S.KnownFact { value = "Redis", confidence = 0.8 } },
}
local h_match = S.Hypothesis { claim = "match", turn_id = 1, status = "active" }
h_match:add_evidence(S.Evidence {
    content = "Redis is fast", supports = true,
    confidence = S.Confidence { value = 0.7, basis = "llm_eval" },
})
h_match:update_confidence()
local h_nomatch = S.Hypothesis { claim = "nomatch", turn_id = 1, status = "active" }
h_nomatch:add_evidence(S.Evidence {
    content = "Python is popular", supports = true,
    confidence = S.Confidence { value = 0.6, basis = "llm_eval" },
})
h_nomatch:update_confidence()
p_precise.hypotheses = { h_match, h_nomatch }

local precise_result = strat.re_evaluate.DeltaEval.re_evaluate(
    p_precise, { low_confidence_bound = 0.5, same_group_weight = 0.3 }, { "tech" })
check("DeltaEval: updated == 1 (only matching)", precise_result.updated == 1)
check("DeltaEval: h_match revised", h_match.status == "revised")
check("DeltaEval: h_nomatch still active", h_nomatch.status == "active")

-- LLM configure test
io.write("\n[LLM configure]\n")
local llm_mod = require("lua_solver.llm")
check("default claude_path = claude", llm_mod.claude_path == "claude")
llm_mod.configure({ claude_path = "/usr/local/bin/claude", model = "sonnet" })
check("configure: claude_path changed", llm_mod.claude_path == "/usr/local/bin/claude")
check("configure: model changed", llm_mod.model == "sonnet")
-- reset for other tests
llm_mod.configure({ claude_path = "claude", model = "opus" })

-- Summary
io.write(string.format("\n=== Results: %d passed, %d failed ===\n", pass, fail))
if fail > 0 then os.exit(1) end

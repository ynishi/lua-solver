#!/usr/bin/env lua
-- examples/run_scenario.lua
-- Run a 2-turn scenario demonstrating lua_solver features

-- Package path: add lua_solver's parent directory
local script_dir = arg[0]:match("(.*/)")
if script_dir then
    package.path = script_dir .. "../../?.lua"
        .. ";" .. script_dir .. "../../?/init.lua"
        .. ";" .. package.path
end

local Solver = require("lua_solver")

-- =========================================
-- Display helpers
-- =========================================
local ESC = string.char(27)
local function color(code, text) return ESC.."["..code.."m"..text..ESC.."[0m" end
local function header(text) io.write("\n"..color("1;36","["..text.."]").."\n") end
local function info(text) io.write(color("0;33",text).."\n") end
local function dim(text) io.write(color("0;90",text).."\n") end
local function conf_bar(v)
    local f = math.floor(v*20)
    return string.format("[%s%s] %.2f", string.rep("#",f), string.rep("-",20-f), v)
end

-- =========================================
-- Build Problem
-- =========================================
local problem = Solver.Problem {
    statement = "Lua vs Nim でよいほうは？（Rustに埋め込むスクリプト言語選定）",
    known = {
        use_case = "スクリプト埋め込み＆オリジナルDSL",
        embedding_direction = "Rustに埋め込む",
        performance_requirement = "ユーザー対話ベースにリアルタイム",
        runtime_size = "特になし",
        maintainer_count = "保守は1人、経験は1週間くらい両言語",
        hot_reload = "なし",
        existing_ecosystem = "POC実装あり（Lua=Agent実装5000行、Nim=Disktool1000行）",
        dsl_complexity = "型定義、関数定義、自動拡張",
        safety_requirement = "Sandbox必要（IO制限のみ）",
        ffi_direction = "Rust→言語のみ",
        target_platform = "バイナリ配布",
        poc_evaluation = "Lua=独特な記法だがクリティカルバグなし、Nim=AI生成コードの品質が低い（ロジックミス多い）",
        dsl_user = "本人＋AI",
        error_recovery = "ユーザー向けエラーメッセージ必須",
        long_term_vision = "プラグインエコシステム化・外部配布",
        plugin_api_surface = "フル機能公開",
        sandbox_implementation = "ホスト言語側で用意",
        type_system_requirement = "具体型の生成",
    },
    constraints = {
        "Rustとの連携がしやすい（FFI/埋め込み）",
    },
}

-- Low-confidence KnownFacts
problem.known["long_term_vision"] = Solver.KnownFact {
    value = "プラグインエコシステム化・外部配布",
    confidence = 0.5,
    source = "user",
}
problem.known["type_system_requirement"] = Solver.KnownFact {
    value = "具体型の生成",
    confidence = 0.6,
    source = "user",
}

problem.gap_rounds = math.huge

-- =========================================
-- Build Solver
-- =========================================
local solver = Solver.new {
    hypothesis_gen = Solver.strategies.hypothesis_gen.BiasAware,
    evidence_eval = Solver.strategies.evidence_eval.IndependenceWeighted,
    continuation = Solver.strategies.continuation.ExpectedValue,
    max_hypotheses = 5,
    confidence_threshold = 0.6,
    same_group_weight = 0.3,
    low_confidence_bound = 0.5,
    continuation_threshold = 0.1,
}

Solver.llm.reset_count()

-- =========================================
-- Display result
-- =========================================
local function show_result(result)
    if result.type == "solution" then
        if result.changed_keys and #result.changed_keys > 0 then
            header("Known Changes (since previous turn)")
            for _, k in ipairs(result.changed_keys) do
                local fact = problem.known[k]
                io.write(string.format("  %s: %s (conf=%.1f)\n", k, fact.value, fact.confidence))
            end
        end

        if result.hypotheses then
            header("Hypotheses (all active, by confidence)")
            for i, h in ipairs(result.hypotheses) do
                io.write(string.format("\n  %d. %s\n", i, h.claim))
                io.write(string.format("     %s (%s)\n", conf_bar(h.confidence.value), h.confidence.basis))
                dim(string.format("     turn_id=%d  status=%s", h.turn_id or 0, h.status or "?"))

                if #h.evidence > 0 then
                    local groups = {}
                    for _, e in ipairs(h.evidence) do
                        groups[e.independence_group] = (groups[e.independence_group] or 0) + 1
                        local mark = e.supports and "  +" or "  -"
                        io.write(string.format("     %s %.1f %s\n", mark, e.confidence.value, e.content))
                    end
                    local grp_parts = {}
                    for grp, cnt in pairs(groups) do
                        grp_parts[#grp_parts + 1] = string.format("%s:%d", grp, cnt)
                    end
                    dim("     groups: " .. table.concat(grp_parts, ", "))
                end
            end
        end

        header("Solution (turn_id=" .. (result.solution.turn_id or "?") .. ")")
        io.write(result.solution.content .. "\n")

        local sol = result.solution
        info(string.format("\nConfidence: %s  volatility: %.2f  basis: %s",
            conf_bar(sol.confidence.value), sol.confidence.volatility, sol.confidence.basis))

        if next(sol.constraint_results) then
            header("Constraint Check")
            for desc, ok in pairs(sol.constraint_results) do
                io.write(string.format("  %s %s\n",
                    ok and color("0;32","OK") or color("0;31","NG"), desc))
            end
        end

        if result.continuation then
            local cont = result.continuation
            header("Continuation Advice")
            if cont.recommend then
                info(string.format("Recommend: another round (expected improvement: +%.2f)", cont.expected_improvement))
                if cont.suggested_action ~= "" then
                    info("  -> " .. cont.suggested_action)
                end
            else
                dim(string.format("Sufficient (expected improvement: +%.2f < threshold)", cont.expected_improvement))
            end
            dim("reason: " .. cont.reason)
        end

        header("Turn Stats")
        dim(string.format("  new hypotheses this turn: %d",
            result.new_hypotheses and #result.new_hypotheses or 0))
        dim(string.format("  pruned this turn: %d", result.pruned_count or 0))
        dim(string.format("  active/total: %d / %d",
            #problem:active_hypotheses(), #problem.hypotheses))
        dim(string.format("  solutions accumulated: %d", #problem.solutions))
    else
        header("Unexpected: " .. result.type)
        if result.gaps then
            for _, g in ipairs(result.gaps) do
                io.write(string.format("  GAP: [%s] %s (status: %s)\n", g.key, g.question, g.status))
            end
        end
        if result.message then io.write(result.message .. "\n") end
    end
end

-- =========================================
-- Turn 1
-- =========================================
header("=== TURN 1 ===")
dim("known facts: 18 items (2 low-confidence: long_term_vision=0.5, type_system_requirement=0.6)")
dim("constraints: 1")
dim("Strategy: BiasAware + IndependenceWeighted + ExpectedValue continuation")
io.write("\n")

local result1 = solver:turn(problem)
show_result(result1)

-- =========================================
-- Turn 2: after known changes
-- =========================================
header("=== TURN 2: after known changes ===")

problem:fill("long_term_vision",
    "プラグインエコシステム化は当面しない。自分専用ツール",
    0.9, "user")
problem:fill("type_system_requirement",
    "メタテーブルベースの動的型で十分",
    0.8, "user")

dim("known changes:")
dim("  long_term_vision: 0.5 -> 0.9 (content changed)")
dim("  type_system_requirement: 0.6 -> 0.8 (content changed)")
io.write("\n")

problem.gap_rounds = math.huge

local result2 = solver:turn(problem)
show_result(result2)

-- =========================================
-- KnownFact Confidence
-- =========================================
header("KnownFact Confidence (final)")
local low_conf_items = {}
for k, fact in pairs(problem.known) do
    if fact.confidence < 0.8 then
        low_conf_items[#low_conf_items + 1] = { key = k, fact = fact }
    end
end
if #low_conf_items > 0 then
    table.sort(low_conf_items, function(a, b) return a.fact.confidence < b.fact.confidence end)
    for _, item in ipairs(low_conf_items) do
        io.write(string.format("  %s: %.1f -- %s\n",
            item.key, item.fact.confidence, item.fact.value))
    end
else
    dim("  All KnownFacts: confidence >= 0.8")
end

-- =========================================
-- Summary
-- =========================================
header("Final Summary")
dim(string.format("LLM calls: %d", Solver.llm.call_count))
dim(string.format("Total turns: %d", problem.turn_count))
dim(string.format("Hypotheses total: %d", #problem.hypotheses))
dim(string.format("Active hypotheses: %d", #problem:active_hypotheses()))
dim(string.format("Solutions accumulated: %d", #problem.solutions))
dim(string.format("Known facts: %d",
    (function() local n=0; for _ in pairs(problem.known) do n=n+1 end; return n end)()))
dim(string.format("Gap stats: unanswerable=%d, skipped=%d, low_conf_known=%d",
    problem:gap_stats().unanswerable, problem:gap_stats().skipped, problem:gap_stats().low_confidence_known))

if #problem.solutions >= 2 then
    header("Solution Confidence Progression")
    for i, sol in ipairs(problem.solutions) do
        io.write(string.format("  Turn %d: %s (vol=%.2f)\n",
            sol.turn_id, conf_bar(sol.confidence.value), sol.confidence.volatility))
    end
end

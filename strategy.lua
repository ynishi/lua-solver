-- lua_solver/strategy.lua
-- Strategy implementations (差し替え可能なアルゴリズム)

local llm = require("lua_solver.llm")
local S = require("lua_solver.structure")

local M = {}

local STRICT = "\n\n重要: 上記フォーマットのみで出力してください。説明文・見出し・マークダウン表は不要です。"

-- ========================================
-- Strategy 1: GapDetection
-- ========================================
M.gap_detection = {}

M.gap_detection.Static = {
    detect = function(problem)
        return problem:open_gaps()
    end,
}

M.gap_detection.LLM = {
    detect = function(problem)
        local open = problem:open_gaps()
        if #open > 0 then return open end

        local known_text = llm.format_context(problem.known)
        local constraint_text = ""
        for _, c in ipairs(problem.constraints) do
            constraint_text = constraint_text .. "- " .. c.description .. "\n"
        end

        local prompt = string.format([[問題を解くために不足している重要な情報を特定してください。

問題: %s

既知の情報:
%s

制約:
%s

不足情報がなければ「COMPLETE」とだけ回答。
ある場合、1行1つ厳密にこのフォーマット:
GAP: キー名 | 質問文

例:
GAP: team_size | チーム規模は何人ですか？
GAP: budget | 予算はいくらですか？]] .. STRICT,
            problem.statement,
            known_text ~= "" and known_text or "(なし)",
            constraint_text ~= "" and constraint_text or "(なし)")

        local resp = llm.call(prompt)
        if not resp or resp:match("COMPLETE") then return {} end

        local existing = {}
        for _, g in ipairs(problem.gaps) do existing[g.key] = true end

        local items = llm.extract_marked(resp, "GAP")
        for _, item in ipairs(items) do
            local key, question = item:match("^([^|]+)|%s*(.+)")
            if key then
                key = key:match("^%s*(.-)%s*$"):gsub("`", "")
                question = question:match("^%s*(.-)%s*$")
            else
                key = item:match("^%s*(%S+)")
                question = item
            end
            if key and key ~= "" and not existing[key] and not problem.known[key] then
                problem:add_gap(S.Gap { key = key, question = question or (key .. "?") })
                existing[key] = true
            end
        end

        return problem:open_gaps()
    end,
}

-- ========================================
-- Strategy 2: GapResolution
-- ========================================
M.gap_resolution = {}

M.gap_resolution.Direct = {
    resolve = function(_gap, user_input)
        return {
            known_fact = S.KnownFact {
                value = user_input,
                confidence = 0.9,
                source = "user",
            },
        }
    end,
    handle_unanswerable = function(_gap, _problem)
        return "skip"
    end,
}

M.gap_resolution.ConfidenceAware = {
    confidence_markers = {
        { patterns = { "確定", "間違いなく", "絶対" }, confidence = 1.0 },
        { patterns = { "たぶん", "おそらく", "maybe" }, confidence = 0.7 },
        { patterns = { "とりあえず", "一旦", "仮に", "仮で" }, confidence = 0.5 },
        { patterns = { "わからないけど", "推測", "guess", "不明だが" }, confidence = 0.3 },
    },

    resolve = function(self_or_gap, user_input, _problem)
        local strategy = M.gap_resolution.ConfidenceAware

        local explicit_conf, rest = user_input:match("^(%d%.%d+):%s*(.+)")
        if not explicit_conf then
            rest, explicit_conf = user_input:match("^(.-)%s*%((%d%.%d+)%)%s*$")
        end

        if explicit_conf then
            return {
                known_fact = S.KnownFact {
                    value = rest or user_input,
                    confidence = tonumber(explicit_conf),
                    source = "user",
                },
            }
        end

        local confidence = 0.9
        local input_lower = user_input:lower()
        for _, marker in ipairs(strategy.confidence_markers) do
            for _, pat in ipairs(marker.patterns) do
                if user_input:find(pat, 1, true) or input_lower:find(pat, 1, true) then
                    confidence = marker.confidence
                    goto found
                end
            end
        end
        ::found::

        return {
            known_fact = S.KnownFact {
                value = user_input,
                confidence = confidence,
                source = "user",
            },
        }
    end,

    handle_unanswerable = function(_gap, _problem)
        return "skip"
    end,
}

-- ========================================
-- Strategy 3: DecomposeStrategy
-- ========================================
M.decompose = {}

M.decompose.Threshold = {
    should = function(problem, policy)
        return problem:complexity() > (policy.decompose_threshold or 3)
    end,
    decompose = function(problem)
        local prompt = string.format([[問題を独立して解ける部分問題に分解してください。
結合度が高い場合は分解しないでください。

問題: %s

既知の情報:
%s

分解不要なら「NOSPLIT」とだけ回答。
分解する場合、1行1つ:
SUB: 部分問題の記述]] .. STRICT,
            problem.statement, llm.format_context(problem.known))

        local resp = llm.call(prompt)
        if not resp or resp:match("NOSPLIT") then return {} end

        local subs = {}
        for _, stmt in ipairs(llm.extract_marked(resp, "SUB")) do
            if #stmt > 5 then
                subs[#subs + 1] = S.Problem {
                    statement = stmt,
                    known = problem.known,
                    constraints = problem.constraints,
                }
            end
        end
        return subs
    end,
}

-- ========================================
-- Strategy 4: HypothesisGeneration
-- ========================================
M.hypothesis_gen = {}

M.hypothesis_gen.LLM = {
    generate = function(problem, policy, _existing)
        local constraint_text = ""
        for _, c in ipairs(problem.constraints) do
            constraint_text = constraint_text .. "- " .. c.description .. "\n"
        end

        local prompt = string.format([[問題に対する仮説（解の候補）を生成してください。

問題: %s

既知の情報:
%s

制約:
%s

重要: ユーザーが想定していない選択肢も含めること。
二択で聞かれていても第三・第四の選択肢を探すこと。

最大%d個。1行1つ:
HYPOTHESIS: 仮説の記述

例:
HYPOTHESIS: モノリスアーキテクチャを採用する
HYPOTHESIS: モジュラーモノリスで段階的に分離する]] .. STRICT,
            problem.statement,
            llm.format_context(problem.known),
            constraint_text ~= "" and constraint_text or "(なし)",
            policy.max_hypotheses or 5)

        local resp = llm.call(prompt)
        if not resp then return {} end

        local hypotheses = {}
        for _, claim in ipairs(llm.extract_marked(resp, "HYPOTHESIS")) do
            if #claim > 5 then
                hypotheses[#hypotheses + 1] = S.Hypothesis { claim = claim }
            end
        end
        return hypotheses
    end,
}

M.hypothesis_gen.BiasAware = (function()
    local biases = {
        { name = "二択バイアス", check = "AかBかと聞かれたらC,Dも探す" },
        { name = "現状維持バイアス", check = "何もしない/現状維持も選択肢に入れる" },
        { name = "アンカリング", check = "最初の情報に引きずられていないか確認" },
        { name = "生存者バイアス", check = "失敗事例からの仮説も生成" },
        { name = "全修正バイアス", check = "レビュー指摘=全修正ではない。環境やコンテキストで不要な項目を識別" },
    }

    return {
        biases = biases,
        generate = function(problem, policy, _existing)
            local bias_text = ""
            for _, b in ipairs(biases) do
                bias_text = bias_text .. string.format("- [%s] %s\n", b.name, b.check)
            end

            local constraint_text = ""
            for _, c in ipairs(problem.constraints) do
                constraint_text = constraint_text .. "- " .. c.description .. "\n"
            end

            local known_text = llm.format_context(problem.known)

            local prompt = string.format([[問題に対する仮説を生成してください。

問題: %s

既知の情報:
%s
（[低確信]マークの情報は、ユーザーが確信を持っていない回答です。前提として扱いすぎないこと。）

制約:
%s

バイアス補正チェックリスト:
%s

最大%d個。1行1つ:
HYPOTHESIS: 仮説の記述]] .. STRICT,
                problem.statement,
                known_text,
                constraint_text ~= "" and constraint_text or "(なし)",
                bias_text,
                policy.max_hypotheses or 5)

            local resp = llm.call(prompt)
            if not resp then return {} end

            local hypotheses = {}
            for _, claim in ipairs(llm.extract_marked(resp, "HYPOTHESIS")) do
                if #claim > 5 then
                    hypotheses[#hypotheses + 1] = S.Hypothesis { claim = claim }
                end
            end
            return hypotheses
        end,
    }
end)()

--- DeltaAwareHypothesis
--- 蓄積済み仮説を「既知の候補」としてLLMに渡し、新角度を要求
M.hypothesis_gen.DeltaAware = {
    generate = function(problem, policy, existing)
        existing = existing or {}
        local constraint_text = ""
        for _, c in ipairs(problem.constraints) do
            constraint_text = constraint_text .. "- " .. c.description .. "\n"
        end

        local existing_text = ""
        if #existing > 0 then
            existing_text = "既に検討済みの仮説（これらと異なる角度から生成すること）:\n"
            for i, h in ipairs(existing) do
                existing_text = existing_text .. string.format(
                    "%d. %s (conf: %.2f, status: %s)\n",
                    i, h.claim, h.confidence.value, h.status)
            end
        end

        local prompt = string.format([[問題に対する新しい仮説を生成してください。

問題: %s

既知の情報:
%s

制約:
%s

%s
既出の仮説とは異なる視点・アプローチからの仮説を求めます。
既出仮説の単なる言い換えは不要です。

最大%d個。1行1つ:
HYPOTHESIS: 仮説の記述]] .. STRICT,
            problem.statement,
            llm.format_context(problem.known),
            constraint_text ~= "" and constraint_text or "(なし)",
            existing_text,
            policy.max_hypotheses or 5)

        local resp = llm.call(prompt)
        if not resp then return {} end

        local hypotheses = {}
        for _, claim in ipairs(llm.extract_marked(resp, "HYPOTHESIS")) do
            if #claim > 5 then
                hypotheses[#hypotheses + 1] = S.Hypothesis { claim = claim }
            end
        end
        return hypotheses
    end,
}

--- AdversarialHypothesisGen
--- 内部generatorで仮説を生成後、各仮説に対抗仮説(!H)をペア生成
M.hypothesis_gen.Adversarial = {
    -- inner generator (デフォルト: BiasAware)
    inner = nil,

    generate = function(problem, policy, existing)
        local inner = M.hypothesis_gen.Adversarial.inner or M.hypothesis_gen.BiasAware
        local hypotheses = inner.generate(problem, policy, existing)

        if #hypotheses == 0 then return hypotheses end

        -- 仮説一覧をまとめて反論生成 (1 LLM call で効率化)
        local claims_text = ""
        for i, h in ipairs(hypotheses) do
            claims_text = claims_text .. string.format("%d. %s\n", i, h.claim)
        end

        local prompt = string.format([[以下の各仮説に対する、最も説得力のある反論仮説を1つずつ生成してください。

問題: %s

仮説一覧:
%s

各仮説に対して1行1つ:
COUNTER: 番号|反論仮説の記述

例:
COUNTER: 1|初期コストが高く中小企業には不適]] .. STRICT,
            problem.statement, claims_text)

        local resp = llm.call(prompt)
        if resp then
            for line in (resp .. "\n"):gmatch("([^\n]*)\n") do
                local _num, content = line:match("COUNTER:%s*(%d+)|%s*(.+)")
                if content and #content > 5 then
                    hypotheses[#hypotheses + 1] = S.Hypothesis {
                        claim = "[反証] " .. content:match("^%s*(.-)%s*$"),
                    }
                end
            end
        end

        -- max_hypotheses上限でトリミング (反証含めて超過しないよう)
        local max = policy.max_hypotheses or 5
        if #hypotheses > max then
            while #hypotheses > max do
                table.remove(hypotheses)
            end
        end

        return hypotheses
    end,
}

-- ========================================
-- Strategy 5: EvidenceEvaluation
-- ========================================
M.evidence_eval = {}

--- 内部: evidence取得用LLMプロンプト (共通)
function M._eval_evidence_llm(hypothesis, problem)
    local prompt = string.format([[仮説について、支持する根拠と反証する根拠を挙げてください。

問題: %s
仮説: %s

既知の情報:
%s

1行1つ:
EVIDENCE: support|0.8|根拠の記述
EVIDENCE: contradict|0.6|反証の記述

例:
EVIDENCE: support|0.7|チーム規模が小さいため管理コストが低い
EVIDENCE: contradict|0.5|将来のスケーラビリティに制約がある]] .. STRICT,
        problem.statement, hypothesis.claim,
        llm.format_context(problem.known))

    return llm.call(prompt)
end

--- 内部: evidenceパース (共通)
function M._parse_evidence(resp, hypothesis, call_id)
    call_id = call_id or "unknown"
    local found = false

    for line in (resp .. "\n"):gmatch("([^\n]*)\n") do
        local direction, conf_str, content = line:match(
            "EVIDENCE:%s*(%w+)|([%d%.]+)|%s*(.+)")
        if direction and content then
            hypothesis:add_evidence(S.Evidence {
                content = content,
                supports = direction:match("support") ~= nil,
                confidence = S.Confidence {
                    value = tonumber(conf_str) or 0.5,
                    basis = "llm_eval",
                },
                source_id = call_id,
                independence_group = call_id,
            })
            found = true
        end
    end

    -- Fallback: markdown table
    if not found then
        for line in (resp .. "\n"):gmatch("([^\n]*)\n") do
            if line:match("^|") and not line:match("^|%-") and not line:match("^|%s*#") then
                local cells = {}
                for cell in line:gmatch("|%s*([^|]+)%s*") do
                    cell = cell:match("^%s*(.-)%s*$")
                    if cell ~= "" then cells[#cells + 1] = cell end
                end
                if #cells >= 3 then
                    local dir = cells[1]:lower()
                    local conf_val = tonumber(cells[2]) or 0.5
                    local content = cells[3]
                    if dir:match("support") or dir:match("contra") then
                        hypothesis:add_evidence(S.Evidence {
                            content = content,
                            supports = dir:match("support") ~= nil,
                            confidence = S.Confidence {
                                value = conf_val,
                                basis = "llm_eval",
                            },
                            source_id = call_id,
                            independence_group = call_id,
                        })
                    end
                end
            end
        end
    end
end

--- 内部: KnownFact確信度の波及
--- 元のconfidenceを保持し、毎回元値から再計算 (累積乗算を防止)
function M._apply_known_confidence(hypothesis, problem, policy)
    local bound = policy.low_confidence_bound or 0.5
    for _, e in ipairs(hypothesis.evidence) do
        -- 元値を保持 (初回のみ記録)
        if not e._original_confidence then
            e._original_confidence = e.confidence.value
        end
        -- 毎回元値から再計算
        local discount = 1.0
        local applied_keys = {}
        for key, fact in pairs(problem.known) do
            if fact.confidence < bound then
                if e.content:find(fact.value, 1, true) or e.content:find(key, 1, true) then
                    discount = discount * fact.confidence
                    applied_keys[#applied_keys + 1] = key
                end
            end
        end
        e.confidence.value = e._original_confidence * discount
        if #applied_keys > 0 then
            e.confidence.basis = "llm_eval (low_conf_known:" .. table.concat(applied_keys, ",") .. ")"
        end
    end
end

--- デフォルトのevaluate_batch実装 (per-hypothesis loop)
local function default_evaluate_batch(impl, hypotheses, problem, policy)
    for _, h in ipairs(hypotheses) do
        impl.evaluate(h, problem, policy)
    end
    return { discovered_gaps = {} }
end

--- SimpleCount
M.evidence_eval.SimpleCount = {
    evaluate = function(hypothesis, problem, policy)
        local resp, _, call_id = M._eval_evidence_llm(hypothesis, problem)
        if not resp then return end
        M._parse_evidence(resp, hypothesis, call_id)
        hypothesis:update_confidence()
    end,
    evaluate_batch = function(hypotheses, problem, policy)
        return default_evaluate_batch(M.evidence_eval.SimpleCount, hypotheses, problem, policy)
    end,
}

--- LLM (SimpleCountのエイリアス)
M.evidence_eval.LLM = {
    evaluate = function(hypothesis, problem, policy)
        local resp, _, call_id = M._eval_evidence_llm(hypothesis, problem)
        if not resp then return end
        M._parse_evidence(resp, hypothesis, call_id)
        hypothesis:update_confidence()
    end,
    evaluate_batch = function(hypotheses, problem, policy)
        return default_evaluate_batch(M.evidence_eval.LLM, hypotheses, problem, policy)
    end,
}

--- IndependenceWeighted
M.evidence_eval.IndependenceWeighted = {
    evaluate = function(hypothesis, problem, policy)
        local resp, _, call_id = M._eval_evidence_llm(hypothesis, problem)
        if not resp then return end
        M._parse_evidence(resp, hypothesis, call_id)

        if policy and policy.low_confidence_bound then
            M._apply_known_confidence(hypothesis, problem, policy)
        end

        hypothesis:update_confidence(policy)
    end,
    evaluate_batch = function(hypotheses, problem, policy)
        return default_evaluate_batch(M.evidence_eval.IndependenceWeighted, hypotheses, problem, policy)
    end,
}

-- ========================================
-- Strategy 6: ConstraintVerification
-- ========================================
M.constraint_verify = {}

M.constraint_verify.LLM = {
    verify = function(solution, constraints, problem)
        if #constraints == 0 then return {} end

        local clist = ""
        for i, c in ipairs(constraints) do
            clist = clist .. string.format("%d. %s\n", i, c.description)
        end

        local prompt = string.format([[解決策が制約を満たしているか判定してください。

問題: %s
解決策:
%s

制約:
%s

1行1つ:
CHECK: 番号|yes or no|理由

例:
CHECK: 1|yes|チーム規模に適合
CHECK: 2|no|予算超過の可能性]] .. STRICT,
            problem.statement,
            type(solution.content) == "string" and solution.content:sub(1, 2000) or "(structured)",
            clist)

        local resp = llm.call(prompt)
        if not resp then return {} end

        local results = {}
        for line in (resp .. "\n"):gmatch("([^\n]*)\n") do
            local num_str, yn = line:match("CHECK:%s*(%d+)|%s*(%w+)")
            if num_str then
                local idx = tonumber(num_str)
                if idx and constraints[idx] then
                    results[constraints[idx].description] = (yn == "yes")
                end
            end
        end
        return results
    end,
}

-- ========================================
-- Strategy 7: SubProblemMerge
-- ========================================
M.merge = {}

M.merge.WeakestLink = {
    merge = function(sub_solutions, parent)
        if #sub_solutions == 0 then return nil end

        local min_conf, max_vol = 1.0, 0.0
        local contents = {}
        local all_basis = {}

        for _, s in ipairs(sub_solutions) do
            contents[#contents + 1] = tostring(s.content)
            min_conf = math.min(min_conf, s.confidence.value)
            max_vol = math.max(max_vol, s.confidence.volatility)
            for _, h in ipairs(s.basis) do
                all_basis[#all_basis + 1] = h
            end
        end

        local prompt = string.format(
            [[部分問題の解決策を統合してください。

問題: %s

部分解:
%s

統合した解決策を記述してください。]],
            parent.statement, table.concat(contents, "\n---\n"))

        local resp = llm.call(prompt)

        return S.Solution {
            content = resp or table.concat(contents, "\n"),
            confidence = S.Confidence {
                value = min_conf,
                volatility = max_vol,
                basis = "merged:" .. #sub_solutions,
            },
            basis = all_basis,
        }
    end,
}

-- ========================================
-- Strategy 8: ContinuationJudge
-- ========================================
M.continuation = {}

M.continuation.AlwaysStop = {
    judge = function(_solution, _problem, _policy)
        return {
            recommend = false,
            expected_improvement = 0,
            reason = "AlwaysStop policy",
            suggested_action = "",
        }
    end,
}

M.continuation.ExpectedValue = {
    judge = function(solution, problem, policy)
        local stats = problem:gap_stats()
        local threshold = policy.continuation_threshold or 0.1

        local ei = stats.unanswerable * 0.05
                 + stats.skipped * 0.08
                 + stats.low_confidence_known * 0.03

        if solution.confidence.volatility > (policy.volatility_threshold or 0.4) then
            ei = ei + 0.05
        end

        local recommend = ei >= threshold

        local suggested = ""
        if stats.skipped > 0 then
            for _, g in ipairs(problem.gaps) do
                if g.status == "skipped" then
                    suggested = string.format("'%s' の深掘りが効果的です", g.key)
                    break
                end
            end
        elseif stats.low_confidence_known > 0 then
            for k, fact in pairs(problem.known) do
                if fact.confidence < 0.6 then
                    suggested = string.format("'%s' の確信度を上げることが効果的です（現在 %.1f）", k, fact.confidence)
                    break
                end
            end
        elseif stats.unanswerable > 0 then
            suggested = "別角度からの質問を試みることが効果的です"
        end

        return {
            recommend = recommend,
            expected_improvement = ei,
            reason = string.format(
                "unanswerable=%d, skipped=%d, low_conf_known=%d, volatility=%.2f",
                stats.unanswerable, stats.skipped, stats.low_confidence_known,
                solution.confidence.volatility),
            suggested_action = suggested,
        }
    end,
}

-- ========================================
-- Strategy 9: ReEvaluate
-- ========================================
M.re_evaluate = {}

--- NoOp: 何もしない
M.re_evaluate.NoOp = {
    re_evaluate = function(_problem, _policy, _changed_keys)
        return { updated = 0, superseded = 0, delta = 0 }
    end,
}

--- DeltaEval: changed_keysに関連するevidenceを持つ仮説のみ再評価
M.re_evaluate.DeltaEval = {
    re_evaluate = function(problem, policy, changed_keys)
        if not changed_keys or #changed_keys == 0 then
            return { updated = 0, superseded = 0, delta = 0 }
        end

        local updated, superseded = 0, 0
        local total_delta = 0

        for _, h in ipairs(problem:active_hypotheses()) do
            local old_conf = h.confidence.value
            local needs_update = false

            for _, e in ipairs(h.evidence) do
                for _, key in ipairs(changed_keys) do
                    local fact = problem.known[key]
                    if fact and (e.content:find(key, 1, true)
                        or e.content:find(fact.value, 1, true)) then
                        needs_update = true
                        break
                    end
                end
                if needs_update then break end
            end

            if needs_update then
                h.status = "revised"
                if policy.low_confidence_bound then
                    M._apply_known_confidence(h, problem, policy)
                end
                h:update_confidence(policy)
                updated = updated + 1
                total_delta = total_delta + math.abs(h.confidence.value - old_conf)

                local threshold = policy.supersede_threshold or 0.2
                if h.confidence.value < threshold then
                    h.status = "superseded"
                    superseded = superseded + 1
                end
            end
        end

        return { updated = updated, superseded = superseded, delta = total_delta }
    end,
}

--- DecayBased: 古いターンの仮説をdecay割引 + supersede判定
M.re_evaluate.DecayBased = {
    re_evaluate = function(problem, policy, _changed_keys)
        local decay_rate = policy.hypothesis_decay_rate or 0.9
        local supersede_threshold = policy.supersede_threshold or 0.2
        local current_turn = problem.turn_count or 1
        local updated, superseded = 0, 0
        local total_delta = 0

        for _, h in ipairs(problem:active_hypotheses()) do
            local age = current_turn - (h.turn_id or 0)
            if age > 0 then
                local old_conf = h.confidence.value
                local decay = decay_rate ^ age
                h.confidence.value = h.confidence.value * decay
                -- basis上書き (累積連結ではなく毎回置換)
                h.confidence.basis = string.format("%s (decay:%.2f age:%d)",
                    h.confidence.basis:gsub(" %(decay:[%d%.]+.-%)$", ""), decay, age)
                updated = updated + 1
                total_delta = total_delta + math.abs(h.confidence.value - old_conf)

                if h.confidence.value < supersede_threshold then
                    h.status = "superseded"
                    superseded = superseded + 1
                end
            end
        end

        return { updated = updated, superseded = superseded, delta = total_delta }
    end,
}

-- ========================================
-- Synthesize
-- ========================================
M.synthesize = {}

M.synthesize.LLM = {
    synthesize = function(hypotheses, problem)
        local hyp_text = ""
        for i, h in ipairs(hypotheses) do
            hyp_text = hyp_text .. string.format(
                "%d. %s (confidence: %.2f, %s)\n",
                i, h.claim, h.confidence.value, h.confidence.basis)
            for _, e in ipairs(h.evidence) do
                local dir = e.supports and "支持" or "反証"
                hyp_text = hyp_text .. string.format(
                    "   - [%s %.1f] %s\n",
                    dir, e.confidence.value, e.content)
            end
        end

        local prompt = string.format([[評価済み仮説を踏まえ、最善の解決策を提案してください。

問題: %s

評価済み仮説:
%s

既知の情報:
%s

複数の仮説の組み合わせも可。根拠を明示すること。]],
            problem.statement, hyp_text,
            llm.format_context(problem.known))

        local resp = llm.call(prompt)

        local best_conf = 0
        local best_vol = 1.0
        for _, h in ipairs(hypotheses) do
            if h.confidence.value > best_conf then
                best_conf = h.confidence.value
                best_vol = h.confidence.volatility
            end
        end

        return S.Solution {
            content = resp or "",
            confidence = S.Confidence {
                value = best_conf,
                volatility = best_vol,
                basis = #hypotheses .. " hypotheses",
            },
            basis = hypotheses,
        }
    end,
}

return M

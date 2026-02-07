# lua_solver Modeling

## Core Thesis

「課題解決」ドメインは **Structure（不変骨格）+ Strategy IF（差し替え可能アルゴリズム）** で完全にモデリングできる。

---

## Structure（7つの不変型）

```
Problem
├── KnownFact     ... 確信度付き既知事実（soft判定: 0.0〜1.0）
├── Gap            ... 知識の穴（情報完全性管理）
├── Constraint     ... 解が満たすべき条件
├── Hypothesis     ... 解の候補
│   └── Evidence   ... 支持/反証 + independence group
├── Confidence     ... value + volatility + basis
└── Solution       ... 合成解 + 制約充足結果
```

これらの組み換えと関係性で、あらゆる課題解決プロセスの状態を表現する。

---

## Strategy IF（10の差し替え点）と実装一覧

外部IFは `strategy_name.method(inputs) → outputs` で統一。内部実装（LLM / ヒューリスティック / 人間判断）は自由。

| # | Strategy | 責務 | 実装 |
|---|----------|------|------|
| 1 | GapDetection | 情報不足の検出 | Static, LLM |
| 2 | GapResolution | 不足情報の解決 | Direct, ConfidenceAware |
| 3 | Decompose | 部分問題への分解 | Threshold |
| 4 | HypothesisGen | 仮説生成 | LLM, BiasAware, DeltaAware, Adversarial |
| 5 | EvidenceEval | 根拠評価 (evaluate_batch IF) | SimpleCount, LLM, IndependenceWeighted |
| 6 | ConstraintVerify | 制約充足判定 | LLM |
| 7 | Synthesize | 仮説群→解の合成 | LLM |
| 8 | Merge | 部分解の統合 | WeakestLink |
| 9 | Continuation | 継続/打切り判定 | AlwaysStop, ExpectedValue |
| 10 | ReEvaluate | 情報変化時の再評価 | NoOp, DeltaEval, DecayBased |

### LLM Backend

デフォルトはClaude Code Headless Mode (`claude -p`)。`llm.call` を差し替えることで任意のLLM APIに対応可能。

---

## 既存フレームワークとの対応

### 学術フレームワーク

| フレームワーク | 構造 | lua_solverでの対応 |
|---|---|---|
| ReAct | Thought→Action→Obs線形ループ | Hypothesis→EvalEvidence→KnownFact更新 |
| CoT | 線形推論チェーン | 各LLM call内部で暗黙使用 |
| ToT | 木構造分岐 + self-eval | HypGen→Confidence→supersede/prune |
| GoT | DAG（合流・分岐自由） | Synthesize（複数仮説の合成） |
| LATS | MCTS + LM value function | evaluate_batch IFで拡張可能（未実装） |
| DSPy | 宣言的モジュール + 自動最適化 | Strategy + Policy（最適化は将来課題） |

### 商用プロダクト

| プロダクト | アプローチ | lua_solverでの表現 |
|---|---|---|
| ClaudeCode | Sub並列 + 柔軟対応 | Strategy差し替え + evaluate_batch並列化 |
| Codex | 仮説検証→段階的確定 | Hypothesis→Evidence→confidence→supersedeループ |
| Gemini | 大Context一括投入 | synthesize.LLMにcontext全投入（実装詳細の差） |
| フローガイド系Prompt | 構造化された質問フロー | Gap Detection + Constraint定義 |
| Plugin/MCP/Tool | 外部ツール接続 | Strategy追加（eval内でtool呼ぶだけ） |
| Skill/Agent拡張 | 能力追加 | Strategy IFの差し替え or 組合せ |

全て **Structureの組み換え + Strategy実装差異** に帰着する。

---

## 独自性

| 機能 | 他フレームワークとの差 |
|---|---|
| KnownFact confidence（軟判定） | 多くはbinary（known/unknown） |
| Independence-weighted evidence | 同一ソース割引は見当たらない |
| Gap Detection（仮説生成前の情報完全性チェック） | ReActのActionが近いが事前/事後が異なる |
| Confidence伝播（低確信KnownFact→Evidence割引） | 独自 |
| Continuation Judge（期待改善値で打切り） | LATSのbudget管理が近い |

これらは **「人間も正解がわからない」前提** から導かれている。他フレームワークの多くはground truthが存在するベンチマーク向き。

---

## 拡張設計（未実装）

基本構造は完成。以降の改善は全てStrategy IF内部で吸収可能。

| 拡張 | 対応Strategy | 構造変更 |
|------|-------------|---------|
| MCT Selective Deepening (LATS的) | EvidenceEval.evaluate_batch拡張 | 不要 |
| LLMSemanticEval (意味的re-evaluate) | ReEvaluate差し替え | 不要 |
| Adversarial強化 (反証ペア) | HypothesisGen差し替え | 不要 |
| Prompting改善 | synthesize/evalのプロンプト文面 | 不要 |
| Policy自動最適化 | DSPy的なtuning | 不要 |

---

## 変更履歴

- 0.1.0: lua_solverとして公開用に整理。LLM backend差し替え対応、テスト追加

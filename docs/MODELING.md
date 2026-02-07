# lua_solver Modeling

## Core Thesis

The "problem-solving" domain can be fully modeled with **Structure (immutable skeleton) + Strategy IF (swappable algorithms)**.

---

## Structure (7 immutable types)

```
Problem
├── KnownFact     ... known fact with confidence (soft judgment: 0.0–1.0)
├── Gap            ... knowledge hole (information completeness management)
├── Constraint     ... condition the solution must satisfy
├── Hypothesis     ... solution candidate
│   └── Evidence   ... support/contradiction + independence group
├── Confidence     ... value + volatility + basis
└── Solution       ... synthesized answer + constraint satisfaction results
```

All problem-solving process states are expressed through combinations and relationships of these types.

---

## Strategy IF (11 swap points) and implementations

External IF is unified as `strategy_name.method(inputs) → outputs`. Internal implementation (LLM / heuristic / human judgment) is unconstrained.

| # | Strategy | Responsibility | Implementations |
|---|----------|----------------|-----------------|
| 1 | GapDetection | Detect information gaps | Static, LLM |
| 2 | GapResolution | Resolve missing information | Direct, ConfidenceAware |
| 3 | Decompose | Decompose into sub-problems | Threshold |
| 4 | HypothesisGen | Generate hypotheses | LLM, BiasAware, DeltaAware, Adversarial |
| 5 | EvidenceEval | Evaluate evidence (evaluate_batch IF) | SimpleCount, LLM, IndependenceWeighted, Selective |
| 6 | ConstraintVerify | Check constraint satisfaction | LLM |
| 7 | Synthesize | Synthesize hypotheses into solution | LLM |
| 8 | Merge | Merge sub-solutions | WeakestLink |
| 9 | Continuation | Continue/stop judgment | AlwaysStop, ExpectedValue |
| 10 | ReEvaluate | Re-evaluate on information change | NoOp, DeltaEval, DecayBased |
| 11 | HypothesisSelection | Select which hypotheses to evaluate/rank | Greedy, UCB1, Thompson |

### LLM Backend

Default is Claude Code Headless Mode (`claude -p`). Replace `llm.call` to use any LLM API.

---

## Correspondence with existing frameworks

### Academic frameworks

| Framework | Structure | lua_solver mapping |
|---|---|---|
| ReAct | Thought→Action→Obs linear loop | Hypothesis→EvalEvidence→KnownFact update |
| CoT | Linear reasoning chain | Implicitly used within each LLM call |
| ToT | Tree-structured branching + self-eval | HypGen→Confidence→supersede/prune |
| GoT | DAG (free merge/branch) | Synthesize (merge multiple hypotheses) |
| LATS | MCTS + LM value function | Extensible via evaluate_batch IF (not yet implemented) |
| DSPy | Declarative modules + auto-optimization | Strategy + Policy (optimization is future work) |

### Commercial products

| Product | Approach | lua_solver representation |
|---|---|---|
| ClaudeCode | Parallel sub-tasks + flexible handling | Strategy swap + evaluate_batch parallelization |
| Codex | Hypothesis verification → incremental confirmation | Hypothesis→Evidence→confidence→supersede loop |
| Gemini | Large context bulk injection | Full context injection to synthesize.LLM (implementation detail difference) |
| Flow-guided prompts | Structured question flow | Gap Detection + Constraint definition |
| Plugin/MCP/Tool | External tool integration | Strategy addition (just call tool within eval) |
| Skill/Agent extensions | Capability addition | Strategy IF swap or combination |

All reduce to **Structure recombination + Strategy implementation differences**.

---

## Unique features

| Feature | Difference from other frameworks |
|---|---|
| KnownFact confidence (soft judgment) | Most use binary (known/unknown) |
| Independence-weighted evidence | Same-source discounting not found elsewhere |
| Gap Detection (information completeness check before hypothesis generation) | ReAct's Action is close but differs in pre/post timing |
| Confidence propagation (low-confidence KnownFact → Evidence discount) | Unique |
| Continuation Judge (stop based on expected improvement value) | LATS budget management is closest |
| Hypothesis Selection (UCB1/Thompson for evaluate budget allocation) | Inspired by swarm-engine ExplorationMap + SelectionLogic |

These derive from the premise that **"humans also don't know the correct answer"**. Most other frameworks are oriented toward benchmarks where ground truth exists.

---

## Extension design

The core structure is complete. All future improvements can be absorbed within Strategy IFs.

| Extension | Target Strategy | Structure change | Status |
|-----------|----------------|-----------------|--------|
| Selective Deepening (UCB1/Thompson) | HypothesisSelection + EvidenceEval.Selective | None | **Implemented** |
| Cross-turn deepening (re-evaluate existing via selection) | HypothesisSelection + EvidenceEval | None | Planned |
| LLMSemanticEval (semantic re-evaluate) | ReEvaluate swap | None | Planned |
| Adversarial enhancement (contradiction pairs) | HypothesisGen swap | None | Planned |
| Prompting improvements | synthesize/eval prompt text | None | Planned |
| Policy auto-optimization | DSPy-style tuning | None | Planned |

---

## Changelog

- 0.2.0: HypothesisSelection strategy (Greedy/UCB1/Thompson), Selective evaluate_batch, eval_budget policy
- 0.1.0: Organized for publication as lua_solver. LLM backend swap support, tests added

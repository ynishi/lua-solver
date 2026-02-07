# lua_solver

Structure + Strategy based problem-solving framework for Lua.

## Core Thesis

Problem-solving can be fully modeled as **Structure (immutable data skeleton) + Strategy IF (swappable algorithms)**.

## Structure (7 immutable types)

```
Problem
├── KnownFact     ... known facts with confidence (soft: 0.0-1.0)
├── Gap            ... knowledge holes (information completeness)
├── Constraint     ... conditions the solution must satisfy
├── Hypothesis     ... solution candidates
│   └── Evidence   ... support/contradict + independence group
├── Confidence     ... value + volatility + basis
└── Solution       ... synthesized solution + constraint results
```

## Strategy IF (10 swappable points)

| # | Strategy | Responsibility |
|---|----------|----------------|
| 1 | GapDetection | Detect missing information |
| 2 | GapResolution | Resolve missing information |
| 3 | Decompose | Break into sub-problems |
| 4 | HypothesisGen | Generate hypotheses (Adversarial, DeltaAware, etc.) |
| 5 | EvidenceEval | Evaluate evidence (evaluate_batch IF) |
| 6 | ConstraintVerify | Check constraint satisfaction |
| 7 | Synthesize | Synthesize hypotheses into solution |
| 8 | Merge | Merge sub-solutions |
| 9 | Continuation | Continue/stop decision |
| 10 | ReEvaluate | Re-evaluate on information change |

## Install

```bash
luarocks install lua_solver
```

Or clone directly:

```bash
git clone https://github.com/ynishi/lua-solver.git lua_solver
```

Note: The directory must be named `lua_solver` (underscore) for `require("lua_solver")` to work. The `-o` target in the clone command handles this. If you already cloned, rename:

```bash
mv lua-solver lua_solver
```

## Quick Start

```lua
local solver = require("lua_solver")

-- Define a problem
local problem = solver.Problem {
    statement = "Which database should we use?",
    known = {
        scale = solver.KnownFact { value = "10M users", confidence = 0.9 },
        budget = "limited",  -- auto-wrapped as KnownFact(confidence=0.9)
    },
    gaps = {
        { "read_write_ratio", "What is the read/write ratio?" },
        { "latency_req", "What is the latency requirement?" },
    },
    constraints = {
        "Must handle 10M users",
        "Budget under $1000/month",
    },
}

-- Create engine with default strategies
local engine = solver.new()

-- Or swap strategies
local engine = solver.new({
    hypothesis_gen = solver.strategies.hypothesis_gen.DeltaAware,
    re_evaluate = solver.strategies.re_evaluate.DecayBased,
})
```

## LLM Backend

Default implementation uses Claude Code CLI in [Headless Mode](https://docs.anthropic.com/en/docs/claude-code/cli-usage#non-interactive-mode) (`claude -p`).

```lua
-- Configure the default backend
solver.llm.configure({
    claude_path = "/usr/local/bin/claude",
    model = "sonnet",
})

-- Or replace the call function entirely
solver.llm.call = function(prompt)
    -- your custom LLM API call
    return result, nil, "call-id"
end
```

## Tests

```bash
lua lua_solver/test.lua
```

104 unit tests, no LLM required.

## License

MIT

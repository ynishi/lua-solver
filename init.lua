-- lua_solver/init.lua
-- Module entry point: require("lua_solver")

local structure = require("lua_solver.structure")
local strategy  = require("lua_solver.strategy")
local engine    = require("lua_solver.engine")
local llm       = require("lua_solver.llm")

return {
    -- DSL Constructors (Structure)
    Problem    = structure.Problem,
    Gap        = structure.Gap,
    Constraint = structure.Constraint,
    Hypothesis = structure.Hypothesis,
    Evidence   = structure.Evidence,
    Confidence = structure.Confidence,
    Solution   = structure.Solution,
    KnownFact  = structure.KnownFact,

    -- Strategies (swappable)
    strategies = strategy,

    -- Engine
    new = engine.new,

    -- LLM config
    llm = llm,
}

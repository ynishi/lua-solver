-- lua_solver/llm.lua
-- Default LLM backend: Claude Code Headless Mode (claude -p)
--
-- Default backend uses Claude Code CLI Headless Mode.
-- https://docs.anthropic.com/en/docs/claude-code/cli-usage#non-interactive-mode
--
-- Headless Mode is a non-interactive execution mode designed for CI/automation.
-- Prompts are passed via tmpfile to stdin (no shell expansion).
--
-- Replaceable: any function satisfying M.call(prompt) -> result, err, call_id:
--   llm.call = function(prompt) return my_api_call(prompt) end

local M = {}

M.claude_path = "claude"  -- default: resolved from PATH
M.model = "opus"
M.debug = false
M.call_count = 0

--- Configure settings (Claude Code Headless Mode specific)
--- @param opts table { claude_path?: string, model?: string, debug?: boolean }
function M.configure(opts)
    if opts.claude_path then M.claude_path = opts.claude_path end
    if opts.model then M.model = opts.model end
    if opts.debug ~= nil then M.debug = opts.debug end
end

--- LLM call (replaceable: M.call = your_function)
function M.call(prompt)
    M.call_count = M.call_count + 1
    local call_id = "llm-call-" .. M.call_count

    local tmpfile = os.tmpname()
    local f = io.open(tmpfile, "w")
    if not f then return nil, "failed to create temp file", call_id end
    f:write(prompt)
    f:close()

    local cmd = string.format(
        "%s -p --model %s < %s 2>/dev/null",
        M.claude_path, M.model, tmpfile
    )

    if M.debug then
        io.stderr:write(string.format("[LLM #%d] %s...\n",
            M.call_count, prompt:sub(1, 80):gsub("\n", " ")))
    end

    local handle = io.popen(cmd)
    if not handle then
        os.remove(tmpfile)
        return nil, "failed to execute claude", call_id
    end

    local result = handle:read("*a")
    local ok = handle:close()
    os.remove(tmpfile)

    if M.debug then
        io.stderr:write(string.format("[LLM #%d] -> %d chars\n",
            M.call_count, result and #result or 0))
    end

    if not ok then return nil, "claude exited with error", call_id end
    return result, nil, call_id
end

--- Convert table to human-readable text (for LLM context)
function M.format_context(t, indent)
    indent = indent or ""
    if type(t) ~= "table" then return indent .. tostring(t) end

    local parts = {}
    for k, v in pairs(t) do
        if type(v) == "function" then
            -- skip
        elseif type(v) == "table" and v.value and v.confidence then
            -- KnownFact
            local conf_mark = ""
            if v.confidence < 0.6 then conf_mark = " [low confidence]"
            elseif v.confidence < 0.8 then conf_mark = " [medium confidence]"
            end
            parts[#parts + 1] = indent .. tostring(k) .. ": " .. tostring(v.value) .. conf_mark
        elseif type(v) == "table" then
            parts[#parts + 1] = indent .. tostring(k) .. ":"
            parts[#parts + 1] = M.format_context(v, indent .. "  ")
        else
            parts[#parts + 1] = indent .. tostring(k) .. ": " .. tostring(v)
        end
    end
    return table.concat(parts, "\n")
end

function M.reset_count()
    M.call_count = 0
end

--- Extract marked lines from response (supports multiple formats)
function M.extract_marked(resp, prefix)
    if not resp then return {} end
    local results = {}
    local text = resp .. "\n"

    -- Format 1: PREFIX: content
    for line in text:gmatch("([^\n]*)\n") do
        local content = line:match("^%s*" .. prefix .. ":%s*(.+)")
        if content then
            results[#results + 1] = content:match("^%s*(.-)%s*$")
        end
    end
    if #results > 0 then return results end

    -- Format 2: markdown table
    for line in text:gmatch("([^\n]*)\n") do
        if line:match("^|%s*%d") then
            local cells = {}
            for cell in line:gmatch("|%s*([^|]+)%s*") do
                cell = cell:match("^%s*(.-)%s*$")
                if cell ~= "" then cells[#cells + 1] = cell end
            end
            if #cells >= 3 then
                local key = cells[2]:gsub("`", "")
                results[#results + 1] = key .. " | " .. cells[3]
            elseif #cells >= 2 then
                results[#results + 1] = cells[1]:gsub("`", "") .. " | " .. cells[2]
            end
        end
    end
    if #results > 0 then return results end

    -- Format 3: numbered/bulleted list
    for line in text:gmatch("([^\n]*)\n") do
        local content = line:match("^%s*%d+[%.%)%s]+(.+)")
            or line:match("^%s*[%-%*]%s+(.+)")
        if content and #content > 5 then
            results[#results + 1] = content:match("^%s*(.-)%s*$")
        end
    end

    return results
end

return M

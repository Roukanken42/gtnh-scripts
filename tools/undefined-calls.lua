-- Finds calls that will fail at run time but compile perfectly.
--
-- luac -p only checks syntax: Lua resolves a bare name at RUN time, so deleting a
-- function while leaving its callers behind compiles fine and then dies with
-- "attempt to call a nil value" the first time that branch is reached. That is
-- exactly how three helpers went missing from setup.lua and every check passed.
--
-- Two faults are reported:
--
--   NEVER DEFINED   `name(` where `name` is never introduced in the file as a
--                   local, a function, a parameter or a loop variable, and is not
--                   a known global.
--
--   USED TOO EARLY  `name(` ABOVE the `local` that declares it. A local is only
--                   in scope from its declaration down, so a call above it does
--                   not see it at all -- it resolves to a global, finds nil, and
--                   dies. The name IS defined in the file, so the first check
--                   waves it through; this one is what catches a helper that was
--                   added below the code that uses it.
--
-- Crude on purpose. False positives are fine -- each is one line to eyeball.

local KNOWN = {}
for _, n in ipairs({
    "assert", "error", "ipairs", "next", "pairs", "pcall", "print", "require",
    "select", "setmetatable", "getmetatable", "tonumber", "tostring", "type",
    "rawget", "rawset", "rawequal", "unpack", "xpcall", "collectgarbage", "load",
    "loadstring", "dofile", "string", "table", "math", "os", "io", "coroutine",
    "debug", "bit32", "checkArg",
}) do KNOWN[n] = true end

local KEYWORD = {}
for _, n in ipairs({
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
    "true", "until", "while",
}) do KEYWORD[n] = true end

-- Replaces a run of source with spaces, keeping its newlines, so that stripping
-- strings and comments does not move anything: the offsets below become line
-- numbers, and a report pointing at the wrong line is worse than no report.
local function blank(s)
    return (s:gsub("[^\n]", " "))
end

local function lineOf(src, pos)
    local _, n = src:sub(1, pos):gsub("\n", "")
    return n + 1
end

local function scan(path)
    local f = assert(io.open(path, "r"))
    local src = f:read("a")
    f:close()

    -- Strings go FIRST: several of them contain "--", and stripping comments
    -- first would eat the closing quote and spill the rest of the line into code.
    src = src:gsub("%-%-%[%[.-%]%]", blank)
    src = src:gsub("%[%[.-%]%]", blank)
    src = src:gsub('"[^"\n]*"', blank)
    src = src:gsub("'[^'\n]*'", blank)
    src = src:gsub("%-%-[^\n]*", blank)

    local defined = {}
    local localAt = {}      -- name -> offset of its first `local` declaration

    for pos, names in src:gmatch("()local%s+([%w_%s,]+)") do
        for n in names:gmatch("[%a_][%w_]*") do
            if n ~= "function" then
                defined[n] = true
                if not localAt[n] or pos < localAt[n] then localAt[n] = pos end
            end
        end
    end
    -- A plain `function f()` is a global: callable from anywhere the call happens
    -- after load, so it gets no position and no ordering check.
    for n in src:gmatch("function%s+([%a_][%w_]*)") do defined[n] = true end
    for n in src:gmatch("function%s+[%a_][%w_%.:]*%s*%(([^%)]*)%)") do
        for a in n:gmatch("[%a_][%w_]*") do defined[a] = true end
    end
    for names in src:gmatch("for%s+([%w_%s,]+)%s*[=i]") do
        for n in names:gmatch("[%a_][%w_]*") do defined[n] = true end
    end

    -- Only BARE calls: a leading "." or ":" makes it a field or method, resolved
    -- on some table, which cannot be checked this way.
    local faults, seen = {}, {}
    for prefix, pos, name in src:gmatch("([^%w_%.:])()([%a_][%w_]*)%s*%(") do
        local _ = prefix
        if not KNOWN[name] and not KEYWORD[name] and not seen[name] then
            if not defined[name] then
                seen[name] = true
                faults[#faults + 1] = {
                    name = name, line = lineOf(src, pos),
                    why = "called, never defined here",
                }
            elseif localAt[name] and pos < localAt[name] then
                seen[name] = true
                faults[#faults + 1] = {
                    name = name, line = lineOf(src, pos),
                    why = string.format("called at line %d, but its local is only "
                        .. "declared at line %d -- out of scope, so it is nil there",
                        lineOf(src, pos), lineOf(src, localAt[name])),
                }
            end
        end
    end
    table.sort(faults, function(a, b)
        if a.line ~= b.line then return a.line < b.line end
        return a.name < b.name
    end)
    return faults
end

local bad = 0
for _, path in ipairs({ ... }) do
    local faults = scan(path)
    if #faults > 0 then
        print(path .. ":")
        for _, fault in ipairs(faults) do
            print(string.format("    %s  -- %s", fault.name, fault.why))
        end
        bad = bad + #faults
    end
end
if bad == 0 then print("no undefined calls") end
os.exit(bad == 0 and 0 or 1)

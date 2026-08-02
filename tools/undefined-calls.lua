-- Finds calls to names that are never defined in the same file.
--
-- luac -p only checks syntax: Lua resolves a bare name at RUN time, so deleting a
-- function while leaving its callers behind compiles perfectly and then dies with
-- "attempt to call a nil value" the first time that branch is reached. That is
-- exactly how three helpers went missing from setup.lua and every check passed.
--
-- Crude on purpose: it looks for `name(` where `name` is never introduced as a
-- local, a function, a parameter or a loop variable in that file, and is not a
-- known global. False positives are fine -- each is one line to eyeball.

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

local function scan(path)
    local f = assert(io.open(path, "r"))
    local src = f:read("a")
    f:close()

    -- Strip strings and comments so their contents cannot look like code.
    -- Strings go FIRST: several of them contain "--" and stripping comments first
    -- would eat the closing quote, spilling the rest of the line back into "code".
    src = src:gsub("%-%-%[%[.-%]%]", " ")
    src = src:gsub("%[%[.-%]%]", "[[]]")
    src = src:gsub('"[^"\n]*"', '""')
    src = src:gsub("'[^'\n]*'", "''")
    src = src:gsub("%-%-[^\n]*", " ")

    local defined = {}
    -- local x, y = ... / local function f / function M.f / for x, y in / parameters
    for names in src:gmatch("local%s+([%w_%s,]+)") do
        for n in names:gmatch("[%a_][%w_]*") do
            if n ~= "function" then defined[n] = true end
        end
    end
    for n in src:gmatch("function%s+([%a_][%w_]*)") do defined[n] = true end
    for n in src:gmatch("function%s+[%a_][%w_%.:]*%s*%(([^%)]*)%)") do
        for a in n:gmatch("[%a_][%w_]*") do defined[a] = true end
    end
    for names in src:gmatch("for%s+([%w_%s,]+)%s*[=i]") do
        for n in names:gmatch("[%a_][%w_]*") do defined[n] = true end
    end

    -- Only BARE calls: a leading "." or ":" makes it a field or method, which is
    -- resolved on some table and cannot be checked this way.
    local missing, seen = {}, {}
    for prefix, name in src:gmatch("([^%w_%.:])([%a_][%w_]*)%s*%(") do
        local _ = prefix
        if not defined[name] and not KNOWN[name] and not KEYWORD[name] and not seen[name] then
            seen[name] = true
            missing[#missing + 1] = name
        end
    end
    table.sort(missing)
    return missing
end

local bad = 0
for _, path in ipairs({ ... }) do
    local missing = scan(path)
    if #missing > 0 then
        print(path .. ":")
        for _, n in ipairs(missing) do print("    " .. n .. "  -- called, never defined here") end
        bad = bad + #missing
    end
end
if bad == 0 then print("no undefined calls") end
os.exit(bad == 0 and 0 or 1)

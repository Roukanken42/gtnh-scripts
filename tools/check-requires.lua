-- Checks that every require() in a program folder resolves to a file that exists.
--
-- Lua only resolves a require when the line runs, so a module that has been moved
-- or renamed fails on the machine, at whatever moment that branch is first
-- reached -- and `luac -p` is perfectly happy in the meantime. Rearranging a
-- folder is exactly when that bites.
--
-- Usage, from the repo root:
--     lua tools/check-requires.lua mining
--
-- Paths are resolved the way OpenComputers does it for a program run from its own
-- folder: require("lib.hw.db") means lib/hw/db.lua relative to that folder. Names
-- the OC standard library provides are known and skipped.

local STDLIB = {}
for _, n in ipairs({
    "component", "computer", "event", "filesystem", "internet", "keyboard", "note",
    "process", "rc", "serialization", "shell", "sides", "colors", "term", "text",
    "thread", "transforms", "unicode", "uuid", "bit32", "os", "io", "string",
    "table", "math", "coroutine", "debug", "package",
}) do STDLIB[n] = true end

local root = ... or "."

-- Every .lua under `root`, as a set of module names ("lib.hw.db") and paths.
local function listFiles(dir, prefix, out)
    -- io.popen is not available everywhere; use a directory walk via `ls` when it
    -- is, and fall back to probing the names actually required.
    local p = io.popen and io.popen('cmd /c dir /b /s "' .. dir .. '\\*.lua" 2>nul')
    if p then
        for line in p:lines() do
            local rel = line:gsub("\\", "/")
            local at = rel:lower():find(dir:gsub("\\", "/"):lower(), 1, true)
            if at then rel = rel:sub(at + #dir) end
            rel = rel:gsub("^/", "")
            out[rel] = true
        end
        p:close()
    end
    return out
end

local files = listFiles(root, "", {})

local function exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local bad, checked = 0, 0
for rel in pairs(files) do
    local path = root .. "/" .. rel
    local f = io.open(path, "r")
    if f then
        local src = f:read("a")
        f:close()
        -- Ignore requires that are commented out.
        src = src:gsub("%-%-[^\n]*", " ")
        for name in src:gmatch('require%s*%(?%s*["\']([%w_%.]+)["\']') do
            checked = checked + 1
            if not STDLIB[name] then
                local target = root .. "/" .. name:gsub("%.", "/") .. ".lua"
                if not exists(target) then
                    print(string.format("%s: require(\"%s\") -> %s does not exist",
                        rel, name, target))
                    bad = bad + 1
                end
            end
        end
    end
end

if bad == 0 then
    print(string.format("all %d require(s) resolve under %s/", checked, root))
end
os.exit(bad == 0 and 0 or 1)

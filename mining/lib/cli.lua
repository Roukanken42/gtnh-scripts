-- Shared plumbing for the mining CLI scripts: argument parsing, --help, and
-- output that keeps a run readable.
--
-- Every script here grew its own copy of the same three things -- a usage block
-- printed from two places that drifted apart, a --verbose flag one of them had,
-- and a pile of print() calls. This is that, once.
--
-- A script declares what it is and hands over its arguments:
--
--     local cli = require("lib.cli")
--     local ctx = cli.start({
--         name = "plasma",
--         summary = "Drive each module's plasma feed.",
--         usage = {
--             { "plasma",              "what each hatch holds, against its target" },
--             { "plasma keep [name]",  "keep every hatch topped up until stopped" },
--         },
--         notes = { "Switching is not instant: a hatch holds one fluid ..." },
--     }, ...)
--     if not ctx then return end          -- --help was handled
--
-- ctx.args are the arguments with the flags removed, so positional handling stays
-- simple, and ctx.flags carries what was set.

local cli = {}

-- Flags every script understands, so --help and --verbose mean the same thing
-- everywhere and no script has to remember to document them.
local COMMON = {
    ["--help"] = "help", ["-h"] = "help", ["-?"] = "help",
    ["--verbose"] = "verbose", ["-v"] = "verbose",
}

local term = nil
do local ok, t = pcall(require, "term"); term = ok and t or nil end

local function fmt(f, ...)
    if select("#", ...) > 0 then return string.format(f, ...) end
    return tostring(f)
end

-- ---- output -----------------------------------------------------------------

-- A step line rewrites itself in place, so "3/9 done" is one line counting up
-- rather than nine scrolling past. `stepping` tracks whether one is still open,
-- because anything printed over it would land mid-line.
local stepping = false

function cli.say(f, ...)
    if stepping then io.write("\n"); stepping = false end
    print(fmt(f, ...))
end

-- Rewrites the current line. With --verbose, or with no terminal to rewrite,
-- each update is simply printed -- the detail lines in between would scroll a
-- self-rewriting line away anyway.
function cli.step(ctx, f, ...)
    local line = fmt(f, ...)
    if (ctx and ctx.flags.verbose) or not term then cli.say(line); return end
    local ok = pcall(function()
        local _, y = term.getCursor()
        term.setCursor(1, y)
        term.clearLine()
        io.write(line)
    end)
    if ok then stepping = true else print(line) end
end

-- Closes a step line, optionally replacing it with its final form.
function cli.stepEnd(ctx, f, ...)
    if f then cli.step(ctx, f, ...) end
    if stepping then io.write("\n"); stepping = false end
end

-- ---- help --------------------------------------------------------------------

-- Prints the script's own documentation. `spec.usage` is a list of
-- { invocation, what it does } pairs; the column is sized to the longest one, so
-- adding a command cannot leave the table ragged.
function cli.help(spec)
    if spec.summary then print(spec.summary); print("") end

    local width = 0
    for _, u in ipairs(spec.usage or {}) do
        if #u[1] > width then width = #u[1] end
    end
    if #(spec.usage or {}) > 0 then
        print("Usage:")
        for _, u in ipairs(spec.usage) do
            print(string.format("  %-" .. width .. "s  %s", u[1], u[2] or ""))
        end
    end

    if spec.flags and #spec.flags > 0 then
        print("")
        print("Options:")
        local fw = 0
        for _, f in ipairs(spec.flags) do if #f[1] > fw then fw = #f[1] end end
        if fw < 11 then fw = 11 end
        for _, f in ipairs(spec.flags) do
            print(string.format("  %-" .. fw .. "s  %s", f[1], f[2] or ""))
        end
        print(string.format("  %-" .. fw .. "s  %s", "--verbose", "show the detail behind each step"))
        print(string.format("  %-" .. fw .. "s  %s", "--help", "this message"))
    else
        print("")
        print("Options:")
        print("  --verbose    show the detail behind each step")
        print("  --help       this message")
    end

    for _, n in ipairs(spec.notes or {}) do
        print("")
        print(n)
    end
end

-- ---- entry -------------------------------------------------------------------

-- Parses arguments and, when --help was asked for, prints the documentation and
-- returns nil so the caller can simply `return`. Otherwise returns a context:
--   ctx.args    positional arguments, flags removed
--   ctx.flags   { verbose = true, ... } including any spec.flags that were set
--   ctx.spec    what was passed in, so a script can print its own usage on error
function cli.start(spec, ...)
    local ctx = { spec = spec, args = {}, flags = {} }

    -- Script-specific long flags are declared in spec.flags as { "--fast", "..." }.
    local known = {}
    for _, f in ipairs(spec.flags or {}) do
        known[f[1]] = f[1]:gsub("^%-+", "")
    end

    for _, a in ipairs({ ... }) do
        local common = COMMON[a]
        if common then
            ctx.flags[common] = true
        elseif known[a] then
            ctx.flags[known[a]] = true
        elseif a:sub(1, 1) == "-" and a ~= "-" then
            cli.say("Unknown option '%s'.", a)
            cli.help(spec)
            return nil
        else
            ctx.args[#ctx.args + 1] = a
        end
    end

    if ctx.flags.help then
        cli.help(spec)
        return nil
    end
    return ctx
end

-- Prints usage after an error the caller wants to explain itself.
function cli.usage(ctx, msg, ...)
    if msg then cli.say(msg, ...) end
    cli.help(ctx.spec or ctx)
end

return cli

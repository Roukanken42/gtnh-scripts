-- Where the time goes.
--
-- The controller reads every module, every hatch and the local net on each
-- cycle, and does it all in the event loop -- so a slow cycle is a frozen
-- dashboard. This says which part is slow, and it is built around one fact about
-- OpenComputers:
--
--     A component call that is not marked DIRECT does not return until the next
--     tick. It costs 50ms of wall clock however trivial the operation is.
--
-- So the number that matters is usually not "how long did getAllStacks take" but
-- "how many calls did the cycle make". A hundred indirect calls is five seconds
-- no matter how fast the underlying block is. Both are recorded: COUNT is the
-- one to read first, and a total close to count * 0.05 is the signature of an
-- indirect call.
--
-- Two things are measured:
--
--   SPANS   named phases of a cycle, started and stopped by hand. Inclusive, so
--           a span covers everything its phase did.
--   CALLS   every component method, aggregated by "<kind>.<method>". A proxy is
--           wrapped once at the edge (profile.proxy) and everything downstream
--           is counted without knowing it is being watched.
--
-- OFF unless asked for. The overhead is small next to a call that probably costs
-- a whole tick, but it is not nothing -- a closure and a table per call -- and a
-- controller that runs for days should not pay for an instrument nobody is
-- reading. profile.enable() turns it on; until then span() hands back a no-op and
-- proxy() hands back the proxy it was given, so every call site can stay exactly
-- where it is.

local profile = {}

-- Nothing is measured until this is set. main.lua sets it for --profile.
profile.enabled = false

local computer
do local ok, c = pcall(require, "computer"); computer = ok and c or nil end

-- computer.uptime() is real-world seconds. Its resolution is not documented as
-- better than a tick, which is fine here: a call that costs less than a tick is
-- not the one making the dashboard stutter.
local function now()
    if computer then return computer.uptime() end
    return os.clock()
end

profile.now = now

profile.spans = {}      -- name -> { n, total, max, last }
profile.spanOrder = {}  -- names, first-seen order -- a cycle reads in sequence
profile.calls = {}      -- "kind.method" -> { n, total, max, last }
profile.callOrder = {}
profile.cycles = 0
profile.since = now()

-- The span that wraps a whole cycle, if the caller declares one. It is excluded
-- from "which phase is worst", since it is all of them.
profile.root = nil

local function bucket(into, order, name)
    local b = into[name]
    if not b then
        b = { name = name, n = 0, total = 0, max = 0, last = 0 }
        into[name] = b
        order[#order + 1] = name
    end
    return b
end

local function record(into, order, name, dt, count)
    local b = bucket(into, order, name)
    b.n = b.n + (count or 1)
    b.total = b.total + dt
    b.last = dt
    if dt > b.max then b.max = dt end
end

-- Shared, so a disabled span costs one comparison and no allocation.
local function noop() end

-- Starts a named phase. Returns the function that ends it, so a phase cannot be
-- left open by an early return:  local done = profile.span("readFleet") ... done()
function profile.span(name)
    if not profile.enabled then return noop end
    local t0 = now()
    local calls0 = profile.callCount
    return function()
        record(profile.spans, profile.spanOrder, name, now() - t0)
        -- How many component calls this phase made, which is the number that
        -- actually explains its duration.
        local b = profile.spans[name]
        b.calls = (b.calls or 0) + (profile.callCount - calls0)
    end
end

profile.callCount = 0

-- Wraps a component proxy so every method call through it is timed. Returns a
-- stand-in that behaves like the proxy: plain fields (address, type) pass
-- straight through, and a method comes back as a closure, so the `proxy.foo ~=
-- nil` capability checks this codebase makes everywhere still work.
--
-- OC proxy methods are callable TABLES rather than functions, and every caller
-- here invokes them with a dot rather than a colon, so the wrapper simply
-- forwards its arguments.
-- Wrappers already handed out. Some proxies are reachable by more than one route
-- -- every station shares one database handle, and a station's fluid half may be
-- the same transposer as its item half -- so wrapping is made idempotent. Two
-- layers would not just double the overhead, they would double the COUNT, which
-- is the number this whole module exists to report.
profile.wrapped = setmetatable({}, { __mode = "k" })

function profile.proxy(p, kind)
    if not profile.enabled then return p end
    if type(p) ~= "table" then return p end
    if profile.wrapped[p] then return p end
    kind = kind or (p.type) or "component"

    local wrapped = {}
    local stub = setmetatable({}, {
        __index = function(_, key)
            local v = p[key]
            if v == nil then return nil end

            -- Anything not callable is a field: hand it back untouched.
            local callable = type(v) == "function"
            if not callable and type(v) == "table" then
                local mt = getmetatable(v)
                callable = mt ~= nil and mt.__call ~= nil
            end
            if not callable then return v end

            local w = wrapped[key]
            if not w then
                local label = kind .. "." .. key
                w = function(...)
                    local t0 = now()
                    profile.callCount = profile.callCount + 1
                    -- Timed through a pcall so a FAILED call is still recorded.
                    -- Not a rarity worth ignoring: half the calls this program
                    -- makes are probes wrapped in pcall by their caller --
                    -- readPatterns walks 36 pattern slots and most of them
                    -- error -- and a call that errors has still crossed to the
                    -- block and still cost its tick. Leaving those out would
                    -- hide the most expensive phase there is.
                    local r = table.pack(pcall(v, ...))
                    record(profile.calls, profile.callOrder, label, now() - t0)
                    if not r[1] then error(r[2], 0) end
                    return table.unpack(r, 2, r.n)
                end
                wrapped[key] = w
            end
            return w
        end,
        -- Assignment would otherwise land on the empty stand-in and be lost.
        __newindex = function(_, key, value) p[key] = value end,
    })
    profile.wrapped[stub] = true
    return stub
end

-- Starts measuring. Called before anything is wrapped, since a proxy handed out
-- while disabled is the bare proxy and stays that way.
function profile.enable()
    profile.enabled = true
    profile.reset()
end

function profile.reset()
    profile.spans, profile.spanOrder = {}, {}
    profile.calls, profile.callOrder = {}, {}
    profile.cycles, profile.callCount = 0, 0
    profile.since = now()
end

-- The recorded buckets as sorted rows: biggest total first, which is the order
-- the question "what is slow" wants them in.
local function rows(into, order, cycles)
    local out = {}
    for _, name in ipairs(order) do
        local b = into[name]
        out[#out + 1] = {
            name = b.name, n = b.n, total = b.total, max = b.max, last = b.last,
            calls = b.calls,
            avg = b.n > 0 and (b.total / b.n) or 0,
            perCycle = cycles > 0 and (b.n / cycles) or b.n,
            timePerCycle = cycles > 0 and (b.total / cycles) or b.total,
        }
    end
    table.sort(out, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        return a.name < b.name
    end)
    return out
end

-- Everything measured, ready to display: spans and calls, plus the totals that
-- say whether the component calls account for the whole cycle.
function profile.snapshot()
    local cycles = math.max(profile.cycles, 0)
    local spans = rows(profile.spans, profile.spanOrder, cycles)
    local calls = rows(profile.calls, profile.callOrder, cycles)

    local callTotal, callN = 0, 0
    for _, c in ipairs(calls) do callTotal = callTotal + c.total; callN = callN + c.n end

    -- Which phase is actually the cycle. Worth stating outright rather than
    -- leaving to be read off two tables: the answer is nearly always one phase
    -- making most of the calls, and that is the thing to go and fix.
    local cycleTotal, worst = 0, nil
    for _, r in ipairs(spans) do
        if r.name == profile.root then
            cycleTotal = r.total
        elseif (r.calls or 0) > ((worst and worst.calls) or 0) then
            worst = r
        end
    end
    if cycleTotal == 0 then
        for _, r in ipairs(spans) do
            if r.total > cycleTotal then cycleTotal = r.total end
        end
    end

    local note
    if worst and callN > 0 and (worst.calls or 0) > 0 then
        note = string.format(
            "%s makes %d of the %d call(s) per cycle (%.0f%%) -- that phase is the cycle",
            worst.name, math.floor(worst.calls / math.max(cycles, 1) + 0.5),
            math.floor(callN / math.max(cycles, 1) + 0.5),
            100 * worst.calls / callN)
    end

    return {
        spans = spans, calls = calls, cycles = cycles,
        callTotal = callTotal, callCount = callN,
        cycleTotal = cycleTotal, note = note,
        elapsed = now() - profile.since,
        -- What the calls would cost if every one of them were indirect. When the
        -- measured total is near this, the cycle is not slow -- it is just long.
        indirectCost = callN * 0.05,
    }
end

-- A plain-text report, for a file or a headless run. The screen shows the same
-- numbers; this is what survives being scrolled away.
function profile.report(title)
    local s = profile.snapshot()
    local out = {}
    local function put(f, ...) out[#out + 1] = select("#", ...) > 0 and string.format(f, ...) or f end

    put("%s", title or "mining controller profile")
    put("%s", os.date("%Y-%m-%d %H:%M:%S"))
    put("")
    put("%d cycle(s) over %.1fs", s.cycles, s.elapsed)
    put("%d component call(s), %.2fs measured", s.callCount, s.callTotal)
    put("%.2fs is what they would cost if every one were indirect (50ms/call)",
        s.indirectCost)
    if s.cycles > 0 then
        put("per cycle: %.0f call(s), %.2fs", s.callCount / s.cycles, s.callTotal / s.cycles)
    end
    if s.note then put("%s", s.note) end
    put("")
    put("%-34s %7s %9s %9s %9s %8s", "PHASE", "N", "TOTAL", "PER CYCLE", "MAX", "CALLS")
    for _, r in ipairs(s.spans) do
        put("%-34s %7d %8.2fs %8.3fs %8.3fs %8s", r.name, r.n, r.total,
            r.timePerCycle, r.max, r.calls and tostring(r.calls) or "-")
    end
    put("")
    put("%-34s %7s %9s %9s %9s %8s", "COMPONENT CALL", "N", "TOTAL", "PER CYCLE", "MAX", "AVG")
    for _, r in ipairs(s.calls) do
        put("%-34s %7d %8.2fs %8.1f %8.3fs %7.3fs", r.name, r.n, r.total,
            r.perCycle, r.max, r.avg)
    end
    return table.concat(out, "\n")
end

-- Writes the report next to the program. Returns the path, or nil + error.
function profile.save(path, title)
    path = path or "mining-profile.txt"
    local f, err = io.open(path, "w")
    if not f then return nil, tostring(err) end
    f:write(profile.report(title), "\n")
    f:close()
    return path
end

return profile

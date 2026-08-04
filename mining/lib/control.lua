-- Maintenance for a manually-configured mining fleet.
--
-- In MANUAL mode the player owns the interesting decisions -- which drone goes in
-- which module, what distance, what overdrive -- and this keeps the fleet fed
-- while they do: plasma into the hatches, kits and plasma into the local net.
-- Nothing here chooses a configuration; target.lua does that, and the automatic
-- mode that uses it comes later.
--
-- Two ideas shape the module:
--
-- 1. DEMAND IS READ OFF THE HARDWARE. A miner's input bus says which drone it
--    runs, and a drone says which material its kits are made of, so what to stock
--    can be derived from the fleet rather than listed by hand. A config target
--    still wins where one is set -- nil in config.lua means "I have not said",
--    which is exactly the case where the fleet's own answer should be used.
--
-- 2. RESTOCK JOBS ARE CAPPED. Every request holds a crafting CPU on the main net
--    until the fake pattern's inputs are pushed. Uncapped, one cycle could ask
--    for every material at once and take the whole crafting bank with it, so
--    concurrency is limited per kind and the plan's emptiest-first order decides
--    who goes now and who waits for the next cycle.
--
-- Everything except the two component-touching helpers at the bottom is pure, so
-- the caps, the demand arithmetic and the top-up threshold can be exercised
-- off-machine the way target.lua is.

local supply = require("lib.hw.supply")
local drones = require("lib.gtnh.drones")

local control = {}

-- How many restock jobs of each kind may be in flight at once. Plasma is a single
-- job because one plasma feeds the whole fleet in manual mode -- a second would
-- be for a fluid nothing is burning.
control.JOBS = { plasma = 1, kit = 2 }

-- Kits to keep per PARALLEL running that material, when nothing in config says.
-- One kit is one meteor and a parallel mines one meteor an operation, so this is
-- "a few hundred meteors of runway each" -- big enough that a restock is rare,
-- small enough not to hoard Infinity.
control.KITS_PER_PARALLEL = 256

-- Local-net plasma buffer, in hatchfuls per PARALLEL with a plasma feed. The
-- hatches themselves hold one each; this is what refills them.
control.HATCH_REFILLS = 4

-- How long after a craft finishes before its material may be requested again.
-- Only long enough for the network to show goods that have just been pushed into
-- it -- the stock re-read that happens on the same event is what really prevents
-- a second order.
control.SETTLE_GRACE = 5

-- Top a hatch up once it falls below this fraction of its target (config.lua's
-- cfg.supply.hatchRefill overrides). Same laziness as `plasma keep`: big, rare
-- transfers rather than a trickle every cycle.
control.HATCH_REFILL = 0.5

-- ---- pure: what to stock ----------------------------------------------------

-- The drone materials in TIER order -- Steel first, Transcendent Metal last.
-- supply.MATERIALS is sorted longest-name-first (it has to be, to tell "Naquadah
-- Alloy" from "Naquadah"), which is not an order anyone wants to read.
function control.materialsByTier()
    local seen, list = {}, {}
    for tier = drones.MIN_TIER, drones.MAX_TIER do
        local m = drones.get(tier).material
        if m and not seen[m] then seen[m] = true; list[#list + 1] = m end
    end
    return list
end

-- What the local net should hold, given what the fleet is actually running.
--   fleet   list of { material = <kit material or nil>, hasFluid = <bool>,
--                     plasma = <that module's plasma, or nil>,
--                     parallels = <how many it runs; missing counts as 1> }
--   scfg    cfg.supply (target / plasma / hatchLitres / hatchMeteors)
--   ccfg    cfg.control (kitsPerParallel / hatchRefills)
--   plasma  the fleet default, for modules that name none of their own
-- Returns kits (material -> kits), litres (fluid name -> L), and `from`
-- (key -> "fleet" | "config") so the UI can say where a number came from.
--
-- Everything is counted in PARALLELS rather than modules, which is what makes the
-- figures track consumption: both consumables are spent per METEOR, and a module
-- mines one meteor per parallel per operation. So a T2 on 4 parallels burns four
-- times what a module on 1 does, and now asks for four times as much. Counting
-- modules meant one number had to cover both, and it starved the wide ones.
--
-- A module that cannot say how many it runs counts as one parallel: too little
-- stock stalls a module, while too much only sits in the net.
function control.demand(fleet, scfg, ccfg, plasma)
    scfg, ccfg = scfg or {}, ccfg or {}
    local kits, litres, from = {}, {}, {}

    local perMaterial, perPlasma = {}, {}
    for _, m in ipairs(fleet or {}) do
        local par = math.floor(tonumber(m.parallels) or 1)
        if par < 1 then par = 1 end
        if m.material then perMaterial[m.material] = (perMaterial[m.material] or 0) + par end
        -- Counted per plasma, not once for the fleet: a module switched on its own
        -- burns a different fluid, and stocking only the majority's would starve it.
        if m.hasFluid then
            local p = m.plasma or plasma
            if p then
                local e = perPlasma[p.name]
                if not e then e = { plasma = p, n = 0 }; perPlasma[p.name] = e end
                e.n = e.n + par
            end
        end
    end

    -- kitsPerMiner is what this used to be called, and the number means the same
    -- thing read per parallel -- so an old config keeps working and simply stocks
    -- a T2 four times over, which is the point of the change.
    local perParallel = ccfg.kitsPerParallel or ccfg.kitsPerMiner or control.KITS_PER_PARALLEL
    for material, n in pairs(perMaterial) do
        kits[material] = n * perParallel
        from[material] = "fleet"
    end

    local refills = ccfg.hatchRefills or control.HATCH_REFILLS
    for name, e in pairs(perPlasma) do
        litres[name] = e.n * supply.hatchLitres(e.plasma, scfg) * refills
        from[name] = "fleet"
    end

    -- An explicit target wins. nil in config.lua is "I have not said", so it never
    -- reaches this loop and the fleet's own figure stands; a number is a decision
    -- and overrides it -- including a 0, which is how to say "never stock this".
    for material, n in pairs(scfg.target or {}) do
        kits[material] = n; from[material] = "config"
    end
    for name, n in pairs(scfg.plasma or {}) do
        litres[name] = n; from[name] = "config"
    end

    return kits, litres, from
end

-- The plasma a module is MEANT to be on, in order of authority:
--
--   1. a queued change      the switch being carried out right now, which is not
--                          what the hatch holds until it lands
--   2. what it was told     an individual or fleet-wide choice, remembered so a
--                          freshly drained hatch is not mistaken for a module
--                          that has lost its plasma
--   3. what is in its hatch what it is demonstrably running
--
-- And NOTHING after that. In particular NOT the fleet's plasma, which used to be
-- the last resort and turned advising ONE module into a fleet-wide switch: the
-- module filled, it became the only hatch holding anything, so the fleet majority
-- became its plasma -- and every other module, having no opinion of its own, read
-- that majority and was primed with it. A module nobody has configured has no
-- plasma, and the controller may not invent one for it.
function control.plasmaFor(queued, told, inHatch)
    if queued then return queued end
    if told then return told end
    return inHatch
end

-- ---- restock jobs -----------------------------------------------------------

local Jobs = {}
Jobs.__index = Jobs
control.Jobs = Jobs

-- Tracker for in-flight restock requests, with a cap per kind. `limits` is
-- { kit = n, plasma = n }; a kind not listed is unlimited.
function control.newJobs(limits)
    return setmetatable({
        limits = limits or control.JOBS, active = {}, cooling = {},
    }, Jobs)
end

-- Advances every job and drops the ones that have settled. Fake-crafting patterns
-- finish the moment their inputs are pushed, so this is normally one cycle's wait.
-- Returns the finished ones, each carrying .state ("done"/"failed"/"canceled").
--
-- A settled job starts its key SETTLING (see below). The caller is expected to
-- re-read the local net when this returns anything: that reading, not any
-- bookkeeping here, is what stops the same shortfall being ordered twice.
function Jobs:poll(at, grace)
    local finished, running = {}, {}
    for _, j in ipairs(self.active) do
        j.state = supply.jobState(j.job)
        if j.state == "computing" then
            running[#running + 1] = j
        else
            finished[#finished + 1] = j
            self.cooling[j.key] = (at or 0) + (grace or control.SETTLE_GRACE)
        end
    end
    self.active = running
    return finished
end

function Jobs:count(kind)
    local n = 0
    for _, j in ipairs(self.active) do
        if j.kind == kind then n = n + 1 end
    end
    return n
end

-- How many more jobs of `kind` may start. math.huge when uncapped.
function Jobs:room(kind)
    local limit = self.limits and self.limits[kind]
    if not limit then return math.huge end
    return limit - self:count(kind)
end

-- True if something is already being fetched for `key` -- one job per material or
-- plasma at a time, so a slow craft cannot be requested again every cycle.
function Jobs:has(key)
    for _, j in ipairs(self.active) do
        if j.key == key then return true end
    end
    return false
end

-- `extra` carries what the request was FOR -- the level before it, what one craft
-- delivers, how many items AE2 was actually asked for -- so that when the job settles
-- the caller can compare what arrived with what was expected. A craft that reports
-- success and delivers a fraction of the goods is otherwise invisible.
function Jobs:add(kind, key, job, crafts, at, extra)
    local j = { kind = kind, key = key, job = job, crafts = crafts, since = at or 0 }
    if extra then for k, v in pairs(extra) do if j[k] == nil then j[k] = v end end end
    self.active[#self.active + 1] = j
    return j
end

function Jobs:list() return self.active end

-- ---- settling ----------------------------------------------------------------
--
-- A finished craft is not re-requested for a moment afterwards. The controller
-- re-reads the stock as soon as a job settles, which is what actually prevents
-- the double order -- but the goods were pushed a tick or two before that read,
-- and this covers the gap without predicting anything.
--
-- Short on purpose. It is not a substitute for the reading; it only stops the one
-- cycle where the reading could still be behind the push.

-- True while `key` is still settling from a craft that just finished.
function Jobs:isCooling(key, at)
    local until_ = self.cooling[key]
    return until_ ~= nil and (at or 0) < until_
end

-- Requests as much of `work` (from supply.plan, already sorted emptiest-first) as
-- the caps allow. Returns the jobs started, how many were held back, and any
-- errors -- a refused request is reported rather than retried in a tight loop.
function control.issue(itf, work, jobs, at)
    local issued, blocked, errs = {}, 0, {}
    for _, w in ipairs(work or {}) do
        local kind = w.entry.kind
        if jobs:has(w.key) then
            -- already on its way
        elseif jobs:isCooling(w.key, at) then
            -- just delivered; the stock reading may not show it yet
        elseif jobs:room(kind) <= 0 then
            blocked = blocked + 1
        else
            local job, items = supply.request(itf, w.entry, w.crafts)
            if job then
                issued[#issued + 1] = jobs:add(kind, w.key, job, w.crafts, at, {
                    -- Everything needed to check the delivery against the promise.
                    before = w.have, target = w.target, perCraft = w.perCraft,
                    expected = w.perCraft and (w.crafts * w.perCraft) or nil,
                    items = items, capped = w.capped,
                })
            else
                errs[#errs + 1] = w.key .. ": " .. tostring(items)
            end
        end
    end
    return issued, blocked, errs
end

-- ---- hatches ----------------------------------------------------------------

-- Whether a hatch at `level` wants topping up towards `target`, and to what. Kept
-- separate from the transfer so the threshold is testable on its own.
function control.wantsTopUp(level, capacity, target, refill)
    local want = target
    if capacity and capacity > 0 and want > capacity then want = capacity end
    if want <= 0 then return false, 0 end
    return level < want * (refill or control.HATCH_REFILL), want
end

-- Tops up every hatch that has fallen below the refill threshold. ONE transfer
-- per station per cycle: the staging tank holds at most 16,000 L and refills from
-- ME between cycles, so a larger target simply takes a few cycles. Station's own
-- fillHatchTo would sleep until it got there, which is right for `plasma keep`
-- and wrong for a loop that also has a screen to repaint.
--
-- An entry is { station, level, capacity, plasma, switching }:
--   level/capacity  what the CALLER already read this cycle. Reading them again
--                   here was six component calls a cycle, each costing a tick.
--   plasma          the plasma THAT MODULE should be on -- not the fleet's. Every
--                   decision here is per hatch, which is the whole point: the
--                   caller used to skip this entirely unless some fleet-wide
--                   plasma had been detected, so a module whose hatch was empty
--                   was never filled, and a switch onto an empty hatch waited for
--                   a fluid nothing was moving. nil means there is nothing to
--                   fill it with, and it is left alone.
--   switching       the state of a queued plasma change, if there is one. Only
--                   "filling" may be topped up; earlier than that the switch is
--                   still emptying the hatch, and refilling it would fight the
--                   drain.
-- Returns the number of hatches touched and the litres moved.
function control.topUp(entries, scfg, refill)
    local touched, moved = 0, 0
    for _, e in ipairs(entries or {}) do
        local st = e.station
        if st and st:hasFluid() and e.plasma
            and (e.switching == nil or e.switching == "filling") then
            local target = supply.hatchLitres(e.plasma, scfg)
            local wants, want = control.wantsTopUp(e.level or 0, e.capacity, target, refill)
            if wants then
                local n = st:fillHatch(want, e.level) or 0
                if n > 0 then touched, moved = touched + 1, moved + n end
            end
        end
    end
    return touched, moved
end

-- ---- the keyboard ------------------------------------------------------------
--
-- The whole navigation, as one state machine, kept here rather than inside
-- main.lua's event loop because it is the part of the controller a player drives
-- directly -- and a two-step confirm that is wrong in one direction is not
-- noticed until it has drained nine hatches.
--
--   screen   "dashboard" | "detail" | "profile" | "advise"
--            | "fleetMeteors" | "fleetOre" | "wants"
--   module   cursor in the module list; in "detail", which module is open
--   focus    nil | "plasma"          -- dashboard: is the plasma picker open
--   cursor   row in the plasma picker
--   confirm  picker row awaiting a second ENTER
--   scroll   how many rows a long table is scrolled down by. Kept here so it
--            survives repaints, and reset whenever the view changes -- landing on
--            a new table already scrolled halfway is disorienting.
--   field    1..#FIELDS              -- detail: which parameter is selected
--   edit     nil | { field, value }  -- detail: the pending, uncommitted value
--   clipboard nil | { addr, drone, distance, overdrive, plasma }
--            -- a module's settings, copied with C and pasted with V. Holding
--            -- them keeps COPY MODE open so one module can be pasted onto
--            -- several; Q closes it rather than quitting, which is also why a
--            -- stray Q cannot end the program mid-copy.
--
-- Letters are matched on the CHARACTER and navigation on the SCANCODE: a
-- character is what the keyboard layout actually produced, while the arrows and
-- TAB have none. The codes are the ones OpenComputers reports (LWJGL).
--
-- THERE IS NO ESCAPE KEY. Pressing it in OpenComputers closes the screen rather
-- than delivering a key_down, so a program can never see it -- an ESC binding is
-- a dead end with no way out of whatever it was supposed to leave. Q does that
-- job everywhere instead, and means the same thing at every depth: BACK OUT ONE
-- LEVEL. Cancel an edit, close a picker, leave a screen -- and at the top, with
-- nothing open, quit.
control.KEY = {
    tab = 15, enter = 28, numEnter = 156,
    up = 200, down = 208, left = 203, right = 205,
    pageUp = 201, pageDown = 209, delete = 211,
}
control.CH = { space = 32, a = 97, c = 99, f = 102, l = 108, m = 109,
               o = 111, p = 112, q = 113, r = 114, s = 115, v = 118,
               w = 119, x = 120 }

-- The parameters a module can be driven with, in the order they are listed.
-- `list` fields cycle through a fixed set (the caller maps index -> thing);
-- `number` fields step by `step`, or by `page` with left/right.
control.FIELDS = {
    { key = "drone",     label = "Drone",     kind = "list", min = 1, max = 13 },
    { key = "distance",  label = "Distance",  kind = "number", step = 1, page = 10,
      min = 1 },
    -- A quarter was too coarse to tune with: the useful overdrive range is barely
    -- wider than one, so the bigger jump is a tenth and the arrows a twentieth.
    -- Both are whole multiples of the step, which is what clampField snaps to.
    { key = "overdrive", label = "Overdrive", kind = "number", step = 0.05, page = 0.1,
      -- Not 0: mineTime divides by the overdrive, so a preview at 0 is infinite.
      min = 0.05, max = 2 },
    { key = "plasma",    label = "Plasma",    kind = "list", min = 1, max = 5 },
}

-- Furthest any meteor can be found, which is where the distance field stops.
control.MAX_DISTANCE = 0
do
    local meteors = require("lib.gtnh.meteors")
    for _, m in ipairs(meteors.list) do
        if m.distance[2] > control.MAX_DISTANCE then control.MAX_DISTANCE = m.distance[2] end
    end
end

local function fieldByKey(key)
    for _, f in ipairs(control.FIELDS) do
        if f.key == key then return f end
    end
end

-- Clamps and snaps an edited value for its field.
--
-- Snapped to a whole number of STEPS, not to a fixed number of decimals: the
-- overdrive step is 0.05 and rounding that to one decimal would turn 1.05 into
-- 1.1, so half the reachable values would be unreachable. The trailing round then
-- clears the binary dust -- adding 0.05 twenty times does not land on 2 by
-- itself, and a value shown as 1.35 has to be the 1.35 that gets written.
-- Moves a table's scroll offset, clamped against what the caller reports about the
-- table it is showing: `rows` in total, `page` visible at once. Clamping HERE rather
-- than when drawing means the offset can never run past the end and then need a
-- dozen keypresses before anything moves again.
local function scrollBy(st, delta, ctx)
    local rows, page = ctx.rows or 0, ctx.page or 1
    local most = math.max(0, rows - page)
    local at = math.max(0, math.min((st.scroll or 0) + delta, most))
    local moved = at ~= (st.scroll or 0)
    st.scroll = at
    return moved
end

-- Anything that changes which table is on screen starts it at the top.
local function toScreen(st, screen)
    st.screen, st.scroll = screen, 0
end

control.scrollBy = scrollBy

local function clampField(f, v)
    local max = f.max
    if f.key == "distance" then max = control.MAX_DISTANCE end
    if f.min and v < f.min then v = f.min end
    if max and v > max then v = max end
    if f.kind == "number" then
        local step = f.step or 1
        v = math.floor(v / step + 0.5) * step
        v = math.floor(v * 1000 + 0.5) / 1000
    end
    if f.key == "distance" then v = math.floor(v + 0.5) end
    return v
end

-- Applies a keypress to `st`, mutated in place. `ctx` says what there is to
-- navigate: { modules = n, plasmas = n, profiling = <bool>, cur = { drone,
-- distance, overdrive, plasma } } -- `cur` being the open module's live values,
-- which is what an edit starts from. Returns the action for the caller and whether anything changed, so
-- a key that did nothing does not force a repaint.
--
-- Actions: "open" | "close" | "commit" | "apply-plasma" | "auto" | "copy" |
-- "paste" | "advise" | "pause" | "log" | "quit" (plus the profile screen's two).
-- On "commit", st.edit still holds { field, value }; on "apply-plasma",
-- st.confirm still holds the row. The caller reads and clears them, because only
-- the caller knows whether the change can actually be carried out.
function control.key(st, ctx, char, code)
    local KEY, CH = control.KEY, control.CH
    local nMod, nPla = ctx.modules or 0, ctx.plasmas or 0
    local function enter() return code == KEY.enter or code == KEY.numEnter end

    -- ---- detail: editing one parameter ----
    if st.screen == "detail" and st.edit then
        local f = fieldByKey(st.edit.field)
        local delta
        if code == KEY.up then delta = f.kind == "list" and 1 or f.step
        elseif code == KEY.down then delta = f.kind == "list" and -1 or -f.step
        elseif code == KEY.right then delta = f.kind == "list" and 1 or f.page
        elseif code == KEY.left then delta = f.kind == "list" and -1 or -f.page
        end

        if delta then
            if f.kind == "list" then
                -- Wrap: thirteen drone tiers are quicker to reach from either end.
                local n = (f.key == "plasma") and nPla or f.max
                if n > 0 then st.edit.value = (st.edit.value - 1 + delta) % n + 1 end
            else
                st.edit.value = clampField(f, st.edit.value + delta)
            end
            return nil, true
        end
        if enter() then return "commit", true end
        if char == CH.q then st.edit = nil; return nil, true end
        return nil, false
    end

    -- ---- the fleet breakdowns and the want list ----
    -- Read-only tables, so the arrows are free to scroll them. M, O and W switch
    -- between the three without going back to the dashboard first: "what is the
    -- fleet spending its time on", "what comes out of it" and "what was it FOR" are
    -- the same question asked three ways, and the answer is in comparing them.
    -- Pressing the key for the screen you are already on goes back, so each of them
    -- is its own toggle.
    if st.screen == "fleetMeteors" or st.screen == "fleetOre" or st.screen == "wants" then
        if code == KEY.up then return nil, scrollBy(st, -1, ctx) end
        if code == KEY.down then return nil, scrollBy(st, 1, ctx) end
        if code == KEY.pageUp then return nil, scrollBy(st, -(ctx.page or 1), ctx) end
        if code == KEY.pageDown then return nil, scrollBy(st, ctx.page or 1, ctx) end
        local jump = { [CH.m] = "fleetMeteors", [CH.o] = "fleetOre", [CH.w] = "wants" }
        local to = char and jump[char]
        if to then
            toScreen(st, (st.screen == to) and "dashboard" or to)
            return nil, true
        end
        if char == CH.q then toScreen(st, "dashboard"); return nil, true end
        if char == CH.l then return "log", true end
        return nil, false
    end

    -- ---- the profile screen ----
    -- Read-only, so it needs no guarding: Q leaves, S writes a file, R starts the
    -- measurement again.
    if st.screen == "profile" then
        if char == CH.q or char == CH.f then
            toScreen(st, "dashboard")
            return nil, true
        end
        if char == CH.s then return "save-profile", true end
        if char == CH.r then return "reset-profile", true end
        if char == CH.l then return "log", true end
        return nil, false
    end

    -- ---- detail: choosing a parameter ----
    if st.screen == "detail" then
        local n = #control.FIELDS
        if code == KEY.up then st.field = (st.field - 2) % n + 1
        elseif code == KEY.down then st.field = st.field % n + 1
        elseif code == KEY.pageUp then
            return nil, scrollBy(st, -(ctx.page or 1), ctx)
        elseif code == KEY.pageDown then
            return nil, scrollBy(st, ctx.page or 1, ctx)
        elseif code == KEY.tab then
            -- A different table, so back to the top of it.
            st.view = (st.view == "ore") and "meteors" or "ore"
            st.scroll = 0
        elseif enter() then
            local f = control.FIELDS[st.field]
            local cur = (ctx.cur or {})[f.key]
            if cur == nil then return nil, false end
            st.edit = { field = f.key, value = cur }
        elseif char == CH.a then
            return "advise", true
        elseif char == CH.q then
            return "close", true
        elseif char == CH.l then return "log", true
        else return nil, false
        end
        return nil, true
    end

    -- ---- dashboard: confirming a fleet-wide plasma switch ----
    -- Only ENTER commits; anything else that means "no" backs out to the list
    -- rather than out of the picker, so a mistyped key can neither commit nor
    -- lose the selection.
    if st.confirm then
        if enter() then return "apply-plasma", true end
        if char == CH.q then st.confirm = nil; return nil, true end
        return nil, false
    end

    -- ---- dashboard: the plasma picker ----
    if st.focus == "plasma" then
        if nPla > 0 and code == KEY.up then st.cursor = (st.cursor - 2) % nPla + 1
        elseif nPla > 0 and code == KEY.down then st.cursor = st.cursor % nPla + 1
        elseif enter() then
            if nPla <= 0 then return nil, false end
            st.confirm = st.cursor
        elseif char == CH.p or char == CH.q then
            st.focus = nil
        else
            return nil, false
        end
        return nil, true
    end

    -- ---- dashboard ----
    -- The module list needs no key to enter: it is the main table, so the arrows
    -- belong to it and ENTER opens what they landed on.
    if nMod > 0 and code == KEY.up then
        st.module = (st.module - 2) % nMod + 1
        return nil, true
    elseif nMod > 0 and code == KEY.down then
        st.module = st.module % nMod + 1
        return nil, true
    elseif enter() then
        if nMod <= 0 then return nil, false end
        return "open", true
    end

    if char == CH.p then st.focus = "plasma"; return nil, true end

    -- Copy and paste a module's settings. The caller reads the cursor to know
    -- which module, and does the work; all that lives here is the mode.
    if char == CH.c then
        if nMod <= 0 then return nil, false end
        return "copy", true
    end
    if char == CH.v then
        if not st.clipboard or nMod <= 0 then return nil, false end
        return "paste", true
    end

    -- Hand a module back to the controller, or take it off it. Editing anything
    -- already claims a module (that is main.lua's job, not the keyboard's), so this
    -- key exists mainly for the way BACK -- but it toggles, because a module you are
    -- about to fiddle with by hand is one you want the controller off first.
    if char == CH.a then
        if nMod <= 0 then return nil, false end
        return "auto", true
    end

    -- Only when there is something to show: without --profile nothing is
    -- measured, and a screen of zeroes is worse than no screen.
    if char == CH.m then toScreen(st, "fleetMeteors"); return nil, true end
    if char == CH.o then toScreen(st, "fleetOre"); return nil, true end
    if char == CH.w then toScreen(st, "wants"); return nil, true end
    if char == CH.f and ctx.profiling then toScreen(st, "profile"); return nil, true end
    if char == CH.space then return "pause", true end
    if char == CH.l then return "log", true end
    if char == CH.q then
        -- Q closes copy mode before it closes the program: pasting onto several
        -- modules means Q is the key at hand, and quitting by accident mid-copy
        -- would be a poor reward for it.
        if st.clipboard then st.clipboard = nil; return nil, true end
        return "quit", true
    end
    return nil, false
end

-- ---- the advisor ------------------------------------------------------------
--
-- A screen that asks target.lua what this module SHOULD be set to, and applies
-- the answer. It reaches the same searcher the planning code will, so the answers
-- a player gets by hand and the ones an automatic mode would pick come from one
-- place.
--
-- Any of the four parameters can be PINNED, which narrows the search rather than
-- filtering its results: pin Radon and overdrive 1.5 and the recommendations are
-- the best available UNDER that, which is the question actually being asked when
-- somebody says "what if I keep using Radon".
--
--   want     the material being asked for
--   pins     { drone, distance, overdrive, plasma } -- nil means "any"
--   cursor   1..ADVISE_SETTINGS are the settings, past that the recommendations
--   edit     { field, value } while a pin is being dialled
--   picking  { cursor } while a material is being chosen
--   result   whatever the last search returned

-- want, one row per pinnable field, then the unavailable-configurations toggle.
control.ADVISE_SETTINGS = 2 + #control.FIELDS

function control.newAdvise(want)
    -- Configurations the fleet cannot actually supply are HIDDEN to begin with.
    -- A recommendation you cannot run is worse than one fewer recommendation, and
    -- hiding them also stops them filling the result limit and crowding out the
    -- ones you can.
    return { want = want, pins = {}, cursor = 1, edit = nil, picking = nil,
             showAll = false }
end

-- Applies a keypress to the advisor. `ctx.materials` is the list a material is
-- chosen from, `ctx.cur` the module's live values (what a pin starts from), and
-- `ctx.results` how many recommendations are on screen.
-- Returns "advise-changed" when the search has to be re-run, "advise-filter" when
-- only what is shown changed, "advise-apply" when a recommendation was chosen
-- (st.cursor says which), "close" to leave.
function control.adviseKey(st, ctx, char, code)
    local KEY, CH = control.KEY, control.CH
    local function enter() return code == KEY.enter or code == KEY.numEnter end
    local mats = ctx.materials or {}

    -- ---- choosing a material ----
    -- 154 of them, so a letter jumps to the first one starting with it. Scrolling
    -- to Tungsten one row at a time is not a user interface.
    if st.picking then
        local n = #mats
        if n == 0 then st.picking = nil; return nil, true end
        if code == KEY.up then st.picking.cursor = (st.picking.cursor - 2) % n + 1
        elseif code == KEY.down then st.picking.cursor = st.picking.cursor % n + 1
        elseif code == KEY.pageUp then
            st.picking.cursor = math.max(1, st.picking.cursor - 10)
        elseif code == KEY.pageDown then
            st.picking.cursor = math.min(n, st.picking.cursor + 10)
        elseif enter() then
            st.want = mats[st.picking.cursor]
            st.picking = nil
            return "advise-changed", true
        elseif char == CH.q then
            st.picking = nil
        elseif char and ((char >= 97 and char <= 122) or (char >= 65 and char <= 90)) then
            -- Q is spent on backing out, which would leave Quantium and Quartzite
            -- reachable only by scrolling -- so an UPPERCASE letter jumps too, and
            -- shift-Q gets to them. A different character code, so there is no
            -- clash with the lowercase q that cancels.
            local want = string.char(char):lower()
            for i, m in ipairs(mats) do
                if m:sub(1, 1):lower() == want then st.picking.cursor = i; break end
            end
        else
            return nil, false
        end
        return nil, true
    end

    -- ---- dialling a pin ----
    if st.edit then
        local f
        for _, cand in ipairs(control.FIELDS) do
            if cand.key == st.edit.field then f = cand end
        end
        local delta
        if code == KEY.up then delta = f.kind == "list" and 1 or f.step
        elseif code == KEY.down then delta = f.kind == "list" and -1 or -f.step
        elseif code == KEY.right then delta = f.kind == "list" and 1 or f.page
        elseif code == KEY.left then delta = f.kind == "list" and -1 or -f.page
        end
        if delta then
            if f.kind == "list" then
                local n = (f.key == "plasma") and (ctx.plasmas or 5) or f.max
                if n > 0 then st.edit.value = (st.edit.value - 1 + delta) % n + 1 end
            else
                st.edit.value = clampField(f, st.edit.value + delta)
            end
            return nil, true
        end
        if enter() then
            st.pins[st.edit.field] = st.edit.value
            st.edit = nil
            return "advise-changed", true
        end
        if char == CH.q then st.edit = nil; return nil, true end
        return nil, false
    end

    -- ---- the list ----
    local rows = control.ADVISE_SETTINGS + (ctx.results or 0)
    if code == KEY.up then
        st.cursor = (st.cursor - 2) % rows + 1
        return nil, true
    elseif code == KEY.down then
        st.cursor = st.cursor % rows + 1
        return nil, true
    end

    if enter() then
        if st.cursor == 1 then
            -- Open the picker on whatever is already chosen.
            local at = 1
            for i, m in ipairs(mats) do if m == st.want then at = i end end
            st.picking = { cursor = at }
            return nil, true
        elseif st.cursor == control.ADVISE_SETTINGS then
            -- The last setting row: show or hide what cannot be supplied.
            st.showAll = not st.showAll
            return "advise-filter", true
        elseif st.cursor < control.ADVISE_SETTINGS then
            local f = control.FIELDS[st.cursor - 1]
            -- Seeded from the pin if there is one, else from what the module is
            -- actually set to: "best if I keep what I have" is the common ask.
            local from = st.pins[f.key] or (ctx.cur or {})[f.key]
            if from == nil then
                from = (f.kind == "list") and 1 or (f.min or 1)
            end
            st.edit = { field = f.key, value = from }
            return nil, true
        else
            return "advise-apply", true
        end
    end

    -- Releasing a pin back to "any".
    if (char == CH.x or code == KEY.delete)
        and st.cursor > 1 and st.cursor < control.ADVISE_SETTINGS then
        local f = control.FIELDS[st.cursor - 1]
        if st.pins[f.key] == nil then return nil, false end
        st.pins[f.key] = nil
        return "advise-changed", true
    end

    if char == CH.a or char == CH.q then return "close", true end
    if char == CH.l then return "log", true end
    return nil, false
end

-- A fresh navigation state.
function control.newNav()
    return {
        screen = "dashboard", module = 1, focus = nil, cursor = 1,
        confirm = nil, field = 1, edit = nil, view = "meteors", clipboard = nil,
        advise = nil, scroll = 0,
    }
end

-- ---- queued changes ----------------------------------------------------------
--
-- A change to a module cannot simply be written. TecTech accepts a parameter
-- write only while the machine is STOPPED, and a mining operation runs for forty
-- seconds or more -- so halting a module and waiting a couple of seconds, as this
-- used to, quietly failed every single time the module was busy. Which is most of
-- the time.
--
-- So changes are QUEUED and worked at a little each cycle until the module is
-- ready to take them. Nothing blocks the event loop, and the dashboard can say
-- what is waiting on what.
--
-- The queue also fixes a subtler failure. Switching ONE module's plasma drained
-- its hatch and pointed it at the new fluid; the next cycle then saw an empty
-- hatch, concluded the module had no plasma, and re-pointed it at the FLEET's --
-- undoing the switch before it could take. What was missing is an intent that
-- outlives a cycle, which is exactly what a queue is.
--
-- An entry:
--   addr    the module it belongs to
--   field   "drone" | "distance" | "overdrive" | "plasma"
--   value   the target: a drone tier, a distance, an overdrive, a plasma tier
--   state   "waiting" | "stopping" | "loading" | "draining" | "filling"
--           | "done" | "failed"
--   since   uptime when it was queued, which is what the wait is measured from
--   note    what it is waiting for, in words, for the dashboard
--   error   why it gave up

-- How long to keep waiting for a module to finish what it is doing. A mining
-- operation is tens of seconds and a throttled one can be minutes, so this is a
-- stuck-machine backstop rather than an expected wait.
control.STOP_TIMEOUT = 180

local Queue = {}
Queue.__index = Queue
control.Queue = Queue

function control.newQueue()
    return setmetatable({ byAddr = {} }, Queue)
end

-- Queues a change, replacing any pending one for the same module and field:
-- asking for overdrive 1.2 and then 1.3 before either lands should end at 1.3,
-- not visit both. `extra` carries whatever the field needs (a plasma entry and
-- its database slot).
function Queue:want(addr, field, value, at, extra)
    local list = self.byAddr[addr]
    if not list then list = {}; self.byAddr[addr] = list end

    local e = { addr = addr, field = field, value = value,
                state = "waiting", since = at or 0 }
    if extra then for k, v in pairs(extra) do e[k] = v end end

    for i, old in ipairs(list) do
        if old.field == field then
            -- Carry the work already done across the replacement. wasEnabled
            -- above all: it was read BEFORE the module was halted, and re-reading
            -- it now would report "off" and leave the module off for good.
            e.wasEnabled = old.wasEnabled
            list[i] = e
            return e
        end
    end
    list[#list + 1] = e
    return e
end

-- The unsettled changes for a module, in the order they were asked for.
function Queue:pending(addr)
    local out = {}
    for _, e in ipairs(self.byAddr[addr] or {}) do
        if e.state ~= "done" and e.state ~= "failed" then out[#out + 1] = e end
    end
    return out
end

-- Every unsettled change, for the dashboard.
function Queue:all()
    local out = {}
    for _, list in pairs(self.byAddr) do
        for _, e in ipairs(list) do
            if e.state ~= "done" and e.state ~= "failed" then out[#out + 1] = e end
        end
    end
    table.sort(out, function(a, b)
        if a.since ~= b.since then return a.since < b.since end
        return a.field < b.field
    end)
    return out
end

-- What is queued for one module and field, or nil. The controller asks this to
-- know a module's INTENDED plasma, which is not what its hatch holds yet.
function Queue:find(addr, field)
    for _, e in ipairs(self.byAddr[addr] or {}) do
        if e.field == field and e.state ~= "done" and e.state ~= "failed" then
            return e
        end
    end
    return nil
end

-- Removes settled entries and hands them back, so the caller can report them.
function Queue:reap(addr)
    local list = self.byAddr[addr]
    if not list then return {} end
    local done, keep = {}, {}
    for _, e in ipairs(list) do
        if e.state == "done" or e.state == "failed" then done[#done + 1] = e
        else keep[#keep + 1] = e end
    end
    self.byAddr[addr] = (#keep > 0) and keep or nil
    return done
end

-- ---- carrying a change out ---------------------------------------------------

-- Writes one parameter to a module that is ALREADY STOPPED. The stopping is the
-- queue's job; this is only the write.
function control.writeParam(miner, field, value)
    if field == "distance" then return miner:setDistance(value) end
    if field == "overdrive" then return miner:setOverdrive(value) end
    return false, "cannot write '" .. tostring(field) .. "' as a parameter"
end

local function restoreEnabled(miner, entries)
    local wasEnabled
    for _, e in ipairs(entries) do
        if e.wasEnabled ~= nil then wasEnabled = e.wasEnabled end
    end
    -- Where the build cannot report whether work was allowed, the module is
    -- re-enabled: in manual mode a module exists to run, and leaving one silently
    -- off after an edit is the worse of the two mistakes.
    miner:setEnabled(wasEnabled ~= false)
end

-- Advances the parameter changes queued for one module. They share a single stop:
-- if a distance and an overdrive are both waiting, both are written while the
-- module is down rather than stopping it twice.
local function stepParams(entries, row, at, timeout)
    local miner = row.miner

    -- Ask it to stop, once, remembering first whether it was allowed to work.
    local starting = false
    for _, e in ipairs(entries) do
        if e.state == "waiting" then starting = true end
    end
    if starting then
        local wasEnabled
        for _, e in ipairs(entries) do
            if e.wasEnabled ~= nil then wasEnabled = e.wasEnabled end
        end
        if wasEnabled == nil then wasEnabled = miner:isEnabled() end
        miner:setEnabled(false)
        for _, e in ipairs(entries) do
            if e.wasEnabled == nil then e.wasEnabled = wasEnabled end
            if e.state == "waiting" then e.state = "stopping" end
        end
    end

    -- A drone already on its way is polled whatever the machine is doing: it goes
    -- into the input bus, which does not care.
    local loading = false
    for _, e in ipairs(entries) do
        if e.state == "loading" then
            row.station:pollDrone(e.job)
            if e.job.phase == "done" then
                e.state = "done"
            elseif e.job.phase == "error" then
                e.state, e.error = "failed", e.job.err
            else
                loading = true
                e.note = "waiting for the drone to arrive from ME"
            end
        end
    end

    local stopping = {}
    for _, e in ipairs(entries) do
        if e.state == "stopping" then stopping[#stopping + 1] = e end
    end

    if #stopping > 0 then
        if miner:isActive() then
            local oldest = at
            for _, e in ipairs(stopping) do
                if e.since < oldest then oldest = e.since end
            end
            local waited = at - oldest
            for _, e in ipairs(stopping) do
                e.note = string.format("waiting for the module to finish (%ds)",
                    math.floor(waited))
            end
            if waited > timeout then
                for _, e in ipairs(stopping) do
                    e.state = "failed"
                    e.error = string.format("still running after %ds", math.floor(waited))
                end
                restoreEnabled(miner, entries)
            end
            return
        end

        -- Stopped. Write everything waiting on that.
        for _, e in ipairs(stopping) do
            if e.field == "drone" then
                -- Non-blocking: ask ME for it now and poll on later cycles, so a
                -- slow stock does not freeze the dashboard for ten seconds.
                local drone = drones.get(e.value)
                if not row.station then
                    e.state, e.error = "failed", "no station configured"
                elseif not drone then
                    e.state, e.error = "failed", "invalid drone tier " .. tostring(e.value)
                else
                    e.job = row.station:beginDrone(drone, 1)
                    if e.job.phase == "done" then e.state = "done"
                    elseif e.job.phase == "error" then e.state, e.error = "failed", e.job.err
                    else e.state, loading = "loading", true end
                end
            else
                local ok, err = control.writeParam(miner, e.field, e.value)
                if ok then e.state = "done" else e.state, e.error = "failed", tostring(err) end
            end
        end
    end

    -- Only let it run again once nothing is still mid-flight.
    if not loading then
        local busy = false
        for _, e in ipairs(entries) do
            if e.state == "stopping" or e.state == "loading" then busy = true end
        end
        if not busy then restoreEnabled(miner, entries) end
    end
end

-- Advances a queued plasma change. No stop is needed -- it is a station
-- operation -- but a GT hatch holds one fluid, so the old one has to go first and
-- that takes a cycle or two.
local function stepPlasma(e, row, at, timeout)
    local st = row.station
    if not st or not row.hasFluid then
        e.state, e.error = "failed", "no plasma feed configured"
        return
    end
    if not e.slot then
        e.state, e.error = "failed", e.slotError or "no database slot for the drop"
        return
    end

    if e.state == "waiting" then
        -- Clear the staging config FIRST, so the interface tank is free to take
        -- the drained fluid back rather than refusing it as the wrong one.
        st:clearPlasmaSource()
        e.state = "draining"
    end

    if e.state == "draining" then
        local level = row.hatchLevel or 0
        if level > 0 and row.hatchFluid ~= e.plasma.name then
            st:drainHatch()
            e.note = "draining the old plasma"
            if at - e.since > timeout then
                e.state, e.error = "failed", "the hatch would not empty"
            end
            return
        end
        local ok, err = st:setPlasmaSource(e.slot)
        if not ok then e.state, e.error = "failed", tostring(err); return end
        e.state = "filling"
        e.note = "waiting for the hatch to take it"
        return
    end

    if e.state == "filling" then
        if row.hatchFluid == e.plasma.name then e.state = "done"; return end
        e.note = "waiting for the hatch to take it"
        if at - e.since > timeout then
            e.state, e.error = "failed", "the hatch never took it -- is the plasma in stock?"
        end
    end
end

-- Advances everything queued for one module. `row` is the fleet row: its miner,
-- its station and the hatch figures already read this cycle.
-- Returns the entries that settled (removed from the queue) and how many are
-- still pending.
function control.stepModule(queue, row, at, cfg)
    local entries = queue:pending(row.addr)
    if #entries == 0 then return {}, 0 end
    local timeout = (cfg and cfg.stopTimeout) or control.STOP_TIMEOUT

    local params = {}
    for _, e in ipairs(entries) do
        if e.field == "plasma" then stepPlasma(e, row, at, timeout)
        else params[#params + 1] = e end
    end
    if #params > 0 then stepParams(params, row, at, timeout) end

    local settled = queue:reap(row.addr)
    return settled, #queue:pending(row.addr)
end

-- A one-line description of a queued change, for the dashboard.
function control.describe(e, plasmas)
    local what
    if e.field == "drone" then
        local d = drones.get(e.value)
        what = "drone " .. (d and ("MK-" .. d.roman) or tostring(e.value))
    elseif e.field == "plasma" then
        what = (e.plasma and e.plasma.name) or "plasma"
    elseif e.field == "overdrive" then
        what = string.format("overdrive %.2f", e.value)
    else
        what = e.field .. " " .. tostring(e.value)
    end
    return what, e.state
end

-- ---- component edge ---------------------------------------------------------

-- The database slot holding the ae2fc drop for `plasma`, which is the only form
-- setFluidInterfaceConfiguration accepts -- and it exists only on the supply
-- network, so it has to be lifted out of that plasma's own pattern.
-- Returns the slot, or nil + error.
function control.plasmaSlot(catalog, itf, handle, plasma)
    for _, e in ipairs(catalog or {}) do
        if e.kind == "plasma" and e.plasma.tier == plasma.tier then
            return supply.storePlasmaDrop(itf, e, handle)
        end
    end
    return nil, "the supply interface has no pattern for " .. plasma.name
        .. " -- its drop is the only way to name a fluid to a fluid interface"
end

return control

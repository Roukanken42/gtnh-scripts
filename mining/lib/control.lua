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

-- Kits to keep per miner running that material, when nothing in config says.
-- One kit is one meteor, so this is "a few hundred meteors of runway each" --
-- big enough that a restock is rare, small enough not to hoard Infinity.
control.KITS_PER_MINER = 256

-- Local-net plasma buffer, in hatchfuls per miner with a plasma feed. The hatches
-- themselves hold one each; this is what refills them.
control.HATCH_REFILLS = 4

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
--   fleet   list of { material = <kit material or nil>, hasFluid = <bool> }
--   scfg    cfg.supply (target / plasma / hatchLitres / hatchMeteors)
--   ccfg    cfg.control (kitsPerMiner / hatchRefills)
--   plasma  the plasma the fleet is set to, or nil
-- Returns kits (material -> kits), litres (fluid name -> L), and `from`
-- (key -> "fleet" | "config") so the UI can say where a number came from.
function control.demand(fleet, scfg, ccfg, plasma)
    scfg, ccfg = scfg or {}, ccfg or {}
    local kits, litres, from = {}, {}, {}

    local perMaterial, fluidMiners = {}, 0
    for _, m in ipairs(fleet or {}) do
        if m.material then perMaterial[m.material] = (perMaterial[m.material] or 0) + 1 end
        if m.hasFluid then fluidMiners = fluidMiners + 1 end
    end

    local perMiner = ccfg.kitsPerMiner or control.KITS_PER_MINER
    for material, n in pairs(perMaterial) do
        kits[material] = n * perMiner
        from[material] = "fleet"
    end

    if plasma and fluidMiners > 0 then
        local refills = ccfg.hatchRefills or control.HATCH_REFILLS
        litres[plasma.name] = fluidMiners * supply.hatchLitres(plasma, scfg) * refills
        from[plasma.name] = "fleet"
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

-- ---- restock jobs -----------------------------------------------------------

local Jobs = {}
Jobs.__index = Jobs
control.Jobs = Jobs

-- Tracker for in-flight restock requests, with a cap per kind. `limits` is
-- { kit = n, plasma = n }; a kind not listed is unlimited.
function control.newJobs(limits)
    return setmetatable({ limits = limits or control.JOBS, active = {} }, Jobs)
end

-- Advances every job and drops the ones that have settled. Fake-crafting patterns
-- finish the moment their inputs are pushed, so this is normally one cycle's wait.
-- Returns the finished ones, each carrying .state ("done"/"failed"/"canceled").
function Jobs:poll()
    local finished, running = {}, {}
    for _, j in ipairs(self.active) do
        j.state = supply.jobState(j.job)
        if j.state == "computing" then running[#running + 1] = j
        else finished[#finished + 1] = j end
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

function Jobs:add(kind, key, job, crafts, at)
    local j = { kind = kind, key = key, job = job, crafts = crafts, since = at or 0 }
    self.active[#self.active + 1] = j
    return j
end

function Jobs:list() return self.active end

-- Requests as much of `work` (from supply.plan, already sorted emptiest-first) as
-- the caps allow. Returns the jobs started, how many were held back, and any
-- errors -- a refused request is reported rather than retried in a tight loop.
function control.issue(itf, work, jobs, at)
    local issued, blocked, errs = {}, 0, {}
    for _, w in ipairs(work or {}) do
        local kind = w.entry.kind
        if jobs:has(w.key) then
            -- already on its way
        elseif jobs:room(kind) <= 0 then
            blocked = blocked + 1
        else
            local job, err = supply.request(itf, w.entry, w.crafts)
            if job then
                issued[#issued + 1] = jobs:add(kind, w.key, job, w.crafts, at)
            else
                errs[#errs + 1] = w.key .. ": " .. tostring(err)
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

-- Tops up every station that has fallen below the refill threshold. ONE transfer
-- per station per cycle: the staging tank holds at most 16,000 L and refills from
-- ME between cycles, so a larger target simply takes a few cycles. Station's own
-- fillHatchTo would sleep until it got there, which is right for `plasma keep`
-- and wrong for a loop that also has a screen to repaint.
-- Returns the number of hatches touched and the litres moved.
function control.topUp(stations, target, refill)
    local touched, moved = 0, 0
    for _, st in ipairs(stations or {}) do
        if st:hasFluid() then
            local level, capacity = st:hatchTank()
            local wants, want = control.wantsTopUp(level, capacity, target, refill)
            if wants then
                local n = st:fillHatch(want) or 0
                if n > 0 then touched, moved = touched + 1, moved + n end
            end
        end
    end
    return touched, moved
end

-- Points every station at `plasma`, draining any hatch still holding something
-- else -- a GT hatch takes one fluid and will refuse the new one until the old is
-- gone. Configs are cleared before any draining starts, so each interface tank is
-- free by the time a hatch pushes through it.
-- Returns a list of { station, ok, err, drained } and the litres given back.
function control.switchPlasma(stations, plasma, dbSlot)
    local results, returned = {}, 0

    local wrong = {}
    for _, st in ipairs(stations or {}) do
        if st:hasFluid() then
            local label = st:hatchFluid()
            if label and label ~= plasma.name then
                st:clearPlasmaSource()
                wrong[st] = label
            end
        end
    end
    for st, label in pairs(wrong) do
        local n = st:drainHatch() or 0
        returned = returned + n
        results[#results + 1] = { station = st, ok = true, drained = n, was = label }
    end

    for _, st in ipairs(stations or {}) do
        if st:hasFluid() then
            local ok, err = st:setPlasmaSource(dbSlot)
            if not ok then
                results[#results + 1] = { station = st, ok = false, err = err }
            end
        end
    end
    return results, returned
end

-- ---- the keyboard ------------------------------------------------------------
--
-- The whole navigation, as one state machine, kept here rather than inside
-- main.lua's event loop because it is the part of the controller a player drives
-- directly -- and a two-step confirm that is wrong in one direction is not
-- noticed until it has drained nine hatches.
--
--   screen   "dashboard" | "detail" | "profile"
--   module   cursor in the module list; in "detail", which module is open
--   focus    nil | "plasma"          -- dashboard: is the plasma picker open
--   cursor   row in the plasma picker
--   confirm  picker row awaiting a second ENTER
--   field    1..#FIELDS              -- detail: which parameter is selected
--   edit     nil | { field, value }  -- detail: the pending, uncommitted value
--
-- Letters are matched on the CHARACTER and navigation on the SCANCODE: a
-- character is what the keyboard layout actually produced, while arrows, TAB and
-- ESC have none. The codes are the ones OpenComputers reports (LWJGL).
control.KEY = {
    esc = 1, tab = 15, enter = 28, numEnter = 156,
    up = 200, down = 208, left = 203, right = 205,
}
control.CH = { space = 32, f = 102, l = 108, p = 112, q = 113, r = 114, s = 115 }

-- The parameters a module can be driven with, in the order they are listed.
-- `list` fields cycle through a fixed set (the caller maps index -> thing);
-- `number` fields step by `step`, or by `page` with left/right.
control.FIELDS = {
    { key = "drone",     label = "Drone",     kind = "list", min = 1, max = 13 },
    { key = "distance",  label = "Distance",  kind = "number", step = 1, page = 10,
      min = 1 },
    { key = "overdrive", label = "Overdrive", kind = "number", step = 0.1, page = 0.5,
      -- Not 0: mineTime divides by the overdrive, so a preview at 0 is infinite.
      min = 0.1, max = 2 },
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

-- Clamps and rounds an edited value for its field. Overdrive is rounded to one
-- decimal because repeated +0.1 in binary floating point does not land on 1.3.
local function clampField(f, v)
    local max = f.max
    if f.key == "distance" then max = control.MAX_DISTANCE end
    if f.min and v < f.min then v = f.min end
    if max and v > max then v = max end
    if f.kind == "number" then v = math.floor(v * 10 + 0.5) / 10 end
    if f.key == "distance" then v = math.floor(v + 0.5) end
    return v
end

-- Applies a keypress to `st`, mutated in place. `ctx` says what there is to
-- navigate: { modules = n, plasmas = n, cur = { drone, distance, overdrive,
-- plasma } } -- `cur` being the open module's live values, which is what an edit
-- starts from. Returns the action for the caller and whether anything changed, so
-- a key that did nothing does not force a repaint.
--
-- Actions: "open" | "close" | "commit" | "apply-plasma" | "pause" | "log" | "quit".
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
        if code == KEY.esc then st.edit = nil; return nil, true end
        return nil, false
    end

    -- ---- the profile screen ----
    -- Read-only, so it needs no guarding: ESC leaves, S writes a file, R starts
    -- the measurement again.
    if st.screen == "profile" then
        if code == KEY.esc or char == CH.q or char == CH.f then
            st.screen = "dashboard"
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
        elseif code == KEY.tab then
            st.view = (st.view == "ore") and "meteors" or "ore"
        elseif enter() then
            local f = control.FIELDS[st.field]
            local cur = (ctx.cur or {})[f.key]
            if cur == nil then return nil, false end
            st.edit = { field = f.key, value = cur }
        elseif code == KEY.esc or char == CH.q then
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
        if code == KEY.esc or char == CH.q then st.confirm = nil; return nil, true end
        return nil, false
    end

    -- ---- dashboard: the plasma picker ----
    if st.focus == "plasma" then
        if nPla > 0 and code == KEY.up then st.cursor = (st.cursor - 2) % nPla + 1
        elseif nPla > 0 and code == KEY.down then st.cursor = st.cursor % nPla + 1
        elseif enter() then
            if nPla <= 0 then return nil, false end
            st.confirm = st.cursor
        elseif code == KEY.esc or char == CH.p or char == CH.q then
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
    if char == CH.f then st.screen = "profile"; return nil, true end
    if char == CH.space then return "pause", true end
    if char == CH.l then return "log", true end
    if char == CH.q then return "quit", true end
    return nil, false
end

-- A fresh navigation state.
function control.newNav()
    return {
        screen = "dashboard", module = 1, focus = nil, cursor = 1,
        confirm = nil, field = 1, edit = nil, view = "meteors",
    }
end

-- ---- driving one module ------------------------------------------------------

-- Monotonic seconds and a yield, as transport.lua does them: computer.uptime()
-- and os.sleep() on the machine, os.clock() and nothing off it.
local computer
do local ok, c = pcall(require, "computer"); computer = ok and c or nil end

local function now() return computer and computer.uptime() or os.clock() end
local function pause(s) if os.sleep then os.sleep(s) end end

-- Runs `fn` with the module halted and then puts its work-allowed state back.
--
-- TecTech accepts a parameter write only while the machine is STOPPED, and
-- setWorkAllowed is asynchronous -- a module can take up to ~0.5s to actually
-- halt -- so this polls isActive rather than guessing a delay (pump/main.lua
-- learned the same thing). The 2s cap is a stuck-machine backstop, not the
-- expected wait.
--
-- If the build cannot report whether work was allowed, the module is re-enabled:
-- in manual mode a module exists to run, and leaving one silently off after an
-- edit is the worse of the two mistakes. Returns fn's result, plus whether the
-- module actually stopped.
local function withStopped(miner, fn)
    local wasEnabled = miner:isEnabled()
    miner:setEnabled(false)

    local deadline = now() + 2
    while miner:isActive() and now() < deadline do pause(0.1) end
    local stopped = not miner:isActive()

    local ok, err = fn()

    miner:setEnabled(wasEnabled ~= false)
    return ok, err, stopped
end

control.withStopped = withStopped

-- Writes one edited parameter to a module. `field` is a control.FIELDS key;
-- plasma is NOT handled here (it is a station operation, see switchPlasma).
-- Returns true, or false + why.
function control.applyParam(miner, field, value)
    if field == "distance" or field == "overdrive" then
        local ok, err, stopped = withStopped(miner, function()
            if field == "distance" then return miner:setDistance(value) end
            return miner:setOverdrive(value)
        end)
        if not ok then return false, tostring(err) end
        -- A write to a machine that never halted is the one that looks like it
        -- worked and did not, so say so rather than report success.
        if not stopped then
            return false, "the module would not stop, so the write may not have taken"
        end
        return true
    end

    if field == "drone" then
        if not miner.station then return false, "no station configured" end
        local drone = drones.get(value)
        if not drone then return false, "invalid drone tier " .. tostring(value) end
        local ok, err = withStopped(miner, function()
            return miner.station:setDrone(drone, 1)
        end)
        if not ok then return false, tostring(err) end
        return true
    end

    return false, "cannot set '" .. tostring(field) .. "' here"
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

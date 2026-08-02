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

-- ---- the plasma picker's keyboard -------------------------------------------
--
-- A state machine over { focus, cursor, confirm }, kept here rather than inside
-- main.lua's event loop because it is the one part of the controller a player
-- drives directly -- and a two-step confirm that is wrong in one direction is not
-- noticed until it has drained nine hatches.
--
-- Letters are matched on the CHARACTER and navigation on the SCANCODE: a
-- character is what the keyboard layout actually produced, while arrows and ESC
-- have none. The codes are the ones OpenComputers reports (LWJGL).
control.KEY = { esc = 1, enter = 28, up = 200, down = 208, numEnter = 156 }
control.CH = { space = 32, l = 108, p = 112, q = 113 }

-- Applies a keypress to `st` (mutated in place; fields focus / cursor / confirm)
-- given `n` selectable plasmas. Returns the action for the caller to carry out --
-- "apply" | "pause" | "log" | "quit" | nil -- and whether anything changed, so a
-- key that did nothing does not force a repaint.
--
-- On "apply", st.confirm still holds the chosen index: the caller reads it and
-- clears it, because it is the caller that knows whether the switch can start.
function control.key(st, n, char, code)
    local KEY, CH = control.KEY, control.CH
    local function enter() return code == KEY.enter or code == KEY.numEnter end

    -- Confirming. Only ENTER commits; anything else that means "no" backs out to
    -- the list rather than out of the picker, so a mistyped key cannot commit and
    -- cannot lose the selection either.
    if st.confirm then
        if enter() then return "apply", true end
        if code == KEY.esc or char == CH.q then st.confirm = nil; return nil, true end
        return nil, false
    end

    if st.focus == "plasma" then
        if n > 0 and code == KEY.up then
            st.cursor = (st.cursor - 2) % n + 1
        elseif n > 0 and code == KEY.down then
            st.cursor = st.cursor % n + 1
        elseif enter() then
            if n <= 0 then return nil, false end
            st.confirm = st.cursor
        elseif code == KEY.esc or char == CH.p or char == CH.q then
            st.focus = nil
        else
            return nil, false
        end
        return nil, true
    end

    if char == CH.p then st.focus = "plasma"; return nil, true end
    if char == CH.space then return "pause", true end
    if char == CH.l then return "log", true end
    if char == CH.q then return "quit", true end
    return nil, false
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

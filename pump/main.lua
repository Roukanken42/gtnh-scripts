-- Pump regulator: keeps demanded gas stocks topped up by allocating pump
-- THREADS to under-stocked gases in priority order. Each pump has one thread per
-- tier (MK-1: 1, MK-2/3: 4), and every thread can be set to a different gas.
-- Multiple threads may serve the same gas; a thread's estimated output is used
-- to assign just enough threads to cover each gas's deficit.
--
-- Run from this folder:  main
-- See config.lua for demand and the dry-run safety switch.

local ae2 = require("ae2")
local pumps = require("pumps")
local gases = require("gases")
local cfg = require("config")

local function log(msg)
    print("[" .. os.date("%H:%M:%S") .. "] " .. msg)
end

-- name -> gas definition
local gasByName = {}
for _, g in ipairs(gases) do
    gasByName[g.name] = g
end

local pumpList = pumps.discover()
local satisfied = {} -- gas name -> boolean (hysteresis latch)
local lowWater = cfg.lowWater or 0.9
local interval = cfg.sleep or 30

-- Flatten pumps into individual thread "slots" (built once; slot.name carries
-- the current gas assignment across cycles for sticky reallocation).
local slots = {}
for _, p in ipairs(pumpList) do
    for thread = 0, (p.threads or 1) - 1 do
        slots[#slots + 1] = { pump = p, thread = thread, parallels = p.parallels or 0, name = nil }
    end
end

-- Estimated production (mB) of one thread serving `gas` over one cycle.
-- Each parallel produces `gas.amount` mB of fluid per second.
local function estPerCycle(slot, gas)
    return slot.parallels * gas.amount * interval
end

-- Returns the list of gases that need pumping right now, sorted by priority
-- (then by deficit), applying hysteresis to avoid flapping around the target.
local function computeNeedy(stock)
    local needy = {}
    for name, demand in pairs(cfg.demand) do
        local gas = gasByName[name]
        if not gas then
            log("WARN: demand for unknown gas '" .. name .. "' (not in gases.lua)")
        else
            local current = stock[name] or 0
            local target = demand.target
            local need
            if current >= target then
                satisfied[name] = true
                need = false
            elseif satisfied[name] and current >= lowWater * target then
                need = false
            else
                satisfied[name] = false
                need = true
            end

            if need then
                needy[#needy + 1] = {
                    name = name,
                    gas = gas,
                    priority = demand.priority or 0,
                    deficit = target - current,
                    target = target,
                    current = current,
                    threadsAssigned = 0,
                    estProduction = 0,
                }
            end
        end
    end

    table.sort(needy, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        return a.deficit > b.deficit
    end)
    return needy
end

-- Assigns threads to needy gases and returns a map slot -> gas name (nil = idle).
-- Sticky: threads already serving a still-needy gas are kept; only the surplus
-- and previously-idle threads are (re)assigned, biggest thread first.
local function allocate(needy)
    local needyByName = {}
    for _, n in ipairs(needy) do needyByName[n.name] = n end

    -- Partition current assignments into sticky (still needed) vs free.
    local keptByGas, free = {}, {}
    for _, s in ipairs(slots) do
        if s.name and needyByName[s.name] then
            local list = keptByGas[s.name]
            if not list then list = {}; keptByGas[s.name] = list end
            list[#list + 1] = s
        else
            free[#free + 1] = s
        end
    end

    local newName = {}

    -- Phase 1: keep sticky threads up to each gas's deficit; free the surplus.
    for _, n in ipairs(needy) do
        for _, s in ipairs(keptByGas[n.name] or {}) do
            if n.estProduction >= n.deficit then
                free[#free + 1] = s
            else
                newName[s] = n.name
                n.threadsAssigned = n.threadsAssigned + 1
                n.estProduction = n.estProduction + estPerCycle(s, n.gas)
            end
        end
    end

    -- Phase 2: cover remaining deficits from the free pool, biggest thread first
    -- and in priority order. free[i] = false marks a thread as taken.
    table.sort(free, function(a, b) return a.parallels > b.parallels end)
    for _, n in ipairs(needy) do
        local i = 1
        while n.estProduction < n.deficit and i <= #free do
            local s = free[i]
            if s then
                newName[s] = n.name
                n.threadsAssigned = n.threadsAssigned + 1
                n.estProduction = n.estProduction + estPerCycle(s, n.gas)
                free[i] = false
            end
            i = i + 1
        end
    end

    return newName
end

-- Applies the assignment to the hardware: configures assigned threads, idles the
-- rest (parallels 0), and enables pumps with any active thread / disables idle
-- ones. Also updates slot.name for next cycle's stickiness.
local function applyAllocation(newName)
    local active = {}
    for _, s in ipairs(slots) do
        if newName[s] then active[s.pump] = true end
    end

    for _, s in ipairs(slots) do
        local name = newName[s]
        if name then
            local g = gasByName[name]
            local ok, err = s.pump:setThread(s.thread, g.planet, g.gas, s.parallels)
            if not ok then
                log("ERROR " .. s.pump.address .. " thread " .. s.thread .. ": " .. tostring(err))
            end
        else
            s.pump:idleThread(s.thread)
        end
        s.name = name
    end

    for _, p in ipairs(pumpList) do
        p:setEnabled(active[p] == true)
    end
end

local function logAllocation(needy)
    if #needy == 0 then
        log("All demanded gases satisfied; " .. #slots .. " thread(s) idle.")
        return
    end
    local used = 0
    for _, n in ipairs(needy) do
        used = used + n.threadsAssigned
        log(string.format("  %-18s cur=%d/%d prio=%d -> %d thread(s), ~%d mB/cycle",
            n.name, n.current, n.target, n.priority, n.threadsAssigned, n.estProduction))
    end
    log(string.format("  (%d/%d threads assigned)", used, #slots))
end

if #pumpList == 0 then
    log("No pumps discovered. Are the pump Adapters connected? (try `probe gt_machine`)")
end
log(string.format("Pump regulator started -- %d pump(s), %d thread(s), %ds cycle%s:",
    #pumpList, #slots, interval, cfg.dryRun and " [DRY RUN -- no pumps will be touched]" or ""))
for _, p in ipairs(pumpList) do
    log(string.format("  %s  %s (%d thread(s), %d parallels)",
        p.address, p.tierName or "?", p.threads or 0, p.parallels or 0))
end

while true do
    local stock, err = ae2.getStock(gases)
    if not stock then
        log("AE2 error: " .. tostring(err))
    else
        local needy = computeNeedy(stock)
        local newName = allocate(needy)
        if not cfg.dryRun then
            applyAllocation(newName)
        end
        logAllocation(needy)
    end
    os.sleep(interval)
end

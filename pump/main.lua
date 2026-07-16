-- Pump regulator: keeps demanded gas stocks topped up by allocating pump
-- THREADS to under-stocked gases. Each pump has one thread per tier level
-- (MK-1: 1, MK-2/3: 4), and every thread can be set to a different gas. Gases are
-- ranked by a score blending priority with how empty the tank is (see
-- computeNeedy), then threads are handed out breadth-first by score so the top
-- gases are served first when threads are scarce.
--
-- Run from this folder:  main
-- See config.lua for demand and the dry-run safety switch.

local ae2 = require("ae2")
local pumps = require("pumps")
local gases = require("gases")
local cfg = require("config")
local ui = require("ui")

-- Recent log lines. Shown in the UI's log panel; also printed to the console
-- when the UI is not active.
local messages = {}
local MAX_MESSAGES = 50

local function log(msg)
    local line = "[" .. os.date("%H:%M:%S") .. "] " .. msg
    messages[#messages + 1] = line
    if #messages > MAX_MESSAGES then table.remove(messages, 1) end
    if not ui.active then print(line) end
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
local criticalWeight = cfg.criticalWeight or 4

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

-- Returns the list of gases that need pumping right now, sorted by score,
-- applying hysteresis to avoid flapping around the target. The score blends
-- configured priority with criticality (how empty the tank is):
--   score = priority * (1 + (criticalWeight - 1) * missingFraction^2)
-- so a full tank scores priority*1 and an empty one priority*criticalWeight;
-- the square keeps the boost small until a tank is genuinely low.
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
                local priority = demand.priority or 0
                local cw = demand.criticalWeight or criticalWeight
                local missingFraction = (target - current) / target
                needy[#needy + 1] = {
                    name = name,
                    gas = gas,
                    priority = priority,
                    deficit = target - current,
                    target = target,
                    current = current,
                    missingFraction = missingFraction,
                    score = priority * (1 + (cw - 1) * missingFraction * missingFraction),
                    threadsAssigned = 0,
                    estProduction = 0,
                }
            end
        end
    end

    table.sort(needy, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.missingFraction ~= b.missingFraction then return a.missingFraction > b.missingFraction end
        return a.priority > b.priority
    end)
    return needy
end

-- Assigns threads to needy gases and returns a map slot -> gas name (nil = idle).
-- Threads are scarce relative to demand, so allocation is breadth-first by score:
-- every served gas gets one thread before any gets a second. When threads are
-- plentiful, the surplus is shared among the served gases in proportion to score.
-- Sticky: a thread already serving a gas is reused for it to avoid reconfiguring.
local function allocate(needy)
    -- Single pool of all threads, biggest (most parallels) first.
    local free = {}
    for _, s in ipairs(slots) do free[#free + 1] = s end
    table.sort(free, function(a, b) return a.parallels > b.parallels end)

    local newName = {}

    -- Take a thread for gas `name`: reuse one already on it (no reconfigure) if
    -- available, else the biggest still-free thread. free[i]=false marks taken.
    local function takeThreadFor(name)
        local pick
        for i = 1, #free do
            if free[i] and free[i].name == name then pick = i; break end
        end
        if not pick then
            for i = 1, #free do
                if free[i] then pick = i; break end
            end
        end
        if not pick then return nil end
        local s = free[pick]
        free[pick] = false
        return s
    end

    local function assign(n)
        local s = takeThreadFor(n.name)
        if not s then return false end
        newName[s] = n.name
        n.threadsAssigned = n.threadsAssigned + 1
        n.estProduction = n.estProduction + estPerCycle(s, n.gas)
        return true
    end

    -- Breadth: one thread to each needy gas in score order until threads run out.
    -- With few threads and many gases this picks the top-scoring working set.
    local served = {}
    for _, n in ipairs(needy) do
        if not assign(n) then break end
        served[#served + 1] = n
    end

    -- Depth: hand any remaining threads to served gases by highest-averages on
    -- score (score / (threads+1)), skipping gases already covered this cycle.
    while true do
        local best, bestVal
        for _, n in ipairs(served) do
            if n.estProduction < n.deficit then
                local val = n.score / (n.threadsAssigned + 1)
                if not bestVal or val > bestVal then best, bestVal = n, val end
            end
        end
        if not best or not assign(best) then break end
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

-- Human-readable "2x MK-1  1x MK-3" summary of the discovered fleet.
local tierSummary
do
    local counts = {}
    for _, p in ipairs(pumpList) do
        local t = p.tierName or "?"
        counts[t] = (counts[t] or 0) + 1
    end
    local parts = {}
    for tier, c in pairs(counts) do parts[#parts + 1] = c .. "x " .. tier end
    table.sort(parts)
    tierSummary = table.concat(parts, "  ")
end

local function statusFor(g)
    if g.threads > 0 then return "PUMP" end
    if not g.needy then return "OK" end
    if g.fill < 0.25 then return "CRIT" end
    return "WAIT"
end

-- Assembles the read-only snapshot the UI renders. Keeps all display shaping out
-- of the allocation logic above.
local function buildState(stock, needy, newName, cycle)
    -- Per-pump view with each thread's current assignment + parallels in use.
    local pumpView, pumpIndex = {}, {}
    for _, p in ipairs(pumpList) do
        local pv = {
            tierName = p.tierName, address = p.address, parallels = p.parallels,
            threadCount = p.threads or 0, threads = {}, active = 0,
        }
        pumpIndex[p] = pv
        pumpView[#pumpView + 1] = pv
    end
    local parallels = 0
    for _, s in ipairs(slots) do
        local name = newName[s]
        if name then
            local pv = pumpIndex[s.pump]
            pv.threads[s.thread] = name
            pv.active = pv.active + 1
            parallels = parallels + s.parallels
        end
    end

    local needyByName = {}
    for _, n in ipairs(needy) do needyByName[n.name] = n end

    -- Every demanded gas (target > 0), whether needy or satisfied.
    local gasView = {}
    for name, demand in pairs(cfg.demand) do
        if (demand.target or 0) > 0 and gasByName[name] then
            local current = stock[name] or 0
            local target = demand.target
            local n = needyByName[name]
            local g = {
                name = name, current = current, target = target,
                fill = math.min(1, current / target),
                priority = demand.priority or 0,
                score = n and n.score or 0,
                threads = n and n.threadsAssigned or 0,
                needy = n ~= nil,
            }
            g.status = statusFor(g)
            gasView[#gasView + 1] = g
        end
    end
    table.sort(gasView, function(a, b)
        if (a.threads > 0) ~= (b.threads > 0) then return a.threads > 0 end
        if a.needy ~= b.needy then return a.needy end
        if a.score ~= b.score then return a.score > b.score end
        return a.fill < b.fill
    end)

    local threadsUsed = 0
    for _, pv in ipairs(pumpView) do threadsUsed = threadsUsed + pv.active end

    return {
        dryRun = cfg.dryRun, cycle = cycle, updated = os.date("%H:%M:%S"),
        pumps = pumpView, tierSummary = tierSummary, gases = gasView,
        totals = {
            pumps = #pumpList, threadsUsed = threadsUsed, threadsTotal = #slots,
            parallels = parallels, euPerTick = parallels * 2097152,
        },
        messages = messages,
    }
end

local function logAllocation(needy)
    if #needy == 0 then
        log("All demanded gases satisfied; " .. #slots .. " thread(s) idle.")
        return
    end
    -- needy is sorted by score, so served gases are the top entries.
    local used, unserved, topUnserved = 0, 0, nil
    for _, n in ipairs(needy) do
        if n.threadsAssigned > 0 then
            used = used + n.threadsAssigned
            log(string.format("  %-18s %3d%% full  prio=%d score=%.0f -> %d thread(s), ~%d mB/cycle",
                n.name, math.floor((1 - n.missingFraction) * 100 + 0.5),
                n.priority, n.score, n.threadsAssigned, n.estProduction))
        else
            unserved = unserved + 1
            topUnserved = topUnserved or n.name
        end
    end
    log(string.format("  (%d/%d threads assigned; %d gas(es) waiting%s)",
        used, #slots, unserved,
        topUnserved and (", next: " .. topUnserved) or ""))
end

local uiActive = (cfg.ui ~= false) and ui.init()

if #pumpList == 0 then
    log("No pumps discovered. Are the pump Adapters connected? (try `probe gt_machine`)")
end
log(string.format("Pump regulator started -- %d pump(s), %d thread(s), %ds cycle%s",
    #pumpList, #slots, interval, cfg.dryRun and " [DRY RUN]" or ""))
for _, p in ipairs(pumpList) do
    log(string.format("  %s  %s (%d thread(s), %d parallels)",
        p.address, p.tierName or "?", p.threads or 0, p.parallels or 0))
end

local cycle = 0
local function loop()
    while true do
        cycle = cycle + 1
        local stock, err = ae2.getStock(gases)
        local needy, newName = {}, {}
        if not stock then
            log("AE2 error: " .. tostring(err))
            stock = {}
        else
            needy = computeNeedy(stock)
            newName = allocate(needy)
            if not cfg.dryRun then
                applyAllocation(newName)
            end
        end

        if uiActive then
            ui.render(buildState(stock, needy, newName, cycle))
        else
            logAllocation(needy)
        end
        os.sleep(interval)
    end
end

-- Restore the screen on exit (including Ctrl-C, which surfaces as an error).
local ok, err = pcall(loop)
ui.shutdown()
if not ok then error(err, 0) end

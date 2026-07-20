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
local event = require("event")
local computer = require("computer")
local keyboard = require("keyboard")

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
local paused = false -- user-toggled halt: all pumps off, allocation frozen (SPACE/P)
local lowWater = cfg.lowWater or 0.9
local interval = cfg.sleep or 30
-- How often the dashboard repaints (and re-polls AE2 stock for live fill bars),
-- independent of the control cycle above. Floored so a misconfig cannot busy-loop.
local uiRefresh = math.max(cfg.uiRefresh or 1, 0.1)
local criticalWeight = cfg.criticalWeight or 4
-- How many top-scoring needy gases are guaranteed one thread each before threads
-- are concentrated by score. 0 = pure priority (a dominant gas can take every
-- thread up to its deficit); large = spread one thread across as many gases as
-- possible first. (0 is truthy in Lua, so an explicit 0 is honoured.)
local coverageFloor = cfg.coverageFloor or 1

-- Flatten pumps into individual thread "slots" (built once; slot.name carries
-- the current gas assignment across cycles for sticky reallocation).
local slots = {}
for _, p in ipairs(pumpList) do
    for thread = 0, (p.threads or 1) - 1 do
        slots[#slots + 1] = { pump = p, thread = thread, parallels = p.parallels or 0, name = nil }
    end
end

-- Total parallels the whole fleet can run at once (every thread active). Used to
-- turn the summed per-parallel fill time into a rough real-time ETA.
local fleetParallels = 0
for _, s in ipairs(slots) do fleetParallels = fleetParallels + s.parallels end

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
-- Allocation is score-weighted: each thread goes to the gas with the highest
-- score / (threadsAssigned + 1), so high-priority/critical gases accumulate more
-- threads while the diminishing 1/(threads+1) term still lets others in. A
-- coverage floor (cfg.coverageFloor) first guarantees the top-N needy gases one
-- thread each so pure weighting can't starve them; the per-gas deficit cap stops
-- any gas hoarding threads it can't use this cycle. Sticky: a thread already
-- serving a gas is reused for it to avoid reconfiguring.
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

    -- Coverage floor: guarantee the top `coverageFloor` needy gases (needy is
    -- pre-sorted by score) one thread each, so the score-weighting below can't
    -- starve them entirely. Stops early if threads run out.
    for i = 1, math.min(coverageFloor, #needy) do
        if not assign(needy[i]) then break end
    end

    -- Score-weighted: hand every remaining thread to the needy gas with the
    -- highest score / (threadsAssigned + 1) that still needs production this
    -- cycle. Considers all needy gases (including any not covered above), so a
    -- lower-ranked gas can still earn a thread when it out-averages the leaders.
    while true do
        local best, bestVal
        for _, n in ipairs(needy) do
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
    -- etaOne = seconds for a SINGLE parallel to cover the deficit (deficit / mB
    -- per parallel per second). Per-fluid real time is unknowable because pumps
    -- switch between gases, so this normalised "one-parallel" figure is shown
    -- instead; summed across gases it also feeds the overall real-time ETA.
    local gasView = {}
    local etaSumOne = 0 -- total one-parallel seconds to fill all deficits
    for name, demand in pairs(cfg.demand) do
        if (demand.target or 0) > 0 and gasByName[name] then
            local current = stock[name] or 0
            local target = demand.target
            local gas = gasByName[name]
            local deficit = math.max(0, target - current)
            local etaOne = (deficit > 0 and (gas.amount or 0) > 0) and (deficit / gas.amount) or 0
            etaSumOne = etaSumOne + etaOne
            local n = needyByName[name]
            local g = {
                name = name, current = current, target = target,
                fill = math.min(1, current / target),
                priority = demand.priority or 0,
                score = n and n.score or 0,
                threads = n and n.threadsAssigned or 0,
                needy = n ~= nil,
                etaOne = etaOne,
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
        dryRun = cfg.dryRun, paused = paused, cycle = cycle, updated = os.date("%H:%M:%S"),
        pumps = pumpView, tierSummary = tierSummary, gases = gasView,
        totals = {
            pumps = #pumpList, threadsUsed = threadsUsed, threadsTotal = #slots,
            parallels = parallels, euPerTick = parallels * 2097152,
            -- Fill-time ETA: the summed one-parallel seconds, plus a rough
            -- real-time figure assuming the whole fleet pumps demand flat out.
            etaSumOne = etaSumOne,
            etaRealtime = (fleetParallels > 0) and (etaSumOne / fleetParallels) or 0,
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
log("Press SPACE (or P) to pause/resume all pumps.")
for _, p in ipairs(pumpList) do
    log(string.format("  %s  %s (%d thread(s), %d parallels)",
        p.address, p.tierName or "?", p.threads or 0, p.parallels or 0))
end

-- Keys that toggle the manual pause: SPACE or P.
local PAUSE_KEYS = { [keyboard.keys.space] = true, [keyboard.keys.p] = true }

-- Halts every pump right now. Used when the user pauses so the freeze takes
-- effect immediately rather than at the next cycle, and re-asserted each paused
-- cycle so the pumps stay off even if something else re-enables them.
local function haltPumps()
    for _, p in ipairs(pumpList) do p:setEnabled(false) end
end

local cycle = 0        -- control-cycle counter (shown as "cycle #N")
local tick = 0         -- repaint counter, drives the title spinner animation
local lastToggle = -1  -- debounce against key-repeat while a key is held
-- Latest results from the most recent control cycle. The UI refresh repaints
-- these with freshly-polled stock between cycles, so fill levels stay live even
-- though the allocation decision only changes on the (slower) control cadence.
local lastStock, lastNeedy, lastNewName = {}, {}, {}

-- One control cycle: read stock, (re)decide the allocation, and drive the
-- hardware. This mutates the hysteresis latch and touches pumps, so it runs only
-- on the control cadence -- never from a plain UI refresh.
local function runCycle()
    cycle = cycle + 1
    local stock, err = ae2.getStock(gases)
    if not stock then
        log("AE2 error: " .. tostring(err))
        lastNeedy, lastNewName = {}, {}
        stock = {}
    else
        lastNeedy = computeNeedy(stock)
        lastNewName = allocate(lastNeedy)
        if not cfg.dryRun then
            if paused then haltPumps() else applyAllocation(lastNewName) end
        end
    end
    lastStock = stock
    if not uiActive then logAllocation(lastNeedy) end
end

-- Repaint the dashboard from the last cycle's allocation, re-polling AE2 so the
-- fill bars reflect the current stock. Pure display: no allocation, no hardware.
-- A no-op when headless (there is no screen to refresh).
local function refresh()
    if not uiActive then return end
    lastStock = ae2.getStock(gases) or lastStock
    tick = tick + 1
    local state = buildState(lastStock, lastNeedy, lastNewName, cycle)
    state.tick = tick
    ui.render(state)
end

local function loop()
    local nextCycle = computer.uptime()   -- both due immediately on first pass
    local nextRefresh = computer.uptime()
    while true do
        local t = computer.uptime()
        if t >= nextCycle then
            runCycle()
            nextCycle = computer.uptime() + interval
            refresh()                       -- repaint right after a decision
            nextRefresh = computer.uptime() + uiRefresh
        elseif uiActive and t >= nextRefresh then
            refresh()
            nextRefresh = computer.uptime() + uiRefresh
        end

        -- Sleep until the sooner of the two cadences, staying responsive to the
        -- pause key. (When headless there is nothing to refresh, so we wait for
        -- the control cycle alone.)
        local wake = uiActive and math.min(nextCycle, nextRefresh) or nextCycle
        local timeout = wake - computer.uptime()
        if timeout > 0 then
            local _, _, _, code = event.pull(timeout, "key_down")
            if code and PAUSE_KEYS[code] then
                local now = computer.uptime()
                if now - lastToggle >= 0.3 then
                    lastToggle = now
                    paused = not paused
                    if paused then
                        log("PAUSED by user -- all pumps halted. Press SPACE to resume.")
                        if not cfg.dryRun then haltPumps() end
                    else
                        log("RESUMED by user.")
                        nextCycle = computer.uptime()  -- re-decide + apply at once
                    end
                    refresh()  -- reflect the new status immediately
                end
            end
        end
    end
end

-- Restore the screen on exit (including Ctrl-C, which surfaces as an error).
local ok, err = pcall(loop)
ui.shutdown()
if not ok then error(err, 0) end

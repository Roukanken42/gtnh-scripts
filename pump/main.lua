-- Pump regulator: keeps demanded gas stocks topped up by allocating the
-- available pumps to under-stocked gases in priority order, doubling several
-- pumps onto one gas when its deficit warrants a faster refill.
--
-- Run from this folder:  main
-- See config.lua for demand, pump addresses, and the dry-run safety switch.

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

local pumpList = pumps.load(cfg.pumps or {})
local satisfied = {} -- gas name -> boolean (hysteresis latch)

local lowWater = cfg.lowWater or 0.9
local maxPerGas = cfg.maxPumpsPerGas or math.max(1, #pumpList)

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

-- Decides how many pumps each needy gas should get: one pump each in priority
-- order first (breadth), then leftover pumps double up on the highest-priority
-- gases (depth), capped by maxPerGas.
local function desiredCounts(needy, nPumps)
    local want = {}
    for _, n in ipairs(needy) do want[n.name] = 0 end

    local remaining = nPumps
    while remaining > 0 do
        local progress = false
        for _, n in ipairs(needy) do
            if remaining == 0 then break end
            if want[n.name] < maxPerGas then
                want[n.name] = want[n.name] + 1
                remaining = remaining - 1
                progress = true
            end
        end
        if not progress then break end
    end
    return want
end

-- Reconciles physical pumps with the desired allocation, keeping pumps on a gas
-- they are already serving (sticky) to minimize costly reconfigurations.
local function apply(needy, want)
    local free = {}
    local held = {} -- gas name -> number of pumps kept on it

    for _, p in ipairs(pumpList) do
        local name = p.assignedName
        if name and (want[name] or 0) > (held[name] or 0) then
            held[name] = (held[name] or 0) + 1
        else
            free[#free + 1] = p
        end
    end

    for _, n in ipairs(needy) do
        local have = held[n.name] or 0
        local parallels = n.gas.parallels or cfg.parallels
        while have < want[n.name] and #free > 0 do
            local p = table.remove(free)
            local ok, err = p:setConfig(n.gas.planet, n.gas.gas, parallels)
            if ok then
                p.assignedName = n.name
                p:setEnabled(true)
                have = have + 1
            else
                log("ERROR configuring pump " .. p.address .. ": " .. tostring(err))
            end
        end
    end

    for _, p in ipairs(free) do
        p:setEnabled(false)
        p.assignedName = nil
    end
end

local function logAllocation(needy, want)
    if #needy == 0 then
        log("All demanded gases satisfied; " .. #pumpList .. " pump(s) idle.")
        return
    end
    local used = 0
    for _, n in ipairs(needy) do
        local w = want[n.name] or 0
        used = used + w
        log(string.format("  %-16s cur=%d/%d prio=%d -> %d pump(s)",
            n.name, n.current, n.target, n.priority, w))
    end
    log(string.format("  (%d/%d pumps assigned)", used, #pumpList))
end

if #pumpList == 0 then
    log("No pumps configured. Set cfg.pumps in config.lua (run `probe` for addresses).")
end
log("Pump regulator started with " .. #pumpList .. " pump(s)" ..
    (cfg.dryRun and " [DRY RUN -- no pumps will be touched]" or ""))

while true do
    local stock, err = ae2.getStock(gases)
    if not stock then
        log("AE2 error: " .. tostring(err))
    else
        local needy = computeNeedy(stock)
        local want = desiredCounts(needy, #pumpList)
        if not cfg.dryRun then
            apply(needy, want)
        end
        logAllocation(needy, want)
    end
    os.sleep(cfg.sleep or 10)
end

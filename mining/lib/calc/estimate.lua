-- Yield + cost estimator for a mining module at a given set of parameters.
--
-- This is the piece that ties the three data modules together and answers the
-- practical question: with the module set to <distance, drone, plasma,
-- overdrive, parallels>, what does it PRODUCE and what does it CONSUME, per
-- second of operation?
--
--   meteors.lua   which asteroids are findable, how long they take, what they drop
--   plasmas.lua   the plasma's time discount / size bonus, and its drain per meteor
--   drones.lua    the metal each drone tier is made of -- the mining kit's material
--
-- Costs tracked, all per meteor mined (i.e. per parallel, not per operation):
--   energy       the recipe's EU/t, drone-tier scaled, times the parallels
--   mining kit   1 per meteor: 4 rods + 4 drill tips of the drone's material,
--                which is 4*0.5 + 4*4 = 18 ingots (see estimate.KIT)
--   plasma       plasmas.lua `consumed`, in L (mB)
--   computation  the meteor's computation requirement, times the parallels
--
-- ---- how the averaging works ----------------------------------------------
-- A module does not mine one fixed asteroid: each operation rolls one meteor
-- out of the pool findable at its distance, weighted by recipe weight, and the
-- roll decides how long that operation takes. So the long-run rates are NOT the
-- averages of the per-meteor rates -- slow meteors occupy more of the clock than
-- their roll chance suggests. What holds is
--
--     rate of X = E[X per operation] / E[time per operation]
--
-- so every quantity below is accumulated as a chance-weighted expectation per
-- operation and divided by the expected cycle time once, at the end. The same
-- identity makes the reported EU/t and computation TIME-weighted averages (both
-- are per-tick draws that last exactly as long as their operation).
--
-- ---- parallels -------------------------------------------------------------
-- Parallels are per meteor, not global: the module can only run as many as its
-- own voltage pays for, since the recipe's EU/t is charged per parallel and the
-- machine's available EU/t is V[tier]. An expensive meteor therefore runs at
-- fewer parallels than a cheap one, and one whose EU/t exceeds V[tier] outright
-- cannot be mined at all -- those land in `blocked` and are dropped from the
-- pool (their chance is reported as `blockedChance`, and in game they stall the
-- module rather than rolling something else, so a non-zero value is a warning
-- to drop a drone tier or move up a module). Passing `computation` caps the
-- parallels the same way.
--
-- NOT modelled: an asteroid outpost discounts both the plasma drain and the
-- computation requirement, so a module attached to one is cheaper than this
-- says. Nothing in the data modules describes those discounts yet.

local meteors = require("lib.gtnh.meteors")
local plasmas = require("lib.gtnh.plasmas")
local drones = require("lib.gtnh.drones")

local estimate = {}

estimate.TPS = 20   -- ticks per second

-- Mining module tiers. Mirrors miners.TIERS -- duplicated so this module stays
-- pure data (miners.lua pulls in the OpenComputers component API). `voltage` is
-- GTValues.V[tier], which is what caps the parallels.
estimate.MODULES = {
    [1] = { name = "T1", parallels = 2, voltName = "UV",  voltage = 524288 },
    [2] = { name = "T2", parallels = 4, voltName = "UHV", voltage = 2097152 },
    [3] = { name = "T3", parallels = 8, voltName = "UEV", voltage = 8388608 },
}

-- One mining kit is consumed per meteor mined. It is 4 rods + 4 drill tips of
-- the drone's material; in GT material units a rod is half an ingot and a drill
-- tip is four, so 4*0.5 + 4*4 = 18 ingots per kit.
estimate.KIT = { rods = 4, drillTips = 4, ingots = 18 }

-- The mining-kit cost of one meteor at `droneTier`: the drone's material plus
-- the piece counts from estimate.KIT. nil if the tier is out of range.
function estimate.kitCost(droneTier)
    local d = drones.get(droneTier)
    if not d then return nil end
    return {
        material = d.material,
        rods = estimate.KIT.rods,
        drillTips = estimate.KIT.drillTips,
        ingots = estimate.KIT.ingots,
    }
end

-- ---- parameters ------------------------------------------------------------

-- Validates and normalizes a parameter table (see estimate.run). Returns the
-- resolved params, or nil + error.
local function resolve(p)
    p = p or {}

    local distance = tonumber(p.distance)
    if not distance then return nil, "distance is required" end

    local droneTier = tonumber(p.drone)
    local drone = droneTier and drones.get(droneTier)
    if not drone then return nil, "drone must be a tier 1.." .. drones.MAX_TIER end

    local moduleTier = tonumber(p.module)
    local mod = moduleTier and estimate.MODULES[moduleTier]
    if not mod then return nil, "module must be a tier 1..3" end

    local plasma = p.plasma
    if type(plasma) == "number" then plasma = plasmas.byTier[plasma] end
    if type(plasma) ~= "table" then
        return nil, "plasma must be a tier 1..5 or a plasmas.lua entry"
    end

    local overdrive = tonumber(p.overdrive) or 1
    if overdrive <= 0 or overdrive > 2 then
        return nil, "overdrive must be in (0, 2]"   -- 0 never runs; >2 the module rejects
    end

    -- Default to the module's ceiling; a requested value is clamped to it.
    local parallels = math.floor(tonumber(p.parallels) or mod.parallels)
    if parallels < 1 then return nil, "parallels must be >= 1" end
    parallels = math.min(parallels, mod.parallels)

    return {
        distance = distance,
        drone = droneTier,
        droneName = drone.name,
        module = moduleTier,
        moduleName = mod.name,
        voltName = mod.voltName,
        voltage = tonumber(p.voltage) or mod.voltage,
        parallels = parallels,
        overdrive = overdrive,
        plasma = plasma,
        computation = tonumber(p.computation),   -- optional parallels cap
    }
end

-- How many parallels meteor `m` actually gets, and what limited it. Starts from
-- the requested count and shaves it down by the module's voltage (the recipe
-- EU/t is charged per parallel) and, when known, the computation on tap.
local function parallelsFor(p, m, eut)
    local par, limit = p.parallels, nil
    local byVoltage = math.floor(p.voltage / eut)
    if byVoltage < par then par, limit = byVoltage, "voltage" end
    if p.computation then
        local byComp = math.floor(p.computation / m.computation)
        if byComp < par then par, limit = byComp, "computation" end
    end
    return par, limit
end

-- ---- the estimate ----------------------------------------------------------

-- Estimates a module's steady-state throughput and running cost.
--   params = {
--     distance    = <n>,        -- the module's distance setting
--     drone       = 1..13,      -- drone tier loaded in the bus
--     module      = 1..3,       -- module tier (T1/T2/T3); sets parallels + voltage
--     plasma      = 1..5,       -- plasma tier, or a plasmas.lua entry
--     overdrive   = 0..2,       -- default 1; trades size bonus for speed
--     parallels   = <n>,        -- default: the module tier's maximum
--     computation = <n>,        -- optional: computation on tap, caps parallels
--     voltage     = <n>,        -- optional override of the module's V[tier]
--   }
-- Returns nil + error on bad parameters, otherwise:
--   { params,                   -- the resolved parameters
--     pool = {                  -- runnable meteors, most likely first
--       { meteor, name, weight, chance, parallels, limit, time, stacks,
--         eut, computation, plasma, kits, yield }, ... },
--     blocked,                  -- same shape, but parallels = 0 and `needs` =
--                               -- { eut, computation } for one parallel; `limit`
--                               -- says which of the two fell short
--     blockedChance,            -- their share of the raw roll (0 is what you want)
--     cycle,                    -- average seconds per mining operation
--     operationsPerSecond, meteorsPerSecond,
--     stacksPerSecond, itemsPerSecond,
--     yield = {                 -- per output, aggregated over the whole pool
--       { oredict, mat, item, stacksPerSecond, itemsPerSecond, share }, ... },
--     cost = {
--       eut, euPerSecond, peakEut,          -- average / peak power draw
--       computation, peakComputation,       -- sustained / peak computation
--       plasma = { tier, name, material, perMeteor, perSecond },   -- L (mB)
--       kit = { material, perSecond, rodsPerSecond, drillTipsPerSecond,
--               ingotsPerSecond } } }
-- Rates are per second of RUNNING time -- they assume the module never idles for
-- want of drones, plasma, kits or power.
function estimate.run(params)
    local p, err = resolve(params)
    if not p then return nil, err end

    local raw, rawWeight = meteors.available(p.distance, p.drone, p.module)

    -- Per-meteor figures for one operation, split into what the module can run
    -- and what it cannot power.
    local pool, blocked, poolWeight, blockedWeight = {}, {}, 0, 0
    for _, h in ipairs(raw) do
        local m = h.meteor
        local est = meteors.estimate(m, p.drone, p.plasma, p.overdrive)
        local par, limit = parallelsFor(p, m, est.eut)
        local e = {
            meteor = m,
            name = m.name,
            weight = m.weight,
            parallels = par,
            limit = limit,                              -- what capped it, or nil
            time = est.time / estimate.TPS,             -- seconds per operation
            stacks = est.stacks * par,                  -- average, whole operation
            eut = est.eut * par,
            computation = m.computation * par,
            plasma = p.plasma.consumed * par,
            kits = par,                                 -- one kit per meteor
            yield = est.yield,                          -- per meteor; x parallels
        }
        if par >= 1 then
            pool[#pool + 1] = e
            poolWeight = poolWeight + m.weight
        else
            -- Every per-operation figure is zero at zero parallels, so record
            -- what a SINGLE parallel would have needed -- that is the demand
            -- that could not be met.
            e.needs = { eut = est.eut, computation = m.computation }
            blocked[#blocked + 1] = e
            blockedWeight = blockedWeight + m.weight
        end
    end

    -- Expectations over one operation (chance-weighted across the runnable pool).
    local expTime, expStacks, expKits, expPlasma = 0, 0, 0, 0
    local expEnergy, expCompTicks = 0, 0
    local peakEut, peakComp = 0, 0
    local acc, order = {}, {}

    for _, e in ipairs(pool) do
        e.chance = e.weight / poolWeight
        local c = e.chance

        expTime = expTime + c * e.time
        expStacks = expStacks + c * e.stacks
        expKits = expKits + c * e.kits
        expPlasma = expPlasma + c * e.plasma
        expEnergy = expEnergy + c * e.eut * e.time * estimate.TPS
        expCompTicks = expCompTicks + c * e.computation * e.time

        if e.eut > peakEut then peakEut = e.eut end
        if e.computation > peakComp then peakComp = e.computation end

        for _, y in ipairs(e.yield) do
            local a = acc[y.oredict]
            if not a then
                a = { oredict = y.oredict, mat = y.mat, item = y.item, stacks = 0 }
                acc[y.oredict] = a
                order[#order + 1] = a
            end
            a.stacks = a.stacks + c * y.stacks * e.parallels
        end
    end

    table.sort(pool, function(a, b) return a.chance > b.chance end)
    table.sort(blocked, function(a, b) return a.weight > b.weight end)

    -- Turn the per-operation expectations into per-second rates. An empty pool
    -- (nothing findable at this distance) leaves every rate at zero.
    local perSecond = expTime > 0 and (1 / expTime) or 0

    local yield = {}
    for _, a in ipairs(order) do
        yield[#yield + 1] = {
            oredict = a.oredict, mat = a.mat, item = a.item,
            stacksPerSecond = a.stacks * perSecond,
            itemsPerSecond = a.stacks * meteors.STACK * perSecond,
            share = expStacks > 0 and (a.stacks / expStacks) or 0,
        }
    end
    table.sort(yield, function(a, b)
        if a.stacksPerSecond ~= b.stacksPerSecond then
            return a.stacksPerSecond > b.stacksPerSecond
        end
        return a.oredict < b.oredict
    end)

    local kit = estimate.kitCost(p.drone)
    local kitsPerSecond = expKits * perSecond

    return {
        params = p,
        pool = pool,
        blocked = blocked,
        blockedChance = rawWeight > 0 and (blockedWeight / rawWeight) or 0,

        cycle = expTime,
        operationsPerSecond = perSecond,
        meteorsPerSecond = kitsPerSecond,   -- one meteor per parallel per operation
        stacksPerSecond = expStacks * perSecond,
        itemsPerSecond = expStacks * meteors.STACK * perSecond,
        yield = yield,

        cost = {
            -- Time-weighted average draw, and the worst meteor's draw -- size the
            -- power line for the peak, budget the average.
            eut = expTime > 0 and (expEnergy / (expTime * estimate.TPS)) or 0,
            euPerSecond = expEnergy * perSecond,
            peakEut = peakEut,
            computation = expCompTicks * perSecond,
            peakComputation = peakComp,
            plasma = {
                tier = p.plasma.tier,
                name = p.plasma.name,
                material = p.plasma.material,
                perMeteor = p.plasma.consumed,
                perSecond = expPlasma * perSecond,
            },
            kit = {
                material = kit.material,
                perSecond = kitsPerSecond,
                rodsPerSecond = kit.rods * kitsPerSecond,
                drillTipsPerSecond = kit.drillTips * kitsPerSecond,
                ingotsPerSecond = kit.ingots * kitsPerSecond,
            },
        },
    }
end

return estimate

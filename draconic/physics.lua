-- The Draconic Reactor's rules, as pure maths. No components are touched, so
-- this runs in any Lua interpreter and can be checked off-machine.
--
-- Everything here mirrors GTNewHorizons/Draconic-Evolution
-- TileReactorCore.java (runTick, startingTick, setInventorySlotContents) and
-- ContainerReactor.java, with the numbers from GTNH's DraconicEvolution.cfg
-- (see cfg.game in config.lua).

local P = {}

-- Fuel units, per the server config.
--   nugget = awakenedDraconiumFuelValue, ingot = 9 nuggets, block = 9 ingots
--   chaos shard = chaosShardOutputValue * 9^3 (tiny -> small -> large -> full)
function P.constants(game)
    local nugget = game.nuggetFuel
    return {
        nugget = nugget,
        ingot = nugget * 9,
        block = nugget * 81,
        shard = game.tinyChaos * 729,
        maxFuel = game.maxFuel,
        maxTemp = 10000,  -- maxReactTemperature, only a scale; not a limit
    }
end

-- Fuel value of one item, by its label: "Awakened Draconium Block/Ingot/Nugget"
-- (or "Block of Awakened Draconium"). The reactor itself goes by ore dictionary
-- (blockDraconiumAwakened, ...), which OpenComputers does not show; an item
-- that matches here but not there is simply refused by the stabilizer.
function P.fuelValue(label, C)
    local l = tostring(label or ""):lower()
    if not (l:find("awakened", 1, true) and l:find("draconium", 1, true)) then return 0 end
    if l:find("block", 1, true) then return C.block end
    if l:find("ingot", 1, true) then return C.ingot end
    if l:find("nugget", 1, true) then return C.nugget end
    return 0
end

-- tempDrainFactor: 0 below 1000 C, ramps to 1 at 2000 C, 1 up to 8000 C, then
-- grows with the square of the excess. It scales both fuel use and field drain.
function P.tempDrainFactor(T)
    if T > 8000 then return 1 + (T - 8000) ^ 2 * 0.0000025 end
    if T > 2000 then return 1 end
    if T > 1000 then return (T - 1000) / 1000 end
    return 0
end

-- Fuel converted per tick at temperature T and saturation `sat` (0..1).
function P.fuelPerTick(T, sat, game)
    local k = P.tempDrainFactor(T) * 0.001 * game.fuelUsageMultiplier
    if game.linearFuelUsage then return k * (1 - sat) end
    return k * (1 - math.max(sat - 0.1, 0) ^ 0.3)
end

-- The reactor's own "conversion" term, -0.3 .. 1.0 as the chaos share goes
-- 0 .. 100%. It is 0 at a 23.1% chaos share.
function P.conversionTerm(converted, fuel)
    local total = converted + fuel
    if total <= 0 then return 1 end
    return converted / total * 1.3 - 0.3
end

-- Simulates a shutdown that starts now, tick by tick, exactly as runTick does
-- in STOPPING state:
--   * the stabilizers stop taking energy out, so saturation climbs toward 100%;
--   * until saturation reaches 99% the temperature moves as when running;
--   * from 99% on, and ONLY while unconverted fuel remains, it drops by
--     (1 - conversion) C per tick;
--   * at 2001 C or below the reactor goes OFFLINE;
--   * fuel keeps converting the whole time.
-- The containment field is not simulated (it depends on the injector feed).
-- Chaos shards pulled out meanwhile are ignored, which errs on the safe side.
--
-- s: { temp, sat, satMax, converted (fuelConversion), fuel (unconverted) }
-- Returns { finished, ticks, fuelUsed, peak, ranOut, why }.
function P.simulateStop(s, game, maxTicks)
    maxTicks = maxTicks or 72000
    local T, E, Emax = s.temp, math.floor(s.sat), s.satMax
    local res = { finished = false, ticks = 0, fuelUsed = 0, peak = T, ranOut = false }
    if T <= 2001 then res.finished = true return res end
    if not Emax or Emax <= 0 then res.why = "no saturation data" return res end

    local conv = math.floor(s.converted)
    local unit = s.converted - conv
    local fuel = s.fuel
    local fuel0 = fuel
    local mult = 0.001 * game.fuelUsageMultiplier
    local baseMaxRFt = math.floor(Emax / 1000 * game.outputMultiplier * 1.5)

    for tick = 1, maxTicks do
        local sat = E / Emax
        local satI = (1 - sat) * 99
        local tn = T / 10000 * 50
        if tn >= 99.9 then res.ticks, res.why = tick, "temperature runs away" break end
        local denom = conv + fuel - unit
        local c = denom > 0 and ((conv + unit) / denom * 1.3 - 0.3) or 1
        local expo = satI ^ 3 / (100 - satI) + 444.7
        local resist = tn ^ 4 / (100 - tn)
        local rise = (expo - resist * (1 - c) + c * 1000) / 10000

        if T <= 2001 then
            res.finished, res.ticks = true, tick - 1
            break
        end
        if E >= Emax * 0.99 and fuel > 0 then
            T = T - (1 - c)
        else
            T = T + rise * 10
        end
        if T > res.peak then res.peak = T end

        local maxRFt = math.floor(baseMaxRFt * (1 + c * 2))
        E = math.floor(E + (1 - sat) * maxRFt)

        local tdf = P.tempDrainFactor(T)
        local use
        if game.linearFuelUsage then
            use = tdf * (1 - sat) * mult
        else
            use = tdf * (1 - math.max(sat - 0.1, 0) ^ 0.3) * mult
        end
        unit = unit + use
        if unit >= 1 and fuel > 0 then
            local n = math.floor(unit)
            fuel, conv, unit = fuel - n, conv + n, unit - n
        end
        if fuel <= 0 then
            res.ranOut, res.ticks, res.why = true, tick, "fuel runs out before it cools"
            break
        end
        res.ticks = tick
    end
    if not res.finished and not res.why then res.why = "does not cool within " .. math.floor(maxTicks / 20) .. " s" end
    res.fuelUsed = fuel0 - fuel
    return res
end

-- Max containment field and saturation a charge would lock in for `total` fuel
-- (startingTick). Only for display: more fuel at charge time, bigger buffers.
function P.chargeCapacity(total, C)
    local ratio = C.maxFuel / 10368
    return total / ratio * 96.45061728395062 * 100, total / ratio * 96.45061728395062 * 1000
end

return P

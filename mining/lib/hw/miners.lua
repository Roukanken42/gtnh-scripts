-- Miner abstraction layer -- the ONE place that talks to the mining hardware.
--
-- Analogous to pump/pumps.lua: the demand/allocation logic (added in a later
-- part) will only ever call the small interface below, so everything about HOW
-- a mining module is driven lives here. That keeps the TecTech parameter layout
-- in one spot and leaves room for a future remote-transport layer.
--
-- So far: auto-discovery + per-tier stats, the generic machine controls,
-- setDrone (loads the drone the module mines with, via transport.lua), and the
-- parameter controls (distance / max parallels / cycle mode).
-- Unlike the pumps, mining modules have no threads -- just parallels.

local component = require("component")
local transport = require("lib.hw.transport")
local drones = require("lib.gtnh.drones")

-- =====================================================================
-- Mining module identity + per-tier stats.
--
-- Miners are GregTech multiblocks reached through an Adapter, so they show up
-- as gt_machine components (same as the pumps). Each is identified by
--   getName() == "projectmoduleminertN"   (N = the tier)
-- e.g. "projectmoduleminert2" is a T2 module.
--
-- Per tier we know:
--   parallels  = max parallel mining operations the module can run
--   voltage    = operating voltage in EU/t (each step up is one GTNH tier = 4x)
--   voltName   = that voltage tier's name, for display
-- =====================================================================

local MINER_TYPE = "gt_machine"   -- component type the miner's Adapter exposes
local MINER_NAME = "projectmoduleminert"

local TIERS = {
    [1] = { name = "T1", parallels = 2, voltName = "UV",  voltage = 524288 },
    [2] = { name = "T2", parallels = 4, voltName = "UHV", voltage = 2097152 },
    [3] = { name = "T3", parallels = 8, voltName = "UEV", voltage = 8388608 },
}

-- Named parameters (GTNH 2.9+), the same access as the pumps:
--   setParameter(key:string, val)   writes one parameter
--   getParameters():table           returns all of them as key -> value
-- (Computronics DriverParametrized.) A wrong value type or an unknown key makes
-- setParameter throw, which writeParam turns into false + error. Mining modules
-- have no threads (unlike the pumps), just parallels, so these are plain
-- machine-wide settings. The module also has "cycleDistance", "range" and
-- "step", which only matter in cycle mode, so we never touch them.
--
-- 2.9 dropped OVERDRIVE: it is no longer a parameter, and the module runs as if
-- it were 1. Plasma tier alone now sets speed and size bonus.
local PARAM = {
    DISTANCE      = "distance",  -- target distance (integer)
    MAX_PARALLELS = "parallel",  -- max parallels (integer, 0..tier max)
    CYCLE         = "cycle",     -- distance cycle mode (boolean); false = static
}

local function writeParam(proxy, key, value)
    if proxy.setParameter == nil then return false, "setParameter not available" end
    return pcall(proxy.setParameter, key, value)
end

-- All parameters as key -> value, or an empty table if they cannot be read.
local function readParams(proxy)
    if proxy.getParameters == nil then return {} end
    local ok, params = pcall(proxy.getParameters)
    if not ok or type(params) ~= "table" then return {} end
    return params
end

local function readParam(proxy, key)
    return readParams(proxy)[key]
end
-- =====================================================================

local Miner = {}
Miner.__index = Miner

function Miner.new(address, tier, proxy)
    local self = setmetatable({}, Miner)
    self.address = address
    self.proxy = proxy or component.proxy(address)

    -- Per-tier stats (see TIERS), kept for later parallels-aware allocation.
    local stats = TIERS[tier] or {}
    self.tier = tier
    self.tierName = stats.name
    self.parallels = stats.parallels
    self.voltName = stats.voltName
    self.voltage = stats.voltage
    return self
end

-- Generic gt_machine controls -- identical across every TecTech multiblock, so
-- these are safe to provide now, before the mining parameter layout is known.

-- Allows / disallows the machine to work.
function Miner:setEnabled(enabled)
    if self.proxy.setWorkAllowed ~= nil then
        pcall(self.proxy.setWorkAllowed, enabled)
    end
end

-- True if the machine is currently running.
function Miner:isActive()
    if self.proxy.isMachineActive ~= nil then
        local ok, v = pcall(self.proxy.isMachineActive)
        return ok and v == true
    end
    return false
end

-- Whether the machine is ALLOWED to work, which is not the same as isActive():
-- a module waiting on plasma is allowed but not active. Returns nil when the
-- build exposes no getter, so a caller that has to stop the machine and put it
-- back knows the difference between "it was off" and "I cannot tell" -- guessing
-- would silently leave a deliberately-disabled module running, or the reverse.
function Miner:isEnabled()
    for _, name in ipairs({ "isWorkAllowed", "getWorkAllowed", "isAllowedToWork" }) do
        if self.proxy[name] ~= nil then
            local ok, v = pcall(self.proxy[name])
            if ok and type(v) == "boolean" then return v end
        end
    end
    return nil
end

-- Parameters ---------------------------------------------------------------

-- Sets the target mining distance. In cycle mode the module wanders around it,
-- which is why setStatic exists. Returns true, or false + error.
function Miner:setDistance(distance)
    return writeParam(self.proxy, PARAM.DISTANCE, distance)
end

-- Reads back the target distance. nil if unreadable.
function Miner:getDistance()
    return readParam(self.proxy, PARAM.DISTANCE)
end

-- Caps how many parallels the module may run (its ceiling is the tier's
-- parallels: T1=2, T2=4, T3=8). Returns true, or false + error.
function Miner:setMaxParallels(n)
    return writeParam(self.proxy, PARAM.MAX_PARALLELS, n)
end

-- Turns distance cycle mode on or off. On, the module sweeps the distance by
-- itself, which we do NOT want. Returns true, or false + error.
function Miner:setCycle(enabled)
    return writeParam(self.proxy, PARAM.CYCLE, enabled == true)
end

-- Convenience: keep the module in static distance mode so OC owns distance.
function Miner:setStatic()
    return self:setCycle(false)
end

-- Reads back every input parameter we drive, so a run that has to change them can
-- put them back afterwards (setup does). A parameter that cannot be read comes
-- back nil, and restore() then leaves that one alone rather than guessing.
function Miner:snapshot()
    local params = readParams(self.proxy)
    return {
        distance = params[PARAM.DISTANCE],
        maxParallels = params[PARAM.MAX_PARALLELS],
        cycle = params[PARAM.CYCLE],
    }
end

-- Puts back what snapshot() read. Callers stop the machine first, so a change
-- never lands in the middle of an operation.
function Miner:restore(snap)
    if type(snap) ~= "table" then return end
    if snap.distance then writeParam(self.proxy, PARAM.DISTANCE, snap.distance) end
    if snap.maxParallels then writeParam(self.proxy, PARAM.MAX_PARALLELS, snap.maxParallels) end
    if snap.cycle ~= nil then writeParam(self.proxy, PARAM.CYCLE, snap.cycle) end
end

-- Drone loading ------------------------------------------------------------

-- Attaches the item-transport station (transposer + ME interface + input bus)
-- this module uses to receive drones. Built from config.stations and passed in
-- by the controller; without it setDrone has no way to move items.
--   station: a transport.Station handle (see transport.new)
function Miner:setStation(station)
    self.station = station
end

-- Loads the tier-`tier` mining drone (1..13) into this module's input bus,
-- returning any wrong/old drone to the ME network first. Needs a station (see
-- Miner:setStation). `count` defaults to 1. Returns true, or false + error.
function Miner:setDrone(tier, count)
    if not self.station then
        return false, "no transposer station configured for miner " .. self.address
    end
    local drone = drones.get(tier)
    if not drone then
        return false, "invalid drone tier " .. tostring(tier) .. " (expected 1..13)"
    end
    return self.station:setDrone(drone, count)
end

local miners = {}

-- Builds a transport.Station for a miner from its config entry and attaches it.
-- `spec` is a config.stations[...] table (transposer/interface/sides); `shared`
-- carries the cross-station defaults (database address, dryRun, timeouts, log).
-- Returns true, or false + error (the miner is left station-less on failure).
function miners.attachStation(miner, spec, shared)
    shared = shared or {}
    local station, err = transport.new({
        label = spec.label or miner.tierName .. " " .. miner.address:sub(1, 8),
        transposer = spec.transposer,
        interface = spec.interface,
        database = spec.database or shared.database,
        interfaceSide = spec.interfaceSide,
        inputBusSide = spec.inputBusSide,
        interfaceSlot = spec.interfaceSlot or shared.interfaceSlot,
        -- Plasma feed: absent from the spec means this module has no fluid half
        -- yet, which transport.new treats as simply not having one.
        fluidTransposer = spec.fluidTransposer,
        fluidInterface = spec.fluidInterface,
        fluidInterfaceSide = spec.fluidInterfaceSide,
        inputHatchSide = spec.inputHatchSide,
        fluidTank = spec.fluidTank,
        stockTimeout = spec.stockTimeout or shared.stockTimeout,
        dryRun = shared.dryRun,
        log = shared.log,
    })
    if not station then return false, err end
    miner:setStation(station)
    return true
end

-- Loads drones into many miners AT ONCE (concurrently), which is much faster
-- than one-by-one because every module's ME interface stocks in parallel.
-- `requests` is a list of { miner = <Miner>, tier = <1..13>, count = <n>|nil }.
-- Returns a list of { miner, ok, err, note, drone } in the same order. Miners
-- with no station or an invalid tier are reported as errors (not attempted).
function miners.setDrones(requests, pollInterval)
    local results, transportReqs, indexOf = {}, {}, {}
    for i, r in ipairs(requests) do
        local drone = drones.get(r.tier)
        if not r.miner.station then
            results[i] = { miner = r.miner, ok = false, err = "no station configured for " .. r.miner.address }
        elseif not drone then
            results[i] = { miner = r.miner, ok = false, err = "invalid drone tier " .. tostring(r.tier) }
        else
            transportReqs[#transportReqs + 1] = { station = r.miner.station, drone = drone, count = r.count }
            indexOf[#transportReqs] = i
        end
    end

    local tRes = transport.loadDrones(transportReqs, pollInterval)
    for j, res in ipairs(tRes) do
        local i = indexOf[j]
        results[i] = { miner = requests[i].miner, ok = res.ok, err = res.err, note = res.note, drone = res.drone }
    end
    return results
end

-- Autodiscovers mining multiblocks on the network. Every gt_machine whose
-- getName() is "projectmoduleminertN" (N = a known tier) becomes a Miner
-- carrying that tier's stats. Machines that error on getName() or are not
-- miners are skipped. Returns the list of Miner objects.
function miners.discover()
    local list = {}
    for addr in component.list(MINER_TYPE) do
        local proxy = component.proxy(addr)
        local ok, name = pcall(function() return proxy.getName() end)
        if ok and type(name) == "string" then
            local tier = tonumber(name:match("^" .. MINER_NAME .. "(%d+)$"))
            if tier and TIERS[tier] then
                list[#list + 1] = Miner.new(addr, tier, proxy)
            end
        end
    end
    return list
end

miners.Miner = Miner
miners.TYPE = MINER_TYPE
miners.TIERS = TIERS
miners.PARAM = PARAM

return miners

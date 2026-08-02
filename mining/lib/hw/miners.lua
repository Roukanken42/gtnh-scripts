-- Miner abstraction layer -- the ONE place that talks to the mining hardware.
--
-- Analogous to pump/pumps.lua: the demand/allocation logic (added in a later
-- part) will only ever call the small interface below, so everything about HOW
-- a mining module is driven lives here. That keeps the TecTech parameter layout
-- in one spot and leaves room for a future remote-transport layer.
--
-- So far: auto-discovery + per-tier stats, the generic machine controls,
-- setDrone (loads the drone the module mines with, via transport.lua), and the
-- TecTech parameter controls (distance / overdrive / max parallels / mode).
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
local PARAM_SET = "setParameters"
local PARAM_GET = "getParameters"

local TIERS = {
    [1] = { name = "T1", parallels = 2, voltName = "UV",  voltage = 524288 },
    [2] = { name = "T2", parallels = 4, voltName = "UHV", voltage = 2097152 },
    [3] = { name = "T3", parallels = 8, voltName = "UEV", voltage = 8388608 },
}

-- TecTech parameters, addressed by (hatch, id). Same access as the pumps:
-- setParameters(hatch, id, value) writes an input parameter, getParameters(hatch,
-- id) reads it back. The OC API only exposes the INPUT parameters (hatch 0..9,
-- id 0..1), so we can only read what we set -- the module's OUTPUT parameters
-- (e.g. the applied distance, which lags) are NOT reachable. Mining modules have
-- no threads (unlike the pumps), just parallels, so these are plain machine-wide
-- settings.
local PARAM = {
    DISTANCE      = { hatch = 0, id = 0 },  -- target distance            (0:0:I)
    MAX_PARALLELS = { hatch = 0, id = 1 },  -- max parallels              (0:1:I)
    OVERDRIVE     = { hatch = 1, id = 0 },  -- overdrive 0..2             (1:0:I)
    MODE          = { hatch = 2, id = 0 },  -- distance mode; 0 = static  (2:0:I)
}

local function writeParam(proxy, slot, value)
    local setter = proxy[PARAM_SET]
    if setter == nil then return false, PARAM_SET .. " not available" end
    return pcall(setter, slot.hatch, slot.id, value)
end

local function readParam(proxy, slot)
    local getter = proxy[PARAM_GET]
    if getter == nil then return nil end
    local ok, v = pcall(getter, slot.hatch, slot.id)
    if not ok then return nil end
    return v
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

-- TecTech parameters -------------------------------------------------------

-- Sets the target mining distance. The module's applied distance lags this and
-- isn't readable via OC, so we only ever know what we requested. Returns true,
-- or false + error.
function Miner:setDistance(distance)
    return writeParam(self.proxy, PARAM.DISTANCE, distance)
end

-- Reads back the target distance we set (its input parameter) -- not necessarily
-- the live applied value, which the OC API doesn't expose. nil if unreadable.
function Miner:getDistance()
    return readParam(self.proxy, PARAM.DISTANCE)
end

-- Caps how many parallels the module may run (its ceiling is the tier's
-- parallels: T1=2, T2=4, T3=8). Returns true, or false + error.
function Miner:setMaxParallels(n)
    return writeParam(self.proxy, PARAM.MAX_PARALLELS, n)
end

-- Sets the overdrive parameter (0..2; higher = faster but less size bonus, see
-- meteors.lua). Returns true, or false + error.
function Miner:setOverdrive(overdrive)
    return writeParam(self.proxy, PARAM.OVERDRIVE, overdrive)
end

-- Sets the distance mode. 0 = static (OC drives the distance); non-zero lets the
-- module auto-switch distance, which we do NOT want. Returns true, or false+err.
function Miner:setMode(mode)
    return writeParam(self.proxy, PARAM.MODE, mode)
end

-- Convenience: keep the module in static distance mode (0) so OC owns distance.
function Miner:setStatic()
    return self:setMode(0)
end

-- Reads back every input parameter we drive, so a run that has to change them can
-- put them back afterwards (setup does). A parameter that cannot be read comes
-- back nil, and restore() then leaves that one alone rather than guessing.
function Miner:snapshot()
    return {
        distance = readParam(self.proxy, PARAM.DISTANCE),
        maxParallels = readParam(self.proxy, PARAM.MAX_PARALLELS),
        overdrive = readParam(self.proxy, PARAM.OVERDRIVE),
        mode = readParam(self.proxy, PARAM.MODE),
    }
end

-- Puts back what snapshot() read. Like any parameter write, this only takes while
-- the machine is STOPPED -- call setEnabled(false) and let it settle first.
function Miner:restore(snap)
    if type(snap) ~= "table" then return end
    if snap.distance then writeParam(self.proxy, PARAM.DISTANCE, snap.distance) end
    if snap.maxParallels then writeParam(self.proxy, PARAM.MAX_PARALLELS, snap.maxParallels) end
    if snap.overdrive then writeParam(self.proxy, PARAM.OVERDRIVE, snap.overdrive) end
    if snap.mode then writeParam(self.proxy, PARAM.MODE, snap.mode) end
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
miners.PARAM_SET = PARAM_SET
miners.PARAM_GET = PARAM_GET

return miners

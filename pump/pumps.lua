-- Pump abstraction layer -- the ONE place that talks to the TecTech hardware.
--
-- The allocation/demand logic in main.lua only ever calls the small interface
-- below (setThread / idleThread / setEnabled / isActive). Everything about
-- HOW a pump is driven lives here, so:
--   * the TecTech parameter layout can be corrected in one spot, and
--   * a future modem/worker transport (remote pumps) can be slotted in here
--     without touching the demand logic.

local component = require("component")

-- =====================================================================
-- TecTech parameter layout for the Space Elevator pumping module.
--
-- Parameters are written with:  setParameters(hatch:int, id:int, value:double)
-- and the machine is toggled with:  setWorkAllowed(work:boolean)
--
-- Each thread i (0-indexed) occupies hatches 2i and 2i+1:
--   planet    -> hatch 2i,   id 0
--   gas       -> hatch 2i,   id 1
--   parallels -> hatch 2i+1, id 0   (pumping speed; hatch 2i+1 id 1 is unused)
--
-- Verified for thread 0 (planet (0,0), gas (0,1), parallels (1,0)). Higher-tier
-- pumps with multiple threads follow the same pattern; this MVP drives thread 0
-- only, but the layout below already generalizes to any thread index.
-- =====================================================================

local PUMP_TYPE = "gt_machine"   -- component type the pump's Adapter exposes
local PARAM_SET = "setParameters"
local PARAM_GET = "getParameters"

-- Pumps are identified by getName() == "projectmodulepumptN", where N is the
-- tier. Each tier has fixed stats (stored on the Pump for later multi-thread /
-- parallels-aware allocation).
local PUMP_NAME = "projectmodulepumpt"
local TIERS = {
    [1] = { name = "MK-1", threads = 1, parallels = 4 },
    [2] = { name = "MK-2", threads = 4, parallels = 4 },
    [3] = { name = "MK-3", threads = 4, parallels = 64 },
}

local function layout(thread)
    thread = thread or 0
    return {
        planet    = { hatch = 2 * thread,     id = 0 },
        gas       = { hatch = 2 * thread,     id = 1 },
        parallels = { hatch = 2 * thread + 1, id = 0 },
    }
end
-- =====================================================================

local Pump = {}
Pump.__index = Pump

function Pump.new(address, tier, proxy)
    local self = setmetatable({}, Pump)
    self.address = address
    self.proxy = proxy or component.proxy(address)

    -- Per-tier stats (see TIERS), kept for later multi-thread / parallels use.
    local stats = TIERS[tier] or {}
    self.tier = tier
    self.tierName = stats.name
    self.threads = stats.threads
    self.parallels = stats.parallels

    -- Per-thread hardware config last applied by us (thread index -> table).
    self.threadConfig = {}
    return self
end

local function writeParam(proxy, slot, value)
    local setter = proxy[PARAM_SET]
    if setter == nil then
        return false, PARAM_SET .. " not available"
    end
    return pcall(setter, slot.hatch, slot.id, value)
end

local function readParam(proxy, slot)
    local getter = proxy[PARAM_GET]
    if getter == nil then return nil end
    local ok, v = pcall(getter, slot.hatch, slot.id)
    if not ok then return nil end
    return v
end

-- Configures one thread to pump (planet, gas) at the given parallels count.
-- Returns true, or false + error.
function Pump:setThread(thread, planet, gas, parallels)
    local slots = layout(thread)

    local ok, err = writeParam(self.proxy, slots.planet, planet)
    if not ok then return false, tostring(err) end

    ok, err = writeParam(self.proxy, slots.gas, gas)
    if not ok then return false, tostring(err) end

    ok, err = writeParam(self.proxy, slots.parallels, parallels)
    if not ok then return false, tostring(err) end

    self.threadConfig[thread] = { planet = planet, gas = gas, parallels = parallels }
    return true
end

-- Reads a thread's currently-applied (planet, gas, parallels) straight from the
-- hardware via getParameters -- the ground truth of what the pump is pumping,
-- independent of what we last tried to write. Any field is nil if unreadable.
function Pump:getThread(thread)
    local slots = layout(thread)
    return {
        planet    = readParam(self.proxy, slots.planet),
        gas       = readParam(self.proxy, slots.gas),
        parallels = readParam(self.proxy, slots.parallels),
    }
end

-- Idles one thread by setting its parallels to 0 (produces nothing) without
-- disturbing the other threads. Returns true, or false + error.
function Pump:idleThread(thread)
    local ok, err = writeParam(self.proxy, layout(thread).parallels, 0)
    self.threadConfig[thread] = nil
    if not ok then return false, tostring(err) end
    return true
end

-- Allows / disallows the machine to work.
function Pump:setEnabled(enabled)
    if self.proxy.setWorkAllowed ~= nil then
        pcall(self.proxy.setWorkAllowed, enabled)
    end
end

-- True if the machine is currently running.
function Pump:isActive()
    if self.proxy.isMachineActive ~= nil then
        local ok, v = pcall(self.proxy.isMachineActive)
        return ok and v == true
    end
    return false
end

local pumps = {}

-- Autodiscovers pump multiblocks on the network. Every gt_machine whose
-- getName() is "projectmodulepumptN" (N = a known tier) becomes a Pump carrying
-- that tier's stats. Machines that error on getName() or are not pumps are
-- skipped. Returns the list of Pump objects.
function pumps.discover()
    local list = {}
    for addr in component.list(PUMP_TYPE) do
        local proxy = component.proxy(addr)
        local ok, name = pcall(function() return proxy.getName() end)
        if ok and type(name) == "string" then
            local tier = tonumber(name:match("^" .. PUMP_NAME .. "(%d+)$"))
            if tier and TIERS[tier] then
                list[#list + 1] = Pump.new(addr, tier, proxy)
            end
        end
    end
    return list
end

pumps.Pump = Pump
pumps.TYPE = PUMP_TYPE
pumps.TIERS = TIERS

return pumps

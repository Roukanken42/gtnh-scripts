-- Pump abstraction layer -- the ONE place that talks to the TecTech hardware.
--
-- The allocation/demand logic in main.lua only ever calls the small interface
-- below (setConfig / setEnabled / isActive / currentConfig). Everything about
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

function Pump.new(address)
    local self = setmetatable({}, Pump)
    self.address = address
    self.proxy = component.proxy(address)
    self.config = nil        -- { planet=, gas=, parallels= } last applied by us
    self.assignedName = nil  -- gas name main.lua allocated to this pump
    return self
end

local function writeParam(proxy, slot, value)
    local setter = proxy[PARAM_SET]
    if type(setter) ~= "function" then
        return false, PARAM_SET .. " not available"
    end
    return pcall(setter, slot.hatch, slot.id, value)
end

-- Applies a (planet, gas) configuration to a thread (default 0), optionally the
-- parallels count too (pass nil to leave the pump's existing parallels
-- untouched). Returns true, or false + error.
function Pump:setConfig(planet, gas, parallels, thread)
    local slots = layout(thread)

    local ok, err = writeParam(self.proxy, slots.planet, planet)
    if not ok then return false, tostring(err) end

    ok, err = writeParam(self.proxy, slots.gas, gas)
    if not ok then return false, tostring(err) end

    if parallels ~= nil then
        ok, err = writeParam(self.proxy, slots.parallels, parallels)
        if not ok then return false, tostring(err) end
    end

    self.config = { planet = planet, gas = gas, parallels = parallels }
    return true
end

-- Allows / disallows the machine to work.
function Pump:setEnabled(enabled)
    if type(self.proxy.setWorkAllowed) == "function" then
        pcall(self.proxy.setWorkAllowed, enabled)
    end
end

-- True if the machine is currently running.
function Pump:isActive()
    if type(self.proxy.isMachineActive) == "function" then
        local ok, v = pcall(self.proxy.isMachineActive)
        return ok and v == true
    end
    return false
end

-- The last (planet, gas, parallels) we applied, or nil if never configured.
function Pump:currentConfig()
    return self.config
end

local pumps = {}

-- Builds Pump objects for an explicit list of component addresses (may be
-- partial addresses -- they are resolved against PUMP_TYPE). A bad address is
-- skipped with a warning rather than crashing the controller.
function pumps.load(addresses)
    local list = {}
    for _, addr in ipairs(addresses or {}) do
        local full = component.get(addr, PUMP_TYPE) or addr
        local ok, pump = pcall(Pump.new, full)
        if ok then
            list[#list + 1] = pump
        else
            print("WARN: could not load pump '" .. tostring(addr) .. "': " .. tostring(pump))
        end
    end
    return list
end

-- Lists candidate pump addresses currently on the network (for config setup).
function pumps.discover()
    local found = {}
    for addr in component.list(PUMP_TYPE) do
        found[#found + 1] = addr
    end
    return found
end

pumps.Pump = Pump
pumps.TYPE = PUMP_TYPE

return pumps

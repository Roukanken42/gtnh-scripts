-- Pump abstraction layer -- the ONE place that talks to the TecTech hardware.
--
-- The allocation/demand logic in main.lua only ever calls the small interface
-- below (setConfig / setEnabled / isActive / currentConfig). Everything about
-- HOW a pump is driven lives here, so:
--   * the TecTech parameter API can be corrected in one spot after `probe`, and
--   * a future modem/worker transport (remote pumps) can be slotted in here
--     without touching the demand logic.

local component = require("component")

-- =====================================================================
-- PENDING PHASE 0 VERIFICATION. Run `probe <PUMP_TYPE>` in-game and fix
-- the constants below to match what the pump's Adapter actually exposes.
-- =====================================================================

-- Component type the pump's Adapter surfaces. TecTech multiblocks usually show
-- up as "gt_machine"; confirm with `probe` (look for the pumping module).
local PUMP_TYPE = "gt_machine"

-- Method that writes an input parameter. Best guess from TecTech's OC glue;
-- confirm the exact name + argument order from `probe <PUMP_TYPE>` docs.
local SET_PARAM = "setParameterIn"

-- Translate a (planet, gas) configuration into the raw parameter writes.
-- Default guess: parameter slot 0 side A = planet, slot 0 side B = gas.
-- Adjust indices/sides once the real layout is known.
local function paramWrites(planet, gas)
    return {
        { index = 0, isB = false, value = planet },
        { index = 0, isB = true,  value = gas },
    }
end

-- Some machines require being stopped before parameters change. If probing
-- shows live changes are fine, set this to false to avoid a stop/start cycle.
local STOP_BEFORE_RECONFIGURE = true
-- =====================================================================

local Pump = {}
Pump.__index = Pump

function Pump.new(address)
    local self = setmetatable({}, Pump)
    self.address = address
    self.proxy = component.proxy(address)
    self.config = nil        -- { planet=, gas= } last applied by us
    self.assignedName = nil  -- gas name main.lua allocated to this pump
    return self
end

-- Applies a (planet, gas) parameter configuration. Returns true, or false+err.
function Pump:setConfig(planet, gas)
    local setter = self.proxy[SET_PARAM]
    if type(setter) ~= "function" then
        return false, SET_PARAM .. " not available on " .. self.address
    end

    if STOP_BEFORE_RECONFIGURE then
        self:setEnabled(false)
    end

    for _, w in ipairs(paramWrites(planet, gas)) do
        local ok, err = pcall(setter, w.index, w.isB, w.value)
        if not ok then
            return false, tostring(err)
        end
    end

    self.config = { planet = planet, gas = gas }
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

-- The last (planet, gas) we applied, or nil if never configured this run.
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

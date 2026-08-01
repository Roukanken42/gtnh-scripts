-- Miner abstraction layer -- the ONE place that talks to the mining hardware.
--
-- Analogous to pump/pumps.lua: the demand/allocation logic (added in a later
-- part) will only ever call the small interface below, so everything about HOW
-- a mining module is driven lives here. That keeps the TecTech parameter layout
-- in one spot and leaves room for a future remote-transport layer.
--
-- This is PART 1: auto-discovery + per-tier stats + the generic machine
-- controls. The mining-specific parameter layout (what a thread mines, how
-- parallels are set, etc.) is deliberately NOT here yet -- it differs from
-- pumping and will be reverse-engineered and wired up in a following part.

local component = require("component")

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

    -- Per-thread hardware config last applied by us (thread index -> table).
    -- The layout that fills this is TBD (see the module header).
    self.threadConfig = {}
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

local miners = {}

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

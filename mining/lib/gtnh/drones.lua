-- Catalog of mining drones. Every mining module needs a drone loaded into its
-- input bus; the drone's tier is what actually sets the module's mining power.
--
-- Drones are items whose display label is "Mining Drone MK-<roman>", using Roman
-- numerals MK-I .. MK-XIII (tiers 1..13). That label is what we request from the
-- ME network (see transport.lua), so it must match the in-game name exactly.
--
-- `material` is the metal each tier is crafted from -- recorded here for future
-- reference (cost/craft planning, tier-vs-throughput tuning); nothing uses it
-- yet.

local ROMAN = {
    "I", "II", "III", "IV", "V", "VI", "VII",
    "VIII", "IX", "X", "XI", "XII", "XIII",
}

-- Mining material by tier: 1-2 Steel, 3-4 Titanium, 5-6 Tungstensteel,
-- 7-8 Naquadah, 9 Naquadah Alloy, 10 Neutronium, 11 Cosmic Neutronium,
-- 12 Infinity, 13 Transcendent Metal.
local MATERIAL = {
    "Steel", "Steel",
    "Titanium", "Titanium",
    "Tungstensteel", "Tungstensteel",
    "Naquadah", "Naquadah",
    "Naquadah Alloy",
    "Neutronium",
    "Cosmic Neutronium",
    "Infinity",
    "Transcendent Metal",
}

local drones = {}

drones.PREFIX = "Mining Drone MK-"
drones.MIN_TIER = 1
drones.MAX_TIER = #ROMAN   -- 13

-- The item id every mining drone shares (only the label differs per tier), used
-- to find drones in the ME network.
drones.ITEM_NAME = "gtnhintergalactic:item.MiningDrone"

-- Build the per-tier descriptors once: { tier, roman, name, material }.
-- `name` is the exact item label used to pull the drone from ME.
local byTier = {}
local byName = {}
for tier = 1, #ROMAN do
    local d = {
        tier = tier,
        roman = ROMAN[tier],
        name = drones.PREFIX .. ROMAN[tier],
        material = MATERIAL[tier],
    }
    byTier[tier] = d
    byName[d.name] = d
end

-- Returns the drone descriptor for a tier (1..13), or nil if out of range.
function drones.get(tier)
    return byTier[tier]
end

-- Returns the drone descriptor for an item label ("Mining Drone MK-VII"), or nil.
function drones.fromName(label)
    return label and byName[label] or nil
end

drones.all = byTier      -- 1..13 array of descriptors
drones.byName = byName

return drones

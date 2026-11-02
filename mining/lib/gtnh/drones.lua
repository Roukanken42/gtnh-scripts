-- Catalog of mining drones. Every mining module needs a drone loaded into its
-- input bus; the drone's tier is what actually sets the module's mining power.
--
-- Drones are items whose display label is "Mining Drone Mk-<roman> (<voltage>)",
-- e.g. "Mining Drone Mk-VII (ZPM)", for Mk-I (LV) .. Mk-XIII (UXV), tiers 1..13
-- (GTNH 2.9; 2.8 labelled them "Mining Drone MK-<roman>"). That label is what we
-- request from the ME network (see transport.lua), so it must match the in-game
-- name exactly. There is also a Mk-XIV (MAX), which 2.9 gives no drill material,
-- so it is not listed here.
--
-- `material` is the metal each tier is crafted from -- recorded here for future
-- reference (cost/craft planning, tier-vs-throughput tuning); nothing uses it
-- yet.

local ROMAN = {
    "I", "II", "III", "IV", "V", "VI", "VII",
    "VIII", "IX", "X", "XI", "XII", "XIII",
}

-- The voltage tier in each drone's label, by tier.
local VOLTAGE = {
    "LV", "MV", "HV", "EV", "IV", "LuV", "ZPM",
    "UV", "UHV", "UEV", "UIV", "UMV", "UXV",
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

drones.PREFIX = "Mining Drone Mk-"
drones.MIN_TIER = 1
drones.MAX_TIER = #ROMAN   -- 13

-- The item id every mining drone shares (only the label differs per tier), used
-- to find drones in the ME network.
drones.ITEM_NAME = "gtnhintergalactic:item.MiningDrone"

-- Build the per-tier descriptors once: { tier, roman, voltage, name, material }.
-- `name` is the exact item label used to pull the drone from ME.
local byTier = {}
local byName = {}
for tier = 1, #ROMAN do
    local d = {
        tier = tier,
        roman = ROMAN[tier],
        voltage = VOLTAGE[tier],
        name = drones.PREFIX .. ROMAN[tier] .. " (" .. VOLTAGE[tier] .. ")",
        material = MATERIAL[tier],
    }
    byTier[tier] = d
    byName[d.name] = d
end

-- Returns the drone descriptor for a tier (1..13), or nil if out of range.
function drones.get(tier)
    return byTier[tier]
end

local tierOfRoman = {}
for tier, r in ipairs(ROMAN) do tierOfRoman[r] = tier end

-- Returns the drone descriptor for an item label ("Mining Drone Mk-VII (ZPM)"),
-- or nil. Anything else of the form "Mining Drone MK-<roman>..." resolves too, by
-- its numeral, so a label from an older build (or one stored before an update)
-- still names the right tier.
function drones.fromName(label)
    if type(label) ~= "string" then return nil end
    local d = byName[label]
    if d then return d end
    local roman = label:match("^Mining Drone [Mm][Kk]%-(%u+)")
    return roman and byTier[tierOfRoman[roman]] or nil
end

drones.all = byTier      -- 1..13 array of descriptors
drones.byName = byName

return drones

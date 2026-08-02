-- User configuration for the space-mining controller. This file is NOT
-- overwritten when you re-run `install` (it is marked `?` in the manifest), so
-- your settings survive updates.
--
-- The fiddly per-module addresses (transposer / ME interface / sides) are best
-- filled in by running the `setup` script, which discovers them and writes them
-- to stations.lua next to this file. This config loads that file automatically.

local cfg = {}

-- ---- Stations (one per mining module) --------------------------------------
-- Each module needs a "station": the transposer that shuffles its drones, the
-- ME interface it stocks from, and which transposer SIDES face the interface and
-- the module's input bus. Keyed by the miner's component address:
--
--   cfg.stations = {
--     ["<miner-address>"] = {
--       label         = "T2 miner",       -- friendly name (optional)
--       transposer    = "<transposer-address>",
--       interface     = "<me_interface-address>",
--       interfaceSide = 3,                 -- transposer side facing the interface
--       inputBusSide  = 2,                 -- transposer side facing the input bus
--       interfaceSlot = 1,                 -- staging slot; distinct per station
--                                          -- when several share one interface
--     },
--   }
--
-- Prefer running `setup` over editing this by hand -- it also assigns each
-- station a distinct interfaceSlot when several share an ME interface, so their
-- drone loads can run concurrently. Anything set here wins over stations.lua.
cfg.stations = {}

-- Shared database component that holds item metadata for ME stocking. Leave nil
-- to let setup pick it (there is usually exactly one).
cfg.database = nil

-- Pull in whatever `setup` discovered (stations.lua) without clobbering anything
-- you set above. stations.lua is machine-specific and not shipped in the repo.
do
    local ok, data = pcall(require, "stations")
    if ok and type(data) == "table" then
        if cfg.database == nil then cfg.database = data.database end
        if type(data.stations) == "table" then
            for addr, st in pairs(data.stations) do
                if cfg.stations[addr] == nil then cfg.stations[addr] = st end
            end
        end
    end
end

-- ---- Behaviour -------------------------------------------------------------

-- How many drones to keep in each module's input bus. One is enough to run the
-- module; revisit once we know whether parallels want a drone each.
cfg.dronesPerModule = 1

-- Safety: when true, drone moves are only LOGGED, never performed. Flip to false
-- once you have watched a drone move correctly in-game.
cfg.dryRun = true

-- Seconds to wait for AE2 to stock a requested drone into the interface before
-- giving up on a load.
cfg.stockTimeout = 10

-- Interface config/inventory slot (1..8) used to stage drones through.
cfg.interfaceSlot = 1

-- ---- What the inputs cost you ----------------------------------------------
-- The targeter (target.lua) searches for the CHEAPEST module configuration that
-- serves a demand, so it needs to know what the two consumables are worth to you.
--
-- The numbers are arbitrary POINTS and are only ever compared against each other,
-- so they never have to be right in absolute terms -- just roughly right
-- relative to one another. Neutronium is the baseline at 1.
--
-- A material set to `false` (or simply left out) is treated as UNOBTAINABLE and
-- its drone tiers are dropped from the search entirely, rather than being priced
-- as free. Same for plasmas.

-- Points per INGOT of a drone's material. One mining kit -- 4 rods + 4 drill tips,
-- consumed per meteor -- is 18 of them, so these get multiplied hard.
cfg.kitCost = {
    ["Steel"] = 0.02,               -- MK-I,   MK-II
    ["Titanium"] = 0.02,            -- MK-III, MK-IV
    ["Tungstensteel"] = 0.02,       -- MK-V,   MK-VI
    ["Naquadah"] = 0.05,            -- MK-VII, MK-VIII
    ["Naquadah Alloy"] = 0.1,       -- MK-IX
    ["Neutronium"] = 1,             -- MK-X    -- baseline
    ["Cosmic Neutronium"] = 10,     -- MK-XI   -- TUNE
    ["Infinity"] = 240,             -- MK-XII  -- 24x cosmic (24 go into one)
    ["Transcendent Metal"] = false, -- MK-XIII -- unobtainable
}

-- Points per LITRE (mB) of plasma, by tier. Higher tiers burn far less per meteor
-- (825 L of Helium vs 150 L of Plutonium-241) but cost much more to make, which is
-- exactly the trade-off these numbers settle. All TUNE.
cfg.plasmaCost = {
    [1] = 0.001,   -- Helium
    [2] = 0.004,   -- Bismuth
    [3] = 0.02,    -- Radon
    [4] = 0.1,     -- Technetium
    [5] = 0.5,     -- Plutonium-241
}

-- Points per EU. Deliberately tiny: power is meant to break ties between
-- otherwise-equal configurations, not to drive the choice.
cfg.euCost = 1e-9

-- What you can actually SUPPLY per second. A configuration that burns more than
-- any of these is reported as infeasible instead of being recommended. Leave a
-- material out (or the whole table empty) to leave it ungated.
cfg.budget = {
    ingots = {
        -- ["Neutronium"] = 0.5,       -- ingots per second you can make
        -- ["Cosmic Neutronium"] = 0.1,
    },
    plasma = {
        -- [5] = 200,                  -- litres per second you can make
    },
    eu = nil,                          -- EU per second the mining line may draw
}

-- Computation the space elevator can feed a module. Meteors ask for a fixed
-- amount per parallel, so this caps how many parallels each one actually gets --
-- and a meteor whose requirement it cannot cover at all is one the module stalls
-- on. Leave nil to assume computation is never the limit.
cfg.computation = nil

-- ---- Keeping the local net stocked -----------------------------------------
-- Consumables reach the local net through an ME Interface on the MAIN net that
-- carries fake crafting patterns: requesting one pushes that pattern's INPUTS
-- across. supply.lua reads those patterns to learn what is on offer, so nothing
-- here has to name items -- only how much of each to keep.
--
-- Run `stock patterns` once after wiring the adapter to see what it found.

cfg.supply = {
    -- Adapter address of the supply interface. nil = autodetect (the one
    -- me_interface that has patterns; the per-module station interfaces have none).
    interface = nil,

    -- KITS to keep in the local net, per drone material. One kit is 4 drill tips
    -- + 4 rods, i.e. one meteor's worth. Materials are the ones in drones.lua:
    -- Steel, Titanium, Tungstensteel, Naquadah, Naquadah Alloy, Neutronium,
    -- Cosmic Neutronium, Infinity and Transcendent Metal (that last one only for
    -- completeness -- target.lua treats it as unobtainable and never picks it).
    -- Anything not listed here is simply not stocked.
    target = {
        -- ["Neutronium"] = 500,
    },

    -- Litres of plasma to keep in the local net, by fluid name.
    plasma = {
        -- ["Radon Plasma"] = 64000,
    },

    -- Litres one craft of a plasma pattern actually delivers. A pattern carries a
    -- count of ae2fc "drops", which does not tell us its litre value -- so measure
    -- it once (`stock plasma "Radon Plasma" 1`, watch the level) and record it
    -- here. Until then plasma shortfalls are reported but never auto-requested.
    plasmaPerCraft = {
        -- ["Radon Plasma"] = 16000,
    },

    -- Refill only once stock falls below this fraction of target, then fill to
    -- the top. Stops a slow drain from re-requesting every single cycle.
    lowWater = 0.9,

    -- Cap on how many crafts a single request may ask for. nil = the whole
    -- deficit in one job.
    maxCrafts = nil,
}

return cfg

-- User configuration for the space-mining controller. This file is NOT
-- overwritten when you re-run `install` (it is marked `?` in the manifest), so
-- your settings survive updates.
--
-- The fiddly per-module addresses (transposer / ME interface / sides) are best
-- filled in by running the `setup` script, which discovers them and writes them
-- to data/stations.lua. This config loads that file automatically, at the very
-- bottom, so it can fill in anything left unset here.

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
--
--       -- Plasma feed (optional). May reuse the transposer and interface above
--       -- -- both can carry items and fluids -- or name different ones. All
--       -- four go together.
--       fluidTransposer    = "<transposer-address>",
--       fluidInterface     = "<me_interface-address>",   -- the FLUID interface
--       fluidInterfaceSide = 1,            -- transposer side facing it
--       inputHatchSide     = 0,            -- transposer side facing the input HATCH
--       fluidTank          = 0,            -- which of its 6 tanks, 0-BASED;
--                                          -- distinct per station when shared
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

-- Whatever `setup` discovered is merged in at the BOTTOM of this file, so it can
-- fill in anything you left unset here -- including cfg.supply.interface, which is
-- defined further down.

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
-- any of these is reported as infeasible rather than recommended.
--
-- Every entry is listed so you never have to remember how a material is spelled:
-- replace a nil with a number. nil means NO LIMIT -- "I have not said", not
-- "none allowed".
cfg.budget = {
    -- Ingots per second you can produce, per drone material.
    ingots = {
        ["Steel"]              = nil,
        ["Titanium"]           = nil,
        ["Tungstensteel"]      = nil,
        ["Naquadah"]           = nil,
        ["Naquadah Alloy"]     = nil,
        ["Neutronium"]         = nil,
        ["Cosmic Neutronium"]  = nil,
        ["Infinity"]           = nil,
        ["Transcendent Metal"] = nil,
    },

    -- Litres per second you can produce, by plasma TIER (as cfg.plasmaCost).
    plasma = {
        [1] = nil,   -- Helium
        [2] = nil,   -- Bismuth
        [3] = nil,   -- Radon
        [4] = nil,   -- Technetium
        [5] = nil,   -- Plutonium-241
    },

    eu = nil,        -- EU per second the mining line may draw
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
    -- Adapter address of the supply interface. `setup` records the one it found
    -- in stations.lua, so this is normally left nil and filled in below; setting
    -- it here overrides that. A stored address that no longer has patterns is
    -- discarded and re-detected rather than trusted.
    interface = nil,

    -- KITS to keep in the local net, per drone material. One kit is 4 drill tips
    -- + 4 rods, i.e. one meteor's worth. nil means DO NOT STOCK it, so filling in
    -- only the materials your drones actually use is the normal state.
    target = {
        ["Steel"]              = nil,
        ["Titanium"]           = nil,
        ["Tungstensteel"]      = nil,
        ["Naquadah"]           = nil,
        ["Naquadah Alloy"]     = nil,
        ["Neutronium"]         = nil,
        ["Cosmic Neutronium"]  = nil,
        ["Infinity"]           = nil,
        ["Transcendent Metal"] = nil,   -- listed for completeness; unobtainable above
    },

    -- Litres of plasma to keep in the local net, by fluid name. nil = do not stock.
    -- ae2fc carries a fluid through a pattern as "drop of <Fluid>" at one drop per
    -- litre, so a pattern's input count is already its volume -- nothing to measure.
    plasma = {
        ["Helium Plasma"]        = nil,
        ["Bismuth Plasma"]       = nil,
        ["Radon Plasma"]         = nil,
        ["Technetium Plasma"]    = nil,
        ["Plutonium-241 Plasma"] = nil,
    },

    -- `plasma keep` tops a hatch up once it falls below this fraction of its
    -- target, and then fills it right back to the top. The gap between the two is
    -- the batch size, so a LOW value means big, infrequent transfers -- which is
    -- the point: moving fluid costs a component call, and the hatch holds plenty.
    hatchRefill = 0.5,

    -- Seconds between checks in `plasma keep`. Only reads tank levels, so this is
    -- cheap; the refill itself is rare.
    hatchPoll = 5,

    -- How much plasma to keep in each module's INPUT HATCH, in meteors' worth.
    -- Expressing it per-meteor makes it scale itself with the plasma tier: 64
    -- meteors is 52,800 L of Helium but only 9,600 L of Plutonium-241, since a
    -- higher tier burns far fewer litres per meteor. There is no reason to hoard
    -- more -- the interface keeps another 16,000 L staged behind it.
    --
    -- Note a module running 8 parallels chews through this eight times faster
    -- than one running 1, so raise it if the feed cycle is slow. Clamped to what
    -- the hatch can actually hold.
    --
    -- Sized for `plasma keep` to be lazy: a few hundred meteors means it tops a
    -- hatch up every few minutes rather than every few seconds.
    hatchMeteors = 256,

    -- Per-plasma override in LITRES, when the meteor figure above does not suit.
    -- nil = use hatchMeteors.
    hatchLitres = {
        ["Helium Plasma"]        = nil,
        ["Bismuth Plasma"]       = nil,
        ["Radon Plasma"]         = nil,
        ["Technetium Plasma"]    = nil,
        ["Plutonium-241 Plasma"] = nil,
    },

    -- Refill only once stock falls below this fraction of target, then fill to
    -- the top. Stops a slow drain from re-requesting every single cycle.
    lowWater = 0.9,

    -- Cap on how many crafts a single request may ask for. nil = the whole
    -- deficit in one job.
    maxCrafts = nil,
}

-- ---- The controller (main.lua) ---------------------------------------------
-- MANUAL mode: you set each module's drone, distance and overdrive yourself and
-- the controller keeps the consumables flowing. It never reconfigures a module.
--
-- What to stock is READ OFF THE HARDWARE -- a module's input bus says which drone
-- it runs, and that says which material its kits are made of -- so nothing here
-- names a material. The two figures below turn "which" into "how many". A number
-- in cfg.supply.target or cfg.supply.plasma overrides the result for that entry.

cfg.control = {
    -- Seconds between maintenance cycles. Each one reads every module and its
    -- hatch, so this is the real cost of running the controller; the dashboard
    -- repaints on its own faster cadence without touching hardware.
    interval = 5,
    uiRefresh = 1,

    -- How many cycles between the SLOW reads: which drone is in each bus, how
    -- much plasma is staged, and what the local net holds. Every one of those
    -- changes on a scale of minutes, while a component call that is not direct
    -- costs a whole tick -- so asking every cycle spent most of a second to learn
    -- nothing. The hatch level is still read every cycle, since topping up
    -- decides on it, and an edit forces a full read on the spot.
    --
    -- The cost is staleness: with the defaults, a drone swapped by hand shows up
    -- within 30s. Lower it if that matters more than the cycle time.
    slowEvery = 6,

    -- Kits to keep in the local net per module running that material. One kit is
    -- one meteor, so this is roughly "how many meteors of runway each module
    -- has". Worth lowering for the expensive materials -- 256 Infinity kits is
    -- 4,608 Infinity ingots sitting idle -- via cfg.supply.target above.
    kitsPerMiner = 256,

    -- Local-net plasma buffer, in hatchfuls per module with a plasma feed. The
    -- hatches hold one each; this is what refills them.
    hatchRefills = 4,

    -- How many restock requests may be in flight at once, per kind. Each holds a
    -- crafting CPU on the main net until the fake pattern's inputs are pushed, so
    -- an uncapped controller could take the whole crafting bank. Plasma is one
    -- because manual mode runs a single plasma fleet-wide.
    jobs = { kit = 2, plasma = 1 },
}

-- ---- What `setup` discovered -----------------------------------------------
-- Dead last, after every cfg table above exists: it fills in whatever was left
-- unset and never clobbers something you set by hand. stations.lua is
-- machine-specific and not in the repo; re-run `setup` to regenerate it.
do
    local ok, stations = pcall(require, "lib.stations")
    local data = ok and stations.load() or nil
    if type(data) == "table" then
        if cfg.database == nil then cfg.database = data.database end
        if cfg.supply.interface == nil then cfg.supply.interface = data.supply end
        if type(data.stations) == "table" then
            for addr, st in pairs(data.stations) do
                if cfg.stations[addr] == nil then cfg.stations[addr] = st end
            end
        end
    end
end

return cfg

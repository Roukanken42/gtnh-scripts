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

-- Safety: when true, nothing is actually MOVED or WRITTEN -- drone moves are only
-- logged, and automatic mode plans, reports what it would set, and leaves every
-- module alone. Everything that only reads still runs, so the dashboard, the want
-- list and the log show exactly what would happen. Flip to false once you have
-- watched a drone move correctly in-game and you agree with what AUTO says it would
-- do.
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
-- relative to one another. Nothing is a fixed baseline: what matters is the ratios
-- between them, and a material being cheaper than a lower-tier one is a perfectly
-- ordinary thing to say if that is how your production actually looks.
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
    ["Naquadah"] = 0.02,            -- MK-VII, MK-VIII
    ["Naquadah Alloy"] = 0.02,      -- MK-IX
    ["Neutronium"] = 0.4,           -- MK-X    
    ["Cosmic Neutronium"] = 0.1,    -- MK-XI   
    ["Infinity"] = 2.4,             -- MK-XII  
    ["Transcendent Metal"] = false, -- MK-XIII 
}

-- Points per LITRE (mB) of plasma, by tier. Higher tiers burn far less per meteor
-- (825 L of Helium vs 150 L of Plutonium-241) but usually cost more to make, and
-- these numbers are what settles that trade-off. Pricing them all the SAME, as
-- below, says the litres are interchangeable -- which hands the choice to the
-- consumption rate alone, and so always favours the highest tier available.
cfg.plasmaCost = {
    [1] = 0.01,   -- Helium
    [2] = 0.01,   -- Bismuth
    [3] = 0.01,   -- Radon
    [4] = 0.01,   -- Technetium
    [5] = false,  -- Plutonium-241
}

-- Points per EU. Deliberately tiny: power is meant to break ties between
-- otherwise-equal configurations, not to drive the choice.
cfg.euCost = 1e-12

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
        ["Transcendent Metal"] = nil,
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
    -- This one is per HATCH, not per parallel like cfg.control's figures below --
    -- a hatch holds what it holds however many parallels drink from it. So a module
    -- running 8 chews through this eight times faster than one running 1: raise it
    -- if the feed cycle is slow. Clamped to what the hatch can actually hold.
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
    lowWater = 0.5,

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

    -- Kits to keep in the local net per PARALLEL running that material. One kit is
    -- one meteor and a module mines one meteor per parallel per operation, so this
    -- is roughly "how many meteors of runway each parallel has" -- and counting
    -- parallels is what makes it track consumption: a T2 on 4 of them asks for four
    -- times what a single-parallel module does, because it burns four times as much.
    --
    -- Worth lowering for the expensive materials -- 1,024 Infinity kits is 18,432
    -- Infinity ingots sitting idle, and a T3 asks for eight lots of it -- via
    -- cfg.supply.target above, which is a flat figure and ignores parallels.
    kitsPerParallel = 256,

    -- Local-net plasma buffer, in hatchfuls per PARALLEL with a plasma feed. Same
    -- reasoning as the kits: the litres go per meteor, so parallels are what spend
    -- them. The hatches hold one hatchful each; this is what refills them.
    hatchRefills = 8,

    -- How long after a craft finishes before its material may be requested again.
    -- The local net is re-read the moment a craft lands, and THAT is what stops a
    -- second order; this only covers the tick or two between the goods being
    -- pushed and the network showing them. Short on purpose -- if a craft really
    -- did under-deliver, this is how long before the shortfall is noticed.
    settleGrace = 5,

    -- How long to keep waiting for a module to finish its operation before
    -- giving up on a queued parameter change. TecTech only accepts a write while
    -- the machine is STOPPED, and a mining operation runs for tens of seconds --
    -- minutes, if the overdrive is throttled -- so this is a stuck-machine
    -- backstop, not an expected wait. The change sits in the queue meanwhile and
    -- the dashboard shows it waiting.
    stopTimeout = 180,

    -- How many restock requests may be in flight at once, per kind. Each holds a
    -- crafting CPU on the main net until the fake pattern's inputs are pushed, so
    -- an uncapped controller could take the whole crafting bank. Plasma is one
    -- because manual mode runs a single plasma fleet-wide.
    jobs = { kit = 2, plasma = 1 },
}

-- ---- Automatic mode --------------------------------------------------------
-- WHAT the fleet is for lives in wants.lua, deliberately in its own file. These are
-- the knobs for HOW EAGERLY it is served, and every one of them exists because
-- mining is slow and imprecise: an operation runs for tens of seconds, a parameter
-- write needs the module stopped, and no configuration yields one material cleanly.
-- So the defaults are all on the side of leaving a settled fleet alone.
--
-- A module is only aimed if it is in AUTO (they all start there; setting anything by
-- hand claims a module, and A on the dashboard hands it back). `main --manual` turns
-- the whole thing off for one run without changing any of that.
cfg.auto = {
    -- Seconds to close a shortfall in. This is the only thing that converts "I am
    -- 60,000 items short" into a rate a fleet can be asked for, so it sets how hard
    -- the whole list pulls: an hour means an empty want of 60k asks for ~17 items a
    -- second, which is several modules' worth, while a day asks for less than one.
    --
    -- It is also the dial for how much of the fleet gets used. The targeter throttles
    -- overdrive down to the rate demanded and no further, and the allocator stops
    -- assigning modules once the demand is covered -- so a long horizon leaves
    -- modules idle and a short one puts them all to work at full speed. Shorten it
    -- when the fleet is sitting around; lengthen it when kits are the bottleneck.
    horizon = 3600,

    -- Stock items per ORE ITEM MINED, for entries in wants.lua that do not say. A
    -- module mines ore; what reaches the main net is whatever your line turns that ore
    -- into, and the controller cannot see that step -- so this is the bridge between
    -- "how much ore a meteor gives" and "how much of the item I hold". Commonly 2 or
    -- about 2.7 for a line ending in dust, and 1 for stocking the raw ore.
    --
    -- 1 is the honest default and errs towards over-mining, but it makes every ETA
    -- read several times too long, and it biases the fleet between two wants whose
    -- lines yield differently. It belongs per entry in wants.lua, where the factor
    -- actually lives; set it here only if your whole list happens to share one.
    perOre = 1,

    -- Hysteresis, and the reason a fleet settles instead of oscillating. A want that
    -- reaches its target stops being asked for until it falls back below this
    -- fraction of it, so ore hovering at 100% cannot re-aim the fleet every cycle.
    refillAt = 0.75,

    -- Below this share of its target a want is CRITICAL and its weight is multiplied
    -- by criticalBoost, which is how "nearly out" outbids "getting low" when they
    -- want different meteors. The boost is deliberately blunt: purity is so poor
    -- that a small nudge would change nothing about which pool wins.
    criticalAt = 0.15,
    criticalBoost = 3,

    -- How much better a configuration has to be before a module is STOPPED to write
    -- it: 0.25 means "a quarter more of the demand covered, or don't bother". Every
    -- re-aim costs a mining operation and a plasma change drains a hatch, so this is
    -- the difference between a fleet that mines and one that spends its life
    -- stopping. 0 re-aims on any improvement; a large number freezes the fleet.
    margin = 0.25,

    -- Sweeps of the allocator's coverage search. Two settle the normal case -- the
    -- first hands out the broad configurations, the second is where a module notices
    -- its neighbour has covered its materials and moves to what is still missing.
    passes = 3,
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

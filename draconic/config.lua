-- User configuration for the Draconic Reactor controller. This file is NOT
-- overwritten when you re-run `install` (it is marked `?` in the manifest).
-- Run `probe` to see what the script finds.

local cfg = {}

-- Full-screen dashboard (needs a GPU + screen, 80x25 or bigger). false = plain
-- text log.
cfg.ui = true

-- ---------------------------------------------------------------- hardware --

-- The reactor, through an Adapter touching a Reactor Stabilizer or the Energy
-- Injector. nil = the only draconic_reactor component.
cfg.reactor = { address = nil }

-- The transposer touches the Super Stock Replenisher (fuel comes in there from
-- the main net) and a buffer chest (a compressed chest) that something else
-- empties into a Reactor Stabilizer. The replenisher is found by name; the
-- chest by name (chest/compress), else as the one other inventory. Set a side
-- here only to override what `probe sides` reports. Sides: 0 down, 1 up,
-- 2 north, 3 south, 4 west, 5 east.
-- Chaos shards must be pulled out of a stabilizer too (an item conduit): while
-- a full shard waits in the reactor's slot, no fuel can get in.
cfg.transposer = {
    address = nil,      -- nil = the transposer that touches both
    stockSide = nil,
    targetSide = nil,   -- the buffer chest
}

-- -------------------------------------------------------------------- fuel --

cfg.feed = {
    enabled = true,       -- false = never touch items, only watch/start/stop
    -- Keep topping the reactor up while it runs. With a steady supply it then
    -- runs indefinitely and only shuts down when the supply dries up and the
    -- fuel inside gets low. false = fill only between runs.
    whileRunning = true,
    interval = 1,         -- seconds between replenisher checks
    maxMoves = 4,         -- transferItem calls per check (each costs a tick)
}

-- -------------------------------------------------------------- auto-start --

cfg.autoStart = {
    -- Starting state. The A key toggles it and the choice is remembered in
    -- the state file.
    enabled = true,
    -- Charge once the reactor holds at least this much UNCONVERTED fuel, in
    -- awakened draconium block equivalents (1 block = 9 ingots = 81 nuggets =
    -- 162 fuel; the reactor holds at most 3240 blocks). The containment field
    -- and saturation capacity are fixed from the fuel inside when charging
    -- starts, so more is better.
    minBlocks = 1620,
    -- Also require this much fuel AVAILABLE in total: unconverted fuel in the
    -- reactor plus draconium in the replenisher, in block equivalents. It can
    -- be more than the reactor holds; the rest is fed in while it runs. Use
    -- it for a minimum running time: time = (total x 162) / burn rate. At the
    -- dashboard's "Burn" of 100 fuel/s, 10000 blocks is about 4.5 hours.
    -- The replenisher must be able to stock the part beyond 3240 blocks, or
    -- this is never reached. Only counts while feeding (F) and
    -- cfg.feed.whileRunning are on. 0 = off.
    minTotalBlocks = 0,
    -- Also wait until the replenisher is empty or the reactor is full, so a
    -- charge does not start halfway through a delivery.
    waitForDelivery = true,
    -- Seconds the reactor must have been OFFLINE before starting again.
    cooldown = 30,
    -- Leftover chaos from the last run must be below this share of the
    -- contents (the conversion gauge). Adding fuel lowers it.
    maxConversion = 0.10,
    -- Press "activate" by itself once charged -- also after a manual start
    -- or a charge started from the reactor GUI.
    activate = true,
}

-- ------------------------------------------------------------------ safety --

cfg.safety = {
    -- The reactor only cools down while it still has UNCONVERTED fuel, and it
    -- keeps converting fuel while it cools. Every `simInterval` seconds the
    -- script simulates a shutdown from the current state (physics.lua, the
    -- mod's own formulas) and stops the reactor when the fuel left is below
    -- reserveFactor x what that shutdown would use, plus reserveBlocks.
    reserveFactor = 2.0,
    reserveBlocks = 10,
    simInterval = 2,
    -- The wiki script's two rules, kept as backstops:
    stopConversion = 0.20,  -- chaos share of the contents
    stopField = 0.20,       -- containment field. Hitting this also turns
                            -- auto-start off: the injector is not keeping up.
    -- Display only.
    warnTemp = 8000,        -- above this, fuel use and field drain climb fast
    warnField = 0.30,
    -- Q (twice) quits. true = stop the reactor first: once the script is gone
    -- nothing feeds it and nothing stops it before the fuel runs out, which
    -- ends in an explosion.
    stopOnQuit = true,
}

-- -------------------------------------------------------------------- game --

-- The server's config/DraconicEvolution.cfg, "draconic reactor" section.
-- These are the GTNH values; change them only if your pack differs.
cfg.game = {
    nuggetFuel = 2,              -- awakenedDraconiumFuelValue
    tinyChaos = 36,              -- chaosShardOutputValue (shard = x729 = 26244)
    maxFuel = 524880,            -- maxFuelStorage
    fuelUsageMultiplier = 3035,  -- FuelUsageMultiplier
    linearFuelUsage = false,     -- linearReactorFuelUsage
    outputMultiplier = 1,        -- EnergyOutputMultiplier
}

cfg.timing = {
    poll = 0.25,    -- seconds between reactor reads (safety checks run on each)
    render = 1,     -- seconds between dashboard redraws
}

-- Remembers auto-start on/off and the shard counter across restarts.
cfg.stateFile = "state.dat"
-- Starts, stops and faults are appended here. nil = no file.
cfg.logFile = "reactor.log"

return cfg

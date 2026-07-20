-- User configuration for the pump regulator. This file is NOT overwritten when
-- you re-run `install` (it is marked `?` in the manifest), so your settings and
-- demand survive updates. Edit to taste.

local cfg = {}

-- Pumps are auto-discovered on the network (any gt_machine whose getName() is
-- "projectmodulepumptN"), so there is no pump list to maintain here.

-- Demand: for each gas you want kept in stock,
--   target         = amount (mB) to maintain in the AE2 network (0 = do not pump it)
--   priority       = base importance; higher wins when threads are scarce
--   criticalWeight = per-gas override of cfg.criticalWeight below (pre-filled at
--                    the default; raise it for a gas that must not run dry)
-- Threads are assigned by a score that boosts priority as a tank empties:
--   score = priority * (1 + (criticalWeight - 1) * missingFraction^2)
-- so a nearly-empty low-priority gas can outrank a well-stocked high-priority one
-- (see cfg.criticalWeight below). priority = 0 means "only if threads are spare".
-- Every gas from gases.lua is listed below with target 0 (disabled). Set a
-- target and priority for the gases you want maintained; delete the rest if you
-- like. Grouped by planet to match gases.lua.
cfg.demand = {
    -- Planet 2
    ["Chlorobenzene"]     = { target = 0, priority = 0, criticalWeight = 4 },

    -- Planet 3
    ["Ender Goo"]         = { target = 0, priority = 0, criticalWeight = 4 },
    ["Very Heavy Oil"]    = { target = 0, priority = 0, criticalWeight = 4 },
    ["Lava"]              = { target = 0, priority = 0, criticalWeight = 4 },
    ["Natural Gas"]       = { target = 0, priority = 0, criticalWeight = 4 },

    -- Planet 4
    ["Sulfuric Acid"]     = { target = 0, priority = 0, criticalWeight = 4 },
    ["Molten Iron"]       = { target = 0, priority = 0, criticalWeight = 4 },
    ["Oil"]               = { target = 0, priority = 0, criticalWeight = 4 },
    ["Heavy Oil"]         = { target = 0, priority = 0, criticalWeight = 4 },
    ["Molten Lead"]       = { target = 0, priority = 0, criticalWeight = 4 },
    ["Raw Oil"]           = { target = 0, priority = 0, criticalWeight = 4 },
    ["Light Oil"]         = { target = 0, priority = 0, criticalWeight = 4 },
    ["Carbon Dioxide"]    = { target = 0, priority = 0, criticalWeight = 4 },

    -- Planet 5
    ["Carbon Monoxide"]   = { target = 0, priority = 0, criticalWeight = 4 },
    ["Helium-3"]          = { target = 0, priority = 0, criticalWeight = 4 },
    ["Salt Water"]        = { target = 0, priority = 0, criticalWeight = 4 },
    ["Helium"]            = { target = 0, priority = 0, criticalWeight = 4 },
    ["Liquid Oxygen"]     = { target = 0, priority = 0, criticalWeight = 4 },
    ["Neon"]              = { target = 0, priority = 0, criticalWeight = 4 },
    ["Argon"]             = { target = 0, priority = 0, criticalWeight = 4 },
    ["Krypton"]           = { target = 0, priority = 0, criticalWeight = 4 },
    ["Methane"]           = { target = 0, priority = 0, criticalWeight = 4 },
    ["Hydrogen Sulfide"]  = { target = 0, priority = 0, criticalWeight = 4 },
    ["Ethane"]            = { target = 0, priority = 0, criticalWeight = 4 },

    -- Planet 6
    ["Deuterium"]         = { target = 0, priority = 0, criticalWeight = 4 },
    ["Tritium"]           = { target = 0, priority = 0, criticalWeight = 4 },
    ["Ammonia"]           = { target = 0, priority = 0, criticalWeight = 4 },
    ["Xenon"]             = { target = 0, priority = 0, criticalWeight = 4 },
    ["Ethylene"]          = { target = 0, priority = 0, criticalWeight = 4 },

    -- Planet 7
    ["Hydrofluoric Acid"] = { target = 0, priority = 0, criticalWeight = 4 },
    ["Fluorine"]          = { target = 0, priority = 0, criticalWeight = 4 },
    ["Nitrogen"]          = { target = 0, priority = 0, criticalWeight = 4 },
    ["Oxygen"]            = { target = 0, priority = 0, criticalWeight = 4 },

    -- Planet 8
    ["Hydrogen"]          = { target = 0, priority = 0, criticalWeight = 4 },
    ["Liquid Air"]        = { target = 0, priority = 0, criticalWeight = 4 },
    ["Molten Copper"]     = { target = 0, priority = 0, criticalWeight = 4 },
    ["Unknown Liquid"]    = { target = 0, priority = 0, criticalWeight = 4 },
    ["Distilled Water"]   = { target = 0, priority = 0, criticalWeight = 4 },
    ["Radon"]             = { target = 0, priority = 0, criticalWeight = 4 },
    ["Molten Tin"]        = { target = 0, priority = 0, criticalWeight = 4 },
}

-- Seconds between control cycles. Also the window used to estimate how much a
-- thread will produce (each parallel makes <gas.amount> mB per second).
cfg.sleep = 30

-- Hysteresis: once a gas reaches its target it is considered satisfied and is
-- not pumped again until it drops below (lowWater * target). Prevents a thread
-- from flapping on/off around the target. 0.9 = resume at 90% of target.
cfg.lowWater = 0.9

-- Criticality: how many times more important a gas is when EMPTY versus FULL.
-- With criticalWeight = 4, an empty tank scores 4x its priority and a full one
-- scores 1x; the boost ramps up quadratically, so it stays small until a tank is
-- genuinely low. Raise it to let emptiness override bigger priority gaps; set to
-- 1 to disable criticality and rank purely by priority. Individual gases can
-- override this via a `criticalWeight` field in their demand entry above.
cfg.criticalWeight = 4

-- Coverage floor: how many of the top-scoring needy gases are guaranteed one
-- thread each before the rest are handed out by score. Threads are otherwise
-- allocated score-weighted (score / (threads + 1)), so higher-priority/emptier
-- gases pull more threads.
--   0 = pure priority: a dominant gas takes as many threads as its deficit needs
--       before anything else is served (lower gases can be starved a cycle).
--   1 = guarantee the single most-critical gas a thread, then weight the rest.
--   big (>= number of demanded gases) = spread one thread across as many gases as
--       possible first (the old breadth-first behaviour).
cfg.coverageFloor = 1

-- Safety: when true, the controller only LOGS the allocation it would make and
-- never touches a pump. Flip to false once you have verified the plan in-game.
cfg.dryRun = true

-- Show the full-screen dashboard (needs a GPU + screen). Set to false to run
-- headless with plain text logging instead. Falls back to text automatically if
-- no GPU/screen is present.
cfg.ui = true

-- Dashboard refresh rate in seconds, decoupled from the control cycle above:
-- the screen (clock, spinner, fill bars) repaints this often while pumps are
-- only reallocated every cfg.sleep. Each refresh re-polls AE2 stock, so lower =
-- smoother/live but more frequent AE2 reads. Ignored when running headless.
cfg.uiRefresh = 1

return cfg

-- User configuration for the pump regulator. This file is NOT overwritten when
-- you re-run `install` (it is marked `?` in the manifest), so your settings and
-- demand survive updates. Edit to taste.

local cfg = {}

-- Pumps are auto-discovered on the network (any gt_machine whose getName() is
-- "projectmodulepumptN"), so there is no pump list to maintain here.

-- Demand: for each gas you want kept in stock,
--   target         = amount (mB) to maintain in the AE2 network (0 = do not pump it)
--   priority       = base importance; higher wins when threads are scarce
--   criticalWeight = (optional) per-gas override of cfg.criticalWeight below
-- Threads are assigned by a score that boosts priority as a tank empties:
--   score = priority * (1 + (criticalWeight - 1) * missingFraction^2)
-- so a nearly-empty low-priority gas can outrank a well-stocked high-priority one
-- (see cfg.criticalWeight below). priority = 0 means "only if threads are spare".
-- Every gas from gases.lua is listed below with target 0 (disabled). Set a
-- target and priority for the gases you want maintained; delete the rest if you
-- like. Grouped by planet to match gases.lua.
cfg.demand = {
    -- Planet 2
    ["Chlorobenzene"]     = { target = 0, priority = 0 },

    -- Planet 3
    ["Ender Goo"]         = { target = 0, priority = 0 },
    ["Very Heavy Oil"]    = { target = 0, priority = 0 },
    ["Lava"]              = { target = 0, priority = 0 },
    ["Natural Gas"]       = { target = 0, priority = 0 },

    -- Planet 4
    ["Sulfuric Acid"]     = { target = 0, priority = 0 },
    ["Molten Iron"]       = { target = 0, priority = 0 },
    ["Oil"]               = { target = 0, priority = 0 },
    ["Heavy Oil"]         = { target = 0, priority = 0 },
    ["Molten Lead"]       = { target = 0, priority = 0 },
    ["Raw Oil"]           = { target = 0, priority = 0 },
    ["Light Oil"]         = { target = 0, priority = 0 },
    ["Carbon Dioxide"]    = { target = 0, priority = 0 },

    -- Planet 5
    ["Carbon Monoxide"]   = { target = 0, priority = 0 },
    ["Helium-3"]          = { target = 0, priority = 0 },
    ["Salt Water"]        = { target = 0, priority = 0 },
    ["Helium"]            = { target = 0, priority = 0 },
    ["Liquid Oxygen"]     = { target = 0, priority = 0 },
    ["Neon"]              = { target = 0, priority = 0 },
    ["Argon"]             = { target = 0, priority = 0 },
    ["Krypton"]           = { target = 0, priority = 0 },
    ["Methane"]           = { target = 0, priority = 0 },
    ["Hydrogen Sulfide"]  = { target = 0, priority = 0 },
    ["Ethane"]            = { target = 0, priority = 0 },

    -- Planet 6
    ["Deuterium"]         = { target = 0, priority = 0 },
    ["Tritium"]           = { target = 0, priority = 0 },
    ["Ammonia"]           = { target = 0, priority = 0 },
    ["Xenon"]             = { target = 0, priority = 0 },
    ["Ethylene"]          = { target = 0, priority = 0 },

    -- Planet 7
    ["Hydrofluoric Acid"] = { target = 0, priority = 0 },
    ["Fluorine"]          = { target = 0, priority = 0 },
    ["Nitrogen"]          = { target = 0, priority = 0 },
    ["Oxygen"]            = { target = 0, priority = 0 },

    -- Planet 8
    ["Hydrogen"]          = { target = 0, priority = 0 },
    ["Liquid Air"]        = { target = 0, priority = 0 },
    ["Molten Copper"]     = { target = 0, priority = 0 },
    ["Unknown Liquid"]    = { target = 0, priority = 0 },
    ["Distilled Water"]   = { target = 0, priority = 0 },
    ["Radon"]             = { target = 0, priority = 0 },
    ["Molten Tin"]        = { target = 0, priority = 0 },
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

-- Safety: when true, the controller only LOGS the allocation it would make and
-- never touches a pump. Flip to false once you have verified the plan in-game.
cfg.dryRun = true

-- Show the full-screen dashboard (needs a GPU + screen). Set to false to run
-- headless with plain text logging instead. Falls back to text automatically if
-- no GPU/screen is present.
cfg.ui = true

return cfg

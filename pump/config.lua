-- User configuration for the pump regulator. This file is NOT overwritten when
-- you re-run `install` (it is marked `?` in the manifest), so your settings and
-- demand survive updates. Edit to taste.

local cfg = {}

-- Pumps are auto-discovered on the network (any gt_machine whose getName() is
-- "projectmodulepumptN"), so there is no pump list to maintain here.

-- Demand: for each gas you want kept in stock,
--   target   = amount (mB) to maintain in the AE2 network (0 = do not pump it)
--   priority = higher number wins when there are not enough pumps for everyone
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

-- Optional default "parallels" count (pumping speed, hatch 1 id 0) to set on a
-- pump when it is assigned to a gas. Leave nil to never touch parallels and use
-- whatever each pump was set to manually. A per-gas `parallels` in gases.lua
-- overrides this.
cfg.parallels = nil

-- Seconds between control cycles.
cfg.sleep = 10

-- Hysteresis: once a gas reaches its target it is considered satisfied and is
-- not pumped again until it drops below (lowWater * target). Prevents a pump
-- from flapping on/off around the target. 0.9 = resume at 90% of target.
cfg.lowWater = 0.9

-- Maximum pumps that may be assigned to a single gas. Every needy gas gets one
-- pump first (in priority order); leftover pumps then double up on the highest
-- priority gases, up to this cap. Defaults to "all pumps" if left nil.
cfg.maxPumpsPerGas = nil

-- Safety: when true, the controller only LOGS the allocation it would make and
-- never touches a pump. Flip to false once you have verified the plan in-game.
cfg.dryRun = true

return cfg

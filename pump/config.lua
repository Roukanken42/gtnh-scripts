-- User configuration for the pump regulator. This file is NOT overwritten when
-- you re-run `install` (it is marked `?` in the manifest), so your settings and
-- demand survive updates. Edit to taste.

local cfg = {}

-- Component addresses of the pumps this computer controls. Run `probe` to list
-- connected components and copy the pumping modules' addresses here. Partial
-- (prefix) addresses are fine. Only pumps listed here are ever reconfigured.
cfg.pumps = {
    -- "a1b2c3d4",
}

-- Demand: for each gas you want kept in stock,
--   target   = amount to maintain (in AE2 item count / "drops")
--   priority = higher number wins when there are not enough pumps for everyone
cfg.demand = {
    -- ["Hydrogen"] = { target = 64000, priority = 10 },
    -- ["Helium"]   = { target = 16000, priority = 5  },
    -- ["Nitrogen"] = { target = 8000,  priority = 1  },
}

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

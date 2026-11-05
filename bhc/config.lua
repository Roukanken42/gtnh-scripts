-- User configuration for the Black Hole Compressor controller. This file is NOT
-- overwritten when you re-run `install` (it is marked `?` in the manifest).
-- Run `probe` to find the sides and addresses to put here.

local sides = require("sides")

local cfg = {}

-- Safety: when true the controller tracks the hole and LOGS what it would do,
-- but never inserts an item, never feeds spacetime and never toggles the
-- machine. Flip to false once the log looks right.
cfg.dryRun = true

-- Full-screen dashboard (needs a GPU + screen). false = plain text log.
cfg.ui = true

-- ---------------------------------------------------------------- hardware --

-- The BHC controller, through an Adapter. nil = the only gt_machine on the
-- network, or the first one whose getName() contains "blackhole".
cfg.machine = { address = nil }

-- The transposer. It touches:
--   tankSide       the tank holding spacetime -- the one the stocking hatch
--                  pulls from through ME. Read only: how much is left, and
--                  whether a hold second was paid for.
--   interfaceSide  the ME interface stocking Black Hole Seeds and Collapsers
--   busSide        the BHC input bus the seed/collapser are moved into
-- address = nil uses the only transposer on the network.
cfg.transposer = {
    address = nil,
    tankSide = sides.down,
    interfaceSide = sides.north,
    busSide = sides.south,
}

-- Redstone. Each signal is { address = <redstone component or nil for the
-- primary one>, side = sides.x, color = nil|colors.x for bundled cables }.
cfg.signals = {
    -- IN: on while the crafting net has items waiting for the BHC.
    request = { address = nil, side = sides.west },
    -- IN: a Black Hole Utility Hatch set to PULSE mode. One pulse per machine
    -- second while a hole is open -- this is the script's clock.
    pulse = { address = nil, side = sides.east },
    -- OUT: on = the spacetime hatch (an ME stocking input hatch) is enabled.
    -- Wire it to a redstone cover on the hatch that disables it without a
    -- signal. invert = true if your cover enables it on LOW.
    spacetime = { address = nil, side = sides.up, invert = false },
}

-- Substring of the spacetime fluid's name or label (case-insensitive).
cfg.spacetimeFluid = "spacetime"

-- Item labels as the interface reports them.
cfg.items = { seed = "Black Hole Seed", collapser = "Black Hole Collapser" }

-- Optional: count seeds/collapsers in the whole local ME net instead of only
-- what the interface currently stocks. Address of an me_interface or
-- me_controller component on that net (via an Adapter), or nil.
cfg.meAddress = nil

-- ------------------------------------------------------------------ policy --

-- Holding the hole at a stability = feeding spacetime so it stops decaying.
-- It costs 1 L/s, doubling after every 30 s held -- and that count is per hole,
-- it does NOT reset between holds. Parallels: x2 below 50%, x4 below 20%.
cfg.hold = {
    enabled = true,
    -- Hold stages: hold at `at`% for up to `seconds` (per hole), then let it
    -- decay to the next stage. 19 is the first stability with x4 parallels,
    -- 49 the first with x2. Examples:
    --   { { at = 19, seconds = 300 } }                         x4, up to 5 min
    --   { { at = 49, seconds = 60 }, { at = 19, seconds = 240 } }
    stages = { { at = 19, seconds = 300 } },
    -- Stop holding once one second would cost more than this (L/s). 8 allows
    -- 30 s each at 1, 2, 4 and 8 L/s: 120 s for 450 L.
    maxCost = 8,
    maxSeconds = math.huge,  -- total hold time per hole, over all stages
    maxSpend = math.huge,    -- total spacetime (L) per hole
    -- Only hold while there is something to craft. When the crafting net runs
    -- dry the hole is left to decay and the spacetime is saved.
    onlyWithWork = true,
}

-- Void protection: when the hole is about to go unstable under a running
-- recipe, hold it (whatever the hold limits say) until that recipe finishes.
-- New recipes are blocked meanwhile. Engages at `margin`% stability.
cfg.voidProtection = { enabled = true, margin = 3 }

-- Black Hole Collapser: closes an unstable hole at the next recipe check, so a
-- new one can be opened right away instead of waiting out the 15 minutes.
cfg.collapser = {
    enabled = true,
    -- Only collapse when there is work waiting; otherwise let it close itself.
    onlyWhenRequested = true,
    -- Don't spend a collapser to save less than this many seconds of waiting.
    minSecondsSaved = 60,
}

-- Low-resource protection.
cfg.resources = {
    keepSeeds = 0,            -- never use the last N seeds
    keepCollapsers = 0,       -- never use the last N collapsers
    spacetimeReserve = 0,     -- L only void protection may use
    -- Spacetime that must be in the tank before a hole is opened (on top of
    -- the reserve). "plan" = what the full hold plan above costs (450 L with
    -- the defaults), or a number of L, or 0 to open regardless.
    minSpacetimeToOpen = "plan",
}

-- Recipes. New recipes start only while the hole will outlive them (by hold
-- budget included). Their length is learned from the machine as it runs; until
-- then `defaultSeconds` is assumed.
cfg.recipe = { defaultSeconds = 10, safety = 2 }

-- Treat the request as still on for this many seconds after it drops, so a gap
-- between two batches does not look like "nothing to craft".
cfg.requestHoldSeconds = 5

cfg.timing = {
    pulseTimeout = 2.5,     -- no pulse for this long = the hole has closed
    catalystTimeout = 30,   -- the machine should have taken a seed/collapser by now
    resourcePoll = 10,      -- seconds between seed/collapser counts
}

-- Where the hole's state is saved, so a reboot can pick up an open hole.
cfg.stateFile = "state.dat"

return cfg

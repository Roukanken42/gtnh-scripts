-- User configuration for the power controller. This file is NOT overwritten when
-- you re-run `install` (it is marked `?` in the manifest), so your settings
-- survive updates. Edit to taste.

local cfg = {}

-- ===========================================================================
-- GENERATORS
-- ===========================================================================
-- Each generator (or group of generators wired to one redstone signal) is one
-- entry. The controller switches them with STAGED THRESHOLDS: as the battery
-- level falls, generators turn on in priority order (cheapest first); as it
-- recovers, they turn off in reverse. Each generator has its own on/off band, so
-- cheap base-load generators run most of the time and expensive ones only kick in
-- when the battery is genuinely low.
--
-- Fields:
--   name     display label.
--   side     side of the redstone card/block the signal comes out of:
--            "top","bottom","front","back","left","right" (or a number 0..5).
--   color    OPTIONAL bundled-cable colour ("white".."black", or 0..15). Omit for
--            a plain per-side signal. Use colours to drive many generators from
--            one side via a bundled cable.
--   output   how strong this generator is, in EU/t ("3.2M", "32M", or a number).
--            Used for the display and the "online EU/t" total; it does not affect
--            switching (that is purely the thresholds below).
--   prio     priority / cost rank. LOWER = cheaper = turned on FIRST, off LAST.
--   onBelow  turn ON  when the battery level drops to/below this fraction (0..1).
--   offAbove turn OFF when the battery level rises to/above this fraction (0..1).
--            Keep onBelow < offAbove: the gap is the hysteresis that stops flapping.
--   minOn    OPTIONAL minimum seconds to stay on once started (extra anti-flap).
--
-- Example: a cheap base-load array, a mid diesel bank, and an expensive peaker.
-- As the battery drains: 60% -> LGT on; 35% -> +Diesel; 15% -> +Naquadah.
-- As it fills back up they switch off in reverse. EDIT / DELETE these for your base.
cfg.generators = {
    { name = "LGT array",     side = "top",   output = "3.2M", prio = 1, onBelow = 0.60, offAbove = 0.80, minOn = 30 },
    { name = "Diesel bank",   side = "back",  output = "6M",   prio = 2, onBelow = 0.35, offAbove = 0.65, minOn = 30 },
    { name = "Naquadah",      side = "left",  output = "32M",  prio = 3, onBelow = 0.15, offAbove = 0.45, minOn = 30 },
}

-- ===========================================================================
-- CONTROL SOURCE
-- ===========================================================================
-- What the single energy level (and the dashboard bar) is made of:
--   "auto"     follow the LSC's wireless mode: when wireless is ENABLED the pool
--              fills/drains the LSC, so the level is LSC stored + wireless pool;
--              otherwise it is the local LSC alone. (Recommended.)
--   "lsc"      always the local LSC only.
--   "wireless" always LSC + wireless pool.
cfg.source = "auto"

-- Energy "full" reference for the level/bar (100%), which the generator
-- onBelow/offAbove fractions apply to. One value for whatever the level is made
-- of (per cfg.source above):
--   wireless off -> stored / max
--   wireless on  -> (LSC stored + wireless pool) / max
-- Leave nil to use the LSC's real capacity (100% = physically full battery). Set
-- an EU string with an SI suffix ("500T", "1E" =1e18, "10E") to treat a smaller
-- amount as "full" -- handy when the real capacity is so large the true % is
-- always tiny, and effectively required when wireless is on (the pool has no
-- real capacity to fall back on).
cfg.max = nil

-- ===========================================================================
-- TIMING & SAFETY
-- ===========================================================================
-- Seconds between control cycles (how often generators are re-evaluated and the
-- hardware driven).
cfg.sleep = 5

-- Seconds of history the net flow is measured over when WIRELESS is on: the
-- change in LSC + wireless total across this window. The LSC's own averages
-- cannot be used then (the 5-minute wireless rebalance counts as its in/out).
-- Longer is steadier, shorter reacts faster. nil = 60.
cfg.netWindow = 60

-- Dashboard repaint rate in seconds, decoupled from the control cycle: the screen
-- re-reads the LSC and repaints this often (each read is a single
-- getSensorInformation() call) while switching decisions are only made every
-- cfg.sleep. Floored internally so it can't busy-loop.
cfg.uiRefresh = 1

-- Safety: when true, the controller only LOGS the switches it WOULD make and
-- never touches redstone. Flip to false once you have verified the plan in-game.
cfg.dryRun = true

-- Show the full-screen dashboard (needs a GPU + screen). Set to false to run
-- headless with plain text logging. Falls back to text automatically if no
-- GPU/screen is present.
cfg.ui = true

return cfg

-- User configuration for the DTPF passive-recipe controller. This file is NOT
-- overwritten when you re-run `install` (it is marked `?` in the manifest).
-- Run `probe` to find the addresses and sides to put here.

local cfg = {}

-- Safety: when true the controller reads everything and LOGS which filters it
-- would set, but never writes a storage bus. Flip to false once it looks right.
cfg.dryRun = true

-- Full-screen dashboard (needs a GPU + screen). false = plain text log.
cfg.ui = true

-- ---------------------------------------------------------------- hardware --

-- The DTPF controllers, each through an Adapter. nil = every gt_machine whose
-- getName() contains `nameMatch` ("multimachine.plasmaforge").
cfg.forges = { addresses = nil, nameMatch = "plasmaforge" }

-- The stocker: the inventory AE keeps stocked with the passive ingredients, read
-- through a transposer. nil = the one side of the one transposer that has both
-- slots and tanks. `probe sides` shows what each side is.
cfg.stocker = { transposer = nil, side = nil }

-- The storage buses, each { address = <cable component>, side = <0..5> }. The
-- component is the CABLE the bus sits on (through an Adapter touching it), and
-- `side` is the side of that cable the bus is on. `probe buses` lists them all.
--   items     item storage bus on the stocker      (nil = the only one there is)
--   fluids    fluid storage bus on the stocker     (nil = the only fluid bus
--                                                   that is not `catalyst`)
--   catalyst  fluid storage bus on the main-net interface with the catalysts.
--             REQUIRED: two fluid buses look the same to the script.
-- Give the item bus its own cable block: on a cable that also carries a fluid
-- storage bus, OpenComputers routes every call to the fluid driver and the
-- item bus cannot be reached (README.md, Hardware).
cfg.buses = {
    items = nil,
    fluids = nil,
    catalyst = nil,   -- TODO: e.g. { address = "1a2b3c4d", side = 4 }
}

-- Any ME component on the main net (me_interface, me_controller or
-- fluid_interface, through an Adapter): products and catalysts are counted
-- there. nil = the only such component.
cfg.mainnet = { address = nil }

-- ----------------------------------------------------------------- products --

-- What to make. `target` is the stock (L, on the main net) the controller aims
-- for. `max` (optional) is a hard ceiling it will not make more beyond, except
-- to keep the array busy when nothing else is runnable (selection.keepBusy).
--
-- `priority` (higher = more important, default 1): a product's own target is
-- only worked on while no MORE important demand is short and runnable.
-- Demand a product inherits from what is made from it keeps the priority of
-- that consumer: shirabon short by 1440 L asks spacetime for 2880 L at
-- shirabon's priority, and spacetime passes that on to infinity at the same
-- priority. So a low-priority infinity is still made at full urgency to feed
-- the others, and only tops up its own stock when they are fine.
-- Ties (same priority and fill) go to the product listed first.
-- See README.md, "Which product".
cfg.products = {
    { name = "shirabon",  target = 50000,   priority = 2 },
    { name = "spacetime", target = 100000,  priority = 2 },
    { name = "hypogen",   target = 200000,  priority = 2 },
    -- Also made elsewhere: the DTPF is just an extra passive source.
    { name = "infinity",  target = 1000000, priority = 1 },
}

-- ---------------------------------------------------------------- catalysts --

-- Catalysts passive recipes may use. The best runnable variant of a product
-- is picked; a catalyst that is missing here is never exposed.
--   crude, prosaic, resplendent, exotic, stellar
cfg.catalysts = {
    allowed = { "prosaic", "resplendent", "exotic", "stellar" },
    -- Never let passive recipes take a catalyst below this much (L) on the main
    -- net, so the AE-driven active recipes always have theirs.
    reserve = { crude = 0, prosaic = 0, resplendent = 0, exotic = 0, stellar = 0 },
    -- Per product, a narrower list, e.g. infinity = { "exotic", "resplendent" }
    -- to keep stellar for hypogen.
    perProduct = {},
}

-- Variants never to run (ids from recipes.lua). The Awakened-coil infinity
-- recipe gives 144 L per Infinity Catalyst instead of 9216 L: it only makes
-- sense while your coils are below Hypogen, so it is off by default.
cfg.disabledVariants = { "inf_t3", "inf_t3_comb" }

-- Coil heat the variants are checked against. "min" = the coldest formed DTPF
-- (they share one input, so every machine must be able to run the pick), or a
-- number in K to override.
cfg.heat = "min"

-- Optional EU/t ceiling: variants whose base EU/t is above it are skipped.
cfg.maxEUt = nil

-- Convergence: a recipe WITHOUT catalyst (spacetime, shirabon) still takes
-- the catalyst type chosen in each DTPF's GUI for its perfect overclocks. Set
-- that type here ("exotic", ...) and the controller exposes it with those
-- recipes. nil = expose no catalyst with them.
cfg.convergence = { catalystForNoCatalystRecipes = nil }

-- ---------------------------------------------------------------- selection --

cfg.selection = {
    -- A product is runnable when the stocker holds at least this many
    -- batches of every input (and the main net that much catalyst).
    minBatches = 1,
    -- Stay on a product at least this long (s) while it stays runnable...
    minDwell = 120,
    -- ...and after that until another product's fill is lower by this much
    -- (0.05 = 5 % of its effective target).
    switchMargin = 0.05,
    -- When every runnable product is at its `max`, keep making the lowest one
    -- anyway: an idle DTPF loses 100 ticks of running time per tick.
    keepBusy = true,
}

-- What goes into a filter when nothing may come through: an empty storage
-- bus filter lets everything through. Anything no DTPF recipe can be made
-- from alone works.
cfg.blocker = {
    item = { name = "minecraft:bedrock", damage = 0 },
    fluid = { name = "lava" },
}

-- Extra match keys per material (see recipes.lua R.materials), e.g.
--   cfg.materials = { precious = { "molten.preciousmetalsalloy" } }
cfg.materials = {}

cfg.timing = {
    machines = 2,   -- s between DTPF reads
    stock = 5,      -- s between stocker + main net reads (and decisions)
}

return cfg

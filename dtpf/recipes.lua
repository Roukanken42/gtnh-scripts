-- What the game gives us: the DTPF recipes this controller can run passively,
-- the five catalysts, and the coil heats that gate them. Pure data.
--
-- Read from the GTNH 2.9.0 sources (DreamAssemblerXXL manifest 2.9.0):
--   NewHorizonsCoreMod 2.9.99   gthandler/recipes/DTPFRecipes.java  infinity,
--                               hypogen, spacetime; DTPFCalculator.java for the
--                               computed infinity amounts
--   GT5-Unofficial 5.09.54.265  goodgenerator/loader/RecipeLoader2.java  shirabon;
--                               MTEPlasmaForge.java  catalysts, discount, heat
-- If a pack update changes a recipe, fix the numbers here. Variants are listed
-- best first; the controller runs the first one it can.
--
-- Amounts are L for fluids and items for items. `amount = 0` marks an item that
-- is not consumed: one must be present, and it stays in the stocker.

local R = {}

-- Coil heat (K), as the DTPF reports it on its scanner.
R.heat = { awakened = 10800, infinity = 11700, hypogen = 12600, eternal = 13500 }

-- Catalyst tiers, low to high. `key` is how config.lua names them.
R.catalysts = {
    { key = "crude",       tier = 1, mat = "dtcc" },
    { key = "prosaic",     tier = 2, mat = "dtpc" },
    { key = "resplendent", tier = 3, mat = "dtrc" },
    { key = "exotic",      tier = 4, mat = "dtec" },
    { key = "stellar",     tier = 5, mat = "dtsc" },
}
R.catalystByKey = {}
for _, c in ipairs(R.catalysts) do R.catalystByKey[c.key] = c end

-- How a stack is recognised. `keys` are compared with a stack's name AND its
-- label after plan.norm(): lower case, only letters and digits, a leading
-- "molten" dropped. A key can therefore be a registry name too
-- ("gregtech:gt.integrated_circuit" -> gregtechgtintegratedcircuit). So "Molten Infinity" and "molten.infinity" both become
-- "infinity", while "Molten Cosmic Neutronium" (cosmicneutronium) does not
-- match "neutronium". `damage` must also match when given (circuits).
-- `probe stock` prints the normalised keys of everything in the stocker; add
-- a key in cfg.materials if one of yours is not recognised.
R.materials = {
    -- products
    infinity   = { kind = "fluid", keys = { "infinity" } },
    hypogen    = { kind = "fluid", keys = { "hypogen" } },
    spacetime  = { kind = "fluid", keys = { "spacetime" } },
    shirabon   = { kind = "fluid", keys = { "shirabon" } },
    -- other fluids
    neutronium = { kind = "fluid", keys = { "neutronium" } },
    quantum    = { kind = "fluid", keys = { "quantum" } },
    residue    = { kind = "fluid", keys = { "dimensionallytranscendentresidue" } },
    oganesson  = { kind = "fluid", keys = { "metastableoganesson" } },
    precious   = { kind = "fluid", keys = { "preciousmetalsalloy", "preciousmetalalloy" } },
    -- catalysts
    dtcc = { kind = "fluid", keys = { "exciteddtcc", "exciteddimensionallytranscendentcrudecatalyst" } },
    dtpc = { kind = "fluid", keys = { "exciteddtpc", "exciteddimensionallytranscendentprosaiccatalyst" } },
    dtrc = { kind = "fluid", keys = { "exciteddtrc", "exciteddimensionallytranscendentresplendentcatalyst" } },
    dtec = { kind = "fluid", keys = { "exciteddtec", "exciteddimensionallytranscendentexoticcatalyst" } },
    dtsc = { kind = "fluid", keys = { "exciteddtsc", "exciteddimensionallytranscendentstellarcatalyst" } },
    -- items
    infinityCatalyst = { kind = "item", keys = { "infinitycatalyst" } },       -- Avaritia:Resource:5
    infinityComb     = { kind = "item", keys = { "infinitycomb" } },           -- gregtech:gt.comb
    tesseract        = { kind = "item", keys = { "energisedtesseract" } },
    hypervisor       = { kind = "item", keys = { "hypervisormatrixfusion" } },  -- GT++ Compressed_Fusion_Reactor
    hic5             = { kind = "item", keys = { "hicomputationstationmkvfinaltype" } }, -- GoodGenerator HiC_T5
    -- damage = circuit number. Matched by registry name: since 2.9 the label
    -- carries the number ("Programmed Circuit 4").
    circuit          = { kind = "item", keys = { "gregtech:gt.integrated_circuit", "programmedcircuit" } },
}

-- The four products, in the order config.lua lists them by default.
R.products = { "infinity", "hypogen", "spacetime", "shirabon" }

local H = R.heat
local function fl(mat, amount) return { mat = mat, amount = amount } end
local function it(mat, amount, damage) return { mat = mat, amount = amount, damage = damage } end
local function circ(n) return it("circuit", 0, n) end

-- id         unique name, for cfg.disabledVariants and the log
-- extra      an optional bonus variant (combs): used when its extra input is
--            there, but never blamed when explaining why a product cannot run
-- catalyst   catalyst key, or nil (consumed amount in `catalystAmount`)
-- heat       coil heat needed
-- eut        base EU/t (before overclocks)
-- ticks      base duration
-- inputs     what must be in the stocker, besides the catalyst
-- outputs    what comes out, per batch (residue included)
R.variants = {
    infinity = {
        -- DTPFCalculator: parallel 64, catalyst tiers 3..5, EU/t divided by 2,
        -- calculateNonEBFRecipe(32M, 10000). Combs: 15% less catalyst, half time.
        { id = "inf_t5_comb", extra = true, catalyst = "stellar", catalystAmount = 9667, heat = H.eternal,
          eut = 409600000, ticks = 625,
          inputs = { it("infinityCatalyst", 4), it("infinityComb", 1), circ(3) },
          outputs = { infinity = 36864, residue = 19334 } },
        { id = "inf_t5", catalyst = "stellar", catalystAmount = 11373, heat = H.eternal,
          eut = 409600000, ticks = 1250,
          inputs = { it("infinityCatalyst", 4), circ(4) },
          outputs = { infinity = 36864, residue = 22746 } },
        { id = "inf_t4_comb", extra = true, catalyst = "exotic", catalystAmount = 22307, heat = H.eternal,
          eut = 204800000, ticks = 1250,
          inputs = { it("infinityCatalyst", 2), it("infinityComb", 1), circ(3) },
          outputs = { infinity = 18432, residue = 22307 } },
        { id = "inf_t4", catalyst = "exotic", catalystAmount = 26243, heat = H.eternal,
          eut = 204800000, ticks = 2500,
          inputs = { it("infinityCatalyst", 2), circ(4) },
          outputs = { infinity = 18432, residue = 26243 } },
        { id = "inf_t35_comb", extra = true, catalyst = "resplendent", catalystAmount = 50092, heat = H.hypogen,
          eut = 102400000, ticks = 2500,
          inputs = { it("infinityCatalyst", 1), it("infinityComb", 1), circ(2) },
          outputs = { infinity = 9216, residue = 25046 } },
        { id = "inf_t35", catalyst = "resplendent", catalystAmount = 58932, heat = H.hypogen,
          eut = 102400000, ticks = 5000,
          inputs = { it("infinityCatalyst", 1), circ(5) },
          outputs = { infinity = 9216, residue = 29466 } },
        -- The Awakened-coil recipe: 144 L per Infinity Catalyst instead of 9216.
        { id = "inf_t3_comb", extra = true, catalyst = "resplendent", catalystAmount = 782, heat = H.awakened,
          eut = 1600000, ticks = 19,
          inputs = { it("infinityCatalyst", 1), it("infinityComb", 1), circ(3) },
          outputs = { infinity = 144, residue = 391 } },
        { id = "inf_t3", catalyst = "resplendent", catalystAmount = 920, heat = H.awakened,
          eut = 1600000, ticks = 39,
          inputs = { it("infinityCatalyst", 1), circ(4) },
          outputs = { infinity = 144, residue = 460 } },
    },
    hypogen = {
        { id = "hyp_v4", catalyst = "stellar", catalystAmount = 1000, heat = H.eternal,
          eut = 2000000000, ticks = 1500,
          inputs = { it("hypervisor", 0), fl("neutronium", 11520), fl("quantum", 5760), fl("infinity", 1440) },
          outputs = { hypogen = 11520, residue = 2000 } },
        { id = "hyp_v3", catalyst = "exotic", catalystAmount = 1000, heat = H.eternal,
          eut = 1600000000, ticks = 1500,
          inputs = { it("hypervisor", 0), fl("neutronium", 5760), fl("quantum", 5760), fl("infinity", 1440) },
          outputs = { hypogen = 5760, residue = 1000 } },
        { id = "hyp_v2", catalyst = "resplendent", catalystAmount = 1000, heat = H.hypogen,
          eut = 1200000000, ticks = 1500,
          inputs = { fl("neutronium", 5760), fl("quantum", 5760), fl("infinity", 1440) },
          outputs = { hypogen = 2880, residue = 500 } },
        { id = "hyp_v1", catalyst = "prosaic", catalystAmount = 1000, heat = H.infinity,
          eut = 800000000, ticks = 1500,
          inputs = { fl("hypogen", 144), fl("neutronium", 5760), fl("quantum", 5760), fl("infinity", 1440) },
          outputs = { hypogen = 1584, residue = 250 } },
    },
    spacetime = {
        { id = "st_v2", heat = H.eternal, eut = 2000000000, ticks = 400,
          inputs = { it("tesseract", 1), it("hypervisor", 0), fl("residue", 5000), fl("infinity", 1152) },
          outputs = { spacetime = 576 } },
        { id = "st_v1", heat = H.hypogen, eut = 1000000000, ticks = 800,
          inputs = { it("tesseract", 1), fl("residue", 10000), fl("infinity", 2304), fl("hypogen", 1152) },
          outputs = { spacetime = 144 } },
    },
    shirabon = {
        { id = "sh_v1", heat = H.eternal, eut = 1500000000, ticks = 200,
          inputs = { it("hic5", 0), fl("oganesson", 1152), fl("precious", 2304), fl("spacetime", 288),
                     fl("residue", 5000) },
          outputs = { shirabon = 144 } },
    },
}

return R

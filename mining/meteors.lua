-- Space-mining meteor (asteroid) data, extracted from GTNH 2.8.4.
--
-- These are the BASE (pre-scaling) values straight from the recipe source. Size,
-- duration and EU/t depend on the drone tier you actually use; compute those on
-- the fly with meteors.scale(m, tier). Yields are relative chance weights by
-- oredict material -- the actual output amounts depend on the module
-- configuration, so only the distribution lives here. The weights usually sum to
-- ~10000 but not always (e.g. iron 9000, gem 10750), matching the source.
--
-- Per entry:
--   name         asteroid id (recipe name)
--   drones       {startMK, endMK}  drone tiers that can mine it (1..13 = MK-I..XIII)
--   module       minimum mining-module tier (1..3 = T1/T2/T3, UV/UHV/UEV)
--   distance     {min, max}        constant across drone tiers
--   size         {min, max}        BASE; per-tier below
--   computation  required computation per second (constant)
--   duration     BASE ticks; per-tier below
--   eut          BASE EU/t; per-tier below (eutScales=false keeps it constant)
--   eutScales    whether EU/t scales with drone tier
--   weight       recipe weight (meteor rarity; constant)
--   orePrefix    oredict prefix for yields ("oreEndstone"/"ore"/"dust"); nil = items only
--   yield        { { mat = <material>, chance = <n> } | { item = <id>, chance = <n> }, ... }
--                oredict item = orePrefix .. mat  (see meteors.oredict)
--   conditional  present only if the meteor needs another mod loaded
--
-- Per-drone-tier scaling (k = tier - startMK; see meteors.scale):
--   size     = { min + 2^k - 1, max + 2^k - 1 }
--   duration = ceil(duration / sqrt(k + 1))
--   eut      = eutScales and ceil(eut * sqrt(k + 1)) or eut
-- EU/t bases are TierEU.RECIPE_x = GTValues.VP[x] = V[x]*30/32:
--   EV=1920  IV=7680  LuV=30720  ZPM=122880  UV=491520  UEV=7864320
--
-- ===========================================================================
-- HOW TO REGENERATE for a future GTNH version (current: 2.8.4 / gregtech
-- 5.09.51.482). The data is hardcoded in the GregTech jar (the GTNH-Intergalactic
-- mod ships inside it), class gtnhintergalactic.recipe.SpaceMiningRecipes.
--   1. Find the gregtech jar in the instance's mods/ folder:
--        grep -l MiningDrone .minecraft/mods/*.jar
--   2. Extract + decompile the recipe classes (needs a JDK + a decompiler; CFR:
--        curl -sL -o cfr.jar https://github.com/leibnitz27/cfr/releases/download/0.152/cfr-0.152.jar
--        unzip -o <gregtech.jar> 'gtnhintergalactic/recipe/SpaceMining*.class' \
--                                 'gtnhintergalactic/item/ItemMiningDrones*.class'
--        java -jar cfr.jar gtnhintergalactic/recipe/SpaceMiningRecipes.class --outputdir out
--   3. addAsteroids() has one addRecipesToDrones(...) call per meteor. Arg order:
--        (name, itemInputs, fluidInputs, chances[], ores[]|outputs[], [orePrefix],
--         minSize, maxSize, minDist, maxDist, computation, minModuleTier,
--         duration, EUt, startDroneTier, endDroneTier, weight)
--      Two overloads: the Materials[]+OrePrefixes one scales EU/t up per tier
--      (eutScales=true); the ItemStack[] one keeps EU/t flat (eutScales=false).
--   4. Drone tier = DroneTiers ordinal (0-based) + 1 = MK level (1..13 here).
--      Confirm DroneTiers/DroneMaterials in ItemMiningDrones.java still match.
--   5. EU/t base = TierEU.RECIPE_x = GTValues.VP[x] (V[x]*30/32); V/VP in
--      gregtech.api.enums.GTValues.
-- NOTE: cross-mod material names (bartworks/goodgenerator/GT++) are taken from
-- the code identifier and may need their exact oredict verified.
-- ===========================================================================

local meteors = {}

-- Ore "chance" is a relative weight (see header); values are the source weights.
meteors.list = {
    { name = "coalAsteroid", drones = { 1, 7 }, module = 1, distance = { 1, 40 }, size = { 30, 120 },
      computation = 20, duration = 200, eut = 1920, eutScales = true, weight = 200, orePrefix = "oreEndstone",
      yield = { { mat = "Coal", chance = 7000 }, { mat = "Lignite", chance = 1000 }, { mat = "Graphite", chance = 2000 } } },

    { name = "saltAsteroid", drones = { 1, 5 }, module = 1, distance = { 1, 250 }, size = { 30, 120 },
      computation = 20, duration = 200, eut = 1920, eutScales = true, weight = 300, orePrefix = "oreEndstone",
      yield = { { mat = "Salt", chance = 4000 }, { mat = "RockSalt", chance = 2000 }, { mat = "Saltpeter", chance = 4000 } } },

    { name = "ironAsteroid", drones = { 1, 7 }, module = 1, distance = { 1, 180 }, size = { 30, 150 },
      computation = 10, duration = 200, eut = 1920, eutScales = true, weight = 600, orePrefix = "oreEndstone",
      yield = { { mat = "Iron", chance = 4000 }, { mat = "Gold", chance = 2000 }, { mat = "Magnetite", chance = 1000 },
                { mat = "Pyrite", chance = 1000 }, { mat = "BasalticMineralSand", chance = 500 }, { mat = "GraniticMineralSand", chance = 500 } } },

    { name = "copperAsteroid", drones = { 1, 6 }, module = 1, distance = { 3, 12 }, size = { 30, 150 },
      computation = 10, duration = 200, eut = 1920, eutScales = true, weight = 500, orePrefix = "oreEndstone",
      yield = { { mat = "Copper", chance = 5000 }, { mat = "Chalcopyrite", chance = 3000 }, { mat = "Malachite", chance = 2000 } } },

    { name = "tinAsteroid", drones = { 1, 5 }, module = 1, distance = { 2, 100 }, size = { 50, 200 },
      computation = 10, duration = 50, eut = 7680, eutScales = true, weight = 400, orePrefix = "oreEndstone",
      yield = { { mat = "Cassiterite", chance = 2000 }, { mat = "CassiteriteSand", chance = 1500 }, { mat = "Tin", chance = 6000 }, { mat = "Asbestos", chance = 500 } } },

    { name = "aluminiumAsteroid", drones = { 2, 4 }, module = 1, distance = { 5, 20 }, size = { 10, 20 },
      computation = 20, duration = 50, eut = 7680, eutScales = true, weight = 120, orePrefix = "oreEndstone",
      yield = { { mat = "Aluminium", chance = 5000 }, { mat = "Bauxite", chance = 3500 }, { mat = "Rutile", chance = 1500 } } },

    { name = "nickelAsteroid", drones = { 1, 5 }, module = 1, distance = { 5, 20 }, size = { 20, 40 },
      computation = 20, duration = 50, eut = 7680, eutScales = true, weight = 170, orePrefix = "oreEndstone",
      yield = { { mat = "Nickel", chance = 4000 }, { mat = "Pentlandite", chance = 3000 }, { mat = "Garnierite", chance = 3000 } } },

    { name = "chromeAsteroid", drones = { 2, 6 }, module = 1, distance = { 10, 20 }, size = { 16, 32 },
      computation = 40, duration = 50, eut = 30720, eutScales = true, weight = 100, orePrefix = "oreEndstone",
      yield = { { mat = "Chrome", chance = 5000 }, { mat = "Ruby", chance = 3000 }, { mat = "Chromite", chance = 2000 } } },

    { name = "platlineOreAsteroid", drones = { 3, 7 }, module = 1, distance = { 10, 50 }, size = { 20, 40 },
      computation = 60, duration = 50, eut = 30720, eutScales = true, weight = 130, orePrefix = "oreEndstone",
      yield = { { mat = "Platinum", chance = 6000 }, { mat = "Palladium", chance = 2000 }, { mat = "Iridium", chance = 1500 }, { mat = "Osmium", chance = 500 } } },

    { name = "gemAsteroid", drones = { 1, 6 }, module = 1, distance = { 17, 40 }, size = { 30, 160 },
      computation = 60, duration = 100, eut = 30720, eutScales = true, weight = 180, orePrefix = "oreEndstone",
      yield = { { mat = "Ruby", chance = 1500 }, { mat = "Emerald", chance = 1500 }, { mat = "Sapphire", chance = 1500 },
                { mat = "GreenSapphire", chance = 1500 }, { mat = "Diamond", chance = 750 }, { mat = "Opal", chance = 750 },
                { mat = "Amethyst", chance = 750 }, { mat = "Topaz", chance = 1000 }, { mat = "BlueTopaz", chance = 500 },
                { mat = "Bauxite", chance = 500 }, { mat = "Vinteum", chance = 400 }, { mat = "NetherStar", chance = 100 } } },

    { name = "indiumAsteroid", drones = { 5, 10 }, module = 2, distance = { 50, 90 }, size = { 30, 120 },
      computation = 120, duration = 500, eut = 30720, eutScales = true, weight = 170, orePrefix = "oreEndstone",
      yield = { { mat = "Indium", chance = 6000 }, { mat = "Sphalerite", chance = 2000 }, { mat = "Zinc", chance = 1000 }, { mat = "Cadmium", chance = 1000 } } },

    { name = "thaumiumAsteroid", drones = { 3, 6 }, module = 1, distance = { 10, 70 }, size = { 20, 50 },
      computation = 120, duration = 600, eut = 30720, eutScales = true, weight = 150, orePrefix = "dust",
      yield = { { mat = "Thaumium", chance = 6000 }, { mat = "Void", chance = 4000 } } },

    { name = "basicMagicAsteroid", drones = { 3, 6 }, module = 1, distance = { 8, 24 }, size = { 24, 60 },
      computation = 120, duration = 100, eut = 30720, eutScales = true, weight = 200, orePrefix = "oreEndstone",
      yield = { { mat = "InfusedGold", chance = 3500 }, { mat = "Shadow", chance = 3500 }, { mat = "InfusedAir", chance = 500 },
                { mat = "InfusedEarth", chance = 500 }, { mat = "InfusedFire", chance = 500 }, { mat = "InfusedWater", chance = 500 },
                { mat = "InfusedEntropy", chance = 500 }, { mat = "InfusedOrder", chance = 500 } } },

    { name = "niobiumAsteroid", drones = { 5, 9 }, module = 1, distance = { 30, 160 }, size = { 30, 120 },
      computation = 120, duration = 500, eut = 30720, eutScales = true, weight = 160, orePrefix = "oreEndstone",
      yield = { { mat = "Niobium", chance = 3000 }, { mat = "Quantium", chance = 2000 }, { mat = "Ytterbium", chance = 1500 }, { mat = "Yttrium", chance = 3500 } } },

    { name = "quartzAsteroid", drones = { 2, 7 }, module = 1, distance = { 20, 120 }, size = { 20, 80 },
      computation = 50, duration = 500, eut = 7680, eutScales = true, weight = 230, orePrefix = "oreEndstone",
      yield = { { mat = "Quartzite", chance = 3000 }, { mat = "CertusQuartz", chance = 2250 }, { mat = "NetherQuartz", chance = 2250 }, { mat = "Vanadium", chance = 2500 } } },

    { name = "lutetiumAsteroid", drones = { 5, 9 }, module = 1, distance = { 40, 240 }, size = { 20, 80 },
      computation = 90, duration = 500, eut = 30720, eutScales = true, weight = 100, orePrefix = "oreEndstone",
      yield = { { mat = "Tellurium", chance = 1500 }, { mat = "Thulium", chance = 1000 }, { mat = "Tantalum", chance = 1500 }, { mat = "Lutetium", chance = 500 }, { mat = "Redstone", chance = 5500 } } },

    { name = "siliconAsteroid", drones = { 3, 6 }, module = 2, distance = { 50, 250 }, size = { 20, 80 },
      computation = 60, duration = 500, eut = 30720, eutScales = true, weight = 200, orePrefix = "oreEndstone",
      yield = { { mat = "Mica", chance = 2000 }, { mat = "Silicon", chance = 4500 }, { mat = "SiliconSG", chance = 2500 } } },

    { name = "phosphateAsteroid", drones = { 5, 11 }, module = 1, distance = { 60, 250 }, size = { 20, 150 },
      computation = 60, duration = 500, eut = 30720, eutScales = true, weight = 150, orePrefix = "oreEndstone",
      yield = { { mat = "Phosphate", chance = 4500 }, { mat = "TricalciumPhosphate", chance = 2500 }, { mat = "Sulfur", chance = 3000 } } },

    { name = "leadAsteroid", drones = { 1, 8 }, module = 1, distance = { 5, 150 }, size = { 30, 100 },
      computation = 20, duration = 500, eut = 1920, eutScales = true, weight = 220, orePrefix = "oreEndstone",
      yield = { { mat = "Lead", chance = 3000 }, { mat = "Arsenic", chance = 2500 }, { mat = "Barium", chance = 2500 }, { mat = "Lepidolite", chance = 2000 } } },

    { name = "adamantiumAsteroid", drones = { 4, 7 }, module = 1, distance = { 5, 120 }, size = { 30, 120 },
      computation = 20, duration = 500, eut = 1920, eutScales = true, weight = 300, orePrefix = "oreEndstone",
      yield = { { mat = "Adamantium", chance = 2500 }, { mat = "Bismuth", chance = 2000 }, { mat = "Antimony", chance = 2000 }, { mat = "Gallium", chance = 2000 }, { mat = "Lithium", chance = 1500 } } },

    { name = "tungstenTitaniumAsteroid", drones = { 1, 6 }, module = 1, distance = { 60, 200 }, size = { 30, 70 },
      computation = 120, duration = 500, eut = 30720, eutScales = true, weight = 100, orePrefix = "oreEndstone",
      yield = { { mat = "Tungsten", chance = 3000 }, { mat = "Titanium", chance = 3000 }, { mat = "Neodymium", chance = 2000 }, { mat = "Molybdenum", chance = 1500 }, { mat = "Tungstate", chance = 500 } } },

    { name = "blueAsteroid", drones = { 3, 8 }, module = 1, distance = { 20, 200 }, size = { 10, 50 },
      computation = 60, duration = 500, eut = 7680, eutScales = true, weight = 250, orePrefix = "oreEndstone",
      yield = { { mat = "Lapis", chance = 6000 }, { mat = "Calcite", chance = 2000 }, { mat = "Lazurite", chance = 1000 }, { mat = "Sodalite", chance = 1000 } } },

    { name = "aluminiumLanthlineAsteroid", drones = { 2, 7 }, module = 1, distance = { 40, 120 }, size = { 10, 80 },
      computation = 60, duration = 500, eut = 7680, eutScales = true, weight = 250, orePrefix = "oreEndstone",
      yield = { { mat = "Aluminium", chance = 3500 }, { mat = "Bauxite", chance = 1500 }, { mat = "Monazite", chance = 2500 }, { mat = "Bastnasite", chance = 2500 } } },

    -- GT++ ores (getOre, "ore" prefix). Verify exact oredict names against GT++.
    { name = "evergladesAsteroid", drones = { 7, 9 }, module = 1, distance = { 110, 230 }, size = { 10, 20 },
      computation = 200, duration = 500, eut = 7680, eutScales = false, weight = 100, orePrefix = "ore",
      yield = { { mat = "Koboldite", chance = 600 }, { mat = "Crocoite", chance = 400 }, { mat = "GadoliniteY", chance = 1500 },
                { mat = "Lepersonnite", chance = 1500 }, { mat = "Zircon", chance = 1000 }, { mat = "Lautarite", chance = 400 },
                { mat = "Honeaite", chance = 1000 }, { mat = "Alburnite", chance = 600 }, { mat = "RareEarthLow", chance = 1000 },
                { mat = "RareEarthMid", chance = 1000 }, { mat = "RareEarthHigh", chance = 1000 } } },

    { name = "draconicAsteroid", drones = { 6, 9 }, module = 2, distance = { 60, 200 }, size = { 15, 60 },
      computation = 360, duration = 600, eut = 30720, eutScales = true, weight = 190, orePrefix = "oreEndstone",
      yield = { { mat = "Draconium", chance = 6500 }, { mat = "DraconiumAwakened", chance = 2500 }, { mat = "ElectrumFlux", chance = 1000 } } },

    { name = "cheeseAsteroid", drones = { 5, 13 }, module = 2, distance = { 90, 200 }, size = { 1, 30 },
      computation = 240, duration = 1000, eut = 122880, eutScales = true, weight = 10, orePrefix = "oreEndstone",
      yield = { { mat = "Cheese", chance = 10000 } } },

    { name = "arditeCobaltAsteroid", drones = { 4, 9 }, module = 1, distance = { 30, 100 }, size = { 20, 90 },
      computation = 180, duration = 1000, eut = 7680, eutScales = true, weight = 150, orePrefix = "ore",
      yield = { { mat = "Cobalt", chance = 3750 }, { mat = "Ardite", chance = 3750 }, { mat = "Manyullyn", chance = 2500 } } },

    { name = "europiumAsteroid", drones = { 7, 13 }, module = 2, distance = { 40, 60 }, size = { 40, 120 },
      computation = 240, duration = 1000, eut = 122880, eutScales = true, weight = 150, orePrefix = "oreEndstone",
      yield = { { mat = "Ledox", chance = 4000 }, { mat = "CallistoIce", chance = 4000 }, { mat = "Borax", chance = 1500 }, { mat = "Europium", chance = 500 } } },

    { name = "cosmicAsteroid", drones = { 7, 13 }, module = 2, distance = { 60, 100 }, size = { 10, 70 },
      computation = 240, duration = 500, eut = 491520, eutScales = true, weight = 170, orePrefix = "oreEndstone",
      yield = { { mat = "CosmicNeutronium", chance = 2500 }, { mat = "Neutronium", chance = 2500 }, { mat = "BlackPlutonium", chance = 2500 }, { mat = "Bedrockium", chance = 2500 } } },

    { name = "infinityCatalystAsteroid", drones = { 8, 13 }, module = 2, distance = { 70, 100 }, size = { 30, 120 },
      computation = 320, duration = 1000, eut = 491520, eutScales = true, weight = 150, orePrefix = "oreEndstone",
      yield = { { mat = "InfinityCatalyst", chance = 5000 }, { mat = "CosmicNeutronium", chance = 3000 }, { mat = "Neutronium", chance = 2000 } } },

    { name = "ichoriumAsteroid", drones = { 10, 13 }, module = 3, distance = { 70, 100 }, size = { 30, 120 },
      computation = 320, duration = 1000, eut = 491520, eutScales = true, weight = 150, orePrefix = "oreEndstone",
      yield = { { mat = "ShadowIron", chance = 4500 }, { mat = "MeteoricIron", chance = 3000 }, { mat = "Ichorium", chance = 1500 }, { mat = "Desh", chance = 500 }, { mat = "Americium", chance = 500 } } },

    -- Raw item output (minecraft clay block).
    { name = "clayAsteroid", drones = { 1, 6 }, module = 1, distance = { 20, 100 }, size = { 30, 60 },
      computation = 30, duration = 800, eut = 7680, eutScales = false, weight = 200,
      yield = { { item = "minecraft:clay", chance = 10000 } } },

    -- Mixed oreEndstone GT materials + one HEE item. Needs HardcoreEnderExpansion.
    { name = "mysteriousCrystalAsteroid", drones = { 5, 13 }, module = 1, distance = { 65, 120 }, size = { 30, 60 },
      computation = 300, duration = 500, eut = 122880, eutScales = false, weight = 220, orePrefix = "oreEndstone",
      conditional = "HardcoreEnderExpansion",
      yield = { { mat = "MysteriousCrystal", chance = 7400 }, { mat = "Mytryl", chance = 2000 }, { mat = "Oriharukon", chance = 500 },
                { mat = "HeeEndium", chance = 98 }, { item = "HardcoreEnderExpansion:end_powder_ore", chance = 2 } } },

    { name = "uraniumPlutoniumAsteroid", drones = { 3, 7 }, module = 1, distance = { 30, 70 }, size = { 40, 180 },
      computation = 120, duration = 400, eut = 30720, eutScales = true, weight = 150, orePrefix = "ore",
      yield = { { mat = "Uranium", chance = 3000 }, { mat = "Uranium235", chance = 2450 }, { mat = "Plutonium", chance = 2450 },
                { mat = "Plutonium241", chance = 2000 }, { mat = "Thorianit", chance = 100 } } },  -- Thorianit: bartworks

    { name = "holmiumSamariumAsteroid", drones = { 8, 13 }, module = 2, distance = { 40, 80 }, size = { 15, 50 },
      computation = 260, duration = 500, eut = 30720, eutScales = true, weight = 75, orePrefix = "ore",
      yield = { { mat = "Holmium", chance = 2000 }, { mat = "Samarium", chance = 3000 }, { mat = "Tiberium", chance = 3000 }, { mat = "Strontium", chance = 2000 } } },  -- Tiberium: bartworks

    { name = "platlinePureAsteroid", drones = { 7, 10 }, module = 3, distance = { 25, 200 }, size = { 10, 30 },
      computation = 360, duration = 500, eut = 122880, eutScales = true, weight = 60, orePrefix = "dust",
      yield = { { mat = "Platinum", chance = 3800 }, { mat = "Palladium", chance = 2000 }, { mat = "Iridium", chance = 1500 },
                { mat = "Osmium", chance = 500 }, { mat = "Ruthenium", chance = 1200 }, { mat = "Rhodium", chance = 1000 } } },  -- Ruthenium/Rhodium: bartworks

    { name = "magnesiumAsteroid", drones = { 4, 9 }, module = 1, distance = { 10, 200 }, size = { 10, 80 },
      computation = 60, duration = 400, eut = 7680, eutScales = true, weight = 250, orePrefix = "ore",
      yield = { { mat = "Magnesium", chance = 4000 }, { mat = "Manganese", chance = 3000 }, { mat = "Fluorspar", chance = 3000 } } },  -- Fluorspar: bartworks

    { name = "lanthanumAsteroid", drones = { 5, 11 }, module = 2, distance = { 30, 230 }, size = { 30, 120 },
      computation = 120, duration = 500, eut = 30720, eutScales = true, weight = 150, orePrefix = "ore",
      yield = { { mat = "Trinium", chance = 1500 }, { mat = "Lanthanum", chance = 2000 }, { mat = "Orundum", chance = 3000 }, { mat = "Silver", chance = 3500 } } },  -- Orundum: goodgenerator

    { name = "tengamAsteroid", drones = { 10, 13 }, module = 3, distance = { 20, 100 }, size = { 5, 100 },
      computation = 120, duration = 500, eut = 30720, eutScales = true, weight = 50, orePrefix = "ore",
      yield = { { mat = "Dilithium", chance = 100 }, { mat = "Orundum", chance = 1650 }, { mat = "Vanadium", chance = 3500 },
                { mat = "Ytterbium", chance = 2250 }, { mat = "TengamRaw", chance = 2500 } } },  -- Orundum: goodgenerator

    { name = "naquadahAsteroid", drones = { 5, 8 }, module = 1, distance = { 50, 150 }, size = { 20, 80 },
      computation = 240, duration = 1000, eut = 30720, eutScales = true, weight = 200, orePrefix = "ore",
      yield = { { mat = "NaquadahEarth", chance = 4000 }, { mat = "EnrichedNaquadahEarth", chance = 3500 }, { mat = "NaquadriaEarth", chance = 2500 } } },  -- goodgenerator earths

    -- Special item outputs. Needs Draconic Evolution.
    { name = "draconicCoreRuin", drones = { 9, 11 }, module = 3, distance = { 50, 200 }, size = { 1, 1 },
      computation = 1000, duration = 2000, eut = 7864320, eutScales = false, weight = 1,
      conditional = "DraconicEvolution",
      yield = { { item = "kubatech:DEFCDraconicSchematic", chance = 100 }, { item = "DraconicEvolution:draconicCore", chance = 100 },
                { item = "gregtech:ZPM-battery", chance = 9800 } } },
}

-- ---- helpers -------------------------------------------------------------

-- Per-drone-tier values for a meteor. `tier` is a drone tier (1..13 = MK-I..XIII)
-- and must be within m.drones. Returns { size = {min, max}, duration, eut }, or
-- nil if the tier can't mine this meteor.
function meteors.scale(m, tier)
    if tier < m.drones[1] or tier > m.drones[2] then return nil end
    local k = tier - m.drones[1]
    local grow = 2 ^ k - 1
    local f = math.sqrt(k + 1)
    return {
        size = { m.size[1] + grow, m.size[2] + grow },
        duration = math.ceil(m.duration / f),
        eut = m.eutScales and math.ceil(m.eut * f) or m.eut,
    }
end

-- Resolves a yield entry to its oredict item name (orePrefix .. mat), or the raw
-- item id for item-only outputs.
function meteors.oredict(m, y)
    if y.item then return y.item end
    return (m.orePrefix or "") .. y.mat
end

-- ---- yield estimation ----------------------------------------------------
-- On top of the drone-tier scaling, actual yield depends on the selected PLASMA
-- (a base time discount and a size multiplier) and the machine's OVERDRIVE
-- parameter (0..2). Overdrive trades size for speed:
--   real time  = baseTime * (1 - timeDiscount) / overdrive     (discount <= 50%)
--   size bonus = sizeMultiplier * (2 - overdrive)              (bonus <= 75%)
-- The size bonus is the chance of extra stacks above the minimum, so the average
-- run yields  size.min + sizeBonus * (size.max - size.min)  stacks, split among
-- the ores by their chance weights.

-- Items in one output stack (the recipes emit getOre(64)); special item-only
-- meteors differ, so treat `items` for those as informative only.
meteors.STACK = 64

local function clamp(x, lo, hi)
    if x < lo then return lo elseif x > hi then return hi end
    return x
end

-- Real mining time (ticks). `timeDiscount` is the plasma's base discount (capped
-- at 0.5); `overdrive` is the machine parameter (0..2, higher = faster). An
-- overdrive of 0 can't run (returns math.huge).
function meteors.mineTime(baseTime, timeDiscount, overdrive)
    overdrive = overdrive or 1
    if overdrive <= 0 then return math.huge end
    return baseTime * (1 - clamp(timeDiscount or 0, 0, 0.5)) / overdrive
end

-- Size bonus (0..0.75): plasma sizeMultiplier * (2 - overdrive), capped at 0.75.
function meteors.sizeBonus(sizeMultiplier, overdrive)
    return clamp((sizeMultiplier or 0) * (2 - (overdrive or 1)), 0, 0.75)
end

-- Average total stacks: guaranteed minimum plus the size-bonus share of the span.
function meteors.avgStacks(sizeMin, sizeMax, sizeBonus)
    return sizeMin + sizeBonus * (sizeMax - sizeMin)
end

-- Full per-run estimate for meteor `m` at `droneTier` (1..13) with the given
-- plasma and overdrive.
--   plasma = { timeDiscount = 0..0.5, sizeMultiplier = <number> }
-- Returns nil if the drone tier can't mine `m`, otherwise:
--   { time,       -- real mine time, ticks
--     eut,        -- EU/t (drone-tier scaled)
--     size,       -- { min, max } scaled size range, in stacks
--     sizeBonus,  -- 0..0.75
--     stacks,     -- average total stacks produced
--     yield = {   -- average per output over one run
--       { oredict, mat, item, chance, fraction, stacks, items }, ... } }
function meteors.estimate(m, droneTier, plasma, overdrive)
    local s = meteors.scale(m, droneTier)
    if not s then return nil end
    plasma = plasma or {}
    local sizeBonus = meteors.sizeBonus(plasma.sizeMultiplier, overdrive)
    local total = meteors.avgStacks(s.size[1], s.size[2], sizeBonus)

    local totalChance = 0
    for _, y in ipairs(m.yield) do totalChance = totalChance + y.chance end

    local yield = {}
    for _, y in ipairs(m.yield) do
        local fraction = totalChance > 0 and y.chance / totalChance or 0
        local stacks = total * fraction
        yield[#yield + 1] = {
            oredict = meteors.oredict(m, y), mat = y.mat, item = y.item, chance = y.chance,
            fraction = fraction, stacks = stacks, items = stacks * meteors.STACK,
        }
    end

    return {
        time = meteors.mineTime(s.duration, plasma.timeDiscount, overdrive),
        eut = s.eut,
        size = s.size,
        sizeBonus = sizeBonus,
        stacks = total,
        yield = yield,
    }
end

-- Lookup by asteroid name.
meteors.byName = {}
for _, m in ipairs(meteors.list) do meteors.byName[m.name] = m end

return meteors

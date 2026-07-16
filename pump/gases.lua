-- Static data: the available pumping configurations.
--
-- Each entry describes one unique gas the pumping module can be set to produce:
--   name       The gas name. Doubles as (a) the key used in config.lua `demand`
--              and (b) the AE2 fluid label matched against getFluidsInNetwork()
--              (e.g. "Molten Redstone"), so it must match the in-game label.
--   planet     TecTech parameter (hatch 0, id 0) selecting the planet.
--   gas        TecTech parameter (hatch 0, id 1) selecting the gas type.
--   amount     Fluid produced per parallel per second (mB). The controller uses
--              it to estimate a thread's output and assign enough threads to
--              cover each gas's deficit.
--
-- Sorted by planet then gas. Run `check` to verify names against the AE2
-- network and to detect duplicate names / (planet, gas) pairs.

local gases = {
    -- === Planet 2 ===
    { name = "Chlorobenzene",     planet = 2, gas =  1, amount = 896000 },

    -- === Planet 3 ===
    { name = "Ender Goo",         planet = 3, gas =  1, amount = 32000 },
    { name = "Very Heavy Oil",    planet = 3, gas =  2, amount = 14000000 },
    { name = "Lava",              planet = 3, gas =  3, amount = 18000000 },
    { name = "Natural Gas",       planet = 3, gas =  4, amount = 1400000 },

    -- === Planet 4 ===
    { name = "Sulfuric Acid",     planet = 4, gas =  1, amount = 784000 },
    { name = "Molten Iron",       planet = 4, gas =  2, amount = 896000 },
    { name = "Oil",               planet = 4, gas =  3, amount = 1400000 },
    { name = "Heavy Oil",         planet = 4, gas =  4, amount = 1792000 },
    { name = "Molten Lead",       planet = 4, gas =  5, amount = 896000 },
    { name = "Raw Oil",           planet = 4, gas =  6, amount = 1400000 },
    { name = "Light Oil",         planet = 4, gas =  7, amount = 780000 },
    { name = "Carbon Dioxide",    planet = 4, gas =  8, amount = 1680000 },

    -- === Planet 5 ===
    { name = "Carbon Monoxide",   planet = 5, gas =  1, amount = 4480000 },
    { name = "Helium-3",          planet = 5, gas =  2, amount = 2800000 },
    { name = "Salt Water",        planet = 5, gas =  3, amount = 2800000 },
    { name = "Helium",            planet = 5, gas =  4, amount = 1400000 },
    { name = "Liquid Oxygen",     planet = 5, gas =  5, amount = 896000 },
    { name = "Neon",              planet = 5, gas =  6, amount = 32000 },
    { name = "Argon",             planet = 5, gas =  7, amount = 32000 },
    { name = "Krypton",           planet = 5, gas =  8, amount = 8000 },
    { name = "Methane",           planet = 5, gas =  9, amount = 1792000 },
    { name = "Hydrogen Sulfide",  planet = 5, gas = 10, amount = 392000 },
    { name = "Ethane",            planet = 5, gas = 11, amount = 1194000 },

    -- === Planet 6 ===
    { name = "Deuterium",         planet = 6, gas =  1, amount = 1568000 },
    { name = "Tritium",           planet = 6, gas =  2, amount = 240000 },
    { name = "Ammonia",           planet = 6, gas =  3, amount = 240000 },
    { name = "Xenon",             planet = 6, gas =  4, amount = 16000 },
    { name = "Ethylene",          planet = 6, gas =  5, amount = 1792000 },

    -- === Planet 7 ===
    { name = "Hydrofluoric Acid", planet = 7, gas =  1, amount = 672000 },
    { name = "Fluorine",          planet = 7, gas =  2, amount = 1792000 },
    { name = "Nitrogen",          planet = 7, gas =  3, amount = 1792000 },
    { name = "Oxygen",            planet = 7, gas =  4, amount = 1792000 },

    -- === Planet 8 ===
    { name = "Hydrogen",          planet = 8, gas =  1, amount = 1568000 },
    { name = "Liquid Air",        planet = 8, gas =  2, amount = 875000 },
    { name = "Molten Copper",     planet = 8, gas =  3, amount = 672000 },
    { name = "Unknown Liquid",    planet = 8, gas =  4, amount = 672000 },
    { name = "Distilled Water",   planet = 8, gas =  5, amount = 17920000 },
    { name = "Radon",             planet = 8, gas =  6, amount = 64000 },
    { name = "Molten Tin",        planet = 8, gas =  7, amount = 672000 },
}

return gases

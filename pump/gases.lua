-- Static data: the ~40 available pumping configurations.
--
-- Each entry describes one unique gas the pumping module can be set to produce:
--   name       The gas name. Doubles as (a) the key used in config.lua `demand`
--              and (b) the AE2 fluid label matched against getFluidsInNetwork()
--              (e.g. "Molten Redstone"), so it must match the in-game label.
--   planet     TecTech parameter (hatch 0, id 0) selecting the planet.
--   gas        TecTech parameter (hatch 0, id 1) selecting the gas type.
--   amount     Relative pumping speed of this configuration (higher = faster).
--              Reserved for future throughput-based pump-count tuning.
--   parallels  (optional) Parallels count to set on a pump serving this gas
--              (hatch 1, id 0). Leave nil to keep the pump's manual setting.
--
-- TODO(fill in-game): planet/gas integers + amounts come from the pumping
-- module's parameter table; `name` must match the fluid labels from
-- `probe fluids`. Replace the examples below with all ~40 real configurations.

local gases = {
    -- === EXAMPLES -- replace with real data ===
    { name = "Hydrogen", planet = 0, gas = 0, amount = 1 },
    { name = "Helium",   planet = 0, gas = 1, amount = 1 },
    { name = "Nitrogen", planet = 1, gas = 0, amount = 1 },
}

return gases

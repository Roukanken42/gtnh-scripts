-- Static data: the ~40 available pumping configurations.
--
-- Each entry describes one unique gas the pumping module can be set to produce:
--   name       Human name, used as the key in config.lua `demand`.
--   planet     TecTech parameter (hatch 0, id 0) selecting the planet.
--   gas        TecTech parameter (hatch 0, id 1) selecting the gas type.
--   fluid      AE2 fluid label to match stock against -- the clean user-facing
--              name from getFluidsInNetwork(), e.g. "Molten Redstone".
--   fluidName  (optional) Unlocalized fluid id, for an exact match instead of
--              `fluid` if labels turn out ambiguous.
--   amount     Relative pumping speed of this configuration (higher = faster).
--              Reserved for future throughput-based pump-count tuning.
--   parallels  (optional) Parallels count to set on a pump serving this gas
--              (hatch 1, id 0). Leave nil to keep the pump's manual setting.
--
-- TODO(fill in-game): planet/gas integers + amounts come from the pumping
-- module's parameter table; `fluid` labels come from `probe fluids`. Replace the
-- examples below with all ~40 real configurations.

local gases = {
    -- === EXAMPLES -- replace with real data ===
    { name = "Hydrogen", planet = 0, gas = 0, amount = 1, fluid = "Hydrogen" },
    { name = "Helium",   planet = 0, gas = 1, amount = 1, fluid = "Helium" },
    { name = "Nitrogen", planet = 1, gas = 0, amount = 1, fluid = "Nitrogen" },
}

return gases

-- Static data: the ~40 available pumping configurations.
--
-- Each entry describes one unique gas the pumping module can be set to produce:
--   name       Human name, used as the key in config.lua `demand`.
--   planet     TecTech parameter #1 (small integer) selecting the planet.
--   gas        TecTech parameter #2 (small integer) selecting the gas type.
--   amount     Relative pumping speed of this configuration (higher = faster).
--              Reserved for future throughput-based pump-count tuning.
--   item       AE2 item label to match stock against (the ae2fc "drop of Xyz").
--   itemName   (optional) Unlocalized item id, for an exact match instead of
--   itemDamage (optional) label; use these if labels turn out ambiguous.
--
-- TODO(fill in-game): planet/gas integers + amounts come from the pumping
-- module's parameter table; `item` labels come from `probe ae drop`. Replace the
-- examples below with all ~40 real configurations.

local gases = {
    -- === EXAMPLES -- replace with real data ===
    { name = "Hydrogen", planet = 0, gas = 0, amount = 1, item = "drop of Hydrogen" },
    { name = "Helium",   planet = 0, gas = 1, amount = 1, item = "drop of Helium" },
    { name = "Nitrogen", planet = 1, gas = 0, amount = 1, item = "drop of Nitrogen" },
}

return gases

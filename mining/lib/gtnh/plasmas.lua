-- Space-mining plasma stats, from GTNH 2.9.
--
-- The mining module burns a plasma while mining. The plasma's tier sets a time
-- discount and a size multiplier, and its consumption is per meteor mined.
-- Feed a plasma entry straight into meteors.estimate(m, tier, plasma).
--
-- Per entry:
--   tier            plasma tier (1..5)
--   name            fluid label (matches the ME fluid, e.g. "Helium Plasma")
--   material        GT material whose plasma this is (Materials.<material>.getPlasma())
--   consumed        L (= mB) of plasma per meteor (per parallel)
--   fluid           the fluid's registry name, e.g. "plasma.helium"
--   timeDiscount    tau = 0.1 * (tier - 1)      -> time *= max(1 - tau, 0.5)
--   sizeMultiplier  lambda = (tier / 6) ^ 3     -> sizeBonus = min(lambda, 0.75)
-- Matches the wiki's plasma table: duration 100% .. 60%, bonus-stack chance
-- 0.46% .. 57.87%.
--
-- ===========================================================================
-- HOW TO REGENERATE (future GTNH version; current 2.9.0 / gregtech 5.09.54.265).
-- All of this lives in the miner-module tile entity in the GregTech jar:
--   gtnhintergalactic.tile.multi.elevatormodules.TileEntityModuleMiner
-- (decompile as in meteors.lua). The relevant bits:
--   * PLASMA_<X>_USAGE fields                -> `consumed`
--   * getTierFromPlasma()                    -> which fluids / tier order
--     (Materials.<X>.getPlasma(); Technetium is MaterialsElements TECHNETIUM)
--   * getRecipeTime(t, tier) = t * max(1 - 0.1*(tier-1), 0.5)
--   * getBonusStackChance(tier) = min((tier/6)^3 * 10000, BONUS_STACK_MAX_CHANCE)
--                                     (7500 = 0.75)
--   (2.9.0's source still divides/multiplies by a legacy overdrive setting, but
--   nothing can change it from its default of 1 any more, so it is left out.)
-- If the tiers/usages/formulas change, update RAW and the derivations below.
-- ===========================================================================

local plasmas = {}

-- Only the per-tier facts differ; the rest is derived by the shared formulas.
local RAW = {
    { tier = 1, name = "Helium Plasma",        material = "Helium",       consumed = 825 },
    { tier = 2, name = "Bismuth Plasma",       material = "Bismuth",      consumed = 550 },
    { tier = 3, name = "Radon Plasma",         material = "Radon",        consumed = 375 },
    { tier = 4, name = "Technetium Plasma",    material = "Technetium",   consumed = 250 },  -- MaterialsElements
    { tier = 5, name = "Plutonium-241 Plasma", material = "Plutonium241", consumed = 150 },
}

plasmas.list = {}
for _, r in ipairs(RAW) do
    local t = r.tier
    local lambda = (t / 6) ^ 3
    plasmas.list[#plasmas.list + 1] = {
        tier = t,
        name = r.name,
        material = r.material,
        -- The fluid's registry name, which is how a fluid interface is told what
        -- to stock: "plasma." .. the lower-cased material (GT names them so).
        fluid = "plasma." .. r.material:lower(),
        consumed = r.consumed,
        timeDiscount = 0.1 * (t - 1),
        sizeMultiplier = lambda,
    }
end

plasmas.byTier = {}
plasmas.byName = {}
for _, p in ipairs(plasmas.list) do
    plasmas.byTier[p.tier] = p
    plasmas.byName[p.name] = p
end

return plasmas

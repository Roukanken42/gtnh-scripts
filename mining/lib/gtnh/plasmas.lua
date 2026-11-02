-- Space-mining plasma stats, from GTNH 2.8.4.
--
-- The mining module burns a plasma while mining. The plasma's tier sets a base
-- time discount and a size multiplier, and its consumption is per meteor mined
-- (so the plasma DRAIN rate rises with overdrive, since meteors finish faster).
-- Feed a plasma entry straight into meteors.estimate(m, tier, plasma, overdrive).
--
-- Per entry:
--   tier            plasma tier (1..5)
--   name            fluid label (matches the ME fluid, e.g. "Helium Plasma")
--   material        GT material whose plasma this is (Materials.<material>.getPlasma())
--   consumed        L (= mB) of plasma per meteor (per parallel)
--   timeDiscount    tau = 0.1 * (tier - 1)      -> time *= max((1-tau)/OD, 0.5)
--   sizeMultiplier  lambda = (tier / 6) ^ 3     -> sizeBonus = min(lambda*(2-OD), 0.75)
--   minOD, maxOD    the overdrive values where the caps are reached (informational):
--                     minOD = max(0, 2 - 0.75/lambda)   (size bonus hits 0.75 below it)
--                     maxOD = 2 - 0.2 * (tier - 1)       (time hits its 50% floor above it)
--
-- ===========================================================================
-- HOW TO REGENERATE (future GTNH version; current 2.8.4 / gregtech 5.09.51.482).
-- All of this lives in the miner-module tile entity in the GregTech jar:
--   gtnhintergalactic.tile.multi.elevatormodules.TileEntityModuleMiner
-- (decompile as in meteors.lua). The relevant bits:
--   * PLASMA_<X>_USAGE fields                -> `consumed`
--   * getTierFromPlasma()                    -> which fluids / tier order
--     (Materials.<X>.getPlasma(); Technetium is MaterialsElements TECHNETIUM)
--   * getRecipeTime(t, tier) = t * max((1 - 0.1*(tier-1)) / overdrive, 0.5)
--   * getBonusStackChance(tier) = min((tier/6)^3 * 10000 * (2 - overdrive),
--                                     BONUS_STACK_MAX_CHANCE)   (7500 = 0.75)
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
        minOD = math.max(0, 2 - 0.75 / lambda),
        maxOD = 2 - 0.2 * (t - 1),
    }
end

plasmas.byTier = {}
plasmas.byName = {}
for _, p in ipairs(plasmas.list) do
    plasmas.byTier[p.tier] = p
    plasmas.byName[p.name] = p
end

return plasmas

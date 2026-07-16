-- Utility to double-check gases.lua. Read-only; touches no pumps.
--
--   1. Static checks: duplicate gas names and duplicate (planet, gas) pairs.
--   2. Live check: the current stored amount (mB) of each listed gas, and
--      whether its name is present as a fluid label in the AE2 network -- so you
--      can catch names that do not match the in-game fluid label.
--
-- Run from this folder:  check

local ae2 = require("ae2")
local gases = require("gases")

-- ---- Static validation --------------------------------------------------
print("== gases.lua static checks (" .. #gases .. " entries) ==")

local seenName, seenKey = {}, {}
local nameDups, keyDups = {}, {}
for _, g in ipairs(gases) do
    if seenName[g.name] then
        nameDups[#nameDups + 1] = g.name
    else
        seenName[g.name] = true
    end

    local key = g.planet .. "/" .. g.gas
    if seenKey[key] then
        keyDups[#keyDups + 1] = string.format("(%s) %s & %s", key, seenKey[key], g.name)
    else
        seenKey[key] = g.name
    end
end

if #nameDups > 0 then
    print("DUPLICATE names: " .. table.concat(nameDups, ", "))
end
if #keyDups > 0 then
    print("DUPLICATE (planet/gas): " .. table.concat(keyDups, "; "))
end
if #nameDups == 0 and #keyDups == 0 then
    print("OK: no duplicate names or (planet, gas) pairs.")
end

-- ---- Live AE2 cross-check ------------------------------------------------
local me, err = ae2.getMe()
if not me then
    print("\nAE2 unavailable, skipping live check: " .. tostring(err))
    return
end

-- Sum stored amount per fluid label present in the network.
local present = {}
local fluids = me.getFluidsInNetwork()
for i = 1, #fluids do
    local f = fluids[i]
    if f.label then
        present[f.label] = (present[f.label] or 0) + (f.amount or 0)
    end
end

print("\n== current amounts in AE2 (mB) ==")
local missing = {}
for _, g in ipairs(gases) do
    local amount = present[g.name]
    if amount == nil then
        missing[#missing + 1] = g.name
        print(string.format("  [%d/%2d] %-20s NOT FOUND", g.planet, g.gas, g.name))
    else
        print(string.format("  [%d/%2d] %-20s %d", g.planet, g.gas, g.name, amount))
    end
end

if #missing > 0 then
    print("\n" .. #missing .. " name(s) not found as a fluid in the network:")
    print("  " .. table.concat(missing, ", "))
    print("Either none is stored right now, or the name does not match the")
    print("in-game fluid label. Compare against `probe fluids`.")
else
    print("\nOK: every listed gas was found in the network.")
end

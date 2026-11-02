-- Thin AE2 wrapper: reads how much of each gas is currently stored in the
-- network. Gases are read as fluids via getFluidsInNetwork(), whose `label` is
-- the clean user-facing name (e.g. "Molten Redstone", without the "drop of"
-- prefix) and whose `amount` is the stored quantity in mB.
--
-- Mirrors the style of aether/src/AE2.lua.

local component = require("component")

local ae2 = {}

-- Component types that expose the AE2 network API (getFluidsInNetwork, ...).
-- Since GTNH 2.9 an adapter on an ME Fluid Interface shows up as
-- "fluid_interface" instead of "me_interface"; both carry the full network API,
-- as does the ME Controller. Tried in this order.
ae2.ME_TYPES = { "me_controller", "fluid_interface", "me_interface" }

-- Returns a proxy for the first AE2 network component found, or nil + error.
function ae2.getMe()
    for _, ctype in ipairs(ae2.ME_TYPES) do
        if component.isAvailable(ctype) then
            return component.getPrimary(ctype)
        end
    end
    return nil, "no AE2 network component found (looked for "
        .. table.concat(ae2.ME_TYPES, ", ") .. ")"
end

-- Given the gas definitions (see gases.lua), returns a map of
--   gas.name -> current amount (mB) stored in the network
-- Every gas in `gases` is present in the result (0 if none stored).
--
-- gas.name is matched against each fluid's `label` from getFluidsInNetwork().
function ae2.getStock(gases)
    local me, err = ae2.getMe()
    if not me then
        return nil, err
    end

    -- Build an O(1) lookup so we only walk the network fluid list once.
    local byLabel = {}
    local stock = {}
    for _, gas in ipairs(gases) do
        stock[gas.name] = 0
        byLabel[gas.name] = gas
    end

    local fluids = me.getFluidsInNetwork()
    for i = 1, #fluids do
        local f = fluids[i]
        local gas = f.label and byLabel[f.label]
        if gas then
            stock[gas.name] = stock[gas.name] + (f.amount or 0)
        end
    end

    return stock
end

return ae2

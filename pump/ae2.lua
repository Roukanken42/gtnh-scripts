-- Thin AE2 wrapper: reads how much of each gas is currently stored in the
-- network. Gases are read as fluids via getFluidsInNetwork(), whose `label` is
-- the clean user-facing name (e.g. "Molten Redstone", without the "drop of"
-- prefix) and whose `amount` is the stored quantity in mB.
--
-- Mirrors the style of aether/src/AE2.lua.

local component = require("component")

local ae2 = {}

-- Returns a me_interface / me_controller proxy, or nil + error message.
function ae2.getMe()
    if component.isAvailable("me_interface") then
        return component.me_interface
    elseif component.isAvailable("me_controller") then
        return component.me_controller
    end
    return nil, "no me_interface or me_controller component found"
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

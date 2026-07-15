-- Thin AE2 wrapper: reads how much of each gas is currently stored in the
-- network. Gases are stored as ae2fc "drop of Xyz" items, so we query
-- getItemsInNetwork (NOT getFluidsInNetwork) and sum their stack sizes.
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
--   gas.name -> current amount stored in the network
-- Every gas in `gases` is present in the result (0 if none stored).
--
-- Matching precedence per gas:
--   * gas.itemName (unlocalized id), optionally narrowed by gas.itemDamage
--   * otherwise gas.item (localized label, e.g. "drop of Hydrogen")
function ae2.getStock(gases)
    local me, err = ae2.getMe()
    if not me then
        return nil, err
    end

    -- Build O(1) lookups so we only walk the network item list once.
    local byName, byLabel = {}, {}
    local stock = {}
    for _, gas in ipairs(gases) do
        stock[gas.name] = 0
        if gas.itemName then
            byName[gas.itemName .. "#" .. tostring(gas.itemDamage or 0)] = gas
            byName[gas.itemName] = byName[gas.itemName] or gas
        elseif gas.item then
            byLabel[gas.item] = gas
        end
    end

    local items = me.getItemsInNetwork()
    for i = 1, #items do
        local it = items[i]
        local gas = byLabel[it.label]
        if not gas and it.name then
            gas = byName[it.name .. "#" .. tostring(it.damage or 0)] or byName[it.name]
        end
        if gas then
            stock[gas.name] = stock[gas.name] + (it.size or 0)
        end
    end

    return stock
end

return ae2

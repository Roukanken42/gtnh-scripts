-- Access to the LOCAL space-mining ME network -- the one reached via an adapter
-- on its ME Controller (component type "me_controller"). The mining drones live
-- in this net; this is where setup pulls a probe drone from and where the
-- controller (main) checks what drones are in stock. Kept separate from setup so
-- both can reuse the stock query.

local component = require("component")
local drones = require("lib.gtnh.drones")

local localnet = {}

-- Returns the me_controller proxy for the local mining net, or nil + error.
-- (An me_interface adapter on the same net would also work, but the ME
-- Controller is the unambiguous "this is the local net" anchor.)
function localnet.proxy()
    if component.isAvailable("me_controller") then
        return component.me_controller
    end
    return nil, "no me_controller found -- add an adapter on the mining net's ME Controller"
end

-- Lists the mining drones currently in stock in the local net as
--   { { tier = <1..13 or nil>, label = <"Mining Drone Mk-.. (..)">, size = <count> }, ... }
-- sorted by tier ascending. `net` defaults to localnet.proxy().
function localnet.dronesInStock(net)
    net = net or localnet.proxy()
    if not net or net.getItemsInNetwork == nil then return {} end
    local ok, items = pcall(net.getItemsInNetwork, { name = drones.ITEM_NAME })
    if not ok or type(items) ~= "table" then return {} end

    local out = {}
    for _, it in ipairs(items) do
        if it and it.name == drones.ITEM_NAME and (it.size or 0) > 0 then
            local d = drones.fromName(it.label)
            out[#out + 1] = { tier = d and d.tier or nil, label = it.label, size = it.size }
        end
    end
    table.sort(out, function(a, b) return (a.tier or 99) < (b.tier or 99) end)
    return out
end

-- The lowest-tier drone in stock. A low-tier drone runs in any module, while a
-- high-tier one won't run a lower-tier module, so the lowest is the safe choice
-- for probing / identification. Returns { tier, label, size } or nil.
function localnet.lowestDrone(net)
    return localnet.dronesInStock(net)[1]
end

-- Current stocked count of a specific drone label in the local net.
function localnet.countOf(label, net)
    net = net or localnet.proxy()
    if not net or net.getItemsInNetwork == nil then return 0 end
    local ok, items = pcall(net.getItemsInNetwork, { label = label })
    if not ok or type(items) ~= "table" then return 0 end
    local n = 0
    for _, it in ipairs(items) do
        if it and it.label == label then n = n + (it.size or 0) end
    end
    return n
end

return localnet

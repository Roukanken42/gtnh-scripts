-- Which OpenComputers component types are AE2 network access points.
--
-- Since GTNH 2.9 an Adapter on an ME Fluid Interface shows up as
-- "fluid_interface" instead of "me_interface". Both carry the whole ME interface
-- API (patterns, config slots, getItemsInNetwork, ...) because the fluid
-- interface's tile extends the regular one; the ME Controller carries the network
-- reads but no interface config. Everything that enumerates interfaces goes
-- through here, so a renamed type is fixed in one place.

local me = {}

-- Blocks that are ME interfaces: station staging, the supply interface.
me.INTERFACE_TYPES = { "me_interface", "fluid_interface" }

-- Anything that can read a network's contents, in order of preference.
me.NETWORK_TYPES = { "me_controller", "fluid_interface", "me_interface" }

-- Addresses of every component of the given types, in the order of `types`.
-- `component` defaults to the OC component library; callers that load it lazily
-- (so they can run off-machine) pass their own.
function me.list(types, component)
    component = component or require("component")
    local out = {}
    for _, t in ipairs(types) do
        for addr in component.list(t, true) do out[#out + 1] = addr end
    end
    return out
end

-- Addresses of every ME interface (item or fluid).
function me.interfaces(component)
    return me.list(me.INTERFACE_TYPES, component)
end

-- True if `ctype` is one of the ME interface types.
function me.isInterface(ctype)
    for _, t in ipairs(me.INTERFACE_TYPES) do
        if t == ctype then return true end
    end
    return false
end

return me

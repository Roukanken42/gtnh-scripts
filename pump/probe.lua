-- Phase 0 discovery tool. Run this in-game to learn the things the docs do not
-- tell us: the TecTech parameter API, the pump's component type/addresses, the
-- live component count, and the exact AE2 item labels of the gas "drops".
--
-- Usage (from the folder this file lives in):
--   probe                  list every connected component + a total count
--   probe <type>           list all methods (with docs) of the first <type> found
--   probe fluids [substr]  list AE2 fluids whose label contains <substr>
--   probe items  [substr]  list AE2 items whose label contains <substr>
--
-- Paste the output back so gases.lua / pumps.lua / config.lua can be finalized.

local component = require("component")

local args = {...}
local mode = args[1]

local function listComponents()
    local list = {}
    for addr, ctype in component.list() do
        list[#list + 1] = { addr = addr, type = ctype }
    end
    table.sort(list, function(a, b)
        if a.type ~= b.type then return a.type < b.type end
        return a.addr < b.addr
    end)

    print("== Connected components ==")
    for _, c in ipairs(list) do
        print(string.format("%-26s %s", c.type, c.addr))
    end
    print("Total: " .. #list .. " components (this counts against the computer's budget)")
end

local function listMethods(ctype)
    local addr = component.list(ctype, true)()
    if not addr then
        -- fall back to a partial match
        addr = component.list(ctype)()
    end
    if not addr then
        print("No component of type '" .. ctype .. "' found. Run `probe` to see types.")
        return
    end

    print("== Methods of '" .. ctype .. "' (" .. addr .. ") ==")
    local methods = component.methods(addr)
    local names = {}
    for name in pairs(methods) do names[#names + 1] = name end
    table.sort(names)

    for _, name in ipairs(names) do
        local doc = component.doc(addr, name)
        local direct = methods[name] and " [direct]" or ""
        print("- " .. name .. direct)
        if doc and doc ~= "" then
            print("    " .. doc)
        end
    end
end

local function getMe()
    if component.isAvailable("me_interface") then
        return component.me_interface
    elseif component.isAvailable("me_controller") then
        return component.me_controller
    end
    print("No me_interface or me_controller component found.")
    return nil
end

local function dumpFluids(substr)
    substr = (substr or ""):lower()
    local me = getMe()
    if not me then return end

    local fluids = me.getFluidsInNetwork()
    print("== AE2 fluids matching '" .. substr .. "' ==")
    local matched = 0
    for i = 1, #fluids do
        local f = fluids[i]
        local label = f.label or ""
        if substr == "" or label:lower():find(substr, 1, true) then
            print(string.format("amount=%-14s label=%q  name=%q",
                tostring(f.amount), label, tostring(f.name)))
            matched = matched + 1
        end
    end
    print("Matched " .. matched .. " of " .. #fluids .. " fluids.")
end

local function dumpItems(substr)
    substr = (substr or ""):lower()
    local me = getMe()
    if not me then return end

    local items = me.getItemsInNetwork()
    print("== AE2 items matching '" .. substr .. "' ==")
    local matched = 0
    for i = 1, #items do
        local it = items[i]
        local label = it.label or ""
        if substr == "" or label:lower():find(substr, 1, true) then
            print(string.format("size=%-12s label=%q  name=%q  dmg=%s",
                tostring(it.size), label, tostring(it.name), tostring(it.damage)))
            matched = matched + 1
        end
    end
    print("Matched " .. matched .. " of " .. #items .. " items.")
end

if mode == nil then
    listComponents()
elseif mode == "fluids" then
    dumpFluids(args[2])
elseif mode == "items" then
    dumpItems(args[2])
else
    listMethods(mode)
end

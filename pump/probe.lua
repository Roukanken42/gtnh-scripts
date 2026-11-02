-- Phase 0 discovery tool. Run this in-game to learn the things the docs do not
-- tell us: the TecTech parameter API, the pump's component type/addresses, the
-- live component count, and the exact AE2 item labels of the gas "drops".
--
-- Usage (from the folder this file lives in):
--   probe                  list every connected component + a total count
--   probe <type>           list all methods (with docs) of the first <type> found
--   probe pump             list the methods of the first pumping module found and
--                          dump what its getParameters() returns (redirect to a
--                          file to keep it: `probe pump > /home/pump.txt`)
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

local function printMethods(addr, title)
    print("== Methods of " .. title .. " (" .. addr .. ") ==")
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
    printMethods(addr, "'" .. ctype .. "'")
end

-- Finds the first gt_machine whose getName() is a pumping module, lists its
-- methods and dumps the raw result of getParameters(), so the parameter API
-- (which changed in GTNH 2.9) can be read off directly.
local function dumpPump()
    for addr in component.list("gt_machine", true) do
        local proxy = component.proxy(addr)
        local ok, name = pcall(proxy.getName)
        if ok and type(name) == "string" and name:find("projectmodulepump", 1, true) then
            printMethods(addr, "pump '" .. name .. "'")
            print("")
            if proxy.getParameters == nil then
                print("This pump has no getParameters method.")
                return
            end
            local okP, params = pcall(proxy.getParameters)
            print("== getParameters() ==")
            if not okP then
                print("error: " .. tostring(params))
            else
                print(require("serialization").serialize(params, true))
            end
            return
        end
    end
    print("No gt_machine named projectmodulepump* found. Run `probe gt_machine` to see one.")
end

local function getMe()
    local me, err = require("ae2").getMe()
    if not me then
        print(err)
    end
    return me
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
elseif mode == "pump" then
    dumpPump()
else
    listMethods(mode)
end

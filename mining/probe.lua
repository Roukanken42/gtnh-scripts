-- Read-only discovery tool for the mining setup. Touches nothing; prints what
-- the hardware reports, so names and labels the scripts match against can be
-- checked after a modpack update.
--
-- Usage (from this folder):
--   probe                          list the ME, transposer and mining components
--   probe items  [filter] [@addr]  every item in an ME network: size, label,
--                                  name, damage
--   probe fluids [filter] [@addr]  every fluid in an ME network: amount, label, name
--   probe sides                    what each transposer sees on each side
--                                  (inventory name, size, tanks)
--   probe patterns [@addr]         the patterns in every ME interface (or just
--                                  @addr), with how the supply code reads each
--
-- [filter] keeps entries whose label OR name contains it (case-insensitive).
-- [@addr] reads the network behind that component (an address prefix is
-- enough, e.g. @1a2b); without it, the local mining net's ME Controller.
--
-- Output can be long; keep it with a redirect and share it with pastebin:
--   probe items > /home/items.txt
--   pastebin put /home/items.txt

local component = require("component")
local me = require("lib.hw.me")
local localnet = require("lib.hw.localnet")
local supply = require("lib.hw.supply")

local args = { ... }
local mode = args[1]

local SIDE_LABEL = {
    [0] = "bottom", [1] = "top", [2] = "north", [3] = "south", [4] = "west", [5] = "east",
}

-- Splits the arguments after the mode into a filter and an @address.
local function parseArgs()
    local filter, addr
    for i = 2, #args do
        local a = args[i]
        if a:sub(1, 1) == "@" then addr = a:sub(2) else filter = a end
    end
    return filter and filter:lower() or nil, addr
end

local function matches(filter, ...)
    if not filter then return true end
    for _, s in ipairs({ ... }) do
        if type(s) == "string" and s:lower():find(filter, 1, true) then return true end
    end
    return false
end

-- The network to read: the component at `addr`, or the local net's controller.
local function network(addr)
    if not addr then
        local net, err = localnet.proxy()
        if not net then return nil, err end
        return net, "local net (me_controller " .. net.address:sub(1, 8) .. ")"
    end
    local ok, full = pcall(component.get, addr)
    if not ok or not full then return nil, "no component matches @" .. addr end
    local p = component.proxy(full)
    return p, p.type .. " " .. full:sub(1, 8)
end

local function listComponents()
    local rows = {}
    local function add(t)
        for addr in component.list(t, true) do rows[#rows + 1] = { t = t, addr = addr } end
    end
    for _, t in ipairs(me.NETWORK_TYPES) do add(t) end
    add("transposer")
    add("database")

    print("== ME, transposer and database components ==")
    for _, r in ipairs(rows) do print(string.format("%-16s %s", r.t, r.addr)) end

    print("")
    print("== Mining modules (gt_machine named projectmoduleminert*) ==")
    local n = 0
    for addr in component.list("gt_machine", true) do
        local p = component.proxy(addr)
        local ok, name = pcall(p.getName)
        if ok and type(name) == "string" and name:find("projectmoduleminer", 1, true) then
            local okP, params = pcall(p.getParameters)
            local ptxt = ""
            if okP and type(params) == "table" then
                local keys = {}
                for k, v in pairs(params) do keys[#keys + 1] = k .. "=" .. tostring(v) end
                table.sort(keys)
                ptxt = "  " .. table.concat(keys, " ")
            end
            print(string.format("%-22s %s%s", name, addr, ptxt))
            n = n + 1
        end
    end
    print(n .. " mining module(s).")
end

local function dumpItems()
    local filter, addr = parseArgs()
    local net, what = network(addr)
    if not net then print(what); return end
    if net.getItemsInNetwork == nil then print(what .. " cannot list items"); return end

    local ok, items = pcall(net.getItemsInNetwork)
    if not ok or type(items) ~= "table" then
        print("getItemsInNetwork failed: " .. tostring(items)); return
    end
    local list = {}
    for i = 1, #items do
        local it = items[i]
        if type(it) == "table" and matches(filter, it.label, it.name) then list[#list + 1] = it end
    end
    table.sort(list, function(a, b) return tostring(a.label) < tostring(b.label) end)

    print("== Items in " .. what .. (filter and (" matching '" .. filter .. "'") or "") .. " ==")
    for _, it in ipairs(list) do
        print(string.format("%10s  %-40s name=%s dmg=%s%s",
            tostring(it.size), string.format("%q", tostring(it.label)), tostring(it.name),
            tostring(it.damage), it.hasTag and " +tag" or ""))
    end
    print("Matched " .. #list .. " of " .. #items .. " item types.")
end

local function dumpFluids()
    local filter, addr = parseArgs()
    local net, what = network(addr)
    if not net then print(what); return end
    if net.getFluidsInNetwork == nil then print(what .. " cannot list fluids"); return end

    local ok, fluids = pcall(net.getFluidsInNetwork)
    if not ok or type(fluids) ~= "table" then
        print("getFluidsInNetwork failed: " .. tostring(fluids)); return
    end
    local list = {}
    for i = 1, #fluids do
        local f = fluids[i]
        if type(f) == "table" and matches(filter, f.label, f.name) then list[#list + 1] = f end
    end
    table.sort(list, function(a, b) return tostring(a.label) < tostring(b.label) end)

    print("== Fluids in " .. what .. (filter and (" matching '" .. filter .. "'") or "") .. " ==")
    for _, f in ipairs(list) do
        print(string.format("%12s L  %-36s name=%s",
            tostring(f.amount), string.format("%q", tostring(f.label)), tostring(f.name)))
    end
    print("Matched " .. #list .. " of " .. #fluids .. " fluid types.")
end

local function dumpSides()
    local n = 0
    for addr in component.list("transposer", true) do
        n = n + 1
        local tp = component.proxy(addr)
        print("== transposer " .. addr .. " ==")
        for side = 0, 5 do
            local okN, name = pcall(tp.getInventoryName, side)
            local okS, size = pcall(tp.getInventorySize, side)
            local okT, tanks = pcall(tp.getTankCount, side)
            local inv = (okN and name) and string.format("%s (%s slots)", tostring(name),
                tostring(okS and size or "?")) or "-"
            local tank = (okT and tanks and tanks > 0) and string.format("  %d tank(s)", tanks) or ""
            if inv ~= "-" or tank ~= "" then
                print(string.format("  %d %-6s %s%s", side, SIDE_LABEL[side], inv, tank))
            end
        end
    end
    print(n .. " transposer(s).")
end

local function slotText(list)
    local parts = {}
    if type(list) == "table" then
        local keys = {}
        for k, s in pairs(list) do
            if type(k) == "number" and type(s) == "table" then keys[#keys + 1] = k end
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local s = list[k]
            -- 2.9 slots are item tables (label/size/name/damage); 2.8 had name/count.
            parts[#parts + 1] = string.format("[%d] %q x%s (%s:%s)", k,
                tostring(s.label or s.name), tostring(s.size or s.count),
                tostring(s.name), tostring(s.damage))
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or "(none)"
end

local function dumpPatterns()
    local _, addr = parseArgs()
    local addrs
    if addr then
        local ok, full = pcall(component.get, addr)
        if not ok or not full then print("no component matches @" .. addr); return end
        addrs = { full }
    else
        addrs = me.interfaces()
    end

    local total = 0
    for _, a in ipairs(addrs) do
        local itf = component.proxy(a)
        local patterns = supply.readPatterns(itf)
        if #patterns > 0 or addr then
            print("== " .. itf.type .. " " .. a .. ": " .. #patterns .. " pattern(s) ==")
        end
        for _, p in ipairs(patterns) do
            total = total + 1
            local e = supply.classify(p)
            local what = e.kind
            if e.kind == "kit" then
                what = "kit " .. tostring(e.material) .. ", " .. tostring(e.perCraft) .. " per craft"
            elseif e.kind == "plasma" then what = "plasma " .. tostring(e.plasma and e.plasma.name)
            elseif e.kind == "drone" then what = "drone " .. tostring(e.drone and e.drone.name)
            else what = "UNKNOWN: " .. tostring(e.reason) end
            print(string.format("  #%d  -> %s", p.index, what))
            print("      in:  " .. slotText(p.inputs))
            print("      out: " .. slotText(p.outputs))
        end
    end
    print(total .. " pattern(s) in " .. #addrs .. " interface(s).")
end

if mode == nil then
    listComponents()
elseif mode == "items" then
    dumpItems()
elseif mode == "fluids" then
    dumpFluids()
elseif mode == "sides" then
    dumpSides()
elseif mode == "patterns" then
    dumpPatterns()
else
    print("Unknown mode '" .. tostring(mode) .. "'. Modes: (none), items, fluids, sides, patterns.")
end

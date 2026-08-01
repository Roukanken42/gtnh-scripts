-- Interactive configuration for the mining controller.
--
-- There is no fully automatic way to learn which transposer + ME interface +
-- input bus serve each mining module, so this walks you through it: it
-- auto-detects everything it can and only asks when a choice is genuinely
-- ambiguous. The result is written to stations.lua (loaded by config.lua).
--
-- What it can do on its own:
--   * find the database, transposers, ME interfaces and miners on the network
--   * classify a transposer's sides by inventory name
--       input bus  -> "gt.blockmachines"
--       interface  -> "tile.appliedenergistics2.BlockInterface" / "tile.fluid_interface"
--   * give stations that SHARE an ME interface distinct staging slots, so their
--     drone loads can run concurrently without colliding
-- When it can't tell sides apart it asks you to poke the intended inventory and
-- watches which side's contents change (any change -- nothing is running). For
-- the ME interface, setting it to stock a marker item both reveals its side on
-- the transposer AND identifies which me_interface component it is (that being
-- the only one left with a stock config), so it never has to ask.
--
-- Run from this folder:  setup

local component = require("component")
local serialization = require("serialization")
local filesystem = require("filesystem")
local shell = require("shell")
local miners = require("miners")

local INPUT_BUS_NAME = "gt.blockmachines"
local INTERFACE_NAMES = {
    ["tile.appliedenergistics2.BlockInterface"] = true,
    ["tile.fluid_interface"] = true,
}
local SIDE_LABEL = {
    [0] = "bottom", [1] = "top", [2] = "north/back",
    [3] = "south/front", [4] = "east/right", [5] = "west/left",
}

-- ---- console helpers -----------------------------------------------------

local function ask(prompt)
    io.write(prompt)
    local line = io.read()
    if line == nil then return "" end
    return (line:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Numbered menu; returns the chosen item, or nil if the user skips.
local function choose(title, items, render)
    print(title)
    for i, it in ipairs(items) do
        print(string.format("  %2d) %s", i, render(it)))
    end
    while true do
        local a = ask("  choose a number (blank to skip): ")
        if a == "" then return nil end
        local n = tonumber(a)
        if n and items[n] then return items[n] end
        print("  ? not a valid choice")
    end
end

local function listByType(t)
    local out = {}
    for addr in component.list(t) do out[#out + 1] = addr end
    return out
end

-- ---- transposer inspection -----------------------------------------------

-- Reads a transposer side's stacks as a plain array (getAllStacks may return a
-- StackSlot with getAll(), or the array directly).
local function readSideStacks(tp, side)
    local ok, res = pcall(tp.getAllStacks, side)
    if not ok or not res then return {} end
    if type(res) == "table" and res.getAll ~= nil then
        local okAll, a = pcall(res.getAll)
        return (okAll and a) or {}
    end
    return res
end

-- A slot-order-independent signature of a side's contents. Used only to tell
-- whether ANYTHING changed after the user pokes an inventory -- nothing is
-- running during setup, so any change (in any slot) is the user.
local function sideSig(tp, side)
    local parts = {}
    local arr = readSideStacks(tp, side)
    for i = 1, #arr do
        local s = arr[i]
        if s and (s.size or 0) > 0 and (s.name or s.label) then
            parts[#parts + 1] = (s.name or s.label) .. "x" .. tostring(s.size)
        end
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

-- True if a me_interface currently has anything configured to stock (any slot).
local function interfaceHasConfig(compAddr)
    local ok, p = pcall(component.proxy, compAddr)
    if not ok or not p or p.getInterfaceConfiguration == nil then return false end
    for slot = 1, 8 do
        local ok2, cfg = pcall(p.getInterfaceConfiguration, slot)
        if ok2 and type(cfg) == "table" and (cfg.name or cfg.label or (cfg.size and cfg.size > 0)) then
            return true
        end
    end
    return false
end

-- Classify all six sides of a transposer by inventory name.
local function scanSides(tp)
    local info = {}
    for side = 0, 5 do
        local ok, name = pcall(tp.getInventoryName, side)
        name = ok and name or nil
        info[side] = {
            name = name,
            isBus = (name == INPUT_BUS_NAME),
            isInterface = (name ~= nil and INTERFACE_NAMES[name] == true),
        }
    end
    return info
end

-- Ask the user to poke the intended inventory and detect which candidate side's
-- contents changed (any change, any slot). Falls back to a manual pick.
local function identifyByInsertion(tp, candidates, thing)
    print("  several sides could be the " .. thing .. ":")
    for _, s in ipairs(candidates) do
        print(string.format("     side %d (%s)", s, SIDE_LABEL[s] or "?"))
    end
    print("  put (or move) ANY item in the " .. thing .. " to identify it.")
    local before = {}
    for _, s in ipairs(candidates) do before[s] = sideSig(tp, s) end
    ask("  press Enter once you have done that... ")
    for _, s in ipairs(candidates) do
        if sideSig(tp, s) ~= before[s] then
            print(string.format("  -> %s is side %d (%s)", thing, s, SIDE_LABEL[s] or "?"))
            return s
        end
    end
    print("  no change detected.")
    return choose("  which side is the " .. thing .. "?", candidates,
        function(s) return string.format("side %d (%s)", s, SIDE_LABEL[s] or "?") end)
end

-- Resolve exactly one side matching `predicate`, auto when unambiguous.
local function resolveSide(tp, info, predicate, thing)
    local cands = {}
    for side = 0, 5 do
        if predicate(info[side]) then cands[#cands + 1] = side end
    end
    if #cands == 0 then
        print("  ! no side looks like the " .. thing .. " on this transposer.")
        return nil
    elseif #cands == 1 then
        print(string.format("  %s: side %d (%s)", thing, cands[1], SIDE_LABEL[cands[1]] or "?"))
        return cands[1]
    end
    return identifyByInsertion(tp, cands, thing)
end

-- ---- pickers -------------------------------------------------------------

local function pickDatabase()
    local dbs = listByType("database")
    if #dbs == 0 then
        print("! No database component found. You need a Database Upgrade (in an")
        print("  adapter or the computer) to stock items from ME. Add one, re-run.")
        return nil
    elseif #dbs == 1 then
        print("Database: " .. dbs[1]:sub(1, 8) .. "..")
        return dbs[1]
    end
    return choose("Multiple databases -- choose the one to use:", dbs,
        function(a) return a end)
end

-- Identify the ME interface serving this transposer -- both which side faces it
-- (when a transposer touches more than one interface) and which me_interface
-- COMPONENT it is (when several exist). Both come from a single marker step: the
-- user sets that interface to stock any item, which makes the item appear on the
-- transposer's interface side AND leaves a stock config on exactly that
-- component (the only one), so we detect it rather than asking. Anything
-- unambiguous resolves with no marker at all.
-- Returns interfaceSide, interfaceComponentAddress (either may be nil).
local function resolveInterface(tp, info, interfaceComps)
    local sideCands = {}
    for side = 0, 5 do
        if info[side].isInterface then sideCands[#sideCands + 1] = side end
    end
    if #sideCands == 0 then
        print("  ! no interface side on this transposer.")
        return nil, nil
    end
    if #interfaceComps == 0 then
        print("  ! no me_interface component found -- the interface needs an adapter")
        print("    so we can call setInterfaceConfiguration/store on it.")
    end

    local side = (#sideCands == 1) and sideCands[1] or nil
    local comp = (#interfaceComps == 1) and interfaceComps[1] or nil

    -- Fully unambiguous (or no component to pick): no marker needed.
    if side and (comp or #interfaceComps == 0) then
        print(string.format("  ME interface: side %d (%s)%s", side, SIDE_LABEL[side] or "?",
            comp and (", component " .. comp:sub(1, 8) .. "..") or ""))
        return side, comp
    end

    print("  identify this transposer's ME interface: in-game, set that interface")
    print("  to STOCK any one item (drop an item into one of its config slots),")
    print("  then press Enter.")
    local sideBefore = {}
    for _, s in ipairs(sideCands) do sideBefore[s] = sideSig(tp, s) end
    local compBefore = {}
    for _, c in ipairs(interfaceComps) do compBefore[c] = interfaceHasConfig(c) end
    ask("  press Enter once it is stocking the marker... ")

    if not side then
        for _, s in ipairs(sideCands) do
            if sideSig(tp, s) ~= sideBefore[s] then side = s; break end
        end
    end
    if not comp then
        -- The interface the user just configured is the newly-stocked one.
        for _, c in ipairs(interfaceComps) do
            if interfaceHasConfig(c) and not compBefore[c] then comp = c; break end
        end
        if not comp then
            for _, c in ipairs(interfaceComps) do
                if interfaceHasConfig(c) then comp = c; break end
            end
        end
    end

    if not side then
        side = choose("  which side is the interface?", sideCands,
            function(s) return string.format("side %d (%s)", s, SIDE_LABEL[s] or "?") end)
    end
    if not comp and #interfaceComps > 0 then
        print("  could not auto-detect the interface component.")
        comp = choose("  which me_interface component?", interfaceComps, function(a) return a end)
    end

    if side then print(string.format("  -> interface side %d (%s)", side, SIDE_LABEL[side] or "?")) end
    if comp then print(string.format("  -> interface component %s..", comp:sub(1, 8))) end
    print("  (you can clear that interface's stock config now)")
    return side, comp
end

local function pickMiner(minerList, used, stationLabel)
    local avail = {}
    for _, m in ipairs(minerList) do
        if not used[m.address] then avail[#avail + 1] = m end
    end
    if #avail == 0 then avail = minerList end
    local render = function(m)
        return string.format("%s..  %s, %d parallels @ %s",
            m.address:sub(1, 8), m.tierName or "?", m.parallels or 0, m.voltName or "?")
    end
    if #avail == 1 then
        print("  serves miner " .. render(avail[1]))
        return avail[1]
    end
    return choose("  which miner does " .. stationLabel .. " serve?", avail, render)
end

-- ---- main flow -----------------------------------------------------------

print("== Mining controller setup ==")

local minerList = miners.discover()
print(string.format("Discovered %d mining module(s).", #minerList))
if #minerList == 0 then
    print("  (looking for gt_machine with getName 'projectmoduleminertN')")
end

local dbAddr = pickDatabase()

local transposers = listByType("transposer")
local interfaceComps = listByType("me_interface")
print(string.format("Found %d transposer(s), %d ME interface(s).",
    #transposers, #interfaceComps))

local stations = {}
local used = {}

for _, tpAddr in ipairs(transposers) do
    print("")
    print("Transposer " .. tpAddr:sub(1, 8) .. "..")
    local tp = component.proxy(tpAddr)
    local info = scanSides(tp)
    for side = 0, 5 do
        if info[side].name then
            print(string.format("  side %d (%-11s): %s",
                side, SIDE_LABEL[side] or "?", info[side].name))
        end
    end

    local busSide = resolveSide(tp, info, function(x) return x.isBus end, "input bus")
    local itfSide, itfComp = resolveInterface(tp, info, interfaceComps)

    if not busSide or not itfSide then
        print("  skipping: could not find both an input bus and an interface side.")
    else
        local miner = pickMiner(minerList, used, tpAddr:sub(1, 8) .. "..")
        if not miner then
            print("  no miner chosen; skipping this transposer.")
        else
            used[miner.address] = true
            stations[miner.address] = {
                label = (miner.tierName or "?") .. " " .. miner.address:sub(1, 8),
                transposer = tpAddr,
                interface = itfComp,
                interfaceSide = itfSide,
                inputBusSide = busSide,
            }
            print(string.format("  bound: bus side %d, interface side %d.", busSide, itfSide))
        end
    end
end

-- ---- assign distinct interface slots -------------------------------------
-- One ME interface can serve several transposers. Concurrent drone loads stage
-- through the interface's config slots, so stations sharing an interface must
-- each use a DIFFERENT slot. Assign deterministically (sorted by miner address),
-- 1..8 per interface.
local orderedKeys = {}
for addr in pairs(stations) do orderedKeys[#orderedKeys + 1] = addr end
table.sort(orderedKeys)
do
    local nextSlot = {}
    for _, addr in ipairs(orderedKeys) do
        local st = stations[addr]
        if st.interface then
            local n = (nextSlot[st.interface] or 0) + 1
            nextSlot[st.interface] = n
            st.interfaceSlot = n
            if n > 8 then
                print(string.format("WARNING: %d stations share interface %s.. (only 8 slots)"
                    .. " -- concurrent loads may collide.", n, st.interface:sub(1, 8)))
            end
        else
            st.interfaceSlot = 1
        end
    end
end

-- ---- write stations.lua --------------------------------------------------

local count = #orderedKeys

local payload = { database = dbAddr, stations = stations }
local text = table.concat({
    "-- Generated by mining/setup.lua. Machine-specific; safe to regenerate.",
    "-- Loaded by config.lua. NOT part of the repo/manifest.",
    "return " .. serialization.serialize(payload, true),
    "",
}, "\n")

local path = filesystem.concat(shell.getWorkingDirectory(), "stations.lua")
local f, err = io.open(path, "w")
if not f then
    print("")
    print("! could not write " .. path .. ": " .. tostring(err))
    print("Config below -- paste it into stations.lua yourself:")
    print(text)
    return
end
f:write(text)
f:close()

print("")
print(string.format("Wrote %d station(s) to %s", count, path))
for _, addr in ipairs(orderedKeys) do
    local st = stations[addr]
    print(string.format("  %s: transposer %s.. bus=side%d interface=side%d slot=%d",
        st.label, st.transposer:sub(1, 8), st.inputBusSide, st.interfaceSide, st.interfaceSlot))
end
if not dbAddr then
    print("WARNING: no database configured -- drone loading will not work until you add one.")
end
print("Keep cfg.dryRun = true until you've watched a drone move, then flip it.")

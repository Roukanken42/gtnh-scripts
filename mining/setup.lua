-- Interactive configuration for the mining controller.
--
-- There is no fully automatic way to learn which transposer + ME interface +
-- input bus serve each mining module, so this walks you through it: it
-- auto-detects everything it can and only asks when a choice is genuinely
-- ambiguous. The result is written to stations.lua (loaded by config.lua).
--
-- It is INCREMENTAL: re-running loads the existing stations.lua, leaves already-
-- configured transposers/miners untouched (keeping their interface slots), and
-- only configures new ones -- so you can add modules a few at a time.
--
-- What it can do on its own:
--   * find the database, transposers, ME interfaces and miners on the network
--   * classify a transposer's sides by inventory name
--       input bus  -> "gt.blockmachines"
--       interface  -> "tile.appliedenergistics2.BlockInterface" / "tile.fluid_interface"
--   * give stations that SHARE an ME interface distinct staging slots, so their
--     drone loads can run concurrently without colliding
-- Disambiguation, when it can't tell things apart, is done by live polling --
-- nothing is running during setup, so any change is you:
--   * input bus side  -- put an item in the bus; the side whose contents change.
--   * ME interface     -- when the transposer has one interface side it AUTO-
--                         probes: it stocks a probe item on each me_interface in
--                         turn and watches that side, no action needed. Only if
--                         the side itself is ambiguous (or probing is
--                         inconclusive) does it ask you to stock a marker item.
--   * which miner a transposer serves -- it disables every candidate miner, you
--                         switch the right one on, then it restores their states.
--
-- Run from this folder:  setup

local component = require("component")
local computer = require("computer")
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

-- How long to watch for a marker (interface stock config, or a miner being
-- switched on) before giving up and asking the user to pick manually.
local IDENTIFY_TIMEOUT = 120
local POLL_INTERVAL = 0.5

-- Interface auto-probe: to learn which me_interface a transposer feeds, we stock
-- a probe item on each candidate in turn and watch the transposer's interface
-- side. PROBE_TIMEOUT is how long to wait for one candidate to stock before
-- ruling it out; PROBE_CFG_SLOT / PROBE_DB_SLOT are the interface config slot and
-- database slot we borrow for the probe.
local PROBE_TIMEOUT = 4
local PROBE_CFG_SLOT = 9
local PROBE_DB_SLOT = 1

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

-- Loads an existing stations.lua (setup's own output) so a re-run is
-- incremental. Returns { database=, stations= }, or nil if absent/unreadable.
local function loadExisting(path)
    if not filesystem.exists(path) then return nil end
    local chunk = loadfile(path)
    if not chunk then return nil end
    local ok, data = pcall(chunk)
    if ok and type(data) == "table" then return data end
    return nil
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
-- running during setup, so any change (in any slot) is the user. The transposer
-- indexes inventories from 0, so we iterate with pairs (which catches slot 0).
local function sideSig(tp, side)
    local parts = {}
    for _, s in pairs(readSideStacks(tp, side)) do
        if type(s) == "table" and (s.size or 0) > 0 and (s.name or s.label) then
            parts[#parts + 1] = (s.name or s.label) .. "x" .. tostring(s.size)
        end
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

-- Signature of a me_interface's full stock configuration (config slots 1..9,
-- 1-based on the interface). We compare it before/after the user drops a marker
-- into one slot: the interface whose signature CHANGES is the one they
-- configured. getInterfaceConfiguration returns a normal item stack, so we key
-- on its label/name/size.
local function interfaceConfigSig(compAddr)
    local ok, p = pcall(component.proxy, compAddr)
    if not ok or not p or p.getInterfaceConfiguration == nil then return "" end
    local parts = {}
    for slot = 1, 9 do
        local ok2, cfg = pcall(p.getInterfaceConfiguration, slot)
        if ok2 and type(cfg) == "table" then
            parts[#parts + 1] = string.format("%s/%s/%s",
                tostring(cfg.label), tostring(cfg.name), tostring(cfg.size))
        else
            parts[#parts + 1] = ""
        end
    end
    return table.concat(parts, "|")
end

-- Clears stock config on a me_interface: one slot if `onlySlot` is given, else
-- all slots (1..9). Used to tidy up markers/probes after identification.
local function clearInterfaceConfig(compAddr, onlySlot)
    if not compAddr then return end
    local ok, p = pcall(component.proxy, compAddr)
    if not ok or not p or p.setInterfaceConfiguration == nil then return end
    if onlySlot then
        pcall(p.setInterfaceConfiguration, onlySlot)
    else
        for slot = 1, 9 do pcall(p.setInterfaceConfiguration, slot) end
    end
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

-- Stores any in-stock network item's metadata into PROBE_DB_SLOT for use as a
-- probe. Returns the db slot on success, or nil. `refComp` is any me_interface.
local function storeProbeItem(refComp, dbAddr)
    local ok, p = pcall(component.proxy, refComp)
    if not ok or not p or p.getItemsInNetwork == nil or p.store == nil then return nil end
    local okDb, db = pcall(component.proxy, dbAddr)
    if not okDb or not db or db.get == nil then return nil end
    local okItems, items = pcall(p.getItemsInNetwork)
    if not okItems or type(items) ~= "table" then return nil end
    for _, it in ipairs(items) do
        if it and it.label and (it.size or 0) > 0 then
            pcall(db.clear, PROBE_DB_SLOT)
            local okStore = pcall(p.store, { label = it.label }, dbAddr, PROBE_DB_SLOT, 1)
            local okGet, st = pcall(db.get, PROBE_DB_SLOT)
            if okStore and okGet and type(st) == "table" and (st.name or st.label) then
                return PROBE_DB_SLOT
            end
        end
    end
    return nil
end

-- Identify which me_interface sits on the transposer's `interfaceSide`, with no
-- user action: stock a probe item on each candidate in turn and watch that side
-- -- the one whose stock shows up there is the adjacent interface. Needs the
-- database and a network item. Returns the matched component address, or nil if
-- inconclusive (caller then falls back to the manual marker).
local function probeInterfaceComponent(tp, interfaceSide, interfaceComps, dbAddr)
    if not dbAddr or #interfaceComps == 0 then return nil end
    local dbSlot = storeProbeItem(interfaceComps[1], dbAddr)
    if not dbSlot then return nil end

    print("  auto-detecting interface (probing up to " .. #interfaceComps .. ")...")
    local found
    for _, c in ipairs(interfaceComps) do
        local before = sideSig(tp, interfaceSide)
        local ok, p = pcall(component.proxy, c)
        if ok and p and p.setInterfaceConfiguration ~= nil then
            pcall(p.setInterfaceConfiguration, PROBE_CFG_SLOT, dbAddr, dbSlot, 1)
            local deadline = computer.uptime() + PROBE_TIMEOUT
            while computer.uptime() < deadline do
                if sideSig(tp, interfaceSide) ~= before then found = c; break end
                os.sleep(POLL_INTERVAL)
            end
            clearInterfaceConfig(c, PROBE_CFG_SLOT)   -- clear just the probe slot
        end
        if found then break end
    end

    local okDb, db = pcall(component.proxy, dbAddr)   -- tidy the probe metadata
    if okDb and db and db.clear then pcall(db.clear, PROBE_DB_SLOT) end
    return found
end

-- Identify the ME interface serving this transposer -- both which side faces it
-- (when a transposer touches more than one interface) and which me_interface
-- COMPONENT it is (when several exist). When the interface side is unambiguous we
-- auto-probe the components (no user action); otherwise a single marker step (the
-- user sets an interface to stock any item) reveals the side and the component.
-- Anything unambiguous resolves with nothing to do.
-- Returns interfaceSide, interfaceComponentAddress (either may be nil).
local function resolveInterface(tp, info, interfaceComps, dbAddr)
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

    -- One interface side, several components: find the adjacent one by probing --
    -- no user action needed.
    if side and not comp then
        local probed = probeInterfaceComponent(tp, side, interfaceComps, dbAddr)
        if probed then
            print(string.format("  ME interface: side %d (%s), component %s.. (auto-detected)",
                side, SIDE_LABEL[side] or "?", probed:sub(1, 8)))
            return side, probed
        end
        print("  auto-detect inconclusive; falling back to the marker.")
    end

    print("  identify this transposer's ME interface: in-game, set that interface")
    print("  to STOCK any one item (drop an item into one of its config slots).")
    print("  watching for it...")
    local sideBefore = {}
    for _, s in ipairs(sideCands) do sideBefore[s] = sideSig(tp, s) end
    local compBefore = {}
    for _, c in ipairs(interfaceComps) do compBefore[c] = interfaceConfigSig(c) end

    -- Poll until the marker reveals the component (and/or the side), or we time
    -- out. The interface whose stock config changes is the one the user set.
    local needComp = (#interfaceComps > 0)
    local deadline = computer.uptime() + IDENTIFY_TIMEOUT
    while true do
        if not comp then
            for _, c in ipairs(interfaceComps) do
                if interfaceConfigSig(c) ~= compBefore[c] then comp = c; break end
            end
        end
        if not side then
            for _, s in ipairs(sideCands) do
                if sideSig(tp, s) ~= sideBefore[s] then side = s; break end
            end
        end
        if side and (comp or not needComp) then break end
        if computer.uptime() >= deadline then break end
        os.sleep(POLL_INTERVAL)
    end

    -- Fall back to a manual pick for anything still unresolved.
    if not side then
        side = choose("  timed out -- which side is the interface?", sideCands,
            function(s) return string.format("side %d (%s)", s, SIDE_LABEL[s] or "?") end)
    end
    if not comp and needComp then
        comp = choose("  timed out -- which me_interface component?", interfaceComps,
            function(a) return a end)
    end

    -- Auto-clear the marker stock config so the user does not have to.
    if comp then
        clearInterfaceConfig(comp)
        print("  cleared the marker config on " .. comp:sub(1, 8) .. "..")
    end

    if side then print(string.format("  -> interface side %d (%s)", side, SIDE_LABEL[side] or "?")) end
    if comp then print(string.format("  -> interface component %s..", comp:sub(1, 8))) end
    return side, comp
end

-- Reads whether a miner is currently allowed to work (its on/off state).
local function minerOn(m)
    local ok, v = pcall(m.proxy.isWorkAllowed)
    return ok and v == true
end

-- Identify which discovered miner a transposer serves by having the user switch
-- it on: disable every candidate, watch for one to be turned back on, then
-- restore each miner's original state. Auto-picks when only one is unassigned;
-- falls back to a manual list on timeout.
local function identifyMiner(minerList, used)
    local cands = {}
    for _, m in ipairs(minerList) do
        if not used[m.address] then cands[#cands + 1] = m end
    end
    if #cands == 0 then cands = minerList end

    local render = function(m)
        return string.format("%s..  %s, %d parallels @ %s",
            m.address:sub(1, 8), m.tierName or "?", m.parallels or 0, m.voltName or "?")
    end
    if #cands == 1 then
        print("  serves miner " .. render(cands[1]))
        return cands[1]
    end

    -- Snapshot each candidate's on/off state, then disable them all.
    local wasOn = {}
    for _, m in ipairs(cands) do
        wasOn[m.address] = minerOn(m)
        m:setEnabled(false)
    end
    os.sleep(POLL_INTERVAL)   -- let the disables register before we poll
    print("  disabled all candidate miners. Now ENABLE (turn on) the one this")
    print("  transposer serves. Watching...")

    local found
    local deadline = computer.uptime() + IDENTIFY_TIMEOUT
    while not found and computer.uptime() < deadline do
        for _, m in ipairs(cands) do
            if minerOn(m) then found = m; break end
        end
        if not found then os.sleep(POLL_INTERVAL) end
    end

    -- Cleanup: restore every candidate to the state it had before we started.
    for _, m in ipairs(cands) do
        m:setEnabled(wasOn[m.address] == true)
    end

    if found then
        print("  -> " .. render(found))
        return found
    end
    print("  timed out; pick manually.")
    return choose("  which miner does this transposer serve?", cands, render)
end

-- ---- module exports ------------------------------------------------------
-- Returned when this file is require()'d, so the helpers can be called directly
-- to debug detection -- e.g. from the OpenOS Lua prompt:
--     S   = require("setup")               -- returns this table; runs nothing
--     ifs = S.listByType("me_interface")
--     tp  = require("component").proxy("<transposer-address>")
--     S.interfaceConfigSig(ifs[1])
--     S.probeInterfaceComponent(tp, <side>, ifs, "<database-address>")
-- Running `setup` as a program still launches the interactive flow below.
local M = {
    listByType = listByType,
    loadExisting = loadExisting,
    readSideStacks = readSideStacks,
    sideSig = sideSig,
    interfaceConfigSig = interfaceConfigSig,
    clearInterfaceConfig = clearInterfaceConfig,
    scanSides = scanSides,
    identifyByInsertion = identifyByInsertion,
    resolveSide = resolveSide,
    pickDatabase = pickDatabase,
    storeProbeItem = storeProbeItem,
    probeInterfaceComponent = probeInterfaceComponent,
    resolveInterface = resolveInterface,
    minerOn = minerOn,
    identifyMiner = identifyMiner,
    INTERFACE_NAMES = INTERFACE_NAMES,
    INPUT_BUS_NAME = INPUT_BUS_NAME,
    SIDE_LABEL = SIDE_LABEL,
}

-- When loaded via require (to poke the helpers) rather than run as the `setup`
-- program, stop here -- don't run the interactive flow. The two are told apart
-- by the running process's path.
do
    local ok, info = pcall(function() return require("process").info() end)
    local asProgram = ok and info and type(info.path) == "string"
        and info.path:find("setup%.lua$") ~= nil
    if not asProgram then return M end
end

-- ---- main flow -----------------------------------------------------------

print("== Mining controller setup ==")

-- Incremental: load any existing stations.lua and keep what's already there, so
-- a re-run only configures new / not-yet-configured components.
local path = filesystem.concat(shell.getWorkingDirectory(), "stations.lua")
local existing = loadExisting(path)
local stations = {}
local used = {}              -- miner addresses already bound
local usedTransposers = {}   -- transposer addresses already bound
local dbAddr
if existing then
    dbAddr = existing.database
    local n = 0
    for addr, st in pairs(existing.stations or {}) do
        stations[addr] = st
        used[addr] = true
        if st.transposer then usedTransposers[st.transposer] = true end
        n = n + 1
    end
    print(string.format("Loaded %d existing station(s); leaving those as-is.", n))
end

local minerList = miners.discover()
print(string.format("Discovered %d mining module(s).", #minerList))
if #minerList == 0 then
    print("  (looking for gt_machine with getName 'projectmoduleminertN')")
end

if dbAddr then
    print("Database (from existing config): " .. dbAddr:sub(1, 8) .. "..")
else
    dbAddr = pickDatabase()
end

local transposers = listByType("transposer")
local interfaceComps = listByType("me_interface")
print(string.format("Found %d transposer(s), %d ME interface(s).",
    #transposers, #interfaceComps))

-- Skip transposers already bound to a station on a previous run.
local toConfigure = {}
for _, tpAddr in ipairs(transposers) do
    if usedTransposers[tpAddr] then
        print("Transposer " .. tpAddr:sub(1, 8) .. ".. already configured; skipping.")
    else
        toConfigure[#toConfigure + 1] = tpAddr
    end
end

for _, tpAddr in ipairs(toConfigure) do
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
    local itfSide, itfComp = resolveInterface(tp, info, interfaceComps, dbAddr)

    if not busSide or not itfSide then
        print("  skipping: could not find both an input bus and an interface side.")
    else
        local miner = identifyMiner(minerList, used)
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
-- each use a DIFFERENT slot. Existing stations keep the slot they were given;
-- only newly-added ones get the next free slot on their interface.
local orderedKeys = {}
for addr in pairs(stations) do orderedKeys[#orderedKeys + 1] = addr end
table.sort(orderedKeys)
do
    -- Record slots already taken on each interface (by existing stations).
    local taken = {}
    for _, addr in ipairs(orderedKeys) do
        local st = stations[addr]
        if st.interface and st.interfaceSlot then
            taken[st.interface] = taken[st.interface] or {}
            taken[st.interface][st.interfaceSlot] = true
        end
    end
    -- Assign a free slot to each station that doesn't have one yet.
    for _, addr in ipairs(orderedKeys) do
        local st = stations[addr]
        if not st.interfaceSlot then
            if st.interface then
                local set = taken[st.interface] or {}
                taken[st.interface] = set
                local n = 1
                while set[n] do n = n + 1 end
                set[n] = true
                st.interfaceSlot = n
                if n > 9 then
                    print(string.format("WARNING: interface %s.. now has %d stations (>9 slots)"
                        .. " -- concurrent loads may collide.", st.interface:sub(1, 8), n))
                end
            else
                st.interfaceSlot = 1
            end
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

return M

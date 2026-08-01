-- Fully-automatic configuration for the mining controller.
--
-- Figures out, with no user interaction (unless something genuinely fails), how
-- to feed a drone to every mining module, and writes the result to stations.lua
-- (loaded by config.lua).
--
-- How it works:
--   1. The local space-mining ME net is reached via an adapter on its ME
--      Controller (component me_controller); the drones live there. We take the
--      LOWEST-tier drone in stock as a probe -- a low drone runs in any module,
--      a high one won't run a low-tier module.
--   2. For each transposer, we stock that probe drone on each me_interface in
--      turn and watch whether the transposer can see it -- that pairs the
--      transposer with its interface and tells us which side faces it. The
--      network has interfaces on OTHER nets too, so this is time-boxed, and we
--      use "did a drone leave the local net?" to skip non-local interfaces fast.
--   3. For every input bus a transposer reaches, we find its miner: empty the
--      buses, drop a drone in one, turn the miners on, and see which one starts
--      mining (isMachineActive => it has a drone). isMachineActive lags after a
--      miner is switched off, so already-found miners are ignored.
--   4. Each (miner -> transposer + interface + sides) becomes a station.
--
-- Run from this folder:  setup
-- require("setup") returns the helper functions (for debugging) without running.

local component = require("component")
local computer = require("computer")
local serialization = require("serialization")
local filesystem = require("filesystem")
local shell = require("shell")
local miners = require("miners")
local drones = require("drones")
local localnet = require("localnet")
local transport = require("transport")

local INPUT_BUS_NAME = "gt.blockmachines"
local INTERFACE_NAMES = {
    ["tile.appliedenergistics2.BlockInterface"] = true,
    ["tile.fluid_interface"] = true,
}
local SIDE_LABEL = {
    [0] = "bottom", [1] = "top", [2] = "north/back",
    [3] = "south/front", [4] = "east/right", [5] = "west/left",
}

local POLL_INTERVAL = 0.5
-- Interface + side detection is time-boxed: the network has interfaces that are
-- NOT on the local mining net, and we don't want to wait on every one.
local DETECT_PER_CANDIDATE = 3   -- s to watch one interface for the probe drone
local DETECT_BUDGET = 30         -- s total to find a single transposer's interface
local DETECT_LOCAL_HINT = 1.5    -- s: if no drone has left the local net by now, skip
-- How long to wait for a miner to start mining once its bus has a drone.
local MINER_TIMEOUT = 15
-- ME interface config slot we stage the probe drone through (1-based on the
-- interface; the transposer sees it at slot-1). Config slot 1's item does not
-- surface to the transposer, so use 2.
local PROBE_CFG_SLOT = 2
local PROBE_DB_SLOT = 1

-- ---- helpers -------------------------------------------------------------

local function listByType(t)
    local out = {}
    for addr in component.list(t) do out[#out + 1] = addr end
    return out
end

-- Reads a transposer side's stacks as a plain array (0-indexed on the transposer).
local function readSideStacks(tp, side)
    local ok, res = pcall(tp.getAllStacks, side)
    if not ok or not res then return {} end
    if type(res) == "table" and res.getAll ~= nil then
        local okAll, a = pcall(res.getAll)
        return (okAll and a) or {}
    end
    return res
end

-- True if the transposer sees an item with `label` on `side` (any slot).
local function sideHasLabel(tp, side, label)
    for _, s in pairs(readSideStacks(tp, side)) do
        if type(s) == "table" and s.label == label and (s.size or 0) > 0 then
            return true
        end
    end
    return false
end

-- Classify a transposer's six sides: returns the interface-candidate sides and
-- the input-bus sides.
local function scanSides(tp)
    local ifSides, busSides = {}, {}
    for side = 0, 5 do
        local ok, name = pcall(tp.getInventoryName, side)
        name = ok and name or nil
        if name == INPUT_BUS_NAME then
            busSides[#busSides + 1] = side
        elseif name and INTERFACE_NAMES[name] then
            ifSides[#ifSides + 1] = side
        end
    end
    return ifSides, busSides
end

-- Stores the probe drone's metadata into the database via the local net (for use
-- with setInterfaceConfiguration). Returns the db slot, or nil + error.
local function storeProbe(net, dbAddr, probe)
    if net.store == nil then return nil, "local net has no store()" end
    pcall(net.store, { label = probe.label }, dbAddr, PROBE_DB_SLOT, 1)
    local okp, db = pcall(component.proxy, dbAddr)
    if okp and db and db.get then
        local okg, st = pcall(db.get, PROBE_DB_SLOT)
        if okg and type(st) == "table" and (st.name or st.label) then return PROBE_DB_SLOT end
    end
    return nil, "database did not accept the probe drone"
end

-- Finds which me_interface a transposer feeds: stock the probe drone on each
-- interface in turn and see whether the transposer can see it. A drone leaving
-- the local net confirms the interface is local; the transposer seeing it
-- confirms it is the ADJACENT one. Time-boxed. Returns interfaceAddr, side.
local function detectInterface(tp, ifSides, interfaceComps, dbAddr, dbSlot, probe, net)
    local budget = computer.uptime() + DETECT_BUDGET
    for _, c in ipairs(interfaceComps) do
        if computer.uptime() >= budget then break end
        local ok, p = pcall(component.proxy, c)
        if ok and p and p.setInterfaceConfiguration ~= nil then
            local before = localnet.countOf(probe.label, net)
            pcall(p.setInterfaceConfiguration, PROBE_CFG_SLOT, dbAddr, dbSlot, 1)

            local foundSide, start = nil, computer.uptime()
            local candEnd = start + DETECT_PER_CANDIDATE
            while computer.uptime() < candEnd do
                for _, side in ipairs(ifSides) do
                    if sideHasLabel(tp, side, probe.label) then foundSide = side; break end
                end
                if foundSide then break end
                -- Skip fast if this interface clearly isn't stocking from the
                -- local net (i.e. not on it) after a short grace period.
                if computer.uptime() - start > DETECT_LOCAL_HINT
                    and localnet.countOf(probe.label, net) >= before then
                    break
                end
                os.sleep(POLL_INTERVAL)
            end

            pcall(p.setInterfaceConfiguration, PROBE_CFG_SLOT)   -- clear (drone back to net)
            if foundSide then return c, foundSide end
        end
    end
    return nil, nil
end

-- Miner state readers.
local function minerActive(m)  -- currently mining
    local ok, v = pcall(m.proxy.isMachineActive)
    return ok and v == true
end
local function minerOn(m)      -- allowed to work (soft on/off)
    local ok, v = pcall(m.proxy.isWorkAllowed)
    return ok and v == true
end

-- Picks the database to stage probes through (first one found).
local function pickDatabase()
    return listByType("database")[1]
end

-- ---- module exports ------------------------------------------------------
-- Returned when require()'d, so the helpers can be poked at for debugging.
-- Running `setup` as a program launches the automatic flow below.
local M = {
    listByType = listByType,
    readSideStacks = readSideStacks,
    sideHasLabel = sideHasLabel,
    scanSides = scanSides,
    storeProbe = storeProbe,
    detectInterface = detectInterface,
    minerActive = minerActive,
    minerOn = minerOn,
    pickDatabase = pickDatabase,
    INTERFACE_NAMES = INTERFACE_NAMES,
    INPUT_BUS_NAME = INPUT_BUS_NAME,
    SIDE_LABEL = SIDE_LABEL,
}

do
    local ok, info = pcall(function() return require("process").info() end)
    local asProgram = ok and info and type(info.path) == "string"
        and info.path:find("setup%.lua$") ~= nil
    if not asProgram then return M end
end

-- ---- automatic flow ------------------------------------------------------

print("== Mining controller setup (automatic) ==")

-- 1. Local net + probe drone.
local net, nerr = localnet.proxy()
if not net then print("ERROR: " .. nerr); return M end
local probe = localnet.lowestDrone(net)
if not probe then
    print("ERROR: no mining drones in the local net -- keep a few of the lowest")
    print("       tier in stock so setup can borrow one to probe with.")
    return M
end
local probeDrone = drones.fromName(probe.label) or { name = probe.label }
print(string.format("Local net OK. Probe drone: %s (tier %s).",
    probe.label, tostring(probe.tier)))

-- 2. Database for staging probes.
local dbAddr = pickDatabase()
if not dbAddr then
    print("ERROR: no database component. Add a Database Upgrade in an adapter.")
    return M
end
local dbSlot, derr = storeProbe(net, dbAddr, probe)
if not dbSlot then print("ERROR: " .. tostring(derr)); return M end

local transposers = listByType("transposer")
local interfaceComps = listByType("me_interface")
local minerList = miners.discover()
print(string.format("Found %d transposer(s), %d interface(s), %d miner(s).",
    #transposers, #interfaceComps, #minerList))

-- 3. Pair each transposer with its interface; collect its input buses.
local feeds = {}   -- { transposer, interface, interfaceSide, inputBusSide }
for _, tpAddr in ipairs(transposers) do
    local tp = component.proxy(tpAddr)
    local ifSides, busSides = scanSides(tp)
    if #ifSides == 0 then
        print(string.format("  %s..: no interface side -- skipped (each transposer needs one).",
            tpAddr:sub(1, 8)))
    elseif #busSides == 0 then
        print(string.format("  %s..: no input bus -- skipped.", tpAddr:sub(1, 8)))
    else
        local ifAddr, ifSide = detectInterface(tp, ifSides, interfaceComps, dbAddr, dbSlot, probe, net)
        if not ifAddr then
            print(string.format("  %s..: could not detect its interface (timed out).",
                tpAddr:sub(1, 8)))
        else
            print(string.format("  %s..: interface %s.. on side %d, %d input bus(es).",
                tpAddr:sub(1, 8), ifAddr:sub(1, 8), ifSide, #busSides))
            for _, busSide in ipairs(busSides) do
                feeds[#feeds + 1] = {
                    transposer = tpAddr, interface = ifAddr,
                    interfaceSide = ifSide, inputBusSide = busSide,
                }
            end
        end
    end
end
if #feeds == 0 then print("No usable input buses found -- nothing to configure."); return M end

-- Build a transport.Station for a feed. Slot is fixed here (we load buses one at
-- a time during identification, so there is no concurrency to collide).
local function stationFor(feed)
    return transport.new({
        transposer = feed.transposer, interface = feed.interface,
        database = dbAddr, interfaceSide = feed.interfaceSide,
        inputBusSide = feed.inputBusSide, interfaceSlot = PROBE_CFG_SLOT,
        stockTimeout = 20,
    })
end

-- 4. Identify the miner behind each input bus. Empty the buses, enable all
--    miners, then load one drone at a time and watch which miner starts.
print("Emptying input buses...")
for _, feed in ipairs(feeds) do
    local st = stationFor(feed)
    if st then st:returnAll() end
end

local wasOn = {}
for _, m in ipairs(minerList) do
    wasOn[m.address] = minerOn(m)
    m:setEnabled(true)
end

-- TODO(next part): a mining module needs more than a drone to actually produce
-- (target/planet selection, output filters, ...). Once we know that API, capture
-- each module's extra config here alongside the bus->miner mapping so the
-- controller can drive it.

print("Identifying miners...")
local assigned = {}   -- miner address -> feed
for _, feed in ipairs(feeds) do
    local st = stationFor(feed)
    if st then
        local ok, err = st:setDrone(probeDrone, 1)
        if not ok then
            print(string.format("  bus %s../side%d: could not load a probe drone (%s).",
                feed.transposer:sub(1, 8), feed.inputBusSide, tostring(err)))
        else
            local found
            local deadline = computer.uptime() + MINER_TIMEOUT
            while computer.uptime() < deadline do
                for _, m in ipairs(minerList) do
                    if not assigned[m.address] and minerActive(m) then found = m; break end
                end
                if found then break end
                os.sleep(POLL_INTERVAL)
            end
            if found then
                assigned[found.address] = feed
                print(string.format("  miner %s.. <- transposer %s.. bus side %d",
                    found.address:sub(1, 8), feed.transposer:sub(1, 8), feed.inputBusSide))
            else
                print(string.format("  bus %s../side%d: no new miner started (already found, or none).",
                    feed.transposer:sub(1, 8), feed.inputBusSide))
            end
        end
        st:returnAll()   -- empty this bus before testing the next
    end
end

-- Restore miners to their original on/off state, and tidy the probe metadata.
for _, m in ipairs(minerList) do m:setEnabled(wasOn[m.address] == true) end
local okdb, db = pcall(component.proxy, dbAddr)
if okdb and db and db.clear then pcall(db.clear, PROBE_DB_SLOT) end

-- 5. Build stations, assign a distinct interface slot per shared interface.
local minerByAddr = {}
for _, m in ipairs(minerList) do minerByAddr[m.address] = m end
local stations = {}
for addr, feed in pairs(assigned) do
    local m = minerByAddr[addr]
    stations[addr] = {
        label = (m and m.tierName or "?") .. " " .. addr:sub(1, 8),
        transposer = feed.transposer,
        interface = feed.interface,
        interfaceSide = feed.interfaceSide,
        inputBusSide = feed.inputBusSide,
    }
end

local keys = {}
for a in pairs(stations) do keys[#keys + 1] = a end
table.sort(keys)
do
    local nextSlot = {}
    for _, a in ipairs(keys) do
        local st = stations[a]
        local n = (nextSlot[st.interface] or 0) + 1
        nextSlot[st.interface] = n
        st.interfaceSlot = n
        if n > 9 then
            print(string.format("WARNING: interface %s.. has %d stations (>9 slots) -- "
                .. "concurrent loads may collide.", st.interface:sub(1, 8), n))
        end
    end
end

-- 6. Write stations.lua.
local payload = { database = dbAddr, stations = stations }
local text = table.concat({
    "-- Generated by mining/setup.lua (automatic). Machine-specific; safe to regenerate.",
    "-- Loaded by config.lua. NOT part of the repo/manifest.",
    "return " .. serialization.serialize(payload, true),
    "",
}, "\n")

local path = filesystem.concat(shell.getWorkingDirectory(), "stations.lua")
local f, ferr = io.open(path, "w")
if not f then
    print("! could not write " .. path .. ": " .. tostring(ferr))
    print(text)
    return M
end
f:write(text)
f:close()

print(string.format("Wrote %d station(s) to %s", #keys, path))
for _, a in ipairs(keys) do
    local st = stations[a]
    print(string.format("  %s: transposer %s.. bus=side%d interface=side%d slot=%d",
        st.label, st.transposer:sub(1, 8), st.inputBusSide, st.interfaceSide, st.interfaceSlot))
end
print("Keep cfg.dryRun = true until you've watched a drone move, then flip it.")

return M

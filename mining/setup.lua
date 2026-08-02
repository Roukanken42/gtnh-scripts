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
--      transposer with its interface and tells us which side faces it. The base
--      has interfaces on OTHER nets too, so the list is first narrowed to the
--      ones whose own network actually holds the probe; only those can stage it.
--   3. A module only mines with a drone, KITS and PLASMA all present, so both
--      detection phases below need the other two inputs already satisfied:
--        * kits arrive from the local net by themselves (they are chosen by the
--          drone), so setup only makes sure the probe drone's kits are in stock;
--        * plasma is placed by us, through the fluid half of a station.
--   4. PHASE A -- buses. Give every fluid hatch a little plasma, then drop a drone
--      into one bus at a time and see which miner starts mining. That pairs each
--      input bus with its miner.
--   5. PHASE B -- hatches. The reverse: put a drone in EVERY bus, empty every
--      hatch, then fill one hatch at a time and see which miner starts. That pairs
--      each input hatch with its miner. The miners are stopped and allowed to
--      settle in between, because isMachineActive lags.
--   6. Each (miner -> item transposer + fluid transposer + sides) becomes a station.
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
local dbslots = require("db")
local supply = require("supply")
local plasmas = require("plasmas")

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
-- How long to watch one candidate interface for the probe to appear. There is no
-- overall budget: candidates are narrowed to the networks that actually hold the
-- probe first (see interfacesHolding), so the list is short by the time we get
-- here, and giving up early looks exactly like "nothing feeds this transposer".
local DETECT_PER_CANDIDATE = 3
-- How long to wait for a miner to start mining once its bus has a drone.
local MINER_TIMEOUT = 15
-- How long to wait for already-running miners to actually stop after we switch
-- them off (isMachineActive lags) before detection begins.
local SETTLE_TIMEOUT = 60
-- ME interface config slot we stage the probe drone through (1-based on the
-- interface; the transposer sees it at slot-1). Config slot 1's item does not
-- surface to the transposer, so use 2.
local PROBE_CFG_SLOT = 2

-- Fluid probing. The interface tank we stage plasma through during detection
-- (0-BASED, like every fluid-interface index -- see transport.lua), and the db
-- slot its ae2fc drop goes in.
local PROBE_FLUID_TANK = 0
-- Plasma put in a hatch to make a module runnable. One operation costs
-- (consumed x parallels), at worst 825 x 8 for Helium, so this covers a few.
local PROBE_PLASMA_L = 8000
-- Kits to have in the local net before detecting. Detection runs a module flat
-- out for up to MINER_TIMEOUT, and the probe is the LOWEST-tier drone, so these
-- are the cheapest kits there are.
local PROBE_KITS = 256
-- How long to wait for a staged fluid to show up.
local FLUID_TIMEOUT = 20
-- How long to wait on a supply request for kits or plasma. A large plasma order
-- arrives in pieces, so this is the settle window as well as the job window.
local STOCK_TIMEOUT = 30
-- One ME fluid interface tank. Each hatch is staged through its own, and they are
-- all stocked at once, so this is charged per hatch rather than once overall.
local STAGING_L = 16000

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

-- How many tanks with REAL CAPACITY a side has. This is what tells an input HATCH
-- from an input BUS: both report the same "gt.blockmachines" inventory name, and
-- only the hatch has a tank. Capacity rather than level -- an empty hatch reads
-- level 0 exactly like a bus does.
local function tankCount(tp, side)
    local ok, n = pcall(tp.getTankCount, side)
    n = (ok and tonumber(n)) or 0
    local real = 0
    for t = 1, n do
        local okc, cap = pcall(tp.getTankCapacity, side, t)
        if okc and (tonumber(cap) or 0) > 0 then real = real + 1 end
    end
    return real
end

-- How many item slots a side has. Nothing to do with fluids -- see tankCount.
local function inventorySize(tp, side)
    local ok, n = pcall(tp.getInventorySize, side)
    return (ok and tonumber(n)) or 0
end

-- Classify a transposer's six sides:
--   ifSides       ME interface, item staging
--   fluidIfSides  ME interface, fluid staging
--   busSides      GT input bus  -- takes drones and kits
--   hatchSides    GT input hatch -- takes plasma
-- plus a per-side detail list for the printout, because getting this wrong is
-- silent otherwise: a mislabelled side just means nothing is ever detected.
--
-- One ME interface can stage BOTH items and fluids, so an interface side goes in
-- ifSides and, when it has tanks, fluidIfSides as well. One transposer can serve
-- both too, so a transposer may come back with buses AND hatches.
--
-- A GT block is decided by its TANK alone: an input hatch also has item slots
-- (for cells, not drones), so slots cannot be used to spot a bus. Capacity rather
-- than tank level, since an empty hatch reads level 0 exactly like a bus.
local function scanSides(tp)
    local ifSides, busSides, hatchSides, fluidIfSides, detail = {}, {}, {}, {}, {}
    for side = 0, 5 do
        local ok, name = pcall(tp.getInventoryName, side)
        name = ok and name or nil
        local slots = inventorySize(tp, side)
        local tanks = tankCount(tp, side)
        local kind

        if name and INTERFACE_NAMES[name] then
            ifSides[#ifSides + 1] = side
            kind = "interface"
            if tanks > 0 then
                fluidIfSides[#fluidIfSides + 1] = side
                kind = "interface+fluid"
            end
        elseif tanks > 0 then
            -- Tank wins: this is a hatch even though it has slots too.
            hatchSides[#hatchSides + 1] = side
            kind = "hatch"
        elseif name == INPUT_BUS_NAME then
            busSides[#busSides + 1] = side
            kind = "bus"
        elseif slots > 0 or name then
            kind = "-"
        end

        if kind then
            detail[#detail + 1] = { side = side, name = name or "?",
                slots = slots, tanks = tanks, kind = kind }
        end
    end
    return ifSides, busSides, hatchSides, fluidIfSides, detail
end

-- Stores the probe drone's metadata into the database via the local net (for use
-- with setInterfaceConfiguration). Returns the db slot, or nil + error.
local function storeProbe(net, handle, probe)
    if net.store == nil then return nil, "local net has no store()" end

    -- A permanent named slot: nothing else can be handed it, which is exactly the
    -- collision that used to leave a plasma drop where the drone should be.
    local slot, err = handle:slot("probe-drone")
    if not slot then return nil, tostring(err) end

    local okStore, res = pcall(net.store, { label = probe.label }, handle.address, slot, 1)
    if not okStore then return nil, "store() errored: " .. tostring(res) end

    -- The ME filter is not reliably exact, so confirm what landed is the drone
    -- itself: staging the wrong metadata would fail later and much less clearly.
    local held, what = handle:holds(slot, probe.label)
    if not held then return nil, what end
    return slot
end

-- The interfaces whose OWN network holds `label`. Only those can possibly stage
-- the probe, so this turns a base full of ME interfaces into the handful worth
-- probing: each survivor costs seconds to test, each rejection costs one call.
-- An interface always reports its own network, whichever that is.
local function interfacesHolding(interfaceComps, label)
    local out = {}
    for _, c in ipairs(interfaceComps) do
        local ok, p = pcall(component.proxy, c)
        if ok and p and p.getItemsInNetwork ~= nil then
            local okItems, items = pcall(p.getItemsInNetwork, { label = label })
            if okItems and type(items) == "table" then
                for _, it in ipairs(items) do
                    -- re-checked: the ME filter is not reliably exact
                    if it and it.label == label and (it.size or 0) > 0 then
                        out[#out + 1] = c
                        break
                    end
                end
            end
        end
    end
    return out
end

-- The same, for a fluid.
local function interfacesHoldingFluid(interfaceComps, label)
    local out = {}
    for _, c in ipairs(interfaceComps) do
        local ok, p = pcall(component.proxy, c)
        if ok and p and p.getFluidsInNetwork ~= nil then
            local okF, fluids = pcall(p.getFluidsInNetwork)
            if okF and type(fluids) == "table" then
                for _, f in ipairs(fluids) do
                    if f and f.label == label and (f.amount or 0) > 0 then
                        out[#out + 1] = c
                        break
                    end
                end
            end
        end
    end
    return out
end

-- Confirms a database slot really holds `label`, so a stage that fails can be
-- blamed on the interface rather than on metadata that was never written.
-- Returns true + what is there, or false + why not.
-- Which interface config slot actually accepts a stocking request. The item slots
-- have already caught us out once -- there is a note that slot 1's item does not
-- surface to the transposer -- and the fluid side of the same block turned out to
-- be 0-based, so the base is not something to assume. The first slot that reads
-- back what we wrote is remembered and used for every later interface.
local CFG_SLOT_CANDIDATES = { PROBE_CFG_SLOT, 1, 3, 0 }
local knownCfgSlot = nil

-- Stages the probe into an interface and says exactly what happened. Returns
-- slot, ok, detail -- slot is nil when nothing could be written at all.
local function stageProbe(p, dbAddr, dbSlot)
    local tried = knownCfgSlot and { knownCfgSlot } or CFG_SLOT_CANDIDATES
    local lastWhy = "no config slot accepted it"

    for _, slot in ipairs(tried) do
        local ok, res = pcall(p.setInterfaceConfiguration, slot, dbAddr, dbSlot, 1)
        if not ok then
            lastWhy = "slot " .. slot .. " errored (" .. tostring(res) .. ")"
        elseif res == false then
            lastWhy = "slot " .. slot .. " refused the request"
        else
            -- Read it back: a call that returns true but leaves the slot empty is
            -- the failure actually seen in the field.
            local okc, cfg = pcall(p.getInterfaceConfiguration, slot)
            if okc and type(cfg) == "table" and (cfg.name or cfg.label) then
                knownCfgSlot = slot
                return slot, true, tostring(cfg.label or cfg.name)
            end
            lastWhy = "slot " .. slot .. " set but reads back empty"
            pcall(p.setInterfaceConfiguration, slot)
        end
    end
    return nil, false, lastWhy
end

-- Finds which me_interface a transposer feeds: stock the probe drone on each
-- candidate in turn and see whether the transposer can see it, which confirms it
-- is the ADJACENT one. Returns interfaceAddr, side.
--
-- `interfaceComps` is expected to be pre-narrowed by interfacesHolding. There is
-- no overall time budget: running out of it is indistinguishable from "nothing
-- feeds this transposer", and that silence is expensive to debug. There is no
-- "did a drone leave the local net" shortcut either -- a stocked item may still
-- count as network inventory, and that test would then reject the RIGHT interface.
local function detectInterface(tp, ifSides, interfaceComps, dbAddr, dbSlot, probe, net)
    for _, c in ipairs(interfaceComps) do
        local ok, p = pcall(component.proxy, c)
        if ok and p and p.setInterfaceConfiguration ~= nil then
            local slot, staged, how = stageProbe(p, dbAddr, dbSlot)

            local foundSide = nil
            if staged then
                local deadline = computer.uptime() + DETECT_PER_CANDIDATE
                while computer.uptime() < deadline do
                    for _, side in ipairs(ifSides) do
                        if sideHasLabel(tp, side, probe.label) then foundSide = side; break end
                    end
                    if foundSide then break end
                    os.sleep(POLL_INTERVAL)
                end
                if not foundSide then
                    print(string.format("      %s..: staged %s in slot %d, no side saw it",
                        c:sub(1, 8), how, slot))
                end
            else
                -- Previously discarded, which made a refused write look exactly
                -- like a transposer that simply is not adjacent.
                print(string.format("      %s..: could not stage the probe -- %s",
                    c:sub(1, 8), how))
            end

            if slot then
                pcall(p.setInterfaceConfiguration, slot)   -- clear (drone back to net)
            end
            if foundSide then return c, foundSide end
        end
    end
    return nil, nil
end

-- ---- fluid-side probing ----------------------------------------------------

-- Makes sure the probe drone's KITS are in the local net. A module eats 4 drill
-- tips + 4 rods of the drone's material per meteor and will not run -- so cannot
-- be detected -- without them. They reach the modules from the local net on their
-- own, so setup only has to see that they are in stock. The exact item labels come
-- from the supply interface's kit pattern rather than being guessed at.
-- Returns true, or false + reason (which is a warning, not a hard stop: the kits
-- may have been put there by hand).
local function ensureKits(net, material, itf, handle)
    if not itf then return false, "no supply interface found to request kits from" end

    -- Resolved against the database so the request targets the fake pattern's real
    -- (renamed) output rather than the base item its slot reports.
    local entry
    for _, e in ipairs(supply.catalog(itf, handle)) do
        if e.kind == "kit" and e.material == material then entry = e; break end
    end
    if not entry then
        return false, "the supply interface has no kit pattern for " .. material
    end

    local stock = supply.stock({ entry }, net)
    local have = supply.kitsInStock(entry, stock.items)
    if have >= PROBE_KITS then
        return true, string.format("%d %s kit(s) in stock", have, material)
    end

    local crafts = math.ceil((PROBE_KITS - have) / math.max(1, entry.perCraft))
    print(string.format("  stocking %s kits: %d of %d, requesting %d craft(s)...",
        material, have, PROBE_KITS, crafts))
    local job, err = supply.request(itf, entry, crafts)
    if not job then return false, tostring(err) end

    local deadline = computer.uptime() + STOCK_TIMEOUT
    while computer.uptime() < deadline do
        local state = supply.jobState(job)
        if state ~= "computing" then break end
        os.sleep(POLL_INTERVAL)
    end
    stock = supply.stock({ entry }, net)
    have = supply.kitsInStock(entry, stock.items)
    if have <= 0 then return false, "no " .. material .. " kits arrived" end
    return true, string.format("%d %s kit(s) in stock", have, material)
end

-- Makes sure the local net actually HOLDS the plasma we mean to probe with. A
-- fluid interface can only stage what its network has, so without this every
-- hatch stays empty and every hatch-to-miner pairing fails -- and fails silently,
-- because an unfilled hatch looks exactly like a wrong side.
-- Returns true, or false + reason.
local function ensurePlasma(net, entry, itf, litres)
    if not entry then return false, "no plasma pattern to stock from" end
    local function have()
        return supply.plasmaInStock(entry, supply.stock({ entry }, net))
    end

    local now = have()
    if now >= litres then
        return true, string.format("%d L of %s in the local net", now, entry.plasma.name)
    end

    local crafts = math.ceil((litres - now) / math.max(1, entry.perCraft))
    print(string.format("  stocking %s: %d of %d L, requesting %d craft(s)...",
        entry.plasma.name, now, litres, crafts))
    local job, err = supply.request(itf, entry, crafts)
    if not job then return false, tostring(err) end

    local deadline = computer.uptime() + STOCK_TIMEOUT
    while computer.uptime() < deadline do
        if supply.jobState(job) ~= "computing" then break end
        os.sleep(POLL_INTERVAL)
    end
    -- The fluid can take a while to land after the job itself reports done, and a
    -- large request arrives in pieces.
    deadline = computer.uptime() + STOCK_TIMEOUT
    while computer.uptime() < deadline and have() < litres do os.sleep(POLL_INTERVAL) end

    now = have()
    if now <= 0 then return false, "no " .. entry.plasma.name .. " arrived" end
    if now < litres then
        -- Partial is not success: the hatches it does not cover stay empty, and an
        -- empty hatch is indistinguishable from a wrong side during detection.
        return false, string.format("only %d of %d L of %s", now, litres, entry.plasma.name)
    end
    return true, string.format("%d L of %s in the local net", now, entry.plasma.name)
end

-- Puts a plasma's ae2fc drop in the database, which is the only way to name a
-- fluid to setFluidInterfaceConfiguration -- the local net holds plasma as fluid,
-- never as drops, so it is lifted out of the supply interface's own pattern.
-- Returns plasma, dbSlot, or nil + error.
local function stagePlasmaDrop(itf, handle)
    if not itf then return nil, "no supply interface found to take a plasma drop from" end

    -- Any plasma will do for detection; take the cheapest per litre to probe with.
    local best
    for _, e in ipairs(supply.catalog(itf, handle)) do
        if e.kind == "plasma" and (not best or e.plasma.tier < best.plasma.tier) then best = e end
    end
    if not best then return nil, "the supply interface has no plasma pattern" end

    local slot, err = supply.storePlasmaDrop(itf, best, handle)
    if not slot then return nil, tostring(err) end
    return best, slot
end

-- Finds which me_interface a FLUID transposer stages through, and on which side:
-- configure the probe plasma into each interface's tank in turn and watch whether
-- the transposer can see it. The fluid mirror of detectInterface.
-- Returns interfaceAddr, side.
local function detectFluidInterface(tp, fluidIfSides, interfaceComps, dbAddr, dropSlot, plasmaName)
    for _, c in ipairs(interfaceComps) do
        local ok, p = pcall(component.proxy, c)
        if ok and p and p.setFluidInterfaceConfiguration ~= nil then
            pcall(p.setFluidInterfaceConfiguration, PROBE_FLUID_TANK, dbAddr, dropSlot)

            local foundSide = nil
            local deadline = computer.uptime() + DETECT_PER_CANDIDATE
            while computer.uptime() < deadline do
                for _, side in ipairs(fluidIfSides) do
                    -- the reads are 1-based, the config is 0-based (transport.lua)
                    local okf, f = pcall(tp.getFluidInTank, side, PROBE_FLUID_TANK + 1)
                    if okf and type(f) == "table" then
                        if f.label == nil and type(f[1]) == "table" then f = f[1] end
                        if f.label == plasmaName and (f.amount or 0) > 0 then
                            foundSide = side; break
                        end
                    end
                end
                if foundSide then break end
                os.sleep(POLL_INTERVAL)
            end

            pcall(p.setFluidInterfaceConfiguration, PROBE_FLUID_TANK)   -- clear
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

-- Waits for every miner to stop mining. isMachineActive lags after a miner is
-- switched off, so without this a module still finishing an operation would be
-- mistaken for the one we just fed. Returns true if they all settled.
local function waitIdle(minerList)
    local deadline = computer.uptime() + SETTLE_TIMEOUT
    while computer.uptime() < deadline do
        local anyActive = false
        for _, m in ipairs(minerList) do
            if minerActive(m) then anyActive = true; break end
        end
        if not anyActive then return true end
        os.sleep(POLL_INTERVAL)
    end
    return false
end

-- Waits for a miner that has NOT already been identified to start mining -- the
-- one we just gave its missing input to. Already-found miners are ignored
-- because isMachineActive lags behind them being switched off.
local function waitForNewMiner(minerList, assigned, timeout)
    local deadline = computer.uptime() + (timeout or MINER_TIMEOUT)
    while computer.uptime() < deadline do
        for _, m in ipairs(minerList) do
            if not assigned[m.address] and minerActive(m) then return m end
        end
        os.sleep(POLL_INTERVAL)
    end
    return nil
end

-- Clean slate before detection: clear any leftover mining-drone stock configs on
-- the interfaces (so a pre-stocked drone can't fool detection), switch every
-- miner off, and wait for in-progress mining to finish (isMachineActive lags
-- after a miner is switched off). Only drone configs are cleared, so unrelated
-- interfaces are left alone. Returns each miner's original on/off state.
local function prepare(interfaceComps, minerList)
    for _, c in ipairs(interfaceComps) do
        local ok, p = pcall(component.proxy, c)
        if ok and p and p.getInterfaceConfiguration ~= nil and p.setInterfaceConfiguration ~= nil then
            for slot = 1, 9 do
                local okc, cfg = pcall(p.getInterfaceConfiguration, slot)
                if okc and type(cfg) == "table" and cfg.name == drones.ITEM_NAME then
                    pcall(p.setInterfaceConfiguration, slot)
                end
            end
        end
    end

    local wasOn = {}
    for _, m in ipairs(minerList) do
        wasOn[m.address] = minerOn(m)
        m:setEnabled(false)
    end

    if not waitIdle(minerList) then
        print("  WARNING: some miners are still finishing; detection may be off -- re-run if needed.")
    end
    return wasOn
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
    stageProbe = stageProbe,
    detectInterface = detectInterface,
    interfacesHolding = interfacesHolding,
    interfacesHoldingFluid = interfacesHoldingFluid,
    tankCount = tankCount,
    inventorySize = inventorySize,
    ensureKits = ensureKits,
    ensurePlasma = ensurePlasma,
    stagePlasmaDrop = stagePlasmaDrop,
    detectFluidInterface = detectFluidInterface,
    minerActive = minerActive,
    minerOn = minerOn,
    prepare = prepare,
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

-- 2. Database for staging probes. Slots come from db.lua by NAME, so the probe
-- drone, the plasma drop and the scratch entry cannot land on each other -- which
-- they used to, silently, leaving a plasma drop where the drone should have been.
local dbAddr = pickDatabase()
if not dbAddr then
    print("ERROR: no database component. Add a Database Upgrade in an adapter.")
    return M
end
local handle, dbErr = dbslots.open(dbAddr)
if not handle then print("ERROR: " .. tostring(dbErr)); return M end
print(string.format("Database %s.. has %d slot(s).", dbAddr:sub(1, 8), handle:size()))

local dbSlot, derr = storeProbe(net, handle, probe)
if not dbSlot then print("ERROR: " .. tostring(derr)); return M end

-- 2b. Kits and plasma. A module needs a drone, kits AND plasma to mine, so both
-- detection phases depend on the other two being available first.
local supplyItf, supplyErr = supply.find(nil)
if not supplyItf then print("WARNING: " .. tostring(supplyErr)) end
local probeMaterial = (probeDrone.material) or (drones.get(probe.tier or 0) or {}).material
if probeMaterial then
    local okKits, kitMsg = ensureKits(net, probeMaterial, supplyItf, handle)
    print((okKits and "Kits OK: " or "WARNING: kits -- ") .. tostring(kitMsg))
    if not okKits then
        print("       detection needs them; continuing in case they are stocked by hand.")
    end
else
    print("WARNING: unknown material for the probe drone; cannot check kits.")
end

local plasmaEntry, dropSlot = stagePlasmaDrop(supplyItf, handle)
local probePlasma = plasmaEntry and plasmaEntry.plasma
if not plasmaEntry then
    print("WARNING: no plasma to probe with (" .. tostring(dropSlot) .. ").")
    print("         Input hatches cannot be matched to miners without it; buses still can.")
    dropSlot = nil
else
    print(string.format("Probing plasma: %s (%d L per hatch).", probePlasma.name, PROBE_PLASMA_L))
end

local transposers = listByType("transposer")
local interfaceComps = listByType("me_interface")
local minerList = miners.discover()
print(string.format("Found %d transposer(s), %d interface(s), %d miner(s).",
    #transposers, #interfaceComps, #minerList))

-- Clean slate: clear leftover drone configs, stop miners, wait for them to idle.
print("Preparing (clearing drone configs, stopping miners, waiting for idle)...")
local wasOn = prepare(interfaceComps, minerList)

-- 3. Pair each transposer with its interface(s), and collect what it reaches.
-- A transposer may serve items AND fluids, and one ME interface may stage both,
-- so a transposer can yield input buses and input hatches together.
local feeds = {}        -- item: { transposer, interface, interfaceSide, inputBusSide }
local fluidFeeds = {}   -- fluid: { transposer, interface, interfaceSide, inputHatchSide }

-- Scan every transposer's sides FIRST. Two reasons: the hatch count decides how
-- much plasma to stock before any of it can be filled, and the printout below is
-- the only way to see a misread side -- detection just quietly finds nothing.
local scans, hatchTotal = {}, 0
for _, tpAddr in ipairs(transposers) do
    local tp = component.proxy(tpAddr)
    local ifSides, busSides, hatchSides, fluidIfSides, detail = scanSides(tp)
    scans[#scans + 1] = { addr = tpAddr, tp = tp, ifSides = ifSides, busSides = busSides,
        hatchSides = hatchSides, fluidIfSides = fluidIfSides }
    hatchTotal = hatchTotal + #hatchSides

    print(string.format("  %s..: %d interface(s) (%d fluid), %d bus(es), %d hatch(es)",
        tpAddr:sub(1, 8), #ifSides, #fluidIfSides, #busSides, #hatchSides))
    for _, d in ipairs(detail) do
        print(string.format("      side %d %-11s %-34s %d slot(s), %d tank(s)",
            d.side, d.kind, d.name, d.slots, d.tanks))
    end
end

-- Plasma has to be IN the local net before a fluid interface can stage any: the
-- interface only offers what its network holds.
--
-- Every hatch gets its OWN staging tank, and phase A primes them all at once, so
-- the network has to cover a full tank for each of them on top of what actually
-- lands in the hatches -- not one tank between them. Plus a spare tank of
-- headroom, since a request that comes up short leaves hatches unfilled and their
-- miners unmatched.
if hatchTotal > 0 and plasmaEntry then
    local want = hatchTotal * (STAGING_L + PROBE_PLASMA_L) + STAGING_L
    local okP, msg = ensurePlasma(net, plasmaEntry, supplyItf, want)
    print((okP and "Plasma OK: " or "WARNING: plasma -- ") .. tostring(msg))
    if not okP then
        print(string.format("         %d hatch(es) need %d L staged at once; any that stay "
            .. "empty cannot be matched to a miner.", hatchTotal, want))
    end
end

-- Narrow the interfaces before probing them. Only a network that HOLDS the probe
-- can stage it, so this is the difference between testing three interfaces and
-- testing every one in the base at seconds apiece.
-- The probe's metadata has to still be in the database: everything since
-- storeProbe has also been writing to it, and a cleared slot would make every
-- interface look like it refused.
local okDb, dbWhat = handle:holds(dbSlot, probe.label)
print(string.format("Probe metadata in database slot %d: %s", dbSlot, dbWhat))
if not okDb then
    print("  Nothing can be staged without it -- no input bus will be paired.")
end

local itemCandidates = interfacesHolding(interfaceComps, probe.label)
print(string.format("Interfaces that can stage %s: %d of %d.",
    probe.label, #itemCandidates, #interfaceComps))
if #itemCandidates == 0 then
    print("  None. Every interface's network was asked and none reported that drone,")
    print("  so no input bus can be paired. Is the local net's interface adaptered?")
end

local fluidCandidates = interfaceComps
if probePlasma then
    fluidCandidates = interfacesHoldingFluid(interfaceComps, probePlasma.name)
    print(string.format("Interfaces that can stage %s: %d of %d.",
        probePlasma.name, #fluidCandidates, #interfaceComps))
end

for _, s in ipairs(scans) do
    local tpAddr, tp = s.addr, s.tp
    local ifSides, busSides = s.ifSides, s.busSides
    local hatchSides, fluidIfSides = s.hatchSides, s.fluidIfSides
    local tag = tpAddr:sub(1, 8)

    if #busSides > 0 then
        if #ifSides == 0 then
            print(string.format("  %s..: input buses but no interface side -- skipped.", tag))
        else
            local ifAddr, ifSide = detectInterface(tp, ifSides, itemCandidates, dbAddr, dbSlot, probe, net)
            if not ifAddr then
                print(string.format("  %s..: could not detect its interface (timed out).", tag))
            else
                print(string.format("  %s..: interface %s.. on side %d, %d input bus(es).",
                    tag, ifAddr:sub(1, 8), ifSide, #busSides))
                for _, busSide in ipairs(busSides) do
                    feeds[#feeds + 1] = {
                        transposer = tpAddr, interface = ifAddr,
                        interfaceSide = ifSide, inputBusSide = busSide,
                    }
                end
            end
        end
    end

    if #hatchSides > 0 then
        if not dropSlot then
            print(string.format("  %s..: %d input hatch(es), but there is no plasma to probe with.",
                tag, #hatchSides))
        elseif #fluidIfSides == 0 then
            print(string.format("  %s..: input hatches but no fluid interface side -- skipped.", tag))
        else
            local ifAddr, ifSide = detectFluidInterface(tp, fluidIfSides, fluidCandidates,
                dbAddr, dropSlot, probePlasma.name)
            if not ifAddr then
                print(string.format("  %s..: could not detect its fluid interface (timed out).", tag))
            else
                print(string.format("  %s..: fluid interface %s.. on side %d, %d input hatch(es).",
                    tag, ifAddr:sub(1, 8), ifSide, #hatchSides))
                for _, hatchSide in ipairs(hatchSides) do
                    fluidFeeds[#fluidFeeds + 1] = {
                        transposer = tpAddr, interface = ifAddr,
                        interfaceSide = ifSide, inputHatchSide = hatchSide,
                    }
                end
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

-- Fluid-only station: during detection a hatch has no miner yet, which is why
-- transport.new allows a station with just one half.
local function fluidStationFor(feed)
    return transport.new({
        database = dbAddr,
        fluidTransposer = feed.transposer, fluidInterface = feed.interface,
        fluidInterfaceSide = feed.interfaceSide, inputHatchSide = feed.inputHatchSide,
        fluidTank = feed.fluidTank,
    })
end

-- Tops a hatch up, giving the staging tank time to refill from ME in between.
local function fillHatchTo(st, target)
    local deadline = computer.uptime() + FLUID_TIMEOUT
    while computer.uptime() < deadline do
        if st:hatchTank() >= target then return true end
        if (st:fillHatch(target) or 0) <= 0 then os.sleep(POLL_INTERVAL) end
    end
    return st:hatchTank() > 0
end

-- Hatches sharing one fluid interface need distinct tanks, exactly as buses
-- sharing an interface need distinct slots. Assign them once; the same numbers
-- go into stations.lua at the end.
local fluidStations = {}
do
    local nextTank = {}
    for i, feed in ipairs(fluidFeeds) do
        local n = nextTank[feed.interface] or 0
        nextTank[feed.interface] = n + 1
        feed.fluidTank = n
        if n > 5 then
            print(string.format("WARNING: fluid interface %s.. has %d hatches (>6 tanks) -- "
                .. "the extras cannot be staged.", feed.interface:sub(1, 8), n + 1))
        end
        fluidStations[i] = fluidStationFor(feed)
    end
end

-- 4. PHASE A -- pair input BUSES with miners. Every hatch gets a little plasma so
-- the only thing a module is still missing is its drone; then feed one bus at a
-- time and watch which miner starts.
if #fluidStations > 0 then
    print(string.format("Priming %d hatch(es) with %s...", #fluidStations, probePlasma.name))
    for i, st in ipairs(fluidStations) do
        if st then
            st:setPlasmaSource(dropSlot)
            local okFill = fillHatchTo(st, PROBE_PLASMA_L)
            local level = st:hatchTank()
            print(string.format("  hatch %s../side%d: %d L%s",
                fluidFeeds[i].transposer:sub(1, 8), fluidFeeds[i].inputHatchSide, level,
                okFill and "" or "  (did not fill -- is that plasma in the local net?)"))
        end
    end
end

print("Emptying input buses...")
for _, feed in ipairs(feeds) do
    local st = stationFor(feed)
    if st then st:returnAll() end
end

-- Miners are already off (prepare); enable them so the one with a drone runs.
for _, m in ipairs(minerList) do m:setEnabled(true) end

print("Identifying miners by input bus...")
local assigned = {}   -- miner address -> item feed
for _, feed in ipairs(feeds) do
    local st = stationFor(feed)
    if st then
        local ok, err = st:setDrone(probeDrone, 1)
        if not ok then
            print(string.format("  bus %s../side%d: could not load a probe drone (%s).",
                feed.transposer:sub(1, 8), feed.inputBusSide, tostring(err)))
        else
            local found = waitForNewMiner(minerList, assigned)
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

-- 5. PHASE B -- pair input HATCHES with miners, the other way round: a drone in
-- EVERY bus, every hatch empty, then fill one hatch at a time.
local fluidAssigned = {}   -- miner address -> fluid feed
if #fluidStations > 0 then
    print("Settling miners between phases...")
    for _, m in ipairs(minerList) do m:setEnabled(false) end
    if not waitIdle(minerList) then
        print("  WARNING: some miners are still finishing; hatch detection may be off.")
    end

    print("Draining hatches...")
    for _, st in ipairs(fluidStations) do
        if st then
            st:clearPlasmaSource()   -- so the tank cannot refuse what we drain back
            st:drainHatch()
        end
    end

    print("Loading a drone into every bus...")
    local busStations = {}
    for i, feed in ipairs(feeds) do
        local st = stationFor(feed)
        busStations[i] = st
        if st then
            local ok, err = st:setDrone(probeDrone, 1)
            if not ok then
                print(string.format("  bus %s../side%d: %s",
                    feed.transposer:sub(1, 8), feed.inputBusSide, tostring(err)))
            end
        end
    end

    for _, m in ipairs(minerList) do m:setEnabled(true) end

    print("Identifying miners by input hatch...")
    for i, st in ipairs(fluidStations) do
        local feed = fluidFeeds[i]
        if st then
            st:setPlasmaSource(dropSlot)
            if not fillHatchTo(st, PROBE_PLASMA_L) then
                print(string.format("  hatch %s../side%d: would not fill -- skipped.",
                    feed.transposer:sub(1, 8), feed.inputHatchSide))
            else
                local found = waitForNewMiner(minerList, fluidAssigned)
                if found then
                    fluidAssigned[found.address] = feed
                    print(string.format("  miner %s.. <- transposer %s.. hatch side %d tank %d",
                        found.address:sub(1, 8), feed.transposer:sub(1, 8),
                        feed.inputHatchSide, feed.fluidTank))
                else
                    print(string.format("  hatch %s../side%d: no new miner started.",
                        feed.transposer:sub(1, 8), feed.inputHatchSide))
                end
            end
            -- Empty it again so the next hatch is the only plasma in play.
            st:clearPlasmaSource()
            st:drainHatch()
        end
    end

    -- Give the drones back; the controller loads what it actually wants later.
    for _, st in ipairs(busStations) do
        if st then st:returnAll() end
    end
end

-- Restore miners to their original on/off state, and tidy the probe metadata.
for _, m in ipairs(minerList) do m:setEnabled(wasOn[m.address] == true) end
-- The probe metadata stays put: the slots are named, so a later run reuses them
-- rather than tripping over them, and leaving them filled saves re-storing.
print(string.format("Database slots used: %d of %d.", handle:used(), handle:size()))
for _, e in ipairs(handle:dump()) do
    print(string.format("  %2d  %-24s %s", e.slot, e.name, tostring(e.label)))
end

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

-- Merge in the plasma feed for every miner that got one. A miner found by hatch
-- but not by bus has no station to attach to -- report it rather than inventing
-- one, since it cannot be driven without its item half.
for addr, feed in pairs(fluidAssigned) do
    local st = stations[addr]
    if st then
        st.fluidTransposer = feed.transposer
        st.fluidInterface = feed.interface
        st.fluidInterfaceSide = feed.interfaceSide
        st.inputHatchSide = feed.inputHatchSide
        st.fluidTank = feed.fluidTank
    else
        print(string.format("WARNING: miner %s.. was found by its hatch but not by any bus; "
            .. "its plasma feed cannot be recorded without one.", addr:sub(1, 8)))
    end
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
    -- Compact mode: pretty mode limits entries and truncates with "...", which
    -- would make stations.lua unloadable.
    "return " .. serialization.serialize(payload),
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
local withoutPlasma = 0
for _, a in ipairs(keys) do
    local st = stations[a]
    print(string.format("  %s: transposer %s.. bus=side%d interface=side%d slot=%d",
        st.label, st.transposer:sub(1, 8), st.inputBusSide, st.interfaceSide, st.interfaceSlot))
    if st.fluidTransposer then
        print(string.format("      plasma:  transposer %s.. hatch=side%d interface=side%d tank=%d",
            st.fluidTransposer:sub(1, 8), st.inputHatchSide, st.fluidInterfaceSide, st.fluidTank))
    else
        withoutPlasma = withoutPlasma + 1
        print("      plasma:  none found -- this module cannot be fed plasma")
    end
end
if withoutPlasma > 0 then
    print(string.format("%d module(s) have no plasma feed. Each needs a transposer touching "
        .. "an input hatch and an ME interface with tanks", withoutPlasma))
    print("(the same transposer and interface that carry its items will do).")
end
print("Keep cfg.dryRun = true until you've watched a drone move, then flip it.")

return M

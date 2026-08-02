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
--   2. To pair transposers with interfaces we stage that probe drone in each
--      me_interface ONCE and ask every transposer whether it can see it, rather
--      than the other way round: staging costs seconds of ME stocking, reading a
--      transposer side costs one call. The base has interfaces on OTHER nets too,
--      so the list is first narrowed to the ones whose own network holds the
--      probe; only those can stage it at all.
--   3. A module only mines with a drone, KITS and PLASMA all present, so both
--      detection phases below need the other two inputs already satisfied:
--        * kits arrive from the local net by themselves (they are chosen by the
--          drone), so setup only makes sure the probe drone's kits are in stock;
--        * plasma is placed by us, through the fluid half of a station.
--   4. Everything a module could run on is cleared first: leftover drone and
--      plasma staging on every interface, every input bus emptied, every input
--      hatch drained. Anything left behind makes a module run before we feed it,
--      and the first thing tested then gets the credit.
--   5. PHASE A -- buses. Give every fluid hatch a little plasma, then drop a drone
--      into one bus at a time and see which miner starts mining. That pairs each
--      input bus with its miner.
--   6. PHASE B -- hatches. The reverse: put a drone in EVERY bus, empty every
--      hatch, then fill one hatch at a time and see which miner starts. That pairs
--      each input hatch with its miner. The miners are stopped and allowed to
--      settle in between, because isMachineActive lags.
--   7. Each (miner -> item transposer + fluid transposer + sides) becomes a station.
--
-- Run from this folder:
--   setup              a one-screen summary: what was found, what was paired,
--                      what was written, and anything that went wrong
--   setup --verbose    adds the detail that only matters once something HAS gone
--                      wrong -- every side considered and how it was classified,
--                      every interface probed and what it said, the database map
--
-- require("setup") returns the helper functions (for debugging) without running.

local component = require("component")
local computer = require("computer")
local miners = require("lib.hw.miners")
local drones = require("lib.gtnh.drones")
local localnet = require("lib.hw.localnet")
local transport = require("lib.hw.transport")
local dbslots = require("lib.hw.db")
local supply = require("lib.hw.supply")
local stationfile = require("lib.stations")
local cli = require("lib.cli")

local ctx = cli.start({
    name = "setup",
    summary = "Work out how to feed every mining module, with no questions asked.",
    usage = {
        { "setup", "discover everything and write data/stations.lua" },
    },
    notes = {
        "Discovery needs a module to START mining, and a module only mines with a "
            .. "drone, KITS and PLASMA all present. So setup stocks the probe "
            .. "drone's kits, stages plasma itself, and points each module at a "
            .. "distance where something is actually in range.",
        "It runs in two passes. PHASE A primes every hatch and feeds one bus at a "
            .. "time, pairing buses with miners; PHASE B puts a drone in every bus "
            .. "and fills one hatch at a time, pairing hatches with miners.",
        "Everything it touches is put back: interface staging cleared, buses "
            .. "emptied, hatches drained, and each module's own parameters restored "
            .. "before its on/off state is.",
        "Safe to re-run. It regenerates data/stations.lua from scratch, and "
            .. "config.lua is never written -- anything you set there wins.",
    },
}, ...)
if not ctx then return end

-- ---- output ----------------------------------------------------------------
-- A default run is meant to fit on one screen: the narrative, the result, and
-- anything that went wrong. Detail that only matters once something HAS gone
-- wrong -- per-side classification, per-candidate probe outcomes, the database
-- slot map -- is behind --verbose. lib/cli.lua does the work.
local verbose = ctx.flags.verbose

local function say(f, ...) cli.say(f, ...) end
local function detail(f, ...) if verbose then cli.say(f, ...) end end
local function step(f, ...) cli.step(ctx, f, ...) end
local function stepEnd(f, ...) cli.stepEnd(ctx, f, ...) end

local discover = require("lib.hw.discover")

-- Point the library's reporting at this CLI, then alias what the flow uses. The
-- aliases are only for readability -- the flow below reads as prose either way.
discover.out = { say = say, detail = detail, step = step, stepEnd = stepEnd }

local listByType = discover.listByType
local scanSides = discover.scanSides
local storeProbe = discover.storeProbe
local sweepInterfaces = discover.sweepInterfaces
local sideHasLabel = discover.sideHasLabel
local interfacesHolding = discover.interfacesHolding
local interfacesHoldingFluid = discover.interfacesHoldingFluid
local stageProbe = discover.stageProbe
local ensureKits = discover.ensureKits
local ensurePlasma = discover.ensurePlasma
local stagePlasmaDrop = discover.stagePlasmaDrop
local purgeFeeds = discover.purgeFeeds
local aimMiners = discover.aimMiners
local prepare = discover.prepare
local pickDatabase = discover.pickDatabase
local waitIdle = discover.waitIdle
local waitForNewMiner = discover.waitForNewMiner
local minerActive = discover.minerActive

local POLL_INTERVAL = discover.POLL_INTERVAL
local PROBE_PLASMA_L = discover.PROBE_PLASMA_L
local PROBE_FLUID_TANK = discover.PROBE_FLUID_TANK
local PROBE_CFG_SLOT = discover.PROBE_CFG_SLOT
local FLUID_TIMEOUT = discover.FLUID_TIMEOUT
local STAGING_L = discover.STAGING_L

-- require("setup") hands back the library rather than running anything, so the
-- helpers can be poked at from the shell.
do
    local ok, info = pcall(function() return require("process").info() end)
    local asProgram = ok and info and type(info.path) == "string"
        and info.path:find("setup%.lua$") ~= nil
    if not asProgram then return discover end
end

-- ---- automatic flow ------------------------------------------------------

say("== Mining controller setup (automatic) ==%s", verbose and "  [verbose]" or "")

-- 1. Local net + probe drone.
local net, nerr = localnet.proxy()
if not net then say("ERROR: " .. nerr); return discover end
local probe = localnet.lowestDrone(net)
if not probe then
    say("ERROR: no mining drones in the local net -- keep a few of the lowest")
    say("       tier in stock so setup can borrow one to probe with.")
    return discover
end
local probeDrone = drones.fromName(probe.label) or { name = probe.label }
say("Probe: %s (tier %s)", probe.label, tostring(probe.tier))

-- 2. Database for staging probes. Slots come from db.lua by NAME, so the probe
-- drone, the plasma drop and the scratch entry cannot land on each other -- which
-- they used to, silently, leaving a plasma drop where the drone should have been.
local dbAddr = pickDatabase()
if not dbAddr then
    say("ERROR: no database component. Add a Database Upgrade in an adapter.")
    return discover
end
local handle, dbErr = dbslots.open(dbAddr)
if not handle then say("ERROR: " .. tostring(dbErr)); return discover end
detail("Database %s..: %d slot(s)", dbAddr:sub(1, 8), handle:size())

local dbSlot, derr = storeProbe(net, handle, probe)
if not dbSlot then say("ERROR: " .. tostring(derr)); return discover end

-- 2b. Kits and plasma. A module needs a drone, kits AND plasma to mine, so both
-- detection phases depend on the other two being available first.
-- Start from the address a previous run recorded (config.lua picks it up from
-- stations.lua): finding it again means scanning every interface on the network
-- for patterns. supply.find checks the hint still has patterns before trusting
-- it, so a moved or rebuilt interface is re-detected rather than used blindly.
local supplyHint = nil
do
    local okCfg, cfg = pcall(require, "config")
    if okCfg and type(cfg) == "table" and type(cfg.supply) == "table" then
        supplyHint = cfg.supply.interface
    end
end
local supplyItf, supplyHow = supply.find(supplyHint)
if not supplyItf then
    say("WARNING: " .. tostring(supplyHow))
else
    detail("Supply interface %s.. (%s)", supplyItf.address:sub(1, 8), tostring(supplyHow))
end
local probeMaterial = (probeDrone.material) or (drones.get(probe.tier or 0) or {}).material
if probeMaterial then
    local okKits, kitMsg = ensureKits(net, probeMaterial, supplyItf, handle)
    stepEnd((okKits and "Kits: " or "WARNING: kits -- ") .. tostring(kitMsg))
    if not okKits then
        say("       detection needs them; continuing in case they are stocked by hand.")
    end
else
    say("WARNING: unknown material for the probe drone; cannot check kits.")
end

local plasmaEntry, dropSlot = stagePlasmaDrop(supplyItf, handle)
local probePlasma = plasmaEntry and plasmaEntry.plasma
if not plasmaEntry then
    say("WARNING: no plasma to probe with (" .. tostring(dropSlot) .. ").")
    say("         Input hatches cannot be matched to miners without it; buses still can.")
    dropSlot = nil
else
    say("Plasma: %s, %d L per hatch", probePlasma.name, PROBE_PLASMA_L)
end

local transposers = listByType("transposer")
local interfaceComps = listByType("me_interface")
local minerList = miners.discover()
-- Clean slate: clear leftover drone configs, stop miners, wait for them to idle.
step("Preparing miners (clearing drone configs, waiting for idle)...")
local wasOn = prepare(interfaceComps, minerList)

-- Point every module at something the probe drone can actually mine. Must be here:
-- the miners are stopped and settled, and a parameter write does not take on a
-- running machine.
local snaps, aimed, stuckAim = aimMiners(minerList, probe.tier or 1)
stepEnd("Aimed %d of %d miner(s) at a reachable meteor%s", aimed, #minerList,
    stuckAim > 0 and string.format(" (%d have none)", stuckAim) or "")
stepEnd("Found %d transposer(s), %d interface(s), %d miner(s)",
    #transposers, #interfaceComps, #minerList)

-- 3. Pair each transposer with its interface(s), and collect what it reaches.
-- A transposer may serve items AND fluids, and one ME interface may stage both,
-- so a transposer can yield input buses and input hatches together.
local feeds = {}        -- item: { transposer, interface, interfaceSide, inputBusSide }
local fluidFeeds = {}   -- fluid: { transposer, interface, interfaceSide, inputHatchSide }

-- Scan every transposer's sides FIRST. Two reasons: the hatch count decides how
-- much plasma to stock before any of it can be filled, and the printout below is
-- the only way to see a misread side -- detection just quietly finds nothing.
local scans, hatchTotal, busTotal = {}, 0, 0
for _, tpAddr in ipairs(transposers) do
    local tp = component.proxy(tpAddr)
    local ifSides, busSides, hatchSides, fluidIfSides, sides = scanSides(tp)
    scans[#scans + 1] = { addr = tpAddr, tp = tp, ifSides = ifSides, busSides = busSides,
        hatchSides = hatchSides, fluidIfSides = fluidIfSides }
    hatchTotal = hatchTotal + #hatchSides

    busTotal = busTotal + #busSides
    step("Scanning transposers... %d/%d", #scans, #transposers)
    detail("  %s..: %d interface(s) (%d fluid), %d bus(es), %d hatch(es)",
        tpAddr:sub(1, 8), #ifSides, #fluidIfSides, #busSides, #hatchSides)
    for _, d in ipairs(sides) do
        detail("      side %d %-11s %-34s %d slot(s), %d tank(s)",
            d.side, d.kind, d.name, d.slots, d.tanks)
    end
end
stepEnd("Scanned %d transposer(s): %d bus(es), %d hatch(es)",
    #transposers, busTotal, hatchTotal)

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
    stepEnd((okP and "Plasma staged: " or "WARNING: plasma -- ") .. tostring(msg))
    if not okP then
        say("         %d hatch(es) need %d L staged at once; any that stay "
            .. "empty cannot be matched to a miner.", hatchTotal, want)
    end
end

-- Narrow the interfaces before probing them. Only a network that HOLDS the probe
-- can stage it, so this is the difference between testing three interfaces and
-- testing every one in the base at seconds apiece.
-- The probe's metadata has to still be in the database: everything since
-- storeProbe has also been writing to it, and a cleared slot would make every
-- interface look like it refused.
local okDb, dbWhat = handle:holds(dbSlot, probe.label)
detail("Probe metadata in database slot %d: %s", dbSlot, dbWhat)
if not okDb then
    say("WARNING: database slot %d -- %s", dbSlot, dbWhat)
    say("  Nothing can be staged without it -- no input bus will be paired.")
end

local itemCandidates = interfacesHolding(interfaceComps, probe.label)
local fluidCandidates = interfaceComps
if probePlasma then
    fluidCandidates = interfacesHoldingFluid(interfaceComps, probePlasma.name)
end
say("Can stage the probe: %d/%d interface(s); the plasma: %d/%d",
    #itemCandidates, #interfaceComps, #fluidCandidates, #interfaceComps)
if #itemCandidates == 0 then
    say("  None. Every interface's network was asked and none reported that drone,")
    say("  so no input bus can be paired. Is the local net's interface adaptered?")
end

-- Both sweeps go interface-first: staging is the expensive half, so it happens
-- once per interface rather than once per transposer per interface.
local itemPairs = sweepInterfaces(scans, itemCandidates, {
    sidesOf = function(sc) return sc.ifSides end,
    sees = function(tp, side) return sideHasLabel(tp, side, probe.label) end,
    supports = function(p) return p.setInterfaceConfiguration ~= nil end,
    stage = function(p) return stageProbe(p, dbAddr, dbSlot) end,
    clear = function(p, slot)
        if slot then pcall(p.setInterfaceConfiguration, slot) end   -- drone back to net
    end,
}, "interfaces")
stepEnd()

local fluidPairs = {}
if dropSlot and probePlasma then
    fluidPairs = sweepInterfaces(scans, fluidCandidates, {
        sidesOf = function(sc) return sc.fluidIfSides end,
        -- The reads are 1-based, the config is 0-based (see transport.lua).
        sees = function(tp, side)
            local okf, f = pcall(tp.getFluidInTank, side, PROBE_FLUID_TANK + 1)
            if not okf or type(f) ~= "table" then return false end
            if f.label == nil and type(f[1]) == "table" then f = f[1] end
            return f.label == probePlasma.name and (f.amount or 0) > 0
        end,
        supports = function(p) return p.setFluidInterfaceConfiguration ~= nil end,
        stage = function(p)
            local ok = pcall(p.setFluidInterfaceConfiguration, PROBE_FLUID_TANK, dbAddr, dropSlot)
            return PROBE_FLUID_TANK, ok, ok and "staged" or "setFluidInterfaceConfiguration failed"
        end,
        clear = function(p) pcall(p.setFluidInterfaceConfiguration, PROBE_FLUID_TANK) end,
    }, "fluid interfaces")
    stepEnd()
end

-- Turn the pairings into feeds, one per bus and one per hatch.
local pairedItem, pairedFluid = 0, 0
for _, sc in ipairs(scans) do
    local tag = sc.addr:sub(1, 8)

    if #sc.busSides > 0 then
        local m = itemPairs[sc.addr]
        if #sc.ifSides == 0 then
            say("  %s..: input buses but no interface side -- skipped.", tag)
        elseif not m then
            say("  %s..: could not detect its interface.", tag)
        else
            pairedItem = pairedItem + 1
            for _, busSide in ipairs(sc.busSides) do
                feeds[#feeds + 1] = {
                    transposer = sc.addr, interface = m.interface,
                    interfaceSide = m.side, inputBusSide = busSide,
                }
            end
        end
    end

    if #sc.hatchSides > 0 then
        local m = fluidPairs[sc.addr]
        if not dropSlot then
            say("  %s..: %d input hatch(es), but there is no plasma to probe with.",
                tag, #sc.hatchSides)
        elseif #sc.fluidIfSides == 0 then
            say("  %s..: input hatches but no fluid interface side -- skipped.", tag)
        elseif not m then
            say("  %s..: could not detect its fluid interface.", tag)
        else
            pairedFluid = pairedFluid + 1
            for _, hatchSide in ipairs(sc.hatchSides) do
                fluidFeeds[#fluidFeeds + 1] = {
                    transposer = sc.addr, interface = m.interface,
                    interfaceSide = m.side, inputHatchSide = hatchSide,
                }
            end
        end
    end
end
say("Paired %d transposer(s) to an interface, %d to a fluid interface",
    pairedItem, pairedFluid)

-- Everything the modules could run on has to be gone before detection, and it has
-- to happen BEFORE the hatches are primed -- otherwise this would drain what we
-- just filled.
step("Emptying buses and hatches...")
do
    local emptied, drained, stuck = purgeFeeds(scans, itemPairs, fluidPairs)
    stepEnd("Emptied %d bus(es), drained %d hatch(es)%s", emptied, drained,
        stuck > 0 and string.format(", %d left for you", stuck) or "")
end
if #feeds == 0 then say("No usable input buses found -- nothing to configure."); return discover end

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

-- Tops a hatch up. Station:fillHatchTo owns the looping -- plasma.lua needs the
-- same thing, and it is the station that knows why more than one pass is needed.
local function fillHatchTo(st, target)
    st:fillHatchTo(target, FLUID_TIMEOUT)
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
            say("WARNING: fluid interface %s.. has %d hatches (>6 tanks) -- "
                .. "the extras cannot be staged.", feed.interface:sub(1, 8), n + 1)
        end
        fluidStations[i] = fluidStationFor(feed)
    end
end

-- 4. PHASE A -- pair input BUSES with miners. Every hatch gets a little plasma so
-- the only thing a module is still missing is its drone; then feed one bus at a
-- time and watch which miner starts.
if #fluidStations > 0 then
    local primed = 0
    for i, st in ipairs(fluidStations) do
        if st then
            st:setPlasmaSource(dropSlot)
            local okFill = fillHatchTo(st, PROBE_PLASMA_L)
            local level = st:hatchTank()
            if okFill then primed = primed + 1 end
            step("Priming hatches with %s... %d/%d", probePlasma.name, primed, #fluidStations)
            detail("  hatch %s../side%d: %d L%s",
                fluidFeeds[i].transposer:sub(1, 8), fluidFeeds[i].inputHatchSide, level,
                okFill and "" or "  (did not fill -- is that plasma in the local net?)")
            if not okFill then
                say("  hatch %s../side%d did not fill -- is that plasma in the local net?",
                    fluidFeeds[i].transposer:sub(1, 8), fluidFeeds[i].inputHatchSide)
            end
        end
    end
    stepEnd("Primed %d of %d hatch(es) with %s", primed, #fluidStations, probePlasma.name)
end

-- Miners are already off (prepare); enable them so the one with a drone runs.
for _, m in ipairs(minerList) do m:setEnabled(true) end

local assigned, foundBus = {}, 0
for _, feed in ipairs(feeds) do
    local st = stationFor(feed)
    if st then
        local ok, err = st:setDrone(probeDrone, 1)
        if not ok then
            say("  bus %s../side%d: could not load a probe drone (%s).",
                feed.transposer:sub(1, 8), feed.inputBusSide, tostring(err))
        else
            local found = waitForNewMiner(minerList, assigned)
            if found then
                assigned[found.address] = feed
                foundBus = foundBus + 1
                detail("  miner %s.. <- transposer %s.. bus side %d",
                    found.address:sub(1, 8), feed.transposer:sub(1, 8), feed.inputBusSide)
            else
                detail("  bus %s../side%d: no new miner started (already found, or none).",
                    feed.transposer:sub(1, 8), feed.inputBusSide)
            end
        end
        st:returnAll()   -- empty this bus before testing the next
    end
    step("Identifying by bus... %d/%d", foundBus, #feeds)
end
stepEnd("Identified %d miner(s) by input bus (%d bus(es) tested)", foundBus, #feeds)

-- 5. PHASE B -- pair input HATCHES with miners, the other way round: a drone in
-- EVERY bus, every hatch empty, then fill one hatch at a time.
local fluidAssigned = {}   -- miner address -> fluid feed
if #fluidStations > 0 then
    step("Settling miners between phases...")
    for _, m in ipairs(minerList) do m:setEnabled(false) end
    if not waitIdle(minerList) then
        say("  WARNING: some miners are still finishing; hatch detection may be off.")
    end

    step("Draining hatches...")
    for _, st in ipairs(fluidStations) do
        if st then
            st:clearPlasmaSource()   -- so the tank cannot refuse what we drain back
            st:drainHatch()
        end
    end

    step("Loading a drone into every bus...")
    local busStations = {}
    for i, feed in ipairs(feeds) do
        local st = stationFor(feed)
        busStations[i] = st
        if st then
            local ok, err = st:setDrone(probeDrone, 1)
            if not ok then
                say("  bus %s../side%d: %s",
                    feed.transposer:sub(1, 8), feed.inputBusSide, tostring(err))
            end
        end
    end

    for _, m in ipairs(minerList) do m:setEnabled(true) end

    local foundHatch = 0
    for i, st in ipairs(fluidStations) do
        local feed = fluidFeeds[i]
        if st then
            st:setPlasmaSource(dropSlot)
            if not fillHatchTo(st, PROBE_PLASMA_L) then
                say("  hatch %s../side%d: would not fill -- skipped.",
                    feed.transposer:sub(1, 8), feed.inputHatchSide)
            else
                local found = waitForNewMiner(minerList, fluidAssigned)
                if found then
                    fluidAssigned[found.address] = feed
                    foundHatch = foundHatch + 1
                    detail("  miner %s.. <- transposer %s.. hatch side %d tank %d",
                        found.address:sub(1, 8), feed.transposer:sub(1, 8),
                        feed.inputHatchSide, feed.fluidTank)
                else
                    detail("  hatch %s../side%d: no new miner started.",
                        feed.transposer:sub(1, 8), feed.inputHatchSide)
                end
            end
            -- Empty it again so the next hatch is the only plasma in play.
            st:clearPlasmaSource()
            st:drainHatch()
        end
        step("Identifying by hatch... %d/%d", foundHatch, #fluidStations)
    end
    stepEnd("Identified %d miner(s) by input hatch (%d hatch(es) tested)",
        foundHatch, #fluidStations)

    -- Give the drones back; the controller loads what it actually wants later.
    for _, st in ipairs(busStations) do
        if st then st:returnAll() end
    end
end

-- Give the miners back exactly as they were. Parameters only accept a write while
-- the machine is stopped, so they go back BEFORE the on/off state does.
for _, m in ipairs(minerList) do m:setEnabled(false) end
waitIdle(minerList)
for _, m in ipairs(minerList) do m:restore(snaps[m.address]) end
for _, m in ipairs(minerList) do m:setEnabled(wasOn[m.address] == true) end
-- The probe metadata stays put: the slots are named, so a later run reuses them
-- rather than tripping over them, and leaving them filled saves re-storing.
say("Database: %d of %d slot(s) used%s", handle:used(), handle:size(),
    supplyItf and ("; supply interface " .. supplyItf.address:sub(1, 8) .. "..") or "")
for _, e in ipairs(handle:dump()) do
    detail("  %2d  %-24s %s", e.slot, e.name, tostring(e.label))
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
        say("WARNING: miner %s.. was found by its hatch but not by any bus; "
            .. "its plasma feed cannot be recorded without one.", addr:sub(1, 8))
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
            say("WARNING: interface %s.. has %d stations (>9 slots) -- "
                .. "concurrent loads may collide.", st.interface:sub(1, 8), n)
        end
    end
end

-- 6. Write stations.lua.
-- The supply interface goes in too, so later runs -- and stock/plasma/the
-- controller -- can go straight to it instead of scanning every interface on the
-- network for patterns.
local payload = {
    database = dbAddr,
    supply = supplyItf and supplyItf.address or nil,
    stations = stations,
}
-- lib/stations.lua owns where this goes, so config.lua reads back exactly what
-- was written here rather than the two agreeing by coincidence.
local path, werr, text = stationfile.save(payload)
if not path then
    say("! could not write " .. stationfile.FILE .. ": " .. tostring(werr))
    print(text)
    return discover
end

say("Wrote %d station(s) to %s", #keys, path)
local withoutPlasma = 0
for _, a in ipairs(keys) do
    local st = stations[a]
    local plasma = "no plasma feed"
    if st.fluidTransposer then
        plasma = string.format("plasma %s.. hatch s%d/if s%d tank%d",
            st.fluidTransposer:sub(1, 8), st.inputHatchSide, st.fluidInterfaceSide, st.fluidTank)
    else
        withoutPlasma = withoutPlasma + 1
    end
    say("  %-12s %s.. bus s%d/if s%d slot%d  |  %s", st.label,
        st.transposer:sub(1, 8), st.inputBusSide, st.interfaceSide, st.interfaceSlot, plasma)
end
if withoutPlasma > 0 then
    say("%d module(s) have no plasma feed: each needs a transposer touching an input "
        .. "hatch and an ME interface with tanks (the same ones carrying its items will do).",
        withoutPlasma)
end
say("Keep cfg.dryRun = true until you've watched a drone move, then flip it.")
if not verbose then say("Run `setup --verbose` for per-side and per-candidate detail.") end

return discover

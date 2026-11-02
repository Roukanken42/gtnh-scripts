-- Discovering a mining setup: everything `setup` does to work out which
-- transposer feeds which module, and to leave the machinery in a state where
-- that can be observed at all.
--
-- This is a library rather than part of setup.lua because none of it is specific
-- to running setup by hand. A controller that finds a module has been rebuilt,
-- or wants to re-aim a fleet, needs the same pieces: classify a transposer's
-- sides, pair transposers to interfaces, clear leftover staging, empty buses and
-- hatches, point modules at a reachable meteor, watch for one to start mining.
--
-- Nothing here prints on its own. A caller that wants a running commentary points
-- `discover.out` at something (mining/setup.lua points it at lib/cli); everything
-- else stays silent, which is what a controller wants.

local component = require("component")
local computer = require("computer")
local drones = require("lib.gtnh.drones")
local meteors = require("lib.gtnh.meteors")
local supply = require("lib.hw.supply")

local discover = {}

-- ---- reporting ---------------------------------------------------------------
-- Silent by default. `say` is for things that always matter, `detail` for what
-- only matters once something has gone wrong, `step`/`stepEnd` for a progress
-- line that rewrites itself.
local function noop() end
discover.out = { say = noop, detail = noop, step = noop, stepEnd = noop }

local function say(...) discover.out.say(...) end
local function detail(...) discover.out.detail(...) end
local function step(...) discover.out.step(...) end
local function stepEnd(...) discover.out.stepEnd(...) end

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

-- Fluid probing. The interface tank we stage plasma through during detection,
-- 0-based like a station's stored fluidTank (see transport.lua).
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
-- How long to wait for a probe to LEAVE a side after its interface was cleared.
-- Seeing it go is what proves that interface put it there, rather than it having
-- been left behind by an earlier candidate.
local VERIFY_TIMEOUT = 5
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

-- Waits for the probe to LEAVE a transposer side after its interface was
-- cleared. This is what separates "this interface put it there" from "it was
-- already there": the second never goes away when we clear, because something
-- else staged it. Returns true if it went.
local function waitSideEmpty(tp, side, sees)
    local deadline = computer.uptime() + VERIFY_TIMEOUT
    while computer.uptime() < deadline do
        if not sees(side) then return true end
        os.sleep(POLL_INTERVAL)
    end
    return false
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
-- plus a per-side list for the --verbose printout, because getting this wrong is
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
    local ifSides, busSides, hatchSides, fluidIfSides, sides = {}, {}, {}, {}, {}
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
            sides[#sides + 1] = { side = side, name = name or "?",
                slots = slots, tanks = tanks, kind = kind }
        end
    end
    return ifSides, busSides, hatchSides, fluidIfSides, sides
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
    step("Kits: %d of %d %s, requesting %d craft(s)...", have, PROBE_KITS, material, crafts)
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
    step("Plasma: %d of %d L, requesting %d craft(s)...", now, litres, crafts)
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

-- Picks the plasma to probe hatches with: any will do for detection, so the
-- lowest tier the supply interface has a pattern for (the cheapest per litre).
-- Returns the pattern entry, or nil + error.
local function pickProbePlasma(itf, handle)
    if not itf then return nil, "no supply interface found to take plasma from" end
    local best
    for _, e in ipairs(supply.catalog(itf, handle)) do
        if e.kind == "plasma" and (not best or e.plasma.tier < best.plasma.tier) then best = e end
    end
    if not best then return nil, "the supply interface has no plasma pattern" end
    return best
end

-- Pairs transposers with the interface that feeds them, for ALL of them at once.
--
-- The loops are the other way round from the obvious shape, because the two
-- halves cost wildly different amounts: staging a probe in an ME interface takes
-- seconds of stocking, while asking a transposer what it can see is one component
-- call. So each interface is staged ONCE and every still-unpaired transposer is
-- asked about it -- the expensive half becomes O(interfaces) instead of
-- O(transposers x interfaces), and transposers sharing an interface are all
-- paired by the same staging.
--
-- `candidates` is expected to be pre-narrowed by interfacesHolding. There is no
-- overall time budget: running out of one is indistinguishable from "nothing
-- feeds this transposer", and that silence is expensive to debug.
--
-- Every sighting is bracketed by two checks, because a sighting alone proves
-- nothing. Anything visible BEFORE the candidate is staged is recorded as stale
-- and ignored -- clearing an interface does not empty it instantly, so residue
-- from the previous candidate may still be sitting there. And a sighting is only
-- accepted once clearing that interface makes it GO AWAY again; something another
-- interface staged will not budge. Skipping either is how a transposer ends up
-- paired with an interface it is not touching.
--
-- `spec` carries what differs between items and fluids:
--   sidesOf(scan)    which of that transposer's sides are worth watching
--   sees(tp, side)   is the probe visible there
--   supports(proxy)  can this interface stage that kind of probe
--   stage(proxy)     put the probe in -> token, ok, detail
--   clear(proxy, token)
-- Returns { [transposerAddress] = { interface = addr, side = n } }.
local function sweepInterfaces(scans, candidates, spec, what)
    local found, foundCount, remaining = {}, 0, 0
    for _, sc in ipairs(scans) do
        if #spec.sidesOf(sc) > 0 then remaining = remaining + 1 end
    end
    if remaining == 0 then return found end
    local total = remaining

    for _, c in ipairs(candidates) do
        if remaining == 0 then break end
        local okProxy, p = pcall(component.proxy, c)
        if okProxy and p and spec.supports(p) then
            -- Only transposers still looking, and only those with a side to look at.
            local waiting = {}
            for _, sc in ipairs(scans) do
                if not found[sc.addr] and #spec.sidesOf(sc) > 0 then waiting[#waiting + 1] = sc end
            end

            local stale = {}
            for _, sc in ipairs(waiting) do
                stale[sc] = {}
                for _, side in ipairs(spec.sidesOf(sc)) do
                    stale[sc][side] = spec.sees(sc.tp, side)
                end
            end

            local token, staged, how = spec.stage(p)
            local hits, hitCount = {}, 0
            if staged then
                local deadline = computer.uptime() + DETECT_PER_CANDIDATE
                while computer.uptime() < deadline and hitCount < #waiting do
                    for _, sc in ipairs(waiting) do
                        if not hits[sc] then
                            for _, side in ipairs(spec.sidesOf(sc)) do
                                if not stale[sc][side] and spec.sees(sc.tp, side) then
                                    hits[sc] = side
                                    hitCount = hitCount + 1
                                    break
                                end
                            end
                        end
                    end
                    if hitCount < #waiting then os.sleep(POLL_INTERVAL) end
                end
            else
                detail("      %s..: could not stage the probe -- %s", c:sub(1, 8), tostring(how))
            end

            spec.clear(p, token)

            for _, sc in ipairs(waiting) do
                local side = hits[sc]
                if side then
                    if waitSideEmpty(sc.tp, side, function(x) return spec.sees(sc.tp, x) end) then
                        found[sc.addr] = { interface = c, side = side }
                        foundCount = foundCount + 1
                        remaining = remaining - 1
                        detail("      %s..: %s %s.. on side %d",
                            sc.addr:sub(1, 8), what, c:sub(1, 8), side)
                    else
                        detail("      %s..: side %d still held the probe after clearing %s.. -- "
                            .. "not that interface", sc.addr:sub(1, 8), side, c:sub(1, 8))
                    end
                end
            end
            step("Pairing %s... %d/%d", what, foundCount, total)
        end
    end
    return found
end

-- Empties every input bus and drains every input hatch before detection begins.
-- Anything left in one makes its module runnable before we have fed it, and then
-- the first thing tested gets the credit -- a false pairing that looks exactly
-- like a correct one.
--
-- Contents go back through that transposer's PAIRED interface. A transposer that
-- could not be paired is reported instead of guessed at: pushing items into an
-- interface we have not identified could put them on the wrong network, and
-- someone else's at that.
-- Returns emptied, drained, stuck counts.
local function purgeFeeds(scans, itemPairs, fluidPairs)
    local emptied, drained, stuck = 0, 0, 0

    for _, sc in ipairs(scans) do
        local tag = sc.addr:sub(1, 8)

        local m = itemPairs[sc.addr]
        for _, busSide in ipairs(sc.busSides) do
            local held = 0
            for _, st in pairs(readSideStacks(sc.tp, busSide)) do
                if type(st) == "table" then held = held + (st.size or 0) end
            end
            if held > 0 then
                if m then
                    -- getAllStacks is 0-indexed, transferItem takes 1-based slots.
                    for i, st in pairs(readSideStacks(sc.tp, busSide)) do
                        if type(st) == "table" and (st.size or 0) > 0 then
                            pcall(sc.tp.transferItem, busSide, m.side, st.size, i + 1)
                        end
                    end
                    emptied = emptied + 1
                    detail("  %s.. bus side %d: returned %d item(s)", tag, busSide, held)
                else
                    stuck = stuck + 1
                    say("  %s.. bus side %d holds %d item(s) and has no paired interface to "
                        .. "return them through -- empty it by hand, or its module may be "
                        .. "credited to the wrong bus.", tag, busSide, held)
                end
            end
        end

        local f = fluidPairs[sc.addr]
        for _, hatchSide in ipairs(sc.hatchSides) do
            local okL, level = pcall(sc.tp.getTankLevel, hatchSide, 1)
            level = (okL and tonumber(level)) or 0
            if level > 0 then
                if f then
                    pcall(sc.tp.transferFluid, hatchSide, f.side, level, 0)
                    drained = drained + 1
                    detail("  %s.. hatch side %d: drained %d L", tag, hatchSide, level)
                else
                    stuck = stuck + 1
                    say("  %s.. hatch side %d holds %d L and has no paired fluid interface to "
                        .. "drain into -- empty it by hand, or its module may be credited to "
                        .. "the wrong hatch.", tag, hatchSide, level)
                end
            end
        end
    end

    return emptied, drained, stuck
end

-- A distance at which this drone tier and module tier can actually find
-- something. Detection needs a module to START mining, and it will not start with
-- nothing in range -- which is indistinguishable from a wiring fault.
--
-- There is no single number that works: what is reachable depends on the
-- distance, the drone tier AND the module tier all at once, so every module needs
-- its own. The pool only changes where some meteor's range begins or ends, so only
-- those distances are worth testing.
--
-- Among the distances that yield anything, the one whose cheapest meteor needs the
-- least COMPUTATION wins: a module starved of computation will not start either,
-- and setup has no way to give it more. Meteors the module could not power at one
-- parallel are ignored, since it cannot run those at all. Ties go to the bigger
-- pool, then the shorter distance. Returns nil if nothing is ever reachable.
local distanceCache = {}

local function probeDistance(droneTier, moduleTier, voltage)
    local key = droneTier .. ":" .. moduleTier .. ":" .. voltage
    local cached = distanceCache[key]
    if cached ~= nil then return cached or nil end

    local seen, grid = {}, {}
    for _, m in ipairs(meteors.list) do
        for _, d in ipairs({ m.distance[1], m.distance[2] + 1 }) do
            if d >= 1 and not seen[d] then seen[d] = true; grid[#grid + 1] = d end
        end
    end
    table.sort(grid)

    local best, bestComp, bestCount
    for _, d in ipairs(grid) do
        local cheapest, count = nil, 0
        for _, m in ipairs(meteors.list) do
            if meteors.canFind(m, d, droneTier, moduleTier) then
                local s = meteors.scale(m, droneTier)
                if s and s.eut <= voltage then
                    count = count + 1
                    if not cheapest or m.computation < cheapest then cheapest = m.computation end
                end
            end
        end
        if cheapest and (not best or cheapest < bestComp
            or (cheapest == bestComp and count > bestCount)) then
            best, bestComp, bestCount = d, cheapest, count
        end
    end

    distanceCache[key] = best or false
    return best
end

-- Points every module at something it can actually mine, and takes a snapshot so
-- the run can put the settings back. Parameter writes only take while the machine
-- is STOPPED, so this must run after prepare() has switched them off and waited.
--
-- Distance mode goes to static as well: left on automatic the module sweeps the
-- distance itself and would wander off whatever we chose. Max parallels is forced
-- to a sane value for the same reason a distance is chosen -- a module at zero
-- parallels never starts.
-- Returns the snapshots, keyed by miner address.
local function aimMiners(minerList, droneTier)
    local snaps, aimed, stuck = {}, 0, 0
    for _, m in ipairs(minerList) do
        snaps[m.address] = m:snapshot()
        local d = probeDistance(droneTier, m.tier or 1, m.voltage or 0)
        if not d then
            stuck = stuck + 1
            say("  %s.. (%s): no meteor is reachable with the probe drone -- it cannot "
                .. "be identified.", m.address:sub(1, 8), tostring(m.tierName))
        else
            m:setStatic()
            m:setDistance(d)
            m:setMaxParallels(m.parallels or 1)
            aimed = aimed + 1
            detail("  %s.. (%s): distance %d, %d parallel(s)",
                m.address:sub(1, 8), tostring(m.tierName), d, m.parallels or 1)
        end
    end
    return snaps, aimed, stuck
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

-- Clears anything a previous run may have left STAGED on an interface. A run that
-- died partway through leaves a drone or a plasma sitting in a config, and a
-- staged probe that nobody put there this time is exactly what makes a transposer
-- pair with an interface it is not touching.
--
-- Only what setup itself stages is touched -- drone item configs and plasma fluid
-- configs. An interface is very likely stocking things for the rest of the base,
-- and clearing those would be a rude surprise.
--
-- Item slots are swept from 0, not 1: stageProbe tries a 0-based index too, since
-- the fluid side of the same block turned out to count from zero.
-- Returns how many item and fluid configs were cleared.
local function clearStaging(interfaceComps)
    local items, fluids = 0, 0
    for _, c in ipairs(interfaceComps) do
        local ok, p = pcall(component.proxy, c)
        if ok and p then
            if p.getInterfaceConfiguration ~= nil and p.setInterfaceConfiguration ~= nil then
                for slot = 0, 9 do
                    local okc, cfg = pcall(p.getInterfaceConfiguration, slot)
                    if okc and type(cfg) == "table" and cfg.name == drones.ITEM_NAME then
                        pcall(p.setInterfaceConfiguration, slot)
                        items = items + 1
                    end
                end
            end
            if p.getFluidInterfaceConfiguration ~= nil
                and p.setFluidInterfaceConfiguration ~= nil then
                -- 1-based since GTNH 2.9 (see transport.lua).
                for tank = 1, 6 do
                    local okc, cfg = pcall(p.getFluidInterfaceConfiguration, tank)
                    if okc and type(cfg) == "table" then
                        -- supply.plasmaOf unwraps the ae2fc "drop of X" form too.
                        local label = cfg.label or cfg.name
                        if label and supply.plasmaOf(label) then
                            pcall(p.setFluidInterfaceConfiguration, tank)
                            fluids = fluids + 1
                        end
                    end
                end
            end
        end
    end
    return items, fluids
end

-- Clean slate before detection: clear leftover staging (above), switch every
-- miner off, and wait for in-progress mining to finish (isMachineActive lags
-- after a miner is switched off). Returns each miner's original on/off state.
local function prepare(interfaceComps, minerList)
    local items, fluids = clearStaging(interfaceComps)
    if items + fluids > 0 then
        detail("  cleared %d leftover item config(s) and %d fluid config(s)", items, fluids)
    end

    local wasOn = {}
    for _, m in ipairs(minerList) do
        wasOn[m.address] = minerOn(m)
        m:setEnabled(false)
    end

    if not waitIdle(minerList) then
        say("  WARNING: some miners are still finishing; detection may be off -- re-run if needed.")
    end
    return wasOn
end

-- Picks the database to stage probes through (first one found).
local function pickDatabase()
    return listByType("database")[1]
end

-- Picks the database to stage probes through (first one found).
local function pickDatabase()
    return listByType("database")[1]
end

discover.listByType = listByType
discover.readSideStacks = readSideStacks
discover.sideHasLabel = sideHasLabel
discover.waitSideEmpty = waitSideEmpty
discover.tankCount = tankCount
discover.inventorySize = inventorySize
discover.scanSides = scanSides
discover.storeProbe = storeProbe
discover.stageProbe = stageProbe
discover.sweepInterfaces = sweepInterfaces
discover.interfacesHolding = interfacesHolding
discover.interfacesHoldingFluid = interfacesHoldingFluid
discover.ensureKits = ensureKits
discover.ensurePlasma = ensurePlasma
discover.pickProbePlasma = pickProbePlasma
discover.minerActive = minerActive
discover.minerOn = minerOn
discover.waitIdle = waitIdle
discover.waitForNewMiner = waitForNewMiner
discover.clearStaging = clearStaging
discover.purgeFeeds = purgeFeeds
discover.probeDistance = probeDistance
discover.aimMiners = aimMiners
discover.prepare = prepare
discover.pickDatabase = pickDatabase

discover.INTERFACE_NAMES = INTERFACE_NAMES
discover.INPUT_BUS_NAME = INPUT_BUS_NAME
discover.SIDE_LABEL = SIDE_LABEL
discover.POLL_INTERVAL = POLL_INTERVAL
discover.MINER_TIMEOUT = MINER_TIMEOUT
discover.PROBE_PLASMA_L = PROBE_PLASMA_L
discover.PROBE_FLUID_TANK = PROBE_FLUID_TANK
discover.PROBE_CFG_SLOT = PROBE_CFG_SLOT
discover.FLUID_TIMEOUT = FLUID_TIMEOUT
discover.STAGING_L = STAGING_L

return discover

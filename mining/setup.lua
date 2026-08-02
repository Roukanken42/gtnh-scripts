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
local meteors = require("meteors")

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

-- ---- output ----------------------------------------------------------------
-- A default run is meant to fit on one screen: the narrative, the result, and
-- anything that went wrong. Detail that only matters once something HAS gone
-- wrong -- per-side classification, per-candidate probe outcomes, the database
-- slot map -- is behind --verbose.
local verbose = false
for _, a in ipairs({ ... }) do
    if a == "-v" or a == "--verbose" then verbose = true end
end

local term = nil
do local okT, t = pcall(require, "term"); term = okT and t or nil end

local function fmt(f, ...)
    if select("#", ...) > 0 then return string.format(f, ...) end
    return f
end

-- A step line rewrites itself in place, so "3/9 primed" does not become nine
-- lines of scroll. `stepping` tracks whether one is still open, because anything
-- printed on top of it would land mid-line.
local stepping = false

local function say(f, ...)
    if stepping then io.write("\n"); stepping = false end
    print(fmt(f, ...))
end

local function detail(f, ...)
    if verbose then say(f, ...) end
end

-- With --verbose each update is printed instead: the detail lines in between
-- would scroll a self-rewriting line away anyway.
local function step(f, ...)
    local line = fmt(f, ...)
    if verbose or not term then say(line); return end
    local ok = pcall(function()
        local _, y = term.getCursor()
        term.setCursor(1, y)
        term.clearLine()
        io.write(line)
    end)
    if ok then stepping = true else print(line) end
end

-- Closes a step line, optionally replacing it with its final form.
local function stepEnd(f, ...)
    if f then step(f, ...) end
    if stepping then io.write("\n"); stepping = false end
end

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
-- distance itself and would wander off whatever we chose. Overdrive and max
-- parallels are forced to sane values for the same reason a distance is chosen --
-- a module at zero parallels, or zero overdrive, never starts.
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
            m:setOverdrive(1)
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
                for tank = 0, 5 do
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
    sweepInterfaces = sweepInterfaces,
    interfacesHolding = interfacesHolding,
    interfacesHoldingFluid = interfacesHoldingFluid,
    tankCount = tankCount,
    inventorySize = inventorySize,
    ensureKits = ensureKits,
    ensurePlasma = ensurePlasma,
    stagePlasmaDrop = stagePlasmaDrop,
    minerActive = minerActive,
    minerOn = minerOn,
    clearStaging = clearStaging,
    purgeFeeds = purgeFeeds,
    probeDistance = probeDistance,
    aimMiners = aimMiners,
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

say("== Mining controller setup (automatic) ==%s", verbose and "  [verbose]" or "")

-- 1. Local net + probe drone.
local net, nerr = localnet.proxy()
if not net then say("ERROR: " .. nerr); return M end
local probe = localnet.lowestDrone(net)
if not probe then
    say("ERROR: no mining drones in the local net -- keep a few of the lowest")
    say("       tier in stock so setup can borrow one to probe with.")
    return M
end
local probeDrone = drones.fromName(probe.label) or { name = probe.label }
say("Probe: %s (tier %s)", probe.label, tostring(probe.tier))

-- 2. Database for staging probes. Slots come from db.lua by NAME, so the probe
-- drone, the plasma drop and the scratch entry cannot land on each other -- which
-- they used to, silently, leaving a plasma drop where the drone should have been.
local dbAddr = pickDatabase()
if not dbAddr then
    say("ERROR: no database component. Add a Database Upgrade in an adapter.")
    return M
end
local handle, dbErr = dbslots.open(dbAddr)
if not handle then say("ERROR: " .. tostring(dbErr)); return M end
detail("Database %s..: %d slot(s)", dbAddr:sub(1, 8), handle:size())

local dbSlot, derr = storeProbe(net, handle, probe)
if not dbSlot then say("ERROR: " .. tostring(derr)); return M end

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
if #feeds == 0 then say("No usable input buses found -- nothing to configure."); return M end

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
    say("! could not write " .. path .. ": " .. tostring(ferr))
    print(text)
    return M
end
f:write(text)
f:close()

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

return M

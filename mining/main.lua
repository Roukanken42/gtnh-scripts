-- Mining controller -- MANUAL mode.
--
-- You configure the modules at the machine (drone, distance, overdrive) and this
-- keeps them fed: plasma into every hatch, kits and plasma into the local net
-- from the main-net supply interface. It never touches a module's parameters and
-- never switches one on or off, so stopping the controller does not stop mining.
--
-- The one decision it does own is WHICH PLASMA the fleet runs on, because that is
-- fleet-wide (a hatch holds one fluid) and switching it means draining every
-- hatch that disagrees. Press P, choose, confirm.
--
-- Automatic mode -- picking configurations with target.lua instead of being told
-- them -- comes later; this is the half that has to work first.
--
-- Run from the mining folder:  main
-- See `main --help`, and config.lua for the knobs.

local miners = require("lib.hw.miners")
local supply = require("lib.hw.supply")
local control = require("lib.control")
local localnet = require("lib.hw.localnet")
local dbslots = require("lib.hw.db")
local drones = require("lib.gtnh.drones")
local plasmas = require("lib.gtnh.plasmas")
local estimate = require("lib.calc.estimate")
local targeter = require("lib.calc.target")
local profile = require("lib.profile")
local ui = require("lib.ui")
local cli = require("lib.cli")
local cfg = require("config")
local event = require("event")
local computer = require("computer")

local ctx = cli.start({
    name = "main",
    summary = "Mining controller: keeps a manually-configured fleet fed.",
    usage = {
        { "main",          "run the controller until stopped" },
        { "main --no-ui",  "run headless, logging to the console" },
        { "main --once",   "run a single maintenance cycle and exit" },
        { "main --profile","write a timing report to a file on exit" },
    },
    flags = {
        { "--no-ui", "no dashboard; print each cycle instead" },
        { "--once",  "one cycle, then exit (for checking a fresh setup)" },
        { "--profile", "measure where the time goes; F shows it, and it is written"
            .. " to mining-profile.txt on exit" },
    },
    notes = {
        "MANUAL mode. You set each module's drone, distance and overdrive yourself; "
            .. "the controller only keeps the consumables flowing. It does not "
            .. "enable, disable or reconfigure a module, so quitting leaves the fleet "
            .. "mining -- with whatever is already in its hatches.",
        "The arrows move down the module list and ENTER opens one. That screen shows "
            .. "its meteor pool and the ore coming out of it (TAB switches between "
            .. "the two), and lets you drive its drone, distance, overdrive and "
            .. "plasma: arrows pick a field, ENTER starts editing, arrows change the "
            .. "value, ENTER applies. Both tables are recomputed from the value being "
            .. "dialled, so you see what a change would do BEFORE applying it.",
        "Distance, overdrive and a drone swap need the module STOPPED -- TecTech "
            .. "accepts a parameter write no other way -- and a mining operation "
            .. "runs for tens of seconds. So applying one QUEUES it: the module is "
            .. "asked to stop, the controller waits in the background, and the write "
            .. "happens the moment it is down. Work is re-allowed afterwards unless "
            .. "it was off to begin with. The PENDING column says what each module "
            .. "is still waiting on.",
        "Plasma is fleet-wide by default because a GT hatch holds one fluid at a "
            .. "time. Press P for the plasma list, arrows to choose, ENTER to select, "
            .. "ENTER again to confirm; every hatch holding something else is drained "
            .. "back into the network first, so the switch takes a few cycles to "
            .. "settle. A single module can be switched on its own from its detail "
            .. "screen, and the controller then keeps it on that plasma rather than "
            .. "putting it back on the fleet's.",
        "What to stock is read off the hardware: a module's input bus says which "
            .. "drone it runs, and that says which material its kits are made of. "
            .. "Set cfg.supply.target or cfg.supply.plasma to override a figure; "
            .. "left nil, the fleet's own answer is used (cfg.control tunes it).",
        "Restock requests are capped -- by default 2 kit jobs and 1 plasma job at "
            .. "once -- because each one holds a crafting CPU on the main net until "
            .. "its inputs are pushed. The emptiest material goes first.",
        "A craft is never ordered twice, because the local net is re-read the "
            .. "moment one finishes and the next decision is made against what is "
            .. "actually there. Requests are therefore only made on the cycles that "
            .. "carry a fresh reading -- planning against a stale one would order a "
            .. "shortfall that has already been filled.",
        "From a module's detail screen, A opens the ADVISOR: pick the material you "
            .. "want and it asks the targeter for the best setups this module could "
            .. "run, then applies the one you choose. Any of the four parameters can "
            .. "be PINNED first (ENTER on it, arrows to set, X to release) -- pinning "
            .. "narrows the search rather than filtering its results, so what comes "
            .. "back is the best available UNDER the pin. Only the module's own tier "
            .. "is searched, since that is hardware.",
        "Configurations the fleet cannot supply -- kits of a material with no "
            .. "pattern, a plasma with no pattern, a drone tier nobody owns -- are "
            .. "left out by default, since a recommendation you cannot run is worse "
            .. "than one fewer. The last setting row shows them instead, marked in "
            .. "red with what is missing. A PINNED drone or plasma is always "
            .. "searched, available or not.",
        "M and O open the whole fleet's meteor pool and ore output -- the same two "
            .. "questions a module's detail screen answers, added up across every "
            .. "module that has a drone, a distance and plasma. Both scroll, as do "
            .. "the per-module tables: arrows on the fleet screens, PgUp/PgDn "
            .. "anywhere (the arrows pick a parameter on a detail screen).",
        "C copies the module under the cursor -- its drone, distance, overdrive and "
            .. "plasma -- and V pastes them onto another. The clipboard is held, so "
            .. "one module can be pasted onto several in turn; Q closes copy mode "
            .. "rather than quitting. Only the settings that actually differ are "
            .. "queued, so pasting does not stop a module to write what it already "
            .. "has.",
        "Q always means BACK OUT ONE LEVEL: cancel an edit, close a picker, leave "
            .. "a screen -- and on the dashboard with nothing open, quit. There is no "
            .. "ESC binding anywhere, because pressing it in OpenComputers closes the "
            .. "screen instead of reaching the program.",
        "SPACE pauses maintenance (the modules keep running); L shows the log.",
        "Run with --profile when a cycle feels slow, then press F: it shows where "
            .. "each cycle's time went and how many component calls it made. That "
            .. "second number is usually the answer -- an OpenComputers call that is "
            .. "not direct returns on the NEXT TICK, so it costs 50ms however trivial "
            .. "it is, and a cycle making a hundred of them takes five seconds no "
            .. "matter how fast the blocks are. S writes the report to a file, since "
            .. "the log only shows a few lines. Without the flag nothing is measured "
            .. "and nothing is wrapped, so the controller pays no overhead for it.",
    },
}, ...)
if not ctx then return end

-- Before anything is wrapped: a proxy handed out while profiling is off is the
-- bare proxy, and stays that way for the life of the run.
if ctx.flags.profile then
    profile.enable()
    profile.root = "whole cycle"
end

local scfg = cfg.supply or {}
local ccfg = cfg.control or {}

local interval = math.max(ccfg.interval or 5, 1)
local uiRefresh = math.max(ccfg.uiRefresh or 1, 0.1)
local jobLimits = ccfg.jobs or control.JOBS

-- ---- log ---------------------------------------------------------------------

local messages = {}
local MAX_MESSAGES = 200

local function log(msg)
    local line = "[" .. os.date("%H:%M:%S") .. "] " .. msg
    messages[#messages + 1] = line
    if #messages > MAX_MESSAGES then table.remove(messages, 1) end
    if not ui.active then print(line) end
end

-- ---- hardware ----------------------------------------------------------------

local shared = {
    database = cfg.database,
    dryRun = cfg.dryRun,
    stockTimeout = cfg.stockTimeout,
    interfaceSlot = cfg.interfaceSlot,
    log = log,
}

local fleet = miners.discover()
table.sort(fleet, function(a, b)
    if a.tier ~= b.tier then return a.tier > b.tier end
    return a.address < b.address
end)

-- Everything the controller talks to goes through a timing wrapper. It is put on
-- here, at the one place that owns the proxies, so nothing downstream knows or
-- cares -- and the profile screen can then say which component is costing the
-- cycle without a single call site being instrumented by hand.
local function watch(p, kind) return profile.proxy(p, kind) end

for _, m in ipairs(fleet) do
    m.proxy = watch(m.proxy, "miner")
    local spec = cfg.stations and cfg.stations[m.address]
    if spec then
        local ok, err = miners.attachStation(m, spec, shared)
        if not ok then
            log("station " .. m.address:sub(1, 8) .. ": " .. tostring(err))
        else
            local st = m.station
            st.transposer = watch(st.transposer, "transposer")
            st.interface = watch(st.interface, "interface")
            st.fluidTransposer = watch(st.fluidTransposer, "fluidTransposer")
            st.fluidInterface = watch(st.fluidInterface, "fluidInterface")
            if st.db then st.db.proxy = watch(st.db.proxy, "database") end
        end
    end
end

-- The supply interface, its catalog and the local net. Any of these can be
-- missing on a half-built setup, so each failure is recorded and the controller
-- carries on doing whatever it still can -- topping hatches up needs none of them.
local itf, dbHandle, catalog, net, supplyErr

local function openSupply()
    itf, catalog, supplyErr = nil, {}, nil

    local handle, dbErr = dbslots.open(cfg.database)
    if not handle then
        supplyErr = "database: " .. tostring(dbErr)
        return
    end
    dbHandle = handle

    local found, how = supply.find(scfg.interface)
    if not found then
        supplyErr = tostring(how)
        return
    end
    itf = watch(found, "supply")

    local usable, unknown = supply.catalog(itf, dbHandle)
    catalog = usable
    log(string.format("Supply interface %s (%s): %d pattern(s)%s",
        itf.address:sub(1, 8), tostring(how), #usable,
        #unknown > 0 and (", " .. #unknown .. " unrecognised") or ""))
end

openSupply()
net = watch(localnet.proxy(), "localnet")
if not net then log("No local ME controller found -- stock levels are unreadable.") end

-- ---- state -------------------------------------------------------------------

local jobs = control.newJobs(jobLimits)

-- Changes asked for but not yet made. A module has to be stopped before a
-- parameter will take, and a mining operation runs for tens of seconds, so the
-- controller works at these in the background instead of waiting.
local queue = control.newQueue()
local satisfied = {}            -- hysteresis latch, carried across cycles
-- The plasma most of the fleet is on. DISPLAY ONLY -- the KPI card and the marker
-- in the plasma picker. No decision reads it: what a given module should be on is
-- control.plasmaFor, which deliberately never consults the fleet.
local activePlasma = nil
local desiredPlasma = {}        -- address -> plasma a module was switched to
local pendingPlasma = nil       -- chosen in the UI, applied by the next cycle
local plasmaSlots = {}          -- plasma name -> database slot of its drop

local paused = false
local showLog = false

local view = { miners = {}, kits = {}, plasmas = {}, totals = {} }
local stock = { items = {}, fluids = {} }

-- Drone tier -> how many the local net holds. A drone is a catalyst rather than a
-- consumable, so this is a presence check: read alongside the stock, since it is
-- the same kind of question and the same cadence.
local droneStock = {}

-- Where the keyboard is: which screen, which row, and what is being edited.
-- control.key owns every transition; main only carries the actions out.
local nav = control.newNav()

local MATERIALS = control.materialsByTier()

-- How often the slow half of readFleet runs, in cycles. See readFleet.
local slowEvery = math.max(ccfg.slowEvery or 6, 1)

-- What the slow reads last saw, by module address, so a fast cycle can carry it
-- forward instead of asking again.
-- A queued change in twenty columns: "OD 1.35 stopping". control.describe spells
-- it out in full, which is right for the log and too wide for a table cell.
local function pendingLabel(e)
    local what
    if e.field == "drone" then
        local d = drones.get(e.value)
        what = d and ("MK-" .. d.roman) or "drone"
    elseif e.field == "distance" then
        what = "dist " .. tostring(e.value)
    elseif e.field == "overdrive" then
        what = string.format("OD %.2f", e.value)
    else
        what = e.plasma and (e.plasma.name:gsub(" Plasma$", "")) or "plasma"
    end
    return what .. " " .. e.state
end

local slowSeen = {}

-- Modules whose slow half must be re-read on the next pass whatever the cadence
-- says. Set when something has just changed one of those values, so the screen
-- catches up at once instead of at the next slow cycle -- and set per MODULE,
-- because re-reading the whole fleet to learn one drone costs a tick per hatch and
-- bus in it.
local slowDue = {}

-- What each module is doing, read fresh. Everything the dashboard shows about a
-- miner comes from here, so a cheap UI repaint never touches hardware.
--
-- Split by how fast the answer actually changes, because each read here is a
-- component call and an indirect one costs a whole tick:
--
--   every cycle   the parameters and whether it is running -- both DIRECT, and
--                 so free, which the profile settled -- and the input hatch,
--                 which is the one thing topping up decides on.
--   `full` only   which drone is in the bus, and how much is staged in the
--                 interface tank. A drone changes when the player changes it, so
--                 slowDue forces those modules on the next pass; the staged
--                 figure is only ever displayed.
local function readFleet(full)
    local rows = {}
    for _, m in ipairs(fleet) do
        local st = m.station
        local row = {
            miner = m, station = st,
            tierName = m.tierName, addr = m.address:sub(1, 8),
            hasFluid = st ~= nil and st:hasFluid(),
            hasItems = st ~= nil and st:hasItems(),
        }

        local snap = m:snapshot()
        row.distance = snap.distance
        row.overdrive = snap.overdrive
        -- What the module is SET to, over what its tier can do -- "4/8" means
        -- half the parallels are being left on the table, which is worth seeing.
        row.parallels = snap.maxParallels
        row.parallelCap = m.parallels

        -- The drone in the input bus is what the module mines with, and its
        -- material is what its kits are made of -- the whole demand, read off the
        -- hardware rather than configured twice.
        local seen = slowSeen[m.address]
        if full or slowDue[m.address] then
            slowDue[m.address] = nil
            seen = {}
            slowSeen[m.address] = seen
            if row.hasItems then
                for _, s in ipairs(st:busStacks()) do
                    local d = drones.fromName(s.label)
                    -- "MK-X" rather than the full "Mining Drone MK-X": the column
                    -- is headed DRONE and every one of them starts the same way.
                    if d then
                        seen.drone, seen.material = "MK-" .. d.roman, d.material
                        seen.droneTier = d.tier
                        break
                    end
                end
            end
            if row.hasFluid then seen.staged = st:bufferTank() end
        end
        if seen then
            row.drone, row.material = seen.drone, seen.material
            row.droneTier, row.staged = seen.droneTier, seen.staged
        end

        if row.hasFluid then
            -- One call for all three: level, capacity and which fluid.
            row.hatchLevel, row.hatchCapacity, row.hatchFluid = st:hatchInfo()
            local p = row.hatchFluid and plasmas.byName[row.hatchFluid]
            if p then
                row.plasma = p
                row.hatchTarget = supply.hatchLitres(p, scfg)
            end
        end

        -- Precedence is worst-first: a module with no station cannot be helped at
        -- all, and an empty hatch explains an idle module better than "IDLE" does.
        if not st then row.state = "NO STATION"
        elseif not row.drone then row.state = "NO DRONE"
        elseif row.hasFluid and (row.hatchLevel or 0) <= 0 then row.state = "DRY"
        elseif m:isActive() then row.state = "MINING"
        else row.state = "IDLE" end

        -- What it is still waiting on. Read here rather than when the view is
        -- assembled, so a row is never handed out with a stale idea of it -- the
        -- moment that matters is right after a keypress queues something.
        local waiting = queue:pending(m.address)
        if #waiting > 0 then
            local e = waiting[1]
            row.pending = pendingLabel(e)
            if #waiting > 1 then row.pending = row.pending .. " +" .. (#waiting - 1) end
            row.pendingNote = e.note
            row.pendingCount = #waiting
            -- A module told to stop is not idle, it is finishing an operation.
            if e.state == "stopping" and (row.state == "IDLE" or row.state == "MINING") then
                row.state = "STOPPING"
            end
        end
        row.stateKind = row.state

        rows[#rows + 1] = row
    end
    return rows
end

-- The plasma the fleet is on: whatever most hatches hold. Manual mode runs one
-- plasma everywhere, so a disagreement means a switch is still settling.
-- The four drivable parameters of the open module, as the values an EDIT starts
-- from. Anything the module cannot tell us is nil, and control.key refuses to
-- start editing a field with no current value -- there is nothing to step from.
local function currentOf(row)
    return {
        drone = row.droneTier,
        distance = row.distance,
        overdrive = row.overdrive,
        plasma = row.plasma and row.plasma.tier or nil,
    }
end

-- The plasma a module is MEANT to be on. The precedence, and the deliberate
-- absence of a fleet-wide fallback at the end of it, are in control.plasmaFor.
local function wantedPlasma(row)
    local queued = queue:find(row.addr, "plasma")
    return control.plasmaFor(queued and queued.plasma or nil,
        desiredPlasma[row.addr], row.plasma)
end

local function detectPlasma(rows)
    local counts, best, bestN = {}, nil, 0
    for _, r in ipairs(rows) do
        local p = r.hatchFluid and plasmas.byName[r.hatchFluid]
        if p then
            counts[p.tier] = (counts[p.tier] or 0) + 1
            if counts[p.tier] > bestN then best, bestN = p, counts[p.tier] end
        end
    end
    return best
end

-- The database slot holding a plasma's ae2fc drop, cached: the fluid interfaces
-- keep pointing at it, so it is stored once and reused for as long as the
-- controller runs.
local function slotFor(p)
    if plasmaSlots[p.name] then return plasmaSlots[p.name] end
    if not itf or not dbHandle then return nil, supplyErr or "no supply interface" end
    local slot, err = control.plasmaSlot(catalog, itf, dbHandle, p)
    if not slot then return nil, err end
    plasmaSlots[p.name] = slot
    return slot
end

-- Queues a committed edit. Nothing is written here: a parameter needs the module
-- stopped, and a module mid-operation takes tens of seconds to get there, so the
-- control thread works at it in the background and the dashboard shows it
-- waiting. Which also means the key handler stays instant.
local function commitEdit(row, field, value)
    local extra
    if field == "plasma" then
        local p = plasmas.byTier[value]
        if not p then return end
        if not row.station or not row.hasFluid then
            log(row.addr .. ": no plasma feed configured")
            return
        end
        local slot, err = slotFor(p)
        extra = { plasma = p, slot = slot, slotError = err }
        -- Recorded as this module's intent right away, so the staging logic stops
        -- treating it as a module that has lost its plasma.
        desiredPlasma[row.addr] = p
    end

    local e = queue:want(row.addr, field, value, computer.uptime(), extra)
    log(string.format("%s: %s queued", row.addr, (control.describe(e))))
    -- So the next read shows it as pending rather than looking ignored.
    slowDue[row.miner.address] = true
end

-- Applies a copied config to another module. Only the fields that DIFFER are
-- queued: pasting a value a module already has would stop it, write what was
-- already there, and start it again for nothing.
local function pasteInto(row, clip)
    if not clip then return end
    if clip.addr == row.addr then
        log(row.addr .. ": that is where the config came from")
        return
    end

    local cur = currentOf(row)
    local n = 0
    for _, f in ipairs(control.FIELDS) do
        local want = clip[f.key]
        if want ~= nil and want ~= cur[f.key] then
            commitEdit(row, f.key, want)
            n = n + 1
        end
    end
    if n == 0 then
        log(row.addr .. ": already matches " .. tostring(clip.addr))
    else
        log(string.format("%s: %d setting(s) queued from %s", row.addr, n,
            tostring(clip.addr)))
    end
end

-- The advisor owns its own keyboard; this is the part that needs the fleet.
-- ---- one maintenance cycle ---------------------------------------------------

local cycle = 0

local function runCycle()
    cycle = cycle + 1
    if profile.enabled then profile.cycles = profile.cycles + 1 end
    local endCycle = profile.span("whole cycle")

    -- The slow reads happen on the first cycle and every slowEvery-th after.
    local full = (cycle % slowEvery) == 1 or slowEvery == 1

    local doneRead = profile.span("readFleet")
    local rows = readFleet(full)
    doneRead()

    -- Jobs first: a finished craft has already landed in the local net, so the
    -- stock read below sees it and the plan does not ask for it again.
    local donePoll = profile.span("poll restock jobs")
    local finishedJobs = jobs:poll(computer.uptime(), ccfg.settleGrace)
    donePoll()
    for _, j in ipairs(finishedJobs) do
        if j.state == "done" then
            log(string.format("stocked %s (x%d)", j.key, j.crafts))
        else
            log(string.format("%s restock %s", j.key, j.state))
        end
    end

    -- A craft has landed, so what the net holds has changed. Re-read it NOW
    -- rather than waiting for the slow cadence: this reading is what stops the
    -- same shortfall being ordered a second time, and it is one component call.
    local stockFresh = false
    if #finishedJobs > 0 and net and #catalog > 0 then
        local doneRefresh = profile.span("refresh stock after a craft")
        stock = supply.stock(catalog, net)
        stockFresh = true
        doneRefresh()
    end

    if full and net then
        local doneDrones = profile.span("read drones in stock")
        droneStock = {}
        for _, d in ipairs(localnet.dronesInStock(net)) do
            if d.tier then droneStock[d.tier] = (droneStock[d.tier] or 0) + (d.size or 0) end
        end
        doneDrones()
    end

    -- A fleet-wide plasma choice becomes one queued change per module, exactly as
    -- an individual switch does. Each hatch then drains and refills at its own
    -- pace, none of it blocks the loop, and the dashboard shows every one of them
    -- working through it.
    if pendingPlasma then
        local p = pendingPlasma
        pendingPlasma = nil
        local slot, err = slotFor(p)
        if not slot then
            log("cannot stage " .. p.name .. ": " .. tostring(err))
        else
            local n = 0
            for _, r in ipairs(rows) do
                if r.station and r.hasFluid then
                    desiredPlasma[r.addr] = p
                    queue:want(r.addr, "plasma", p.tier, computer.uptime(),
                        { plasma = p, slot = slot })
                    n = n + 1
                end
            end
            activePlasma = p
            log(string.format("switching %d module(s) to %s", n, p.name))
        end
    else
        activePlasma = detectPlasma(rows) or activePlasma
    end

    local doneHatch = profile.span("hatches")
    -- Work at whatever each module has been asked to change. Before the hatches,
    -- so a plasma switch gets its drain in before anything tries to top it up.
    local doneQueue = profile.span("queued changes")
    local landed = false
    for _, r in ipairs(rows) do
        local settled = control.stepModule(queue, r, computer.uptime(), ccfg)
        for _, e in ipairs(settled) do
            local what = control.describe(e)
            if e.state == "done" then
                log(string.format("%s: %s set", r.addr, what))
            else
                log(string.format("%s: %s FAILED -- %s", r.addr, what, tostring(e.error)))
            end
            -- Whatever it was, the row read a moment ago describes the module as it
            -- was BEFORE. A drone is the one that shows: it is a slow read, so a
            -- finished swap would sit there with the pending gone and the old drone
            -- still named until the slow cadence came round half a minute later.
            slowDue[r.miner.address] = true
            landed = true
        end
    end
    if landed then rows = readFleet(false) end
    doneQueue()

    -- No fleet-wide condition on any of this. It used to run only when a plasma
    -- had been DETECTED across the fleet, which meant a module whose hatch was
    -- empty never got filled -- and a switch onto an empty hatch sat in "filling"
    -- for ever, waiting for a fluid that nothing was moving. Each hatch is decided
    -- on its own, from the plasma that module is meant to be on.
    if not paused then
        -- Assert the staging config for any station that has none: a hatch can
        -- only be filled from a tank that is pointed at the right fluid, and a
        -- previous run (or `plasma drain`) may have cleared it. One mid-switch is
        -- left alone -- the queue is already handling it.
        for _, r in ipairs(rows) do
            if r.station and r.hasFluid and not queue:find(r.addr, "plasma")
                and (r.staged or 0) <= 0 and (r.hatchLevel or 0) <= 0 then
                local want = wantedPlasma(r)
                local slot = want and (plasmaSlots[want.name] or select(1, slotFor(want)))
                if slot then r.station:setPlasmaSource(slot) end
            end
        end

        -- The levels readFleet just read, rather than reading them again. Each
        -- hatch is filled to ITS plasma's target.
        local hatches = {}
        for _, r in ipairs(rows) do
            if r.station and r.hasFluid then
                local switching = queue:find(r.addr, "plasma")
                hatches[#hatches + 1] = {
                    station = r.station, level = r.hatchLevel,
                    capacity = r.hatchCapacity, plasma = wantedPlasma(r),
                    switching = switching and switching.state or nil,
                }
            end
        end
        local touched, moved = control.topUp(hatches, scfg, scfg.hatchRefill)
        if touched > 0 then
            log(string.format("topped up %d hatch(es), +%d L", touched, moved))
        end
    end
    doneHatch()

    -- What to stock, and what to ask for.
    local demandFleet = {}
    for _, r in ipairs(rows) do
        demandFleet[#demandFleet + 1] = {
            material = r.material, hasFluid = r.hasFluid, plasma = wantedPlasma(r),
        }
    end
    -- No fleet-wide default: every entry already carries the plasma its own module
    -- is on, and one that carries none is a module nothing should be stocked for.
    local kitTargets, plasmaTargets, from =
        control.demand(demandFleet, scfg, ccfg, nil)

    -- Kits go one per meteor and meteors take tens of seconds, so re-reading the
    -- whole net every cycle only buys staleness nobody can see.
    if full and not stockFresh and net and #catalog > 0 then
        local doneStock = profile.span("read local net stock")
        stock = supply.stock(catalog, net)
        stockFresh = true
        doneStock()
    end

    -- Planning only ever happens against a FRESH reading. The plan compares the
    -- target with what is in the net and nothing else, so running it on a stale
    -- one would see a shortfall that has already been filled and order it again --
    -- which is the very thing being fixed.
    local work, notes = {}, {}
    local donePlan = profile.span("plan and request")
    if stockFresh and itf and #catalog > 0 then
        local planCfg = {
            target = kitTargets, plasma = plasmaTargets,
            lowWater = scfg.lowWater, maxCrafts = scfg.maxCrafts,
        }
        work, notes = supply.plan(catalog, stock, planCfg, satisfied)
        if not paused then
            local issued, blocked, errs = control.issue(itf, work, jobs, computer.uptime())
            for _, j in ipairs(issued) do
                log(string.format("requested %s x%d", j.key, j.crafts))
            end
            for _, e in ipairs(errs) do log("request failed: " .. e) end
            if blocked > 0 and #issued > 0 then
                log(string.format("(%d more waiting on a free job slot)", blocked))
            end
        end
    end
    donePlan()
    for _, n in ipairs(notes) do log(n) end

    -- ---- assemble the view ----
    local doneView = profile.span("assemble the view")
    local crafting = {}
    for _, j in ipairs(jobs:list()) do crafting[j.key] = (crafting[j.key] or 0) + j.crafts end

    local patternFor = {}
    for _, e in ipairs(catalog) do
        if e.kind == "plasma" then patternFor[e.plasma.name] = true end
    end

    local kitView = {}
    for _, material in ipairs(MATERIALS) do
        local target = kitTargets[material] or 0
        local have, pattern = 0, false
        for _, e in ipairs(catalog) do
            if e.kind == "kit" and e.material == material then
                have, pattern = supply.kitsInStock(e, stock.items), true
                break
            end
        end
        if target > 0 or have > 0 then
            kitView[#kitView + 1] = {
                name = material, have = have, target = target,
                settling = jobs:isCooling(material, computer.uptime()) or nil,
                fill = target > 0 and math.min(1, have / target) or 1,
                crafts = crafting[material], from = from[material],
                -- supply.plan only ever walks the catalog, so a material with no
                -- pattern is not short -- it is unreachable, and would otherwise
                -- sit at 0% with nothing visibly wrong.
                missing = (not pattern) and itf ~= nil or nil,
            }
        end
    end

    local plasmaView = {}
    for _, p in ipairs(plasmas.list) do
        local target = plasmaTargets[p.name] or 0
        local have = stock.fluids[p.name] or 0
        plasmaView[#plasmaView + 1] = {
            tier = p.tier, name = p.name, plasma = p,
            have = have, target = target,
            settling = jobs:isCooling(p.name, computer.uptime()) or nil,
            fill = target > 0 and math.min(1, have / target) or (have > 0 and 1 or 0),
            crafts = crafting[p.name], from = from[p.name],
            missing = (not patternFor[p.name]) and itf ~= nil or nil,
            active = activePlasma ~= nil and p.tier == activePlasma.tier,
        }
    end

    local mining = 0
    for _, r in ipairs(rows) do if r.state == "MINING" then mining = mining + 1 end end

    view = {
        miners = rows, kits = kitView, plasmas = plasmaView,
        totals = {
            miners = #rows, mining = mining,
            jobsKit = jobs:count("kit"), jobsPlasma = jobs:count("plasma"),
            limitKit = jobLimits.kit, limitPlasma = jobLimits.plasma,
        },
    }
    doneView()
    endCycle()
end

-- ---- the detail screen -------------------------------------------------------

-- Seconds as "41.2s" / "3m20s", for a mining cycle.
local function secs(t)
    if not t or t <= 0 then return "-" end
    if t < 60 then return string.format("%.1fs", t) end
    return string.format("%dm%02ds", math.floor(t / 60), math.floor(t % 60))
end

-- A magnitude: EU/t, computation, litres. Whole numbers below a thousand.
local function si(n)
    n = n or 0
    if n < 1e3 then return string.format("%.0f", n) end
    if n < 1e6 then return string.format("%.2fk", n / 1e3) end
    if n < 1e9 then return string.format("%.2fM", n / 1e6) end
    return string.format("%.2fG", n / 1e9)
end

-- What the module would be doing at `cur`, whether or not that is what it is set
-- to: while a field is being edited the pending value is substituted, so the
-- pool and the ore table show the effect before it is committed. That is the
-- whole reason for editing here rather than at the machine.
local function buildDetail(rows)
    local row = rows[nav.module]
    if not row then return nil end

    local cur = currentOf(row)
    if nav.edit then cur[nav.edit.field] = nav.edit.value end

    local d = {
        miner = row, view = nav.view, field = nav.field,
        edit = nav.edit and nav.edit.field or nil,
        pool = {}, yield = {},
    }

    local fields = {}
    for i, f in ipairs(control.FIELDS) do
        local live, note = currentOf(row)[f.key], nil
        local shown, pending

        if f.key == "drone" then
            local dr = live and drones.get(live)
            shown = dr and ("MK-" .. dr.roman) or nil
            note = dr and (dr.material .. " kits") or "no drone in the input bus"
            if not row.hasItems then note = "no station -- cannot load a drone" end
            local pd = nav.edit and drones.get(nav.edit.value)
            pending = pd and ("MK-" .. pd.roman .. "  " .. pd.material) or nil
        elseif f.key == "distance" then
            shown = live and tostring(live) or nil
            note = "1 .. " .. control.MAX_DISTANCE
            pending = nav.edit and tostring(nav.edit.value) or nil
        elseif f.key == "overdrive" then
            shown = live and string.format("%.2f", live) or nil
            note = "faster, but a smaller size bonus"
            pending = nav.edit and string.format("%.2f", nav.edit.value) or nil
        else
            local pl = row.plasma
            shown = pl and pl.name or nil
            if not row.hasFluid then
                note = "no plasma feed configured"
            elseif pl then
                note = string.format("%s / %s L in the hatch",
                    si(row.hatchLevel or 0), si(row.hatchTarget or 0))
            else
                note = "the hatch is empty"
            end
            local pp = nav.edit and plasmas.byTier[nav.edit.value]
            pending = pp and pp.name or nil
        end

        -- A change already queued for this field: shown as "live -> target", with
        -- the note saying what it is waiting for. Otherwise a parameter that takes
        -- a minute to land looks like one that was never applied.
        local queued, queuedNote = nil, nil
        local q = queue:find(row.addr, f.key)
        if q then
            if f.key == "drone" then
                local qd = drones.get(q.value)
                queued = qd and ("MK-" .. qd.roman) or tostring(q.value)
            elseif f.key == "overdrive" then
                queued = string.format("%.2f", q.value)
            elseif f.key == "plasma" then
                queued = q.plasma and q.plasma.name or tostring(q.value)
            else
                queued = tostring(q.value)
            end
            queuedNote = q.state .. (q.note and ("  -- " .. q.note) or "")
            if q.error then queuedNote = q.state .. "  -- " .. tostring(q.error) end
        end

        fields[i] = {
            label = f.label, kind = f.kind, value = shown,
            note = queuedNote or note,
            queued = queued,
            pending = (nav.edit and nav.edit.field == f.key) and pending or nil,
        }
    end
    d.fields = fields

    if nav.edit then
        local f = control.FIELDS[nav.field]
        d.editHint = "ENTER applies " .. f.label:lower() .. " to this module"
            .. ((f.key == "drone" or f.key == "distance" or f.key == "overdrive")
                and " (it will be stopped for the write)" or "")
            .. " -- the tables below already show the result."
    end

    -- The estimate needs all four. Say which one is missing rather than showing
    -- an empty table that looks like "this module mines nothing".
    local missing
    if not cur.drone then missing = "a drone in the input bus"
    elseif not cur.distance then missing = "a distance (the module reports none)"
    elseif not cur.plasma then missing = "plasma in the hatch"
    end
    if missing then
        d.error = "Cannot estimate without " .. missing .. "."
        d.summary = string.format("%d/%d parallels", row.parallels or 0, row.parallelCap or 0)
        return d
    end

    local est, err = estimate.run({
        distance = cur.distance, drone = cur.drone, module = row.miner.tier,
        plasma = cur.plasma, overdrive = cur.overdrive or 1,
        parallels = row.parallels, computation = cfg.computation,
    })
    if not est then
        d.error = "Cannot estimate: " .. tostring(err)
        return d
    end

    -- Ordered by share of RUNNING TIME, not by chance. estimate.run hands the pool
    -- over most-likely-first, which is its documented contract and no use here: the
    -- meteor at the top of this table should be the one the module actually spends
    -- its life on, and those are frequently not the same meteor.
    local runnable = {}
    for _, e in ipairs(est.pool) do runnable[#runnable + 1] = e end
    table.sort(runnable, function(a, b)
        if a.timeShare ~= b.timeShare then return a.timeShare > b.timeShare end
        return a.name < b.name
    end)

    for _, e in ipairs(runnable) do
        local sz = e.meteor and e.meteor.size
        d.pool[#d.pool + 1] = {
            name = e.name, chance = e.chance, parallels = e.parallels,
            share = e.timeShare,
            size = sz and (sz[1] .. "-" .. sz[2]) or "-",
            time = secs(e.time), eut = si(e.eut), computation = si(e.computation),
            runtime = string.format("%.1f%%", (e.timeShare or 0) * 100),
            note = e.limit and ("capped by " .. e.limit) or nil,
        }
    end
    -- Meteors in range that the module cannot power or compute are shown too,
    -- marked: "why is that ore not coming out" is exactly this list.
    --
    -- Their chance is their share of the RAW roll, not of the runnable pool --
    -- the pool percentages above are renormalised over what can actually run, so
    -- a blocked meteor has no share of it. Showing 0% would read as "this hardly
    -- ever comes up" when it means "this comes up and is thrown away".
    local rawWeight = 0
    for _, e in ipairs(est.pool) do rawWeight = rawWeight + (e.weight or 0) end
    for _, e in ipairs(est.blocked) do rawWeight = rawWeight + (e.weight or 0) end

    for _, e in ipairs(est.blocked) do
        local sz = e.meteor and e.meteor.size
        d.pool[#d.pool + 1] = {
            name = e.name, parallels = 0, blocked = true,
            chance = rawWeight > 0 and (e.weight or 0) / rawWeight or 0,
            size = sz and (sz[1] .. "-" .. sz[2]) or "-",
            -- Never runs, so it takes none of the running time.
            time = "-", runtime = "-",
            eut = si(e.needs and e.needs.eut or 0),
            computation = si(e.needs and e.needs.computation or 0),
            note = "no " .. tostring(e.limit or "capacity"),
        }
    end

    for _, y in ipairs(est.yield) do
        d.yield[#d.yield + 1] = {
            name = y.mat or y.oredict, share = y.share,
            itemsPerSecond = y.itemsPerSecond, stacksPerSecond = y.stacksPerSecond,
        }
    end

    d.summary = string.format("%d/%d parallels   cycle %s   %s EU/t avg   %s comp",
        row.parallels or 0, row.parallelCap or 0, secs(est.cycle),
        si(est.cost.eut), si(est.cost.computation))
    -- Rates keep their decimals: si() would round 12.4 items/s to "12".
    d.rates = string.format("%.2f items/s   %.3f stacks/s   kits %.3f/s   plasma %.1f L/s%s",
        est.itemsPerSecond, est.stacksPerSecond, est.cost.kit.perSecond,
        est.cost.plasma.perSecond,
        est.blockedChance > 0
            and string.format("   %.0f%% of rolls unpowered", est.blockedChance * 100) or "")
    return d
end

-- ---- what can actually be run ------------------------------------------------
--
-- The advisor will happily recommend a configuration nothing can keep supplied:
-- kits of a material with no pattern, a plasma with no pattern, a drone tier
-- nobody owns. Those are worse than no recommendation, so what is available is
-- worked out here and the search is narrowed to it.
--
-- Derived from the pattern catalog plus the drones the local net holds, so it costs
-- nothing beyond the one drone query folded into the stock read.

local function availability()
    local kits, plasmaOf, dronePattern = {}, {}, {}
    for _, e in ipairs(catalog) do
        if e.kind == "kit" then kits[e.material] = true
        elseif e.kind == "plasma" then plasmaOf[e.plasma.tier] = true
        elseif e.kind == "drone" then dronePattern[e.drone.tier] = true end
    end
    return { kits = kits, plasma = plasmaOf, dronePattern = dronePattern,
             droneStock = droneStock }
end

-- Why a drone tier cannot be run, or nil if it can. A tier needs the drone itself
-- -- in the local net, or fetchable through a pattern -- and a kit pattern for the
-- material its drill tips and rods are made of.
local function droneTrouble(avail, tier)
    local d = drones.get(tier)
    if not d then return "no such drone" end
    if not (avail.droneStock[tier] or avail.dronePattern[tier]) then
        return "no MK-" .. d.roman
    end
    if not avail.kits[d.material] then return "no " .. d.material .. " kits" end
    return nil
end

local function plasmaTrouble(avail, tier)
    if avail.plasma[tier] then return nil end
    local p = plasmas.byTier[tier]
    return "no " .. ((p and p.name) or ("plasma " .. tostring(tier)))
end

-- The tiers worth searching: everything the fleet can be supplied with.
local function obtainable(avail)
    local ds, ps = {}, {}
    for tier = drones.MIN_TIER, drones.MAX_TIER do
        if not droneTrouble(avail, tier) then ds[#ds + 1] = tier end
    end
    for _, p in ipairs(plasmas.list) do
        if not plasmaTrouble(avail, p.tier) then ps[#ps + 1] = p.tier end
    end
    return ds, ps
end

-- ---- the fleet breakdowns ---------------------------------------------------
--
-- The same two questions a module's detail screen answers, asked of the whole
-- fleet. Both are plain sums over the modules, so nothing here is an estimate of
-- an estimate:
--
--   meteors mined per second      chance * parallels / cycle, added up
--   ore items per second          the per-module yields, added up
--   share of running time         each module's own share added up and divided by
--                                 the number of modules counted, which makes it a
--                                 fraction of the fleet's capacity and keeps the
--                                 column adding to 100%
--
-- Cached per CYCLE. It costs one estimate.run per module -- a millisecond here,
-- and OpenComputers is far slower than here -- so it is computed when one of these
-- screens asks for it and not again until the next cycle.
local fleetSums, fleetSumsAt = nil, -1

local function fleetAggregate(rows)
    if fleetSumsAt == cycle and fleetSums then return fleetSums end

    local byMeteor, byOre = {}, {}
    local counted = 0

    for _, r in ipairs(rows) do
        local cur = currentOf(r)
        if cur.drone and cur.distance and cur.plasma then
            local est = estimate.run{
                distance = cur.distance, drone = cur.drone, module = r.miner.tier,
                plasma = cur.plasma, overdrive = cur.overdrive or 1,
                parallels = r.parallels, computation = cfg.computation,
            }
            if est and est.cycle > 0 then
                counted = counted + 1
                for _, e in ipairs(est.pool) do
                    local m = byMeteor[e.name]
                    if not m then
                        m = { name = e.name, share = 0, modules = 0, timeSum = 0,
                              meteors = 0, eut = 0, ore = {} }
                        byMeteor[e.name] = m
                    end
                    m.share = m.share + e.timeShare
                    m.modules = m.modules + 1
                    -- Averages weighted by the time each module spends on it, so a
                    -- module that barely rolls this meteor barely moves the figure.
                    m.timeSum = m.timeSum + e.timeShare * e.time
                    m.eut = m.eut + e.timeShare * e.eut
                    m.meteors = m.meteors + e.chance * (e.parallels or 0) / est.cycle
                    for _, y in ipairs(e.yield or {}) do
                        local k = y.mat or y.oredict
                        if k then m.ore[k] = (m.ore[k] or 0) + (y.stacks or 0) end
                    end
                end
                for _, y in ipairs(est.yield) do
                    local k = y.mat or y.oredict
                    if k then
                        local ore = byOre[k]
                        if not ore then
                            ore = { name = k, items = 0, stacks = 0, modules = 0 }
                            byOre[k] = ore
                        end
                        ore.items = ore.items + y.itemsPerSecond
                        ore.stacks = ore.stacks + y.stacksPerSecond
                        ore.modules = ore.modules + 1
                    end
                end
            end
        end
    end

    local meteors, ore = {}, {}
    local totalItems = 0
    for _, m in pairs(byMeteor) do
        m.avgTime = (m.share > 0) and (m.timeSum / m.share) or 0
        m.avgEut = (m.share > 0) and (m.eut / m.share) or 0
        -- A share of the FLEET, not of one module: each module contributed a
        -- fraction of its own clock, and there are `counted` clocks.
        m.share = (counted > 0) and (m.share / counted) or 0
        -- The ore this meteor is mostly there for, which is what makes a row worth
        -- caring about at all.
        local best, bestAt = nil, 0
        for k, v in pairs(m.ore) do
            if v > bestAt then best, bestAt = k, v end
        end
        m.top = best
        meteors[#meteors + 1] = m
    end
    for _, o in pairs(byOre) do
        totalItems = totalItems + o.items
        ore[#ore + 1] = o
    end

    table.sort(meteors, function(a, b)
        if a.share ~= b.share then return a.share > b.share end
        return a.name < b.name
    end)
    table.sort(ore, function(a, b)
        if a.items ~= b.items then return a.items > b.items end
        return a.name < b.name
    end)

    fleetSums = { meteors = meteors, ore = ore, modules = counted,
                  totalItems = totalItems }
    fleetSumsAt = cycle
    return fleetSums
end

-- The fleet breakdowns as the dashboard renders them.
local function buildFleet(rows)
    local agg = fleetAggregate(rows)
    local f = {
        modules = agg.modules, meteors = {}, ore = {},
        totalItems = string.format("%.2f", agg.totalItems),
    }
    if agg.modules == 0 then
        f.empty = "No module has a drone, a distance and plasma all at once, so "
            .. "there is nothing to add up yet."
        return f
    end

    for _, m in ipairs(agg.meteors) do
        f.meteors[#f.meteors + 1] = {
            name = m.name, share = m.share,
            runtime = string.format("%.1f%%", m.share * 100),
            modules = string.format("%d/%d", m.modules, agg.modules),
            time = secs(m.avgTime),
            meteors = string.format("%.3f", m.meteors),
            eut = si(m.avgEut),
            ore = m.top or "",
        }
    end
    for _, o in ipairs(agg.ore) do
        f.ore[#f.ore + 1] = {
            name = o.name,
            share = (agg.totalItems > 0) and (o.items / agg.totalItems) or 0,
            modules = string.format("%d/%d", o.modules, agg.modules),
            items = string.format("%.2f", o.items),
            stacks = string.format("%.3f", o.stacks),
            hour = si(o.items * 3600),
        }
    end
    return f
end

-- ---- the advisor -------------------------------------------------------------

-- What the targeter is told about what things cost and what can be supplied.
local function searchOpts(row, pins, showAll)
    -- Unless asked to show everything, the search is narrowed to what the fleet can
    -- be supplied with -- BEFORE ranking, not after. Filtering the results instead
    -- would let unrunnable configurations fill the result limit and crowd out the
    -- ones that can actually be run.
    --
    -- A pin always wins: asking specifically for a drone means wanting to see it
    -- even when nothing can supply it, and the row says so.
    local onlyDrones, onlyPlasmas = pins.drone, pins.plasma
    if not showAll then
        local ds, ps = obtainable(availability())
        -- An empty list would mean "nothing at all", which target.search reads as
        -- no restriction. Nothing obtainable is worth saying rather than silently
        -- searching everything, so it is left unfiltered and every row gets
        -- labelled instead.
        if not onlyDrones and #ds > 0 then onlyDrones = ds end
        if not onlyPlasmas and #ps > 0 then onlyPlasmas = ps end
    end
    return {
        cost = { ingot = cfg.kitCost, plasma = cfg.plasmaCost, eu = cfg.euCost },
        budget = cfg.budget,
        computation = cfg.computation,
        -- The module tier is hardware, not a choice: only this module's own tier
        -- is searched, so a recommendation is always one it can actually run.
        modules = { row.miner.tier },
        drones = onlyDrones,
        plasmas = onlyPlasmas,
        distance = pins.distance,
        -- A pinned overdrive goes in as the mode. Left open, the targeter throttles
        -- to the demanded rate, and with no rate demanded that is its fast vertex.
        mode = pins.overdrive,
        limit = 12,
        -- OpenComputers kills a thread that does not yield for long enough, and a
        -- search is thousands of evaluations. Yielding costs nothing here.
        onProgress = function() os.sleep(0) end,
    }
end

-- Runs the search for the module's advisor and stores what came back on `adv`.
local function runAdvise(row, adv)
    adv.result, adv.error = nil, nil
    if not adv.want then
        adv.error = "Choose a material first."
        return
    end
    local ok, res, err = pcall(targeter.search, { [adv.want] = 1 },
        searchOpts(row, adv.pins, adv.showAll))
    if not ok then adv.error = "search failed: " .. tostring(res); return end
    if not res then adv.error = tostring(err); return end
    adv.result = res
end

-- The advisor as the dashboard renders it.
local function buildAdvise(rows)
    local row = rows[nav.module]
    local adv = nav.advise
    if not row or not adv then return nil end

    local cur = currentOf(row)
    local a = {
        miner = row, cursor = adv.cursor, settingsCount = control.ADVISE_SETTINGS,
        edit = adv.edit and adv.edit.field or nil,
        error = adv.error, results = {}, notes = {},
        rateLabel = adv.want and (adv.want .. "/s") or "WANTED/s",
        applied = adv.applied,
    }

    -- Straight from the queue rather than from row.pending, which is only filled
    -- in when a cycle assembles the view -- and the interesting moment is the
    -- instant after applying, before any cycle has run.
    local waiting = queue:pending(row.addr)
    if #waiting > 0 then
        local parts = {}
        for _, e in ipairs(waiting) do parts[#parts + 1] = pendingLabel(e) end
        a.pending = table.concat(parts, ", ")
        a.pendingNote = waiting[1].note
    end

    -- The material, then one row per pinnable parameter.
    local settings = {
        {
            label = "Want", value = adv.want,
            note = string.format("%d materials a meteor can yield",
                #targeter.materials()),
            pending = adv.want,
        },
    }
    for _, f in ipairs(control.FIELDS) do
        local pin = adv.pins[f.key]
        local shown, pending, note

        local function nameOf(v)
            if v == nil then return nil end
            if f.key == "drone" then
                local d = drones.get(v)
                return d and ("MK-" .. d.roman) or tostring(v)
            elseif f.key == "plasma" then
                local p = plasmas.byTier[v]
                return p and p.name or tostring(v)
            elseif f.key == "overdrive" then
                return string.format("%.2f", v)
            end
            return tostring(v)
        end

        if pin ~= nil then
            shown = nameOf(pin) .. "  (pinned)"
            note = "X releases it"
        else
            local now = nameOf(cur[f.key])
            note = now and ("ENTER pins; " .. now .. " now") or "ENTER pins a value"
        end
        if adv.edit and adv.edit.field == f.key then pending = nameOf(adv.edit.value) end

        settings[#settings + 1] = {
            label = f.label, value = shown, note = note,
            pinned = pin ~= nil, pending = pending, kind = f.kind,
        }
    end
    -- The last row: what to do with configurations nothing can supply.
    local avail = availability()
    local ds, ps = obtainable(avail)
    settings[#settings + 1] = {
        label = "Unavailable",
        value = adv.showAll and "shown" or "hidden",
        pinned = adv.showAll,
        note = string.format("ENTER toggles; %d of %d drones and %d of %d plasmas "
            .. "can be supplied", #ds, drones.MAX_TIER, #ps, #plasmas.list),
    }
    a.settings = settings

    local res = adv.result
    if res then
        a.summary = string.format("%d configuration(s) scanned, %d worth having",
            res.scanned, #res.candidates)
        for _, c in ipairs(res.candidates) do
            local d = drones.get(c.drone)
            -- Why this one cannot be run, if it cannot. Only ever non-empty when
            -- unavailable configurations are being shown, or when a pin forced one
            -- into the list.
            local why = {}
            local dt = droneTrouble(avail, c.drone)
            if dt then why[#why + 1] = dt end
            local pt = plasmaTrouble(avail, c.plasma)
            if pt then why[#why + 1] = pt end

            a.results[#a.results + 1] = {
                bad = (#why > 0) or nil,
                why = (#why > 0) and table.concat(why, ", ") or nil,
                candidate = c,
                score = string.format("%.4g", c.score),
                drone = d and ("MK-" .. d.roman) or tostring(c.drone),
                distance = (c.distance[1] == c.distance[2]) and tostring(c.distance[1])
                    or (c.distance[1] .. "-" .. c.distance[2]),
                -- The suffix is on every one of them and the header says PLASMA,
                -- so it is eight columns of nothing.
                plasma = (c.plasmaName:gsub(" Plasma$", "")),
                overdrive = string.format("%.2f", c.overdrive),
                rate = string.format("%.2f", c.rates[adv.want] or 0),
                purity = string.format("%.0f%%", (c.purity or 0) * 100),
                eut = si(c.cost.euPerSecond / estimate.TPS),
                kits = string.format("%.3f", c.cost.kits),
                -- Litres a second, the same question KITS/s answers: can the line
                -- that makes this actually keep up with the module burning it.
                plasmaRate = string.format("%.1f", c.cost.plasmaPerSecond),
            }
        end
        if #a.results == 0 and #res.candidates > 0 then
            a.empty = "Everything found needs something the fleet cannot supply."
        end
        if #res.candidates == 0 then
            -- Say WHY, because an empty table with pins set looks like a bug. The
            -- usual answer is that the pins exclude everything that yields it.
            a.empty = "No configuration of this module yields " .. tostring(adv.want)
                .. " under these pins"
                .. (adv.showAll and "." or
                    " that the fleet can supply -- the Unavailable row shows the rest.")
            for _, note in ipairs(res.skipped) do
                a.notes[#a.notes + 1] = note
            end
            if #res.infeasible > 0 then
                a.notes[#a.notes + 1] = string.format(
                    "%d were possible but over budget -- see cfg.budget.",
                    #res.infeasible)
            end
        end
    end

    if adv.picking then
        a.picking = { list = targeter.materials(), cursor = adv.picking.cursor }
    end
    return a
end

-- Applies a recommendation: the four parameters, queued like any other change.
-- Returns a sentence describing what happened, which the advisor puts on screen --
-- because everything this does is invisible from there otherwise. The changes go
-- on the queue, the log is hidden unless asked for, and a parameter write waits
-- for the module to finish its operation, so without a word here pressing ENTER
-- looks exactly like pressing nothing.
local function applyAdvice(row, c)
    if not c then
        return "nothing selected to apply"
    end
    local want = {
        drone = c.drone,
        -- The pool is identical across the whole interval the candidate reports,
        -- so the near end is as good as any and the module travels less.
        distance = c.distance[1],
        overdrive = math.floor(c.overdrive * 100 + 0.5) / 100,
        plasma = c.plasma,
    }
    local cur = currentOf(row)
    local changed = {}
    for _, f in ipairs(control.FIELDS) do
        if want[f.key] ~= nil and want[f.key] ~= cur[f.key] then
            commitEdit(row, f.key, want[f.key])
            changed[#changed + 1] = f.label:lower()
        end
    end
    if #changed == 0 then
        log(row.addr .. ": already set to the recommendation")
        return "this module is already set to that"
    end
    log(string.format("%s: %d setting(s) queued from the advisor", row.addr, #changed))
    return string.format("queued %s -- the module is stopped for the write, so it "
        .. "may take an operation to land", table.concat(changed, ", "))
end

-- ---- rendering ---------------------------------------------------------------

local tick = 0

local function render()
    if not ui.active then return end
    tick = tick + 1
    ui.render({
        mode = "MANUAL", dryRun = cfg.dryRun, paused = paused, showLog = showLog,
        screen = nav.screen, moduleCursor = nav.module, clipboard = nav.clipboard,
        profile = (nav.screen == "profile") and profile.snapshot() or nil,
        advise = (nav.screen == "advise") and buildAdvise(view.miners) or nil,
        scroll = nav.scroll,
        fleet = (nav.screen == "fleetMeteors" or nav.screen == "fleetOre")
            and buildFleet(view.miners) or nil,
        detail = (nav.screen == "detail") and buildDetail(view.miners) or nil,
        focus = nav.focus, cursor = nav.cursor,
        confirm = nav.confirm and view.plasmas[nav.confirm]
            and view.plasmas[nav.confirm].name or nil,
        switching = pendingPlasma and pendingPlasma.name or nil,
        cycle = cycle, tick = tick, updated = os.date("%H:%M:%S"),
        miners = view.miners, kits = view.kits, plasmas = view.plasmas,
        totals = view.totals, supplyErr = supplyErr, messages = messages,
    })
end

-- Console summary for a headless run, so --no-ui is not silent.
local function printCycle()
    log(string.format("cycle #%d -- %d/%d mining, plasma %s", cycle,
        view.totals.mining, view.totals.miners,
        activePlasma and activePlasma.name or "(none)"))
    for _, k in ipairs(view.kits) do
        if k.fill < 1 then
            log(string.format("  %-20s %d / %d kits%s", k.name, k.have, k.target,
                k.crafts and (" (crafting x" .. k.crafts .. ")") or ""))
        end
    end
    for _, p in ipairs(view.plasmas) do
        if p.target > 0 and p.fill < 1 then
            log(string.format("  %-20s %d / %d L%s", p.name, p.have, p.target,
                p.crafts and (" (crafting x" .. p.crafts .. ")") or ""))
        end
    end
end

-- What a copied config is, in a few words: enough to see at a glance which
-- module the clipboard came off, without reading the address.
local function clipLabel(c)
    local parts = {}
    if c.drone then
        local d = drones.get(c.drone)
        parts[#parts + 1] = d and ("MK-" .. d.roman) or ("drone " .. c.drone)
    end
    if c.distance then parts[#parts + 1] = "d" .. tostring(c.distance) end
    if c.overdrive then parts[#parts + 1] = string.format("OD%.2f", c.overdrive) end
    if c.plasma then
        local p = plasmas.byTier[c.plasma]
        if p then parts[#parts + 1] = (p.name:gsub(" Plasma$", "")) end
    end
    return (c.addr or "") .. "  " .. table.concat(parts, " ")
end

-- ---- keys --------------------------------------------------------------------
--
-- The state machine lives in control.lua so it can be tested; this is only the
-- part that needs the fleet -- starting a switch, pausing, quitting.

local quit = false

-- Written next to the program, because the log panel shows six lines and this is
-- a table worth reading whole.
local PROFILE_FILE = "mining-profile.txt"

local function handleAdviseKey(char, code)
    local row = view.miners[nav.module]
    local adv = nav.advise
    if not row or not adv then nav.screen = "dashboard"; return true end

    local action, changed = control.adviseKey(adv, {
        materials = targeter.materials(),
        cur = currentOf(row),
        plasmas = #plasmas.list,
        results = adv.result and #adv.result.candidates or 0,
    }, char, code)

    if action == "advise-filter" then
        -- Narrowing happens inside the search, so this does need re-running -- but
        -- say so plainly rather than pretending the pins changed.
        adv.applied = nil
        runAdvise(row, adv)
        local rows = control.ADVISE_SETTINGS
            + (adv.result and #adv.result.candidates or 0)
        if adv.cursor > rows then adv.cursor = rows end
    elseif action == "advise-changed" then
        adv.applied = nil
        runAdvise(row, adv)
        -- A shorter list can leave the cursor past the end of it.
        local rows = control.ADVISE_SETTINGS
            + (adv.result and #adv.result.candidates or 0)
        if adv.cursor > rows then adv.cursor = rows end
    elseif action == "advise-apply" then
        local i = adv.cursor - control.ADVISE_SETTINGS
        local c = adv.result and adv.result.candidates[i]
        adv.applied = applyAdvice(row, c)
        view.miners = readFleet(false)
    elseif action == "close" then
        nav.screen = "detail"
    elseif action == "log" then
        showLog = not showLog
    end
    return changed
end

-- How many rows the table on the current screen has, so control.key can clamp the
-- scroll offset. ui.tableRows says how many of them fit, as of the last render.
local function tableRowCount()
    if nav.screen == "fleetMeteors" or nav.screen == "fleetOre" then
        local agg = fleetAggregate(view.miners)
        return (nav.screen == "fleetOre") and #agg.ore or #agg.meteors
    end
    if nav.screen == "detail" then
        local d = buildDetail(view.miners)
        if not d then return 0 end
        return (nav.view == "ore") and #d.yield or #d.pool
    end
    return 0
end

local function handleKey(char, code)
    if nav.screen == "advise" then return handleAdviseKey(char, code) end
    local wasFocused = nav.focus
    local action, changed = control.key(nav, {
        modules = #(view.miners or {}),
        plasmas = #(view.plasmas or {}),
        profiling = profile.enabled,
        rows = tableRowCount(),
        page = ui.tableRows,
        cur = (nav.screen == "detail") and view.miners[nav.module]
            and currentOf(view.miners[nav.module]) or nil,
    }, char, code)

    -- Opening the plasma list lands on the plasma in use, so the common case --
    -- look, then escape -- needs no navigation at all.
    if nav.focus == "plasma" and not wasFocused then
        for i, p in ipairs(view.plasmas or {}) do
            if p.active then nav.cursor = i end
        end
    end

    if action == "advise" then
        local row = view.miners[nav.module]
        if row then
            -- Opened on the material the module's own drone is made of when that
            -- is a thing meteors drop, since "more of what I am already mining" is
            -- the usual question. Otherwise on whatever it last looked at.
            local want = (nav.advise and nav.advise.want) or nil
            if not want and row.material then
                for _, m in ipairs(targeter.materials()) do
                    if m == row.material then want = m end
                end
            end
            nav.advise = control.newAdvise(want)
            nav.screen = "advise"
            if want then runAdvise(row, nav.advise) end
        end
    elseif action == "copy" then
        local row = view.miners[nav.module]
        if row then
            -- The four drivable parameters, which is what a module's config IS --
            -- the same set the detail screen edits.
            nav.clipboard = currentOf(row)
            nav.clipboard.addr = row.addr
            nav.clipboard.label = clipLabel(nav.clipboard)
            log("copied " .. nav.clipboard.label .. "  -- V to paste, Q when done")
        end
    elseif action == "paste" then
        local row = view.miners[nav.module]
        if row then
            pasteInto(row, nav.clipboard)
            -- Otherwise the pending column stays blank until the next cycle, and a
            -- paste looks like it did nothing.
            view.miners = readFleet(false)
        end
    elseif action == "open" then
        nav.screen, nav.field, nav.edit = "detail", 1, nil
    elseif action == "close" then
        nav.screen, nav.edit = "dashboard", nil
    elseif action == "commit" then
        local edit = nav.edit
        nav.edit = nil
        local row = view.miners[nav.module]
        if row and edit then commitEdit(row, edit.field, edit.value) end
        -- commitEdit marked the module due, so this picks its slow half up without
        -- re-reading every other module's.
        view.miners = readFleet(false)
    elseif action == "apply-plasma" then
        local pick = view.plasmas[nav.confirm]
        nav.confirm, nav.focus = nil, nil
        if pick then
            pendingPlasma = pick.plasma
            log("switching the fleet to " .. pick.name .. " ...")
        end
    elseif action == "save-profile" then
        local path, err = profile.save(PROFILE_FILE, "mining controller profile")
        log(path and ("profile written to " .. path)
            or ("could not write the profile: " .. tostring(err)))
    elseif action == "reset-profile" then
        profile.reset()
        log("profile reset")
    elseif action == "pause" then
        paused = not paused
        log(paused and "PAUSED -- maintenance frozen; the modules keep running."
            or "RESUMED.")
    elseif action == "log" then
        showLog = not showLog
    elseif action == "quit" then
        quit = true
    end
    return changed
end

-- ---- run ---------------------------------------------------------------------

local uiActive = (not ctx.flags["no-ui"]) and (not ctx.flags.once)
    and (cfg.ui ~= false) and ui.init()

log(string.format("Mining controller (MANUAL) -- %d module(s), %ds cycle%s",
    #fleet, interval, cfg.dryRun and "  [DRY RUN]" or ""))
if profile.enabled then
    log("Profiling on -- press F for the report, S to write it to a file.")
end
if #fleet == 0 then
    log("No mining modules discovered. Are the Adapters connected? (try `probe gt_machine`)")
end
if supplyErr then
    log("Supply unavailable: " .. supplyErr)
    log("  Hatches will still be topped up from what is already staged.")
end
local noStation = 0
for _, m in ipairs(fleet) do if not m.station then noStation = noStation + 1 end end
if noStation > 0 then
    log(string.format("%d module(s) have no station in cfg.stations -- run `setup`.", noStation))
end

local function loop()
    local nextCycle = computer.uptime()
    local nextRefresh = computer.uptime()
    while not quit do
        local t = computer.uptime()
        if t >= nextCycle then
            runCycle()
            -- Scheduled from when this cycle STARTED, so the period is the
            -- interval rather than the interval plus however long a cycle took.
            -- Floored a little ahead of now, so a cycle that overruns cannot
            -- schedule the next in the past and starve the repaint entirely.
            nextCycle = math.max(t + interval, computer.uptime() + 0.25)
            if uiActive then
                render()
                nextRefresh = computer.uptime() + uiRefresh
            else
                printCycle()
            end
            if ctx.flags.once then return end
        elseif uiActive and t >= nextRefresh then
            render()
            nextRefresh = computer.uptime() + uiRefresh
        end

        local wake = uiActive and math.min(nextCycle, nextRefresh) or nextCycle
        local timeout = wake - computer.uptime()
        if timeout > 0 then
            local _, _, char, code = event.pull(timeout, "key_down")
            if char and handleKey(char, code) then
                -- A key that changed something repaints at once rather than
                -- waiting for the next refresh, so the picker feels immediate.
                render()
                if pendingPlasma then nextCycle = computer.uptime() end
            end
        end
    end
end

local ok, err = pcall(loop)
ui.shutdown()

if ctx.flags.profile then
    local path, perr = profile.save(PROFILE_FILE, "mining controller profile")
    if path then
        print("Profile written to " .. path .. ".")
    else
        print("Could not write the profile: " .. tostring(perr))
    end
end

-- Nothing is put back on the way out. The modules are the player's -- they were
-- running before this started and they keep running after, with whatever is in
-- their hatches. `plasma drain` is the command for handing it all back.
if #fleet > 0 then
    print(string.format("Mining controller stopped after %d cycle(s). The modules "
        .. "keep running on what is in their hatches.", cycle))
end
if not ok and not tostring(err):find("interrupt") then error(err, 0) end

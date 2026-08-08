-- Mining controller.
--
-- Keeps a fleet of space-elevator mining modules fed -- plasma into every hatch,
-- kits and plasma into the local net from the main-net supply interface -- and, for
-- the modules you let it, decides what they should be mining.
--
-- Every module is in one of two modes, per module and remembered across runs:
--
--   AUTO (the default)  the controller aims it. Once mining/wants.lua says what ore
--                       you want and how much, it searches for the configurations
--                       that serve that list and shares them out across the AUTO
--                       modules -- and because a want stops paying once it is
--                       covered, they spread over what is still missing instead of
--                       all chasing the same thing. With no want list it changes
--                       nothing, so an un-set-up controller is a harmless one.
--   MANUAL              you own it. Setting anything on a module by hand claims it,
--                       and the controller then leaves its parameters alone for
--                       good -- while still feeding it. A on the dashboard hands it
--                       back.
--
-- The one decision that is fleet-wide either way is WHICH PLASMA, because a hatch
-- holds one fluid and switching it means draining every hatch that disagrees. Press
-- P, choose, confirm.
--
-- Nothing here stops mining: quitting leaves every module running on what is in its
-- hatches, in whatever configuration it was last given.
--
-- Run from the mining folder:  main
-- See `main --help`, config.lua for the knobs and wants.lua for the demand.

local miners = require("lib.hw.miners")
local supply = require("lib.hw.supply")
local control = require("lib.control")
local localnet = require("lib.hw.localnet")
local dbslots = require("lib.hw.db")
local drones = require("lib.gtnh.drones")
local plasmas = require("lib.gtnh.plasmas")
local estimate = require("lib.calc.estimate")
local targeter = require("lib.calc.target")
local wanted = require("lib.calc.wants")
local allocate = require("lib.calc.allocate")
local modes = require("lib.modes")
local profile = require("lib.profile")
local ui = require("lib.ui")
local cli = require("lib.cli")
local cfg = require("config")
local event = require("event")
local computer = require("computer")

-- The want list is a separate file so it can be edited without touching config.lua,
-- and an install that has never had one is a working MANUAL-only controller rather
-- than a crash.
local wantsFile
do
    local ok, loaded = pcall(require, "wants")
    wantsFile = ok and loaded or nil
end

local ctx = cli.start({
    name = "main",
    summary = "Mining controller: aims the fleet at what you want, and keeps it fed.",
    usage = {
        { "main",          "run the controller until stopped" },
        { "main --no-ui",  "run headless, logging to the console" },
        { "main --once",   "run a single maintenance cycle and exit" },
        { "main --manual", "never aim a module; keep the fleet fed and nothing else" },
        { "main --profile","write a timing report to a file on exit" },
    },
    flags = {
        { "--no-ui", "no dashboard; print each cycle instead" },
        { "--once",  "one cycle, then exit (for checking a fresh setup)" },
        { "--manual", "treat every module as MANUAL for this run, whatever their"
            .. " modes say -- the want list is still read and shown" },
        { "--profile", "measure where the time goes; F shows it, and it is written"
            .. " to mining-profile.txt on exit" },
    },
    notes = {
        "Every module is AUTO or MANUAL, and that is remembered between runs. An AUTO "
            .. "module is aimed by the controller at whatever best serves "
            .. "mining/wants.lua -- the file listing the ore you want and how much of "
            .. "it. Setting anything on a module by hand claims it as MANUAL, so the "
            .. "controller stops aiming it (it keeps feeding it); A on the dashboard "
            .. "hands it back. With no want list nothing is ever aimed, and W shows "
            .. "that list against what the fleet is actually producing.",
        "AUTO changes nothing quickly. The main net is read on the slow cadence only, "
            .. "a want that fills stays filled until it drops well below its target, "
            .. "and a module is re-aimed only when the new configuration beats what it "
            .. "is running by a clear margin (cfg.auto.margin) -- because every "
            .. "re-aim costs a mining operation, and a plasma change drains a hatch.",
        "The controller never enables or disables a module, so quitting leaves the "
            .. "fleet mining -- with whatever is already in its hatches.",
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
            .. "drone it runs, and that says which material its kits are made of, "
            .. "while its parallels say how much of it -- both consumables go per "
            .. "meteor, and a module mines one meteor per parallel, so a T2 on 4 of "
            .. "them asks for four times what a single-parallel module does. "
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
local acfg = cfg.auto or {}

local interval = math.max(ccfg.interval or 5, 1)
local uiRefresh = math.max(ccfg.uiRefresh or 1, 0.1)
local jobLimits = ccfg.jobs or control.JOBS

-- Automatic mode off for this run, whatever the modes file says. Not the same as
-- switching every module to MANUAL, which would be written down and would still be
-- off tomorrow: this is "not today".
local manualRun = ctx.flags.manual and true or false

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
-- What the main net's crafting CPUs are already making for us, refreshed on every
-- cycle that plans. Held here rather than inside the cycle so the dashboard can
-- show it on the repaints in between.
local coming = {}
local cpuWarned = false         -- the "cannot see the crafting bank" warning, once
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

-- ---- the demand side ---------------------------------------------------------

-- The want list, validated once. A bad entry is dropped and named rather than
-- guessed at, so `wantProblems` is shown on the WANTS screen and logged at startup.
local wantEntries, wantProblems = wanted.load(wantsFile)

-- Which modules the controller may aim. AUTO unless written down; see lib/modes.lua
-- for why the exceptions are the thing that gets stored.
local moduleModes = modes.load()

-- What the MAIN net holds of each wanted item. nil means NEVER READ, which is a
-- different thing from "holds none" and is treated as such throughout: an unread
-- network must not be able to declare every want critical. One unfiltered scan of a
-- main net is expensive, so it happens on the slow cadence only.
local mainStock, mainStockAt, mainStockInfo = nil, nil, nil

-- Wanted label -> its AE2 item id, learned once and kept for the run. The main net
-- cannot be listed whole -- thousands of item types exceed what an OpenComputers
-- machine may hold, and the call simply returns nothing -- so the reading is by id,
-- and these are what make that possible. See supply.mainStock.
--
-- A label the network has never held is marked `false` there and then left alone,
-- because a misspelled one would otherwise cost a component call every heavy cycle
-- for the rest of the run. Which means something made for the FIRST time would never
-- be noticed either, so the marks are dropped every so often and the labels looked
-- for again. Rarely: nothing that has waited this long to exist is urgent.
local mainIds = {}
local RETRY_LABELS_EVERY = 20        -- heavy cycles, so ~10 minutes at the defaults
local mainIdsRetried = 0

-- The hysteresis latch behind the want list: a want that fills stays filled until it
-- falls back under cfg.auto.refillAt of its target. Carried across cycles, exactly
-- like `satisfied` above does it for kits.
local wantSatisfied = {}

-- What the last evaluation said, kept because it is only recomputed on the slow
-- cadence -- the stock it is derived from is. `wantView` is the same thing formatted
-- for the screen, and `wantMark` is what the ore and meteor tables look rows up in.
local wantRows, wantDemand, wantSummary = {}, nil, { n = #wantEntries }
local wantView = { rows = {}, notes = {}, summary = {} }
local wantMark = {}

-- Every yield key of a want still being ASKED FOR -> the material it serves. What the
-- ore and meteor tables mark, and rebuilt with each evaluation: those tables answer
-- "is the fleet's output going anywhere I need", and a want that is full is not an
-- answer to that. Starts out covering everything, since nothing is satisfied until a
-- reading says so.
local wantKeys = wanted.wantedKeys(wantEntries)

-- The fleet's own ore output, keyed as the estimator keys it, from the last heavy
-- cycle. Feeds both the want rows ("is anything actually mining this?") and the
-- allocation's idea of what a module is worth keeping.
local fleetOreRates = {}

-- What the allocator last did, for the log and the screen, plus the signature of the
-- demand it did it for -- so a heavy cycle whose demand has not moved does not pay
-- for a search that can only come back with the same answer.
local autoNote, autoSignature = nil, nil
local autoDue = true            -- forced after a mode change or a want-list reload

-- ---- whether a module should be RUNNING at all -------------------------------
--
-- The allocator can decide a module is not needed -- every want it could serve is
-- already covered, or the whole list is full -- and until this existed there was
-- nothing to do about it. "Not needed" came back as KEEP, KEEP means "carry on
-- doing exactly what you were", and so a fleet whose wants had all been met went on
-- mining them for ever: kits and plasma spent on ore nobody was waiting for, and
-- nothing on any screen saying why.
--
-- Two tables rather than one, because they answer different questions:
--   autoWanted[addr]   what automatic mode has DECIDED. Survives a cycle in which
--                      no allocation ran (an unchanged demand skips the search), so
--                      the decision does not evaporate between searches.
--   autoRunning[addr]  what has actually been WRITTEN. The write only happens when
--                      the two disagree, so a settled fleet costs no calls at all.
--
-- Cleared for one module whenever a queued parameter change settles: that path
-- stops the machine and puts it back to what it was BEFORE, which is not
-- necessarily what automatic mode wants -- and a module aimed while it happened to
-- be stopped would otherwise stay stopped for good.
--
-- MANUAL modules are never touched by any of this. Turning somebody else's module
-- off is exactly the kind of thing that makes an automatic controller impossible to
-- trust.
local autoWanted, autoRunning = {}, {}

-- Forward declarations. The demand side is built on top of the estimator glue and
-- the searcher options that the detail and advisor screens further down already
-- own -- reimplementing either would be two places to keep in step -- while the
-- cycle that drives it all comes first. Declared here, assigned down there.
local refreshWants, runAuto, fleetAggregate, enforceRunning

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
            -- Whether the controller may aim it. Free -- it is a table lookup, not a
            -- component call -- so it is read every cycle like the parameters.
            auto = (not manualRun) and modes.isAuto(moduleModes, m.address) or false,
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
        -- OFF sits above MINING because a module that has been told to stop is
        -- still active until its operation finishes, and "MINING" for the next
        -- forty seconds would read as the controller having ignored the decision.
        if not st then row.state = "NO STATION"
        -- Not under a dry run: nothing was written, the module is still mining, and
        -- a state column is a report of the hardware rather than of an intention.
        elseif autoWanted[m.address] == false and not cfg.dryRun then row.state = "OFF"
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

-- Remembers that a module is the player's now. Called from every path a HUMAN can
-- change a module by -- an edit, a paste, the advisor -- and from none that the
-- allocator uses, which is the whole distinction between the two modes.
--
-- Written to disk immediately rather than on the way out: the interesting case for
-- remembering this is the run that ends by having the power cut.
local function claimModule(row)
    if not modes.claim(moduleModes, row.miner.address) then return end
    log(row.addr .. ": MANUAL now -- the controller will not aim it (A hands it back)")
    -- Handed back running. A module the controller had stopped for want of anything
    -- to mine would otherwise arrive in the player's hands switched off, with the
    -- only clue a state column reading OFF -- and nothing on the keyboard to undo
    -- it, since taking a module MANUAL is the way to say "I will drive this".
    if autoWanted[row.miner.address] == false then
        row.miner:setEnabled(true)
        log("  (it was stopped for want of anything to mine -- started again)")
    end
    autoWanted[row.miner.address] = nil
    autoRunning[row.miner.address] = nil
    local path, err = modes.save(moduleModes)
    if not path then log("  (could not remember that: " .. tostring(err) .. ")") end
    -- One fewer module to allocate over, so the rest may want re-sharing.
    autoDue = true
end

-- Queues a committed edit. Nothing is written here: a parameter needs the module
-- stopped, and a module mid-operation takes tens of seconds to get there, so the
-- control thread works at it in the background and the dashboard shows it
-- waiting. Which also means the key handler stays instant.
--
-- `byAuto` marks the allocator's own writes, which must NOT claim the module -- a
-- controller that took a module off itself the first time it aimed one would never
-- aim it twice.
local function commitEdit(row, field, value, byAuto)
    if not byAuto then claimModule(row) end
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

    -- What a finished craft actually DELIVERED, against what it was asked for. The
    -- reading above is already fresh, so this costs nothing -- and it is the only
    -- place a job that reports success while pushing a fraction of the goods can be
    -- seen at all. Everything about a fake crafting pattern is inferred: how many
    -- kits one craft is worth comes off its input counts, and how many crafts a
    -- request means depends on its output count. Either can be wrong on a pattern
    -- nobody has checked, and both fail the same silent way.
    local levels = stockFresh and supply.levels(catalog, stock) or nil
    for _, j in ipairs(finishedJobs) do
        if j.state == "done" then
            local now = levels and levels[j.key]
            if now and j.before and j.expected then
                local got = now - j.before
                local unit = (j.kind == "plasma") and " L" or " kits"
                local line = string.format("stocked %s: %d -> %d%s (%+d, expected %+d "
                    .. "from %d craft(s))", j.key, j.before, now, unit, got,
                    j.expected, j.crafts)
                log(line)
                -- Flagged rather than left to be noticed: a delivery this far short of
                -- the promise means the pattern is not what the catalog thinks it is,
                -- and it will go on being short every cycle until someone looks.
                if got < j.expected * 0.9 then
                    log(string.format("  SHORT by %d%s -- check `stock patterns`: one "
                        .. "craft is read as %s%s from its inputs, and %d item(s) of its "
                        .. "output were requested for %d craft(s)",
                        j.expected - got, unit, tostring(j.perCraft), unit,
                        j.items or j.crafts, j.crafts))
                end
            else
                log(string.format("stocked %s (x%d craft(s))", j.key, j.crafts))
            end
        else
            log(string.format("%s restock %s", j.key, j.state))
        end
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
            -- Carrying a parameter change out stops the machine and puts it back to
            -- whatever it was BEFORE the change (control.restoreEnabled). That is
            -- right for a module the player is driving and wrong for one automatic
            -- mode has an opinion about -- in particular a module that was stopped
            -- for want of work and has just been aimed at something would come back
            -- still stopped. Forgetting what was written re-asserts it.
            autoRunning[r.miner.address] = nil
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

    -- What to stock, and what to ask for. The parallels are what the module is SET
    -- to, not what its tier could do: a T3 held at 2 parallels consumes like a T1,
    -- and stocking for the 8 it is not running would hoard for nothing. Falls back
    -- to the tier ceiling only when the parameter could not be read at all.
    local demandFleet = {}
    for _, r in ipairs(rows) do
        demandFleet[#demandFleet + 1] = {
            material = r.material, hasFluid = r.hasFluid, plasma = wantedPlasma(r),
            parallels = r.parallels or r.parallelCap,
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

    -- Planning only ever happens against a FRESH reading. What the plan compares
    -- the target with is what is in the net, so running it on a stale one would see
    -- a shortfall that has already been filled and order it again. The reading
    -- covers goods that have LANDED; the CPU scan just below covers the ones still
    -- being made, and it takes both to stop a duplicate order.
    local work, notes = {}, {}
    local donePlan = profile.span("plan and request")
    if stockFresh and itf and #catalog > 0 then
        -- What the main net is ALREADY making, before deciding to ask it for more.
        -- Without this the controller sees only the local net, and a main net that
        -- is slow to deliver looks exactly like one that never got the order --
        -- so the same shortfall is ordered again every cycle, each order takes
        -- another crafting CPU, and the main net gets slower still. Read here
        -- rather than on the fast cadence because it costs a component call per
        -- BUSY CPU, and because this is the only place the answer is used.
        --
        -- The span's CALL COUNT under --profile understates it: the cpu values
        -- come back inside getCpus' result and never pass through profile.proxy,
        -- so only the getCpus itself is counted. The duration is honest, which is
        -- the number that matters when this shows up as the slow phase.
        local doneCpus = profile.span("read main-net crafting CPUs")
        local cpuInfo
        coming, cpuInfo = supply.inFlight(itf, catalog)
        doneCpus()

        -- Said once, not every cycle. Either way the controller carries on -- a
        -- crafting bank it cannot read is a reason to plan blind, not a reason to
        -- stop feeding the fleet -- so this has to be loud enough to explain the
        -- duplicate orders that follow.
        if not cpuWarned then
            if cpuInfo.error then
                cpuWarned = true
                log("cannot see the main net's crafting jobs: " .. cpuInfo.error)
                log("  restocking plans on the local net alone, so a slow main net")
                log("  may be asked for the same thing more than once")
            elseif cpuInfo.unreadable > 0 and cpuInfo.matched == 0 then
                cpuWarned = true
                log(string.format("%d busy CPU(s) would not say what they are making"
                    .. " -- finalOutput needs a Crafting Monitor in the CPU",
                    cpuInfo.unreadable))
            end
        end

        local planCfg = {
            target = kitTargets, plasma = plasmaTargets,
            lowWater = scfg.lowWater, maxCrafts = scfg.maxCrafts,
        }
        work, notes = supply.plan(catalog, stock, planCfg, satisfied, coming)
        if not paused then
            local issued, blocked, errs = control.issue(itf, work, jobs, computer.uptime())
            for _, j in ipairs(issued) do
                -- In the units that matter: crafts is what AE2 is being asked to run,
                -- but kits (or litres) is what the shortfall was measured in, and the
                -- two only agree if the pattern was read correctly.
                local unit = (j.kind == "plasma") and "L" or "kits"
                log(string.format("requested %s: %d craft(s) = %d %s (%d short of %d)",
                    j.key, j.crafts, j.expected or 0, unit,
                    (j.target or 0) - (j.before or 0), j.target or 0))
                -- Why an order is smaller than the shortfall. Without this the two
                -- numbers on the line above simply do not add up, which reads as an
                -- arithmetic fault rather than as the guard doing its job.
                if (j.coming or 0) > 0 then
                    log(string.format("  %d %s of that is already on a crafting CPU"
                        .. " -- only the difference was ordered",
                        math.floor(j.coming + 0.5), unit))
                end
                if j.capped then
                    log(string.format("  capped at %d of %d craft(s) by "
                        .. "cfg.supply.maxCrafts", j.crafts, j.capped))
                end
            end
            for _, e in ipairs(errs) do log("request failed: " .. e) end
            if blocked > 0 and #issued > 0 then
                log(string.format("(%d more waiting on a free job slot)", blocked))
            end
        end
    end
    donePlan()
    for _, n in ipairs(notes) do log(n) end

    -- ---- what the fleet is FOR, and what to do about it ----
    -- All of it on the heavy cadence: the main-net scan is the most expensive read
    -- the controller makes, the fleet's own output only changes when a module is
    -- reconfigured, and a fleet re-aimed every five seconds would spend its life
    -- stopped for parameter writes.
    if full then
        local doneWants = profile.span("wants and allocation")
        refreshWants(rows)
        if not paused and runAuto(rows) then
            -- Something was queued, so the rows in hand describe the fleet as it was
            -- a moment ago. Re-read the cheap half so PENDING shows up at once
            -- instead of at the next cycle.
            rows = readFleet(false)
        end
        -- Again, unconditionally: runAuto returns early on the cycles where the
        -- demand has not moved -- which is most of them -- and a decision that has
        -- been undone by a parameter write since then still has to be put back.
        -- Costs nothing when nothing has changed, which is the normal case.
        if not paused then enforceRunning(rows) end
        doneWants()
    end

    -- ---- assemble the view ----
    local doneView = profile.span("assemble the view")
    local crafting = {}
    for _, j in ipairs(jobs:list()) do crafting[j.key] = (crafting[j.key] or 0) + j.crafts end

    -- How much of a shortfall is already being made on the main net, in the units
    -- the row is measured in. This is the difference between a row that is stuck at
    -- 12% and one that is at 12% AND being worked on -- which, before the CPUs were
    -- consulted, looked identical and was the reason to keep ordering.
    local function comingFor(key)
        local c = coming[key]
        if not c then return nil end
        if c.unknown then return -1 end          -- being made, amount unknown
        if (c.units or 0) <= 0 then return nil end
        return math.floor(c.units + 0.5)
    end

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
                crafts = crafting[material], coming = comingFor(material),
                from = from[material],
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
            crafts = crafting[p.name], coming = comingFor(p.name),
            from = from[p.name],
            missing = (not patternFor[p.name]) and itf ~= nil or nil,
            active = activePlasma ~= nil and p.tier == activePlasma.tier,
        }
    end

    local mining, auto = 0, 0
    for _, r in ipairs(rows) do
        if r.state == "MINING" then mining = mining + 1 end
        if r.auto then auto = auto + 1 end
    end

    view = {
        miners = rows, kits = kitView, plasmas = plasmaView,
        wants = wantView, wanted = wantMark,
        totals = {
            miners = #rows, mining = mining, auto = auto,
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

-- A long stretch of time, for "how long until this want is full". Hours matter here
-- and seconds do not, which is the opposite of secs() above -- an ETA in seconds is
-- noise, and one in "11h" is the whole message.
local function longSecs(t)
    if not t or t <= 0 or t == math.huge then return nil end
    if t < 90 then return string.format("%ds", math.floor(t)) end
    if t < 5400 then return string.format("%dm", math.floor(t / 60 + 0.5)) end
    if t < 86400 then
        return string.format("%dh%02dm", math.floor(t / 3600), math.floor((t % 3600) / 60))
    end
    if t < 8640000 then return string.format("%dd", math.floor(t / 86400 + 0.5)) end
    return "never"
end

-- ---- marking what the fleet is for -------------------------------------------
--
-- The wants a meteor serves, as a short label, or nil for one that serves none.
-- `keys` is any table whose KEYS are yield keys the way the estimator reports them
-- (the bare material where there is one, else the oredict), which is the shape both
-- the per-module pool and the fleet aggregate already have to hand.
--
-- Truncated to three, because the column is not wide and the point of it is the
-- yes/no: a meteor serving four wants and one serving seven are the same answer.
local function servesLabel(keys)
    local seen, names = {}, {}
    for key in pairs(keys or {}) do
        local mat = wantKeys[key]
        if mat and not seen[mat] then seen[mat] = true; names[#names + 1] = mat end
    end
    if #names == 0 then return nil end
    table.sort(names)
    if #names > 3 then
        names = { names[1], names[2], names[3], "+" .. (#names - 3) }
    end
    return table.concat(names, ", ")
end

-- The yield keys of one meteor, as a set servesLabel can read.
local function yieldKeys(yields)
    local set = {}
    for _, y in ipairs(yields or {}) do
        if y.mat then set[y.mat] = true end
        if y.oredict then set[y.oredict] = true end
    end
    return set
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
            -- Which of the wants this meteor is worth rolling for. The table is
            -- sorted by share of running time, so this column is where "a third of
            -- this module's life goes on something nobody asked for" shows up.
            serves = servesLabel(yieldKeys(e.yield)),
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

function fleetAggregate(rows)
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
            serves = servesLabel(m.ore),
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
        -- is searched, so a recommendation is always one it can actually run. Same
        -- for the parallels it is set to -- every rate reported scales with them, and
        -- a recommendation quoting eight parallels' throughput to a module running
        -- two is a recommendation about a different machine.
        modules = { row.miner.tier },
        parallels = row.parallels,
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

-- Queues a candidate's four parameters onto a module -- only the ones that DIFFER,
-- since writing back a value a module already has would stop it, write what was
-- already there, and start it again for nothing.
--
-- The one path by which any configuration reaches hardware, whether a player chose
-- it in the advisor or the allocator did. `byAuto` is what tells those two apart:
-- it decides whether the module is claimed as MANUAL, and nothing else.
-- Returns the list of field names that were queued.
local function applyCandidate(row, c, byAuto)
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
            commitEdit(row, f.key, want[f.key], byAuto)
            changed[#changed + 1] = f.label:lower()
        end
    end
    return changed
end

-- Applies a recommendation the player chose. Returns a sentence describing what
-- happened, which the advisor puts on screen -- because everything this does is
-- invisible from there otherwise. The changes go on the queue, the log is hidden
-- unless asked for, and a parameter write waits for the module to finish its
-- operation, so without a word here pressing ENTER looks exactly like pressing
-- nothing.
local function applyAdvice(row, c)
    if not c then
        return "nothing selected to apply"
    end
    local changed = applyCandidate(row, c, false)
    if #changed == 0 then
        log(row.addr .. ": already set to the recommendation")
        return "this module is already set to that"
    end
    log(string.format("%s: %d setting(s) queued from the advisor", row.addr, #changed))
    return string.format("queued %s -- the module is stopped for the write, so it "
        .. "may take an operation to land", table.concat(changed, ", "))
end

-- ---- automatic mode ----------------------------------------------------------
--
-- Two steps, both on the heavy cadence, and deliberately separate:
--
--   refreshWants   what is wanted and what is happening about it. Reads the main
--                  net (expensive) and the fleet's own output (an estimate per
--                  module), and turns the two into a demand table and the rows the
--                  WANTS screen shows. Runs whether or not anything is AUTO -- the
--                  screen is worth having in a fully manual fleet.
--   runAuto        what to do about it. Searches per hardware group, shares the
--                  candidates out over the AUTO modules, and queues the ones worth
--                  a stop.
--
-- Nothing here is allowed to be the only path to hardware: it queues changes with
-- exactly the same commitEdit the keyboard uses, and every guard that applies to a
-- player's edit applies to its own.

-- The four parameters of a candidate, in a few words -- for the log, where one line
-- per re-aimed module is the whole record of what the controller decided.
local function candidateLabel(c)
    local d = drones.get(c.drone)
    local p = plasmas.byTier[c.plasma]
    return string.format("%s  d%d  OD%.2f  %s",
        d and ("MK-" .. d.roman) or ("drone " .. tostring(c.drone)),
        c.distance[1], c.overdrive,
        p and (p.name:gsub(" Plasma$", "")) or ("plasma " .. tostring(c.plasma)))
end

-- The want rows, formatted, plus the marking table every ore and meteor table reads.
-- Rebuilt whenever the evaluation is, and never in between: the numbers in it are
-- only as fresh as the main-net read they came from, and the panel title says when
-- that was rather than pretending otherwise.
local function buildWantView()
    local rowsOut, marks = {}, {}
    local askSum, gotSum = 0, 0

    for i, r in ipairs(wantRows) do
        local fill = r.fill and math.min(1, r.fill) or nil
        local pct = fill and string.format("%d%%", math.floor(fill * 100 + 0.5)) or "-"
        local stock = (r.have and si(r.have) or "?") .. " / " .. si(r.want)

        if r.rate > 0 then
            askSum = askSum + r.rate
            gotSum = gotSum + math.min(r.rate, r.produced or 0)
        end

        rowsOut[i] = {
            material = r.material,
            label = (r.label ~= "") and r.label or nil,
            stock = stock,
            fill = fill,
            pct = pct,
            -- The processing factor, and whether anybody said it. Every figure to its
            -- right is scaled by it, so it is shown rather than assumed silently.
            per = "x" .. string.format("%.3g", r.perOre or 1),
            perStated = r.perStated,
            need = (r.rate > 0) and string.format("%.3f", r.rate) or "-",
            made = string.format("%.3f", r.produced or 0),
            making = (r.produced or 0) > 0,
            cover = (r.rate > 0) and r.covered or nil,
            coverPct = (r.rate > 0)
                and string.format("%d%%", math.floor((r.covered or 0) * 100 + 0.5)) or "-",
            eta = longSecs(r.eta),
            state = r.state,
            note = r.note,
        }

        -- Every key the entry absorbs points at the same mark, so an ore table can
        -- ask about "dustPlatinum" and get the Platinum want back. `goal` is what
        -- decides how loudly it is drawn: a met want keeps its figures, quietly, and
        -- an outstanding one is highlighted -- those tables are read to find out where
        -- the fleet's output is going short, not to be reminded what is on the list.
        local e = wantEntries[i]
        if e then
            local mark = { material = r.material, fill = fill, pct = pct, stock = stock,
                           goal = not r.satisfied }
            for key in pairs(e.keys) do marks[key] = mark end
        end
    end

    local notes = {}
    for _, p in ipairs(wantProblems) do notes[#notes + 1] = p end
    if mainStockInfo and mainStockInfo.error then
        notes[#notes + 1] = mainStockInfo.error
    end
    -- The unresolved ones, not merely the empty ones. A label the network holds none
    -- of reads 0 in its own row and needs no note; a label the network has never held
    -- could not even be given an item id, and that is what a misspelling looks like.
    if mainStockInfo and #(mainStockInfo.unresolved or {}) > 0 then
        notes[#notes + 1] = "the main net has never held: "
            .. table.concat(mainStockInfo.unresolved, ", ")
            .. " -- either none has ever been made, or the label is spelled differently"
    end

    local s = wantSummary or {}
    local base
    if (s.n or 0) == 0 then
        base = "mining/wants.lua lists nothing, so no module is being aimed."
    else
        base = string.format("%d of %d want(s) met   --   %d%% average fill",
            (s.n or 0) - (s.demanded or 0), s.n or 0,
            math.floor((s.fill or 0) * 100 + 0.5))
        if (s.critical or 0) > 0 then
            base = base .. string.format("   --   %d CRITICAL", s.critical)
        end
        if askSum > 0 then
            base = base .. string.format("   --   the fleet covers %d%% of what is asked",
                math.floor(gotSum / askSum * 100 + 0.5))
        end
    end

    wantView = {
        rows = rowsOut, notes = notes, read = mainStockAt,
        -- The counts as well as the sentence: the KPI card on the dashboard reads
        -- these, and the sentence is only for the footer of the want screen itself.
        summary = {
            base = base, line = base,
            n = s.n or 0, demanded = s.demanded or 0,
            satisfied = s.satisfied or 0, critical = s.critical or 0,
            fill = s.fill or 0,
        },
    }
    wantMark = marks
end

-- Whatever the allocator last said, kept on the WANTS screen footer next to the ask
-- -- the two questions being "what do I want" and "what is being done about it", and
-- there is no other place the second one is answered.
local function setAutoNote(note)
    autoNote = note
    local s = wantView.summary or {}
    wantView.summary = s
    s.line = note and ((s.base or "") .. "   --   " .. note) or (s.base or "")
end

function refreshWants(rows)
    if #wantEntries == 0 then
        wantRows, wantDemand, wantSummary = {}, nil, { n = 0 }
        buildWantView()
        return
    end

    -- 1. What the main net holds. The expensive one: a single unfiltered scan, which
    -- is why this whole function is on the heavy cadence.
    if itf then
        local labels = {}
        for _, e in ipairs(wantEntries) do
            for _, l in ipairs(e.labels) do labels[#labels + 1] = l end
        end
        if #labels > 0 then
            local doneScan = profile.span("read main net stock")
            -- Give the labels the network has never held another chance, occasionally.
            mainIdsRetried = mainIdsRetried + 1
            if mainIdsRetried >= RETRY_LABELS_EVERY then
                mainIdsRetried = 0
                for label, id in pairs(mainIds) do
                    if id == false then mainIds[label] = nil end
                end
            end
            -- mainIds is carried in and added to: after the first pass this is one
            -- component call for the whole want list.
            local got, info = supply.mainStock(itf, labels, mainIds)
            doneScan()
            local firstRead = (mainStockAt == nil)
            mainStockInfo = info
            if got then
                mainStock, mainStockAt = got, os.date("%H:%M:%S")
                if firstRead then
                    -- Worth saying which way it read: by id is one call for the whole
                    -- list, label by label is one each, and if it ever falls back to
                    -- the slow form for good that is the line that says so.
                    local how = (info.how == "byId") and "item id"
                        or (info.how == "byLabel") and "label" or tostring(info.how)
                    log(string.format("main net: read by %s, %d call(s), %d of %d "
                        .. "wanted label(s) in stock", how,
                        info.calls or 0, info.found or 0, #labels))
                end
                -- A label learned later is worth a line whenever it happens: it means
                -- an item the fleet is for has appeared in the network for the first
                -- time, and until it did its stock was a guess.
                if (info.resolved or 0) > 0 and not firstRead then
                    log(string.format("main net: %d more label(s) resolved to an item id",
                        info.resolved))
                end
                -- Only on the first read for these two: a label that matches nothing
                -- matches nothing every cycle, and saying so every thirty seconds
                -- would bury everything else in the log.
                if firstRead then
                    for _, miss in ipairs(info.missing or {}) do
                        log("  none in stock: " .. miss
                            .. " (check the label if that is a surprise)")
                    end
                    if info.note then log("  (" .. info.note .. ")") end
                end
            elseif firstRead or (info and info.error) then
                log("main net: " .. tostring(info and info.error or "unreadable"))
            end
        end
    end

    -- 2. What the fleet is actually producing. One estimate per configured module,
    -- pure arithmetic -- no component calls -- and cached for the rest of the cycle,
    -- so the fleet screens get it for free if they are opened.
    local agg = fleetAggregate(rows)
    fleetOreRates = {}
    for _, o in ipairs(agg.ore) do fleetOreRates[o.name] = o.items end

    -- 3. Fill, weight, rate, and the latch.
    wantRows, wantDemand, wantSummary =
        wanted.evaluate(wantEntries, mainStock, acfg, wantSatisfied, fleetOreRates)
    -- What the meteor tables mark, now that the latch has been brought up to date:
    -- the wants still outstanding, and not the ones already met.
    wantKeys = wanted.wantedKeys(wantEntries, wantSatisfied)
    buildWantView()
end

-- What the allocation was computed against, coarsely. Re-searching costs thousands
-- of pool evaluations and can only produce a different answer if the demand or the
-- fleet has actually moved, so a heavy cycle where neither has is skipped.
--
-- Coarse on purpose: rates to two significant figures (a 5%-ish bucket) and weights
-- to two decimals. Mining changes the stock continuously, so an exact signature
-- would differ every single cycle and the check would never save anything.
local function autoSignatureOf(targets, list)
    local parts = {}
    for _, t in ipairs(targets) do
        parts[#parts + 1] = string.format("%s:%.2g:%.2f", t.name, t.need, t.weight)
    end
    table.sort(parts)
    local mods = {}
    for _, m in ipairs(list) do
        mods[#mods + 1] = string.format("%s:%d:%d:%s", m.key, m.tier, m.parallels,
            m.current and "set" or "bare")
    end
    table.sort(mods)
    return table.concat(parts, "|") .. "//" .. table.concat(mods, "|")
end

-- Records what automatic mode wants each AUTO module to be doing. `wanted` is a
-- table addr -> boolean; anything not in it is left alone, which is how MANUAL
-- modules and modules the controller cannot reach stay out of it.
local function decideRunning(rows, wanted)
    for _, r in ipairs(rows) do
        local addr = r.miner.address
        if r.auto and wanted[addr] ~= nil then autoWanted[addr] = wanted[addr] end
    end
end

-- Writes the decisions that have not been written yet. Separate from making them
-- because they are not made every cycle -- an unchanged demand skips the search
-- entirely -- while the writing has to be re-asserted after anything else has
-- touched the machine.
--
-- Returns how many modules were stopped and how many started, for the log.
function enforceRunning(rows)
    local stopped, started = 0, 0
    for _, r in ipairs(rows) do
        local addr = r.miner.address
        local want = autoWanted[addr]
        if r.auto and want ~= nil and autoRunning[addr] ~= want then
            if cfg.dryRun then
                log(string.format("auto %s: WOULD %s it  [dry run]", r.addr,
                    want and "start" or "stop"))
            else
                r.miner:setEnabled(want)
            end
            -- Recorded either way. Under a dry run this is a record of the decision
            -- rather than of a write, which is what keeps the line above to one per
            -- change instead of one per cycle.
            autoRunning[addr] = want
            if want then started = started + 1 else stopped = stopped + 1 end
        end
    end
    return stopped, started
end

function runAuto(rows)
    if manualRun then return false end
    if #wantEntries == 0 then setAutoNote(nil); return false end
    if not wantDemand then
        -- EVERY WANT IS MET, and this is where a satisfied fleet stops.
        --
        -- It used to sit here instead: no demand, no search, no changes, and every
        -- module left exactly as it was -- which meant "exactly as it was" was
        -- MINING, for ever, for ore already at target. The fleet went on eating kits
        -- and plasma to overfill something nobody had asked for since the last time
        -- a want ran low.
        --
        -- Nothing is re-aimed, which is still right: the configurations stay where
        -- they are, so when a want falls back under cfg.auto.refillAt the fleet
        -- starts again on what it was already set up to mine, with no search and no
        -- parameter writes to wait for.
        local wanted = {}
        for _, r in ipairs(rows) do
            if r.auto then wanted[r.miner.address] = false end
        end
        decideRunning(rows, wanted)
        local stopped = enforceRunning(rows)
        if stopped > 0 then
            log(string.format("auto: every want is met -- %s %d module(s)",
                cfg.dryRun and "would stop" or "stopped", stopped))
        end
        setAutoNote(string.format("every want is met -- fleet %s until one falls "
            .. "below %d%% of its target",
            cfg.dryRun and "WOULD BE STOPPED [dry run]" or "stopped",
            math.floor((acfg.refillAt or 0.75) * 100 + 0.5)))
        return false
    end

    -- Who can be aimed at all. A module the controller cannot both put a drone in
    -- and feed plasma to cannot be configured by it either -- three of the four
    -- parameters would fail at the queue -- so it is counted and skipped.
    local list, unfed, busy = {}, 0, 0
    for _, r in ipairs(rows) do
        if r.auto then
            if not (r.station and r.hasItems and r.hasFluid) then
                unfed = unfed + 1
            elseif #queue:pending(r.addr) > 0 then
                -- A change is still landing. Re-deciding now would replace it
                -- mid-flight, and the queue is already stopping the machine.
                busy = busy + 1
            else
                list[#list + 1] = {
                    key = r.addr, row = r,
                    tier = r.miner.tier,
                    parallels = r.parallels or r.parallelCap or 1,
                    -- Bigger modules choose first: they have the most parallels and
                    -- so the most say in what is left for everyone else.
                    size = (r.parallels or r.parallelCap or 1) * 10 + r.miner.tier,
                }
            end
        end
    end

    if #list == 0 then
        local why = "nothing to aim"
        if busy > 0 then why = busy .. " module(s) still working through a change" end
        if unfed > 0 then
            why = why .. string.format(" (%d without a station or plasma feed)", unfed)
        end
        setAutoNote(why)
        return false
    end

    -- The demand, as the allocator wants it. Built from the entries rather than the
    -- rows because the allocator needs each want's KEYS to recognise the material in
    -- a module's estimated output.
    local targets = {}
    for _, e in ipairs(wantEntries) do
        local d = wantDemand[e.material]
        if d then
            targets[#targets + 1] = { name = e.material, need = d.rate,
                                      weight = d.weight, keys = e.keys }
        end
    end
    if #targets == 0 then setAutoNote("nothing being asked for"); return false end

    -- What each module is worth as it stands, which is what KEEP is measured
    -- against. Straight off the estimator, in the same points the searcher scores
    -- candidates in.
    local costs = { ingot = cfg.kitCost, plasma = cfg.plasmaCost, eu = cfg.euCost }
    for _, m in ipairs(list) do
        local cur = currentOf(m.row)
        -- A module the controller has STOPPED keeps its parameters, and they still
        -- describe a perfectly good configuration -- but it is not mining, and KEEP
        -- must not be credited with ore that is not coming. Left in, the fleet reads
        -- as producing what it would produce if it were running: the demand looks
        -- covered by machines that are switched off, so nothing is ever started
        -- again and the want drains to nothing with six idle modules watching.
        --
        -- No `current` also means nothing to protect, so the hysteresis test lets it
        -- be aimed freely -- which is right for a module that is doing nothing.
        if autoWanted[m.row.miner.address] == false then
            m.current = nil
        elseif cur.drone and cur.distance and cur.plasma then
            local est = estimate.run{
                distance = cur.distance, drone = cur.drone, module = m.tier,
                plasma = cur.plasma, overdrive = cur.overdrive or 1,
                parallels = m.parallels, computation = cfg.computation,
            }
            if est then
                m.current = {
                    rates = allocate.ratesFromEstimate(est, targets),
                    cost = allocate.costFromEstimate(est, costs),
                }
            end
        end
    end

    local signature = autoSignatureOf(targets, list)
    if not autoDue and signature == autoSignature then return false end
    autoSignature, autoDue = signature, false
    -- Anything that goes wrong below sets this again: the signature has already been
    -- recorded, so without it a search that failed once would not be retried until
    -- the demand happened to move -- which, with the stock unreadable, could be never.
    local retry = false

    -- One search per HARDWARE GROUP, not per module: the demand is fleet-wide, so
    -- two modules of the same tier running the same parallels have the same
    -- candidates and searching twice would buy nothing.
    local doneSearch = profile.span("auto: search")
    local pools, groups = {}, 0
    for _, m in ipairs(list) do
        local gk = m.tier .. "/" .. m.parallels
        local pool = pools[gk]
        if pool == nil then
            groups = groups + 1
            local ok, res, err = pcall(targeter.search, wantDemand,
                searchOpts(m.row, {}, false))
            if not ok then
                log("auto: the search failed -- " .. tostring(res))
                pool, retry = {}, true
            elseif not res then
                log("auto: " .. tostring(err))
                pool, retry = {}, true
            else
                -- Not res.candidates directly: that list is ranked over the whole
                -- demand and one prolific material can fill it, leaving nothing that
                -- serves the others. See allocate.poolFrom.
                local extra
                pool, extra = allocate.poolFrom(res, targets)
                if extra > 0 then
                    log(string.format("auto: +%d specialist configuration(s) for want(s) "
                        .. "the ranking crowded out", extra))
                end
                if #pool == 0 then
                    -- Worth saying which, because the usual cause is a want no
                    -- meteor yields at this tier, or nothing left after the
                    -- availability filter.
                    log(string.format("auto: no configuration of a T%d module on %d "
                        .. "parallel(s) serves the want list", m.tier, m.parallels))
                    for _, note in ipairs(res.skipped or {}) do log("  " .. note) end
                end
            end
            pools[gk] = pool
        end
        m.candidates = pool
    end
    doneSearch()

    local plan = allocate.plan(list, targets, acfg)

    -- Who is worth running. A module contributes nothing when every want it could
    -- serve is already covered by the rest of the fleet -- which is not a fault, it
    -- is the demand being smaller than the fleet, and cfg.auto.horizon is the dial
    -- that decides how often it happens: a long horizon turns a big shortfall into a
    -- small rate, and a small rate needs few modules.
    --
    -- Done before the aiming, so a module about to be pointed at something is
    -- started rather than being stopped and restarted a moment later.
    local wanted = {}
    for _, ch in ipairs(plan.choices) do
        wanted[ch.module.row.miner.address] = ch.needed
    end
    decideRunning(rows, wanted)
    local stopped, started = enforceRunning(rows)
    if stopped > 0 or started > 0 then
        log(string.format("auto: %d module(s) stopped, %d started -- the demand needs "
            .. "%d of %d", stopped, started, plan.needed or 0, #list))
    end

    -- DRY RUN plans and says what it would do, and writes nothing. cfg.dryRun ships
    -- as true, and it would be a poor joke for the flag that means "let me watch it
    -- first" to be the one setting under which a fleet quietly re-aims itself. It
    -- gates only the WRITING: the search, the allocation and the whole want screen
    -- still run, which is exactly what there is to watch.
    local aimed, would = 0, 0
    for _, ch in ipairs(plan.choices) do
        if ch.action == "set" and ch.candidate then
            if cfg.dryRun then
                would = would + 1
                log(string.format("auto %s: WOULD set %s  [dry run]", ch.module.key,
                    candidateLabel(ch.candidate)))
            else
                local changed = applyCandidate(ch.module.row, ch.candidate, true)
                if #changed > 0 then
                    aimed = aimed + 1
                    log(string.format("auto %s: %s  (%s)", ch.module.key,
                        candidateLabel(ch.candidate), table.concat(changed, ", ")))
                end
            end
        end
    end

    local share = (plan.maxCoverage > 0)
        and math.floor(plan.coverage / plan.maxCoverage * 100 + 0.5) or 0
    if would > 0 then
        -- Nothing was written, so nothing has settled: say so every time rather than
        -- letting a dry run look like a fleet that has finished being aimed.
        setAutoNote(string.format("DRY RUN: would re-aim %d of %d AUTO module(s) for "
            .. "%d%% of the ask -- set cfg.dryRun = false to let it", would, #list, share))
        autoDue = true
        return false
    end
    local note = string.format("aimed %d of %d AUTO module(s), %d%% of the ask covered",
        aimed, #list, share)
    if busy > 0 then note = note .. string.format(" (%d still landing a change)", busy) end
    if aimed == 0 then
        -- The common case once a fleet has settled, and it needs saying: "nothing
        -- changed" and "nothing was considered" look identical from outside.
        note = string.format("%d AUTO module(s) already well aimed, %d%% of the ask "
            .. "covered", #list, share)
    end
    -- Why part of the fleet is sitting there, and what to do if that is not what was
    -- wanted. A row of stopped modules with no explanation reads as a broken
    -- controller; it is almost always the horizon, and there is no way to guess that
    -- from the dashboard.
    if (plan.spare or 0) > 0 then
        note = note .. string.format("   --   %d not needed at this demand "
            .. "(shorten cfg.auto.horizon to use them)", plan.spare)
    end
    setAutoNote(note)
    if aimed > 0 then
        log("auto: " .. note .. string.format("  [%d group(s) searched]", groups))
    end
    if retry then autoDue = true end
    return aimed > 0
end

-- ---- rendering ---------------------------------------------------------------

local tick = 0

local function render()
    if not ui.active then return end
    tick = tick + 1
    -- The fleet's mode in one word, which is a summary and not a setting: AUTO with
    -- a count when the controller is aiming anything, MANUAL when it is not -- and
    -- MANUAL is what an empty want list looks like, because that is what it is.
    local t = view.totals or {}
    local mode = "MANUAL"
    if manualRun then mode = "MANUAL (--manual)"
    elseif (t.auto or 0) > 0 and #wantEntries > 0 then
        mode = string.format("AUTO %d/%d", t.auto, t.miners or 0)
    end

    ui.render({
        mode = mode, dryRun = cfg.dryRun, paused = paused, showLog = showLog,
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
        wants = view.wants, wanted = view.wanted,
        totals = view.totals, supplyErr = supplyErr, messages = messages,
    })
end

-- Console summary for a headless run, so --no-ui is not silent.
local function printCycle()
    log(string.format("cycle #%d -- %d/%d mining, %d auto, plasma %s", cycle,
        view.totals.mining, view.totals.miners, view.totals.auto or 0,
        activePlasma and activePlasma.name or "(none)"))
    -- The want list is the reason the fleet exists, so a headless run says where it
    -- stands before it gets to the consumables.
    for _, r in ipairs((view.wants or {}).rows or {}) do
        if r.state ~= "FULL" then
            log(string.format("  %-22s %-14s %s  making %s/s%s", r.material,
                r.pct or "-", r.stock or "-", r.made or "0",
                r.eta and ("  full in " .. r.eta) or ""))
        end
    end
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
    if nav.screen == "wants" then return #((view.wants or {}).rows or {}) end
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
    elseif action == "auto" then
        local row = view.miners[nav.module]
        if row then
            if manualRun then
                log("started with --manual: nothing is aimed this run whatever the mode")
            elseif row.auto then
                -- Taking a module off the controller by hand, rather than by editing
                -- something on it. Same claim either way.
                claimModule(row)
            else
                modes.set(moduleModes, row.miner.address, modes.AUTO)
                local path, err = modes.save(moduleModes)
                log(row.addr .. ": AUTO now -- the controller will aim it"
                    .. ((#wantEntries == 0) and " once wants.lua lists something" or ""))
                if not path then
                    log("  (could not remember that: " .. tostring(err) .. ")")
                end
                -- One more module to share the demand over, so re-plan rather than
                -- waiting for the demand to happen to move.
                autoDue = true
            end
            view.miners = readFleet(false)
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

do
    local addrs = {}
    for _, m in ipairs(fleet) do addrs[#addrs + 1] = m.address end
    local auto, manual = modes.count(moduleModes, addrs)
    if manualRun then auto, manual = 0, #fleet end
    log(string.format("Mining controller -- %d module(s) (%d AUTO, %d MANUAL), %ds cycle%s",
        #fleet, auto, manual, interval, cfg.dryRun and "  [DRY RUN]" or ""))

    -- The want list, and what is wrong with it. Said at startup because a dropped
    -- entry is invisible everywhere else -- it is not in the list any more.
    if #wantEntries > 0 then
        local parts = {}
        for _, e in ipairs(wantEntries) do
            parts[#parts + 1] = e.material .. " x" .. tostring(e.want)
        end
        log(string.format("Wanted (%d): %s", #wantEntries, table.concat(parts, ", ")))
    elseif wantsFile then
        log("mining/wants.lua lists nothing -- no module will be aimed. W shows the list.")
    else
        log("No mining/wants.lua -- MANUAL only. W shows what that means.")
    end
    for _, p in ipairs(wantProblems) do log("wants.lua: " .. p) end
    if manualRun then
        log("--manual: no module is aimed this run, whatever its mode says.")
    end
end
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

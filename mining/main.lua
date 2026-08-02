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
            .. "accepts a parameter write no other way -- so applying one halts it, "
            .. "writes, and re-allows work. It comes back on unless it was off.",
        "Plasma is fleet-wide by default because a GT hatch holds one fluid at a "
            .. "time. Press P for the plasma list, arrows to choose, ENTER to select, "
            .. "ENTER again to confirm; every hatch holding something else is drained "
            .. "back into the network first, so the switch takes a few cycles to "
            .. "settle. A single module can be switched on its own from its detail "
            .. "screen.",
        "What to stock is read off the hardware: a module's input bus says which "
            .. "drone it runs, and that says which material its kits are made of. "
            .. "Set cfg.supply.target or cfg.supply.plasma to override a figure; "
            .. "left nil, the fleet's own answer is used (cfg.control tunes it).",
        "Restock requests are capped -- by default 2 kit jobs and 1 plasma job at "
            .. "once -- because each one holds a crafting CPU on the main net until "
            .. "its inputs are pushed. The emptiest material goes first.",
        "SPACE pauses maintenance (the modules keep running); L shows the log; "
            .. "Q quits.",
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
local satisfied = {}            -- hysteresis latch, carried across cycles
local activePlasma = nil        -- the plasma the fleet runs on
local pendingPlasma = nil       -- chosen in the UI, applied by the next cycle
local plasmaSlots = {}          -- plasma name -> database slot of its drop

local paused = false
local showLog = false

local view = { miners = {}, kits = {}, plasmas = {}, totals = {} }
local stock = { items = {}, fluids = {} }

-- Where the keyboard is: which screen, which row, and what is being edited.
-- control.key owns every transition; main only carries the actions out.
local nav = control.newNav()

local MATERIALS = control.materialsByTier()

-- What each module is doing, read fresh. Everything the dashboard shows about a
-- miner comes from here, so a cheap UI repaint never touches hardware.
local function readFleet()
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
        if row.hasItems then
            for _, s in ipairs(st:busStacks()) do
                local d = drones.fromName(s.label)
                -- "MK-X" rather than the full "Mining Drone MK-X": the column is
                -- headed DRONE and every one of them starts the same way.
                if d then
                    row.drone, row.material = "MK-" .. d.roman, d.material
                    row.droneTier = d.tier
                    break
                end
            end
        end

        if row.hasFluid then
            row.hatchLevel, row.hatchCapacity = st:hatchTank()
            row.hatchFluid = st:hatchFluid()
            row.staged = st:bufferTank()
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
        row.stateKind = row.state

        rows[#rows + 1] = row
    end
    return rows
end

-- The plasma the fleet is on: whatever most hatches hold. Manual mode runs one
-- plasma everywhere, so a disagreement means a switch is still settling.
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

local function stationsOf(rows)
    local out = {}
    for _, r in ipairs(rows) do
        if r.station then out[#out + 1] = r.station end
    end
    return out
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

-- ---- one maintenance cycle ---------------------------------------------------

local cycle = 0

local function runCycle()
    cycle = cycle + 1
    if profile.enabled then profile.cycles = profile.cycles + 1 end
    local endCycle = profile.span("whole cycle")

    local doneRead = profile.span("readFleet")
    local rows = readFleet()
    doneRead()
    local stations = stationsOf(rows)

    -- Jobs first: a finished craft has already landed in the local net, so the
    -- stock read below sees it and the plan does not ask for it again.
    local donePoll = profile.span("poll restock jobs")
    local finishedJobs = jobs:poll()
    donePoll()
    for _, j in ipairs(finishedJobs) do
        if j.state == "done" then
            log(string.format("stocked %s (x%d)", j.key, j.crafts))
        else
            log(string.format("%s restock %s", j.key, j.state))
        end
    end

    -- A plasma chosen in the UI is applied here, in the control thread, because
    -- draining hatches is slow and the key handler must stay responsive.
    if pendingPlasma then
        local doneSwitch = profile.span("switch plasma")
        local p = pendingPlasma
        pendingPlasma = nil
        local slot, err = slotFor(p)
        if not slot then
            log("cannot stage " .. p.name .. ": " .. tostring(err))
        else
            local results, returned = control.switchPlasma(stations, p, slot)
            local failed = 0
            for _, r in ipairs(results) do
                if not r.ok then failed = failed + 1; log("  " .. tostring(r.err)) end
            end
            log(string.format("switched to %s%s%s", p.name,
                returned > 0 and string.format(", returned %d L", returned) or "",
                failed > 0 and string.format(", %d station(s) failed", failed) or ""))
            activePlasma = p
            rows = readFleet()
        end
        doneSwitch()
    else
        activePlasma = detectPlasma(rows) or activePlasma
    end

    local doneHatch = profile.span("hatches")
    if not paused and activePlasma then
        -- Assert the staging config for any station that has none: a hatch can
        -- only be filled from a tank that is pointed at the right fluid, and a
        -- previous run (or `plasma drain`) may have cleared it.
        local slot = plasmaSlots[activePlasma.name] or select(1, slotFor(activePlasma))
        if slot then
            for _, r in ipairs(rows) do
                if r.station and r.hasFluid and (r.staged or 0) <= 0
                    and (r.hatchLevel or 0) <= 0 then
                    r.station:setPlasmaSource(slot)
                end
            end
        end

        local target = supply.hatchLitres(activePlasma, scfg)
        local touched, moved = control.topUp(stations, target, scfg.hatchRefill)
        if touched > 0 then
            log(string.format("topped up %d hatch(es), +%d L", touched, moved))
        end
    end
    doneHatch()

    -- What to stock, and what to ask for.
    local demandFleet = {}
    for _, r in ipairs(rows) do
        demandFleet[#demandFleet + 1] = { material = r.material, hasFluid = r.hasFluid }
    end
    local kitTargets, plasmaTargets, from =
        control.demand(demandFleet, scfg, ccfg, activePlasma)

    if net and #catalog > 0 then
        local doneStock = profile.span("read local net stock")
        stock = supply.stock(catalog, net)
        doneStock()
    end

    local work, notes = {}, {}
    local donePlan = profile.span("plan and request")
    if itf and #catalog > 0 then
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
            shown = live and string.format("%.1f", live) or nil
            note = "faster, but a smaller size bonus"
            pending = nav.edit and string.format("%.1f", nav.edit.value) or nil
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

        fields[i] = {
            label = f.label, kind = f.kind, value = shown, note = note,
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

    for _, e in ipairs(est.pool) do
        local sz = e.meteor and e.meteor.size
        d.pool[#d.pool + 1] = {
            name = e.name, chance = e.chance, parallels = e.parallels,
            size = sz and (sz[1] .. "-" .. sz[2]) or "-",
            time = secs(e.time), eut = si(e.eut), computation = si(e.computation),
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
            time = "-", eut = si(e.needs and e.needs.eut or 0),
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

-- ---- rendering ---------------------------------------------------------------

local tick = 0

local function render()
    if not ui.active then return end
    tick = tick + 1
    ui.render({
        mode = "MANUAL", dryRun = cfg.dryRun, paused = paused, showLog = showLog,
        screen = nav.screen, moduleCursor = nav.module,
        profile = (nav.screen == "profile") and profile.snapshot() or nil,
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

-- ---- keys --------------------------------------------------------------------
--
-- The state machine lives in control.lua so it can be tested; this is only the
-- part that needs the fleet -- starting a switch, pausing, quitting.

local quit = false

-- Written next to the program, because the log panel shows six lines and this is
-- a table worth reading whole.
local PROFILE_FILE = "mining-profile.txt"

-- Switches ONE module's plasma, as opposed to the fleet-wide picker: the hatch
-- has to be emptied of the old fluid before it will take the new one, exactly as
-- for the whole fleet, so the same routine does it for a list of one.
local function switchOne(row, p)
    if not row.station or not row.hasFluid then
        log(row.addr .. ": no plasma feed configured")
        return
    end
    local slot, err = slotFor(p)
    if not slot then
        log(row.addr .. ": cannot stage " .. p.name .. ": " .. tostring(err))
        return
    end
    local _, returned = control.switchPlasma({ row.station }, p, slot)
    log(string.format("%s: plasma -> %s%s", row.addr, p.name,
        returned > 0 and string.format(" (returned %d L)", returned) or ""))
end

-- Carries out a committed edit. Everything here touches hardware and some of it
-- stops the module first, so it runs from the key handler only because the user
-- just asked for it and is watching -- unlike the plasma switch from the
-- dashboard, which is fleet-wide and queued for the control thread.
local function commitEdit(row, field, value)
    if field == "plasma" then
        local p = plasmas.byTier[value]
        if p then switchOne(row, p) end
        return
    end
    local ok, err = control.applyParam(row.miner, field, value)
    if ok then
        local shown = value
        if field == "drone" then
            local d = drones.get(value)
            shown = d and ("MK-" .. d.roman) or value
        elseif field == "overdrive" then
            shown = string.format("%.1f", value)
        end
        log(string.format("%s: %s -> %s", row.addr, field, tostring(shown)))
    else
        log(string.format("%s: %s not set -- %s", row.addr, field, tostring(err)))
    end
end

local function handleKey(char, code)
    local wasFocused = nav.focus
    local action, changed = control.key(nav, {
        modules = #(view.miners or {}),
        plasmas = #(view.plasmas or {}),
        profiling = profile.enabled,
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

    if action == "open" then
        nav.screen, nav.field, nav.edit = "detail", 1, nil
    elseif action == "close" then
        nav.screen, nav.edit = "dashboard", nil
    elseif action == "commit" then
        local edit = nav.edit
        nav.edit = nil
        local row = view.miners[nav.module]
        if row and edit then commitEdit(row, edit.field, edit.value) end
        -- The write changed the hardware; re-read it rather than showing the old
        -- values until the next cycle comes round.
        view.miners = readFleet()
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
            nextCycle = computer.uptime() + interval
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

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
    },
    flags = {
        { "--no-ui", "no dashboard; print each cycle instead" },
        { "--once",  "one cycle, then exit (for checking a fresh setup)" },
    },
    notes = {
        "MANUAL mode. You set each module's drone, distance and overdrive yourself; "
            .. "the controller only keeps the consumables flowing. It does not "
            .. "enable, disable or reconfigure a module, so quitting leaves the fleet "
            .. "mining -- with whatever is already in its hatches.",
        "Plasma is fleet-wide because a GT hatch holds one fluid at a time. Press P "
            .. "to open the plasma list, arrows to choose, ENTER to select, ENTER "
            .. "again to confirm. Every hatch holding something else is drained back "
            .. "into the network first, so the switch takes a few cycles to settle.",
        "What to stock is read off the hardware: a module's input bus says which "
            .. "drone it runs, and that says which material its kits are made of. "
            .. "Set cfg.supply.target or cfg.supply.plasma to override a figure; "
            .. "left nil, the fleet's own answer is used (cfg.control tunes it).",
        "Restock requests are capped -- by default 2 kit jobs and 1 plasma job at "
            .. "once -- because each one holds a crafting CPU on the main net until "
            .. "its inputs are pushed. The emptiest material goes first.",
        "SPACE pauses maintenance (the modules keep running); L shows the log; "
            .. "Q quits.",
    },
}, ...)
if not ctx then return end

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

for _, m in ipairs(fleet) do
    local spec = cfg.stations and cfg.stations[m.address]
    if spec then
        local ok, err = miners.attachStation(m, spec, shared)
        if not ok then log("station " .. m.address:sub(1, 8) .. ": " .. tostring(err)) end
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
    itf = found

    local usable, unknown = supply.catalog(itf, dbHandle)
    catalog = usable
    log(string.format("Supply interface %s (%s): %d pattern(s)%s",
        itf.address:sub(1, 8), tostring(how), #usable,
        #unknown > 0 and (", " .. #unknown .. " unrecognised") or ""))
end

openSupply()
net = localnet.proxy()
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

-- Where the keyboard is: which panel has focus, the row it is on, and the row
-- awaiting a second ENTER. control.key owns the transitions.
local picker = { focus = nil, cursor = 1, confirm = nil }

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
                if d then row.drone, row.material = "MK-" .. d.roman, d.material; break end
            end
        end

        if row.hasFluid then
            row.hatchLevel, row.hatchCapacity = st:hatchTank()
            row.hatchFluid = st:hatchFluid()
            row.staged = st:bufferTank()
            local p = row.hatchFluid and plasmas.byName[row.hatchFluid]
            if p then row.hatchTarget = supply.hatchLitres(p, scfg) end
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
    local rows = readFleet()
    local stations = stationsOf(rows)

    -- Jobs first: a finished craft has already landed in the local net, so the
    -- stock read below sees it and the plan does not ask for it again.
    for _, j in ipairs(jobs:poll()) do
        if j.state == "done" then
            log(string.format("stocked %s (x%d)", j.key, j.crafts))
        else
            log(string.format("%s restock %s", j.key, j.state))
        end
    end

    -- A plasma chosen in the UI is applied here, in the control thread, because
    -- draining hatches is slow and the key handler must stay responsive.
    if pendingPlasma then
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
    else
        activePlasma = detectPlasma(rows) or activePlasma
    end

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

    -- What to stock, and what to ask for.
    local demandFleet = {}
    for _, r in ipairs(rows) do
        demandFleet[#demandFleet + 1] = { material = r.material, hasFluid = r.hasFluid }
    end
    local kitTargets, plasmaTargets, from =
        control.demand(demandFleet, scfg, ccfg, activePlasma)

    if net and #catalog > 0 then
        stock = supply.stock(catalog, net)
    end

    local work, notes = {}, {}
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
    for _, n in ipairs(notes) do log(n) end

    -- ---- assemble the view ----
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
end

-- ---- rendering ---------------------------------------------------------------

local tick = 0

local function render()
    if not ui.active then return end
    tick = tick + 1
    ui.render({
        mode = "MANUAL", dryRun = cfg.dryRun, paused = paused, showLog = showLog,
        focus = picker.focus, cursor = picker.cursor,
        confirm = picker.confirm and view.plasmas[picker.confirm]
            and view.plasmas[picker.confirm].name or nil,
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

local function handleKey(char, code)
    local wasFocused = picker.focus
    local action, changed = control.key(picker, #(view.plasmas or {}), char, code)

    -- Opening the list lands on the plasma in use, so the common case -- look,
    -- then escape -- needs no navigation at all.
    if picker.focus == "plasma" and not wasFocused then
        for i, p in ipairs(view.plasmas or {}) do
            if p.active then picker.cursor = i end
        end
    end

    if action == "apply" then
        local pick = view.plasmas[picker.confirm]
        picker.confirm, picker.focus = nil, nil
        if pick then
            pendingPlasma = pick.plasma
            log("switching the fleet to " .. pick.name .. " ...")
        end
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

-- Nothing is put back on the way out. The modules are the player's -- they were
-- running before this started and they keep running after, with whatever is in
-- their hatches. `plasma drain` is the command for handing it all back.
if #fleet > 0 then
    print(string.format("Mining controller stopped after %d cycle(s). The modules "
        .. "keep running on what is in their hatches.", cycle))
end
if not ok and not tostring(err):find("interrupt") then error(err, 0) end

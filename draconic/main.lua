-- Draconic Reactor controller: turns awakened draconium into chaos shards.
--
-- Starts from the GTNH wiki's safe-shutdown script (credits UltraProdigy, Fox:
-- stop at 20% chaos share or 20% containment field) and adds:
--   * feeding: moves awakened draconium (nuggets, ingots, blocks) from a Super
--     Stock Replenisher into a buffer chest that empties into a stabilizer,
--     before a run and while it runs;
--   * auto-start: charges once the reactor holds enough fuel, and activates it
--     when charged;
--   * a fuel reserve: stops while there is still enough fuel for the shutdown
--     itself (a reactor that runs dry while stopping cannot cool down);
--   * a dashboard with touch buttons, and a log file.
--
-- Run from this folder:  main
-- Keys: S start, X stop (also turns auto-start off), A auto-start on/off,
--       F feeding on/off, Q quit (twice). See config.lua and README.md.

local event = require("event")
local computer = require("computer")
local keyboard = require("keyboard")
local serialization = require("serialization")

local cfg = require("config")
local P = require("physics")
local hwlib = require("hw")
local ui = require("ui")

local C = P.constants(cfg.game)
local now = computer.uptime
local fmtInt, fmtTime, fmtPct, fmtSI = ui.fmtInt, ui.fmtTime, ui.fmtPct, ui.fmtSI

local function blocks(fuel) return fmtInt((fuel or 0) / C.block) end

-- ---- log ------------------------------------------------------------------------

local messages = {}

-- level: info | good | warn | crit. `keep` also appends it to cfg.logFile.
local function log(msg, level, keep)
    local line = os.date("%H:%M:%S") .. "  " .. msg
    messages[#messages + 1] = { text = line, level = level or "info" }
    if #messages > 60 then table.remove(messages, 1) end
    if not ui.active then print(line) end
    if keep and cfg.logFile then
        local f = io.open(cfg.logFile, "a")
        if f then
            f:write(line, "\n")
            f:close()
        end
    end
end

-- Logs `msg` only when it differs from the last one logged under `key`;
-- nil clears it.
local lastOnce = {}
local function logOnce(key, msg, level, keep)
    if lastOnce[key] ~= msg then
        lastOnce[key] = msg
        if msg then log(msg, level, keep) end
    end
end

local lastBeep = -math.huge
local function alarm()
    if now() - lastBeep >= 2 then
        lastBeep = now()
        pcall(computer.beep, 1200, 0.15)
    end
end

-- ---- hardware ---------------------------------------------------------------------

local hw, problems = hwlib.init(cfg)
if not hw then
    io.stderr:write("Hardware not found:\n")
    for _, p in ipairs(problems) do io.stderr:write("  " .. p .. "\n") end
    io.stderr:write("Run `probe` and check config.lua.\n")
    return
end

-- ---- persistence ------------------------------------------------------------------

local saved = {}
do
    local f = io.open(cfg.stateFile, "r")
    if f then
        local ok, data = pcall(serialization.unserialize, f:read("*a"))
        f:close()
        if ok and type(data) == "table" then saved = data end
    end
end

local autoStart = saved.autoStart
if autoStart == nil then autoStart = cfg.autoStart.enabled end
local feedOn = cfg.feed.enabled and hw.tp ~= nil
local totals = { shards = saved.shards or 0, fed = saved.fed or 0 }
local session = { shards = 0, fed = 0 }
local dirty, nextSave = false, 0

local function save()
    local f = io.open(cfg.stateFile, "w")
    if f then
        f:write(serialization.serialize({ autoStart = autoStart, shards = totals.shards, fed = totals.fed }))
        f:close()
    end
    dirty = false
end

local function setAuto(on, why)
    if autoStart == on then return end
    autoStart = on
    log(why or ("Auto-start " .. (on and "ON." or "OFF.")), on and "good" or "warn", true)
    save()
end

-- ---- state ------------------------------------------------------------------------

local last              -- last good reactor reading (hw:info())
local readFails = 0
local offlineSince = now()
local runStart
local lastCmd = { stop = -math.huge, charge = -math.huge, activate = -math.huge }
local sim, simAt, nextSim = nil, -math.huge, 0
-- fuel: in the replenisher. buffer: in the buffer chest, on its way in.
-- usable: what feeding could still move from the replenisher.
local stock = { fuel = 0, buffer = 0, usable = 0, known = false }
local shardsWaiting = 0 -- full shards in the core's slot; they block fuel going in
local shardsSince       -- since when shards have been waiting
local prevTotal, stallSince, stalled = nil, nil, false
local fill = 0          -- fuel fed since the reactor was last seen not filling
local autoWhy = ""      -- why auto-start is (not) starting
local quitArmedUntil = 0

local function isActive(s) return s == "online" or s == "stopping" end

-- Fuel the reserve rule wants kept: the simulated shutdown's use, times the
-- factor, plus the fixed blocks.
local function reserveFuel()
    if not sim then return nil end
    return sim.fuelUsed * cfg.safety.reserveFactor + cfg.safety.reserveBlocks * C.block
end

-- Fuel the auto-start rule wants inside, capped at what fits next to the chaos.
local function autoMinFuel(d)
    local cap = C.maxFuel - math.floor(d and d.converted or 0) - C.block
    return math.max(0, math.min(cfg.autoStart.minBlocks * C.block, cap))
end

-- Fuel the replenisher adds to a run: only what feeding will actually move in
-- while the reactor runs.
local function supplyFuel()
    if feedOn and cfg.feed.whileRunning and stock.known then return math.max(0, stock.fuel) end
    return 0
end

-- ---- commands -------------------------------------------------------------------

local function stop(reason, level)
    if now() - lastCmd.stop < 1 then return end
    lastCmd.stop = now()
    local ok, err = hw:stop()
    if ok then
        logOnce("stop", nil)
        log("STOP: " .. reason, level or "warn", true)
    else
        logOnce("stop", "ERROR: the reactor refused to stop (" .. tostring(err or "not in a stoppable state")
            .. "): " .. reason, "crit", true)
    end
end

local function charge(why)
    lastCmd.charge = now()
    local ok, err = hw:charge()
    if ok then
        logOnce("charge", nil)
        log(string.format("Charging (%s) with %s blocks of fuel inside.", why, blocks(last and last.fuel)), "info", true)
    else
        logOnce("charge", "The reactor refused to charge (" .. tostring(err or "not in a chargeable state") .. ").", "warn")
    end
end

-- Can the reactor be charged now? auto = also apply the auto-start rules.
local function startCheck(d, auto)
    if d.status ~= "offline" then return false, "the reactor is " .. d.status end
    if d.total < 144 then return false, "it needs at least 144 fuel inside" end
    if d.convLvl >= cfg.autoStart.maxConversion then
        return false, string.format("leftover chaos is %s of the contents (limit %s); add fuel",
            fmtPct(d.convLvl), fmtPct(cfg.autoStart.maxConversion, 0))
    end
    if not auto then return true end
    local minTotal = (cfg.autoStart.minTotalBlocks or 0) * C.block
    if minTotal > 0 then
        local supply = stock.buffer + supplyFuel()
        if d.fuel + supply < minTotal then
            return false, string.format("fuel available %s / %s blocks (reactor %s + supply %s)",
                blocks(d.fuel + supply), blocks(minTotal), blocks(d.fuel), blocks(supply))
        end
    end
    local need = autoMinFuel(d)
    if d.fuel < need then
        return false, string.format("fuel %s / %s blocks (%s in the chest)", blocks(d.fuel), blocks(need),
            blocks(stock.buffer))
    end
    if cfg.autoStart.waitForDelivery then
        local flowing = stock.buffer > 0 and C.maxFuel - d.total >= C.nugget and shardsWaiting == 0 and not stalled
        if stock.usable > 0 or flowing then
            return false, "still filling (" .. blocks(stock.buffer) .. " blocks in the chest)"
        end
    end
    local cd = cfg.autoStart.cooldown - (now() - offlineSince)
    if cd > 0 then return false, string.format("cooldown, %ds", math.ceil(cd)) end
    return true, "starting"
end

-- ---- each reading -----------------------------------------------------------------

local function runSim(d)
    if not isActive(d.status) then
        sim = nil
        return
    end
    if now() < nextSim then return end
    nextSim = now() + cfg.safety.simInterval
    local ok, res = pcall(P.simulateStop, {
        temp = d.temp, sat = d.sat, satMax = d.satMax, converted = d.converted, fuel = d.fuel,
    }, cfg.game)
    if ok then
        sim, simAt = res, now()
        logOnce("sim", nil)
    else
        logOnce("sim", "ERROR in the shutdown simulation: " .. tostring(res), "crit")
    end
end

-- The safety rules. Only an ONLINE reactor is stopped; what a STOPPING one
-- needs is fuel, which feed() gives it.
local function safety(d)
    local s = cfg.safety
    if d.status == "stopping" then
        if d.fuel <= 0 then
            logOnce("dry", "CRITICAL: stopping with NO unconverted fuel -- it cannot cool down. "
                .. "Get awakened draconium into it NOW.", "crit", true)
            alarm()
        elseif sim and not sim.finished then
            logOnce("dry", "WARN: this shutdown is predicted to fail (" .. tostring(sim.why) .. "); feeding fuel.",
                "warn", true)
        else
            logOnce("dry", nil)
        end
        return
    end
    logOnce("dry", nil)
    if d.status ~= "online" then return end

    if d.fieldLvl < s.stopField then
        stop(string.format("EMERGENCY: containment field at %s (limit %s)", fmtPct(d.fieldLvl),
            fmtPct(s.stopField, 0)), "crit")
        alarm()
        if autoStart then setAuto(false, "Auto-start OFF: the injector is not keeping the field up.") end
        return
    end
    if d.fuel <= 0 then
        stop("no unconverted fuel left", "crit")
        alarm()
        return
    end
    if d.convLvl >= s.stopConversion then
        stop(string.format("chaos share %s reached the %s limit", fmtPct(d.convLvl), fmtPct(s.stopConversion, 0)))
        return
    end
    if sim and now() - simAt <= 3 * s.simInterval then
        if not sim.finished then
            stop("a shutdown started now would not complete (" .. tostring(sim.why) .. ")", "crit")
            alarm()
            return
        end
        local keep = reserveFuel()
        if d.fuel < keep then
            stop(string.format("fuel reserve: %s fuel left, a shutdown uses ~%s (keeping %s)",
                fmtInt(d.fuel), fmtInt(sim.fuelUsed), fmtInt(keep)))
            return
        end
    end
end

-- Status changes and the shard counter.
local function track(d)
    local prev = last
    if not prev or prev.status ~= d.status then
        if prev then
            local level = (d.status == "online" and "good") or (d.status == "invalid" and "crit") or "info"
            log(string.format("Status %s -> %s", prev.status:upper(), d.status:upper()), level, true)
        end
        if d.status == "offline" then offlineSince, runStart = now(), nil end
        if d.status == "online" then runStart = runStart or now() end
        if prev and prev.status == "online" and d.status ~= "online" and now() - lastCmd.stop > 5 then
            setAuto(false, "Stopped from outside the script: auto-start OFF (A turns it back on).")
        end
    end
    -- The core shows its full shards in its one slot (convertedFuel > one
    -- shard). Until they are pulled out of a stabilizer, nothing can go in.
    shardsWaiting = d.converted > C.shard and math.floor(d.converted / C.shard) or 0
    if shardsWaiting > 0 then shardsSince = shardsSince or now() else shardsSince = nil end
    logOnce("shards", (shardsSince and now() - shardsSince > 30) and ("WARN: " .. shardsWaiting
        .. " chaos shard(s) are not being pulled out of the reactor; no fuel can get in meanwhile.") or nil,
        "warn", true)
    if prev then
        local drop = prev.converted - d.converted
        if drop >= C.shard * 0.5 then
            local n = math.floor(drop / C.shard + 0.5)
            session.shards, totals.shards, dirty = session.shards + n, totals.shards + n, true
        end
    end
    last = d
end

-- Activation and auto-start.
local function control(d)
    if d.status == "charged" and cfg.autoStart.activate and now() - lastCmd.activate > 2 then
        lastCmd.activate = now()
        if d.convLvl >= cfg.safety.stopConversion then
            stop("charge aborted: leftover chaos " .. fmtPct(d.convLvl) .. " is over the stop limit")
        else
            local ok, err = hw:activate()
            if ok then log("Charged: reactor ACTIVATED.", "good", true)
            else logOnce("activate", "The reactor refused to activate (" .. tostring(err or "not charged") .. ").", "warn") end
        end
    end
    if d.status == "offline" then
        local ok, why = startCheck(d, true)
        autoWhy = why
        if autoStart and ok and now() - lastCmd.charge > 30 then charge("auto-start") end
    end
end

local function guarded(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if ok then logOnce("err:" .. name, nil)
    else logOnce("err:" .. name, "ERROR in " .. name .. ": " .. tostring(err), "crit", true) end
end

local function poll()
    local d, err = hw:info()
    if not d then
        readFails = readFails + 1
        if readFails == 8 then log("ERROR: no answer from the reactor: " .. tostring(err), "crit", true) end
        if readFails >= 8 then alarm() end
        return
    end
    if readFails >= 8 then log("The reactor answers again.", "good", true) end
    readFails = 0
    guarded("simulation", runSim, d)
    guarded("safety", safety, d)
    guarded("tracking", track, d)
    guarded("control", control, d)
end

-- ---- feeding ----------------------------------------------------------------------

local FEED_STATES = { offline = true, charging = true, charged = true, stopping = true }

-- The awakened draconium among `list`, blocks first, and its total fuel.
local function fuelStacks(list)
    local stacks, total = {}, 0
    for _, it in ipairs(list) do
        local value = P.fuelValue(it.label, C)
        if value > 0 then
            it.value = value
            total = total + value * it.size
            stacks[#stacks + 1] = it
        end
    end
    table.sort(stacks, function(a, b) return a.value > b.value end)
    return stacks, total
end

-- Fuel in the buffer chest should keep flowing into the reactor while the
-- reactor has room and no shard blocks its slot. Warn when it does not.
local function checkStall(d)
    if stock.buffer > 0 and C.maxFuel - d.total >= C.nugget and shardsWaiting == 0 then
        if prevTotal and d.total > prevTotal then stallSince = nil
        else stallSince = stallSince or now() end
    else
        stallSince = nil
    end
    prevTotal = d.total
    stalled = stallSince ~= nil and now() - stallSince > 30
    logOnce("stall", stalled and ("WARN: " .. blocks(stock.buffer) .. " blocks of fuel sit in the buffer chest "
        .. "but none reaches the reactor. Check the chest -> stabilizer link.") or nil, "warn", true)
end

local function feed()
    local d = last
    if not hw.tp or not d then return end

    local items, err = hw:stock()
    local inChest, berr = hw:buffer()
    if not items or not inChest then
        stock.known = false
        logOnce("stock", "ERROR: " .. tostring(err or berr), "crit")
        return
    end
    logOnce("stock", nil)
    stock.known = true
    local stacks
    stacks, stock.fuel = fuelStacks(items)
    local _, inBuffer = fuelStacks(inChest)
    stock.buffer = inBuffer
    checkStall(d)

    local allowed = feedOn and (FEED_STATES[d.status] or (d.status == "online" and cfg.feed.whileRunning))
    -- Room left once the chest has emptied into the reactor.
    local space = C.maxFuel - d.total - stock.buffer
    local fed, moves = 0, 0
    if allowed then
        for _, st in ipairs(stacks) do
            while moves < cfg.feed.maxMoves do
                local fit = math.min(st.size, 64, math.floor(space / st.value))
                if fit <= 0 then break end
                local n = hw:feed(st.slot, fit)
                moves = moves + 1
                if n <= 0 then
                    logOnce("feed", "WARN: could not move fuel into the buffer chest (full?).", "warn")
                    moves = cfg.feed.maxMoves
                    break
                end
                logOnce("feed", nil)
                st.size, space = st.size - n, space - n * st.value
                fed = fed + n * st.value
            end
        end
    end
    if fed > 0 then
        session.fed, totals.fed, dirty = session.fed + fed, totals.fed + fed, true
        stock.fuel, stock.buffer = stock.fuel - fed, stock.buffer + fed
    end

    -- What could still go in: for "wait for the delivery".
    local usable = 0
    for _, st in ipairs(stacks) do
        usable = usable + math.min(st.size, math.floor(space / st.value)) * st.value
    end
    stock.usable = allowed and usable or 0

    -- One log line per fill between runs, not one per transfer.
    if d.status ~= "online" then
        if fed > 0 then
            fill = fill + fed
        elseif fill > 0 then
            log("Moved " .. blocks(fill) .. " blocks of fuel toward the reactor.", "info", true)
            fill = 0
        end
    end
end

-- ---- actions ----------------------------------------------------------------------

local actions = {}

function actions.start()
    local d = last
    if not d then return log("No reactor data yet.", "warn") end
    if d.status == "online" then return log("Already running.") end
    if d.status == "charging" or d.status == "charged" then return log("Already charging.") end
    local ok, why = startCheck(d, false)
    if not ok then return log("Cannot start: " .. why .. ".", "warn") end
    charge("manual")
end

function actions.stop()
    setAuto(false, "Auto-start OFF (manual stop).")
    local d = last
    if d and d.status ~= "offline" and d.status ~= "stopping" then
        lastCmd.stop = -math.huge
        stop("manual stop")
    else
        log("Nothing to stop.")
    end
end

function actions.auto() setAuto(not autoStart) end

function actions.feed()
    if not hw.tp then return log("Feeding unavailable: " .. tostring(hw.tpProblem or "feeding disabled in config") .. ".", "warn") end
    feedOn = not feedOn
    log("Feeding " .. (feedOn and "ON." or "OFF."), feedOn and "good" or "warn")
end

-- True when the user confirmed quitting.
function actions.quit()
    local active = last and last.status ~= "offline"
    if not active or now() < quitArmedUntil then return true end
    quitArmedUntil = now() + 4
    log("Q again to quit" .. (cfg.safety.stopOnQuit and ": the reactor will be STOPPED."
        or ": the reactor will be left running UNPROTECTED."), "warn")
    return false
end

-- ---- view -------------------------------------------------------------------------

local HEADLINE = {
    offline = "idle",
    charging = "charging the field, saturation and temperature",
    charged = "charged, ready to activate",
    online = "converting draconium to chaos",
    stopping = "shutting down, cooling to 2000 C",
    invalid = "a stabilizer or the injector is missing!",
}

local function buildView()
    local d = last
    local v = {
        clock = os.date("%H:%M:%S"), d = d, linkLost = readFails >= 8,
        autoOn = autoStart, feedOn = feedOn, messages = messages,
        block = C.block, shard = C.shard, maxFuel = C.maxFuel,
        warnTemp = cfg.safety.warnTemp, warnField = cfg.safety.warnField,
        stopField = cfg.safety.stopField, stopConversion = cfg.safety.stopConversion,
        autoMinFuel = autoMinFuel(d), reserve = reserveFuel(), shardsWaiting = shardsWaiting,
        prompt = now() < quitArmedUntil and "press Q again to quit" or nil,
    }
    if not d then
        v.doing = "waiting for the reactor..."
        return v
    end
    v.headline = HEADLINE[d.status] or ""

    if d.status == "offline" then
        if autoStart then
            v.doing = "Auto-start: " .. autoWhy
            v.doingLevel = autoWhy == "starting" and "good" or "dim"
        else
            v.doing = "Auto-start is OFF (A). S starts it by hand."
        end
    elseif d.status == "online" then
        v.doing = runStart and ("Running for " .. fmtTime(now() - runStart)
            .. (feedOn and cfg.feed.whileRunning and ", topped up from the replenisher" or "")) or ""
        v.doingLevel = "good"
    elseif d.status == "stopping" and sim then
        v.doing = sim.finished and ("Cools down in ~" .. fmtTime(sim.ticks / 20) .. ", using ~"
            .. fmtInt(sim.fuelUsed) .. " fuel") or ("Shutdown in trouble: " .. tostring(sim.why))
        v.doingLevel = sim.finished and "info" or "crit"
    end

    local burn = isActive(d.status) and d.useRate * 20 or 0
    if burn > 0 then
        v.burn = string.format("%s fuel/s, %.1f shard/h", fmtInt(burn), burn * 3600 / C.shard)
        local keep = reserveFuel() or 0
        v.runsDry = d.status == "online" and (fmtTime((d.fuel - keep) / burn) .. " to the reserve stop") or "-"
    else
        v.burn, v.runsDry = "-", "-"
    end
    if sim then
        v.shutdown = sim.finished and string.format("%s, uses %s fuel", fmtTime(sim.ticks / 20), fmtInt(sim.fuelUsed))
            or ("FAILS: " .. tostring(sim.why))
        v.shutdownColor = sim.finished and nil or "crit"
        v.stopBelow = fmtInt(reserveFuel()) .. " fuel (" .. blocks(reserveFuel()) .. " blk)"
    else
        v.shutdown = d.status == "online" and "simulating..." or "-"
        v.stopBelow = "-"
    end

    if not hw.tp then
        v.supply, v.supplyColor = "no transposer", "dim"
    elseif not stock.known then
        v.supply, v.supplyColor = "cannot read the replenisher", "crit"
    else
        v.supply = blocks(stock.fuel) .. " blk, chest " .. blocks(stock.buffer)
        if (cfg.autoStart.minTotalBlocks or 0) > 0 then
            v.supply = v.supply .. ", total " .. blocks(d.fuel + stock.buffer + supplyFuel())
        end
        if stalled then v.supplyColor = "warn"
        elseif stock.fuel + stock.buffer <= 0 then v.supplyColor = "dim" end
    end
    v.fed = blocks(session.fed) .. " blk now, " .. blocks(totals.fed) .. " total"
    v.shards = fmtInt(session.shards) .. " now, " .. fmtInt(totals.shards) .. " total"
    v.output = isActive(d.status) and (fmtSI(d.genRate) .. " RF/t, drain " .. fmtSI(d.drainRate)) or "-"
    return v
end

-- ---- main loop --------------------------------------------------------------------

local KEYS = {
    [keyboard.keys.s] = "start", [keyboard.keys.x] = "stop", [keyboard.keys.a] = "auto",
    [keyboard.keys.f] = "feed", [keyboard.keys.q] = "quit",
}

local function loop()
    local nextPoll, nextFeed, nextRender = 0, 0, 0
    while true do
        local ev = { event.pull(0.25) }
        local action
        if ev[1] == "key_down" then
            action = KEYS[ev[4]]
        elseif ev[1] == "touch" then
            action = ui.hit(ev[3], ev[4])
        end
        if action == "quit" then
            if actions.quit() then return end
            nextRender = 0
        elseif action then
            guarded("action", actions[action])
            nextRender = 0
        end

        local t = now()
        if t >= nextPoll then
            nextPoll = t + cfg.timing.poll
            poll()
        end
        if t >= nextFeed then
            nextFeed = t + cfg.feed.interval
            guarded("feeding", feed)
        end
        if dirty and t >= nextSave then
            nextSave = t + 60
            save()
        end
        if ui.active and t >= nextRender then
            nextRender = t + cfg.timing.render
            guarded("display", function() ui.render(buildView()) end)
        end
    end
end

local uiActive = cfg.ui ~= false and ui.init()
log("Draconic reactor controller starting. Auto-start " .. (autoStart and "ON" or "OFF") .. ".", "info", true)
log(hw:describe() .. ".", hw.tp and "info" or "warn")
if not uiActive then log("S start, X stop, A auto-start, F feeding, Q quit (twice).") end

local ok, err = pcall(loop)

-- Leaving: unless told otherwise, do not leave a running reactor behind with
-- nobody to feed or stop it.
local d = hw:info()
local stopped = false
if cfg.safety.stopOnQuit and d and d.status ~= "offline" and d.status ~= "stopping" then
    stopped = hw:stop() == true
end
save()
ui.shutdown()
if stopped then
    print("Reactor controller stopped. The reactor is SHUTTING DOWN (stopOnQuit).")
elseif not d then
    print("Reactor controller stopped. WARNING: the reactor does not answer; check it by hand.")
elseif d.status ~= "offline" then
    print("Reactor controller stopped. WARNING: the reactor is " .. d.status:upper()
        .. " and nothing feeds or protects it now. Run `main` again.")
else
    print("Reactor controller stopped. The reactor is offline.")
end
if not ok and not tostring(err):find("interrupted", 1, true) then error(err, 0) end

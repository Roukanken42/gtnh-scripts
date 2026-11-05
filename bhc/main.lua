-- Black Hole Compressor (Pseudostable Black Hole Containment Field) controller.
--
-- Opens a black hole with a seed when the crafting net has work, holds it with
-- spacetime at the stability you configure (more parallels the lower it is),
-- protects the last recipe from being voided, and closes a dead hole with a
-- collapser when there is more work -- or lets it close itself when there isn't.
--
-- Run from this folder:
--   main                    normal start
--   main --stability=37     a hole is open right now at 37% (read it off WAILA)
-- Keys: SPACE/P pause (hands off: no spacetime, no items, machine untouched),
--       Q quit. See config.lua and README.md.

local shell = require("shell")
local event = require("event")
local computer = require("computer")
local keyboard = require("keyboard")
local serialization = require("serialization")

local cfg = require("config")
local model = require("model")
local hwlib = require("hw")
local ui = require("ui")

local _, opts = shell.parse(...)

-- ---- log ----------------------------------------------------------------------

local messages = {}
local function log(msg)
    local line = os.date("%H:%M:%S") .. "  " .. msg
    messages[#messages + 1] = line
    if #messages > 60 then table.remove(messages, 1) end
    if not ui.active then print(line) end
end

-- Logs `msg` only when it differs from the last one logged under `key`.
local lastOnce = {}
local function logOnce(key, msg)
    if lastOnce[key] ~= msg then
        lastOnce[key] = msg
        if msg then log(msg) end
    end
end

-- ---- hardware ---------------------------------------------------------------

local hw, problems = hwlib.init(cfg)
if not hw then
    io.stderr:write("Hardware not found:\n")
    for _, p in ipairs(problems) do io.stderr:write("  " .. p .. "\n") end
    io.stderr:write("Run `probe` and check config.lua.\n")
    return
end
local dry = cfg.dryRun

-- ---- persistence ------------------------------------------------------------

-- os.time() is in-game time: 72 units per real second (3.6 per tick).
local GAME_UNITS_PER_SECOND = 72
local SAVED = { "hole", "S", "counter", "costMod", "held", "vpHeld", "stageHeld", "spent", "pulses" }

local function save(st)
    local data = { time = os.time() }
    for _, k in ipairs(SAVED) do data[k] = st[k] end
    local f = io.open(cfg.stateFile, "w")
    if f then
        f:write(serialization.serialize(data))
        f:close()
    end
end

local function load()
    local f = io.open(cfg.stateFile, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    local ok, data = pcall(serialization.unserialize, text)
    if ok and type(data) == "table" then return data end
end

-- ---- state ------------------------------------------------------------------

local st = model.new()
local paused = false
local now = computer.uptime
local lastPulse = now()
local lastTank = nil
local reqLevel, lastReqHigh = 0, -math.huge
local seeds, collapsers = 0, 0
local nextStock = 0
local ms = { active = false, remaining = 0, maxProgress = 0 }
local recipeHist = {}   -- recent recipe lengths (s), newest last
local spacetimeOn = nil -- what we last set the output to
local enabledAt = 0     -- when the hatch was last switched on
local workSet = nil     -- what we last set work-allowed to
local lastDecision = { why = "starting" }

local function requested()
    return reqLevel > 0 or now() - lastReqHigh < cfg.requestHoldSeconds
end

local function recipeEst()
    local est = 0
    for _, s in ipairs(recipeHist) do est = math.max(est, s) end
    if est == 0 then est = cfg.recipe.defaultSeconds end
    return est
end

-- The hatch is only switched ON right after a pulse, a full second before the
-- next drain, so the script always knows what the hatch did at a drain.
-- Switching OFF is allowed any time: at worst that drain is skipped.
local function setSpacetime(on, atPulse)
    if on == spacetimeOn then return end
    if on and not atPulse then return end  -- wait for the next pulse
    if not dry then hw:setSpacetime(on) end
    spacetimeOn = on
    if on then enabledAt = now() end
end

-- Was the drain that just happened (this pulse) a held second? Only when the
-- hatch has been on since well before it -- a pulse handled late could
-- otherwise follow a switch-on that came after the drain -- and the tank could
-- pay. A dry run never really enables the hatch.
local function heldThisPulse()
    return spacetimeOn == true and not dry
        and now() - enabledAt >= 0.5
        and (lastTank or 0) >= st.costMod
end

local function setWork(allowed)
    if dry then
        if workSet ~= allowed then log("[dry] would " .. (allowed and "allow" or "block") .. " new recipes") end
        workSet = allowed
        return
    end
    if workSet ~= allowed or ms.workAllowed ~= allowed then
        hw:setWork(allowed)
        if workSet ~= allowed then log(allowed and "New recipes allowed." or "New recipes blocked.") end
        workSet = allowed
    end
end

local function fault(msg)
    st.fault = msg
    log("FAULT: " .. msg)
    log("Automation stopped. Fix it, then restart `main`.")
end

-- How much spacetime there is. Only for budgeting: a stock replenisher refills
-- the tank mid-hole, so its level says nothing about what was drained.
local function pollTank()
    local tank = hw:tank()
    if tank then lastTank = tank end
end

local function pollMachine()
    ms = hw:machineState()
    if ms.active and ms.maxProgress > 0 then
        local secs = ms.maxProgress / 20
        if recipeHist[#recipeHist] ~= secs then
            recipeHist[#recipeHist + 1] = secs
            if #recipeHist > 8 then table.remove(recipeHist, 1) end
        end
    end
end

local function pollStock(force)
    if not force and now() < nextStock then return end
    local s, c, err = hw:stock()
    if err then logOnce("stock", "ERROR reading the interface: " .. tostring(err)) else logOnce("stock", nil) end
    seeds, collapsers = s, c
    nextStock = now() + cfg.timing.resourcePoll
end

-- ---- deciding -----------------------------------------------------------------

local function insert(kind)
    local bs, bc, err = hw:inBus()
    if bs == nil then
        log("ERROR reading the input bus: " .. tostring(err))
        return false
    end
    if bs > 0 or bc > 0 then
        -- Something is already waiting in the bus. Adopt it if it is what we
        -- wanted, refuse to add a second catalyst otherwise.
        if (kind == "seed" and bc == 0) or (kind == "collapser" and bs == 0) then
            st.pending = { kind = kind, since = now() }
            log("A " .. kind .. " is already in the bus, waiting for the machine to take it.")
            return true
        end
        fault(string.format("the input bus holds %d seed(s) and %d collapser(s); remove them", bs, bc))
        return false
    end
    if dry then
        logOnce("dry-insert", "[dry] would insert a " .. kind)
        return false
    end
    local ok, ierr = hw:insert(kind)
    if not ok then
        logOnce("insert", "ERROR: " .. tostring(ierr))
        return false
    end
    logOnce("insert", nil)
    st.pending = { kind = kind, since = now() }
    log(kind == "seed" and "Seed inserted, opening a black hole." or "Collapser inserted, closing the hole.")
    pollStock(true)
    return true
end

local function decideAndApply(atPulse)
    if paused then
        setSpacetime(false)
        lastDecision = { why = "paused" }
        return
    end
    local a = model.decide(st, {
        requested = requested(), active = ms.active, remaining = ms.remaining,
        recipeEst = recipeEst(), tank = lastTank or 0, seeds = seeds, collapsers = collapsers,
    }, cfg)
    if a.insert and not insert(a.insert) and st.hole ~= "closed" then
        a.work = false  -- no collapser in the bus: a recipe now would be voided
    end
    if st.fault then a.spacetime, a.work = false, false end
    setSpacetime(a.spacetime, atPulse)
    setWork(a.work)
    logOnce("why", a.why)
    lastDecision = a
end

-- A seed/collapser that sits in the bus for too long: nudge the machine into a
-- recipe check, or stop if it vanished without the expected effect.
local function checkPending()
    local p = st.pending
    if not p or dry then return end
    if ms.active then p.since = now() end  -- taken only once the running recipe ends
    if now() - p.since < cfg.timing.catalystTimeout then return end
    local bs, bc = hw:inBus()
    local still = p.kind == "seed" and bs or bc
    if still and still > 0 then
        log("WARN: the machine has not taken the " .. p.kind .. " yet, nudging it.")
        hw:setWork(false)
        os.sleep(0.2)
        hw:setWork(true)
        p.since = now()
    elseif still == 0 then
        st.pending = nil
        if p.kind == "seed" then
            fault("the seed was taken but no pulse came: is the Utility Hatch in PULSE mode and wired to the pulse input?")
        else
            fault("the collapser was taken but the pulses go on: was the hole open at all?")
        end
    end
end

-- ---- the hole -----------------------------------------------------------------

local function onPulse()
    lastPulse = now()
    local fed = heldThisPulse()  -- before the tank read: the level going in
    pollTank()
    if st.hole == "closed" then
        local ours = st.pending and st.pending.kind == "seed"
        model.open(st)
        st.pending = nil
        log("Black hole OPEN at 100%" .. (ours and "." or " (opened by someone else)."))
    end
    local before = st.S
    local result = model.step(st, fed)
    if result == "closed" then
        log("The hole closed by itself after 15 minutes unstable.")
    elseif before and st.S then
        local m0, m1 = model.multiplier(before), model.multiplier(st.S)
        if m1 ~= m0 then log(string.format("Stability %d%%: x%d parallels.", st.S, m1)) end
        if before > 0 and st.S <= 0 then log("WARN: UNSTABLE -- anything running now is voided.") end
    end
    pollMachine()
    decideAndApply(true)
    save(st)
end

local function onClosed()
    local how = (st.pending and st.pending.kind == "collapser") and "collapsed" or "closed"
    model.close(st)
    st.pending = nil
    log("Black hole " .. how .. ".")
    save(st)
end

-- ---- startup ------------------------------------------------------------------

local function waitPulse(seconds)
    local deadline = now() + seconds
    while now() < deadline do
        local ev = { event.pull(deadline - now(), "redstone_changed") }
        if ev[1] and hw:matches("pulse", ev[2], ev[3], ev[6]) and ev[5] > 0 and ev[4] == 0 then
            return true
        end
    end
    return false
end

local function startup()
    if not dry then hw:setSpacetime(false) end
    spacetimeOn = false
    reqLevel = hw:level("request") or 0
    if reqLevel > 0 then lastReqHigh = now() end
    pollTank()
    pollMachine()
    pollStock(true)

    log("Looking for a black hole...")
    local saved = load()
    if not waitPulse(cfg.timing.pulseTimeout + 0.5) then
        model.close(st)
        log("No pulses: the hole is closed.")
    else
        lastPulse = now()
        local elapsed = saved and saved.time and (os.time() - saved.time) / GAME_UNITS_PER_SECOND
        local fresh = saved and (saved.hole == "open" or saved.hole == "unstable")
            and elapsed and elapsed >= 0 and elapsed < 1000
        if fresh then
            for _, k in ipairs(SAVED) do st[k] = saved[k] end
            -- Assume it decayed the whole time we were away: errs low, the safe side.
            st.S = saved.S - math.ceil(elapsed)
            st.stageHeld = st.stageHeld or {}
        end
        local given = tonumber(opts.stability)
        if given then st.S = given end
        if fresh or given then
            st.hole = st.S > 0 and "open" or "unstable"
            log(string.format("A hole is open at about %d%% (%s).", st.S, given and "given" or "restored"))
        else
            st.hole, st.S = "unknown", nil
            log("WARN: a hole is open but its stability is unknown. Treating it as unstable;")
            log("      restart with `main --stability=N` (WAILA shows N) to use it.")
        end
    end

    -- A catalyst left in the bus from before.
    local bs, bc = hw:inBus()
    if bs and bs > 0 and st.hole == "closed" then st.pending = { kind = "seed", since = now() } end
    if bc and bc > 0 and st.hole ~= "closed" then st.pending = { kind = "collapser", since = now() } end
    if bs and bs > 0 and st.hole ~= "closed" then
        log("WARN: a seed is in the input bus while a hole is open -- the machine will waste it.")
    end
    save(st)
end

-- ---- view -------------------------------------------------------------------------

local function buildView()
    local a = lastDecision
    return {
        dryRun = dry, paused = paused, clock = os.date("%H:%M:%S"), fault = st.fault,
        hole = st.hole, S = st.S, mult = model.multiplier(st.S),
        closesIn = st.S and (st.S - model.CLOSE_AT),
        why = a.why, life = a.life, feeding = spacetimeOn,
        tank = lastTank,
        costMod = st.costMod, counter = st.counter, held = st.held, vpHeld = st.vpHeld, spent = st.spent,
        active = ms.active, remaining = ms.remaining, recipeEst = recipeEst(),
        workAllowed = workSet, requested = requested(),
        seeds = seeds, collapsers = collapsers, pending = st.pending and st.pending.kind,
        messages = messages,
    }
end

-- ---- main loop ----------------------------------------------------------------------

local function loop()
    local nextPoll, nextRender = 0, 0
    while true do
        local ev = { event.pull(0.25) }
        local name = ev[1]
        if name == "redstone_changed" then
            local addr, side, old, new, color = ev[2], ev[3], ev[4], ev[5], ev[6]
            if hw:matches("pulse", addr, side, color) and new > 0 and old == 0 then
                onPulse()
            elseif hw:matches("request", addr, side, color) then
                reqLevel = new
                if new > 0 then lastReqHigh = now() end
                decideAndApply()
            end
        elseif name == "key_down" then
            local code = ev[4]
            if code == keyboard.keys.space or code == keyboard.keys.p then
                paused = not paused
                log(paused and "PAUSED: hands off until SPACE." or "Resumed.")
                decideAndApply()
            elseif code == keyboard.keys.q then
                return
            end
        end

        local t = now()
        if t >= nextPoll then
            nextPoll = t + 0.5
            if st.hole ~= "closed" and t - lastPulse > cfg.timing.pulseTimeout then onClosed() end
            reqLevel = hw:level("request") or reqLevel
            if reqLevel > 0 then lastReqHigh = t end
            pollTank()
            pollMachine()
            pollStock()
            checkPending()
            decideAndApply()
        end
        if ui.active and t >= nextRender then
            nextRender = t + 1
            ui.render(buildView())
        end
    end
end

local uiActive = cfg.ui ~= false and ui.init()
log("BHC controller starting" .. (dry and " [DRY RUN: nothing is touched]" or "") .. ".")
startup()
log("SPACE/P pause, Q quit.")
if uiActive then ui.render(buildView()) end

local ok, err = pcall(loop)
if not dry then pcall(hw.setSpacetime, hw, false) end
save(st)
ui.shutdown()
print("BHC controller stopped. Spacetime feed is off; the machine was left as it was.")
if not ok then error(err, 0) end

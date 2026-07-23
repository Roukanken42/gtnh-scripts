-- Power controller: monitors the LSC (and the wireless EU network) and switches
-- generators on/off via redstone using staged thresholds -- as the battery level
-- falls, generators turn on in priority order (cheapest first); as it recovers,
-- they turn off in reverse. Each generator has its own on/off band (hysteresis)
-- so nothing flaps around a single setpoint.
--
-- Run from this folder:  main
-- See config.lua for generators, thresholds, and the dry-run safety switch.

local lsc = require("lsc")
local generators = require("generators")
local bignum = require("bignum")
local util = require("util")
local cfg = require("config")
local ui = require("ui")
local event = require("event")
local computer = require("computer")
local keyboard = require("keyboard")

-- Recent log lines. Shown in the UI's log panel; also printed to the console
-- when the UI is not active.
local messages = {}
local MAX_MESSAGES = 50
local function log(msg)
    local line = "[" .. os.date("%H:%M:%S") .. "] " .. msg
    messages[#messages + 1] = line
    if #messages > MAX_MESSAGES then table.remove(messages, 1) end
    if not ui.active then print(line) end
end

-- One-shot warnings so a config problem is logged once, not every cycle.
local warned = {}
local function warnOnce(key, msg)
    if warned[key] then return end
    warned[key] = true
    log("WARN: " .. msg)
end

local interval = cfg.sleep or 5

local lscDev = select(1, lsc.discover())
local gens = generators.build(cfg, log, computer.uptime())

local paused = false
local showLog = false
local showGraph = false     -- swap the generators table for the history graph (G)
local exceedLogged = false  -- whether the "output exceeds wireless cap" warning is active

-- Rolling history for the graph view, one sample per control cycle.
local history = {}
local MAX_HISTORY = 300

-- Latest snapshot + derived control values (repainted between control cycles).
local lastState = { present = false }
local lastLevel, lastSource = 0, "LSC"
local lastStored, lastMax = "0", "0"

-- ---- control logic -------------------------------------------------------

-- Whether the wireless network counts as part of the energy pool this cycle.
local function wirelessActive(s)
    local mode = cfg.source or "auto"
    return (mode == "wireless") or (mode == "auto" and s.wirelessEnabled == true)
end

local function clamp01(x) return math.max(0, math.min(1, x)) end

-- The energy the controller acts on, as ONE 0..1 level plus its composition and
-- the stored / max digit strings behind it (for the display bar). When wireless
-- is on the pool is added to the LSC (it fills/drains the LSC). A single
-- cfg.max is the "full" reference for whatever the level is made of; nil means
-- the LSC's real capacity. All big-integer maths goes through bignum (values
-- exceed 2^64).
local function computeEnergy(s)
    local maxS = cfg.max ~= nil and bignum.expandSI(cfg.max) or (s.capacityEU or "0")
    if wirelessActive(s) then
        if cfg.max == nil then
            warnOnce("nomax", "wireless is on but cfg.max is nil; using LSC capacity as the ceiling. Set cfg.max.")
        end
        local stored = bignum.add(s.storedEU or "0", s.wirelessEU or "0")
        return clamp01(bignum.ratio(stored, maxS)), "LSC + WIRELESS", stored, maxS
    end
    -- Wireless off. With no configured max, use the game's own fill % (robust to
    -- the capacity-getter clamp); with one, scale stored against it.
    if cfg.max ~= nil then
        return clamp01(bignum.ratio(s.storedEU or "0", maxS)), "LSC", s.storedEU or "0", maxS
    end
    return clamp01(s.fill or 0), "LSC", s.storedEU or "0", s.capacityEU or "0"
end

-- Staged-threshold hysteresis for one generator. on when level <= onBelow, off
-- when level >= offAbove, hold otherwise. minOn keeps a just-started generator on.
local function desiredFor(g, level, now)
    if g.on == nil then                       -- first decision: pick a definite state
        return level <= g.onBelow
    end
    if not g.on then
        return level <= g.onBelow             -- off -> on only at/below onBelow
    end
    if level >= g.offAbove then               -- on -> off at/above offAbove...
        if g.minOn > 0 and (now - (g.since or 0)) < g.minOn then
            return true                       -- ...unless still within its minimum on-time
        end
        return false
    end
    return true                               -- on and within the band -> stay on
end

-- Turns every generator off right now (used on pause; live unless dry-run).
local function haltGenerators()
    local now = computer.uptime()
    for _, g in ipairs(gens) do g:apply(false, now, not cfg.dryRun) end
end

-- One control cycle: read the LSC, compute the level, switch generators.
local cycle = 0
local function runCycle()
    cycle = cycle + 1
    if not lscDev then return end
    local s = lscDev:read()
    lastState = s
    if not s.present then
        log("LSC read failed this cycle.")
        return
    end
    local level, source, stored, maxTot = computeEnergy(s)
    lastLevel, lastSource, lastStored, lastMax = level, source, stored, maxTot

    -- Wireless output cap: sustained output can't exceed threshold / 5min. Warn
    -- (once per crossing) when the 5-min average output is over it.
    if wirelessActive(s) and s.outputCap and (s.euOut or 0) > s.outputCap then
        if not exceedLogged then
            log(string.format("WARNING: output %s EU/t exceeds the wireless cap %s EU/t -- the network can't sustain this.",
                util.human(s.euOut), util.human(s.outputCap)))
            exceedLogged = true
        end
    else
        exceedLogged = false
    end

    -- Record a history sample (kept even while paused, for the graph).
    local online = 0
    for _, g in ipairs(gens) do if g.on then online = online + 1 end end
    history[#history + 1] = { level = level, net = s.net or 0,
        euIn = s.euIn or 0, euOut = s.euOut or 0, online = online }
    if #history > MAX_HISTORY then table.remove(history, 1) end

    if paused then
        haltGenerators()
        return
    end
    local now = computer.uptime()
    local live = not cfg.dryRun
    for _, g in ipairs(gens) do
        local desired = desiredFor(g, level, now)
        if g:apply(desired, now, live) then
            log(string.format("%s -> %s  (%s %.1f%%)%s",
                g.name, desired and "ON" or "OFF", source, level * 100,
                cfg.dryRun and "  [dry run]" or ""))
        end
    end
end

-- Per-generator display status: ON (actively demanded), HOLD (on, coasting
-- through the hysteresis band), OFF.
local function statusFor(g, level)
    if not g.on then return "OFF" end
    if level > g.onBelow then return "HOLD" end
    return "ON"
end

-- Assembles the read-only snapshot the UI renders.
local function buildState()
    local s = lastState or { present = false }
    local now = computer.uptime()

    local gview, online, onlineEU = {}, 0, 0
    for _, g in ipairs(gens) do
        if g.on then online = online + 1; onlineEU = onlineEU + (g.output or 0) end
        gview[#gview + 1] = {
            name = g.name, output = g.output, prio = g.prio,
            onBelow = g.onBelow, offAbove = g.offAbove,
            on = g.on, status = statusFor(g, lastLevel),
            sinceSec = now - (g.since or now),
        }
    end

    return {
        dryRun = cfg.dryRun, paused = paused, showLog = showLog, showGraph = showGraph,
        cycle = cycle, updated = os.date("%H:%M:%S"),
        source = lastSource, level = lastLevel,
        energyStored = lastStored, energyMax = lastMax,
        lsc = s,
        generators = gview,
        totals = { online = online, total = #gens, onlineEU = onlineEU },
        history = history, historyStep = interval,
        messages = messages,
    }
end

-- ---- startup -------------------------------------------------------------
local uiActive = (cfg.ui ~= false) and ui.init()

if not lscDev then
    log("No supercapacitor found. Place an Adapter touching the LSC (try `probe`).")
else
    log("LSC found at " .. lscDev.address)
end
log(string.format("Power controller started -- %d generator(s), source=%s, %ds cycle%s",
    #gens, cfg.source or "auto", interval, cfg.dryRun and "  [DRY RUN]" or ""))
log("Keys: SPACE/P pause (all generators off), G graph, L log panel.")
for _, g in ipairs(gens) do
    log(string.format("  %s  side=%d%s  %s EU/t  p%d  on<=%d%% off>=%d%%",
        g.name, g.side, g.color and (" color=" .. g.color) or "",
        tostring(g.output), g.prio,
        math.floor(g.onBelow * 100 + 0.5), math.floor(g.offAbove * 100 + 0.5)))
end

local PAUSE_KEYS = { [keyboard.keys.space] = true, [keyboard.keys.p] = true }

local tick = 0
local lastToggle = -1

-- Repaint from the cached snapshot -- no hardware reads (those happen only on the
-- control cycle, since getSensorInformation() is expensive). A no-op when headless.
local function draw()
    if not uiActive then return end
    tick = tick + 1
    local st = buildState()
    st.tick = tick
    ui.render(st)
end

-- Read + decide + repaint, timed. If any phase blocks for more than a second
-- (the freezes we're chasing), log which one so we can find the culprit.
local function cycle()
    local t0 = computer.uptime()
    runCycle()
    local t1 = computer.uptime()
    draw()
    local t2 = computer.uptime()
    if t2 - t0 > 1 then
        log(string.format("SLOW cycle: read %.1fs, draw %.1fs", t1 - t0, t2 - t1))
    end
end

-- Single cadence: cycle once per control interval, and repaint immediately on a
-- key press. event.pull wakes on either the next cycle deadline or a keypress,
-- so the UI stays responsive without a separate draw timer.
local function loop()
    cycle()
    local nextCycle = computer.uptime() + interval
    while true do
        local timeout = nextCycle - computer.uptime()
        if timeout < 0 then timeout = 0 end
        local w0 = computer.uptime()
        local _, _, _, code = event.pull(timeout, "key_down")
        local over = (computer.uptime() - w0) - timeout
        if over > 1 then log(string.format("SLOW wait: event.pull overran by %.1fs", over)) end
        if code and computer.uptime() - lastToggle >= 0.3 then
            if PAUSE_KEYS[code] then
                lastToggle = computer.uptime()
                paused = not paused
                if paused then
                    log("PAUSED by user -- all generators off. Press SPACE to resume.")
                    haltGenerators()
                else
                    log("RESUMED by user.")
                    nextCycle = computer.uptime() -- re-decide immediately
                end
                draw()
            elseif code == keyboard.keys.g then
                lastToggle = computer.uptime()
                showGraph = not showGraph
                draw()
            elseif code == keyboard.keys.l then
                lastToggle = computer.uptime()
                showLog = not showLog
                draw()
            end
        end
        if computer.uptime() >= nextCycle then
            cycle()
            nextCycle = computer.uptime() + interval
        end
    end
end

-- Restore the screen on exit (including Ctrl-C, which surfaces as an error).
-- NOTE: redstone outputs are deliberately LEFT AS-IS on exit -- we do not force
-- generators off, since cutting power on a crash/quit could brown out the base.
-- Only an explicit pause turns them off.
local ok, err = pcall(loop)
ui.shutdown()
if not ok then error(err, 0) end

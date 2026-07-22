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
local uiRefresh = math.max(cfg.uiRefresh or 1, 0.1)

local lscDev = select(1, lsc.discover())
local gens = generators.build(cfg, log, computer.uptime())

local paused = false
local showLog = false

-- Latest snapshot + derived control values (repainted between control cycles).
local lastState = { present = false }
local lastLevel, lastSource = 0, "LSC"

-- ---- control logic -------------------------------------------------------

-- Wireless pool level, scaled to 0..1 against the configured operating band.
-- All big-integer maths goes through bignum (the pool exceeds 2^64). Returns
-- level plus the resolved min/max digit strings (for display).
local function wirelessLevel(s)
    local minS = bignum.expandSI((cfg.wireless and cfg.wireless.min) or "0")
    local maxS = bignum.expandSI((cfg.wireless and cfg.wireless.max) or "0")
    if bignum.cmp(maxS, minS) <= 0 then return 0, minS, maxS end
    local rMax = bignum.ratio(s.wirelessEU or "0", maxS) -- pool / max
    local rMin = bignum.ratio(minS, maxS)                -- min  / max
    local level = (rMax - rMin) / (1 - rMin)
    return math.max(0, math.min(1, level)), minS, maxS
end

-- The single 0..1 level the controller thresholds against, plus which source it
-- came from. Auto follows the LSC's wireless mode.
local function computeLevel(s)
    local mode = cfg.source or "auto"
    local useWireless = (mode == "wireless") or (mode == "auto" and s.wirelessEnabled == true)
    if useWireless then
        local minS = bignum.expandSI((cfg.wireless and cfg.wireless.min) or "0")
        local maxS = bignum.expandSI((cfg.wireless and cfg.wireless.max) or "0")
        if bignum.cmp(maxS, minS) <= 0 then
            warnOnce("wl-band", "cfg.wireless max <= min; controlling on LSC fill % instead.")
            return s.fill or 0, "LSC"
        end
        return (wirelessLevel(s)), "WIRELESS"
    end
    return s.fill or 0, "LSC"
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
    local level, source = computeLevel(s)
    lastLevel, lastSource = level, source
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
    local wl, minS, maxS = wirelessLevel(s)

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
        dryRun = cfg.dryRun, paused = paused, showLog = showLog,
        cycle = cycle, updated = os.date("%H:%M:%S"),
        source = lastSource, level = lastLevel,
        lsc = s,
        wireless = { level = wl, poolEU = s.wirelessEU, min = minS, max = maxS },
        generators = gview,
        totals = { online = online, total = #gens, onlineEU = onlineEU },
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
log("Press SPACE (or P) to pause/resume (all generators off); L to toggle the log panel.")
for _, g in ipairs(gens) do
    log(string.format("  %s  side=%d%s  %s EU/t  p%d  on<=%d%% off>=%d%%",
        g.name, g.side, g.color and (" color=" .. g.color) or "",
        tostring(g.output), g.prio,
        math.floor(g.onBelow * 100 + 0.5), math.floor(g.offAbove * 100 + 0.5)))
end

local PAUSE_KEYS = { [keyboard.keys.space] = true, [keyboard.keys.p] = true }

local tick = 0
local lastToggle = -1

local function refresh()
    if not uiActive then return end
    if lscDev then
        lastState = lscDev:read()
        if lastState.present then lastLevel, lastSource = computeLevel(lastState) end
    end
    tick = tick + 1
    local st = buildState()
    st.tick = tick
    ui.render(st)
end

local function loop()
    local nextCycle = computer.uptime()
    local nextRefresh = computer.uptime()
    while true do
        local t = computer.uptime()
        if t >= nextCycle then
            runCycle()
            nextCycle = computer.uptime() + interval
            refresh()
            nextRefresh = computer.uptime() + uiRefresh
        elseif uiActive and t >= nextRefresh then
            refresh()
            nextRefresh = computer.uptime() + uiRefresh
        end

        local wake = uiActive and math.min(nextCycle, nextRefresh) or nextCycle
        local timeout = wake - computer.uptime()
        if timeout > 0 then
            local _, _, _, code = event.pull(timeout, "key_down")
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
                    refresh()
                elseif code == keyboard.keys.l then
                    lastToggle = computer.uptime()
                    showLog = not showLog
                    refresh()
                end
            end
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

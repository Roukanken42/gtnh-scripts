-- Terminal dashboard for the power controller. Pure display: it renders a state
-- table handed to it by main.lua and knows nothing about the control logic.
--
-- Falls back to a no-op (ui.active == false) when there is no GPU/screen, so the
-- controller still runs headless. Double-buffered so periodic refreshes do not
-- flicker. Toolkit (palette, helpers, box/panel/bar/kpiCard, human/dur,
-- lifecycle) mirrors pump/ui.lua; humanBig() is added for EU values past 2^64.
--
-- State contract (all fields optional-safe):
--   dryRun, paused, showLog  booleans
--   cycle, tick              integers   (tick drives the spinner)
--   updated                  string     "HH:MM:SS"
--   source                   "LSC" | "WIRELESS"   -- active control source
--   level                    0..1       -- effective control level
--   lsc = { present, fill (0..1), storedEU, capacityEU (digit strings),
--           euInPerTick, euOutPerTick, passiveLoss, net (EU/t numbers),
--           wirelessEnabled, wirelessEU (digit string),
--           timeToFull, timeToEmpty (seconds|nil), maintenance, active }
--   wireless = { level (0..1), poolEU, min, max (digit strings) }
--   generators = { { name, output (num), prio, onBelow, offAbove,
--                    on (bool|nil), status "ON"|"OFF"|"HOLD", sinceSec }, ... }
--   totals = { online, total, onlineEU }
--   messages = { "HH:MM:SS  text", ... }   -- newest last

local component = require("component")

local ui = { active = false }

local gpu
local W, H
local origW, origH, origDepth
local buffer

-- ---- palette -------------------------------------------------------------
local C = {
    bg      = 0x0B0B12,
    panel   = 0x15151F,
    panelHi = 0x24243A,
    border  = 0x3A3A5C,
    accent  = 0x22D3EE,
    accent2 = 0x8B7BFF,
    text    = 0xE6E6F0,
    dim     = 0x9090A8,
    faint   = 0x585870,
    good    = 0x3BD671,
    warn    = 0xF2C94C,
    crit    = 0xFF5C5C,
    pump    = 0x38A6FF,
    titleBg = 0x161634,
    white   = 0xFFFFFF,
    black   = 0x000000,
}

-- Unicode as UTF-8 byte escapes (Lua 5.2/5.3 safe).
local BOX = {
    tl = "\xE2\x94\x8C", tr = "\xE2\x94\x90", bl = "\xE2\x94\x94",
    br = "\xE2\x94\x98", h = "\xE2\x94\x80", v = "\xE2\x94\x82",
}
local EIGHTHS = {
    "\xE2\x96\x8F", "\xE2\x96\x8E", "\xE2\x96\x8D", "\xE2\x96\x8C",
    "\xE2\x96\x8B", "\xE2\x96\x8A", "\xE2\x96\x89",
}
local ARROW = "\xE2\x96\xB8"
local MIDDOT = "\xC2\xB7"
local EMDASH = "\xE2\x80\x94"
local SPIN = { "|", "/", "-", "\\" }

-- ---- low-level drawing ---------------------------------------------------
local function setfg(c) gpu.setForeground(c, false) end
local function setbg(c) gpu.setBackground(c, false) end

local function rect(x, y, w, h, color)
    if w < 1 or h < 1 then return end
    setbg(color)
    gpu.fill(x, y, w, h, " ")
end

local function text(x, y, s, fgc, bgc)
    if bgc then setbg(bgc) end
    if fgc then setfg(fgc) end
    gpu.set(x, y, s)
end

local function trunc(s, w)
    s = tostring(s)
    if #s > w then return s:sub(1, w) end
    return s
end
local function padR(s, w) s = trunc(s, w); return s .. string.rep(" ", w - #s) end
local function padL(s, w) s = trunc(s, w); return string.rep(" ", w - #s) .. s end

local HUMAN_PREFIX = { "k", "M", "G", "T", "P", "E", "Z", "Y", "R", "Q" }

-- SI-style magnitude for a Lua number (<= ~5 chars). Used for the small EU/t rates.
local function human(n)
    n = n or 0
    local a = math.abs(n)
    if a < 1e3 then return string.format("%.0f", n) end
    local div, tier = 1e3, 1
    while tier < #HUMAN_PREFIX and a >= div * 1e3 do
        div = div * 1e3; tier = tier + 1
    end
    local scaled = n / div
    if math.abs(scaled) >= 999.5 and tier < #HUMAN_PREFIX then
        tier = tier + 1; scaled = n / (div * 1e3)
    end
    local mag = math.abs(scaled)
    local fmt = (mag < 10 and "%.2f%s") or (mag < 100 and "%.1f%s") or "%.0f%s"
    return string.format(fmt, scaled, HUMAN_PREFIX[tier])
end

-- SI magnitude for a big-integer DIGIT STRING (works past 2^64, where `human`
-- would lose precision). Chooses the prefix from the string length so e.g. a
-- 19-digit number renders "9.22E". Beyond quetta (1e30) it falls back to "d.dde<n>".
local function humanBig(s)
    local digits = tostring(s or "0"):gsub("%D", ""):gsub("^0+", "")
    if digits == "" then return "0" end
    local L = #digits
    if L <= 3 then return digits end
    local tier = math.floor((L - 1) / 3)                -- 0=none,1=k,2=M,...
    local PRE = { "", "k", "M", "G", "T", "P", "E", "Z", "Y", "R", "Q" }
    if tier >= #PRE then
        return digits:sub(1, 1) .. "." .. digits:sub(2, 3) .. "e" .. (L - 1)
    end
    local intLen = L - 3 * tier                         -- 1..3 leading digits
    local intPart = digits:sub(1, intLen)
    local suffix = PRE[tier + 1]
    if intLen == 3 then return intPart .. suffix end
    return intPart .. "." .. digits:sub(intLen + 1, 3) .. suffix
end

-- Compact duration: 45s / 12m / 3h20m / 2d5h. "--" for non-finite.
local function dur(s)
    s = s or 0
    if s ~= s or s == math.huge or s < 0 then return "--" end
    s = math.floor(s + 0.5)
    if s < 60 then return s .. "s" end
    local m = math.floor(s / 60)
    if m < 60 then local r = s % 60; return r > 0 and (m .. "m" .. r .. "s") or (m .. "m") end
    local h = math.floor(m / 60)
    if h < 24 then local r = m % 60; return r > 0 and (h .. "h" .. r .. "m") or (h .. "h") end
    local d = math.floor(h / 24); local r = h % 24
    return r > 0 and (d .. "d" .. r .. "h") or (d .. "d")
end

local function box(x, y, w, h, borderColor, fillColor)
    rect(x, y, w, h, fillColor)
    setfg(borderColor); setbg(fillColor)
    gpu.set(x, y, BOX.tl .. string.rep(BOX.h, w - 2) .. BOX.tr)
    gpu.set(x, y + h - 1, BOX.bl .. string.rep(BOX.h, w - 2) .. BOX.br)
    for i = 1, h - 2 do
        gpu.set(x, y + i, BOX.v)
        gpu.set(x + w - 1, y + i, BOX.v)
    end
end

local function panel(x, y, w, h, title, titleColor)
    box(x, y, w, h, C.border, C.panel)
    if title then text(x + 2, y, " " .. title .. " ", titleColor or C.accent, C.panel) end
end

-- Horizontal bar with sub-cell precision.
local function bar(x, y, w, frac, cFill, cEmpty)
    frac = math.max(0, math.min(1, frac or 0))
    local units = frac * w
    local full = math.floor(units)
    rect(x, y, w, 1, cEmpty)
    if full > 0 then rect(x, y, full, 1, cFill) end
    local rem = units - full
    if full < w and rem > 0 then
        local idx = math.floor(rem * 8)
        if idx >= 1 then text(x + full, y, EIGHTHS[idx], cFill, cEmpty) end
    end
end

local function rgb(c) return math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256 end
local function lerpColor(a, b, t)
    t = t < 0 and 0 or t > 1 and 1 or t
    local ar, ag, ab = rgb(a)
    local br, bg, bb = rgb(b)
    return math.floor(ar + (br - ar) * t + 0.5) * 65536
        + math.floor(ag + (bg - ag) * t + 0.5) * 256
        + math.floor(ab + (bb - ab) * t + 0.5)
end

local FILL_RAMP = { C.crit, 0xFF8A5C, C.warn, 0xB6D94C, C.good }
local function fillColor(frac)
    frac = frac < 0 and 0 or frac > 1 and 1 or frac
    local n = #FILL_RAMP
    local pos = frac * (n - 1)
    local i = math.floor(pos)
    if i >= n - 1 then return FILL_RAMP[n] end
    return lerpColor(FILL_RAMP[i + 1], FILL_RAMP[i + 2], pos - i)
end

local STATUS_COLOR = { ON = C.good, OFF = C.faint, HOLD = C.warn }

-- ---- lifecycle -----------------------------------------------------------
function ui.available()
    return component.isAvailable("gpu") and component.isAvailable("screen")
end

function ui.init()
    if not ui.available() then
        ui.active = false
        return false
    end
    gpu = component.gpu
    origDepth = gpu.getDepth()
    origW, origH = gpu.getResolution()
    local mw, mh = gpu.maxResolution()
    W = math.min(mw, 160)
    H = math.min(mh, 50)
    pcall(gpu.setDepth, gpu.maxDepth())
    gpu.setResolution(W, H)

    buffer = nil
    if gpu.allocateBuffer ~= nil then
        local ok, idx = pcall(gpu.allocateBuffer, W, H)
        if ok and idx then buffer = idx end
    end
    if buffer then gpu.setActiveBuffer(buffer) end
    rect(1, 1, W, H, C.bg)
    if buffer then gpu.bitblt(0, 1, 1, W, H, buffer, 1, 1) end
    ui.active = true
    return true
end

function ui.shutdown()
    if not ui.active then return end
    if buffer then
        pcall(gpu.setActiveBuffer, 0)
        pcall(gpu.freeBuffer, buffer)
        buffer = nil
    end
    setbg(C.black); setfg(C.white)
    pcall(gpu.setResolution, origW, origH)
    pcall(gpu.setDepth, origDepth)
    gpu.fill(1, 1, origW, origH, " ")
    gpu.set(1, 1, "")
    ui.active = false
end

-- ---- sections ------------------------------------------------------------
local function drawTitle(state)
    rect(1, 1, W, 1, C.titleBg)
    local titleStr = " POWER CONTROLLER"
    text(2, 1, titleStr, C.accent, C.titleBg)
    text(2 + #titleStr + 2, 1, "[SPACE] pause  [L] log", C.faint, C.titleBg)

    local badge, badgeColor
    if state.paused then
        badge, badgeColor = " PAUSED ", C.crit
    elseif state.dryRun then
        badge, badgeColor = " DRY RUN ", C.warn
    else
        badge, badgeColor = " LIVE ", C.good
    end
    local spin = SPIN[(state.tick or state.cycle or 0) % #SPIN + 1]
    local info = string.format("%s  cycle #%d  %s  ", spin, state.cycle or 0, state.updated or "--:--:--")
    local rightX = W - 1 - #badge - #info
    text(rightX, 1, info, C.dim, C.titleBg)
    text(rightX + #info, 1, badge, C.black, badgeColor)
end

local function kpiCard(x, y, w, label, value, valueColor, sub, subColor)
    box(x, y, w, 4, C.border, C.panel)
    text(x + 2, y + 1, padR(label, w - 4), C.dim, C.panel)
    text(x + 2, y + 2, padR(value, w - 4), valueColor or C.text, C.panel)
    if sub then text(x + 2, y + 3, padR(sub, w - 4), subColor or C.faint, C.panel) end
end

local function drawKPIs(state, y)
    local lsc = state.lsc or {}
    local t = state.totals or {}
    local n = 6
    local gap = 1
    local w = math.floor((W - 2 - (n - 1) * gap) / n)
    local x = 2

    local fill = lsc.fill or 0
    kpiCard(x, y, w, "BATTERY (LSC)", string.format("%.1f%%", fill * 100), fillColor(fill),
        humanBig(lsc.storedEU) .. " EU"); x = x + w + gap
    kpiCard(x, y, w, "EU IN", human(lsc.euInPerTick or 0) .. "/t", C.good); x = x + w + gap
    kpiCard(x, y, w, "EU OUT", human(lsc.euOutPerTick or 0) .. "/t", C.pump); x = x + w + gap

    local net = lsc.net or 0
    kpiCard(x, y, w, "NET FLOW",
        (net >= 0 and "+" or "-") .. human(math.abs(net)) .. "/t", net >= 0 and C.good or C.crit,
        net > 0 and "charging" or net < 0 and "draining" or "steady"); x = x + w + gap

    local timeVal, timeSub
    if (lsc.timeToFull or 0) > 0 then
        timeVal, timeSub = dur(lsc.timeToFull), "to full"
    elseif (lsc.timeToEmpty or 0) > 0 then
        timeVal, timeSub = dur(lsc.timeToEmpty), "to EMPTY"
    else
        timeVal, timeSub = "--", nil
    end
    kpiCard(x, y, w, "TIME", timeVal, C.accent, timeSub,
        timeSub == "to EMPTY" and C.crit or C.faint); x = x + w + gap

    kpiCard(x, y, w, "GEN ONLINE", (t.online or 0) .. " / " .. (t.total or 0), C.accent2,
        human(t.onlineEU or 0) .. "/t")
end

-- Two stacked source bars (LSC + wireless); the active control source is starred.
local function drawPower(state, x, y, w, h)
    local src = state.source or "LSC"
    panel(x, y, w, h, "POWER  " .. EMDASH .. "  CONTROL: " .. src, C.accent)
    local lsc = state.lsc or {}
    local wl = state.wireless or {}
    local innerX = x + 2
    local labelW = 10
    local pctW = 7
    local infoW = 26
    local barW = math.max(w - 4 - labelW - pctW - infoW - 3, 10)
    local barX = innerX + labelW

    local function row(ry, name, active, frac, pctStr, info, infoColor)
        local nameColor = active and C.accent or C.dim
        text(innerX, ry, padR((active and (ARROW .. " ") or "  ") .. name, labelW), nameColor, C.panel)
        bar(barX, ry, barW, frac, fillColor(frac), C.panelHi)
        text(barX + barW + 1, ry, padL(pctStr, pctW), fillColor(frac), C.panel)
        text(barX + barW + 1 + pctW + 1, ry, padR(info, infoW), infoColor or C.dim, C.panel)
    end

    local fill = lsc.fill or 0
    row(y + 2, "LSC", src == "LSC", fill, string.format("%.1f%%", fill * 100),
        humanBig(lsc.storedEU) .. " / " .. humanBig(lsc.capacityEU) .. " EU")

    local wlFrac = wl.level or 0
    local mode = lsc.wirelessEnabled and "on" or "off"
    row(y + 4, "WIRELESS", src == "WIRELESS", wlFrac, string.format("%.1f%%", wlFrac * 100),
        humanBig(wl.poolEU) .. " EU  [" .. mode .. "]")

    if lsc.maintenance and not lsc.maintenance:find("perfect", 1, true) then
        text(innerX, y + 5, trunc("Maintenance: " .. lsc.maintenance, w - 4), C.warn, C.panel)
    end
end

local function drawGenerators(state, x, y, w, h)
    local gens = state.generators or {}
    panel(x, y, w, h, "GENERATORS  " .. #gens .. " configured", C.accent)
    local innerX = x + 2
    if #gens == 0 then
        text(innerX, y + 2, "No generators in config.lua.", C.faint, C.panel)
        return
    end

    -- Columns: NAME  OUTPUT  PRIO  ON%-OFF%  STATUS  FOR
    local cName, cOut, cPrio, cBand, cStatus, cFor = 0, 18, 27, 33, 45, 53
    local hy = y + 1
    text(innerX + cName, hy, "GENERATOR", C.faint, C.panel)
    text(innerX + cOut, hy, "OUTPUT", C.faint, C.panel)
    text(innerX + cPrio, hy, "PRIO", C.faint, C.panel)
    text(innerX + cBand, hy, "ON%-OFF%", C.faint, C.panel)
    text(innerX + cStatus, hy, "STATUS", C.faint, C.panel)
    text(innerX + cFor, hy, "FOR", C.faint, C.panel)

    local rowsAvail = h - 3
    for i, g in ipairs(gens) do
        if i > rowsAvail then break end
        local ry = y + 1 + i
        local st = g.status or (g.on and "ON" or "OFF")
        local stColor = STATUS_COLOR[st] or C.dim
        text(innerX + cName, ry, padR(g.name, cOut - cName - 1), C.text, C.panel)
        text(innerX + cOut, ry, padR(human(g.output or 0) .. "/t", cPrio - cOut - 1), C.dim, C.panel)
        text(innerX + cPrio, ry, padR("p" .. tostring(g.prio or 0), cBand - cPrio - 1), C.faint, C.panel)
        text(innerX + cBand, ry, padR(string.format("%d%%-%d%%",
            math.floor((g.onBelow or 0) * 100 + 0.5), math.floor((g.offAbove or 0) * 100 + 0.5)),
            cStatus - cBand - 1), C.dim, C.panel)
        text(innerX + cStatus, ry, padR(st, cFor - cStatus - 1), stColor, C.panel)
        text(innerX + cFor, ry, dur(g.sinceSec or 0), C.faint, C.panel)
    end
end

local function drawLog(state, x, y, w, h)
    panel(x, y, w, h, "LOG")
    local msgs = state.messages or {}
    local lines = h - 2
    local start = math.max(1, #msgs - lines + 1)
    local r = y + 1
    for i = start, #msgs do
        text(x + 2, r, trunc(msgs[i], w - 4), C.dim, C.panel)
        r = r + 1
    end
end

function ui.render(state)
    if not ui.active then return end
    if buffer then gpu.setActiveBuffer(buffer) end

    rect(1, 1, W, H, C.bg)
    drawTitle(state)
    local kpiY = 3
    drawKPIs(state, kpiY)

    local contentY = kpiY + 5
    local powerH = 7
    local logH = state.showLog and 8 or 0
    local logY = H - logH + 1
    local genY = contentY + powerH + 1
    local genBottom = state.showLog and (logY - 2) or H
    local genH = genBottom - genY + 1

    drawPower(state, 2, contentY, W - 2, powerH)
    drawGenerators(state, 2, genY, W - 2, genH)
    if state.showLog then drawLog(state, 2, logY, W - 2, logH) end

    if buffer then gpu.bitblt(0, 1, 1, W, H, buffer, 1, 1) end
end

return ui

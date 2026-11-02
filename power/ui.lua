-- Terminal dashboard for the power controller. Pure display: it renders a state
-- table handed to it by main.lua and knows nothing about the control logic.
--
-- Falls back to a no-op (ui.active == false) when there is no GPU/screen, so the
-- controller still runs headless. Double-buffered so periodic refreshes do not
-- flicker. Toolkit (palette, helpers, box/panel/bar/kpiCard, human/dur,
-- lifecycle) mirrors pump/ui.lua; humanBig() is added for EU values past 2^64.
--
-- State contract (all fields optional-safe):
--   dryRun, paused, showLog, showGraph  booleans
--   cycle, tick              integers   (tick drives the spinner)
--   updated                  string     "HH:MM:SS"
--   history = { { level (0..1), net (EU/t) }, ... }  -- oldest first
--   historyStep              seconds between history samples
--   source                   "LSC" | "LSC + WIRELESS"   -- energy composition
--   level                    0..1       -- effective control level (the bar)
--   energyStored, energyMax  digit strings behind the bar (LSC, +wireless if on)
--   lsc = { present, fill (0..1), storedEU, capacityEU (digit strings),
--           euIn, euOut, passiveLoss, net (EU/t numbers, 5-min averaged),
--           wirelessEnabled, wirelessEU (digit string),
--           outputCap (EU/t number|nil), capacitors, wirelessThreshold,
--           timeToFull, timeToEmpty (seconds|nil), maintenance, active }
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
local function clamp01(v) return v < 0 and 0 or v > 1 and 1 or v end

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

-- Compact duration, two largest units: 45s / 12m / 3h20m / 2d5h / 41y33d.
-- "--" for non-finite. Goes up to years so huge fill/drain ETAs stay readable.
local function dur(s)
    s = s or 0
    if s ~= s or s == math.huge or s < 0 then return "--" end
    s = math.floor(s + 0.5)
    if s < 60 then return s .. "s" end
    local m = math.floor(s / 60)
    if m < 60 then local r = s % 60; return r > 0 and (m .. "m" .. r .. "s") or (m .. "m") end
    local h = math.floor(m / 60)
    if h < 24 then local r = m % 60; return r > 0 and (h .. "h" .. r .. "m") or (h .. "h") end
    local d = math.floor(h / 24)
    if d < 365 then local r = h % 24; return r > 0 and (d .. "d" .. r .. "h") or (d .. "d") end
    local y = math.floor(d / 365); local r = d % 365
    return r > 0 and (y .. "y" .. r .. "d") or (y .. "y")
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
    text(2 + #titleStr + 2, 1, "[SPACE] pause  [G] graph  [L] log", C.faint, C.titleBg)

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
    local n = 7
    local gap = 1
    local w = math.floor((W - 2 - (n - 1) * gap) / n)
    local x = 2

    local level = state.level or 0
    kpiCard(x, y, w, "ENERGY", string.format("%.1f%%", level * 100), fillColor(level),
        humanBig(state.energyStored) .. " EU"); x = x + w + gap
    kpiCard(x, y, w, "EU IN 5m", human(lsc.euIn or 0) .. "/t", C.good); x = x + w + gap
    kpiCard(x, y, w, "EU OUT 5m", human(lsc.euOut or 0) .. "/t", C.pump); x = x + w + gap

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
        human(t.onlineEU or 0) .. "/t"); x = x + w + gap

    -- Wireless sustained-output cap (threshold / 5min); "--" when not applicable.
    local wireless = (state.source or ""):find("WIRELESS", 1, true) ~= nil
    local cap = lsc.outputCap
    if wireless and cap then
        local exceed = (lsc.euOut or 0) > cap
        kpiCard(x, y, w, "WL OUT CAP", human(cap) .. "/t", exceed and C.crit or C.good,
            exceed and "OVER CAP" or "ok", exceed and C.crit or C.faint)
    else
        kpiCard(x, y, w, "WL OUT CAP", "--", C.faint, "wireless off")
    end
end

-- One energy bar: LSC alone, or LSC + wireless pool when wireless is on. Also
-- shows the wireless sustained-output cap (threshold / 5min) and warns if the
-- average output is exceeding it.
local function drawPower(state, x, y, w, h)
    local src = state.source or "LSC"
    local lsc = state.lsc or {}
    local wireless = src:find("WIRELESS", 1, true) ~= nil
    local cap = lsc.outputCap
    local out = lsc.euOut or 0
    local exceed = wireless and cap and out > cap

    local title = "ENERGY  " .. EMDASH .. "  " .. src
    if exceed then title = title .. "   !! OUTPUT EXCEEDS WIRELESS CAP" end
    panel(x, y, w, h, title, exceed and C.crit or C.accent)

    local innerX = x + 2
    local level = state.level or 0
    local labelW = 8
    local pctW = 8
    local barX = innerX + labelW
    local barW = math.max(w - 4 - labelW - pctW - 1, 10)

    text(innerX, y + 2, padR("LEVEL", labelW), C.dim, C.panel)
    bar(barX, y + 2, barW, level, fillColor(level), C.panelHi)
    text(barX + barW + 1, y + 2, padL(string.format("%.1f%%", level * 100), pctW), fillColor(level), C.panel)

    local info = humanBig(state.energyStored) .. " / " .. humanBig(state.energyMax) .. " EU"
    local mode = lsc.wirelessEnabled and "wireless ON" or "wireless off"
    text(innerX, y + 4, info, C.text, C.panel)
    text(innerX + #info + 3, y + 4, mode, lsc.wirelessEnabled and C.good or C.faint, C.panel)
    if lsc.maintenance and lsc.maintenance ~= "ok" then
        local mtext = "  " .. MIDDOT .. "  " .. lsc.maintenance
        text(innerX + #info + 3 + #mode, y + 4, trunc(mtext, w - 4 - #info - 3 - #mode), C.warn, C.panel)
    end

    -- Wireless sustained-output cap line (only meaningful when wireless is on).
    if wireless and cap then
        local capText = string.format("Wireless output cap %s EU/t   (avg out %s/t)", human(cap), human(out))
        text(innerX, y + 5, trunc(capText, w - 4), exceed and C.crit or C.dim, C.panel)
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

-- Braille canvas: each character cell is a 2x4 dot matrix, so a plot gets 2x the
-- horizontal and 4x the vertical resolution of the cell grid. Sub-pixel origin is
-- top-left. One colour per cell (last writer wins).
local BR = { [0] = { [0] = 0x01, [1] = 0x02, [2] = 0x04, [3] = 0x40 },
             [1] = { [0] = 0x08, [1] = 0x10, [2] = 0x20, [3] = 0x80 } }
local function canvasNew(cols, rows) return { cols = cols, rows = rows, mask = {}, col = {} } end
local function canvasSet(cvs, px, py, color)
    if px < 0 or py < 0 then return end
    local cc, cr = math.floor(px / 2), math.floor(py / 4)
    if cc >= cvs.cols or cr >= cvs.rows then return end
    local bit = BR[px % 2][py % 4]
    local idx = cr * cvs.cols + cc
    local m = cvs.mask[idx] or 0
    if math.floor(m / bit) % 2 == 0 then cvs.mask[idx] = m + bit end
    cvs.col[idx] = color
end
local function canvasBlit(cvs, x0, y0)
    for cr = 0, cvs.rows - 1 do
        for cc = 0, cvs.cols - 1 do
            local idx = cr * cvs.cols + cc
            local m = cvs.mask[idx]
            if m and m > 0 then
                -- U+2800 + mask, encoded as 3-byte UTF-8.
                text(x0 + cc, y0 + cr,
                    string.char(0xE2, 0xA0 + math.floor(m / 64), 0x80 + m % 64),
                    cvs.col[idx] or C.text, C.panel)
            end
        end
    end
end

-- Historical view (toggle: G). Two stacked bands sharing the time axis -- energy
-- level % as a filled area, and net flow as points around a zero baseline
-- (position = charge/drain sign). Two scales, so two charts, not a dual axis;
-- position is the primary channel in both, so colour is secondary. Both are drawn
-- on braille canvases for sub-cell precision.
local function drawGraph(state, x, y, w, h)
    local hist = state.history or {}
    panel(x, y, w, h, "HISTORY  " .. EMDASH .. "  ENERGY %  " .. MIDDOT .. "  NET EU/t", C.accent)
    local innerX = x + 2
    local top = y + 1
    local axisRow = y + h - 2

    if #hist < 2 then
        text(innerX, top + 1, "Collecting history...", C.faint, C.panel)
        return
    end

    local labW = 7
    local plotX = innerX + labW
    local plotW = (w - 4) - labW
    if plotW < 4 or (axisRow - top) < 4 then
        text(innerX, top + 1, "Window too small for the graph.", C.faint, C.panel)
        return
    end

    -- 2 sub-columns per cell -> twice as many datapoints across the width.
    local subCols = plotW * 2
    local shown = math.min(#hist, subCols)
    local first = #hist - shown + 1
    local function subX(i) return subCols - shown + (i - first) end -- newest at right

    -- Split the height: energy band (top), a gap row, net band, x-axis row.
    local avail = axisRow - top
    local eH = math.max(3, math.floor(avail * 0.55))
    local nH = avail - eH - 1
    if nH < 3 then eH = avail; nH = 0 end
    local eBase = top + eH - 1
    local eMid = math.floor((top + eBase) / 2)

    -- ENERGY: filled area (fill from the bottom up to level * height).
    text(innerX, top, padL("100%", labW - 1), C.faint, C.panel)
    text(innerX, eMid, padL("50%", labW - 1), C.faint, C.panel)
    text(innerX, eBase, padL("0%", labW - 1), C.faint, C.panel)
    local eRows = eH * 4
    local eCanvas = canvasNew(plotW, eH)
    for i = first, #hist do
        local lvl = clamp01(hist[i].level or 0)
        local fillPx = math.floor(lvl * eRows + 0.5)
        local col = fillColor(lvl)
        local px = subX(i)
        for p = 0, fillPx - 1 do canvasSet(eCanvas, px, eRows - 1 - p, col) end
    end
    canvasBlit(eCanvas, plotX, top)

    -- NET: points around a zero baseline, peak-scaled, green up / red down.
    if nH > 0 then
        local nTop = eBase + 2
        local nBase = nTop + nH - 1
        local nRows = nH * 4
        local nMidPx = math.floor(nRows / 2)
        local midCell = nTop + math.floor(nMidPx / 4)
        local peak = 1
        for i = first, #hist do
            local a = math.abs(hist[i].net or 0)
            if a > peak then peak = a end
        end
        for cx = plotX, plotX + plotW - 1 do text(cx, midCell, BOX.h, C.faint, C.panel) end
        text(innerX, nTop, padL("+" .. human(peak), labW - 1), C.good, C.panel)
        text(innerX, midCell, padL("0", labW - 1), C.faint, C.panel)
        text(innerX, nBase, padL("-" .. human(peak), labW - 1), C.crit, C.panel)
        local nCanvas = canvasNew(plotW, nH)
        for i = first, #hist do
            local v = hist[i].net or 0
            local frac = math.max(-1, math.min(1, v / peak))
            local py = nMidPx - math.floor(frac * nMidPx + 0.5)
            if py < 0 then py = 0 elseif py > nRows - 1 then py = nRows - 1 end
            canvasSet(nCanvas, subX(i), py, v >= 0 and C.good or C.crit)
        end
        canvasBlit(nCanvas, plotX, nTop)
    end

    -- X-axis: time span from oldest shown sample to now.
    local span = (shown - 1) * (state.historyStep or 0)
    text(plotX, axisRow, "-" .. dur(span), C.faint, C.panel)
    text(plotX + plotW - 3, axisRow, "now", C.faint, C.panel)
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
    local powerH = 8
    local logH = state.showLog and 8 or 0
    local logY = H - logH + 1
    local genY = contentY + powerH + 1
    local genBottom = state.showLog and (logY - 2) or H
    local genH = genBottom - genY + 1

    drawPower(state, 2, contentY, W - 2, powerH)
    if state.showGraph then
        drawGraph(state, 2, genY, W - 2, genH)
    else
        drawGenerators(state, 2, genY, W - 2, genH)
    end
    if state.showLog then drawLog(state, 2, logY, W - 2, logH) end

    if buffer then gpu.bitblt(0, 1, 1, W, H, buffer, 1, 1) end
end

return ui

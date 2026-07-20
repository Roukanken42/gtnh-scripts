-- Terminal dashboard for the pump regulator. Pure display: it renders a state
-- table handed to it by main.lua each cycle and knows nothing about allocation.
--
-- Falls back to a no-op (ui.active == false) when there is no GPU/screen, so the
-- controller still runs headless. Designed for a tier-3 GPU (up to 160x50, 8-bit
-- colour) but lays out relative to the actual resolution.
--
-- Frames are double-buffered: each render is drawn to an off-screen VRAM buffer
-- and blitted to the screen in one operation, so the periodic UI refresh does not
-- flicker. Degrades to direct-to-screen drawing if the GPU can't allocate one.
--
-- State contract (all fields optional-safe):
--   dryRun        boolean
--   paused        boolean          -- user halt; pumps off and allocation frozen
--   cycle         integer          -- control-cycle counter
--   tick          integer          -- repaint counter (drives the spinner)
--   updated       string           -- "HH:MM:SS"
--   pumps         { { tierName, address, parallels, active,
--                     threads = { [threadIndex] = gasName | nil } }, ... }
--   tierSummary   string           -- e.g. "2x MK-1  1x MK-3"
--   gases         { { name, current, target, fill (0..1), priority, score,
--                     threads, status, etaOne }, ... }  -- status: PUMP|CRIT|WAIT|OK
--                                                       -- etaOne: sec for 1 parallel
--   totals        { pumps, threadsUsed, threadsTotal, parallels, euPerTick,
--                   etaSumOne, etaRealtime }            -- fill-time ETAs, seconds
--   messages      { "HH:MM:SS  text", ... }      -- newest last

local component = require("component")

local ui = { active = false }

local gpu
local W, H
local origW, origH, origDepth
local buffer -- off-screen VRAM buffer index for double-buffering (nil = draw direct)

-- ---- palette (approximated to the 8-bit palette by the GPU) --------------
local C = {
    bg      = 0x0B0B12,
    panel   = 0x15151F,
    panelHi = 0x24243A,
    border  = 0x3A3A5C,
    accent  = 0x22D3EE, -- cyan
    accent2 = 0x8B7BFF, -- violet
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

-- Unicode as UTF-8 byte escapes (works on Lua 5.2 and 5.3; \u{} is 5.3-only).
local BOX = {
    tl = "\xE2\x94\x8C", tr = "\xE2\x94\x90", bl = "\xE2\x94\x94",
    br = "\xE2\x94\x98", h = "\xE2\x94\x80", v = "\xE2\x94\x82",
}
-- Eighth-width blocks for sub-cell bar precision (index 1..7).
local EIGHTHS = {
    "\xE2\x96\x8F", "\xE2\x96\x8E", "\xE2\x96\x8D", "\xE2\x96\x8C",
    "\xE2\x96\x8B", "\xE2\x96\x8A", "\xE2\x96\x89",
}
local ARROW = "\xE2\x96\xB8" -- triangle marker
local MIDDOT = "\xC2\xB7"    -- middle dot
local EMDASH = "\xE2\x80\x94"
local BLOCK = "\xE2\x96\xAE" -- thread marker
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

local function human(n)
    n = n or 0
    local a = math.abs(n)
    if a >= 1e12 then return string.format("%.2fT", n / 1e12) end
    if a >= 1e9 then return string.format("%.2fG", n / 1e9) end
    if a >= 1e6 then return string.format("%.1fM", n / 1e6) end
    if a >= 1e3 then return string.format("%.1fk", n / 1e3) end
    return string.format("%d", n)
end

-- Compact duration: seconds -> "45s" / "12m" / "3h20m" / "2d5h". Shows the two
-- largest non-zero units. "--" for non-finite (e.g. a zero-rate gas).
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

local function panel(x, y, w, h, title)
    box(x, y, w, h, C.border, C.panel)
    if title then text(x + 2, y, " " .. title .. " ", C.accent, C.panel) end
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

local function fillColor(frac)
    if frac < 0.25 then return C.crit
    elseif frac < 0.60 then return C.warn
    else return C.good end
end

local STATUS_COLOR = { PUMP = C.pump, CRIT = C.crit, WAIT = C.warn, OK = C.good }

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

    -- Double-buffering: allocate an off-screen buffer the size of the screen.
    -- Each frame is drawn there and blitted to the display in one operation, so
    -- periodic refreshes no longer flicker. Falls back to drawing straight to the
    -- screen when the GPU can't provide a buffer (older tiers / low VRAM).
    -- Note: component proxy methods are callable tables, not "function", so test
    -- for presence (~= nil) rather than type -- pcall guards the actual call.
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
    local titleStr = " SPACE ELEVATOR " .. EMDASH .. " PUMP CONTROLLER"
    text(2, 1, titleStr, C.accent, C.titleBg)
    text(2 + #titleStr + 2, 1, "[SPACE] pause/resume", C.faint, C.titleBg)

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

local function kpiCard(x, y, w, label, value, valueColor, note)
    box(x, y, w, 4, C.border, C.panel)
    text(x + 2, y + 1, padR(label, w - 4), C.dim, C.panel)
    text(x + 2, y + 2, padR(value, w - 4), valueColor or C.text, C.panel)
    if note then text(x + 2, y + 2, note, C.faint, C.panel) end
end

local function drawKPIs(state, y)
    local t = state.totals or {}
    local n = 6
    local gap = 1
    local w = math.floor((W - 2 - (n - 1) * gap) / n)
    local x = 2
    kpiCard(x, y, w, "PUMPS", tostring(t.pumps or 0) .. "  " .. (state.tierSummary or ""), C.text)
    x = x + w + gap
    kpiCard(x, y, w, "THREADS ACTIVE", (t.threadsUsed or 0) .. " / " .. (t.threadsTotal or 0), C.accent)
    x = x + w + gap
    kpiCard(x, y, w, "PARALLELS IN USE", tostring(t.parallels or 0), C.accent2)
    x = x + w + gap
    kpiCard(x, y, w, "POWER DRAW", human(t.euPerTick or 0) .. " EU/t", C.warn)
    x = x + w + gap
    -- Fill-time ETA: real-time headline (whole fleet) + one-parallel total.
    local fillVal, fillColorKpi
    if (t.etaSumOne or 0) <= 0 then
        fillVal, fillColorKpi = "DONE", C.good
    else
        fillVal = dur(t.etaRealtime) .. "  1p " .. dur(t.etaSumOne)
        fillColorKpi = C.accent
    end
    kpiCard(x, y, w, "TIME TO FILL", fillVal, fillColorKpi)
    x = x + w + gap
    local st, stColor
    if state.paused then
        st, stColor = "PAUSED", C.crit
    elseif state.dryRun then
        st, stColor = "DRY RUN", C.warn
    else
        st, stColor = "LIVE", C.good
    end
    kpiCard(x, y, w, "STATUS", st, stColor)
end

-- Column x-offsets (relative to the row's left edge) for the wide fluids layout,
-- given the elastic level-bar width. Name and bar are on the left; everything
-- after the bar shifts with it. Keeps the header and rows in lockstep. The row's
-- total width is barW + 70 (15 name + 4 pct + 15 stored/target + 4 prio + 5 score
-- + 8 eta + 5 thr + 6 status, plus a 1-col gap between each of the 9 columns).
local function fluidCols(barW)
    local c = { name = 0, bar = 16 } -- 15-wide name + 1 gap
    c.pct    = c.bar + barW + 1
    c.stored = c.pct + 5             -- pct 4 + gap
    c.prio   = c.stored + 16         -- stored/target 15 + gap
    c.score  = c.prio + 5            -- prio 4 + gap
    c.eta    = c.score + 6           -- score 5 + gap
    c.thr    = c.eta + 9             -- eta 8 + gap
    c.status = c.thr + 6             -- thr 5 + gap
    return c
end

-- Draws one fluid entry inside the fluids panel. In wide mode barW sets the
-- elastic level-bar width so the table fills the available panel width.
local function drawFluidRow(x, y, g, wide, barW)
    local col = fillColor(g.fill)
    local pct = string.format("%3d%%", math.floor(g.fill * 100 + 0.5))
    if wide then
        local c = fluidCols(barW)
        local eta = (g.etaOne and g.etaOne > 0) and dur(g.etaOne) or "--"
        text(x + c.name, y, padR(g.name, 15), C.text, C.panel)
        bar(x + c.bar, y, barW, g.fill, col, C.panelHi)
        text(x + c.pct, y, pct, col, C.panel)
        text(x + c.stored, y, padL(human(g.current), 7) .. "/" .. padR(human(g.target), 7), C.dim, C.panel)
        text(x + c.prio, y, "p" .. padR(tostring(g.priority), 3), C.faint, C.panel)
        text(x + c.score, y, padL(string.format("%.0f", g.score or 0), 5), C.dim, C.panel)
        text(x + c.eta, y, padR(eta, 8), C.accent, C.panel)
        text(x + c.thr, y, g.threads > 0 and string.rep(BLOCK, math.min(g.threads, 4)) or "", C.pump, C.panel)
        text(x + c.status, y, padR(g.status or "", 5), STATUS_COLOR[g.status] or C.dim, C.panel)
    else
        text(x, y, padR(g.name, 13), C.text, C.panel)
        bar(x + 14, y, 14, g.fill, col, C.panelHi)
        text(x + 29, y, pct, col, C.panel)
        text(x + 34, y, g.threads > 0 and tostring(g.threads) or " ", C.pump, C.panel)
        text(x + 36, y, padR(g.status or "", 4), STATUS_COLOR[g.status] or C.dim, C.panel)
    end
end

local function drawFluids(state, x, y, w, h)
    panel(x, y, w, h, "FLUIDS  " .. #(state.gases or {}) .. " demanded")
    local gases = state.gases or {}
    local innerX = x + 2
    local innerW = w - 4
    local rowsAvail = h - 3
    if #gases == 0 then
        text(innerX, y + 2, "No gases with target > 0 in config.lua.", C.faint, C.panel)
        return
    end

    -- Wide detailed rows need ~92 columns; use them when they fit and everything
    -- shows in one column. Otherwise fall back to compact 1- or 2-column rows.
    if innerW >= 92 and #gases <= rowsAvail then
        -- The level bar takes whatever width is left after the fixed columns.
        local barW = math.max(innerW - 70, 8)
        local c = fluidCols(barW)
        -- Header labels at the same column offsets used by drawFluidRow(wide).
        local hy = y + 1
        text(innerX + c.name,   hy, "FLUID", C.faint, C.panel)
        text(innerX + c.bar,    hy, "LEVEL", C.faint, C.panel)
        text(innerX + c.pct,    hy, "PCT", C.faint, C.panel)
        text(innerX + c.stored, hy, "STORED / TARGET", C.faint, C.panel)
        text(innerX + c.prio,   hy, "PRIO", C.faint, C.panel)
        text(innerX + c.score,  hy, "SCORE", C.faint, C.panel)
        text(innerX + c.eta,    hy, "1P ETA", C.faint, C.panel)
        text(innerX + c.thr,    hy, "THR", C.faint, C.panel)
        text(innerX + c.status, hy, "STATUS", C.faint, C.panel)
        for i, g in ipairs(gases) do
            if i > rowsAvail then break end
            drawFluidRow(innerX, y + 1 + i, g, true, barW)
        end
        return
    end

    local colW = 41
    local cols = (innerW >= colW * 2) and 2 or 1
    local perCol = rowsAvail
    for c = 0, cols - 1 do
        text(innerX + c * colW, y + 1, "FLUID         LEVEL          PCT T ST", C.faint, C.panel)
    end
    for i, g in ipairs(gases) do
        if i > perCol * cols then break end
        local c = math.floor((i - 1) / perCol)
        local row = i - c * perCol
        drawFluidRow(innerX + c * colW, y + 1 + row, g, false)
    end
end

local function drawPumps(state, x, y, w, h)
    local title = "PUMPS " .. MIDDOT .. " THREADS"
    if state.paused then title = title .. "  " .. EMDASH .. " HALTED" end
    panel(x, y, w, h, title)
    local innerX = x + 2
    local row = y + 1
    local bottom = y + h - 2
    for _, p in ipairs(state.pumps or {}) do
        if row > bottom then break end
        -- Pump header: tier, parallels, active/total threads.
        text(innerX, row, padR(p.tierName or "?", 6), C.accent, C.panel)
        text(innerX + 7, row, string.format("%dp  %d/%d thr",
            p.parallels or 0, p.active or 0, p.threadCount or 0), C.dim, C.panel)
        row = row + 1
        -- Per-thread assignment (0-indexed; p.threads is sparse, idle = nil).
        for ti = 0, (p.threadCount or 1) - 1 do
            if row > bottom then break end
            local gasName = p.threads and p.threads[ti]
            if gasName then
                text(innerX + 1, row, ARROW .. " T" .. ti .. " " .. padR(gasName, w - 10), C.pump, C.panel)
            else
                text(innerX + 1, row, MIDDOT .. " T" .. ti .. " idle", C.faint, C.panel)
            end
            row = row + 1
        end
        if row <= bottom then row = row + 1 end
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

-- Width the pumps/threads panel actually needs: enough for the longest gas name
-- (thread rows) and the widest title. Independent of the screen fraction, so the
-- fluids panel can claim the rest. Reserves for the "HALTED" title even when not
-- paused so the layout doesn't jump when pausing.
local function pumpsWidth(state)
    local maxName = 6 -- floor so short-name configs still fit the header/title
    for _, g in ipairs(state.gases or {}) do
        if #g.name > maxName then maxName = #g.name end
    end
    -- thread row = "> Tn " (5) + name + left/right chrome (~7); title needs ~30.
    return math.max(maxName + 12, 30)
end

function ui.render(state)
    if not ui.active then return end
    -- Draw the frame off-screen (buffer stays the active target between renders).
    if buffer then gpu.setActiveBuffer(buffer) end

    drawTitle(state)
    local kpiY = 3
    drawKPIs(state, kpiY)

    local contentY = kpiY + 5
    local logH = 6
    local logY = H - logH + 1
    local contentH = logY - contentY - 1

    -- Pumps panel is clamped to its content width; fluids takes everything else.
    local rightW = pumpsWidth(state)
    local rightX = W - rightW
    local leftW = rightX - 3 -- left margin (col 2) + fluids + 1-col gap = rightX

    drawFluids(state, 2, contentY, leftW, contentH)
    drawPumps(state, rightX, contentY, rightW, contentH)
    drawLog(state, 2, logY, W - 2, logH)

    -- Present the finished frame to the screen in a single blit (no flicker).
    if buffer then gpu.bitblt(0, 1, 1, W, H, buffer, 1, 1) end
end

return ui

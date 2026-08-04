-- Terminal dashboard for the mining controller. Pure display: it renders a state
-- table handed to it by main.lua each cycle and knows nothing about maintenance.
--
-- Falls back to a no-op (ui.active == false) when there is no GPU/screen, so the
-- controller still runs headless. Sized for a tier-3 screen (160x50) but lays out
-- relative to the actual resolution.
--
-- Frames are double-buffered: each render is drawn to an off-screen VRAM buffer
-- and blitted in one operation, so the periodic refresh does not flicker.
--
-- The PLASMA panel is not only a readout -- it is where the fleet's plasma is
-- chosen. It has three display states, driven entirely by the fields below, so
-- the key handling stays in main.lua:
--   browsing   state.focus == "plasma", state.cursor marks a row
--   confirming state.confirm names the plasma awaiting a second keypress
--   idle       neither; the active plasma is simply marked
--
-- ---- marking what the fleet is FOR ------------------------------------------
-- Every table that lists ore, or the meteors ore comes out of, marks the rows that
-- serve a want (state.wants). It is the same question in four places -- "is any of
-- this what I asked for?" -- and the answer is what says whether a fleet is
-- effective or merely busy. Wanted ore is drawn in C.mine and carries its stock and
-- fill; everything else stays dim, and a meteor row says which wants it serves.
--
-- State contract (all fields optional-safe):
--   mode        "MANUAL" | "AUTO" | "AUTO 4/8"   -- the fleet's overall mode
--   dryRun / paused / showLog        booleans
--   focus       nil | "plasma"       -- which panel has the keyboard
--   cursor      integer              -- 1-based row in state.plasmas when focused
--   confirm     string               -- plasma name awaiting confirmation
--   switching   string               -- plasma name being applied right now
--   cycle / tick / updated
--   screen      "dashboard" | "detail" | "profile" | "advise"
--               | "fleetMeteors" | "fleetOre" | "wants"
--   scroll      rows the current table is scrolled down by
--   fleet       { meteors, ore, modules, totalItems, empty } -- the fleet sums
--   wants       { rows, summary, notes, empty, read } -- what the fleet is for;
--               a row is { material, label, stock, fill, pct, need, made, cover,
--               coverPct, eta, state, note }. Also read by the ore/meteor tables
--               through `wanted` below.
--   wanted      { [ore key] = { fill, pct, stock, material } } -- what to mark in
--               any table that lists ore. Absent means nothing is wanted.
--   advise      { miner, settings, cursor, settingsCount, results, picking,
--                 summary, error, empty, notes, rateLabel, edit,
--                 applied, pending, pendingNote }
--   profile     { cycles, elapsed, callCount, callTotal, spans, calls, note }
--   moduleCursor integer            -- selected row in state.miners
--   clipboard   nil | { addr, label }  -- the module a copy was taken from
--   detail      { miner, view, field, fields, pool, yield, summary, rates,
--                 edit, editHint, error }   -- see drawParams / drawPool
--   miners      { { tierName, addr, state, stateKind, drone, distance,
--                   parallels, parallelCap, overdrive, material, hatchLevel,
--                   hatchCapacity, hatchTarget, hatchFluid, staged,
--                   auto, pending }, ... }   -- pending: a queued change, in words;
--                   auto: whether the controller may aim this module
--   kits        { { name, have, target, fill, crafts, settling, from }, ... }
--   plasmas     { { tier, name, have, target, fill, crafts, settling, from,
--                   active }, ... }
--   totals      { miners, mining, jobsKit, jobsPlasma, limitKit, limitPlasma }
--   supplyErr   string | nil
--   messages    { "HH:MM:SS  text", ... }   newest last

local component = require("component")

local ui = { active = false }

local gpu
local W, H
local origW, origH, origDepth
local buffer -- off-screen VRAM buffer index (nil = draw direct)

-- ---- palette (approximated to the 8-bit palette by the GPU) ------------------
local C = {
    bg      = 0x0B0B12,
    panel   = 0x15151F,
    panelHi = 0x24243A,
    border  = 0x3A3A5C,
    focus   = 0xF2C94C, -- border of the panel holding the keyboard
    accent  = 0x22D3EE, -- cyan
    accent2 = 0x8B7BFF, -- violet
    text    = 0xE6E6F0,
    dim     = 0x9090A8,
    faint   = 0x585870,
    good    = 0x3BD671,
    warn    = 0xF2C94C,
    crit    = 0xFF5C5C,
    mine    = 0x38A6FF,
    titleBg = 0x161634,
    white   = 0xFFFFFF,
    black   = 0x000000,
}

-- Unicode as UTF-8 byte escapes (works on Lua 5.2 and 5.3; \u{} is 5.3-only).
local BOX = {
    tl = "\xE2\x94\x8C", tr = "\xE2\x94\x90", bl = "\xE2\x94\x94",
    br = "\xE2\x94\x98", h = "\xE2\x94\x80", v = "\xE2\x94\x82",
}
local EIGHTHS = {
    "\xE2\x96\x8F", "\xE2\x96\x8E", "\xE2\x96\x8D", "\xE2\x96\x8C",
    "\xE2\x96\x8B", "\xE2\x96\x8A", "\xE2\x96\x89",
}
local ARROW = "\xE2\x96\xB8"  -- cursor
local DOT = "\xE2\x97\x8F"    -- the active plasma
local MIDDOT = "\xC2\xB7"
local EMDASH = "\xE2\x80\x94"
local SPIN = { "|", "/", "-", "\\" }

-- ---- low-level drawing -------------------------------------------------------
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

-- Screen COLUMNS a string occupies. The markers and box-drawing glyphs are
-- multi-byte UTF-8 and each takes one column, so # overstates them -- by two for
-- every arrow or bullet.
local function cols(s)
    return select(2, tostring(s):gsub("[^\128-\191]", ""))
end

local function trunc(s, w)
    s = tostring(s)
    -- A negative width has to collapse to nothing: s:sub(1, -1) is the WHOLE
    -- string, so an underflowed column would print at full length and paint over
    -- whatever is to its right.
    if w <= 0 then return "" end
    -- Fast path: fewer bytes than columns allowed means it cannot be too wide.
    if #s <= w then return s end
    -- Cut on a GLYPH boundary. s:sub(1, w) would slice a three-byte marker in
    -- half and put an invalid sequence on the screen, which the GPU renders as
    -- a replacement character sitting in the middle of a table.
    local out, n = {}, 0
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if n >= w then break end
        out[#out + 1] = ch
        n = n + 1
    end
    return table.concat(out)
end

local function padR(s, w) s = trunc(s, w); return s .. string.rep(" ", math.max(0, w - cols(s))) end
local function padL(s, w) s = trunc(s, w); return string.rep(" ", math.max(0, w - cols(s))) .. s end

-- Draws one table cell at column `off` within a panel's inner area, clipped to
-- whatever room is left before the right border. Every table row goes through
-- this: column offsets are arithmetic over an elastic width, and the failure mode
-- of getting one wrong is text painted across the frame and into the next panel.
-- Clipping turns that into a truncated column, which is visible and harmless.
-- `bg` is for the rows that are highlighted rather than merely coloured -- wanted
-- ore, which every ore table marks. The row's whole width is filled with it first
-- (see rowBg), because the column offsets leave a space or two between cells and a
-- highlight with the panel showing through the gaps reads as a rendering fault.
local function cell(x, y, off, width, s, fg, inner, bg)
    local avail = inner - off
    if avail <= 0 then return end
    if width > avail then width = avail end
    text(x + off, y, padR(s, width), fg, bg or C.panel)
end

local HUMAN_PREFIX = { "k", "M", "G", "T", "P", "E", "Z", "Y", "R", "Q" }

-- Human-readable magnitude: 999 -> "999", 1234 -> "1.23k". Kept to ~3 significant
-- figures so a column's width stays bounded however large a stock grows.
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

-- A PER-SECOND figure, where the decimals are the whole point: an ore coming out
-- at 12.4/s and one at 12.9/s are different answers, and human() rounds both to
-- "12". Only once a rate is large does the magnitude matter more than the digits.
local function rate(v)
    v = v or 0
    if v >= 1000 then return human(v) end
    if v >= 10 then return string.format("%.2f", v) end
    if v >= 1 then return string.format("%.3f", v) end
    return string.format("%.4f", v)
end

-- How many rows the table on screen can show. Written on every render and read by
-- the key handler on the next keypress, which is the only way the two can agree:
-- the height depends on the panel layout, and the clamping has to happen where the
-- keys are handled or the offset runs off the end and takes a dozen presses to
-- come back.
ui.tableRows = 1

-- The window of `list` a scroll offset selects, plus a "1-24 of 137" for the title.
-- Clamped again here: the offset is only as fresh as the last render, and a list
-- that has just got shorter must not be drawn from past its end.
local function window(list, scroll, rows)
    local n = #list
    ui.tableRows = math.max(rows, 1)
    local first = math.max(0, math.min(scroll or 0, math.max(0, n - rows))) + 1
    local last = math.min(n, first + rows - 1)
    local label
    if n == 0 then label = "empty"
    elseif n <= rows then label = tostring(n)
    else label = string.format("%d-%d of %d", first, last, n) end
    return first, last, label
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

local function panel(x, y, w, h, title, focused)
    box(x, y, w, h, focused and C.focus or C.border, C.panel)
    if title then
        -- Clipped to the box. Titles were never clipped, which went unnoticed while
        -- they were all short: a long one runs along the top of whatever is to the
        -- right of the panel, and off the edge of the screen entirely.
        text(x + 2, y, trunc(" " .. title .. " ", math.max(0, w - 4)),
            focused and C.focus or C.accent, C.panel)
    end
end

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

local function rgb(c)
    return math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256
end

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

-- What a miner is doing, and how alarming that is. The kinds come from main.lua
-- so the colour choice stays here and the diagnosis stays there.
local STATE_COLOR = {
    MINING = C.good, IDLE = C.dim, DRY = C.warn, STOPPING = C.accent2,
    ["NO DRONE"] = C.warn, ["NO STATION"] = C.crit, OFF = C.faint,
}

-- How a want is doing. FULL and OK are both fine and read differently on purpose:
-- one is done, the other is holding.
local WANT_COLOR = {
    FULL = C.good, OK = C.good, LOW = C.warn, CRITICAL = C.crit,
    UNKNOWN = C.faint, ["NOT MINED"] = C.crit,
}

-- The want an ore row serves, or nil. `key` is a yield key as the estimator reports
-- it -- the bare material where there is one, else the oredict.
local function wantOf(state, key)
    if not key then return nil end
    local w = state.wanted
    return w and w[key] or nil
end

-- Fills a table row's background, for the rows that are wanted. Returns the colour
-- the row's cells must then be drawn on.
local function rowBg(x, y, inner, wanted)
    if not wanted then return C.panel end
    rect(x, y, inner, 1, C.panelHi)
    return C.panelHi
end

-- The two columns every ore table grows when there is a want list: what is in stock
-- against what was asked for, and how full that is. `off` is where they start.
local function drawWantCells(x, y, inner, w, off, bg)
    if w then
        cell(x, y, off, 20, w.stock or "-", C.dim, inner, bg)
        cell(x, y, off + 20, 6, padL(w.pct or "-", 5),
            w.fill and fillColor(w.fill) or C.faint, inner, bg)
    else
        -- Deliberately not blank: "this ore is not on the list" is information, and
        -- a run of dots down the column is how you see at a glance how much of what
        -- the fleet makes nobody asked for.
        cell(x, y, off, 26, MIDDOT, C.faint, inner, bg)
    end
end

-- ---- lifecycle ---------------------------------------------------------------
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

    -- Component proxy methods are callable tables, not "function", so test for
    -- presence rather than type; pcall guards the call itself.
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

-- ---- sections ----------------------------------------------------------------

-- The hint line changes with what the keyboard is doing, so the two-step plasma
-- choice explains itself rather than needing to be remembered.
local UPDOWN = "\xE2\x86\x91\xE2\x86\x93"
local LEFTRIGHT = "\xE2\x86\x90\xE2\x86\x92"

local SCROLL = "[" .. "\xE2\x86\x91\xE2\x86\x93" .. "/PgUp/PgDn] scroll"

local function hintFor(state)
    if state.screen == "fleetMeteors" or state.screen == "fleetOre"
        or state.screen == "wants" then
        return SCROLL .. "  [M] pool  [O] ore  [W] wants  [L] log  [Q] back"
    end
    if state.screen == "advise" then
        local a = state.advise or {}
        if a.picking then
            return "[" .. UPDOWN .. "] or a letter  [ENTER] pick  [Q] cancel"
        end
        if a.edit then
            return "[" .. UPDOWN .. "] adjust  [" .. LEFTRIGHT
                .. "] jump  [ENTER] pin  [Q] cancel"
        end
        return "[" .. UPDOWN .. "] row  [ENTER] change or apply  [X] unpin  [Q] back"
    end

    if state.screen == "profile" then
        return "[S] save  [R] reset  [L] log  [Q] back"
    end
    if state.screen == "detail" then
        local d = state.detail or {}
        if d.edit then
            local f = d.fields and d.fields[d.field]
            if f and f.kind == "number" then
                return "[" .. UPDOWN .. "] adjust  [" .. LEFTRIGHT
                    .. "] jump  [ENTER] apply  [Q] cancel"
            end
            return "[" .. UPDOWN .. "] choose  [ENTER] apply  [Q] cancel"
        end
        return "[" .. UPDOWN .. "] field [ENTER] edit [PgUp/PgDn] scroll [TAB] view"
            .. " [A] advise [Q] back"
    end
    if state.confirm then
        return "[ENTER] apply " .. state.confirm .. "   [Q] back"
    elseif state.focus == "plasma" then
        return "[" .. UPDOWN .. "] choose   [ENTER] select   [Q] cancel"
    end
    -- The profile key is deliberately absent: it only does anything under
    -- --profile, and the hint bar is for the keys that always work.
    if state.clipboard then
        return "[" .. UPDOWN .. "] module  [V] paste  [C] copy another  [Q] done copying"
    end
    -- Tight: the whole line has to fit beside the status block and what overflows
    -- is cut off the end. Pause, copy and the log toggle are in --help; the keys
    -- that move you somewhere are the ones worth the space, and [A] earns its place
    -- because it is the only way to hand a module back to the controller.
    return "[" .. UPDOWN .. "] module [ENTER] detail [A] auto [W] wants [P] plasma"
        .. " [M] pool [O] ore [Q] quit"
end

local function drawTitle(state)
    rect(1, 1, W, 1, C.titleBg)
    -- EMDASH is one glyph but three bytes, so # overstates the title's width by
    -- two columns. Everything laid out after it has to allow for that.
    local titleStr = " SPACE ELEVATOR " .. EMDASH .. " MINING CONTROLLER"
    local titleW = #titleStr - 2
    text(2, 1, titleStr, C.accent, C.titleBg)

    local mode = state.mode or "MANUAL"
    text(2 + titleW + 2, 1, mode, C.accent2, C.titleBg)

    local badge, badgeColor
    if state.paused then badge, badgeColor = " PAUSED ", C.crit
    elseif state.dryRun then badge, badgeColor = " DRY RUN ", C.warn
    else badge, badgeColor = " LIVE ", C.good end

    local spin = SPIN[(state.tick or state.cycle or 0) % #SPIN + 1]
    local info = string.format("%s  cycle #%d  %s  ", spin, state.cycle or 0,
        state.updated or "--:--:--")
    local rightX = W - 1 - #badge - #info

    -- The hint fills whatever is left between the mode and the status block. It
    -- is the first thing to go on a narrow screen: the keys are also in --help,
    -- while the badge saying LIVE or PAUSED is not.
    local hintX = 2 + titleW + 2 + #mode + 3
    local room = rightX - hintX - 2
    if room > 0 then
        local hint = hintFor(state)
        -- The arrow glyphs are three bytes each; measure in columns, not bytes.
        local hintW = select(2, hint:gsub("[^\128-\191]", ""))
        if hintW > room then hint = trunc(hint:gsub("[\128-\255]", "?"), room) end
        text(hintX, 1, hint, C.faint, C.titleBg)
    end

    text(rightX, 1, info, C.dim, C.titleBg)
    text(rightX + #info, 1, badge, C.black, badgeColor)
end

local function kpiCard(x, y, w, label, value, valueColor)
    box(x, y, w, 4, C.border, C.panel)
    text(x + 2, y + 1, padR(label, w - 4), C.dim, C.panel)
    text(x + 2, y + 2, padR(value, w - 4), valueColor or C.text, C.panel)
end

local function drawKPIs(state, y)
    local t = state.totals or {}
    local n, gap = 6, 1
    local w = math.floor((W - 2 - (n - 1) * gap) / n)
    local x = 2

    -- How much of the fleet is running, and how much of it the controller is
    -- allowed to aim -- the second number being the one that says whether anything
    -- is going to happen when a want runs down.
    kpiCard(x, y, w, "MINING", (t.mining or 0) .. " / " .. (t.miners or 0)
        .. ((t.auto and t.auto > 0) and ("   " .. t.auto .. " AUTO") or ""),
        (t.mining or 0) > 0 and C.good or C.dim)
    x = x + w + gap

    -- What the fleet is FOR, in one number: how many wants are met, and the average
    -- fill across them. Blank-ish rather than alarming when nothing is asked for --
    -- an empty want list is a setup that has not been finished, not a failure.
    local wsum = (state.wants or {}).summary
    if wsum and (wsum.n or 0) > 0 then
        local met = (wsum.n - (wsum.demanded or 0))
        kpiCard(x, y, w, "WANTS MET", string.format("%d / %d   %d%%", met, wsum.n,
            math.floor((wsum.fill or 0) * 100 + 0.5)),
            (wsum.critical or 0) > 0 and C.crit or fillColor(wsum.fill or 0))
    else
        kpiCard(x, y, w, "WANTS MET", "(none listed)", C.faint)
    end
    x = x + w + gap

    local pName, pColor = "(none chosen)", C.warn
    for _, p in ipairs(state.plasmas or {}) do
        if p.active then pName, pColor = p.name, C.accent end
    end
    if state.switching then pName, pColor = state.switching .. " ...", C.warn end
    kpiCard(x, y, w, "PLASMA", pName, pColor)
    x = x + w + gap

    -- Restock jobs against their caps: the number that explains why something
    -- short is not being fetched yet.
    kpiCard(x, y, w, "RESTOCK JOBS", string.format("%d/%s kit  %d/%s plasma",
        t.jobsKit or 0, tostring(t.limitKit or "-"),
        t.jobsPlasma or 0, tostring(t.limitPlasma or "-")),
        ((t.jobsKit or 0) + (t.jobsPlasma or 0)) > 0 and C.accent2 or C.dim)
    x = x + w + gap

    local low = 0
    for _, k in ipairs(state.kits or {}) do if k.fill < 1 then low = low + 1 end end
    for _, p in ipairs(state.plasmas or {}) do if p.target > 0 and p.fill < 1 then low = low + 1 end end
    kpiCard(x, y, w, "BELOW TARGET", tostring(low), low > 0 and C.warn or C.good)
    x = x + w + gap

    local st, stColor
    if state.paused then st, stColor = "PAUSED", C.crit
    elseif state.supplyErr then st, stColor = "NO SUPPLY", C.crit
    elseif state.dryRun then st, stColor = "DRY RUN", C.warn
    else st, stColor = "LIVE", C.good end
    kpiCard(x, y, w, "STATUS", st, stColor)
end

-- Column offsets for the miners table, relative to the row's left edge. The
-- first two columns are the selection gutter: the arrows drive this list, so it
-- has to show which row they are on.
-- The first THREE columns are the gutter: the selection arrow, the clipboard
-- marker, and a space so a marked row does not read as "CT3".
-- MODE sits second, right after the tier: whether the controller may aim a module
-- changes the meaning of every column after it, so it belongs where the eye lands
-- rather than out past the plasma. The five columns it costs come off LEVEL, STAGED
-- and PLASMA, each of which had a couple to spare.
local MC = {
    tier = 3, mode = 8, addr = 14, state = 24, drone = 35, dist = 44, par = 51,
    od = 58, material = 64, bar = 84, level = 95, staged = 108, fluid = 117,
    pending = 139,
}

local function drawMiners(state, x, y, w, h)
    local list = state.miners or {}
    local focused = state.screen ~= "detail" and not state.focus
    local clip = state.clipboard
    local title = "MODULES  " .. #list .. "  " .. MIDDOT .. "  ENTER for details"
    if clip then
        title = "MODULES  " .. #list .. "  " .. MIDDOT .. "  COPYING "
            .. (clip.label or clip.addr or "")
    end
    panel(x, y, w, h, title, focused)
    local ix, inner = x + 2, w - 4
    local hy = y + 1

    cell(ix, hy, MC.tier, 4, "TIER", C.faint, inner)
    cell(ix, hy, MC.mode, 5, "MODE", C.faint, inner)
    cell(ix, hy, MC.addr, 9, "ADDRESS", C.faint, inner)
    cell(ix, hy, MC.state, 10, "STATE", C.faint, inner)
    cell(ix, hy, MC.drone, 8, "DRONE", C.faint, inner)
    cell(ix, hy, MC.dist, 6, "DIST", C.faint, inner)
    cell(ix, hy, MC.par, 6, "PAR", C.faint, inner)
    cell(ix, hy, MC.od, 5, "OD", C.faint, inner)
    cell(ix, hy, MC.material, 19, "KIT MATERIAL", C.faint, inner)
    cell(ix, hy, MC.bar, 11, "HATCH", C.faint, inner)
    cell(ix, hy, MC.level, 12, "LEVEL", C.faint, inner)
    cell(ix, hy, MC.staged, 8, "STAGED", C.faint, inner)
    cell(ix, hy, MC.fluid, 21, "PLASMA", C.faint, inner)
    cell(ix, hy, MC.pending, inner - MC.pending, "PENDING", C.faint, inner)

    if #list == 0 then
        cell(ix, y + 3, 0, inner,
            "No mining modules discovered -- are the Adapters connected?", C.faint, inner)
        return
    end

    for i, m in ipairs(list) do
        local row = y + 1 + i
        if row > y + h - 2 then
            -- Never silently show a subset: say how many did not fit.
            cell(ix, y + h - 2, 0, inner,
                string.format("... and %d more (screen is %d rows short)",
                    #list - i + 1, #list - i + 1), C.faint, inner)
            break
        end
        cell(ix, row, 0, 1, (state.moduleCursor == i) and ARROW or " ",
            focused and C.focus or C.faint, inner)
        -- The module the clipboard was taken from, so a paste onto the wrong row
        -- is visible before it is made rather than after.
        cell(ix, row, 1, 1, (clip and clip.addr == m.addr) and "C" or " ",
            C.accent2, inner)
        cell(ix, row, MC.tier, 4, m.tierName or "?", C.accent, inner)
        -- AUTO is the fleet doing its job, so it is the quiet one; MAN is the
        -- exception and is coloured like the other things a player has pinned.
        cell(ix, row, MC.mode, 5, m.auto and "auto" or "MAN",
            m.auto and C.dim or C.accent2, inner)
        cell(ix, row, MC.addr, 9, m.addr or "", C.dim, inner)
        cell(ix, row, MC.state, 10, m.state or "",
            STATE_COLOR[m.stateKind or m.state] or C.dim, inner)
        cell(ix, row, MC.drone, 8, m.drone or MIDDOT, m.drone and C.text or C.faint, inner)
        cell(ix, row, MC.dist, 6,
            padL(m.distance and string.format("%d", m.distance) or "-", 5), C.text, inner)
        cell(ix, row, MC.par, 6, padL(m.parallels and
            (m.parallels .. "/" .. (m.parallelCap or "?")) or "-", 5), C.dim, inner)
        cell(ix, row, MC.od, 5,
            padL(m.overdrive and string.format("%.1f", m.overdrive) or "-", 4), C.dim, inner)
        cell(ix, row, MC.material, 19, m.material or MIDDOT,
            m.material and C.text or C.faint, inner)

        if m.hatchTarget and m.hatchTarget > 0 then
            local frac = math.min(1, (m.hatchLevel or 0) / m.hatchTarget)
            if inner - MC.bar >= 10 then
                bar(ix + MC.bar, row, 10, frac, fillColor(frac), C.panelHi)
            end
            cell(ix, row, MC.level, 12,
                human(m.hatchLevel or 0) .. "/" .. human(m.hatchTarget), fillColor(frac), inner)
        else
            cell(ix, row, MC.bar, 25, m.hasFluid and "no target yet" or "no plasma feed",
                C.faint, inner)
        end
        cell(ix, row, MC.staged, 8, m.staged and human(m.staged) or "-", C.dim, inner)
        cell(ix, row, MC.fluid, 21, m.hatchFluid or "(empty)",
            m.hatchFluid and C.mine or C.faint, inner)
        -- A change asked for but not yet made. Without this a parameter write
        -- that is waiting on a forty-second mining operation looks like one that
        -- silently did nothing.
        cell(ix, row, MC.pending, inner - MC.pending, m.pending or "",
            C.warn, inner)
    end
end

-- Column layout shared by KITS and PLASMA -- the two panels differ only in their
-- units and in the gutter marker, so using one set of offsets keeps them reading
-- as the same table side by side. "Plutonium-241 Plasma" is 20 characters, which
-- is what sets the name column.
local SC = { gutter = 0, name = 2, stock = 22, bar = 39, pct = 50, job = 55 }
local SC_END = 64   -- total width a full row wants

local function drawStockHeader(x, y, inner, nameLabel)
    cell(x, y, SC.name, 20, nameLabel, C.faint, inner)
    cell(x, y, SC.stock, 17, padL("STOCK", 7) .. " /" .. padL("TARGET", 7), C.faint, inner)
    cell(x, y, SC.bar, 11, "LEVEL", C.faint, inner)
    cell(x, y, SC.job, 9, "JOB", C.faint, inner)
end

local function drawStockRow(x, y, inner, e, gutter, gutterColor)
    local wanted = (e.target or 0) > 0
    local frac = e.fill or 0
    cell(x, y, SC.gutter, 2, gutter or " ", gutterColor or C.faint, inner)
    cell(x, y, SC.name, 20, e.name, C.text, inner)

    -- Nothing is demanded of an entry with no target, so it gets no bar and no
    -- percentage: "100%" against a target of zero reads as "full" when it means
    -- "not asked for", which is the opposite of reassuring.
    cell(x, y, SC.stock, 17,
        padL(human(e.have), 7) .. " /" .. padL(wanted and human(e.target) or "-", 7),
        wanted and C.dim or C.faint, inner)

    if wanted then
        if inner - SC.bar >= 10 then
            bar(x + SC.bar, y, 10, frac, fillColor(frac), C.panelHi)
        end
        cell(x, y, SC.pct, 5, padL(string.format("%d%%", math.floor(frac * 100 + 0.5)), 4),
            fillColor(frac), inner)
    else
        cell(x, y, SC.bar, 16, "", C.faint, inner)
    end

    -- Why a row that is short is not being acted on. "craft xN" while the job is
    -- still on a CPU; "settling" for the moment after one lands, while the network
    -- catches up with what was pushed into it; "no pattern" when there is nothing
    -- that could deliver it at all.
    if e.missing then
        cell(x, y, SC.job, 11, "no pattern", C.crit, inner)
    elseif (e.crafts or 0) > 0 then
        cell(x, y, SC.job, 9, "craft x" .. e.crafts, C.accent2, inner)
    elseif e.settling then
        cell(x, y, SC.job, 9, "settling", C.accent, inner)
    else
        cell(x, y, SC.job, 9, "", C.faint, inner)
    end
end

local function drawKits(state, x, y, w, h)
    local list = state.kits or {}
    panel(x, y, w, h, "KITS  " .. #list .. " in demand  " .. MIDDOT .. "  whole kits")
    local ix, inner = x + 2, w - 4
    drawStockHeader(ix, y + 1, inner, "MATERIAL")
    if #list == 0 then
        cell(ix, y + 3, 0, inner, "Nothing in demand: no module has a drone loaded,", C.faint, inner)
        cell(ix, y + 4, 0, inner, "and cfg.supply.target names no material.", C.faint, inner)
        return
    end
    for i, e in ipairs(list) do
        local row = y + 1 + i
        if row > y + h - 2 then break end
        drawStockRow(ix, row, inner, e)
    end
end

local function drawPlasma(state, x, y, w, h)
    local list = state.plasmas or {}
    local focused = state.focus == "plasma"
    local title = "PLASMA  " .. MIDDOT .. "  litres"
    if state.confirm then title = "PLASMA  " .. EMDASH .. " CONFIRM"
    elseif focused then title = "PLASMA  " .. EMDASH .. " CHOOSE" end
    panel(x, y, w, h, title, focused)

    local ix, inner = x + 2, w - 4
    drawStockHeader(ix, y + 1, inner, "FLUID")

    for i, e in ipairs(list) do
        local row = y + 1 + i
        if row > y + h - 3 then break end
        local gutter, gcolor = nil, nil
        if focused and state.cursor == i then gutter, gcolor = ARROW, C.focus
        elseif e.active then gutter, gcolor = DOT, C.mine end
        drawStockRow(ix, row, inner, e, gutter, gcolor)
    end

    -- Footer: what pressing a key would do right now. Two steps, because pointing
    -- the whole fleet at a different fluid drains every hatch it disagrees with.
    local fy = y + h - 2
    if state.confirm then
        cell(ix, fy, 0, inner, "Switch all modules to " .. state.confirm .. "?", C.warn, inner)
    elseif state.switching then
        cell(ix, fy, 0, inner, "Switching to " .. state.switching .. " ...", C.accent, inner)
    elseif focused then
        local pick = list[state.cursor or 1]
        cell(ix, fy, 0, inner, pick and ("ENTER selects " .. pick.name) or "", C.faint, inner)
    else
        cell(ix, fy, 0, inner, "Press P to change the fleet's plasma.", C.faint, inner)
    end
end

-- ---- the detail screen -------------------------------------------------------
--
-- One module, close up: its four drivable parameters on top, and underneath
-- either the meteor pool it is rolling against or the ore that comes out. Both
-- tables are computed from the PENDING value while a field is being edited, so
-- dialling the distance shows what it would do before it is committed.

local function drawParams(state, x, y, w, h)
    local d = state.detail or {}
    local m = d.miner or {}
    -- The mode belongs in this title above all: editing anything on this screen is
    -- what CLAIMS a module, so "AUTO" here is a warning that pressing ENTER changes
    -- more than the value being dialled.
    panel(x, y, w, h, "MODULE  " .. (m.tierName or "?") .. "  " .. (m.addr or "")
        .. "  " .. MIDDOT .. "  " .. (m.auto and "AUTO" or "MANUAL"),
        d.edit ~= nil)
    local ix, inner = x + 2, w - 4

    for i, f in ipairs(d.fields or {}) do
        local row = y + i
        if row > y + h - 4 then break end
        local selected = (d.field == i)
        local editing = selected and d.edit ~= nil

        cell(ix, row, 0, 2, (selected and ARROW) or " ",
            editing and C.focus or (selected and C.accent or C.faint), inner)
        cell(ix, row, 2, 12, f.label, selected and C.text or C.dim, inner)

        -- An edited value is shown between arrows and in the focus colour, so
        -- what is pending and what is live are never the same thing on screen.
        if editing then
            cell(ix, row, 14, 26, "\xE2\x97\x82 " .. tostring(f.pending) .. " \xE2\x96\xB8",
                C.focus, inner)
        elseif f.queued then
            -- Asked for, not yet taken: both values, so it is clear which is which.
            cell(ix, row, 14, 26,
                tostring(f.value or "-") .. " \xE2\x86\x92 " .. tostring(f.queued),
                C.warn, inner)
        else
            cell(ix, row, 14, 26, tostring(f.value or "-"),
                f.value and C.text or C.faint, inner)
        end
        cell(ix, row, 41, inner - 41, f.note or "",
            f.queued and C.warn or C.faint, inner)
    end

    local sy = y + h - 3
    if d.edit then
        cell(ix, sy, 0, inner, d.editHint or "", C.focus, inner)
    else
        cell(ix, sy, 0, inner,
            "State " .. (m.state or "?") .. "   " .. (d.summary or "")
            .. (m.auto and "   " .. MIDDOT .. "  editing anything here takes this "
                .. "module off the controller" or ""),
            STATE_COLOR[m.stateKind or m.state] or C.dim, inner)
    end
    cell(ix, y + h - 2, 0, inner, d.rates or "", C.dim, inner)
end

-- RUNTIME | METEOR | SIZE | TIME | CHANCE | PAR | EU/t | COMP, with the bar on the
-- runtime.
--
-- RUNTIME leads because it is the answer to the question people bring to this
-- table. CHANCE is how often a meteor is rolled; RUNTIME is how much of the clock
-- it eats -- the chance weighted by how long it takes -- and they come apart
-- badly. Something rolled one time in seven that takes four times as long as the
-- rest is where a third of the module's life goes, so it is RUNTIME that says which
-- meteor is setting the throughput. The rows are sorted by it too.
-- SERVES shares the last stretch with the note, because they are never both worth
-- saying: a meteor the module cannot power serves nothing whatever it yields, so the
-- note wins where there is one and the wants fill the space the rest of the time.
local PC = { bar = 0, pct = 11, name = 17, size = 45, time = 58, chance = 67,
             par = 78, eut = 84, comp = 95, note = 105 }

local function drawPool(state, x, y, w, h)
    local d = state.detail or {}
    local list = d.pool or {}
    local first, last, span = window(list, state.scroll, h - 3)
    panel(x, y, w, h, "METEOR POOL  " .. span .. "  " .. MIDDOT
        .. "  by share of running time  " .. MIDDOT .. "  TAB for ore output")
    local ix, inner = x + 2, w - 4
    local hy = y + 1

    cell(ix, hy, PC.bar, 10, "RUNTIME", C.faint, inner)
    cell(ix, hy, PC.name, 27, "METEOR", C.faint, inner)
    cell(ix, hy, PC.size, 12, "SIZE", C.faint, inner)
    cell(ix, hy, PC.time, 8, "TIME", C.faint, inner)
    cell(ix, hy, PC.chance, 10, padL("CHANCE", 9), C.faint, inner)
    cell(ix, hy, PC.par, 5, "PAR", C.faint, inner)
    cell(ix, hy, PC.eut, 10, "EU/t", C.faint, inner)
    cell(ix, hy, PC.comp, 9, "COMP", C.faint, inner)
    cell(ix, hy, PC.note, inner - PC.note, "SERVES", C.faint, inner)

    if d.error then
        cell(ix, y + 3, 0, inner, d.error, C.warn, inner)
        return
    end
    if #list == 0 then
        cell(ix, y + 3, 0, inner,
            "Nothing is findable at this distance with this drone.", C.faint, inner)
        return
    end

    -- The bars are scaled to the BIGGEST share rather than to 100%: no single
    -- meteor holds much more than a third of the time, so absolute bars would all
    -- sit in the first few cells and compare nothing. The percentage beside each
    -- one is the absolute figure; the bar is for reading the ranking at a glance.
    local top = 0
    for _, e in ipairs(list) do
        if (e.share or 0) > top then top = e.share end
    end

    for i = first, last do
        local e = list[i]
        local row = y + 1 + (i - first) + 1
        -- A meteor is highlighted when it serves a want AND can actually be run:
        -- highlighting one the module cannot power would advertise ore that is not
        -- coming, which is the opposite of what the marking is for.
        local serving = e.serves ~= nil and not e.blocked
        local bg = rowBg(ix, row, inner, serving)
        local col = e.blocked and C.crit or (serving and C.mine or C.text)
        if inner - PC.bar >= 10 then
            bar(ix + PC.bar, row, 10, (top > 0) and ((e.share or 0) / top) or 0,
                e.blocked and C.crit or C.accent2, serving and C.panel or C.panelHi)
        end
        cell(ix, row, PC.pct, 6, padL(e.runtime or "-", 5),
            e.blocked and C.faint or C.text, inner, bg)
        cell(ix, row, PC.name, 27, e.name or "?", col, inner, bg)
        cell(ix, row, PC.size, 12, e.size or "-", C.dim, inner, bg)
        cell(ix, row, PC.time, 8, e.time or "-", C.dim, inner, bg)
        cell(ix, row, PC.chance, 10,
            padL(string.format("%.1f%%", (e.chance or 0) * 100), 9), C.dim, inner, bg)
        cell(ix, row, PC.par, 5, tostring(e.parallels or "-"), C.dim, inner, bg)
        cell(ix, row, PC.eut, 10, e.eut or "-", C.dim, inner, bg)
        cell(ix, row, PC.comp, 9, e.computation or "-", C.dim, inner, bg)
        cell(ix, row, PC.note, inner - PC.note, e.note or e.serves or "",
            e.note and C.crit or C.mine, inner, bg)
    end
end

-- SHARE | ORE | ITEMS/s | STACKS/s | PER HOUR | STOCK / WANT | FILL, with a bar for
-- the share. The last two are the marking: they say whether the ore this
-- configuration is producing is ore anybody asked for.
local YC = { bar = 0, pct = 11, name = 17, items = 47, stacks = 60, hour = 73,
             want = 88 }

local function drawYield(state, x, y, w, h)
    local d = state.detail or {}
    local list = d.yield or {}
    local first, last, span = window(list, state.scroll, h - 3)
    panel(x, y, w, h, "ORE OUTPUT  " .. span .. "  " .. MIDDOT .. "  TAB for the meteor pool")
    local ix, inner = x + 2, w - 4
    local hy = y + 1

    cell(ix, hy, YC.bar, 10, "SHARE", C.faint, inner)
    cell(ix, hy, YC.name, 29, "ORE", C.faint, inner)
    cell(ix, hy, YC.items, 12, padL("ITEMS/s", 11), C.faint, inner)
    cell(ix, hy, YC.stacks, 12, padL("STACKS/s", 11), C.faint, inner)
    cell(ix, hy, YC.hour, 12, padL("PER HOUR", 11), C.faint, inner)
    cell(ix, hy, YC.want, 26, "STOCK / WANT", C.faint, inner)

    if d.error then
        cell(ix, y + 3, 0, inner, d.error, C.warn, inner)
        return
    end
    if #list == 0 then
        cell(ix, y + 3, 0, inner, "Nothing would be mined at this configuration.",
            C.faint, inner)
        return
    end

    for i = first, last do
        local e = list[i]
        local row = y + 1 + (i - first) + 1
        local want = wantOf(state, e.name)
        local bg = rowBg(ix, row, inner, want)
        if inner - YC.bar >= 10 then
            -- The empty half of the bar has to invert on a highlighted row: its
            -- usual colour IS the highlight, and a full-looking bar on every wanted
            -- ore would be a lie told by the palette.
            bar(ix + YC.bar, row, 10, e.share or 0, C.mine,
                want and C.panel or C.panelHi)
        end
        cell(ix, row, YC.pct, 6, padL(string.format("%.1f%%", (e.share or 0) * 100), 5),
            C.dim, inner, bg)
        cell(ix, row, YC.name, 29, e.name or "?", want and C.mine or C.text, inner, bg)
        cell(ix, row, YC.items, 12, padL(rate(e.itemsPerSecond), 11), C.good, inner, bg)
        cell(ix, row, YC.stacks, 12, padL(string.format("%.3f", e.stacksPerSecond or 0), 11),
            C.dim, inner, bg)
        cell(ix, row, YC.hour, 12, padL(human((e.itemsPerSecond or 0) * 3600), 11),
            C.dim, inner, bg)
        drawWantCells(ix, row, inner, want, YC.want, bg)
    end
end

-- ---- the profile screen ------------------------------------------------------
--
-- Deliberately a screen rather than log lines: the log shows six at a time and
-- scrolls, and this is a table you want to sit and read while the cycles tick
-- over. `S` writes the same numbers to a file.

local function drawProfileTable(x, y, w, h, title, list, headers, isCalls)
    panel(x, y, w, h, title)
    local ix, inner = x + 2, w - 4
    local hy = y + 1
    local C1, C2, C3, C4, C5 = 0, 36, 46, 58, 70

    cell(ix, hy, C1, 34, headers[1], C.faint, inner)
    cell(ix, hy, C2, 9, padL(headers[2], 8), C.faint, inner)
    cell(ix, hy, C3, 11, padL(headers[3], 10), C.faint, inner)
    cell(ix, hy, C4, 11, padL(headers[4], 10), C.faint, inner)
    cell(ix, hy, C5, 11, padL(headers[5], 10), C.faint, inner)

    if #list == 0 then
        cell(ix, y + 3, 0, inner, "Nothing measured yet -- wait for a cycle.",
            C.faint, inner)
        return
    end

    -- Shade by share of the worst row, so the offender is visible without
    -- reading a single number.
    local worst = list[1].total
    for i, r in ipairs(list) do
        local row = y + 1 + i
        if row > y + h - 2 then
            cell(ix, y + h - 2, 0, inner,
                string.format("... and %d more", #list - i + 1), C.faint, inner)
            break
        end
        local share = worst > 0 and (r.total / worst) or 0
        local col = fillColor(1 - share)   -- the biggest total is the reddest

        cell(ix, row, C1, 34, r.name, C.text, inner)
        cell(ix, row, C2, 9, padL(isCalls and string.format("%.0f", r.perCycle)
            or tostring(r.n), 8), C.dim, inner)
        cell(ix, row, C3, 11, padL(string.format("%.3fs", r.timePerCycle), 10), col, inner)
        cell(ix, row, C4, 11, padL(string.format("%.2fs", r.total), 10), C.dim, inner)
        cell(ix, row, C5, 11, padL(isCalls and string.format("%.3fs", r.avg)
            or (r.calls and tostring(r.calls) or "-"), 10), C.dim, inner)
    end
end

local function drawProfile(state, x, y, w, h)
    local p = state.profile or {}
    local headH = 5
    panel(x, y, w, headH, "PROFILE  " .. MIDDOT .. "  [S] save to a file  [R] reset  [Q] back")
    local ix, inner = x + 2, w - 4

    cell(ix, y + 1, 0, inner, string.format(
        "%d cycle(s) over %.0fs   %d component call(s), %.2fs measured",
        p.cycles or 0, p.elapsed or 0, p.callCount or 0, p.callTotal or 0),
        C.text, inner)

    -- The line that usually answers the question. An OC component call that is
    -- not direct returns on the NEXT TICK, so it costs 50ms whatever it does --
    -- meaning a cycle's duration is mostly a function of how many calls it makes,
    -- not how heavy they are.
    local perCycle = (p.cycles or 0) > 0 and (p.callCount / p.cycles) or 0
    cell(ix, y + 2, 0, inner, string.format(
        "%.0f call(s) per cycle   %.2fs if every one were indirect (50ms each)",
        perCycle, perCycle * 0.05),
        perCycle * 0.05 > 1 and C.crit or C.dim, inner)

    cell(ix, y + 3, 0, inner, p.note or "", C.warn, inner)

    local half = math.floor((h - headH - 2) / 2)
    drawProfileTable(x, y + headH + 1, w, half, "PHASES", p.spans or {},
        { "PHASE", "N", "PER CYCLE", "TOTAL", "CALLS" }, false)
    drawProfileTable(x, y + headH + 1 + half + 1, w, h - headH - half - 2,
        "COMPONENT CALLS", p.calls or {},
        { "CALL", "N/CYCLE", "PER CYCLE", "TOTAL", "AVG" }, true)
end

-- ---- the advisor -------------------------------------------------------------
--
-- Asks the targeter what this module should be set to, and applies the answer.
-- One cursor runs down both panels -- the settings and then the recommendations --
-- so there is no mode to be in and no second key to remember: ENTER on a setting
-- changes it, ENTER on a recommendation applies it.

local function drawAdviseSettings(state, x, y, w, h)
    local a = state.advise or {}
    local m = a.miner or {}
    panel(x, y, w, h, "ADVISE  " .. (m.tierName or "?") .. "  " .. (m.addr or ""),
        a.edit ~= nil or a.picking ~= nil)
    local ix, inner = x + 2, w - 4

    for i, f in ipairs(a.settings or {}) do
        local row = y + i
        if row > y + h - 3 then break end
        local selected = (a.cursor == i)
        local editing = selected and a.edit ~= nil

        cell(ix, row, 0, 2, selected and ARROW or " ",
            editing and C.focus or (selected and C.accent or C.faint), inner)
        cell(ix, row, 2, 12, f.label, selected and C.text or C.dim, inner)
        if editing then
            cell(ix, row, 14, 28, "\xE2\x97\x82 " .. tostring(f.pending) .. " \xE2\x96\xB8",
                C.focus, inner)
        else
            -- A pin reads differently from "any": one is a decision, the other is
            -- the absence of one, and the search treats them completely differently.
            cell(ix, row, 14, 28, f.value or "any",
                f.pinned and C.accent2 or (f.value and C.text or C.faint), inner)
        end
        cell(ix, row, 43, inner - 43, f.note or "", C.faint, inner)
    end

    local sy = y + h - 3
    if a.error then
        cell(ix, sy, 0, inner, a.error, C.crit, inner)
    elseif a.edit then
        cell(ix, sy, 0, inner, "ENTER pins it and searches again; Q leaves it as it was",
            C.focus, inner)
    else
        cell(ix, sy, 0, inner, a.summary or "", C.dim, inner)
    end

    -- What applying just did, and what the module is still waiting on. Without
    -- these the screen is identical before and after an apply: the changes are
    -- queued, the log is hidden unless asked for, and a parameter write waits for
    -- the module to finish its operation.
    local py = y + h - 2
    if a.applied then
        cell(ix, py, 0, inner, "\xE2\x9C\x93 " .. a.applied, C.good, inner)
    elseif a.pending then
        cell(ix, py, 0, inner, "pending: " .. a.pending
            .. (a.pendingNote and ("  -- " .. a.pendingNote) or ""), C.warn, inner)
    else
        cell(ix, py, 0, inner, "", C.faint, inner)
    end
end

-- The plasma NAME column lost eight columns to make room for the plasma RATE:
-- every value in it ended in " Plasma", which carries no information when the
-- header already says so.
local AC = {
    cur = 0, score = 2, drone = 14, dist = 23, plasma = 34, od = 49,
    rate = 56, purity = 70, eut = 79, kits = 91, lps = 103, why = 116,
}

local function drawAdviseResults(state, x, y, w, h)
    local a = state.advise or {}
    local ix, inner = x + 2, w - 4

    -- The material list takes over this panel while one is being chosen: it is
    -- where the room is, and nothing below matters until the choice is made.
    if a.picking then
        panel(x, y, w, h, "CHOOSE A MATERIAL  " .. MIDDOT
            .. "  a letter jumps to it  " .. MIDDOT .. "  ENTER picks", true)
        local list = a.picking.list or {}
        local rows = h - 2
        -- Keep the cursor centred so paging through 154 names does not jump about.
        local first = math.max(1, math.min((a.picking.cursor or 1) - math.floor(rows / 2),
            #list - rows + 1))
        for i = 0, rows - 1 do
            local idx = first + i
            local name = list[idx]
            if not name then break end
            local sel = (idx == a.picking.cursor)
            cell(ix, y + 1 + i, 0, 2, sel and ARROW or " ", C.focus, inner)
            cell(ix, y + 1 + i, 2, inner - 2, name, sel and C.text or C.dim, inner)
        end
        return
    end

    local list = a.results or {}
    panel(x, y, w, h, "RECOMMENDED  " .. #list .. "  " .. MIDDOT
        .. "  ENTER applies it to this module")
    local hy = y + 1
    cell(ix, hy, AC.score, 11, padL("POINTS/ITEM", 11), C.faint, inner)
    cell(ix, hy, AC.drone, 8, "DRONE", C.faint, inner)
    cell(ix, hy, AC.dist, 10, "DISTANCE", C.faint, inner)
    cell(ix, hy, AC.plasma, 14, "PLASMA", C.faint, inner)
    cell(ix, hy, AC.od, 6, "OD", C.faint, inner)
    cell(ix, hy, AC.rate, 13, padL(a.rateLabel or "WANTED/s", 12), C.faint, inner)
    cell(ix, hy, AC.purity, 8, padL("PURE", 7), C.faint, inner)
    cell(ix, hy, AC.eut, 11, padL("EU/t", 10), C.faint, inner)
    cell(ix, hy, AC.kits, 11, padL("KITS/s", 10), C.faint, inner)
    cell(ix, hy, AC.lps, 12, padL("PLASMA L/s", 11), C.faint, inner)
    cell(ix, hy, AC.why, inner - AC.why, "", C.faint, inner)

    if #list == 0 then
        cell(ix, y + 3, 0, inner, a.empty or "Nothing to recommend.", C.warn, inner)
        for i, note in ipairs(a.notes or {}) do
            if y + 3 + i > y + h - 2 then break end
            cell(ix, y + 3 + i, 0, inner, note, C.faint, inner)
        end
        return
    end

    for i, r in ipairs(list) do
        local row = y + 1 + i
        if row > y + h - 2 then
            cell(ix, y + h - 2, 0, inner,
                string.format("... and %d more", #list - i + 1), C.faint, inner)
            break
        end
        local sel = (a.cursor == (a.settingsCount or 0) + i)
        -- A configuration nothing can supply is shown in red with what is missing,
        -- rather than silently sitting among ones that can be run.
        local bad = r.bad
        cell(ix, row, AC.cur, 2, sel and ARROW or " ", C.focus, inner)
        cell(ix, row, AC.score, 11, padL(r.score or "-", 10),
            bad and C.crit or (i == 1 and C.good or C.text), inner)
        cell(ix, row, AC.drone, 8, r.drone or "-", bad and C.crit or C.text, inner)
        cell(ix, row, AC.dist, 10, r.distance or "-", C.dim, inner)
        cell(ix, row, AC.plasma, 14, r.plasma or "-", bad and C.crit or C.mine, inner)
        cell(ix, row, AC.od, 6, r.overdrive or "-", C.dim, inner)
        cell(ix, row, AC.rate, 13, padL(r.rate or "-", 12),
            bad and C.crit or C.good, inner)
        cell(ix, row, AC.purity, 8, padL(r.purity or "-", 7), C.dim, inner)
        cell(ix, row, AC.eut, 11, padL(r.eut or "-", 10), C.dim, inner)
        cell(ix, row, AC.kits, 11, padL(r.kits or "-", 10), C.dim, inner)
        cell(ix, row, AC.lps, 12, padL(r.plasmaRate or "-", 11), C.dim, inner)
        cell(ix, row, AC.why, inner - AC.why, r.why or "", C.crit, inner)
    end
end

-- ---- the fleet breakdowns ----------------------------------------------------
--
-- The same two questions as a module's detail screen -- where does the time go,
-- and what comes out -- asked of the whole fleet. Both are plain sums over the
-- modules, which is why they are worth having: nothing here is an estimate of an
-- estimate.

local FM = { bar = 0, pct = 11, name = 17, mods = 47, time = 56, met = 65,
             eut = 79, ore = 92 }

local function drawFleetPool(state, x, y, w, h)
    local f = state.fleet or {}
    local list = f.meteors or {}
    local first, last, span = window(list, state.scroll, h - 3)
    panel(x, y, w, h, "FLEET METEOR POOL  " .. span .. "  " .. MIDDOT .. "  "
        .. (f.modules or 0) .. " module(s) counted  " .. MIDDOT
        .. "  [O] ore output  [Q] back")
    local ix, inner = x + 2, w - 4
    local hy = y + 1

    cell(ix, hy, FM.bar, 10, "RUNTIME", C.faint, inner)
    cell(ix, hy, FM.name, 29, "METEOR", C.faint, inner)
    cell(ix, hy, FM.mods, 8, "MODULES", C.faint, inner)
    cell(ix, hy, FM.time, 8, padL("TIME", 7), C.faint, inner)
    cell(ix, hy, FM.met, 13, padL("METEORS/s", 12), C.faint, inner)
    cell(ix, hy, FM.eut, 12, padL("EU/t", 11), C.faint, inner)
    -- The wants it serves where it serves any, and what it mostly drops otherwise.
    -- "Top ore" alone answered a question nobody was asking: the useful thing to
    -- know about a meteor eating a fifth of the fleet's clock is whether that fifth
    -- is going anywhere.
    cell(ix, hy, FM.ore, inner - FM.ore, "SERVES / TOP ORE", C.faint, inner)

    if #list == 0 then
        cell(ix, y + 3, 0, inner, f.empty
            or "No module is configured well enough to estimate.", C.warn, inner)
        return
    end

    local top = 0
    for _, e in ipairs(list) do
        if (e.share or 0) > top then top = e.share end
    end

    for i = first, last do
        local e = list[i]
        local row = y + 1 + (i - first) + 1
        local serving = e.serves ~= nil
        local bg = rowBg(ix, row, inner, serving)
        if inner - FM.bar >= 10 then
            bar(ix + FM.bar, row, 10, (top > 0) and (e.share / top) or 0,
                C.accent2, serving and C.panel or C.panelHi)
        end
        cell(ix, row, FM.pct, 6, padL(e.runtime or "-", 5), C.text, inner, bg)
        cell(ix, row, FM.name, 29, e.name or "?", serving and C.mine or C.text, inner, bg)
        cell(ix, row, FM.mods, 8, e.modules or "-", C.dim, inner, bg)
        cell(ix, row, FM.time, 8, padL(e.time or "-", 7), C.dim, inner, bg)
        cell(ix, row, FM.met, 13, padL(e.meteors or "-", 12), C.good, inner, bg)
        cell(ix, row, FM.eut, 12, padL(e.eut or "-", 11), C.dim, inner, bg)
        cell(ix, row, FM.ore, inner - FM.ore, e.serves or e.ore or "",
            serving and C.mine or C.faint, inner, bg)
    end
end

local FO = { bar = 0, pct = 11, name = 17, mods = 47, items = 56, stacks = 70,
             hour = 84, want = 99 }

local function drawFleetOre(state, x, y, w, h)
    local f = state.fleet or {}
    local list = f.ore or {}
    local first, last, span = window(list, state.scroll, h - 3)
    panel(x, y, w, h, "FLEET ORE OUTPUT  " .. span .. "  " .. MIDDOT .. "  "
        .. (f.totalItems or "0") .. " items/s in all  " .. MIDDOT
        .. "  [M] meteor pool  [Q] back")
    local ix, inner = x + 2, w - 4
    local hy = y + 1

    cell(ix, hy, FO.bar, 10, "SHARE", C.faint, inner)
    cell(ix, hy, FO.name, 29, "ORE", C.faint, inner)
    cell(ix, hy, FO.mods, 8, "MODULES", C.faint, inner)
    cell(ix, hy, FO.items, 13, padL("ITEMS/s", 12), C.faint, inner)
    cell(ix, hy, FO.stacks, 13, padL("STACKS/s", 12), C.faint, inner)
    cell(ix, hy, FO.hour, 13, padL("PER HOUR", 12), C.faint, inner)
    cell(ix, hy, FO.want, 26, "STOCK / WANT", C.faint, inner)

    if #list == 0 then
        cell(ix, y + 3, 0, inner, f.empty
            or "No module is configured well enough to estimate.", C.warn, inner)
        return
    end

    for i = first, last do
        local e = list[i]
        local row = y + 1 + (i - first) + 1
        local want = wantOf(state, e.name)
        local bg = rowBg(ix, row, inner, want)
        if inner - FO.bar >= 10 then
            bar(ix + FO.bar, row, 10, e.share or 0, C.mine,
                want and C.panel or C.panelHi)
        end
        cell(ix, row, FO.pct, 6, padL(string.format("%.1f%%", (e.share or 0) * 100), 5),
            C.dim, inner, bg)
        cell(ix, row, FO.name, 29, e.name or "?", want and C.mine or C.text, inner, bg)
        cell(ix, row, FO.mods, 8, e.modules or "-", C.dim, inner, bg)
        cell(ix, row, FO.items, 13, padL(e.items or "-", 12), C.good, inner, bg)
        cell(ix, row, FO.stacks, 13, padL(e.stacks or "-", 12), C.dim, inner, bg)
        cell(ix, row, FO.hour, 13, padL(e.hour or "-", 12), C.dim, inner, bg)
        drawWantCells(ix, row, inner, want, FO.want, bg)
    end
end

-- ---- the want list ----------------------------------------------------------
--
-- What the fleet is FOR, against what it is doing about it. Every other screen
-- answers a question about the hardware; this one is the only place the two sides
-- meet, so it carries both -- the ask (stock, want, fill) and the answer (what is
-- being produced, what share of the ask that covers, how long the shortfall would
-- take at that rate).
--
-- ETA is the line that gets read. A want at 40% with three modules on it is fine; a
-- want at 40% with an ETA of eleven hours is a fleet that is not really trying, and
-- neither the fill nor the rate says so on its own.
-- PER ORE earns a column of its own because it is the only figure on this screen the
-- controller cannot work out, and every number to the right of it is scaled by it: a
-- factor left at its default makes NEED/s, MAKING/s, COVER and FULL IN all wrong
-- together, and consistently enough to look right.
local WC = { bar = 0, pct = 11, material = 17, label = 40, stock = 66, per = 86,
             need = 94, made = 106, cover = 118, eta = 127, state = 137 }

local function drawWants(state, x, y, w, h)
    local wants = state.wants or {}
    local list = wants.rows or {}
    local first, last, span = window(list, state.scroll, h - 4)
    panel(x, y, w, h, "WANTS  " .. span .. "  " .. MIDDOT .. "  what the fleet is for"
        .. (wants.read and ("  " .. MIDDOT .. "  main net read " .. wants.read) or "")
        .. "  " .. MIDDOT .. "  [M] pool  [O] ore  [Q] back")
    local ix, inner = x + 2, w - 4
    local hy = y + 1

    cell(ix, hy, WC.bar, 10, "FILL", C.faint, inner)
    cell(ix, hy, WC.material, 22, "MATERIAL", C.faint, inner)
    cell(ix, hy, WC.label, 25, "ITEM", C.faint, inner)
    cell(ix, hy, WC.stock, 19, "STOCK / WANT", C.faint, inner)
    cell(ix, hy, WC.per, 7, "PER ORE", C.faint, inner)
    cell(ix, hy, WC.need, 11, padL("NEED/s", 10), C.faint, inner)
    cell(ix, hy, WC.made, 11, padL("MAKING/s", 10), C.faint, inner)
    cell(ix, hy, WC.cover, 8, padL("COVER", 7), C.faint, inner)
    cell(ix, hy, WC.eta, 10, padL("FULL IN", 9), C.faint, inner)
    cell(ix, hy, WC.state, inner - WC.state, "STATE", C.faint, inner)

    if #list == 0 then
        cell(ix, y + 3, 0, inner, wants.empty
            or "Nothing is wanted: mining/wants.lua lists no items.", C.warn, inner)
        cell(ix, y + 4, 0, inner, "Every AUTO module is left exactly as it is until "
            .. "something is listed there.", C.faint, inner)
        for i, note in ipairs(wants.notes or {}) do
            if y + 5 + i > y + h - 2 then break end
            cell(ix, y + 5 + i, 0, inner, note, C.crit, inner)
        end
        return
    end

    for i = first, last do
        local e = list[i]
        local row = y + 1 + (i - first) + 1
        local col = WANT_COLOR[e.state] or C.dim
        if inner - WC.bar >= 10 then
            bar(ix + WC.bar, row, 10, e.fill or 0,
                e.fill and fillColor(e.fill) or C.faint, C.panelHi)
        end
        cell(ix, row, WC.pct, 6, padL(e.pct or "-", 5), col, inner)
        cell(ix, row, WC.material, 22, e.material or "?", C.text, inner)
        -- The label is what the stock figure was read from, so a wrong one shows up
        -- here as an item nobody recognises next to a stock of zero.
        cell(ix, row, WC.label, 25, e.label or "(no item named)",
            e.label and C.mine or C.crit, inner)
        cell(ix, row, WC.stock, 19, e.stock or "-", C.dim, inner)
        -- Warned rather than dimmed when it is a default: nothing is wrong with the
        -- row, but nobody has said what the line yields, and every figure after this
        -- column is scaled by the guess.
        cell(ix, row, WC.per, 7, e.per or "-",
            e.perStated and C.dim or C.warn, inner)
        cell(ix, row, WC.need, 11, padL(e.need or "-", 10), C.dim, inner)
        -- MAKING is the fleet's answer to this row, and the one number here that is
        -- about the hardware: green when something is coming, red when nothing is.
        cell(ix, row, WC.made, 11, padL(e.made or "-", 10),
            (e.making and C.good) or C.crit, inner)
        cell(ix, row, WC.cover, 8, padL(e.coverPct or "-", 7),
            e.cover and fillColor(e.cover) or C.faint, inner)
        cell(ix, row, WC.eta, 10, padL(e.eta or "-", 9), C.dim, inner)
        -- The state alone. A row's note is always some form of "nothing is mining
        -- it", which the red 0.000 in MAKING/s and the 0% in COVER have already said
        -- twice -- and appending it here only truncated the state off the screen.
        cell(ix, row, WC.state, inner - WC.state, e.state or "", col, inner)
    end

    local sy = y + h - 2
    cell(ix, sy, 0, inner, (wants.summary and wants.summary.line or ""), C.dim, inner)
    -- A config problem is shown on the screen the config is about, not only in the
    -- log: a mistyped material is invisible everywhere else, since the entry it
    -- belongs to was dropped before any of this ran.
    local notes = wants.notes or {}
    if #notes > 0 then
        cell(ix, y + h - 3, 0, inner, notes[1]
            .. ((#notes > 1) and ("   (+" .. (#notes - 1) .. " more in the log)") or ""),
            C.crit, inner)
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

    -- Wipe the frame first. Panels only repaint the rectangles they cover, and the
    -- buffer keeps everything between frames, so anything OUTSIDE this frame's
    -- panels survived from the last one: the gutters between boxes, and worse, the
    -- whole region a different screen's layout used. Switching views left pieces of
    -- the old one stranded between the new one's boxes.
    --
    -- One fill for the whole screen, drawn off-screen like the rest of the frame,
    -- so it costs a single call and cannot flicker.
    rect(1, 1, W, H, C.bg)

    drawTitle(state)
    local kpiY = 3
    drawKPIs(state, kpiY)

    local contentY = kpiY + 5
    local logH = state.showLog and 8 or 0
    local logY = H - logH + 1
    local contentH = state.showLog and (logY - contentY - 1) or (H - contentY + 1)

    -- One chain, with the log/blit boilerplate ONCE after it. This used to be five
    -- near-identical blocks, each repeating those two lines and returning early --
    -- and two of them had quietly become duplicates, harmless only because they sat
    -- after a return. Adding a screen should not mean copying that again.
    if state.screen == "fleetMeteors" then
        drawFleetPool(state, 2, contentY, W - 2, contentH)

    elseif state.screen == "fleetOre" then
        drawFleetOre(state, 2, contentY, W - 2, contentH)

    elseif state.screen == "wants" then
        drawWants(state, 2, contentY, W - 2, contentH)

    elseif state.screen == "advise" then
        local a = state.advise or {}
        local settingsH = #(a.settings or {}) + 5
        drawAdviseSettings(state, 2, contentY, W - 2, settingsH)
        drawAdviseResults(state, 2, contentY + settingsH + 1, W - 2,
            contentH - settingsH - 1)

    elseif state.screen == "profile" then
        drawProfile(state, 2, contentY, W - 2, contentH)

    -- One module, close up. The parameter block is fixed; whichever table is
    -- selected takes the rest.
    elseif state.screen == "detail" then
        local paramsH = #(state.detail and state.detail.fields or {}) + 6
        drawParams(state, 2, contentY, W - 2, paramsH)
        local tableY = contentY + paramsH + 1
        local tableH = contentH - paramsH - 1
        if (state.detail or {}).view == "ore" then
            drawYield(state, 2, tableY, W - 2, tableH)
        else
            drawPool(state, 2, tableY, W - 2, tableH)
        end

    else
        -- The dashboard. The stock panels are sized to their contents (there are
        -- only ever nine materials and five plasmas) and the modules table takes
        -- everything left, because that is the list that grows as the player
        -- builds more of them.
        local stockRows = math.max(#(state.kits or {}), #(state.plasmas or {}), 5)
        local stocksH = math.max(9, math.min(stockRows + 5, contentH - 7))
        local minersH = contentH - stocksH - 1
        local stocksY = contentY + minersH + 1

        drawMiners(state, 2, contentY, W - 2, minersH)

        -- The plasma panel's width is fixed by its contents (SC_END plus the
        -- panel's own chrome); kits takes whatever is left, and on a screen too
        -- narrow for both, each row clips itself rather than spilling over.
        local rightW = math.min(SC_END + 4, math.floor((W - 3) / 2))
        local leftW = W - rightW - 3
        drawKits(state, 2, stocksY, leftW, stocksH)
        drawPlasma(state, 2 + leftW + 1, stocksY, rightW, stocksH)
    end

    if state.showLog then drawLog(state, 2, logY, W - 2, logH) end
    if buffer then gpu.bitblt(0, 1, 1, W, H, buffer, 1, 1) end
end

return ui

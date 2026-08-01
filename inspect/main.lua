-- Interactive component inspector. Enumerates every component wired to the
-- computer and shows them in a scrollable, selectable table (address, type,
-- name, slot, method count). Pick one with the keyboard and hit Enter to open a
-- detail screen listing all of that component's methods and their in-game
-- documentation strings.
--
-- Think of it as a full-screen, browsable version of the one-shot `probe`
-- tools -- handy for discovering the API of a machine before writing a script
-- for it.
--
-- Run from this folder:  main
--
-- Controls
--   list screen:   W/S or Up/Down   move selection
--                  A/D or Left/Right or PgUp/PgDn   page
--                  Home / End       jump to first / last
--                  Enter            open the selected component's methods
--                  R                rescan the component list
--                  Q / Esc          quit
--   detail screen: W/S or Up/Down   scroll one line
--                  A/D or PgUp/PgDn page
--                  Home / End       jump to top / bottom
--                  Q / Backspace    back to the list
--
-- Needs a GPU + screen + keyboard. With no GPU it falls back to printing a
-- plain, non-interactive table (so it is still useful on a headless machine).

local component = require("component")
local event = require("event")
local keyboard = require("keyboard")
local K = keyboard.keys
local ESC = 0x01 -- not in the keyboard.keys table but this is Esc's scan code

-- ---- component discovery -------------------------------------------------

-- Method names, in preference order, that we treat as "the component's name".
-- The first one a component actually exposes is called (read-only, pcall'd) to
-- fill the NAME column. getName covers GregTech machines; the others catch
-- inventories and labelled blocks.
local NAME_METHODS = { "getName", "getLabel", "getInventoryName" }

-- Reads a short display name for a component, or nil. Only calls a getter that
-- the component actually advertises, and guards the call so a misbehaving
-- method can never abort the scan.
local function readName(addr, methods)
    for _, m in ipairs(NAME_METHODS) do
        if methods[m] then
            local ok, val = pcall(component.invoke, addr, m)
            if ok and type(val) == "string" and val ~= "" then
                return val
            end
        end
    end
    return nil
end

-- Walks component.list() and gathers a display row per component. methods (the
-- name->isDirect map) is kept on each entry so the detail screen can reuse it
-- without a second lookup; only the (potentially large) doc strings are fetched
-- lazily, when a component is actually opened.
local function scan()
    local list = {}
    for addr, ctype in component.list() do
        local ok, methods = pcall(component.methods, addr)
        if not ok or type(methods) ~= "table" then methods = {} end

        local mcount, direct = 0, 0
        for _, isDirect in pairs(methods) do
            mcount = mcount + 1
            if isDirect then direct = direct + 1 end
        end

        local slot
        local sok, s = pcall(component.slot, addr)
        if sok and type(s) == "number" and s >= 0 then slot = s end

        list[#list + 1] = {
            addr    = addr,
            type    = ctype,
            name    = readName(addr, methods),
            slot    = slot,
            methods = methods,
            mcount  = mcount,
            direct  = direct,
        }
    end
    table.sort(list, function(a, b)
        if a.type ~= b.type then return a.type < b.type end
        return a.addr < b.addr
    end)
    return list
end

-- ---- headless fallback ---------------------------------------------------

-- Plain, non-interactive dump used when there is no GPU/screen to draw on.
local function printPlain(list)
    print("== Connected components (" .. #list .. ") ==")
    for _, c in ipairs(list) do
        local extra = c.name and ("  " .. c.name) or ""
        print(string.format("%-26s %s  (%d methods)%s", c.type, c.addr, c.mcount, extra))
    end
    print("No GPU/screen -- interactive mode unavailable. Run `probe <type>` for method docs.")
end

-- ---- rendering primitives (tier-3 GPU, double-buffered) ------------------

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
    titleBg = 0x161634,
    white   = 0xFFFFFF,
    black   = 0x000000,
}

-- Box-drawing / marker glyphs as UTF-8 byte escapes (Lua 5.2-safe).
local BOX = {
    tl = "\xE2\x94\x8C", tr = "\xE2\x94\x90", bl = "\xE2\x94\x94",
    br = "\xE2\x94\x98", h = "\xE2\x94\x80", v = "\xE2\x94\x82",
}
local ARROW  = "\xE2\x96\xB8" -- right triangle (selection marker)
local UPTRI  = "\xE2\x96\xB2" -- up triangle (more-above indicator)
local DOWNTRI = "\xE2\x96\xBC" -- down triangle (more-below indicator)
local EMDASH = "\xE2\x80\x94"

local gpu, W, H, buffer
local origW, origH, origDepth
local L -- computed layout (column offsets, panel geometry)

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

-- Shortens a 36-char component UUID to fit column width w (e.g. "2f4a1b..").
local function addrShort(addr, w)
    if #addr <= w then return addr end
    return addr:sub(1, w - 2) .. ".."
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

-- Wraps text to `width` columns, honouring embedded newlines and hard-splitting
-- any single token longer than the width. Returns a list of lines.
local function wrapText(s, width)
    if width < 1 then width = 1 end
    s = tostring(s):gsub("%s+$", "")
    local lines = {}
    for raw in (s .. "\n"):gmatch("(.-)\n") do
        if raw == "" then
            lines[#lines + 1] = ""
        else
            local cur = ""
            for word in raw:gmatch("%S+") do
                if cur == "" then
                    cur = word
                elseif #cur + 1 + #word <= width then
                    cur = cur .. " " .. word
                else
                    lines[#lines + 1] = cur
                    cur = word
                end
                while #cur > width do
                    lines[#lines + 1] = cur:sub(1, width)
                    cur = cur:sub(width + 1)
                end
            end
            if cur ~= "" then lines[#lines + 1] = cur end
        end
    end
    return lines
end

-- ---- lifecycle -----------------------------------------------------------

local function uiAvailable()
    return component.isAvailable("gpu") and component.isAvailable("screen")
end

-- Precomputes table column offsets and the scroll-region geometry for the given
-- resolution. Columns adapt to width so the table stays readable from tier-1
-- (50 wide) up to tier-3 (160 wide).
local function computeLayout()
    local contentX = 3            -- panel border (1) + 1 pad
    local innerW = W - 4
    local typeW = (innerW >= 120 and 24) or (innerW >= 90 and 20) or 14
    local addrW = (innerW >= 110 and 36) or (innerW >= 78 and 14) or 8
    local slotW, mthW = 4, 4

    local xType = 2               -- 2-col selection marker precedes it
    local xAddr = xType + typeW + 1
    local xSlot = xAddr + addrW + 2
    local xMth  = xSlot + slotW + 1
    local xName = xMth + mthW + 2
    local nameW = math.max(4, innerW - xName)

    local panelY = 3
    local panelH = H - panelY     -- rows panelY..H-1, footer on row H
    local firstRow = panelY + 2   -- panelY = top border, +1 = header, +2 = data
    local lastRow  = panelY + panelH - 2

    -- Detail screen: 5-row header card at row 3, methods panel below it.
    local dPanelY = 9             -- header rows 3..7, gap on row 8
    local dPanelH = H - dPanelY   -- rows dPanelY..H-1, footer on row H
    local dFirst = dPanelY + 1
    local dLast  = dPanelY + dPanelH - 2

    L = {
        contentX = contentX, innerW = innerW,
        typeW = typeW, addrW = addrW, slotW = slotW, mthW = mthW,
        xType = xType, xAddr = xAddr, xSlot = xSlot, xMth = xMth,
        xName = xName, nameW = nameW,
        panelY = panelY, panelH = panelH,
        firstRow = firstRow, lastRow = lastRow,
        rows = lastRow - firstRow + 1,
        dPanelY = dPanelY, dPanelH = dPanelH,
        dFirst = dFirst, dLast = dLast,
        dRows = dLast - dFirst + 1,
    }
end

local function initUI()
    gpu = component.gpu
    origDepth = gpu.getDepth()
    origW, origH = gpu.getResolution()
    local mw, mh = gpu.maxResolution()
    W = math.min(mw, 160)
    H = math.min(mh, 50)
    pcall(gpu.setDepth, gpu.maxDepth())
    gpu.setResolution(W, H)

    -- Off-screen buffer so each redraw is blitted in one op (no flicker).
    buffer = nil
    if gpu.allocateBuffer ~= nil then
        local ok, idx = pcall(gpu.allocateBuffer, W, H)
        if ok and idx then buffer = idx end
    end
    if buffer then gpu.setActiveBuffer(buffer) end
    rect(1, 1, W, H, C.bg)
    if buffer then gpu.bitblt(0, 1, 1, W, H, buffer, 1, 1) end

    computeLayout()
end

local function shutdownUI()
    if not gpu then return end
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
end

-- Draws the top title bar and returns nothing. `right` is shown right-aligned.
local function titleBar(titleStr, right)
    rect(1, 1, W, 1, C.titleBg)
    text(2, 1, titleStr, C.accent, C.titleBg)
    if right then
        text(W - 1 - #right, 1, right, C.dim, C.titleBg)
    end
end

-- Draws the bottom hint bar.
local function footer(hint)
    rect(1, H, W, 1, C.titleBg)
    text(2, H, hint, C.faint, C.titleBg)
end

-- ---- list screen ---------------------------------------------------------

local function drawListRow(y, e, selected)
    local bg = selected and C.panelHi or C.panel
    if selected then rect(L.contentX - 1, y, L.innerW + 2, 1, bg) end
    if selected then text(L.contentX, y, ARROW, C.accent, bg) end

    text(L.contentX + L.xType, y, padR(e.type, L.typeW), selected and C.accent or C.text, bg)
    text(L.contentX + L.xAddr, y, padR(addrShort(e.addr, L.addrW), L.addrW), C.dim, bg)
    text(L.contentX + L.xSlot, y, padL(e.slot and tostring(e.slot) or "-", L.slotW), C.faint, bg)
    text(L.contentX + L.xMth,  y, padL(tostring(e.mcount), L.mthW), C.faint, bg)
    if e.name and e.name ~= "" then
        text(L.contentX + L.xName, y, padR(e.name, L.nameW), selected and C.text or C.dim, bg)
    else
        text(L.contentX + L.xName, y, padR(EMDASH, L.nameW), C.faint, bg)
    end
end

local function renderList(list, sel, top)
    if buffer then gpu.setActiveBuffer(buffer) end
    rect(1, 1, W, H, C.bg)

    titleBar(" COMPONENT INSPECTOR ", #list .. " components")
    panel(1, L.panelY, W, L.panelH, "COMPONENTS")

    -- Column header row.
    local hy = L.panelY + 1
    text(L.contentX + L.xType, hy, "TYPE", C.faint, C.panel)
    text(L.contentX + L.xAddr, hy, "ADDRESS", C.faint, C.panel)
    text(L.contentX + L.xSlot, hy, padL("SLOT", L.slotW), C.faint, C.panel)
    text(L.contentX + L.xMth,  hy, padL("MTH", L.mthW), C.faint, C.panel)
    text(L.contentX + L.xName, hy, "NAME", C.faint, C.panel)

    if #list == 0 then
        text(L.contentX, L.firstRow, "No components connected.", C.faint, C.panel)
    else
        for i = 0, L.rows - 1 do
            local idx = top + i
            if idx > #list then break end
            drawListRow(L.firstRow + i, list[idx], idx == sel)
        end
        -- More-above / more-below indicators on the right border.
        if top > 1 then text(W - 2, L.firstRow, UPTRI, C.accent, C.panel) end
        if top + L.rows - 1 < #list then text(W - 2, L.lastRow, DOWNTRI, C.accent, C.panel) end
    end

    footer("[W/S Up/Dn] move   [A/D PgUp/PgDn] page   [Enter] details   [R] rescan   [Q] quit")
    if #list > 0 then
        local pos = sel .. "/" .. #list
        text(W - 1 - #pos, H, pos, C.dim, C.titleBg)
    end

    if buffer then gpu.bitblt(0, 1, 1, W, H, buffer, 1, 1) end
end

-- ---- detail screen -------------------------------------------------------

-- Builds a flat, scrollable line model for a component's methods: a header line
-- per method (name + [direct] badge) followed by its wrapped documentation.
local function buildDetailLines(e, width)
    local names = {}
    for name in pairs(e.methods) do names[#names + 1] = name end
    table.sort(names)

    local lines = {}
    for _, name in ipairs(names) do
        lines[#lines + 1] = { kind = "method", name = name, direct = e.methods[name] }
        local ok, doc = pcall(component.doc, e.addr, name)
        if ok and doc and doc ~= "" then
            for _, dl in ipairs(wrapText(doc, width - 4)) do
                lines[#lines + 1] = { kind = "doc", text = dl }
            end
        else
            lines[#lines + 1] = { kind = "doc", text = "(no documentation)", faint = true }
        end
        lines[#lines + 1] = { kind = "blank" }
    end
    return lines
end

local function renderDetail(e, lines, top)
    if buffer then gpu.setActiveBuffer(buffer) end
    rect(1, 1, W, H, C.bg)

    titleBar(" " .. ARROW .. " " .. e.type, e.name or "")

    -- Header card: address / type / slot / method counts.
    local hy = 3
    box(1, hy, W, 5, C.border, C.panel)
    text(3, hy + 1, "Address", C.faint, C.panel)
    text(12, hy + 1, e.addr, C.text, C.panel)
    text(3, hy + 2, "Type", C.faint, C.panel)
    text(12, hy + 2, e.type, C.accent, C.panel)
    text(3, hy + 3, "Slot", C.faint, C.panel)
    text(12, hy + 3, e.slot and tostring(e.slot) or EMDASH, C.text, C.panel)
    local mid = math.floor(W / 2)
    text(mid, hy + 2, "Name", C.faint, C.panel)
    text(mid + 9, hy + 2, e.name and e.name ~= "" and e.name or EMDASH,
        e.name and C.text or C.faint, C.panel)
    text(mid, hy + 3, "Methods", C.faint, C.panel)
    text(mid + 9, hy + 3, e.mcount .. " (" .. e.direct .. " direct)", C.text, C.panel)

    -- Scrollable methods panel (geometry precomputed in computeLayout).
    panel(1, L.dPanelY, W, L.dPanelH, "METHODS & DOCUMENTATION")
    local first, last, visible = L.dFirst, L.dLast, L.dRows

    if #lines == 0 then
        text(3, first, "This component exposes no methods.", C.faint, C.panel)
    else
        for i = 0, visible - 1 do
            local ln = lines[top + i]
            if not ln then break end
            local y = first + i
            if ln.kind == "method" then
                text(3, y, padR(ARROW .. " " .. ln.name, W - 14), C.accent2, C.panel)
                if ln.direct then text(W - 10, y, "[direct]", C.faint, C.panel) end
            elseif ln.kind == "doc" then
                text(5, y, trunc(ln.text, W - 6), ln.faint and C.faint or C.dim, C.panel)
            end
        end
        if top > 1 then text(W - 2, first, UPTRI, C.accent, C.panel) end
        if top + visible - 1 < #lines then text(W - 2, last, DOWNTRI, C.accent, C.panel) end
    end

    footer("[W/S Up/Dn] scroll   [A/D PgUp/PgDn] page   [Home/End] jump   [Q/Bksp] back")

    if buffer then gpu.bitblt(0, 1, 1, W, H, buffer, 1, 1) end
end

-- ---- input helpers -------------------------------------------------------

local function isUp(c)   return c == K.up or c == K.w end
local function isDown(c) return c == K.down or c == K.s end
local function isPgUp(c) return c == K.pageUp or c == K.left or c == K.a end
local function isPgDn(c) return c == K.pageDown or c == K.right or c == K.d end
local function isEnter(c) return c == K.enter or c == K.numpadenter end

-- ---- main loop -----------------------------------------------------------

local function run()
    local list = scan()
    if not uiAvailable() then
        printPlain(list)
        return
    end

    initUI()

    local mode = "list"
    local sel, top = 1, 1                -- list: selection + first visible row
    local detail, dLines, dTop = nil, nil, 1  -- detail: entry, line model, scroll

    -- Keep the list selection on-screen after it moves.
    local function reveal()
        if sel < top then top = sel end
        if sel > top + L.rows - 1 then top = sel - L.rows + 1 end
        if top < 1 then top = 1 end
    end

    renderList(list, sel, top)

    while true do
        local _, _, _, code = event.pull("key_down")
        if code then
            if mode == "list" then
                local n = #list
                if code == K.q or code == ESC then
                    break
                elseif code == K.r then
                    list = scan()
                    sel = math.max(1, math.min(sel, #list))
                    reveal()
                elseif n > 0 and isEnter(code) then
                    detail = list[sel]
                    dLines = buildDetailLines(detail, L.innerW)
                    dTop = 1
                    mode = "detail"
                elseif n > 0 then
                    if isUp(code) then sel = math.max(1, sel - 1)
                    elseif isDown(code) then sel = math.min(n, sel + 1)
                    elseif isPgUp(code) then sel = math.max(1, sel - L.rows)
                    elseif isPgDn(code) then sel = math.min(n, sel + L.rows)
                    elseif code == K.home then sel = 1
                    elseif code == K["end"] then sel = n
                    end
                    reveal()
                end
            else -- detail
                if code == K.q or code == K.back or code == ESC then
                    mode = "list"
                else
                    local visible = L.dRows
                    local maxTop = math.max(1, #dLines - visible + 1)
                    if isUp(code) then dTop = math.max(1, dTop - 1)
                    elseif isDown(code) then dTop = math.min(maxTop, dTop + 1)
                    elseif isPgUp(code) then dTop = math.max(1, dTop - visible)
                    elseif isPgDn(code) then dTop = math.min(maxTop, dTop + visible)
                    elseif code == K.home then dTop = 1
                    elseif code == K["end"] then dTop = maxTop
                    end
                end
            end

            -- Redraw whichever screen is active now (handles mode transitions).
            if mode == "list" then
                renderList(list, sel, top)
            else
                renderDetail(detail, dLines, dTop)
            end
        end
    end
end

-- Restore the screen on any exit path (including a Ctrl-C interrupt, which
-- surfaces here as an error out of event.pull).
local ok, err = pcall(run)
shutdownUI()
if not ok then error(err, 0) end

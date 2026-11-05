-- Dashboard for the BHC controller. Pure display: renders the view table that
-- main.lua builds and decides nothing. A no-op (ui.active == false) without a
-- GPU and screen, so the controller also runs headless.

local component = require("component")
local unicode = require("unicode")

local ui = { active = false }

local gpu, W, H

local C = {
    bg = 0x0B0B12, panel = 0x15151F, border = 0x3A3A5C, text = 0xE6E6F0,
    dim = 0x9090A8, faint = 0x585870, accent = 0x8B7BFF, good = 0x3BD671,
    warn = 0xF2C94C, crit = 0xFF5C5C, info = 0x22D3EE, titleBg = 0x1E1840,
}

function ui.init()
    if not component.isAvailable("gpu") or not component.isAvailable("screen") then return false end
    gpu = component.gpu
    local ok = pcall(function()
        local mw, mh = gpu.maxResolution()
        gpu.setResolution(math.min(mw, 100), math.min(mh, 32))
    end)
    if not ok then return false end
    W, H = gpu.getResolution()
    gpu.setBackground(C.bg)
    gpu.fill(1, 1, W, H, " ")
    ui.active = true
    return true
end

function ui.shutdown()
    if not ui.active then return end
    gpu.setBackground(0x000000)
    gpu.setForeground(0xFFFFFF)
    gpu.fill(1, 1, W, H, " ")
    ui.active = false
    require("term").setCursor(1, 1)
end

-- Writes `text` at (x, y), padded/cut to `width` so old content is overwritten.
local function put(x, y, text, fg, bg, width)
    text = tostring(text)
    if width then
        local len = unicode.len(text)
        if len > width then text = unicode.sub(text, 1, width)
        else text = text .. string.rep(" ", width - len) end
    end
    gpu.setForeground(fg or C.text)
    gpu.setBackground(bg or C.bg)
    gpu.set(x, y, text)
end

local function holeColor(v)
    if v.fault then return C.crit end
    if v.hole == "open" then
        if v.S and v.S < 20 then return C.accent end
        return C.good
    end
    if v.hole == "unstable" then return C.crit end
    if v.hole == "unknown" then return C.warn end
    return C.dim
end

-- Stability bar from 0 to 100 with the 50% and 20% parallel thresholds marked.
local function stabilityBar(y, v)
    local x0, w = 3, W - 4
    local S = v.S or 0
    local filled = math.max(0, math.min(w, math.floor(w * S / 100 + 0.5)))
    local color = holeColor(v)
    gpu.setBackground(color)
    gpu.fill(x0, y, filled, 1, " ")
    gpu.setBackground(C.panel)
    gpu.fill(x0 + filled, y, w - filled, 1, " ")
    for _, mark in ipairs({ 20, 50 }) do
        local mx = x0 + math.floor(w * mark / 100 + 0.5)
        put(mx, y, "|", C.text, mx < x0 + filled and color or C.panel)
        put(mx - 1, y + 1, mark .. "%", C.faint, C.bg)
    end
end

local function fmtTime(s)
    if not s then return "-" end
    s = math.floor(s + 0.5)
    if s == math.huge then return "inf" end
    if s >= 3600 then return string.format("%dh%02dm", math.floor(s / 3600), math.floor(s % 3600 / 60)) end
    if s >= 60 then return string.format("%dm%02ds", math.floor(s / 60), s % 60) end
    return s .. "s"
end
ui.fmtTime = fmtTime

-- view: see buildView() in main.lua
function ui.render(v)
    if not ui.active then return end
    local y = 1
    local title = " BLACK HOLE CONTROLLER"
    local badge = (v.dryRun and " DRY RUN " or "") .. (v.paused and " PAUSED " or "")
    put(1, y, title, C.text, C.titleBg, W)
    if badge ~= "" then put(W - unicode.len(badge) - 9, y, badge, 0x000000, C.warn) end
    put(W - 8, y, v.clock or "", C.dim, C.titleBg)
    y = y + 2

    local holeText
    if v.hole == "closed" then holeText = "CLOSED"
    elseif v.hole == "unknown" then holeText = "OPEN, STABILITY UNKNOWN"
    elseif v.hole == "unstable" then
        holeText = string.format("UNSTABLE  -- voids recipes, closes itself in %s", fmtTime(v.closesIn))
    else
        holeText = string.format("OPEN  %d%%   x%d parallels", v.S, v.mult or 1)
    end
    put(2, y, holeText, holeColor(v), C.bg, W - 2)
    y = y + 1
    stabilityBar(y, v)
    y = y + 3

    local function row(label, value, color)
        put(2, y, label, C.dim, C.bg, 14)
        put(16, y, value, color or C.text, C.bg, W - 16)
        y = y + 1
    end

    row("Doing", v.why or "", v.fault and C.crit or C.info)
    row("Spacetime", string.format("%s L in tank%s",
        v.tank or "?", v.feeding and "   HATCH ON" or ""), v.feeding and C.accent or nil)
    if v.hole == "open" or v.hole == "unstable" then
        row("Hold cost", string.format("%d L/s, doubles in %ds   held %s (+%s void prot.)   spent %d L",
            v.costMod, 30 - v.counter, fmtTime(v.held), fmtTime(v.vpHeld), v.spent))
        if v.life then row("Hole life", fmtTime(v.life) .. " with the hold budget left") end
    else
        row("Hold cost", "-")
    end
    row("Machine", string.format("%s%s   recipe ~%s",
        v.active and "RUNNING" or "idle",
        v.active and (" (" .. fmtTime(v.remaining) .. " left)") or "",
        fmtTime(v.recipeEst)) .. (v.workAllowed == false and "   [new recipes blocked]" or ""),
        v.active and C.good or C.dim)
    row("Requested", v.requested and "yes" or "no", v.requested and C.good or C.dim)
    row("Stock", string.format("%d seeds, %d collapsers%s", v.seeds or 0, v.collapsers or 0,
        v.pending and ("   [" .. v.pending .. " in the bus]") or ""))
    y = y + 1

    put(2, y, "Log", C.dim, C.bg, W - 2)
    y = y + 1
    local logH = H - y + 1
    local msgs = v.messages or {}
    local first = math.max(1, #msgs - logH + 1)
    for i = 0, logH - 1 do
        local m = msgs[first + i]
        local color = C.dim
        if m and (m:find("ERROR") or m:find("FAULT")) then color = C.crit
        elseif m and m:find("WARN") then color = C.warn end
        put(2, y + i, m or "", color, C.bg, W - 2)
    end
end

return ui

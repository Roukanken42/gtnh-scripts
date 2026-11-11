-- Dashboard for the DTPF controller. Pure display: renders the view table that
-- main.lua builds and decides nothing. A no-op (ui.active == false) without a
-- GPU and screen, so the controller also runs headless.

local component = require("component")
local unicode = require("unicode")

local ui = { active = false }

local gpu, W, H

local C = {
    bg = 0x0B0B12, panel = 0x15151F, text = 0xE6E6F0, dim = 0x9090A8, faint = 0x585870,
    accent = 0x8B7BFF, good = 0x3BD671, warn = 0xF2C94C, crit = 0xFF5C5C, info = 0x22D3EE,
    titleBg = 0x1E1840,
}

local oldW, oldH

-- The dashboard uses the full resolution the GPU and screen allow (160x50 at
-- tier 3); the one the shell had is put back on exit.
function ui.init()
    if not component.isAvailable("gpu") or not component.isAvailable("screen") then return false end
    gpu = component.gpu
    local ok = pcall(function()
        oldW, oldH = gpu.getResolution()
        gpu.setResolution(gpu.maxResolution())
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
    if oldW then pcall(gpu.setResolution, oldW, oldH) end
    local w, h = gpu.getResolution()
    gpu.fill(1, 1, w, h, " ")
    ui.active = false
    require("term").setCursor(1, 1)
end

-- Rows written during the current frame; the rest are blanked at its end, so
-- nothing is left over when the layout shifts.
local drawn = {}

-- Writes `text` at (x, y), padded/cut to `width` so old content is overwritten.
local function put(x, y, text, fg, bg, width)
    if x > W or y > H then return end
    drawn[y] = true
    text = tostring(text)
    if width then
        width = math.min(width, W - x + 1)
        local len = unicode.len(text)
        if len > width then text = unicode.sub(text, 1, width)
        else text = text .. string.rep(" ", width - len) end
    end
    gpu.setForeground(fg or C.text)
    gpu.setBackground(bg or C.bg)
    gpu.set(x, y, text)
end

local function si(n)
    if not n then return "?" end
    local a = math.abs(n)
    if a >= 1e9 then return string.format("%.2fG", n / 1e9) end
    if a >= 1e6 then return string.format("%.2fM", n / 1e6) end
    if a >= 1e4 then return string.format("%.1fk", n / 1e3) end
    return string.format("%d", math.floor(n + 0.5))
end

local function fmtTime(s)
    s = math.floor((s or 0) + 0.5)
    if s >= 3600 then return string.format("%dh%02dm", s // 3600, s % 3600 // 60) end
    if s >= 60 then return string.format("%dm%02ds", s // 60, s % 60) end
    return s .. "s"
end

-- A fill bar, `w` wide, for 0..1 (and beyond, capped).
local function bar(x, y, w, frac, color)
    drawn[y] = true
    local filled = math.max(0, math.min(w, math.floor(w * math.min(frac, 1) + 0.5)))
    gpu.setBackground(color)
    gpu.fill(x, y, filled, 1, " ")
    gpu.setBackground(C.panel)
    gpu.fill(x + filled, y, w - filled, 1, " ")
end

-- view: see buildView() in main.lua
function ui.render(v)
    if not ui.active then return end
    drawn = {}
    local y = 1
    local badge = (v.dryRun and " DRY RUN " or "") .. (v.paused and " PAUSED " or "")
        .. (v.pin and (" PINNED " .. v.pin:upper() .. " ") or "")
    put(1, y, " DTPF PASSIVE CONTROLLER", C.text, C.titleBg, W)
    if badge ~= "" then put(W - unicode.len(badge) - 9, y, badge, 0x000000, C.warn) end
    put(W - 8, y, v.clock or "", C.dim, C.titleBg)
    y = y + 2

    -- the pick
    local pickText, pickColor = "nothing selected", C.dim
    if v.pick then
        for _, p in ipairs(v.products) do
            if p.name == v.pick then
                pickText = string.format("MAKING %s   %s%s   %s batch(es) in the stocker   (%s)",
                    p.name:upper(), p.variant or "?", p.catalyst and (" + " .. p.catalyst) or "",
                    tostring(p.batches or 0), v.pickWhy or "")
                pickColor = C.good
            end
        end
    elseif v.pickWhy then
        pickText, pickColor = "NOTHING RUNNABLE -- " .. v.pickWhy, C.crit
    end
    put(2, y, pickText, pickColor, C.bg, W - 2)
    y = y + 2

    -- products
    put(2, y, string.format("%-3s %-10s %2s %9s %9s %9s ", "", "product", "P", "stock", "target", "effective"),
        C.dim, C.bg, 48)
    put(50, y, "fill   unmet", C.dim, C.bg, 22)
    -- "selected" sits at the right edge; "runnable as" (or why not) gets
    -- everything between.
    local selX = math.max(102, W - 9)
    put(72, y, "runnable as", C.dim, C.bg, selX - 73)
    put(selX, y, "selected", C.dim, C.bg, W - selX + 1)
    y = y + 1
    for _, p in ipairs(v.products) do
        local fill = p.fill == math.huge and 0 or p.fill
        local color = p.selected and C.accent or (p.variant and C.text or C.faint)
        put(2, y, string.format("%-3s %-10s %2d %9s %9s %9s ", (p.selected and ">" or " ") .. p.key, p.name,
            p.priority or 1, si(p.stock), si(p.target), si(p.effective)), color, C.bg, 48)
        bar(50, y, 8, fill, p.capped and C.warn or (fill >= 1 and C.good or C.info))
        -- The most urgent uncovered layer: its priority and how much of it the
        -- stock covers. "ok" once every layer is covered.
        local unmet = p.level and string.format("P%d %3d%%", p.level, math.floor(p.levelFill * 100))
            or (p.fill == math.huge and "-" or "ok")
        put(59, y, unmet, p.level and C.warn or C.dim, C.bg, 12)
        local status = p.variant and (p.variant .. (p.catalyst and (" + " .. p.catalyst) or ""))
            or ("no: " .. tostring(p.why))
        put(72, y, status, p.variant and C.text or C.warn, C.bg, selX - 73)
        put(selX, y, fmtTime(p.share), C.dim, C.bg, W - selX + 1)
        y = y + 1
    end
    y = y + 1

    -- catalysts
    local parts = {}
    for _, c in ipairs(v.catalysts) do
        parts[#parts + 1] = string.format("%s %s%s", c.key, si(c.total), c.reserve > 0 and ("/" .. si(c.reserve)) or "")
    end
    put(2, y, "Catalysts", C.dim, C.bg, 12)
    put(14, y, table.concat(parts, "   ") .. (#parts > 0 and "   (main net / reserve)" or ""), C.text, C.bg, W - 14)
    y = y + 1
    put(2, y, "On the bus", C.dim, C.bg, 12)
    put(14, y, v.busCatalyst or "?", v.busCatalyst and C.accent or C.crit, C.bg, W - 14)
    y = y + 2

    -- machines
    local arr = v.arr
    put(2, y, string.format("DTPFs%s", arr and string.format("   checking against %d K%s", math.floor(arr.heat),
        arr.convergence and "   convergence" or "") or ""), C.dim, C.bg, W - 2)
    y = y + 1
    local logRows = 6
    local room = math.max(1, H - y - logRows - 1)
    local fs = v.forges or {}
    local cols = (#fs > room) and 2 or 1
    local colW = math.floor((W - 2) / cols)
    for i, f in ipairs(fs) do
        local row = (i - 1) % room
        local col = (i - 1) // room
        if col >= cols then
            put(2, y + room - 1, string.format("... and %d more", #fs - cols * room + 1), C.dim, C.bg, colW)
            break
        end
        local state = f.active and string.format("RUN %3d%%", f.maxProgress > 0 and
            math.floor(100 * f.progress / f.maxProgress) or 0)
            or ((f.heat or 0) <= 0 and "UNFORMED" or "IDLE    ")
        local line = string.format("%s  %s  %6sK  disc %4s%%  run %s%s", f.address:sub(1, 8), state,
            f.heat and tostring(math.floor(f.heat)) or "?", f.discount and tostring(math.floor(f.discount)) or "?",
            f.ticks and fmtTime(f.ticks / 20) or "?", f.convergence and "  conv" or "")
        put(2 + col * colW, y + row, line, f.active and C.good or C.warn, C.bg, colW - 1)
    end
    y = y + math.min(room, #fs) + 1

    -- log
    put(2, y, "Log", C.dim, C.bg, W - 2)
    y = y + 1
    local logH = H - y + 1
    local msgs = v.messages or {}
    local first = math.max(1, #msgs - logH + 1)
    for i = 0, logH - 1 do
        local m = msgs[first + i]
        local color = C.dim
        if m and (m:find("ERROR") or m:find("FAULT")) then color = C.crit
        elseif m and m:find("WARN") then color = C.warn
        elseif m and m:find("Making") then color = C.info end
        put(2, y + i, m or "", color, C.bg, W - 2)
    end

    gpu.setBackground(C.bg)
    for row = 1, H do
        if not drawn[row] then gpu.fill(1, row, W, 1, " ") end
    end
end

return ui

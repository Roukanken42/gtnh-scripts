-- Dashboard for the Draconic Reactor controller. Pure display: renders the view
-- table that main.lua builds and decides nothing. A no-op (ui.active == false)
-- without a GPU and screen, so the controller also runs headless.

local component = require("component")
local unicode = require("unicode")

local ui = { active = false }

local gpu, W, H
local buttons = {}  -- { x1, x2, y, action }

local C = {
    bg = 0x0B0B12, panel = 0x1C1C28, text = 0xE6E6F0, dim = 0x9090A8,
    faint = 0x585870, good = 0x3BD671, warn = 0xF2C94C, crit = 0xFF5C5C,
    info = 0x22D3EE, heat = 0xFF8A3D, fuel = 0xA066FF, chaos = 0xE040C8,
    titleBg = 0x2A1240, black = 0x000000,
}
local LEVEL = { info = C.text, good = C.good, warn = C.warn, crit = C.crit, dim = C.dim }

-- ---- formatting (main.lua uses these too) ------------------------------------------

function ui.fmtInt(n)
    n = math.floor((n or 0) + 0.5)
    local s = string.format("%d", math.abs(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
    s = s:gsub("^,", "")
    return (n < 0 and "-" or "") .. s
end

function ui.fmtSI(n)
    n = n or 0
    local a = math.abs(n)
    for _, u in ipairs({ { 1e12, "T" }, { 1e9, "G" }, { 1e6, "M" }, { 1e3, "k" } }) do
        if a >= u[1] then return string.format("%.1f%s", n / u[1], u[2]) end
    end
    return string.format("%d", math.floor(n + 0.5))
end

function ui.fmtTime(s)
    if not s or s ~= s or s == math.huge or s < 0 then return "-" end
    s = math.floor(s + 0.5)
    if s >= 3600 then return string.format("%dh%02dm", math.floor(s / 3600), math.floor(s % 3600 / 60)) end
    if s >= 60 then return string.format("%dm%02ds", math.floor(s / 60), s % 60) end
    return s .. "s"
end

function ui.fmtPct(x, decimals)
    return string.format("%." .. (decimals or 1) .. "f%%", (x or 0) * 100)
end

-- ---- setup -----------------------------------------------------------------------

function ui.init()
    if not component.isAvailable("gpu") or not component.isAvailable("screen") then return false end
    gpu = component.gpu
    local ok = pcall(function()
        local mw, mh = gpu.maxResolution()
        gpu.setResolution(math.min(mw, 100), math.min(mh, 32))
    end)
    if not ok then return false end
    W, H = gpu.getResolution()
    if W < 80 or H < 25 then return false end
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

-- The action under a touch at (x, y), or nil.
function ui.hit(x, y)
    for _, b in ipairs(buttons) do
        if y == b.y and x >= b.x1 and x <= b.x2 then return b.action end
    end
end

-- ---- drawing ---------------------------------------------------------------------

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

-- A labelled bar. `frac` 0..1; `marks` are 0..1 positions drawn as "|".
local function gauge(y, label, frac, color, value, valueColor, marks)
    local x0, valueW = 19, 22
    local w = W - x0 - valueW - 1
    frac = math.max(0, math.min(1, frac or 0))
    local filled = math.floor(w * frac + 0.5)
    put(2, y, label, C.dim, C.bg, x0 - 3)
    gpu.setBackground(color)
    gpu.fill(x0, y, filled, 1, " ")
    gpu.setBackground(C.panel)
    gpu.fill(x0 + filled, y, w - filled, 1, " ")
    for _, m in ipairs(marks or {}) do
        if m > 0 and m < 1 then
            local mx = x0 + math.floor(w * m + 0.5)
            put(mx, y, "|", C.text, mx < x0 + filled and color or C.panel)
        end
    end
    put(x0 + w + 1, y, " " .. value, valueColor or C.text, C.bg, valueW)
end

local STATUS = {
    offline = { "OFFLINE", C.dim },
    charging = { "CHARGING", C.info },
    charged = { "CHARGED", C.info },
    online = { "ONLINE", C.good },
    stopping = { "STOPPING", C.warn },
    invalid = { "INVALID STRUCTURE", C.crit },
}

local function tempColor(v, T)
    if T >= v.warnTemp then return C.crit end
    if T >= 2000 then return C.heat end
    return C.info
end

local function fieldColor(v, f)
    if f < v.stopField then return C.crit end
    if f < v.warnField then return C.warn end
    return C.good
end

-- view: see buildView() in main.lua
function ui.render(v)
    if not ui.active then return end
    local d = v.d

    -- title
    local y = 1
    put(1, y, " DRACONIC REACTOR", C.text, C.titleBg, W)
    local x = W - 9
    put(x, y, v.clock or "", C.dim, C.titleBg)
    local function badge(text, on)
        x = x - unicode.len(text) - 1
        put(x, y, text, on and C.black or C.dim, on and C.good or C.panel)
    end
    badge(v.feedOn and " FEED " or " FEED OFF ", v.feedOn)
    badge(v.autoOn and " AUTO " or " AUTO OFF ", v.autoOn)
    y = y + 2

    -- status
    local st = v.linkLost and { "NO DATA FROM REACTOR", C.crit }
        or (d and (STATUS[d.status] or { d.status:upper(), C.crit })) or { "WAITING", C.dim }
    put(2, y, " " .. st[1] .. " ", C.black, st[2])
    put(5 + unicode.len(st[1]), y, v.headline or "", st[2], C.bg, W - 5 - unicode.len(st[1]))
    y = y + 1
    put(2, y, v.doing or "", LEVEL[v.doingLevel] or C.dim, C.bg, W - 2)
    y = y + 2

    -- gauges
    if d then
        gauge(y, "Temperature", d.temp / 10000, tempColor(v, d.temp),
            ui.fmtInt(d.temp) .. " C", nil, { 0.2, v.warnTemp / 10000 })
        gauge(y + 1, "Containment", d.fieldLvl, fieldColor(v, d.fieldLvl),
            ui.fmtPct(d.fieldLvl) .. "  " .. ui.fmtSI(d.field), nil, { v.stopField })
        gauge(y + 2, "Saturation", d.satLvl, C.info,
            ui.fmtPct(d.satLvl) .. "  " .. ui.fmtSI(d.sat))
        -- The chaos share runs 0..stop limit in practice; scale the bar to 25%.
        local cscale = 0.25
        gauge(y + 3, "Chaos share", d.convLvl / cscale,
            d.convLvl >= v.stopConversion * 0.75 and C.crit or C.chaos,
            ui.fmtPct(d.convLvl, 2) .. " (stop " .. ui.fmtPct(v.stopConversion, 0) .. ")", nil,
            { v.stopConversion / cscale })
        local reserveFrac = v.reserve and v.reserve / v.maxFuel
        gauge(y + 4, "Fuel", d.fuel / v.maxFuel, C.fuel,
            ui.fmtInt(d.fuel / v.block) .. " / " .. ui.fmtInt(v.maxFuel / v.block) .. " blk",
            (v.reserve and d.fuel < v.reserve * 1.5) and C.warn or nil,
            { v.autoMinFuel / v.maxFuel, reserveFrac })
        local waiting = v.shardsWaiting > 0 and ("  +" .. v.shardsWaiting .. " WAITING") or ""
        gauge(y + 5, "Next shard", (d.converted % v.shard) / v.shard, C.chaos,
            ui.fmtPct((d.converted % v.shard) / v.shard, 0) .. waiting, v.shardsWaiting > 0 and C.warn or nil)
    else
        for i = 0, 5 do put(2, y + i, "", C.text, C.bg, W - 2) end
    end
    y = y + 7

    -- facts, two columns
    local colW = math.floor((W - 3) / 2)
    local function cell(col, row, label, value, color)
        local cx = col == 1 and 2 or 3 + colW
        put(cx, y + row, label, C.dim, C.bg, 12)
        put(cx + 12, y + row, value or "-", color or C.text, C.bg, colW - 12)
    end
    cell(1, 0, "Burn", v.burn)
    cell(1, 1, "Runs dry", v.runsDry)
    cell(1, 2, "Shutdown", v.shutdown, v.shutdownColor and LEVEL[v.shutdownColor])
    cell(1, 3, "Stop below", v.stopBelow)
    cell(2, 0, "Supply", v.supply, v.supplyColor and LEVEL[v.supplyColor])
    cell(2, 1, "Fed", v.fed)
    cell(2, 2, "Shards", v.shards)
    cell(2, 3, "Output", v.output)
    y = y + 5

    -- buttons
    buttons = {}
    local bx = 2
    put(1, y, "", C.text, C.bg, W)
    for _, b in ipairs({
        { " S START ", "start", C.good },
        { " X STOP ", "stop", C.crit },
        { v.autoOn and " A AUTO: ON " or " A AUTO: OFF ", "auto", v.autoOn and C.info or C.panel },
        { v.feedOn and " F FEED: ON " or " F FEED: OFF ", "feed", v.feedOn and C.info or C.panel },
        { " Q QUIT ", "quit", C.panel },
    }) do
        local len = unicode.len(b[1])
        put(bx, y, b[1], b[3] == C.panel and C.text or C.black, b[3])
        buttons[#buttons + 1] = { x1 = bx, x2 = bx + len - 1, y = y, action = b[2] }
        bx = bx + len + 2
    end
    if v.prompt then put(bx, y, v.prompt, C.warn, C.bg, W - bx + 1) end
    y = y + 2

    -- log
    put(2, y, "Log", C.dim, C.bg, W - 2)
    y = y + 1
    local logH = H - y + 1
    local msgs = v.messages or {}
    local first = math.max(1, #msgs - logH + 1)
    for i = 0, logH - 1 do
        local m = msgs[first + i]
        put(2, y + i, m and m.text or "", m and LEVEL[m.level] or C.dim, C.bg, W - 2)
    end
end

return ui

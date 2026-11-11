-- Setup helper: finds what config.lua needs and shows what the script sees.
--
--   probe            list every component
--   probe sides      what each transposer side holds; which one is the stocker
--   probe buses      every storage bus part: cable address, side, slots, filter
--   probe stock      the stocker's contents, and the material each one matches
--   probe mainnet    the main net's fluids, and the material each one matches
--   probe forges     every DTPF: raw sensor lines and what was parsed from them

local component = require("component")

local hw = require("hw")
local plan = require("plan")
local R = require("recipes")

local args = { ... }
local mode = args[1]

local ABS = hw.SIDE_NAMES
local function sideName(s) return string.format("%d=%s", s, ABS[s] or "?") end

local function materials()
    local ok, cfg = pcall(require, "config")
    return plan.materials(R.materials, ok and cfg.materials or nil), ok and cfg or {}
end

-- The material ids a stack matches.
local function matchesOf(mats, s, kind)
    local hits = {}
    for id, m in pairs(mats) do
        if m.kind == kind and (m.keys[s.nname] or m.keys[s.nlabel]) then hits[#hits + 1] = id end
    end
    table.sort(hits)
    return #hits > 0 and table.concat(hits, ",") or "-"
end

local function listComponents()
    local list = {}
    for addr, ctype in component.list() do list[#list + 1] = { addr = addr, type = ctype } end
    table.sort(list, function(a, b)
        if a.type ~= b.type then return a.type < b.type end
        return a.addr < b.addr
    end)
    for _, c in ipairs(list) do
        local extra = ""
        if c.type == "gt_machine" then
            local ok, name = pcall(component.invoke, c.addr, "getName")
            if ok then extra = "  " .. tostring(name) end
        end
        print(string.format("%-20s %s%s", c.type, c.addr, extra))
    end
end

local function probeSides()
    for addr in component.list("transposer", true) do
        local tp = component.proxy(addr)
        local survey = hw.surveySides(tp)
        local side, err = hw.pickStockerSide(survey)
        print("== transposer " .. addr .. (side and ("   stocker: side " .. sideName(side)) or ("   " .. err)))
        for s = 0, 5 do
            local i = survey[s]
            if i.size or i.tanks > 0 then
                print(string.format("  %-9s inventory %s (%s slots), %d tank(s)", sideName(s), tostring(i.name),
                    tostring(i.size or 0), i.tanks))
            end
        end
    end
end

local function probeBuses()
    local all = hw.surveyBuses()
    if #all == 0 then print("No storage bus found. Is an Adapter touching the cable each bus sits on?") end
    for _, b in ipairs(all) do
        local f = {}
        for slot = 1, math.min(b.slots, 6) do
            local v = hw.readFilter(b, slot)
            if v then f[#f + 1] = slot .. ":" .. tostring(v.label or v.name) end
        end
        print(string.format("%-17s address=%q side=%d (%s)  %d slots  filter: %s", b.type, b.address, b.side,
            ABS[b.side], b.slots, #f > 0 and table.concat(f, "  ") or "(empty = lets everything through)"))
    end
    print("Put these into cfg.buses as { address = \"...\", side = N }.")
end

local function probeStock()
    local mats, cfg = materials()
    local tp, side
    local c = cfg.stocker or {}
    for addr in component.list("transposer", true) do
        if not c.transposer or addr:find(c.transposer, 1, true) == 1 then
            local p = component.proxy(addr)
            local s = hw.pickStockerSide(hw.surveySides(p), c.side)
            if s then tp, side = p, s; break end
        end
    end
    if not tp then print("No stocker found: see `probe sides`."); return end
    local h = setmetatable({ tp = tp, stockerSide = side }, hw)
    local snap, err = h:readStocker()
    if not snap then print(err); return end
    plan.prepare(snap)
    print(string.format("Stocker: transposer %s side %s", tp.address:sub(1, 8), sideName(side)))
    print("ITEMS  (count  label  [name@damage]  key  -> material)")
    for _, s in ipairs(snap.items) do
        print(string.format("  %8d  %s  [%s@%s]  %s -> %s", s.size, tostring(s.label), s.name, tostring(s.damage),
            s.nlabel, matchesOf(mats, s, "item")))
    end
    print("FLUIDS (L  label  [name]  key  -> material)")
    for _, s in ipairs(snap.fluids) do
        print(string.format("  %10d  %s  [%s]  %s -> %s", s.amount, tostring(s.label), s.name, s.nname,
            matchesOf(mats, s, "fluid")))
    end
    print("A stack showing '-' is not recognised: add its key to cfg.materials.")
end

local function probeMainnet()
    local mats, cfg = materials()
    local addr = cfg.mainnet and cfg.mainnet.address
    local me
    if addr then
        me = component.proxy(component.get(addr))
    else
        for _, t in ipairs({ "me_interface", "me_controller", "fluid_interface" }) do
            for a in component.list(t, true) do
                print("found " .. t .. " " .. a)
                me = me or component.proxy(a)
            end
        end
    end
    if not me then print("No ME component found."); return end
    print("Reading " .. me.type .. " " .. me.address)
    local h = setmetatable({ me = me }, hw)
    local list, err = h:readMainnet()
    if not list then print(err); return end
    plan.prepare({ fluids = list })
    local shown = 0
    for _, s in ipairs(list) do
        local m = matchesOf(mats, s, "fluid")
        if m ~= "-" or args[2] == "all" then
            print(string.format("  %14d  %s  [%s] -> %s", s.amount, tostring(s.label), s.name, m))
            shown = shown + 1
        end
    end
    print(string.format("%d recognised fluid(s) of %d (`probe mainnet all` lists every one).", shown, #list))
end

local function probeForges()
    local cfg = select(2, materials())
    local match = ((cfg.forges or {}).nameMatch or "plasmaforge"):lower()
    for addr in component.list("gt_machine", true) do
        local ok, name = pcall(component.invoke, addr, "getName")
        if ok and type(name) == "string" and name:lower():find(match, 1, true) then
            local p = component.proxy(addr)
            print("== " .. addr .. "  " .. name)
            local okS, sensor = pcall(p.getSensorInformation)
            if okS and type(sensor) == "table" then
                for i = 1, (sensor.n or #sensor) do print("   " .. tostring(sensor[i])) end
            end
            local f = hw.readForge(p)
            print(string.format("   -> heat %s K, ticks run %s, discount %s%%, extra catalyst %s L, convergence %s,"
                .. " active %s", tostring(f.heat), tostring(f.ticks), tostring(f.discount), tostring(f.extra),
                tostring(f.convergence), tostring(f.active)))
        end
    end
end

if mode == nil then listComponents()
elseif mode == "sides" then probeSides()
elseif mode == "buses" then probeBuses()
elseif mode == "stock" then probeStock()
elseif mode == "mainnet" then probeMainnet()
elseif mode == "forges" then probeForges()
else print("usage: probe [sides | buses | stock | mainnet [all] | forges]") end

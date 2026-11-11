-- Everything that talks to a component: the DTPF controllers, the stocker
-- (through a transposer), the three storage buses, and the main net.
-- main.lua decides, this executes.

local component = require("component")

local hw = {}
hw.__index = hw

hw.SIDE_NAMES = { [0] = "down", "up", "north", "south", "west", "east" }

local SECTION = "\194\167"

local function call(proxy, method, ...)
    local ok, v = pcall(proxy[method], ...)
    if ok then return v end
    return nil, v
end

-- A list of tables returned by a component (it may carry `n`), as a plain
-- Lua list.
local function plain(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for i = 1, (list.n or #list) do
        if type(list[i]) == "table" then out[#out + 1] = list[i] end
    end
    return out
end

-- The same for a list of strings (sensor lines).
local function strings(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for i = 1, (list.n or #list) do
        if list[i] ~= nil then out[#out + 1] = tostring(list[i]) end
    end
    return out
end

-- ---- sensor lines -------------------------------------------------------------
-- Since GTNH 2.9 getSensorInformation() returns translation keys, not English:
-- each line is the key and its arguments joined by two backslashes, e.g.
--   GT5U.EBF.heat.s\\13,500
--   GT5U.infodata.plasma_forge.ticks_run_fuel_discount\\§a576,000§r\\§c50§r%\\0
-- Numbers are formatted in the server's locale (grouping commas on English).

local SEP = "\\\\"

local function clean(s)
    return (tostring(s):gsub(SECTION .. ".", ""):gsub("\167.", ""):gsub("\1", "")
        :gsub("^%s+", ""):gsub("%s+$", ""))
end

local function splitLine(raw)
    local parts, pos = {}, 1
    while true do
        local i = raw:find(SEP, pos, true)
        parts[#parts + 1] = clean(raw:sub(pos, (i or 0) - 1))
        if not i then break end
        pos = i + #SEP
    end
    local key = table.remove(parts, 1)
    return key, parts
end

-- "13,500" -> 13500, "50%" -> 50, "12.5" -> 12.5; nil when there is no number.
local function number(s)
    if s == nil then return nil end
    local m = clean(s):gsub(",", ""):match("%-?%d+%.?%d*")
    return m and tonumber(m)
end
hw.number = number

local KEY_HEAT = "GT5U.EBF.heat.s"
local KEY_RUN = "GT5U.infodata.plasma_forge.ticks_run_fuel_discount"
local KEY_CONV = "GT5U.infodata.plasma_forge.convergence"

-- Parses DTPF sensor lines (a list of strings) into { heat, ticks,
-- discount (%), extra (L), convergence (bool or nil) }. Also understands the
-- pre-2.9 English text.
function hw.parseForgeSensor(sensor)
    local f = {}
    for _, raw in ipairs(strings(sensor)) do
        local key, args = splitLine(raw)
        if key == KEY_HEAT then
            f.heat = number(args[1])
        elseif key == KEY_RUN then
            f.ticks, f.discount, f.extra = number(args[1]), number(args[2]), number(args[3])
        elseif key == KEY_CONV then
            local t = table.concat(args, " "):lower()
            f.convergence = not (t:find("inactive", 1, true) ~= nil) and t:find("active", 1, true) ~= nil
        else
            local text = clean(raw)
            local lower = text:lower()
            if lower:find("heat capacity:", 1, true) then
                f.heat = f.heat or number(text:match(":(.*)$"))
            elseif lower:find("ticks run:", 1, true) then
                f.ticks = f.ticks or number(text:match("[Tt]icks run:%s*([%d,%.]+)"))
                f.discount = f.discount or number(text:match("[Dd]iscount:%s*([%d,%.]+)"))
                f.extra = f.extra or number(text:match("use:%s*([%d,%.]+)"))
            elseif lower:find("^convergence:") then
                f.convergence = not lower:find("inactive", 1, true) and lower:find("active", 1, true) ~= nil
            end
        end
    end
    return f
end

-- ---- DTPFs ----------------------------------------------------------------------

local function findForges(cfg)
    local list = {}
    local c = cfg.forges or {}
    if c.addresses then
        for _, a in ipairs(c.addresses) do
            local full = component.get(a, "gt_machine")
            if not full then return nil, "gt_machine " .. a .. " not found" end
            list[#list + 1] = component.proxy(full)
        end
    else
        local match = (c.nameMatch or "plasmaforge"):lower()
        for addr in component.list("gt_machine", true) do
            local ok, name = pcall(component.invoke, addr, "getName")
            if ok and type(name) == "string" and name:lower():find(match, 1, true) then
                list[#list + 1] = component.proxy(addr)
            end
        end
    end
    table.sort(list, function(a, b) return a.address < b.address end)
    if #list == 0 then return nil, "no DTPF found (an Adapter on each DTPF controller?)" end
    return list
end

-- One DTPF, read: sensor values plus machine state.
function hw.readForge(proxy)
    local sensor = call(proxy, "getSensorInformation")
    local f = hw.parseForgeSensor(sensor)
    f.address = proxy.address
    f.active = call(proxy, "isMachineActive") == true
    f.progress = call(proxy, "getWorkProgress") or 0
    f.maxProgress = call(proxy, "getWorkMaxProgress") or 0
    f.workAllowed = call(proxy, "isWorkAllowed")
    f.ok = type(sensor) == "table"
    return f
end

-- ---- the stocker (transposer) ------------------------------------------------------

local function tankList(tp, side)
    local res = call(tp, "getFluidInTank", side)
    if type(res) ~= "table" then return {} end
    if res.amount or res.capacity then return { res } end
    return plain(res)
end

-- What is on each side of a transposer.
function hw.surveySides(tp)
    local survey = {}
    for side = 0, 5 do
        local info = { side = side, tanks = 0 }
        local size = call(tp, "getInventorySize", side)
        if type(size) == "number" then
            info.size = size
            info.name = call(tp, "getInventoryName", side) or "?"
        end
        info.tanks = #tankList(tp, side)
        survey[side] = info
    end
    return survey
end

-- The stocker side: given, else the one side that has both slots and tanks
-- (a stock replenisher holds items and fluids), else the one whose name says
-- stock/replenisher.
function hw.pickStockerSide(survey, fixed)
    if fixed ~= nil then return fixed end
    local both, named = {}, {}
    for side = 0, 5 do
        local s = survey[side]
        if s.size and s.size > 0 and s.tanks > 0 then both[#both + 1] = side end
        local n = (s.name or ""):lower()
        if n:find("stock", 1, true) or n:find("replenisher", 1, true) then named[#named + 1] = side end
    end
    if #both == 1 then return both[1] end
    if #named == 1 then return named[1] end
    return nil, #both == 0 and "no side with both slots and tanks"
        or "several sides with slots and tanks (" .. table.concat(both, ", ") .. ")"
end

local function findStocker(cfg)
    local c = cfg.stocker or {}
    local candidates = {}
    if c.transposer then
        local full = component.get(c.transposer, "transposer")
        if not full then return nil, "transposer " .. c.transposer .. " not found" end
        candidates[1] = component.proxy(full)
    else
        for addr in component.list("transposer", true) do candidates[#candidates + 1] = component.proxy(addr) end
        if #candidates == 0 then return nil, "no transposer found" end
    end
    local firstErr
    for _, tp in ipairs(candidates) do
        local side, err = hw.pickStockerSide(hw.surveySides(tp), c.side)
        if side then return tp, side end
        firstErr = firstErr or ("transposer " .. tp.address:sub(1, 8) .. ": " .. err)
    end
    return nil, firstErr .. " -- run `probe sides`, or set cfg.stocker.side"
end

-- { items = { {name, damage, label, size} }, fluids = { {name, label, amount} } }
function hw:readStocker()
    local items, fluids = {}, {}
    local it, err = call(self.tp, "getAllStacks", self.stockerSide)
    if not it then return nil, "cannot read the stocker: " .. tostring(err) end
    local n = it.count()
    for _ = 1, n do
        local s = it()
        if type(s) == "table" and s.name and (s.size or 0) > 0 then
            items[#items + 1] = { name = s.name, damage = s.damage, label = s.label, size = s.size }
        end
    end
    for _, f in ipairs(tankList(self.tp, self.stockerSide)) do
        if f.name and (f.amount or 0) > 0 then
            fluids[#fluids + 1] = { name = f.name, label = f.label, amount = f.amount }
        end
    end
    return { items = items, fluids = fluids }
end

-- ---- storage buses ------------------------------------------------------------------

-- Every storage bus part reachable: { type, address, side, slots, proxy }.
-- The component is the cable (part host); `side` is the side of the cable the
-- bus sits on.
function hw.surveyBuses()
    local found = {}
    for _, ctype in ipairs({ "me_storagebus", "fluid_storagebus" }) do
        for addr in component.list(ctype, true) do
            local p = component.proxy(addr)
            for side = 0, 5 do
                local n = call(p, "getStorageSlotSize", side)
                if type(n) == "number" then
                    found[#found + 1] = { type = ctype, address = addr, side = side, slots = n, proxy = p }
                end
            end
        end
    end
    return found
end

local function sameBus(a, b) return a.address == b.address and a.side == b.side end

-- Resolves the three buses from config, filling in what can be guessed:
-- `items` is the only item storage bus; `fluids` the only fluid bus that is
-- not the catalyst bus. The catalyst bus must be configured once there are two
-- fluid buses.
local function findBuses(cfg)
    local all = hw.surveyBuses()
    local function byRef(ref, ctype, label)
        local full = component.get(ref.address, ctype)
        if not full then return nil, label .. ": " .. ctype .. " " .. ref.address .. " not found" end
        if type(ref.side) ~= "number" then return nil, label .. ": cfg.buses side is not set" end
        for _, b in ipairs(all) do
            if b.address == full and b.side == ref.side then return b end
        end
        return nil, string.format("%s: no storage bus on side %d of %s", label, ref.side, full:sub(1, 8))
    end
    local function only(ctype, label, except)
        local hits = {}
        for _, b in ipairs(all) do
            if b.type == ctype and not (except and sameBus(b, except)) then hits[#hits + 1] = b end
        end
        if #hits == 1 then return hits[1] end
        return nil, string.format("%s: %d %s parts found, set it in cfg.buses (see `probe buses`)",
            label, #hits, ctype)
    end
    local c = cfg.buses or {}
    local buses, err = {}, nil
    if c.catalyst and c.catalyst.address then
        buses.catalyst, err = byRef(c.catalyst, "fluid_storagebus", "catalyst bus")
    else
        err = "catalyst bus: set cfg.buses.catalyst (see `probe buses`)"
    end
    if not buses.catalyst then return nil, err end
    if c.items and c.items.address then
        buses.items, err = byRef(c.items, "me_storagebus", "item bus")
    else
        buses.items, err = only("me_storagebus", "item bus")
    end
    if not buses.items then return nil, err end
    if c.fluids and c.fluids.address then
        buses.fluids, err = byRef(c.fluids, "fluid_storagebus", "fluid bus")
    else
        buses.fluids, err = only("fluid_storagebus", "fluid bus", buses.catalyst)
    end
    if not buses.fluids then return nil, err end
    if sameBus(buses.fluids, buses.catalyst) then return nil, "the fluid bus and the catalyst bus are the same part" end
    for _, b in pairs(buses) do b.written = {} end
    buses.items.kind, buses.fluids.kind, buses.catalyst.kind = "item", "fluid", "fluid"
    return buses
end

local function detailOf(stack, kind)
    if kind == "item" then return { name = stack.name, damage = stack.damage or 0 } end
    return { name = stack.name }
end
hw.detailOf = detailOf

local function sig(d) return d and (d.name .. ":" .. tostring(d.damage or "")) or "" end

-- Sets a bus's filter to exactly `details` (filter tables), slot 1 up; the
-- remaining slots are cleared. An EMPTY storage bus filter lets EVERYTHING
-- through, so an empty list writes `blocker` instead. Only slots that differ
-- from what was last written are touched. Returns the number of calls made,
-- or nil + error.
function hw.writeFilter(bus, details, blocker)
    if #details == 0 then details = { blocker } end
    if #details > bus.slots then
        return nil, string.format("%d filters wanted but the bus has %d slots", #details, bus.slots)
    end
    local calls = 0
    for slot = 1, bus.slots do
        local want = details[slot]
        local s = sig(want)
        if bus.written[slot] ~= s then
            local ok, err
            if want then
                ok, err = pcall(bus.proxy.setStorageConfiguration, bus.side, slot, want)
            else
                ok, err = pcall(bus.proxy.setStorageConfiguration, bus.side, slot)
            end
            if not ok then
                bus.written[slot] = nil
                return nil, string.format("slot %d: %s", slot, tostring(err))
            end
            bus.written[slot] = s
            calls = calls + 1
        end
    end
    return calls
end

-- What a bus filter slot holds, as the game reports it (nil when empty).
function hw.readFilter(bus, slot)
    local v = call(bus.proxy, "getStorageConfiguration", bus.side, slot)
    if type(v) == "table" and v.name then return v end
    return nil
end

-- Writes `detail` into slot 1 of a fluid bus and reads it back. A fluid bus
-- whose calls end up in OpenComputers' ITEM storage bus driver would not keep
-- a fluid; this finds that out before the controller relies on it.
function hw.verifyBus(bus, detail)
    local n, err = hw.writeFilter(bus, { detail }, detail)
    if not n then return false, err end
    local got = hw.readFilter(bus, 1)
    if not got or got.name ~= detail.name then
        return false, string.format("wrote %s into slot 1 but it reads back %s", detail.name,
            got and tostring(got.name) or "empty")
    end
    return true
end

-- ---- the main net -------------------------------------------------------------------

local ME_TYPES = { "me_interface", "me_controller", "fluid_interface" }

local function findMainnet(cfg)
    local c = cfg.mainnet or {}
    if c.address then
        local full = component.get(c.address)
        if not full then return nil, "main net component " .. c.address .. " not found" end
        return component.proxy(full)
    end
    local hits = {}
    for _, t in ipairs(ME_TYPES) do
        for addr in component.list(t, true) do hits[#hits + 1] = addr end
    end
    if #hits == 1 then return component.proxy(hits[1]) end
    if #hits == 0 then return nil, "no ME interface/controller for the main net (an Adapter on one?)" end
    return nil, #hits .. " ME components found: set cfg.mainnet.address (see `probe`)"
end

-- Every fluid on the main net: { {name, label, amount} }.
function hw:readMainnet()
    local list, err = call(self.me, "getFluidsInNetwork")
    if type(list) ~= "table" then return nil, "cannot read the main net: " .. tostring(err) end
    local out = {}
    for _, f in ipairs(plain(list)) do
        if f.name then out[#out + 1] = { name = f.name, label = f.label, amount = f.amount or f.size or 0 } end
    end
    return out
end

-- ---- init -------------------------------------------------------------------------------

-- Builds the hardware handle, or returns nil + a list of problems.
function hw.init(cfg)
    local self = setmetatable({ cfg = cfg }, hw)
    local problems = {}
    local function need(value, err)
        if not value then problems[#problems + 1] = err end
        return value
    end
    local forges, ferr = findForges(cfg)
    self.forges = need(forges, ferr)
    local tp, side = findStocker(cfg)
    self.tp = need(tp, side)
    if tp then self.stockerSide = side end
    local buses, berr = findBuses(cfg)
    self.buses = need(buses, berr)
    local me, merr = findMainnet(cfg)
    self.me = need(me, merr)
    if #problems > 0 then return nil, problems end
    return self
end

function hw:describe()
    local function bus(b) return string.format("%s side %s(%d)", b.address:sub(1, 8), hw.SIDE_NAMES[b.side], b.side) end
    return {
        string.format("%d DTPF(s); stocker on transposer %s side %s(%d)", #self.forges,
            self.tp.address:sub(1, 8), hw.SIDE_NAMES[self.stockerSide], self.stockerSide),
        string.format("buses: items %s, fluids %s, catalyst %s", bus(self.buses.items), bus(self.buses.fluids),
            bus(self.buses.catalyst)),
        string.format("main net: %s %s", self.me.type, self.me.address:sub(1, 8)),
    }
end

return hw

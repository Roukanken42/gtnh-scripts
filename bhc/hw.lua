-- Everything that talks to a component: redstone, the transposer, the BHC
-- controller and (optionally) the ME network. main.lua decides, this executes.

local component = require("component")

local hw = {}
hw.__index = hw

local function proxyOf(ctype, address)
    if address then
        local full = component.get(address, ctype)
        if not full then return nil, ctype .. " " .. address .. " not found" end
        return component.proxy(full)
    end
    if not component.isAvailable(ctype) then return nil, "no " .. ctype .. " found" end
    return component.getPrimary(ctype)
end

local function findMachine(address)
    if address then return proxyOf("gt_machine", address) end
    local only, count = nil, 0
    for addr in component.list("gt_machine", true) do
        count = count + 1
        only = addr
        local ok, name = pcall(component.invoke, addr, "getName")
        if ok and type(name) == "string" and name:lower():find("blackhole", 1, true) then
            return component.proxy(addr)
        end
    end
    if count == 1 then return component.proxy(only) end
    if count == 0 then return nil, "no gt_machine found (Adapter on the BHC controller?)" end
    return nil, "several gt_machines and none named *blackhole*: set cfg.machine.address"
end

-- ---- transposer discovery -------------------------------------------------

hw.SIDE_NAMES = { [0] = "down", "up", "north", "south", "west", "east" }

-- Fluid tanks seen through a transposer side, as a plain list.
local function tankList(tp, side)
    local ok, res = pcall(tp.getFluidInTank, side)
    if not ok or type(res) ~= "table" then return {} end
    local list = (res.amount or res.capacity) and { res } or res
    local out = {}
    for i = 1, (list.n or #list) do
        if type(list[i]) == "table" then out[#out + 1] = list[i] end
    end
    return out
end

local function isFluid(f, match)
    local id = ((f.name or "") .. " " .. (f.label or "")):lower()
    return id:find(match, 1, true) ~= nil
end

-- What is on each side of a transposer.
function hw.surveySides(tp, fluidMatch)
    local survey = {}
    for side = 0, 5 do
        local okN, name = pcall(tp.getInventoryName, side)
        local okS, size = pcall(tp.getInventorySize, side)
        local info = { side = side, tanks = 0, spacetime = 0 }
        if okS and type(size) == "number" then
            info.size = size
            info.name = okN and type(name) == "string" and name or "?"
        end
        for _, f in ipairs(tankList(tp, side)) do
            info.tanks = info.tanks + 1
            if f.amount and isFluid(f, fluidMatch) then info.spacetime = info.spacetime + f.amount end
        end
        survey[side] = info
    end
    return survey
end

-- Works out which side is which from a survey. Sides already set in `fixed`
-- (from config) are kept. Returns { tankSide, interfaceSide, busSide } or
-- nil + why.
--   interface  an inventory whose name mentions "interface"
--   tank       the side holding spacetime; failing that, the one other side
--              with fluid tanks (the replenisher may be empty right now)
--   bus        a GregTech block (gt.blockmachines) inventory, not the tank
function hw.resolveSides(survey, fixed)
    local found = {
        interfaceSide = fixed.interfaceSide,
        tankSide = fixed.tankSide,
        busSide = fixed.busSide,
    }
    local function pick(key, label, test)
        if found[key] ~= nil then return true end
        local hits = {}
        for side = 0, 5 do
            if test(survey[side]) then hits[#hits + 1] = side end
        end
        if #hits == 1 then found[key] = hits[1]; return true end
        return false, #hits == 0 and ("no " .. label .. " found")
            or ("more than one " .. label .. " (sides " .. table.concat(hits, ", ") .. ")")
    end
    local function taken(side)
        return side == found.interfaceSide or side == found.tankSide or side == found.busSide
    end

    local ok, err = pick("interfaceSide", "ME interface", function(s)
        return s.name and s.name:lower():find("interface", 1, true) ~= nil
    end)
    if not ok then return nil, err end
    if not pick("tankSide", "spacetime tank", function(s)
        return s.spacetime > 0 and not taken(s.side)
    end) then
        ok, err = pick("tankSide", "spacetime tank", function(s)
            return s.tanks > 0 and not taken(s.side)
        end)
        if not ok then return nil, err end
    end
    ok, err = pick("busSide", "GT input bus", function(s)
        return s.name == "gt.blockmachines" and not taken(s.side)
    end)
    if not ok then return nil, err end
    return found
end

-- The transposer (configured, or the first one around) and its sides.
local function findTransposer(cfg)
    local t = cfg.transposer or {}
    local candidates = {}
    if t.address then
        local p, err = proxyOf("transposer", t.address)
        if not p then return nil, err end
        candidates[1] = p
    else
        for addr in component.list("transposer", true) do candidates[#candidates + 1] = component.proxy(addr) end
        if #candidates == 0 then return nil, "no transposer found" end
    end
    local firstErr
    for _, tp in ipairs(candidates) do
        local sides, err = hw.resolveSides(hw.surveySides(tp, cfg.spacetimeFluid:lower()), t)
        if sides then return tp, sides end
        firstErr = firstErr or ("transposer " .. tp.address:sub(1, 8) .. ": " .. err)
    end
    return nil, firstErr .. " -- run `probe sides`, or set the side in cfg.transposer"
end

-- Builds the hardware handle, or returns nil + a list of problems.
function hw.init(cfg)
    local self = setmetatable({ cfg = cfg }, hw)
    local problems = {}
    local function need(value, err)
        if not value then problems[#problems + 1] = err end
        return value
    end

    self.machine = need(findMachine(cfg.machine.address))
    local tp, sides = findTransposer(cfg)
    self.tp = need(tp, sides)
    if tp then self.sides = sides end
    self.rs = {}
    for name, sig in pairs(cfg.signals) do
        local p, err = proxyOf("redstone", sig.address)
        self.rs[name] = need(p, name .. " signal: " .. tostring(err))
        need(type(sig.side) == "number", "cfg.signals." .. name .. ".side is not set")
    end
    if cfg.meAddress then
        local full = component.get(cfg.meAddress)
        self.me = need(full and component.proxy(full), "ME component " .. cfg.meAddress .. " not found")
    end
    if #problems > 0 then return nil, problems end
    return self
end

-- "tank up(1), interface west(4), bus east(5)"
function hw:describeSides()
    local function n(s) return string.format("%s(%d)", hw.SIDE_NAMES[s] or "?", s) end
    return string.format("tank %s, interface %s, bus %s",
        n(self.sides.tankSide), n(self.sides.interfaceSide), n(self.sides.busSide))
end

-- ---- redstone ---------------------------------------------------------------

function hw:level(name)
    local sig, rs = self.cfg.signals[name], self.rs[name]
    if sig.color then return rs.getBundledInput(sig.side, sig.color) end
    return rs.getInput(sig.side)
end

-- Is this redstone_changed event about signal `name`?
function hw:matches(name, address, side, color)
    local sig, rs = self.cfg.signals[name], self.rs[name]
    if rs.address ~= address or sig.side ~= side then return false end
    if sig.color then return color == sig.color end
    return color == nil
end

function hw:setSpacetime(on)
    local sig, rs = self.cfg.signals.spacetime, self.rs.spacetime
    if sig.invert then on = not on end
    local value = on and 15 or 0
    if sig.color then rs.setBundledOutput(sig.side, sig.color, value)
    else rs.setOutput(sig.side, value) end
end

-- ---- fluids -----------------------------------------------------------------

-- Spacetime (L) in the tank on `side`, or nil + error.
function hw:fluid(side)
    local ok, res = pcall(self.tp.getFluidInTank, side)
    if not ok or type(res) ~= "table" then return nil, tostring(res) end
    local list = (res.amount or res.capacity) and { res } or res
    local match = self.cfg.spacetimeFluid:lower()
    local total = 0
    for i = 1, (list.n or #list) do
        local f = list[i]
        if type(f) == "table" and f.amount then
            local id = ((f.name or "") .. " " .. (f.label or "")):lower()
            if id:find(match, 1, true) then total = total + f.amount end
        end
    end
    return total
end

function hw:tank() return self:fluid(self.sides.tankSide) end

-- ---- items ------------------------------------------------------------------

-- { [label] = { count = n, slots = { slot, ... } } } for the inventory on `side`.
function hw:scan(side)
    local ok, it = pcall(self.tp.getAllStacks, side)
    if not ok or not it then return nil, tostring(it) end
    local found = {}
    local n = it.count()
    for slot = 1, n do
        local s = it()
        if type(s) == "table" and s.label and (s.size or 0) > 0 then
            local e = found[s.label]
            if not e then e = { count = 0, slots = {} }; found[s.label] = e end
            e.count = e.count + s.size
            e.slots[#e.slots + 1] = slot
        end
    end
    return found
end

local function countIn(found, label)
    local e = found and found[label]
    return e and e.count or 0
end

-- Seeds and collapsers available: from the ME net when configured, else what
-- the interface holds right now.
function hw:stock()
    local items = self.cfg.items
    if self.me then
        local function net(label)
            local ok, list = pcall(self.me.getItemsInNetwork, { label = label })
            if not ok or type(list) ~= "table" then return 0 end
            local total = 0
            for i = 1, (list.n or #list) do total = total + (list[i].size or 0) end
            return total
        end
        return net(items.seed), net(items.collapser)
    end
    local found, err = self:scan(self.sides.interfaceSide)
    if not found then return 0, 0, err end
    return countIn(found, items.seed), countIn(found, items.collapser)
end

-- Seeds and collapsers sitting in the input bus.
function hw:inBus()
    local found, err = self:scan(self.sides.busSide)
    if not found then return nil, nil, err end
    return countIn(found, self.cfg.items.seed), countIn(found, self.cfg.items.collapser)
end

-- Moves one seed/collapser from the interface into the bus. Returns ok, err.
function hw:insert(kind)
    local label = self.cfg.items[kind]
    local t = self.sides
    local found, err = self:scan(t.interfaceSide)
    if not found then return false, "cannot read the interface: " .. tostring(err) end
    local e = found[label]
    if not e then return false, "no " .. label .. " in the interface" end
    for _, slot in ipairs(e.slots) do
        local ok, moved = pcall(self.tp.transferItem, t.interfaceSide, t.busSide, 1, slot)
        if ok and moved and moved > 0 then return true end
        if not ok then err = moved end
    end
    return false, "could not move a " .. label .. " into the bus (" .. tostring(err or "bus full?") .. ")"
end

-- ---- the machine ------------------------------------------------------------

function hw:machineState()
    local m = self.machine
    local function call(f)
        local ok, v = pcall(m[f])
        if ok then return v end
    end
    local maxp = call("getWorkMaxProgress") or 0
    local prog = call("getWorkProgress") or 0
    return {
        active = call("isMachineActive") == true,
        progress = prog,
        maxProgress = maxp,
        remaining = math.max(0, maxp - prog) / 20,
        workAllowed = call("isWorkAllowed"),
    }
end

function hw:setWork(allowed)
    pcall(self.machine.setWorkAllowed, allowed)
end

return hw

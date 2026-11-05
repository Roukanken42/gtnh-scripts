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

-- Builds the hardware handle, or returns nil + a list of problems.
function hw.init(cfg)
    local self = setmetatable({ cfg = cfg }, hw)
    local problems = {}
    local function need(value, err)
        if not value then problems[#problems + 1] = err end
        return value
    end

    self.machine = need(findMachine(cfg.machine.address))
    self.tp = need(proxyOf("transposer", cfg.transposer.address))
    self.rs = {}
    for name, sig in pairs(cfg.signals) do
        local p, err = proxyOf("redstone", sig.address)
        self.rs[name] = need(p, name .. " signal: " .. tostring(err))
    end
    if cfg.meAddress then
        local full = component.get(cfg.meAddress)
        self.me = need(full and component.proxy(full), "ME component " .. cfg.meAddress .. " not found")
    end
    if #problems > 0 then return nil, problems end
    return self
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

function hw:tank() return self:fluid(self.cfg.transposer.tankSide) end

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
    local found, err = self:scan(self.cfg.transposer.interfaceSide)
    if not found then return 0, 0, err end
    return countIn(found, items.seed), countIn(found, items.collapser)
end

-- Seeds and collapsers sitting in the input bus.
function hw:inBus()
    local found, err = self:scan(self.cfg.transposer.busSide)
    if not found then return nil, nil, err end
    return countIn(found, self.cfg.items.seed), countIn(found, self.cfg.items.collapser)
end

-- Moves one seed/collapser from the interface into the bus. Returns ok, err.
function hw:insert(kind)
    local label = self.cfg.items[kind]
    local t = self.cfg.transposer
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

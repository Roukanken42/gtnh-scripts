-- Everything that talks to a component: the reactor (through an Adapter on a
-- stabilizer or the injector) and the transposer that moves fuel from the
-- Super Stock Replenisher into a buffer chest that feeds a stabilizer.
-- main.lua decides, this executes.

local component = require("component")

local hw = {}
hw.__index = hw

hw.SIDE_NAMES = { [0] = "down", "up", "north", "south", "west", "east" }

local function call(proxy, method, ...)
    local ok, v = pcall(proxy[method], ...)
    if ok then return v end
    return nil, v
end

-- ---- reactor ------------------------------------------------------------------

local function findReactor(cfg)
    local addr = cfg.reactor and cfg.reactor.address
    if addr then
        local full = component.get(addr, "draconic_reactor")
        if not full then return nil, "draconic_reactor " .. addr .. " not found" end
        return component.proxy(full)
    end
    local list = {}
    for a in component.list("draconic_reactor", true) do list[#list + 1] = a end
    if #list == 0 then return nil, "no draconic_reactor (an Adapter touching a stabilizer or the injector?)" end
    -- Several adapters on one reactor all see the same core, so any will do.
    table.sort(list)
    return component.proxy(list[1])
end

-- getReactorInfo(), normalised. Fields as the core reports them (see
-- TileReactorCore.callMethod):
--   status     offline | charging | charged | online | stopping | invalid
--   converted  fuelConversion: chaos inside, in fuel units, incl. the fraction
--   total      maxFuelConversion: unconverted + converted
--   fuel       total - converted: unconverted awakened draconium
--   useRate    fuelConversionRate / 1e6: fuel per tick (last running tick)
function hw:info()
    local raw, err = call(self.reactor, "getReactorInfo")
    if type(raw) ~= "table" then return nil, err or "no reply" end
    local function n(v) return tonumber(v) or 0 end
    local d = {
        status = tostring(raw.status or "unknown"):lower(),
        temp = n(raw.temperature),
        field = n(raw.fieldStrength), fieldMax = n(raw.maxFieldStrength),
        sat = n(raw.energySaturation), satMax = n(raw.maxEnergySaturation),
        converted = n(raw.fuelConversion), total = n(raw.maxFuelConversion),
        genRate = n(raw.generationRate), drainRate = n(raw.fieldDrainRate),
        useRate = n(raw.fuelConversionRate) / 1e6,
    }
    d.fuel = math.max(0, d.total - math.floor(d.converted))
    d.fieldLvl = d.fieldMax > 0 and d.field / d.fieldMax or 0
    d.satLvl = d.satMax > 0 and d.sat / d.satMax or 0
    d.convLvl = d.total > 0 and d.converted / d.total or 0
    return d
end

-- Each returns true when the core accepted it (false = not in a state for it).
function hw:charge() return call(self.reactor, "chargeReactor") end
function hw:activate() return call(self.reactor, "activateReactor") end
function hw:stop() return call(self.reactor, "stopReactor") end

-- ---- transposer --------------------------------------------------------------
-- The transposer touches the Super Stock Replenisher and a buffer chest (a
-- compressed chest) that something else empties into a stabilizer. It never
-- touches the reactor itself.

-- What is on each side of a transposer.
function hw.surveySides(tp)
    local survey = {}
    for side = 0, 5 do
        local info = { side = side }
        local size = call(tp, "getInventorySize", side)
        if type(size) == "number" then
            info.size = size
            info.name = call(tp, "getInventoryName", side) or "?"
        end
        survey[side] = info
    end
    return survey
end

local function sideMatching(survey, test, except)
    local hits = {}
    for side = 0, 5 do
        local s = survey[side]
        if s.size and side ~= except and test((s.name or ""):lower()) then hits[#hits + 1] = side end
    end
    if #hits == 1 then return hits[1] end
    return nil, #hits
end

-- The replenisher: by name (stock / replenisher). The buffer chest: by name
-- (chest / compress), else the one other inventory. Config values win.
function hw.pickSides(survey, c)
    local stock, ns = c.stockSide, nil
    if stock == nil then
        stock, ns = sideMatching(survey, function(n)
            return n:find("stock", 1, true) or n:find("replenisher", 1, true)
        end)
    end
    local target, nt = c.targetSide, nil
    if target == nil then
        target, nt = sideMatching(survey, function(n)
            return n:find("chest", 1, true) or n:find("compress", 1, true)
        end, stock)
        if not target and nt == 0 then
            target, nt = sideMatching(survey, function() return true end, stock)
        end
    end
    local err
    if not stock then err = (ns == 0 and "no" or "several") .. " stock replenisher side(s)" end
    if not target then
        err = (err and err .. ", " or "") .. (nt == 0 and "no" or "several") .. " buffer chest side(s)"
    end
    return stock, target, err
end

local function findTransposer(cfg)
    local c = cfg.transposer or {}
    local candidates = {}
    if c.address then
        local full = component.get(c.address, "transposer")
        if not full then return nil, "transposer " .. c.address .. " not found" end
        candidates[1] = component.proxy(full)
    else
        for addr in component.list("transposer", true) do candidates[#candidates + 1] = component.proxy(addr) end
        if #candidates == 0 then return nil, "no transposer" end
    end
    local firstErr
    for _, tp in ipairs(candidates) do
        local stock, target, err = hw.pickSides(hw.surveySides(tp), c)
        if stock and target then return tp, stock, target end
        firstErr = firstErr or ("transposer " .. tp.address:sub(1, 8) .. ": " .. err)
    end
    return nil, firstErr .. " -- run `probe sides`, or set cfg.transposer sides"
end

local function stacksOn(tp, side, what)
    local it, err = call(tp, "getAllStacks", side)
    if not it then return nil, "cannot read the " .. what .. ": " .. tostring(err) end
    local out = {}
    local n = it.count()
    for slot = 1, n do
        local s = it()
        if type(s) == "table" and s.name and (s.size or 0) > 0 then
            out[#out + 1] = { slot = slot, size = s.size, label = s.label, name = s.name }
        end
    end
    return out
end

-- Every stack in the replenisher / the buffer chest: { slot, size, label, name }.
function hw:stock() return stacksOn(self.tp, self.stockSide, "replenisher") end
function hw:buffer() return stacksOn(self.tp, self.targetSide, "buffer chest") end

-- Moves up to `count` items from a replenisher slot into the buffer chest.
function hw:feed(slot, count)
    local n, err = call(self.tp, "transferItem", self.stockSide, self.targetSide, count, slot)
    return tonumber(n) or 0, err
end

-- ---- init -----------------------------------------------------------------------

-- Returns the hw object, or nil and a list of problems. A missing transposer
-- is not fatal: the script then only watches and starts/stops.
function hw.init(cfg)
    local self = setmetatable({}, hw)
    local problems = {}
    local reactor, err = findReactor(cfg)
    if not reactor then problems[#problems + 1] = err else self.reactor = reactor end

    if cfg.feed and cfg.feed.enabled then
        local tp, stock, target = findTransposer(cfg)
        if tp then
            self.tp, self.stockSide, self.targetSide = tp, stock, target
        else
            self.tpProblem = stock  -- the error text
        end
    end

    if #problems > 0 then return nil, problems end
    return self
end

function hw:describe()
    if not self.tp then return "no transposer (" .. tostring(self.tpProblem or "feeding off") .. ")" end
    local N = hw.SIDE_NAMES
    return string.format("transposer %s: replenisher %s -> buffer chest %s", self.tp.address:sub(1, 8),
        N[self.stockSide], N[self.targetSide])
end

return hw

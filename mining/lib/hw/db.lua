-- Database slots -- the ONE place that decides which slot holds what.
--
-- An OpenComputers database is addressed by bare slot numbers, and several parts
-- of this system need to park item metadata in one:
--
--   * the probe drone, so setup can stock it through an interface
--   * an ae2fc plasma drop, which is how a fluid interface is told what to stage
--   * whatever item a station is currently pulling from ME
--   * a scratch slot for reading a pattern's real output back
--
-- Each of those used to pick its own constant. Two of them picked the same one,
-- and nothing complained: a slot simply holds whatever was written last, so the
-- collision only surfaced much later as "the probe drone metadata is a plasma
-- drop". There is no shortage of room to avoid this -- a T3 database has 81 slots
-- and this system needs a handful -- only a shortage of bookkeeping.
--
-- So slots are handed out BY NAME. The same name always gets the same slot, an
-- entry that lives a long time is written once and reused, and two callers can
-- only share a slot by agreeing on a name. `used()` and `dump()` make the whole
-- allocation visible, which is what the old constants never were.
--
-- component is required lazily, and open() accepts a ready-made proxy, so the
-- allocation logic can be exercised off-machine.

local db = {}

-- Biggest database an upgrade offers (T3). Probing stops here.
db.MAX_SLOTS = 81

local Db = {}
Db.__index = Db

local handles = {}   -- address -> Db, so every caller shares one allocation

-- nil off-machine, so open() can still be handed a ready-made proxy in tests.
local function components()
    local ok, c = pcall(require, "component")
    if ok then return c end
    return nil
end

-- How many slots this database really has. There is no size method, so ask for
-- slots until one is rejected -- a handful of calls, once per database.
local function capacityOf(proxy)
    local n = 0
    for i = 1, db.MAX_SLOTS do
        local ok = pcall(proxy.get, i)
        if not ok then break end
        n = i
    end
    return n
end

-- Opens a database by address (or takes a proxy already made). Handles are shared
-- per address: two modules opening the same database get the same allocation,
-- which is the entire point. Returns the handle, or nil + error.
function db.open(address)
    if address == nil then return nil, "no database configured" end

    local proxy, addr
    if type(address) == "table" then
        proxy, addr = address, address.address
    else
        addr = address
        local existing = handles[addr]
        if existing then return existing end
        local component = components()
        if not component then return nil, "no component library (off-machine?)" end
        local ok, p = pcall(component.proxy, addr)
        if not ok or not p then return nil, "no database at '" .. tostring(addr) .. "'" end
        proxy = p
    end
    if proxy.get == nil then return nil, "component " .. tostring(addr) .. " is not a database" end
    if addr and handles[addr] then return handles[addr] end

    local self = setmetatable({
        proxy = proxy,
        address = addr or proxy.address,
        slots = capacityOf(proxy),
        named = {},        -- name -> slot
        order = {},        -- slot -> name, for dump()
        next = 1,
    }, Db)
    if self.slots <= 0 then return nil, "database reports no usable slots" end
    if addr then handles[addr] = self end
    return self
end

-- The slot for `name`, allocating one the first time it is asked for. Returns
-- slot, fresh -- `fresh` is true only on that first call, which is how a caller
-- knows whether it still has to write the metadata. nil + error when full.
function Db:slot(name)
    if type(name) ~= "string" or name == "" then return nil, "a slot needs a name" end
    local have = self.named[name]
    if have then return have, false end

    if self.next > self.slots then
        return nil, string.format("database is full (%d slots, all named)", self.slots)
    end
    local slot = self.next
    self.next = slot + 1
    self.named[name] = slot
    self.order[slot] = name
    return slot, true
end

-- A slot whose contents nobody keeps. Written and read back immediately, never
-- relied on afterwards -- resolving a pattern's real output, say.
function Db:scratch()
    return (self:slot("<scratch>"))
end

function Db:get(slot)
    local ok, stack = pcall(self.proxy.get, slot)
    if not ok or type(stack) ~= "table" then return nil end
    if not (stack.name or stack.label) then return nil end
    return stack
end

function Db:clear(slot)
    pcall(self.proxy.clear, slot)
end

-- The label of whatever is in `slot`, or nil when it is empty.
function Db:label(slot)
    local stack = self:get(slot)
    return stack and (stack.label or stack.name) or nil
end

-- Confirms a slot holds `label`. Returns true + what is there, or false + why
-- not -- so a failure downstream can be blamed on the right thing.
function Db:holds(slot, label)
    local got = self:label(slot)
    if not got then return false, "slot " .. tostring(slot) .. " is empty" end
    if label and got ~= label then
        return false, "slot " .. tostring(slot) .. " holds '" .. got .. "'"
    end
    return true, got
end

function Db:size() return self.slots end
function Db:used() return self.next - 1 end

-- Every allocation, as { slot, name, label }, lowest slot first. The view the old
-- scattered constants could never give.
function Db:dump()
    local out = {}
    for slot = 1, self:used() do
        out[#out + 1] = { slot = slot, name = self.order[slot] or "?", label = self:label(slot) }
    end
    return out
end

db.Db = Db

return db

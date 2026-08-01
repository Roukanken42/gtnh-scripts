-- Item transport for the mining modules -- the ONE place that shuffles drones
-- (or any item) between the AE2 network and a module's input bus.
--
-- Each module has a "station": a transposer physically touching BOTH the
-- module's input bus AND an ME interface, plus a (shared) database component.
--
-- Moving items back INTO ME is easy -- drop them into the interface and the
-- network absorbs them. Pulling an item OUT of ME is indirect:
--   1. Record the item's metadata into a database once, via interface.store().
--      setInterfaceConfiguration references items by database slot, and the
--      metadata is reusable, so we do this at most once per run per item type.
--   2. Tell the interface to STOCK the item into one of its slots, via
--      interface.setInterfaceConfiguration(slot, db, dbSlot, count).
--   3. Wait for AE2 to actually push it into that interface slot.
--   4. Transpose it from the interface side to the input-bus side.
--   5. CLEAR the interface config. Clearing also makes the interface hand any
--      leftover/just-restocked copies straight back to the network, so the
--      operation is self-correcting -- nothing is left dangling.
--
-- All of that hardware detail lives here; higher layers only call
-- station:setDrone(drone, count) / station:load(...) / station:returnAll().
--
-- API references (OpenComputers):
--   transposer.transferItem(srcSide, dstSide[, count[, srcSlot[, dstSlot]]]) -> moved
--   transposer.getAllStacks(side) / getStackInSlot(side, slot)
--   me_interface.store(filter, dbAddress[, startSlot[, count]]) -> boolean
--   me_interface.setInterfaceConfiguration(slot[, dbAddress, dbSlot, count])
--   database.get(slot) / database.clear(slot)

local component = require("component")
local computer = require("computer")

local transport = {}

-- Per-database metadata cache so each item type is store()d only once per run,
-- even across stations that share a database:
--   dbCache[dbAddress] = { byLabel = { [label] = dbSlot }, next = <next free slot> }
local dbCache = {}
local function cacheFor(dbAddress)
    local c = dbCache[dbAddress]
    if not c then
        c = { byLabel = {}, next = 1 }
        dbCache[dbAddress] = c
    end
    return c
end

-- Resolves a (possibly abbreviated) component address to a proxy, or nil + err.
local function resolve(addr)
    if type(addr) ~= "string" or addr == "" then return nil, "missing address" end
    local full = addr
    if #addr < 36 then
        local ok, g = pcall(component.get, addr)
        if ok and g then full = g end
    end
    local ok, p = pcall(component.proxy, full)
    if not ok or not p then return nil, "no component for address '" .. addr .. "'" end
    return p
end

-- Reads a transposer side's stacks as a plain ItemStack array. getAllStacks
-- returns a StackSlot (with getAll()); older builds return the array directly.
local function readStacks(transposer, side)
    local ok, res = pcall(transposer.getAllStacks, side)
    if not ok or not res then return {} end
    if type(res) == "table" and res.getAll ~= nil then
        local okAll, arr = pcall(res.getAll)
        return (okAll and arr) or {}
    end
    return res
end

-- ---- Station -------------------------------------------------------------

local Station = {}
Station.__index = Station
transport.Station = Station

-- Builds a station handle from a spec table:
--   transposer     component address (touches the input bus + ME interface)
--   interface      me_interface component address (for setInterfaceConfiguration/store)
--   database       database component address (shared item-metadata store)
--   interfaceSide  transposer side facing the interface
--   inputBusSide   transposer side facing the module's input bus
--   interfaceSlot  interface config/inventory slot to stage through (default 1)
--   stockTimeout   seconds to wait for AE2 to stock a request (default 10)
--   pollInterval   seconds between stock-arrival polls (default 0.25)
--   dryRun         when true, item moves are only logged (default false)
--   log            function(msg) sink for progress/dry-run lines (default no-op)
-- Returns the Station, or nil + error message.
function transport.new(spec)
    local self = setmetatable({}, Station)

    local tp, e1 = resolve(spec.transposer)
    if not tp then return nil, "transposer: " .. e1 end
    local itf, e2 = resolve(spec.interface)
    if not itf then return nil, "interface: " .. e2 end
    local db, e3 = resolve(spec.database)
    if not db then return nil, "database: " .. e3 end

    if type(spec.interfaceSide) ~= "number" or type(spec.inputBusSide) ~= "number" then
        return nil, "interfaceSide and inputBusSide must be side numbers"
    end

    self.transposer = tp
    self.interface = itf
    self.database = db
    self.dbAddress = db.address
    self.interfaceSide = spec.interfaceSide
    self.inputBusSide = spec.inputBusSide
    self.interfaceSlot = spec.interfaceSlot or 1
    self.stockTimeout = spec.stockTimeout or 10
    self.pollInterval = spec.pollInterval or 0.25
    self.dryRun = spec.dryRun or false
    self.label = spec.label or "station"
    self.log = spec.log or function() end
    return self
end

-- Ensures `label`'s metadata is in the database and returns its slot, storing it
-- (once per run per database) if needed. nil + err if the item is not in ME.
function Station:ensureDbSlot(filter, label)
    local cache = cacheFor(self.dbAddress)
    if cache.byLabel[label] then return cache.byLabel[label] end

    local slot = cache.next
    local ok, err = pcall(self.interface.store, filter, self.dbAddress, slot, 1)
    if not ok then return nil, "interface.store errored: " .. tostring(err) end

    -- store() is silent on "nothing matched", so confirm the slot got populated.
    local okGet, stack = pcall(self.database.get, slot)
    if not (okGet and type(stack) == "table" and (stack.name or stack.label)) then
        pcall(self.database.clear, slot)   -- keep the database tidy on failure
        return nil, "'" .. label .. "' not found in the ME network"
    end

    cache.byLabel[label] = slot
    cache.next = slot + 1
    return slot
end

-- Clears the interface's staging config (also returns any stocked item to ME).
function Station:clearConfig()
    if self.dryRun then return end
    pcall(self.interface.setInterfaceConfiguration, self.interfaceSlot)
end

-- Returns a list of { slot, label, name, size } for each occupied input-bus slot.
function Station:busStacks()
    local out = {}
    local arr = readStacks(self.transposer, self.inputBusSide)
    for i = 1, #arr do
        local s = arr[i]
        if s and (s.size or 0) > 0 and (s.name or s.label) then
            out[#out + 1] = { slot = i, label = s.label, name = s.name, size = s.size }
        end
    end
    return out
end

-- Moves `count` items from input-bus slot `slot` into the ME interface (the
-- network then absorbs them). Returns the number actually moved.
function Station:returnSlot(slot, count)
    if self.dryRun then
        self.log(string.format("[dry] %s: return %s from bus slot %d -> ME",
            self.label, tostring(count), slot))
        return count or 0
    end
    local ok, moved = pcall(self.transposer.transferItem,
        self.inputBusSide, self.interfaceSide, count, slot)
    return (ok and moved) or 0
end

-- Returns every item currently in the input bus to the ME network. Total moved.
function Station:returnAll()
    local total = 0
    for _, s in ipairs(self:busStacks()) do
        total = total + self:returnSlot(s.slot, s.size)
    end
    return total
end

-- Drone loading is split into a non-blocking begin + poll so many stations can
-- be loaded at once: request every drone from ME first, then poll them all while
-- they stock in parallel (see transport.loadDrones). A `job` tracks one station:
--   job.phase  "stocking" (waiting on ME) | "done" | "error"
--   job.ok     true on success
--   job.err    message when phase == "error"
--   job.note   e.g. "already loaded"

-- Begins loading `count` of `drone` into the input bus WITHOUT waiting. Does the
-- quick synchronous work -- clear any stale config, empty a wrong bus, and ask
-- ME to stock the drone -- then returns a job to feed to pollDrone(). A job that
-- is already satisfied (or fails to start) comes back "done"/"error" already.
function Station:beginDrone(drone, count)
    count = count or 1
    local target = drone.name
    local job = { station = self, drone = drone, label = target, count = count }

    if self.dryRun then
        self.log(string.format("[dry] %s: would load %d x %s", self.label, count, target))
        job.phase, job.ok = "done", true
        return job
    end

    self:clearConfig()   -- known-clean interface slot

    -- Already correct? Leave it be.
    local stacks = self:busStacks()
    local have, onlyTarget = 0, true
    for _, s in ipairs(stacks) do
        if s.label == target then have = have + s.size else onlyTarget = false end
    end
    if have == count and onlyTarget then
        job.phase, job.ok, job.note = "done", true, "already loaded"
        return job
    end

    -- Reset the bus (wrong/old drones back to ME), then request the drone.
    for _, s in ipairs(stacks) do self:returnSlot(s.slot, s.size) end
    if count <= 0 then job.phase, job.ok = "done", true; return job end

    local slot, err = self:ensureDbSlot({ label = target }, target)
    if not slot then job.phase, job.ok, job.err = "error", false, err; return job end

    local okCfg = pcall(self.interface.setInterfaceConfiguration,
        self.interfaceSlot, self.dbAddress, slot, count)
    if not okCfg then
        job.phase, job.ok = "error", false
        job.err = "setInterfaceConfiguration failed for " .. target
        return job
    end

    job.phase = "stocking"
    job.deadline = computer.uptime() + self.stockTimeout
    return job
end

-- Advances a job from beginDrone(): if the drone has arrived in the interface,
-- transpose it to the bus and clear the config; if the stock timeout has passed,
-- give up. Returns the job's phase afterwards ("stocking"/"done"/"error"). Safe
-- to call on an already-settled job (returns its phase unchanged).
function Station:pollDrone(job)
    if job.phase ~= "stocking" then return job.phase end

    local slot = self.interfaceSlot
    local ok, stack = pcall(self.transposer.getStackInSlot, self.interfaceSide, slot)
    local arrived = ok and type(stack) == "table"
        and stack.label == job.label and (stack.size or 0) >= job.count

    if arrived then
        local okT, moved = pcall(self.transposer.transferItem,
            self.interfaceSide, self.inputBusSide, job.count, slot)
        self:clearConfig()   -- also hands back any copy restocked mid-transfer
        moved = (okT and moved) or 0
        if moved >= job.count then
            job.phase, job.ok = "done", true
        else
            job.phase, job.ok = "error", false
            job.err = string.format("only moved %d/%d %s to the input bus",
                moved, job.count, job.label)
        end
    elseif computer.uptime() >= job.deadline then
        self:clearConfig()
        job.phase, job.ok = "error", false
        job.err = job.label .. " did not arrive from ME within " .. self.stockTimeout .. "s"
    end
    return job.phase
end

-- Synchronous convenience: load one drone and block until it settles.
-- Returns true (+ note), or false + error.
function Station:setDrone(drone, count)
    local job = self:beginDrone(drone, count)
    while job.phase == "stocking" do
        os.sleep(self.pollInterval)
        self:pollDrone(job)
    end
    if job.ok then return true, job.note end
    return false, job.err
end

-- Loads drones into many stations concurrently: begins every request (so all
-- the interfaces stock at once), then polls until each settles. `requests` is a
-- list of { station = <Station>, drone = <descriptor>, count = <n> }. Returns a
-- list of { station, drone, ok, err, note } in the same order.
--
-- NOTE: stations that share an ME interface MUST use distinct interfaceSlots or
-- their concurrent loads collide -- setup.lua assigns these automatically.
function transport.loadDrones(requests, pollInterval)
    pollInterval = pollInterval or 0.25
    local jobs = {}
    for i, r in ipairs(requests) do
        jobs[i] = r.station:beginDrone(r.drone, r.count)
    end

    local pending = true
    while pending do
        pending = false
        for _, job in ipairs(jobs) do
            if job.phase == "stocking" then
                if job.station:pollDrone(job) == "stocking" then pending = true end
            end
        end
        if pending then os.sleep(pollInterval) end
    end

    local results = {}
    for i, job in ipairs(jobs) do
        results[i] = {
            station = job.station, drone = requests[i].drone,
            ok = job.ok or false, err = job.err, note = job.note,
        }
    end
    return results
end

return transport

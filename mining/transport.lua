-- Transport for the mining modules -- the ONE place that shuffles drones, kits
-- (or any item) and plasma between the AE2 network and a module's input hatches.
--
-- Each module has a "station", which has up to two halves:
--
--   item half   a transposer touching BOTH the module's input BUS and an ME
--               interface. Carries drones and mining kits.
--   fluid half  a transposer touching the module's input HATCH and an ME
--               interface with tanks. Carries plasma. It may be the SAME
--               transposer and the SAME interface as the item half -- both can
--               serve items and fluids -- but it is addressed separately, so a
--               module whose plasma comes from elsewhere still works.
--
-- Both halves share the station's database component. The fluid half is optional
-- -- a station without it simply has no plasma feed (Station:hasFluid()).
--
-- ---- fluid indexing --------------------------------------------------------
-- An ME fluid interface has SIX tanks of 16,000 L, and its configuration index is
-- 0-BASED because it corresponds to the interface's sides. A transposer beside it
-- can reach all six, so several stations share one interface by taking different
-- `fluidTank` values -- the fluid counterpart of `interfaceSlot`.
--
-- That one 0-based number does three jobs, which is why it is stored raw:
--   setFluidInterfaceConfiguration(fluidTank, db, dbIndex)   0-based
--   transferFluid(src, dst, amount, sourceTank = fluidTank)  0-based
--   getTankLevel / getTankCapacity(side, fluidTank + 1)      1-BASED
-- Only the read methods count from one. Station:tank() is the single place that
-- knows this, so nothing else has to.
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
--   transposer.transferFluid(srcSide, dstSide[, mB[, srcTank]]) -> ok, moved
--   transposer.getTankLevel / getTankCapacity(side, tank) / getFluidInTank(side, tank)
--   me_interface.store(filter, dbAddress[, startSlot[, count]]) -> boolean
--   me_interface.setInterfaceConfiguration(slot[, dbAddress, dbSlot, count])
--   me_interface.setFluidInterfaceConfiguration(tank[, dbAddress, dbIndex])
--   database.get(slot) / database.clear(slot)

-- Pulled in defensively so this module can be LOADED off the machine: the tank
-- indexing and transfer arithmetic below is worth exercising without
-- OpenComputers around. Anything that actually touches hardware still needs
-- them; a test hands transport.new ready-made proxies instead of addresses.
local function optional(name)
    local ok, mod = pcall(require, name)
    if ok then return mod end
    return nil
end

local component = optional("component")
local computer = optional("computer")

local dbslots = require("db")

local transport = {}

-- Resolves a (possibly abbreviated) component address to a proxy, or nil + err.
-- An already-resolved proxy passes straight through, which is how tests inject
-- fakes and how a caller that already holds one avoids a second lookup.
local function resolve(addr)
    if type(addr) == "table" then return addr end
    if type(addr) ~= "string" or addr == "" then return nil, "missing address" end
    if not component then return nil, "no component library (off-machine?)" end
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
-- Optional fluid half (all four required together, see the header):
--   fluidTransposer     component address (touches the input hatch + fluid interface)
--   fluidInterface      me_interface address whose tanks stage the plasma
--   fluidInterfaceSide  transposer side facing the fluid interface
--   inputHatchSide      transposer side facing the module's input hatch
--   fluidTank           which of the interface's 6 tanks to use, 0-BASED (default 0)
--   stockTimeout   seconds to wait for AE2 to stock a request (default 10)
--   pollInterval   seconds between stock-arrival polls (default 0.25)
--   dryRun         when true, item moves are only logged (default false)
--   log            function(msg) sink for progress/dry-run lines (default no-op)
-- Returns the Station, or nil + error message.
function transport.new(spec)
    local self = setmetatable({}, Station)

    local database, e3 = resolve(spec.database)
    if not database then return nil, "database: " .. tostring(e3) end
    -- Slots come from the shared allocator, so a station cannot land on metadata
    -- another part of the system is relying on (see db.lua).
    local handle, e4 = dbslots.open(database)
    if not handle then return nil, "database: " .. tostring(e4) end
    self.database = database
    self.db = handle
    self.dbAddress = handle.address

    -- Either half may be absent, but not both. A module in normal service has
    -- both; setup.lua builds fluid-only handles while it is still working out
    -- which hatch belongs to which miner.
    local wantItem = spec.transposer ~= nil or spec.interface ~= nil
    local wantFluid = spec.fluidTransposer ~= nil or spec.fluidInterface ~= nil
    if not wantItem and not wantFluid then
        return nil, "a station needs an item half, a fluid half, or both"
    end

    if wantItem then
        local tp, e1 = resolve(spec.transposer)
        if not tp then return nil, "transposer: " .. tostring(e1) end
        local itf, e2 = resolve(spec.interface)
        if not itf then return nil, "interface: " .. tostring(e2) end
        if type(spec.interfaceSide) ~= "number" or type(spec.inputBusSide) ~= "number" then
            return nil, "interfaceSide and inputBusSide must be side numbers"
        end
        self.transposer = tp
        self.interface = itf
        self.interfaceSide = spec.interfaceSide
        self.inputBusSide = spec.inputBusSide
        self.interfaceSlot = spec.interfaceSlot or 1
    end
    self.stockTimeout = spec.stockTimeout or 10
    self.pollInterval = spec.pollInterval or 0.25
    self.dryRun = spec.dryRun or false
    self.label = spec.label or "station"
    self.log = spec.log or function() end

    -- Fluid half. All-or-nothing once any of it is given -- a half-configured
    -- plasma feed would fail later and further from the cause.
    if wantFluid then
        local ftp, e4 = resolve(spec.fluidTransposer)
        if not ftp then return nil, "fluidTransposer: " .. tostring(e4) end
        local fitf, e5 = resolve(spec.fluidInterface)
        if not fitf then return nil, "fluidInterface: " .. tostring(e5) end
        if type(spec.fluidInterfaceSide) ~= "number" or type(spec.inputHatchSide) ~= "number" then
            return nil, "fluidInterfaceSide and inputHatchSide must be side numbers"
        end
        local tank = spec.fluidTank or 0
        if type(tank) ~= "number" or tank < 0 or tank > 5 then
            return nil, "fluidTank must be 0..5 (the interface has six tanks, indexed from 0)"
        end
        self.fluidTransposer = ftp
        self.fluidInterface = fitf
        self.fluidInterfaceSide = spec.fluidInterfaceSide
        self.inputHatchSide = spec.inputHatchSide
        self.fluidTank = tank
    end

    return self
end

-- True if this station has an item half (drones and kits).
function Station:hasItems()
    return self.transposer ~= nil
end

-- Ensures `label`'s metadata is in the database and returns its slot, storing it
-- (once per run per database) if needed. nil + err if the item is not in ME.
function Station:ensureDbSlot(filter, label)
    if not self:hasItems() then return nil, "no item half configured" end

    -- One slot per item label, shared across every station on this database. A
    -- name already seen was written on a previous call and can be reused as-is.
    local slot, fresh = self.db:slot("item:" .. label)
    if not slot then return nil, tostring(fresh) end
    if not fresh then return slot end

    local ok, err = pcall(self.interface.store, filter, self.dbAddress, slot, 1)
    if not ok then return nil, "interface.store errored: " .. tostring(err) end

    -- store() is silent on "nothing matched", so confirm the slot got populated.
    local held, why = self.db:holds(slot, nil)
    if not held then
        self.db:clear(slot)   -- keep the database tidy on failure
        return nil, "'" .. label .. "' not found in the ME network (" .. why .. ")"
    end
    return slot
end

-- Clears the interface's staging config (also returns any stocked item to ME).
function Station:clearConfig()
    if not self:hasItems() or self.dryRun then return end
    pcall(self.interface.setInterfaceConfiguration, self.interfaceSlot)
end

-- Returns a list of { slot, label, name, size } for each occupied input-bus slot.
-- getAllStacks returns a 0-indexed array (pairs catches index 0), but transferItem
-- takes 1-based slot numbers, so the slot is the array index + 1.
function Station:busStacks()
    local out = {}
    if not self:hasItems() then return out end
    for i, s in pairs(readStacks(self.transposer, self.inputBusSide)) do
        if type(s) == "table" and (s.size or 0) > 0 and (s.name or s.label) then
            out[#out + 1] = { slot = i + 1, label = s.label, name = s.name, size = s.size }
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

-- ---- fluid half ------------------------------------------------------------

-- True if this station has a plasma feed configured.
function Station:hasFluid()
    return self.fluidTransposer ~= nil
end

-- Level and capacity (mB) of a tank the fluid transposer can see. `tank0` is
-- 0-based, matching transferFluid and the interface config; the read methods
-- count from one, and this is the ONLY place that knows it.
function Station:tank(side, tank0)
    if not self.fluidTransposer then return 0, 0 end
    local t = (tank0 or 0) + 1
    local okL, level = pcall(self.fluidTransposer.getTankLevel, side, t)
    local okC, capacity = pcall(self.fluidTransposer.getTankCapacity, side, t)
    return (okL and tonumber(level)) or 0, (okC and tonumber(capacity)) or 0
end

-- The module's input hatch: level, capacity.
function Station:hatchTank()
    return self:tank(self.inputHatchSide, 0)
end

-- The interface tank plasma is staged in: level, capacity (16,000 L).
function Station:bufferTank()
    return self:tank(self.fluidInterfaceSide, self.fluidTank)
end

-- Which fluid is in the module's input hatch: its label, or nil when empty. A
-- GT hatch holds one fluid at a time, so this is what says whether a plasma
-- switch has actually taken effect yet.
function Station:hatchFluid()
    if not self.fluidTransposer then return nil end
    local ok, f = pcall(self.fluidTransposer.getFluidInTank, self.inputHatchSide, 1)
    if not ok or type(f) ~= "table" then return nil end
    -- Some builds hand back the tank list rather than the tank.
    if f.label == nil and type(f[1]) == "table" then f = f[1] end
    if type(f.label) ~= "string" or (f.amount or 0) <= 0 then return nil end
    return f.label, f.amount
end

-- Points this station's interface tank at a plasma, by database slot (see
-- supply.storePlasmaDrop -- the entry has to be an ae2fc drop). Unlike the item
-- path this config is LEFT SET: the tank then keeps ~16,000 L staged for a
-- continuously-drained hatch, which is the whole reason a pull feed beats a
-- clear-after-every-use one. Returns true, or false + error.
function Station:setPlasmaSource(dbSlot)
    if not self:hasFluid() then return false, "no fluid half configured" end
    if self.dryRun then
        self.log(string.format("[dry] %s: stage plasma from db slot %d in tank %d",
            self.label, dbSlot, self.fluidTank))
        return true
    end
    local ok, err = pcall(self.fluidInterface.setFluidInterfaceConfiguration,
        self.fluidTank, self.dbAddress, dbSlot)
    if not ok then return false, "setFluidInterfaceConfiguration failed: " .. tostring(err) end
    return true
end

-- Clears the staging tank's config, handing whatever it holds back to the
-- network. Do this before switching plasma, so the tank cannot refuse the drained
-- hatch contents for being the wrong fluid.
function Station:clearPlasmaSource()
    if not self:hasFluid() or self.dryRun then return end
    pcall(self.fluidInterface.setFluidInterfaceConfiguration, self.fluidTank)
end

-- Moves fluid between two of the fluid transposer's sides. Returns moved, err.
-- transferFluid answers (ok, amount) on success and (false, message) on refusal,
-- which pcall turns into three values.
function Station:moveFluid(fromSide, toSide, amount, sourceTank)
    if amount <= 0 then return 0 end
    local ok, res, moved = pcall(self.fluidTransposer.transferFluid,
        fromSide, toSide, amount, sourceTank or 0)
    if not ok then return 0, tostring(res) end
    if res ~= true then return 0, tostring(moved or "transfer refused") end
    return tonumber(moved) or 0
end

-- Tops the module's hatch up to `target` litres from the staging tank, capped by
-- what the hatch can hold. Returns moved, err. Moving nothing is normal -- it
-- means the hatch is already full enough, or the staging tank has not refilled
-- yet.
function Station:fillHatch(target)
    if not self:hasFluid() then return 0, "no fluid half configured" end
    local level, capacity = self:hatchTank()
    if capacity > 0 and target > capacity then target = capacity end
    local want = target - level
    if want <= 0 then return 0 end

    if self.dryRun then
        self.log(string.format("[dry] %s: fill hatch %d -> %d mB", self.label, level, target))
        return want
    end
    return self:moveFluid(self.fluidInterfaceSide, self.inputHatchSide, want, self.fluidTank)
end

-- Empties the module's hatch back through the interface into the network. Needed
-- when the plasma choice changes: a GT hatch holds ONE fluid, so it will refuse
-- the new plasma until the old one is gone. Clear the staging config first.
-- Returns moved, err.
function Station:drainHatch()
    if not self:hasFluid() then return 0, "no fluid half configured" end
    local level = self:hatchTank()
    if level <= 0 then return 0 end
    if self.dryRun then
        self.log(string.format("[dry] %s: drain %d mB from the hatch", self.label, level))
        return level
    end
    return self:moveFluid(self.inputHatchSide, self.fluidInterfaceSide, level, 0)
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

    if not self:hasItems() then
        job.phase, job.ok, job.err = "error", false, "no item half configured"
        return job
    end

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

    -- getStackInSlot / transferItem take 1-based slot numbers that match the ME
    -- config slot, so the stocked item is at interfaceSlot (only getAllStacks
    -- returns a 0-indexed array -- see busStacks).
    local ok, stack = pcall(self.transposer.getStackInSlot, self.interfaceSide, self.interfaceSlot)
    local arrived = ok and type(stack) == "table"
        and stack.label == job.label and (stack.size or 0) >= job.count

    if arrived then
        local okT, moved = pcall(self.transposer.transferItem,
            self.interfaceSide, self.inputBusSide, job.count, self.interfaceSlot)
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

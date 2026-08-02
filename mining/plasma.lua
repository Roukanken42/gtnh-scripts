-- Manual plasma tool -- drives each module's plasma feed and shows what is in
-- the hatches. The controller will do this on its own; until then this is how
-- you exercise the fluid half of a station (ME fluid interface -> transposer ->
-- input hatch) and watch a switch actually take.
--
-- Run from this folder:
--   plasma                  what each module's hatch holds, and against what target
--   plasma list             the same
--   plasma <name>           switch every module to that plasma and fill
--   plasma keep [name]      keep every hatch topped up until interrupted
--   plasma fill             top the hatches up with whatever they already hold
--   plasma drain            empty the hatches back into the network
--
-- Switching is not instant. A GT hatch holds ONE fluid, so a module already
-- holding the old plasma has to be drained before it will take the new one --
-- that is done for you here, but the staging tank then has to refill from ME.
--
-- `keep` is the one that runs: it holds every hatch full so a mining setup can be
-- driven by hand, without the controller. However it is stopped it hands
-- everything back -- staging cleared, hatches drained -- because keeping fluid in
-- the hatches is precisely what running it is for.
--
-- See config.lua for cfg.supply.hatchMeteors (how much to keep) and the per-
-- station fluid fields.

local miners = require("miners")
local transport = require("transport")
local dbslots = require("db")
local supply = require("supply")
local plasmas = require("plasmas")
local localnet = require("localnet")
local computer = require("computer")
local cfg = require("config")

local scfg = cfg.supply or {}

local shared = {
    database = cfg.database,
    dryRun = cfg.dryRun,
    stockTimeout = cfg.stockTimeout,
    interfaceSlot = cfg.interfaceSlot,
    log = print,
}

-- ---- setup -----------------------------------------------------------------

local list = miners.discover()
local fluid = {}    -- miners whose station has a fluid half
for _, m in ipairs(list) do
    local spec = cfg.stations and cfg.stations[m.address]
    if spec then
        local ok, err = miners.attachStation(m, spec, shared)
        if not ok then
            print("  ! station " .. m.address:sub(1, 8) .. ": " .. tostring(err))
        elseif m.station:hasFluid() then
            fluid[#fluid + 1] = m
        end
    end
end

if #list == 0 then
    print("No miners discovered. Are the Adapters connected?")
    return
end
if #fluid == 0 then
    print(string.format("None of the %d discovered miner(s) has a plasma feed configured.", #list))
    print("Add the fluid fields to cfg.stations (see config.lua): fluidTransposer,")
    print("fluidInterface, fluidInterfaceSide, inputHatchSide, fluidTank.")
    return
end

-- ---- helpers ---------------------------------------------------------------

-- Resolve a plasma by name or prefix ("radon", "Radon Plasma", "5").
local function findPlasma(name)
    local tier = tonumber(name)
    if tier and plasmas.byTier[tier] then return plasmas.byTier[tier] end
    local lower = tostring(name):lower()
    for _, p in ipairs(plasmas.list) do
        if p.name:lower():sub(1, #lower) == lower then return p end
    end
    return nil
end

-- The plasma a hatch currently holds, as a plasmas.lua entry (or nil).
local function hatchPlasma(m)
    local label = m.station:hatchFluid()
    return label and plasmas.byName[label] or nil, label
end

local function targetFor(p)
    return supply.hatchLitres(p, scfg)
end

-- Puts the ae2fc drop for `p` into the shared database and returns its slot. The
-- drop only exists on the supply network -- the local net holds plasma as fluid
-- -- so it is lifted out of the supply interface's own pattern.
local function plasmaDbSlot(p)
    local itf, err = supply.find(scfg.interface)
    if not itf then return nil, "supply interface: " .. tostring(err) end

    -- Resolved against the database: a fake pattern's output is a renamed item and
    -- the pattern slot only reports its base type, so requesting by that would
    -- craft the wrong thing (see supply.resolveOutput).
    local handle, dbErr = dbslots.open(cfg.database)
    if not handle then return nil, "database: " .. tostring(dbErr) end

    local catalog = supply.catalog(itf, handle)
    local entry
    for _, e in ipairs(catalog) do
        if e.kind == "plasma" and e.plasma.tier == p.tier then entry = e; break end
    end
    if not entry then
        return nil, "the supply interface has no pattern for " .. p.name
            .. " -- its drop is the only way to name a fluid to the interface"
    end

    -- The drop keeps a permanent slot: the fluid interface points at it for as
    -- long as this plasma is the one being staged.
    return supply.storePlasmaDrop(itf, entry, handle)
end

-- Fills a station's hatch to `target`, waiting for the staging tank to refill
-- from ME between transfers. Returns total moved.
local function fillUp(m, target, timeout)
    local moved, deadline = 0, computer.uptime() + (timeout or 15)
    while computer.uptime() < deadline do
        local level = m.station:hatchTank()
        if level >= target then break end
        local n = m.station:fillHatch(target)
        moved = moved + (n or 0)
        if cfg.dryRun then break end
        if (n or 0) <= 0 then os.sleep(0.5) end   -- staging tank still refilling
    end
    return moved
end

-- Empties a hatch back into the network. Loops for the same reason fillUp does,
-- in reverse: it drains through an interface tank that holds only 16,000 L, so a
-- large hatch needs several passes with time in between for the network to take
-- each one. Clear the staging config first, or the tank will refuse fluid that is
-- not what it was told to stock. Returns total moved.
local function drainDown(m, timeout)
    local moved, deadline = 0, computer.uptime() + (timeout or 20)
    while computer.uptime() < deadline do
        if m.station:hatchTank() <= 0 then break end
        local n = m.station:drainHatch()
        moved = moved + (n or 0)
        if cfg.dryRun then break end
        if (n or 0) <= 0 then os.sleep(0.5) end   -- interface tank still emptying
    end
    return moved
end

-- ---- commands --------------------------------------------------------------

local function cmdList()
    print(string.format("%-11s %-22s %-11s %-11s %s",
        "MINER", "IN HATCH", "LEVEL", "TARGET", "STAGED"))
    for _, m in ipairs(fluid) do
        local p, label = hatchPlasma(m)
        local level, capacity = m.station:hatchTank()
        local staged = m.station:bufferTank()
        local target = p and targetFor(p) or nil
        print(string.format("%-11s %-22s %-11s %-11s %d L",
            m.address:sub(1, 8), label or "(empty)",
            string.format("%d/%d", level, capacity),
            target and tostring(target) .. " L" or "-", staged))
        if label and not p then
            print("            ! not a known plasma -- the module cannot mine on it")
        elseif p and target and level < target * (scfg.lowWater or 0.9) then
            print("            low -- run `plasma fill`")
        end
    end
    local skipped = #list - #fluid
    if skipped > 0 then
        print(string.format("(%d other miner(s) have no plasma feed configured)", skipped))
    end
end

local function cmdSet(name)
    local p = findPlasma(name)
    if not p then
        print("No plasma matches '" .. tostring(name) .. "'. Known:")
        for _, x in ipairs(plasmas.list) do
            print(string.format("  %d  %-22s %d L per meteor", x.tier, x.name, x.consumed))
        end
        return
    end

    local slot, err = plasmaDbSlot(p)
    if not slot then print("Cannot stage " .. p.name .. ": " .. tostring(err)); return end

    local target = targetFor(p)
    print(string.format("Switching %d module(s) to %s (%d L per hatch)%s",
        #fluid, p.name, target, cfg.dryRun and "  [DRY RUN]" or ""))

    for _, m in ipairs(fluid) do
        local tag = m.address:sub(1, 8)
        local have, label = hatchPlasma(m)

        -- A hatch holds one fluid: the old one has to go before the new is taken,
        -- and all of it -- a partial drain leaves the hatch refusing the new plasma.
        if label and label ~= p.name then
            m.station:clearPlasmaSource()
            local drained = drainDown(m)
            print(string.format("  %s  drained %d L of %s", tag, drained, label))
        end

        local ok, serr = m.station:setPlasmaSource(slot)
        if not ok then
            print(string.format("  %s  FAIL %s", tag, tostring(serr)))
        else
            local moved = fillUp(m, target)
            local level = m.station:hatchTank()
            print(string.format("  %s  %s +%d L -> %d/%d L%s", tag, p.name, moved, level, target,
                level < target and "  (staging tank still refilling; run `plasma fill`)" or ""))
        end
    end
end

local function cmdFill()
    for _, m in ipairs(fluid) do
        local tag = m.address:sub(1, 8)
        local p, label = hatchPlasma(m)
        if not p then
            -- Nothing in the hatch to identify: the staging tank knows instead.
            print(string.format("  %s  hatch is %s -- run `plasma <name>` to choose one",
                tag, label and ("holding " .. label) or "empty"))
        else
            local target = targetFor(p)
            local moved = fillUp(m, target)
            print(string.format("  %s  %s +%d L -> %d/%d L", tag, p.name, moved,
                (m.station:hatchTank()), target))
        end
    end
end

-- Keeps every hatch topped up until interrupted. Meant for running a mining setup
-- by hand: pick a plasma once and the modules stay fed without the controller.
--
-- Refills are deliberately lazy. A hatch is left alone until it drops below
-- cfg.supply.hatchRefill of its target and is then filled right back to the top,
-- so each transfer moves a large batch and the loop spends almost all its time
-- just reading tank levels.
local function cmdKeep(name)
    local p
    if name then
        p = findPlasma(name)
        if not p then
            print("No plasma matches '" .. tostring(name) .. "'. Known:")
            for _, x in ipairs(plasmas.list) do
                print(string.format("  %d  %-22s %d L per meteor", x.tier, x.name, x.consumed))
            end
            return
        end
    else
        -- No name: carry on with whatever the hatches already hold.
        for _, m in ipairs(fluid) do
            local hp = hatchPlasma(m)
            if hp then p = hp; break end
        end
        if not p then
            print("No plasma in any hatch to continue with -- name one: plasma keep <name>")
            return
        end
    end

    local slot, err = plasmaDbSlot(p)
    if not slot then print("Cannot stage " .. p.name .. ": " .. tostring(err)); return end

    -- Point every station at it, clearing out anything different first: a GT hatch
    -- holds one fluid and will refuse the new one until the old is gone.
    for _, m in ipairs(fluid) do
        local _, label = hatchPlasma(m)
        if label and label ~= p.name then
            m.station:clearPlasmaSource()
            local drained = drainDown(m)
            print(string.format("  %s  drained %d L of %s", m.address:sub(1, 8), drained, label))
        end
        local ok, serr = m.station:setPlasmaSource(slot)
        if not ok then print(string.format("  %s  FAIL %s", m.address:sub(1, 8), tostring(serr))) end
    end

    local target = targetFor(p)
    local refill = scfg.hatchRefill or 0.5
    local poll = scfg.hatchPoll or 5
    print(string.format("Keeping %d hatch(es) at %d L of %s, topping up below %d%%.",
        #fluid, target, p.name, math.floor(refill * 100)))
    print("Press q (or Ctrl-C) to stop.")

    local event = require("event")
    local topped = 0

    local function loop()
        while true do
            for _, m in ipairs(fluid) do
                local level, capacity = m.station:hatchTank()
                local want = (capacity > 0) and math.min(target, capacity) or target
                if level < want * refill then
                    local moved = fillUp(m, want)
                    topped = topped + 1
                    print(string.format("[%s] %s  %d -> %d L (+%d)", os.date("%H:%M:%S"),
                        m.address:sub(1, 8), level, m.station:hatchTank(), moved))
                end
            end
            -- Waiting on the event queue rather than sleeping keeps q responsive.
            local _, _, ch = event.pull(poll, "key_down")
            if ch == 113 then return end   -- 'q'
        end
    end

    local ok, lerr = pcall(loop)

    -- Put everything back, however this ended -- q, Ctrl-C or an error. Nothing
    -- staged and nothing parked: each station holds up to 16,000 L in an interface
    -- tank and however much its hatch takes, and leaving that behind keeps fluid
    -- out of the network for as long as nobody notices. Keeping the hatches full
    -- is what running this command is FOR, so stopping it gives the fluid back.
    --
    -- Configs are cleared for every station before any draining starts, so each
    -- interface tank has had a chance to empty into the network by the time a
    -- hatch tries to push through it.
    print("Stopping: clearing staging and returning hatch contents...")
    for _, m in ipairs(fluid) do m.station:clearPlasmaSource() end

    local returned, left = 0, 0
    for _, m in ipairs(fluid) do
        returned = returned + drainDown(m)
        local remaining = m.station:hatchTank()
        if remaining > 0 then
            left = left + remaining
            print(string.format("  %s  %d L would not go back -- is the network full?",
                m.address:sub(1, 8), remaining))
        end
    end
    print(string.format("Stopped after %d top-up(s); returned %d L%s.", topped, returned,
        left > 0 and string.format(", %d L still in hatches", left) or ""))

    -- An interrupt is how this is meant to end; anything else is a real error.
    if not ok and not tostring(lerr):find("interrupt") then error(lerr, 0) end
end

local function cmdDrain()
    -- Configs first, all of them, so each interface tank is free by the time a
    -- hatch drains through it.
    for _, m in ipairs(fluid) do m.station:clearPlasmaSource() end
    for _, m in ipairs(fluid) do
        local drained = drainDown(m)
        local left = m.station:hatchTank()
        print(string.format("  %s  drained %d L%s%s", m.address:sub(1, 8), drained,
            left > 0 and string.format(", %d L left", left) or "",
            cfg.dryRun and "  [dry]" or ""))
    end
end

local function usage(msg)
    if msg then print(msg) end
    print("Usage:")
    print("  plasma              what each hatch holds, and against what target")
    print("  plasma <name>       switch every module to that plasma and fill")
    print("  plasma keep [name]  keep every hatch topped up until interrupted")
    print("                      (returns the fluid to the network on the way out)")
    print("  plasma fill         top the hatches up with what they already hold")
    print("  plasma drain        empty the hatches back into the network")
    print(string.format("Config: hatchMeteors=%s, dryRun=%s",
        tostring(scfg.hatchMeteors or 64), tostring(cfg.dryRun)))
end

-- ---- dispatch --------------------------------------------------------------

local args = { ... }
local a1 = args[1]

if a1 == nil or a1 == "list" or a1 == "ls" then
    cmdList()
elseif a1 == "keep" then
    cmdKeep(args[2])
elseif a1 == "fill" then
    cmdFill()
elseif a1 == "drain" then
    cmdDrain()
elseif a1 == "help" or a1 == "-h" then
    usage()
else
    cmdSet(a1)
end

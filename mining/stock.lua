-- Manual supply tool -- shows what the main net can push into the local mining
-- net, and pushes it. The controller will do this on its own; until then this is
-- how you exercise the whole path (adapter -> patterns -> craft request -> local
-- net) and check a target table after editing it.
--
-- Run from this folder:
--   stock                    what is on offer, and stock against target
--   stock list               the same
--   stock patterns           RAW pattern dump -- run this first, see below
--   stock <material> [kits]  push kits of a drone material (default: 1)
--   stock plasma <name> [L]  push litres of a plasma pattern
--   stock auto               request whatever the targets say is missing
--
-- `stock patterns` is the one to run first on a fresh setup. Everything else
-- depends on getInterfacePattern returning what the docs say it does -- if the
-- dump looks wrong, nothing built on top of it will behave.
--
-- See config.lua for the supply interface address and the target levels.

local supply = require("supply")
local transport = require("transport")
local localnet = require("localnet")
local cfg = require("config")

local scfg = cfg.supply or {}

-- ---- setup -----------------------------------------------------------------

local itf, err = supply.find(scfg.interface)
if not itf then
    print("No supply interface: " .. tostring(err))
    return
end

local net = localnet.proxy()
if not net then
    print("Warning: no local me_controller found -- stock levels will read as zero.")
end

-- ---- helpers ---------------------------------------------------------------

-- The catalog, built once. A database and a scratch slot are passed so each
-- pattern's REAL output item is read back: a fake pattern's output is usually a
-- renamed item, and the pattern slot only reports the underlying type. Without
-- this, "Mining Kit: Steel" reads as "Steel Drill Tip" and a request would craft
-- drill tips into main-net storage instead of pushing anything across.
local catalogCache, unknownCache
local function getCatalog()
    if not catalogCache then
        local scratch = cfg.database and transport.reserveDbSlot(cfg.database) or nil
        catalogCache, unknownCache = supply.catalog(itf, cfg.database, scratch)
        if not cfg.database then
            print("WARNING: no database configured -- pattern outputs cannot be resolved,")
            print("         so nothing can be requested. Run `setup`, or set cfg.database.")
        end
    end
    return catalogCache, unknownCache
end

local function describeInputs(entry)
    local parts = {}
    for _, i in ipairs(entry.inputs) do
        parts[#parts + 1] = i.count .. "x " .. i.name
    end
    return table.concat(parts, " + ")
end

local function targetFor(entry)
    if entry.kind == "kit" then return (scfg.target or {})[entry.material] end
    if entry.kind == "plasma" then return (scfg.plasma or {})[entry.plasma.name] end
    return nil
end

-- Blocks until a craft request settles. Fake-crafting patterns finish as soon as
-- their inputs are pushed, so this is short; the cap is a stuck-job backstop.
local function settle(job, label)
    local computer = require("computer")
    local deadline = computer.uptime() + 10
    local state = supply.jobState(job)
    while state == "computing" and computer.uptime() < deadline do
        os.sleep(0.25)
        state = supply.jobState(job)
    end
    if state == "done" then
        print("  OK   " .. label)
    elseif state == "computing" then
        print("  ??   " .. label .. "  (still computing after 10s -- check the CPU)")
    else
        print("  FAIL " .. label .. "  (" .. state .. ")")
    end
    return state
end

local function request(entry, crafts, what)
    local job, e = supply.request(itf, entry, crafts)
    if not job then print("  FAIL " .. what .. ": " .. tostring(e)); return false end
    return settle(job, what) == "done"
end

-- ---- commands --------------------------------------------------------------

local function cmdPatterns()
    local raw = supply.readPatterns(itf)
    print(string.format("Interface %s: %d pattern(s) found in %d slots probed.",
        itf.address:sub(1, 8), #raw, supply.MAX_PATTERN_SLOTS))

    local database = cfg.database
    local scratch = database and require("transport").reserveDbSlot(database) or nil
    if database then
        local ok, p = pcall(require("component").proxy, database)
        database = ok and p or nil
    end

    for _, p in ipairs(raw) do
        local entry = supply.classify(p)
        if database and entry.kind ~= "unknown" then
            local ok, err = supply.resolveOutput(itf, entry, database, scratch)
            if not ok then entry.outputError = err end
        end
        print(string.format("  [%2d] %-34s %s", p.index, tostring(entry.label), entry.kind))
        print("       in : " .. describeInputs(entry))
        -- Always print the resolved output, not just when it differs from the slot
        -- name: this is the line that says what a craft request will actually
        -- target, and "resolved to the same label" has to be distinguishable from
        -- "never resolved". A renamed fake output reads back from the pattern slot
        -- as its BASE item, which is usually a real craftable in its own right.
        if entry.output then
            local o = entry.output
            print(string.format("       out: %s  [%s%s]", tostring(o.label),
                tostring(o.name), o.damage and (":" .. tostring(o.damage)) or ""))
            if entry.slotLabel and entry.slotLabel ~= entry.label then
                print("            slot reported the base item: " .. entry.slotLabel)
            else
                print("            slot reported the same -- nothing renamed here")
            end
        elseif entry.outputError then
            print("       out: UNRESOLVED -- " .. entry.outputError)
        elseif entry.kind ~= "unknown" then
            print("       out: not resolved (no database configured)")
        end
        if entry.reason then print("       why: " .. entry.reason) end
    end
    if #raw == 0 then
        print("  Nothing. Is the adapter on the interface that holds the patterns?")
    end
    if not database then
        print("  (no database configured, so real output labels could not be read)")
    end
end

local function cmdList()
    local catalog, unknown = getCatalog()
    if #catalog == 0 and #unknown == 0 then
        print("The supply interface has no patterns. Try `stock patterns`.")
        return
    end

    local stock = supply.stock(catalog, net)
    print(string.format("%-16s %-22s %-9s %-9s %s",
        "KIND", "WHAT", "HAVE", "TARGET", "PER CRAFT"))
    for _, entry in ipairs(catalog) do
        local what, have, unit
        if entry.kind == "kit" then
            what, unit = entry.material, "kits"
            have = supply.kitsInStock(entry, stock.items)
        elseif entry.kind == "plasma" then
            what, unit = entry.plasma.name, "L"
            have = supply.plasmaInStock(entry, stock)
        else
            what, unit = entry.drone and entry.drone.name or entry.label, ""
            have = supply.kitsInStock(entry, stock.items)
        end
        local target = targetFor(entry)
        print(string.format("%-16s %-22s %-9s %-9s %d %s",
            entry.kind, what, tostring(have) .. " " .. unit,
            target and tostring(target) or "-", entry.perCraft or 0, unit))
    end

    for _, entry in ipairs(unknown) do
        print(string.format("  ? %-30s %s", tostring(entry.label), entry.reason or ""))
    end

    local work, notes = supply.plan(catalog, stock, scfg, {})
    if #work == 0 and #notes == 0 then
        print("Everything at target.")
    end
    for _, w in ipairs(work) do
        print(string.format("  short %-20s %d of %d -- %d craft(s)",
            w.key, w.have, w.target, w.crafts))
    end
    for _, n in ipairs(notes) do print("  note: " .. n) end
end

local function cmdMaterial(name, kits)
    local catalog = getCatalog()
    for _, entry in ipairs(catalog) do
        if entry.kind == "kit" and entry.material:lower() == name:lower() then
            local crafts = math.max(1, math.ceil(kits / math.max(1, entry.perCraft)))
            print(string.format("Requesting %d craft(s) of %s -> %d kit(s): %s",
                crafts, entry.label, crafts * entry.perCraft, describeInputs(entry)))
            request(entry, crafts, entry.material)
            return
        end
    end
    print("No kit pattern for '" .. name .. "'. Try `stock list`.")
end

local function cmdPlasma(name, litres)
    local catalog = getCatalog()
    for _, entry in ipairs(catalog) do
        if entry.kind == "plasma" and entry.plasma.name:lower():sub(1, #name) == name:lower() then
            local crafts = math.max(1, math.ceil((litres or 0) / math.max(1, entry.perCraft)))
            local before = (supply.stock(catalog, net).fluids or {})[entry.plasma.name] or 0
            print(string.format("Requesting %d craft(s) of %s -> %d L (have %d L)",
                crafts, entry.label, crafts * entry.perCraft, before))
            if request(entry, crafts, entry.plasma.name) then
                os.sleep(1)
                local after = (supply.stock(catalog, net).fluids or {})[entry.plasma.name] or 0
                print(string.format("  %d L -> %d L  (%+d L, expected %+d)",
                    before, after, after - before, crafts * entry.perCraft))
            end
            return
        end
    end
    print("No plasma pattern matching '" .. name .. "'. Try `stock list`.")
end

local function cmdAuto()
    local catalog = getCatalog()
    local stock = supply.stock(catalog, net)
    -- A fresh latch each run: the hysteresis in supply.plan is for the
    -- controller's loop, where the table persists across cycles.
    local work, notes = supply.plan(catalog, stock, scfg, {})
    if #work == 0 then
        print("Nothing to request -- everything at target.")
    end
    for _, w in ipairs(work) do
        print(string.format("%s: %d of %d, requesting %d craft(s)",
            w.key, w.have, w.target, w.crafts))
        request(w.entry, w.crafts, w.key)
    end
    for _, n in ipairs(notes) do print("note: " .. n) end
end

local function usage(msg)
    if msg then print(msg) end
    print("Usage:")
    print("  stock                    what is on offer, and stock against target")
    print("  stock patterns           raw pattern dump (run this first)")
    print("  stock <material> [kits]  push kits of a drone material")
    print("  stock plasma <name> [L]  push litres of a plasma pattern")
    print("  stock auto               request whatever the targets say is missing")
end

-- ---- dispatch --------------------------------------------------------------

local args = { ... }
local a1, a2, a3 = args[1], args[2], args[3]

if a1 == nil or a1 == "list" or a1 == "ls" then
    cmdList()
elseif a1 == "patterns" or a1 == "raw" then
    cmdPatterns()
elseif a1 == "auto" then
    cmdAuto()
elseif a1 == "plasma" and a2 then
    cmdPlasma(a2, tonumber(a3) or 1)
elseif a1 == "help" or a1 == "-h" then
    usage()
elseif a2 == nil or tonumber(a2) then
    cmdMaterial(a1, tonumber(a2) or 1)
else
    usage("Unrecognized arguments.")
end

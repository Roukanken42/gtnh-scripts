-- Manual supply tool: shows what the main net can push into the local mining net,
-- and pushes it. Exercises the whole path -- adapter, patterns, craft request,
-- local net -- before there is a controller. See `stock --help`.

local supply = require("lib.hw.supply")
local dbslots = require("lib.hw.db")
local localnet = require("lib.hw.localnet")
local cli = require("lib.cli")
local cfg = require("config")

local ctx = cli.start({
    name = "stock",
    summary = "See what the main net can push into the local mining net, and push it.",
    usage = {
        { "stock",                   "what is on offer, and stock against target" },
        { "stock list",              "the same" },
        { "stock patterns",          "raw pattern dump -- run this one first" },
        { "stock cpus",              "what the main net's crafting bank is making" },
        { "stock <material> [kits]", "push kits of a drone material (default 1)" },
        { "stock plasma <name> [L]", "push litres of a plasma pattern" },
        { "stock auto",              "request whatever the targets say is missing" },
    },
    notes = {
        "`stock patterns` is the one to run first on a fresh setup. Everything "
            .. "else rests on getInterfacePattern returning what the docs say it "
            .. "does -- if that dump looks wrong, nothing built on top of it will "
            .. "behave.",
        "Consumables cross from the main net through fake crafting patterns: "
            .. "requesting one pushes that pattern's INPUTS over. The output is a "
            .. "cosmetic handle, so what a pattern is FOR is read off its inputs.",
        "Nothing is ordered that a crafting CPU is already making, so a busy main "
            .. "net is waited on rather than piled on. `stock cpus` is how to see "
            .. "what that guard can see -- a bank it cannot read plans blind.",
        "The supply interface address and the target levels live in config.lua.",
    },
}, ...)
if not ctx then return end

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

-- One shared slot allocator for this database, so nothing here lands on metadata
-- setup or the controller is relying on (see db.lua).
local handle, dbErr = dbslots.open(cfg.database)
if not handle then
    print("WARNING: " .. tostring(dbErr) .. " -- pattern outputs cannot be resolved,")
    print("         so nothing can be requested. Run `setup`, or set cfg.database.")
end

-- ---- helpers ---------------------------------------------------------------

-- The catalog, built once. The database handle is passed so each pattern's REAL
-- output item is read back: a fake pattern's output is usually a renamed item,
-- and the pattern slot only reports the underlying type. Without this,
-- "Mining Kit: Steel" reads as "Steel Drill Tip" and a request would craft drill
-- tips into main-net storage instead of pushing anything across.
local catalogCache, unknownCache
local function getCatalog()
    if not catalogCache then
        catalogCache, unknownCache = supply.catalog(itf, handle)
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

-- What a crafting CPU is already making for a catalog key, as a column. "?" is a
-- CPU that is demonstrably making it and would not say how much -- which is not the
-- same as none, and is the case that stops an order rather than shrinking one.
local function comingText(coming, key)
    local c = key and coming and coming[key]
    if not c then return "-" end
    if c.unknown then return "?" end
    return tostring(math.floor((c.units or 0) + 0.5))
end

-- Why the guard might be seeing less than the whole crafting bank. Printed under
-- anything that plans, because a blind guard and an idle bank look the same from
-- the outside and only one of them will re-order what is already on its way.
local function reportCpus(info)
    if info.error then
        print("  (the crafting bank could not be read: " .. info.error .. ")")
        print("   nothing can be told about what is already being made, so a slow")
        print("   main net may be asked for the same thing twice")
    elseif info.note then
        print("  (" .. info.note .. ")")
    elseif info.unreadable > 0 then
        print(string.format("  (%d of %d busy CPU(s) would not say what they are "
            .. "making -- finalOutput needs a Crafting Monitor in the CPU)",
            info.unreadable, info.busy))
    end
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
    local job, items = supply.request(itf, entry, crafts)
    if not job then print("  FAIL " .. what .. ": " .. tostring(items)); return false end
    -- Say what AE2 was actually asked for. It is a number of output ITEMS, and only
    -- equals the craft count when the pattern's output is a single item.
    if items and items ~= crafts then
        print(string.format("  (asked AE2 for %d output item(s) -- %d craft(s) x %d "
            .. "per craft)", items, crafts, entry.outputCount or 1))
    end
    return settle(job, what) == "done"
end

-- ---- commands --------------------------------------------------------------

local function cmdPatterns()
    local raw = supply.readPatterns(itf)
    print(string.format("Interface %s: %d pattern(s) found in %d slots probed.",
        itf.address:sub(1, 8), #raw, supply.MAX_PATTERN_SLOTS))

    for _, p in ipairs(raw) do
        local entry = supply.classify(p)
        if handle and entry.kind ~= "unknown" then
            local ok, err = supply.resolveOutput(itf, entry, handle)
            if not ok then entry.outputError = err end
        end
        print(string.format("  [%2d] %-34s %s", p.index, tostring(entry.label), entry.kind))
        print("       in : " .. describeInputs(entry))
        -- Always print the resolved output, not just when it differs from the slot
        -- name: this is the line that says what a craft request will actually
        -- target, and "resolved to the same label" has to be distinguishable from
        -- "never resolved". A renamed fake output reads back from the pattern slot
        -- as its BASE item, which is usually a real craftable in its own right.
        -- What ONE craft is worth, in the units the controller plans in, and how many
        -- output items that craft makes. The second number is the one that catches
        -- people out: a craft request asks AE2 for a number of ITEMS, so an output
        -- stack of 64 turns a request for 13 crafts into one.
        if entry.kind ~= "unknown" then
            local unit = (entry.kind == "plasma") and "L" or "kits"
            print(string.format("       one craft: %s %s  ->  %d output item(s)%s",
                tostring(entry.perCraft), unit, entry.outputCount or 1,
                (entry.outputCount or 1) > 1
                    and "   (so a request is multiplied by that)" or ""))
        end
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
    if not handle then
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
    -- COMING is read off the main net's crafting CPUs, and it is what turns "this
    -- is 2,000 kits short" into either "and nothing is happening about it" or "and
    -- it is already being made". The plan below acts on the difference.
    local coming, cpuInfo = supply.inFlight(itf, catalog)
    print(string.format("%-16s %-22s %-9s %-9s %-9s %s",
        "KIND", "WHAT", "HAVE", "TARGET", "COMING", "PER CRAFT"))
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
        print(string.format("%-16s %-22s %-9s %-9s %-9s %d %s",
            entry.kind, what, tostring(have) .. " " .. unit,
            target and tostring(target) or "-",
            comingText(coming, supply.keyOf(entry)), entry.perCraft or 0, unit))
    end

    for _, entry in ipairs(unknown) do
        print(string.format("  ? %-30s %s", tostring(entry.label), entry.reason or ""))
    end

    local work, notes = supply.plan(catalog, stock, scfg, {}, coming)
    if #work == 0 and #notes == 0 then
        print("Nothing to order: everything is at target or already being made.")
    end
    for _, w in ipairs(work) do
        print(string.format("  short %-20s %d of %d%s -- %d craft(s)",
            w.key, w.have, w.target,
            (w.coming or 0) > 0
                and string.format(", %d on the way", math.floor(w.coming + 0.5)) or "",
            w.crafts))
    end
    for _, n in ipairs(notes) do print("  note: " .. n) end
    reportCpus(cpuInfo)
end

-- What the main net's crafting bank is busy with, and which of it is ours. The
-- companion to `stock patterns`: that one says what COULD be pushed across, this
-- one says what is being made right now -- and it is the same read the planner
-- makes, so a job listed here as ours is one that will not be ordered again.
local function cmdCpus()
    local catalog = getCatalog()
    local coming, info = supply.inFlight(itf, catalog)

    if info.error then
        print("Cannot read the crafting bank: " .. info.error)
        print("The adapter has to be on an interface belonging to the MAIN net --")
        print("the same one the patterns live on.")
        return
    end
    if info.note then
        -- The bank was never asked, so the counts below would all read zero and
        -- look like an idle main net rather than a scan that could not start.
        print("Nothing to look for: " .. info.note)
        print("Run `setup`, or set cfg.database, then try again.")
        return
    end

    print(string.format("%d CPU(s) on the main net, %d busy.", info.cpus, info.busy))
    if #info.jobs == 0 then
        print("  Nothing is being crafted.")
    end
    for _, j in ipairs(info.jobs) do
        local name = (j.cpu and j.cpu ~= "") and j.cpu or "(unnamed)"
        if not j.label then
            print(string.format("  %-20s ? would not say what it is making", name))
        else
            print(string.format("  %-20s %s x%s%s", name, tostring(j.label),
                tostring(j.size or "?"),
                j.key and ("   <- ours: " .. j.key) or ""))
        end
    end

    local any = false
    for key, rec in pairs(coming) do
        if not any then print("Already on its way:"); any = true end
        print(string.format("  %-22s %s (%d output item(s) across %d CPU(s))",
            key, rec.unknown and "amount unknown"
                or (math.floor(rec.units + 0.5) .. " unit(s)"),
            math.floor(rec.items or 0), rec.cpus or 0))
    end
    if not any then print("None of it is anything this catalog would ask for.") end
    reportCpus(info)
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
    -- The crafting bank is consulted here exactly as the controller consults it.
    -- Run by hand while the controller is also running -- or twice in a row while
    -- the main net is slow -- this is what stops the second run ordering the first
    -- run's shortfall all over again.
    local coming, cpuInfo = supply.inFlight(itf, catalog)
    -- A fresh latch each run: the hysteresis in supply.plan is for the
    -- controller's loop, where the table persists across cycles.
    local work, notes = supply.plan(catalog, stock, scfg, {}, coming)
    if #work == 0 then
        print("Nothing to request -- everything is at target or already being made.")
    end
    for _, w in ipairs(work) do
        if (w.coming or 0) > 0 then
            print(string.format("%s: %d of %d, %d already on the way, "
                .. "requesting the other %d craft(s)", w.key, w.have, w.target,
                math.floor(w.coming + 0.5), w.crafts))
        else
            print(string.format("%s: %d of %d, requesting %d craft(s)",
                w.key, w.have, w.target, w.crafts))
        end
        request(w.entry, w.crafts, w.key)
    end
    for _, n in ipairs(notes) do print("note: " .. n) end
    reportCpus(cpuInfo)
end

-- ---- dispatch --------------------------------------------------------------

local a1, a2, a3 = ctx.args[1], ctx.args[2], ctx.args[3]

if a1 == nil or a1 == "list" or a1 == "ls" then
    cmdList()
elseif a1 == "patterns" or a1 == "raw" then
    cmdPatterns()
elseif a1 == "cpus" or a1 == "cpu" then
    cmdCpus()
elseif a1 == "auto" then
    cmdAuto()
elseif a1 == "plasma" and a2 then
    cmdPlasma(a2, tonumber(a3) or 1)
elseif a2 == nil or tonumber(a2) then
    cmdMaterial(a1, tonumber(a2) or 1)
else
    cli.usage(ctx, "Unrecognized arguments.")
end

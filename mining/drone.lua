-- Manual drone tool: loads mining drones into modules and shows what each one
-- holds. Exercises the whole transport path -- config, station, ME, input bus --
-- before there is a controller to do it. See `drone --help`.

local miners = require("lib.hw.miners")
local drones = require("lib.gtnh.drones")
local cli = require("lib.cli")
local cfg = require("config")

local ctx = cli.start({
    name = "drone",
    summary = "Load mining drones into modules, and see what each one holds.",
    usage = {
        { "drone",                "list miners, their station, and current drone" },
        { "drone list",           "the same" },
        { "drone <tier>",         "load tier 1..13 into EVERY configured miner at once" },
        { "drone <miner> <tier>", "load one miner, by index from `list` or address prefix" },
        { "drone clear [miner]",  "return drones to the ME network (all, or one)" },
    },
    notes = {
        "Loading every miner at once is concurrent: each module's ME interface "
            .. "stocks in parallel, which is much faster than one at a time.",
        "Respects cfg.dryRun -- with it true (the default) nothing is moved, moves "
            .. "are only logged. Flip it in config.lua once you have watched a drone "
            .. "move correctly.",
    },
}, ...)
if not ctx then return end

-- Cross-station settings handed to every station (see miners.attachStation).
local shared = {
    database = cfg.database,
    dryRun = cfg.dryRun,
    stockTimeout = cfg.stockTimeout,
    interfaceSlot = cfg.interfaceSlot,
    log = print,
}

-- Discover miners and attach the station configured for each (if any).
local list = miners.discover()
local attachErr = {}   -- miner address -> error string
for _, m in ipairs(list) do
    local spec = cfg.stations and cfg.stations[m.address]
    if spec then
        local ok, err = miners.attachStation(m, spec, shared)
        if not ok then attachErr[m.address] = err end
    end
end

-- ---- helpers -------------------------------------------------------------

-- Resolve a miner reference: a 1-based index from `list`, or an address prefix.
local function resolveMiner(ref)
    local n = tonumber(ref)
    if n and list[n] then return list[n] end
    if type(ref) == "string" and ref ~= "" then
        for _, m in ipairs(list) do
            if m.address:sub(1, #ref) == ref then return m end
        end
    end
    return nil
end

-- What's in a miner's input bus right now: returns (drone|nil, size, otherLabel).
local function busDrone(m)
    if not m.station then return nil end
    local stacks = m.station:busStacks()
    for _, s in ipairs(stacks) do
        local d = drones.fromName(s.label)
        if d then return d, s.size end
    end
    if stacks[1] then return nil, stacks[1].size, stacks[1].label end
    return nil
end

local function stationState(m)
    if not (cfg.stations and cfg.stations[m.address]) then return "none" end
    if attachErr[m.address] then return "ERR" end
    return "ok"
end

-- Collect the target miners for a command: all station-equipped miners, or the
-- single one named by `ref`. Returns list, err.
local function targets(ref)
    if ref == nil then
        local t = {}
        for _, m in ipairs(list) do
            if m.station then t[#t + 1] = m end
        end
        if #t == 0 then return nil, "no miners have a configured station -- run `setup` first" end
        return t
    end
    local m = resolveMiner(ref)
    if not m then return nil, "no miner matches '" .. tostring(ref) .. "' (try `drone list`)" end
    if not m.station then return nil, m.address:sub(1, 8) .. " has no configured station" end
    return { m }
end

-- ---- commands ------------------------------------------------------------

local function cmdList()
    if #list == 0 then
        print("No miners discovered (looking for gt_machine 'projectmoduleminertN').")
        return
    end
    print(string.format("%-3s %-11s %-4s %-5s %-8s %s",
        "#", "ADDRESS", "TIER", "PAR", "STATION", "IN BUS"))
    for i, m in ipairs(list) do
        local cur = "-"
        local d, size, other = busDrone(m)
        if d then
            cur = d.name .. ((size and size > 1) and (" x" .. size) or "")
        elseif other then
            cur = other .. " x" .. tostring(size)
        elseif m.station then
            cur = "(empty)"
        end
        print(string.format("%-3d %-11s %-4s %-5d %-8s %s",
            i, m.address:sub(1, 8) .. "..", m.tierName or "?", m.parallels or 0,
            stationState(m), cur))
    end
    for addr, err in pairs(attachErr) do
        print("  ! station " .. addr:sub(1, 8) .. ": " .. err)
    end
end

local function cmdSet(ref, tier)
    local t, err = targets(ref)
    if not t then print(err); return end

    local drone = drones.get(tier)
    print(string.format("Loading %s into %d miner(s)%s ...",
        drone and drone.name or ("tier " .. tostring(tier)),
        #t, cfg.dryRun and "  [DRY RUN]" or ""))

    local requests = {}
    for _, m in ipairs(t) do
        requests[#requests + 1] = { miner = m, tier = tier, count = cfg.dronesPerModule }
    end

    local results = miners.setDrones(requests)
    local okc, failc = 0, 0
    for _, r in ipairs(results) do
        if r.ok then
            okc = okc + 1
            print(string.format("  OK   %s  %s%s", r.miner.address:sub(1, 8),
                (r.drone and r.drone.name) or "",
                r.note and ("  (" .. r.note .. ")") or ""))
        else
            failc = failc + 1
            print(string.format("  FAIL %s  %s", r.miner.address:sub(1, 8), tostring(r.err)))
        end
    end
    print(string.format("Done: %d ok, %d failed.", okc, failc))
end

local function cmdClear(ref)
    local t, err = targets(ref)
    if not t then print(err); return end
    for _, m in ipairs(t) do
        local moved = m.station:returnAll()
        print(string.format("  %s: returned %d item(s) to ME%s",
            m.address:sub(1, 8), moved, cfg.dryRun and "  [dry]" or ""))
    end
end

-- ---- dispatch ------------------------------------------------------------

local a1, a2 = ctx.args[1], ctx.args[2]

if a1 == nil or a1 == "list" or a1 == "ls" then
    cmdList()
elseif a1 == "clear" or a1 == "unload" then
    cmdClear(a2)
elseif tonumber(a1) and a2 == nil then
    cmdSet(nil, tonumber(a1))
elseif a2 ~= nil and tonumber(a2) then
    cmdSet(a1, tonumber(a2))
else
    cli.usage(ctx, "Unrecognized arguments.")
end

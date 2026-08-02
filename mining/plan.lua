-- Manual targeter tool: asks lib/calc/target.lua what to set a mining module to,
-- and prints the answer. This is how you interrogate the search by hand, and how
-- you sanity-check a cost table after tuning it. See `plan --help`.

local targetm = require("lib.calc.target")
local drones = require("lib.gtnh.drones")
local cli = require("lib.cli")
local cfg = require("config")

local ctx = cli.start({
    name = "plan",
    summary = "Find the cheapest module configuration that serves a demand.",
    usage = {
        { "plan <material>",            "rank configurations by cost per item" },
        { "plan <material> <rate>",     "and cover that many items per second" },
        { "plan <material> +<mat>[:w]", "add a secondary target that may nudge the pick" },
    },
    flags = {
        { "--fast", "run flat out, ignoring the demanded rate" },
        { "--all",  "search every module tier, not just the ones on this network" },
    },
    notes = {
        "<material> is an oredict name (oreEndstoneIron) or a bare material "
            .. "(Iron). The bare form can span prefixes -- oreEndstonePlatinum and "
            .. "dustPlatinum are different items -- and the output says so when it "
            .. "happens.",
        "A secondary target defaults to weight 0.5; write +Gold:0.2 to change it. "
            .. "Weights only matter relative to each other: a secondary pulls the "
            .. "choice when its weighted rate outweighs the primary it costs.",
        "Costs, budgets and what you can actually make live in config.lua. Run "
            .. "this after tuning them to see what changed.",
    },
}, ...)
if not ctx then return end

-- ---- arguments -------------------------------------------------------------

local flags = ctx.flags
local demand, primary = {}, nil

for _, a in ipairs(ctx.args) do
    if a:sub(1, 1) == "+" then
        local name, w = a:match("^%+([^:]+):?(.*)$")
        demand[name] = { weight = tonumber(w) or 0.5, rate = 0 }
    elseif primary == nil then
        primary = a
        demand[a] = { weight = 1, rate = 0 }
    elseif tonumber(a) then
        demand[primary].rate = tonumber(a)
    else
        cli.usage(ctx, "Unrecognized argument '" .. a .. "'.")
        return
    end
end

if primary == nil then cli.help(ctx.spec); return end

-- ---- which modules ---------------------------------------------------------
-- Search the tiers this network actually has, so the answer is one you can act
-- on. --all (or no miners found) falls back to every tier.

local moduleTiers, fleet = nil, ""
if not flags.all then
    local ok, miners = pcall(require, "lib.hw.miners")
    if ok then
        local seen, list = {}, {}
        for _, m in ipairs(miners.discover()) do
            if m.tier and not seen[m.tier] then seen[m.tier] = true; list[#list + 1] = m.tier end
        end
        if #list > 0 then
            table.sort(list)
            moduleTiers = list
            local names = {}
            for _, t in ipairs(list) do names[#names + 1] = "T" .. t end
            fleet = "  (discovered: " .. table.concat(names, " ") .. ")"
        end
    end
end

-- ---- search ----------------------------------------------------------------

io.write("Searching")
local result, err = targetm.search(demand, {
    modules = moduleTiers,
    cost = { ingot = cfg.kitCost, plasma = cfg.plasmaCost, eu = cfg.euCost },
    budget = cfg.budget,
    computation = cfg.computation,
    mode = flags.fast and "fast" or nil,
    limit = 8,
    -- OpenComputers kills a script that runs too long without yielding.
    onProgress = function() io.write("."); if os.sleep then os.sleep(0) end end,
})
print("")

if not result then cli.usage(ctx, "Error: " .. tostring(err)); return end

-- ---- output ----------------------------------------------------------------

local function roman(tier)
    local d = drones.get(tier)
    return d and d.roman or tostring(tier)
end

local function fmt(n)
    if n >= 1e6 then return string.format("%.2fM", n / 1e6) end
    if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
    return string.format("%.1f", n)
end

for _, t in ipairs(result.targets) do
    if t.aggregated then
        print("NOTE: '" .. t.name .. "' covers " .. table.concat(t.oredicts, ", ")
            .. " -- different items, counted together.")
    end
end
for _, s in ipairs(result.skipped) do print("  - " .. s) end

print(string.format("Scanned %d configurations.%s", result.scanned, fleet))

local function printTable(title, list)
    if #list == 0 then return end
    print("")
    print(title)
    print(string.format("%-3s %-9s %-7s %-14s %-4s %-6s %-9s %-9s %s",
        "#", "DIST", "DRONE", "PLASMA", "MOD", "OD", "ITEMS/s", "COST/s", "SCORE"))
    for i, c in ipairs(list) do
        print(string.format("%-3d %-9s %-7s %-14s %-4s %-6.3f %-9s %-9.4f %.3g",
            i, c.distance[1] .. "-" .. c.distance[2], "MK-" .. roman(c.drone),
            c.plasmaName:gsub(" Plasma", ""), c.moduleName, c.overdrive,
            fmt(c.rates[primary] or 0), c.cost.total, c.score))
    end
end

printTable("Cheapest configurations:", result.candidates)

local best = result.candidates[1]
if best then
    print("")
    print(string.format("Best: distance %d-%d (any value), %s, %s, %s, overdrive %.3f (%s), %d parallels",
        best.distance[1], best.distance[2], "Mining Drone MK-" .. roman(best.drone),
        best.plasmaName, best.moduleName, best.overdrive, best.overdriveMode, best.parallels))
    local names = {}
    for name, r in pairs(best.rates) do names[#names + 1] = string.format("%s %s/s", name, fmt(r)) end
    table.sort(names)
    print("  yields   " .. table.concat(names, ", "))
    print(string.format("  purity   %.1f%% of output is demanded (%d meteors in the pool)",
        best.purity * 100, best.meteorsInPool))
    print(string.format("  burns    %.3f %s ingots/s (%.4f kits/s), %.1f L/s %s, %s EU/s",
        best.cost.ingotsPerSecond, best.kitMaterial, best.cost.kits,
        best.cost.plasmaPerSecond, best.plasmaName, fmt(best.cost.euPerSecond)))
    if best.modulesNeeded > 1 then
        print(string.format("  NEEDS    %d modules to cover the demanded rate",
            best.modulesNeeded))
    end
    if best.overdriveMode ~= "fast" then
        print(string.format("  headroom overdrive %.3f would give %s weighted items/s (now %s)",
            best.fastOverdrive, fmt(best.fastValue), fmt(best.value)))
    end
end

printTable("Over budget (would work if you could make more):", result.infeasible)
if result.infeasible[1] then
    for _, v in ipairs(result.infeasible[1].violations or {}) do
        print(string.format("   #1 %s: needs %.3f/s, budget %.3f/s", v.resource, v.used, v.budget))
    end
end

-- With several targets, no single configuration need serve them all -- say where
-- each one is cheapest on its own, so it is obvious when to split across modules.
if #result.targets > 1 then
    print("")
    print("Cheapest source of each, on its own:")
    for _, t in ipairs(result.targets) do
        local b = result.perMaterial[t.name]
        if b then
            print(string.format("  %-28s dist %d-%d  MK-%s  %-14s %s  %s/s",
                t.name, b.candidate.distance[1], b.candidate.distance[2],
                roman(b.candidate.drone), b.candidate.plasmaName:gsub(" Plasma", ""),
                b.candidate.moduleName, fmt(b.rate)))
        else
            print(string.format("  %-28s no feasible configuration", t.name))
        end
    end
end

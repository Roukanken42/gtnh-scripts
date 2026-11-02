-- Mining targeter -- finds the cheapest module configuration that serves a demand.
--
-- estimate.lua answers the forward question: given a configuration, what comes
-- out and what does it cost? This is the inverse. A mining module cannot be
-- aimed at a material the way a pump thread is aimed at a gas -- you set a
-- distance, a drone and a plasma, and the game rolls a weighted meteor out of
-- whatever pool that combination exposes -- so the configuration has to be
-- searched for.
--
-- This is the first stage of the controller loop and runs every cycle, so it has
-- to be quick. Three properties of the model make it so:
--
-- 1. THE POOL COLLAPSES TO A HANDFUL OF SUMS. meteors.mineTime multiplies every
--    meteor's own duration by the SAME factor g = max(1-tau, 0.5), which depends
--    only on the plasma. With b = min(lambda, 0.75) for the size bonus, the whole
--    chance-weighted pool reduces to
--
--      ST  = sum wi*Ti                    SK  = sum wi*pari
--      SAx = sum wi*pari*mini*fraci(X)    SBx = sum wi*pari*di*fraci(X)
--      SE  = sum wi*euti*pari*Ti          (di = maxi - mini)
--
--      items/s of X = 20*64 * (SAx + b*SBx) / (g*ST)
--      kits/s       = 20 * SK / (g*ST)
--
--    The pool-weight normaliser cancels out. Nothing in these sums depends on the
--    plasma, so one scan of a pool prices all five plasmas.
--
-- 2. EU/s IS INDEPENDENT OF PLASMA. EU/s = 20*SE/ST: the average
--    EU/t is time-weighted and g stretches every meteor's time alike, so it
--    cancels. Energy only ever bears on the distance/drone/module choice.
--
-- 3. DISTANCE IS A STEP FUNCTION. meteors.canFind tests range membership only, so
--    the pool changes only where some meteor's range starts or ends -- about 88
--    breakpoints, not 250 distances. Candidates report an interval; any distance
--    inside it behaves identically.
--
-- ---- scoring ---------------------------------------------------------------
-- Availability gates first (a drone tier whose kit material has no cost entry is
-- excluded outright -- Transcendent Metal by default), then budgets: a candidate
-- burning more ingots/s, L/s or EU/s than you can make is infeasible. Survivors
-- rank on cost/s divided by weighted items/s, i.e. points per weighted item.
-- Secondary targets enter through the denominator, so they pull the choice only
-- when their weighted rate outweighs the primary it costs. The weights are a
-- parameter: the controller derives them from stock deficits the way
-- pump/main.lua's computeNeedy does.

local meteors = require("lib.gtnh.meteors")
local plasmas = require("lib.gtnh.plasmas")
local drones = require("lib.gtnh.drones")
local estimate = require("lib.calc.estimate")

local target = {}

local TPS = estimate.TPS               -- 20 ticks per second
local STACK = meteors.STACK            -- 64 items per stack
local KIT_INGOTS = estimate.KIT.ingots -- 18 ingots per meteor

-- How many candidates a search keeps. Everything else is discarded as it is
-- scored, so memory stays flat however big the space is.
target.DEFAULT_LIMIT = 8

-- Cost weights in arbitrary POINTS, used only to order candidates against each
-- other -- they never need to be right in absolute terms, just roughly right
-- relative to one another. mining/config.lua carries the copy you tune; these are
-- the fallback when a caller passes none.
--
-- A material listed as `false`, or not listed at all, is treated as UNOBTAINABLE
-- and its drone tiers / plasmas are dropped from the search (reported in
-- `skipped`, so an incomplete table cannot silently price something as free).
target.DEFAULT_COST = {
    ingot = {              -- points per ingot; a kit is KIT_INGOTS of them
        ["Steel"] = 0.02, ["Titanium"] = 0.02, ["Tungstensteel"] = 0.02,
        ["Naquadah"] = 0.05, ["Naquadah Alloy"] = 0.1,
        ["Neutronium"] = 1,                 -- baseline
        ["Cosmic Neutronium"] = 10,         -- TUNE
        ["Infinity"] = 240,                 -- 24x cosmic (24 go into one)
        ["Transcendent Metal"] = false,     -- unobtainable
    },
    plasma = {             -- points per litre (mB), by plasma tier -- all TUNE
        [1] = 0.001, [2] = 0.004, [3] = 0.02, [4] = 0.1, [5] = 0.5,
    },
    eu = 1e-9,             -- points per EU: a tie-break, not a driver
}

-- ---- small helpers ---------------------------------------------------------

-- Keeps `list` sorted by `worse` and no longer than `maxLen`, discarding the
-- tail. Used instead of collecting every candidate: the search space is thousands
-- of entries and an OpenComputers machine has no memory to spare for them.
local function insertRanked(list, item, maxLen, worse)
    local i = #list + 1
    while i > 1 and worse(list[i - 1], item) do
        list[i] = list[i - 1]
        i = i - 1
    end
    if i <= maxLen then list[i] = item end
    for j = #list, maxLen + 1, -1 do list[j] = nil end
end

-- ---- static indexes --------------------------------------------------------

-- meteors.scale is trig-heavy and gets asked the same 44 x 13 questions over and
-- over during a search, so memoise it. `false` caches "this tier cannot mine it".
local scaleCache = {}

local function scaleOf(m, tier)
    local byTier = scaleCache[m]
    if not byTier then byTier = {}; scaleCache[m] = byTier end
    local s = byTier[tier]
    if s == nil then
        s = meteors.scale(m, tier) or false
        byTier[tier] = s
    end
    return s or nil
end

-- The distances worth testing: every point where some meteor's range begins or
-- ends. Between two of them the pool -- and therefore every number this module
-- computes -- is constant. Also returns the largest distance any meteor reaches.
local gridCache, gridMax

local function distanceGrid()
    if gridCache then return gridCache, gridMax end
    local seen, list, top = {}, {}, 0
    for _, m in ipairs(meteors.list) do
        local lo, hi = m.distance[1], m.distance[2]
        if hi > top then top = hi end
        for _, d in ipairs({ lo, hi + 1 }) do
            if d >= 1 and not seen[d] then seen[d] = true; list[#list + 1] = d end
        end
    end
    table.sort(list)
    gridCache, gridMax = list, top
    return list, top
end

-- Turns the caller's demand table into the internal target list. Accepts
--   { ["oreEndstoneIron"] = 3 }                       -- just a weight
--   { ["oreEndstoneIron"] = { rate = 50, weight = 3 } }
-- A name matches a yield entry by full oredict first, then by bare material name
-- ("Iron"). The bare form can span prefixes -- oreEndstonePlatinum and
-- dustPlatinum are NOT the same item -- so `oredicts` records everything a target
-- absorbed and `aggregated` flags when that is more than one.
-- Returns the target list, or nil + error.
local function resolveTargets(demand)
    if type(demand) ~= "table" then return nil, "demand must be a table" end

    local list = {}
    for name, spec in pairs(demand) do
        local weight, rate
        if type(spec) == "number" then
            weight, rate = spec, 0
        elseif type(spec) == "table" then
            weight, rate = spec.weight or 1, spec.rate or 0
        else
            return nil, "demand['" .. tostring(name) .. "'] must be a number or a table"
        end
        if weight <= 0 then return nil, "demand['" .. name .. "'] weight must be > 0" end
        list[#list + 1] = { name = name, weight = weight, rate = rate, oredicts = {}, share = {} }
    end
    if #list == 0 then return nil, "demand is empty" end
    -- pairs() order is arbitrary; keep the output stable.
    table.sort(list, function(a, b) return a.name < b.name end)

    for _, t in ipairs(list) do
        local names = {}
        for i, m in ipairs(meteors.list) do
            local frac, share, counted = meteors.fractions(m), 0, {}
            for _, y in ipairs(m.yield) do
                local key = meteors.oredict(m, y)
                if (key == t.name or y.mat == t.name) and not counted[key] then
                    counted[key] = true                 -- fractions() already merged dupes
                    share = share + frac[key]
                    if not names[key] then
                        names[key] = true
                        t.oredicts[#t.oredicts + 1] = key
                    end
                end
            end
            if share > 0 then t.share[i] = share end
        end
        table.sort(t.oredicts)
        t.aggregated = #t.oredicts > 1
        t.produced = next(t.share) ~= nil
    end

    return list
end

-- ---- pool sums -------------------------------------------------------------

-- Collapses the pool findable at (distance, droneTier, moduleTier) into the sums
-- the rest of the module works from. `parallels` is the module's ceiling; each
-- meteor gets as many as its own EU/t (against the module voltage) and the
-- available computation allow, exactly as estimate.lua does it. Meteors that
-- cannot manage even one parallel contribute nothing -- in game they stall the
-- module, which is estimate.lua's `blocked` and is reported there, not here.
-- Returns nil when the pool is empty.
local function poolSums(distance, droneTier, moduleTier, voltage, parallels, computation, targets)
    local ST, SE, SK, SAall, SBall = 0, 0, 0, 0, 0
    local SA, SB = {}, {}
    for t = 1, #targets do SA[t], SB[t] = 0, 0 end
    local count = 0

    for i, m in ipairs(meteors.list) do
        if meteors.canFind(m, distance, droneTier, moduleTier) then
            local s = scaleOf(m, droneTier)
            local par = parallels
            local byVoltage = math.floor(voltage / s.eut)
            if byVoltage < par then par = byVoltage end
            if computation then
                local byComp = math.floor(computation / m.computation)
                if byComp < par then par = byComp end
            end
            if par >= 1 then
                local w = m.weight
                local mn, span = s.size[1], s.size[2] - s.size[1]
                count = count + 1
                ST = ST + w * s.duration
                SE = SE + w * s.eut * par * s.duration
                SK = SK + w * par
                SAall = SAall + w * par * mn
                SBall = SBall + w * par * span
                for t = 1, #targets do
                    local f = targets[t].share[i]
                    if f then
                        SA[t] = SA[t] + w * par * mn * f
                        SB[t] = SB[t] + w * par * span * f
                    end
                end
            end
        end
    end

    if ST <= 0 then return nil end
    return { ST = ST, SE = SE, SK = SK, SAall = SAall, SBall = SBall, SA = SA, SB = SB, count = count }
end

-- True when two pools produce identical numbers, so their distance intervals can
-- be merged. Distinct pools agreeing on every one of these sums would be a
-- coincidence with no consequence -- the reported figures would match anyway.
local function sameSums(a, b)
    if a.ST ~= b.ST or a.SE ~= b.SE or a.SK ~= b.SK
        or a.SAall ~= b.SAall or a.SBall ~= b.SBall then return false end
    for t = 1, #a.SA do
        if a.SA[t] ~= b.SA[t] or a.SB[t] ~= b.SB[t] then return false end
    end
    return true
end

-- ---- the plasma factors ----------------------------------------------------
-- Size bonus and time factor of a plasma, straight from plasmas.lua's model.
local function bonusOf(p) return math.min(p.sizeMultiplier, 0.75) end
local function timeOf(p) return math.max(1 - p.timeDiscount, 0.5) end

-- ---- scoring one candidate -------------------------------------------------

-- Prices a pool at one plasma. Returns the candidate, or nil when it produces
-- nothing demanded.
local function evaluate(sums, targets, p, ctx)
    -- Weighted-value sums: what the score divides by.
    local SAv, SBv = 0, 0
    for t = 1, #targets do
        SAv = SAv + targets[t].weight * sums.SA[t]
        SBv = SBv + targets[t].weight * sums.SB[t]
    end
    if SAv <= 0 and SBv <= 0 then return nil end   -- pool yields nothing demanded

    local b, g = bonusOf(p), timeOf(p)
    local perSecond = TPS / (g * sums.ST)   -- turns a per-operation sum into a rate

    local rates, value, demanded, modulesNeeded = {}, 0, 0, 1
    for t = 1, #targets do
        local tt = targets[t]
        local r = perSecond * STACK * (sums.SA[t] + b * sums.SB[t])
        rates[tt.name] = r
        value = value + tt.weight * r
        demanded = demanded + r
        if tt.rate > 0 then
            local n = (r > 0) and math.ceil(tt.rate / r) or math.huge
            if n > modulesNeeded then modulesNeeded = n end
        end
    end
    if value <= 0 then return nil end

    local kits = perSecond * sums.SK
    local ingots = KIT_INGOTS * kits
    local litres = p.consumed * kits
    local eu = TPS * sums.SE / sums.ST      -- independent of plasma
    local stacks = perSecond * (sums.SAall + b * sums.SBall)

    local costPerSecond = ingots * ctx.ingotPoints + litres * ctx.plasmaPoints[p.tier]
        + eu * ctx.euPoints

    -- Budgets: what you can actually supply per second. Over any of them and the
    -- candidate is infeasible -- kept, but listed separately.
    local violations
    local budget = ctx.budget
    -- An absent cap means no limit. config.lua lists every material and plasma
    -- with a nil value, so the key is there to edit but says nothing until a
    -- number replaces it -- an untouched entry must not gate anything off.
    local function over(what, used, cap)
        if cap and used > cap then
            violations = violations or {}
            violations[#violations + 1] = { resource = what, used = used, budget = cap }
        end
    end
    over(ctx.kitMaterial, ingots, budget.ingots and budget.ingots[ctx.kitMaterial])
    over(p.name, litres, budget.plasma and budget.plasma[p.tier])
    over("EU", eu, budget.eu)

    return {
        distance = { ctx.distanceLo, ctx.distanceHi },
        drone = ctx.drone, droneName = ctx.droneName, kitMaterial = ctx.kitMaterial,
        plasma = p.tier, plasmaName = p.name,
        module = ctx.module, moduleName = ctx.moduleName, parallels = ctx.parallels,
        meteorsInPool = sums.count,

        rates = rates,
        value = value,
        stacksPerSecond = stacks,
        purity = (stacks > 0) and (demanded / (stacks * STACK)) or 0,
        modulesNeeded = modulesNeeded,

        cost = {
            total = costPerSecond,
            kits = kits, ingotsPerSecond = ingots, kitMaterial = ctx.kitMaterial,
            plasmaPerSecond = litres, euPerSecond = eu,
        },
        score = costPerSecond / value,

        feasible = violations == nil,
        violations = violations,
    }
end

-- ---- the search ------------------------------------------------------------

local function worseCandidate(a, b)
    if a.score ~= b.score then return a.score > b.score end
    -- Cost per item is identical across module tiers -- yield and every cost scale
    -- alike with parallels -- so break that tie on throughput: fewer modules to
    -- cover the demand, then the bigger module.
    if a.modulesNeeded ~= b.modulesNeeded then return a.modulesNeeded > b.modulesNeeded end
    if a.drone ~= b.drone then return a.drone > b.drone end          -- cheaper kits first
    if a.plasma ~= b.plasma then return a.plasma > b.plasma end
    if a.module ~= b.module then return a.module < b.module end
    return a.distance[1] > b.distance[1]
end

-- Offers a candidate to a ranked list. The same (distance interval, drone,
-- plasma) at another module tier is the SAME configuration scored on different
-- hardware -- it ties exactly -- so only the best of them earns a slot, and the
-- list stays a list of genuinely different options.
local function offer(list, cand, maxLen)
    for i, c in ipairs(list) do
        if c.drone == cand.drone and c.plasma == cand.plasma
            and c.distance[1] == cand.distance[1] then
            if not worseCandidate(c, cand) then return end
            table.remove(list, i)
            break
        end
    end
    insertRanked(list, cand, maxLen, worseCandidate)
end

-- Searches every (distance interval, drone, plasma, module) for the cheapest way
-- to serve `demand`.
--   demand = { [material] = weight } or { [material] = { rate = <items/s>, weight = <w> } }
--   opts = {
--     modules     = { 1, 2, 3 },   -- module tiers on hand (miners.discover())
--     cost        = target.DEFAULT_COST,
--     budget      = { ingots = { [material] = <per second> },
--                     plasma = { [tier] = <L per second> }, eu = <per second> },
--     computation = <n>,           -- computation on tap; caps parallels
--     parallels   = <n>,           -- what the module is SET to, if not its tier's
--                                  -- maximum. Clamped to the tier. Cost per item
--                                  -- barely moves -- yield and every cost scale
--                                  -- alike -- but the RATES scale with it, and a
--                                  -- caller sizing a fleet against a demanded rate
--                                  -- is asking about exactly those.
--     modules     = { <tier>, ... },  -- only these module tiers
--     drones      = <tier> | { <tier>, ... },   -- only these drone tiers
--     plasmas     = <tier> | { <tier>, ... },   -- only these plasmas
--     distance    = <n>,           -- only configurations that include it
--   -- The four above PIN part of the answer, for "what is best if I keep using
--   -- Radon at distance 40". A pin narrows the search rather than filtering its
--   -- output, so the candidates that come back are the best AMONG the allowed.
--     limit       = 8,             -- candidates to keep
--     onProgress  = function(scanned) end,   -- every 256 candidates; os.sleep(0)
--   }
-- Returns nil + error on bad input, otherwise:
--   { candidates,        -- feasible, cheapest first, each with .estimate attached
--     infeasible,        -- over budget, same shape, for "if only I had more X"
--     perMaterial,       -- material -> the candidate that serves it most cheaply
--     targets, skipped, scanned }
function target.search(demand, opts)
    opts = opts or {}
    local targets, err = resolveTargets(demand)
    if not targets then return nil, err end

    local cost = opts.cost or target.DEFAULT_COST
    local ingotCost = cost.ingot or {}
    local plasmaCost = cost.plasma or {}
    local euPoints = cost.eu or 0
    local budget = opts.budget or {}
    local limit = opts.limit or target.DEFAULT_LIMIT

    local skipped = {}

    -- Nothing to search for if no meteor drops what was asked for.
    local anyProduced = false
    for _, t in ipairs(targets) do
        if t.produced then anyProduced = true
        else skipped[#skipped + 1] = "no meteor yields '" .. t.name .. "'" end
    end
    if not anyProduced then
        return { candidates = {}, infeasible = {}, perMaterial = {},
                 targets = targets, skipped = skipped, scanned = 0 }
    end

    -- A pin, as a set of allowed tiers. A bare number is the common case.
    local function pinned(v)
        if v == nil then return nil end
        if type(v) == "number" then return { [v] = true } end
        local set = {}
        for _, tier in ipairs(v) do set[tier] = true end
        return next(set) and set or nil
    end
    local onlyDrones, onlyPlasmas = pinned(opts.drones), pinned(opts.plasmas)

    -- Usable plasmas: those you can actually make, minus anything pinned out.
    local usablePlasmas = {}
    for _, p in ipairs(plasmas.list) do
        if onlyPlasmas and not onlyPlasmas[p.tier] then
            -- deliberately excluded by the caller; not a shortage, so not reported
        elseif plasmaCost[p.tier] then usablePlasmas[#usablePlasmas + 1] = p
        else skipped[#skipped + 1] = p.name .. ": no cost entry, not searched" end
    end
    if #usablePlasmas == 0 and onlyPlasmas then
        return nil, "the pinned plasma has no cost entry, so nothing can be searched"
    end

    -- Usable drone tiers: those whose kit material you can actually make.
    local usableDrones = {}
    for tier = drones.MIN_TIER, drones.MAX_TIER do
        local d = drones.get(tier)
        local pts = ingotCost[d.material]
        if onlyDrones and not onlyDrones[tier] then
            -- likewise
        elseif pts then usableDrones[#usableDrones + 1] = { tier = tier, drone = d, points = pts }
        else skipped[#skipped + 1] = d.name .. " (" .. d.material .. "): unobtainable, not searched" end
    end
    if #usableDrones == 0 and onlyDrones then
        return nil, "the pinned drone's material is marked unobtainable in the cost table"
    end

    local moduleTiers = opts.modules
    if not moduleTiers then
        moduleTiers = {}
        for tier in pairs(estimate.MODULES) do moduleTiers[#moduleTiers + 1] = tier end
        table.sort(moduleTiers)
    end

    local grid, maxDistance = distanceGrid()
    local candidates, infeasible, perMaterial = {}, {}, {}
    local scanned = 0
    local ctx = { budget = budget, euPoints = euPoints, plasmaPoints = plasmaCost }

    for _, moduleTier in ipairs(moduleTiers) do
        local mod = estimate.MODULES[moduleTier]
        if mod then
            ctx.module, ctx.moduleName = moduleTier, mod.name
            -- A module held below its tier's maximum runs a proportionally smaller
            -- pool of parallels, and every rate reported here scales with it.
            local parallels = mod.parallels
            if opts.parallels then
                parallels = math.max(1, math.min(math.floor(opts.parallels), mod.parallels))
            end
            ctx.parallels = parallels

            for _, ud in ipairs(usableDrones) do
                ctx.drone, ctx.droneName = ud.tier, ud.drone.name
                ctx.kitMaterial, ctx.ingotPoints = ud.drone.material, ud.points

                -- Walk the distance breakpoints; where the pool is unchanged from
                -- the previous one, just widen that candidate's interval.
                local prevSums, prevCands = nil, nil
                for gi = 1, #grid do
                    local d = grid[gi]
                    local hi = grid[gi + 1] and (grid[gi + 1] - 1) or maxDistance
                    -- A pinned distance keeps only the interval containing it. The
                    -- pool is constant across an interval, so this is one cell, not
                    -- one distance -- and the candidate still reports the whole
                    -- range it is valid over.
                    if opts.distance and not (d <= opts.distance and opts.distance <= hi) then
                        d = nil
                    end
                    if d and d <= maxDistance then
                        local sums = poolSums(d, ud.tier, moduleTier, mod.voltage,
                            parallels, opts.computation, targets)

                        if sums and prevSums and sameSums(sums, prevSums) then
                            for _, c in ipairs(prevCands) do c.distance[2] = hi end
                        elseif sums then
                            ctx.distanceLo, ctx.distanceHi = d, hi
                            prevSums, prevCands = sums, {}
                            for _, p in ipairs(usablePlasmas) do
                                local c = evaluate(sums, targets, p, ctx)
                                scanned = scanned + 1
                                if c then
                                    prevCands[#prevCands + 1] = c
                                    if c.feasible then
                                        offer(candidates, c, limit)
                                        -- Cheapest source of each material on its own,
                                        -- for when no single config serves them all.
                                        for _, t in ipairs(targets) do
                                            local r = c.rates[t.name]
                                            if r and r > 0 then
                                                local s = c.cost.total / r
                                                local best = perMaterial[t.name]
                                                -- Module tiers tie exactly here too, so
                                                -- settle it on throughput like the main list.
                                                if not best or s < best.materialScore
                                                    or (s == best.materialScore and r > best.rate) then
                                                    perMaterial[t.name] =
                                                        { candidate = c, materialScore = s, rate = r }
                                                end
                                            end
                                        end
                                    else
                                        offer(infeasible, c, limit)
                                    end
                                end
                                if opts.onProgress and scanned % 256 == 0 then
                                    opts.onProgress(scanned)
                                end
                            end
                        else
                            prevSums, prevCands = nil, nil
                        end
                    end
                end
            end
        end
    end

    -- The fast path only decides the ORDER. Re-run the winners through the
    -- estimator so every number reported to a human comes from one place -- and so
    -- any drift between the two would show up immediately.
    for _, c in ipairs(candidates) do
        c.estimate = estimate.run{
            distance = c.distance[1], drone = c.drone, module = c.module,
            plasma = c.plasma, parallels = c.parallels,
            computation = opts.computation,
        }
    end

    return {
        candidates = candidates,
        infeasible = infeasible,
        perMaterial = perMaterial,
        targets = targets,
        skipped = skipped,
        scanned = scanned,
    }
end

-- Every material a meteor can yield, sorted. This is the set resolveTargets will
-- accept, so it lives beside it: a picker built from anywhere else could offer
-- something no meteor drops, and the search would come back empty with no hint as
-- to why. Names are the `mat` names, which is what the estimator reports too.
local materialCache

function target.materials()
    if materialCache then return materialCache end
    local seen = {}
    materialCache = {}
    for _, m in ipairs(meteors.list) do
        for _, y in ipairs(m.yield) do
            if y.mat and not seen[y.mat] then
                seen[y.mat] = true
                materialCache[#materialCache + 1] = y.mat
            end
        end
    end
    table.sort(materialCache)
    return materialCache
end

-- Exposed for tests and for callers that want the pieces without a whole search.
target.poolSums = poolSums
target.resolveTargets = resolveTargets
target.distanceGrid = distanceGrid

return target

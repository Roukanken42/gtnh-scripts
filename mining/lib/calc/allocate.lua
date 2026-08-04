-- Sharing a fleet out over a demand: which AUTO module runs which configuration.
--
-- target.lua answers "what is the best configuration for THIS demand" and it does
-- it well, but asking it once and giving every module the answer is the wrong shape
-- for a fleet. Ore purity is dreadful -- a material targeted alone is 1-2% of what
-- comes out -- so the good configurations are the ones that serve several wants at
-- once, and the best FLEET is frequently not several copies of the best module:
--
--   two modules aimed differently often serve more of the list than two modules
--   both aimed at all of it
--
-- Which is the whole problem this module exists to solve. It is a coverage
-- problem, not a ranking problem, and the thing that makes it one is that DEMAND
-- IS CAPPED. Once a want's rate is met, further production of it is worth nothing,
-- so the second module to choose finds the first one's materials already paid for
-- and is drawn towards whatever is still short. That single property -- capping
-- each want at its rate -- is what makes the fleet spread out on its own, with no
-- rule anywhere saying "diversify".
--
-- ---- the objective ----------------------------------------------------------
-- For a set of choices, the fleet produces `produced[t]` of each want, and
--
--   coverage = sum over wants of  weight[t] * min(need[t], produced[t])
--
-- is what is being maximised. Cost is the tie-break, and strictly that: coverage
-- is compared first and cost only settles allocations that cover the SAME amount.
--
-- Which is not a rare case to have thought about -- it is the important one. Once
-- the fleet saturates the demand, every remaining allocation covers exactly the
-- same total (each want is capped at its need, so the sums are identical to the
-- last bit), and cost is then the only thing left to choose on. That is where the
-- fleet settles onto the cheap end of what serves the list.
--
-- Weighing the two against each other instead -- coverage minus some multiple of
-- cost -- reads as more principled and is worse: any exchange rate small enough to
-- keep cost from buying out real coverage is also small enough to be lost in
-- rounding, and any rate big enough to matter will sooner or later refuse a genuine
-- improvement because it costs points. There is no good value, so there is no
-- multiplier.
--
-- ---- how it is searched -----------------------------------------------------
-- Coordinate ascent from the fleet as it stands. Every module starts at KEEP (what
-- it is running now, which already produces something and must therefore count),
-- and each sweep offers every module every candidate of its own tier, taking the
-- best one against what the others are doing. Sweeps run until nothing moves.
--
-- It is not exhaustive -- that would be candidates^modules -- but the objective
-- rises on every accepted step and each sweep is arithmetic over numbers the
-- search already computed, so it costs nothing next to the search itself. In
-- practice two sweeps settle it: the first hands out the broad configurations, the
-- second is where a module notices its neighbour has covered its materials and
-- moves to something narrower.
--
-- ---- and then hysteresis ----------------------------------------------------
-- Re-aiming a module is not free. TecTech only takes a parameter write while the
-- machine is STOPPED, so every change costs a mining operation, and a plasma
-- change drains a hatch. Meanwhile the demand table moves under the allocation
-- constantly -- stock is read every heavy cycle. So a module is only re-aimed when
-- the new choice beats what it already runs by `margin` (25% by default), and the
-- comparison is made against the FINAL allocation rather than in isolation. A
-- module with nothing to keep -- no drone, no estimate -- has nothing to protect
-- and is always set.
--
-- Pure: hand it candidates and rates, and it answers. Nothing here reads a
-- component or calls the searcher.

local allocate = {}

allocate.DEFAULTS = {
    -- How much better a choice has to be before a module is stopped to write it.
    margin = 0.25,
    -- Sweeps to run. Two settles the normal case; the third is insurance.
    passes = 3,
}

local function opt(opts, key)
    local v = opts and opts[key]
    if v == nil then return allocate.DEFAULTS[key] end
    return v
end

-- ---- coverage ---------------------------------------------------------------

-- Weighted demand served, capped per want. `produced` maps want name -> items/s.
--
-- The cap is unconditional, which also settles the degenerate case: a want asking
-- for nothing -- one that is currently satisfied, or was passed in without a rate
-- -- is worth nothing however much of it comes out. Nothing is owed, so nothing is
-- earned by serving it, and a module cannot win an allocation by flooding it.
function allocate.coverage(targets, produced)
    local total = 0
    for _, t in ipairs(targets or {}) do
        local made = produced[t.name] or 0
        local need = t.need or 0
        if made > need then made = need end
        total = total + (t.weight or 1) * made
    end
    return total
end

-- The most any allocation could ever cover: every want served in full.
function allocate.maxCoverage(targets)
    local total = 0
    for _, t in ipairs(targets or {}) do
        total = total + (t.weight or 1) * (t.need or 0)
    end
    return total
end

-- Per-want rates for a live configuration, read off an estimate.run result. The
-- candidates carry their own `rates` (keyed by demand name, straight from the
-- searcher); this is the same table for a module nobody searched for -- what it is
-- mining right now, which is what KEEP is worth.
function allocate.ratesFromEstimate(est, targets)
    local out = {}
    for _, t in ipairs(targets or {}) do out[t.name] = 0 end
    if type(est) ~= "table" then return out end
    for _, t in ipairs(targets or {}) do
        local keys, sum = t.keys, 0
        for _, y in ipairs(est.yield or {}) do
            local key = y.mat or y.oredict
            local hit = (key == t.name) or (y.oredict == t.name)
            if not hit and keys then hit = keys[key] or (y.oredict and keys[y.oredict]) end
            if hit then sum = sum + (y.itemsPerSecond or 0) end
        end
        out[t.name] = sum
    end
    return out
end

-- What a live configuration costs per second, in the same POINTS the searcher
-- scores candidates in, so KEEP and a candidate can be compared at all.
--
-- A material or plasma with no cost entry is priced at ZERO here rather than
-- excluded. In the search, no entry means "I cannot make this, do not offer it";
-- for something already running it can only mean "I have not said what it costs",
-- and refusing to price what the fleet is demonstrably burning would make KEEP
-- look free.
function allocate.costFromEstimate(est, cost)
    if type(est) ~= "table" then return 0 end
    cost = cost or {}
    local ingots = cost.ingot or {}
    local plasma = cost.plasma or {}
    local c = est.cost or {}
    local total = 0
    if c.kit then
        local pts = ingots[c.kit.material]
        if type(pts) == "number" then
            total = total + (c.kit.ingotsPerSecond or 0) * pts
        end
    end
    if c.plasma then
        local pts = plasma[c.plasma.tier]
        if type(pts) == "number" then
            total = total + (c.plasma.perSecond or 0) * pts
        end
    end
    if type(cost.eu) == "number" then
        total = total + (c.euPerSecond or 0) * cost.eu
    end
    return total
end

-- ---- what to choose from ----------------------------------------------------

-- The candidates an allocation should choose between, out of one target.search
-- result. NOT simply result.candidates, and the difference matters more than it
-- looks:
--
-- Those are ranked by cost per weighted item across the WHOLE demand, so one
-- prolific material can fill the entire list. Ask for Thaumium and Dilithium
-- together and every single one of the twelve best serves Thaumium -- its meteor is
-- three times the pool weight and its drones take cheap kits, while Dilithium needs
-- MK-X and up. A fleet allocated out of that list can never point anything at
-- Dilithium, however critical it gets, because nothing in the list produces any.
--
-- The searcher already computes the cheapest source of each material ON ITS OWN
-- (result.perMaterial) and says in its own comments that it is "for when no single
-- config serves them all". This is that case, and this is where it gets used: the
-- ranked list first -- those are the broad configurations, and they should win when
-- they can -- then one specialist per want, so every want has at least one way to
-- be served on the table.
--
-- Returns the pool, and how many specialists had to be added (which is worth
-- logging: it means the ranking was hiding something).
function allocate.poolFrom(result, targets)
    local pool, seen = {}, {}
    for _, c in ipairs((result and result.candidates) or {}) do
        if not seen[c] then seen[c] = true; pool[#pool + 1] = c end
    end
    local added = 0
    for _, t in ipairs(targets or {}) do
        local best = result and result.perMaterial and result.perMaterial[t.name]
        local c = best and best.candidate
        if c and not seen[c] then
            seen[c] = true
            pool[#pool + 1] = c
            added = added + 1
        end
    end
    return pool, added
end

-- ---- the allocation ---------------------------------------------------------

-- Adds every module's chosen rates together.
local function producedBy(modules, choice, targets)
    local out = {}
    for _, t in ipairs(targets) do out[t.name] = 0 end
    for i, m in ipairs(modules) do
        local rates
        local c = choice[i]
        if c then rates = c.rates else rates = m.current and m.current.rates end
        if rates then
            for _, t in ipairs(targets) do
                out[t.name] = out[t.name] + (rates[t.name] or 0)
            end
        end
    end
    return out
end

local function costOf(modules, choice)
    local total = 0
    for i, m in ipairs(modules) do
        local c = choice[i]
        if c then total = total + ((c.cost and c.cost.total) or 0)
        elseif m.current then total = total + (m.current.cost or 0) end
    end
    return total
end

-- Assigns configurations to modules.
--
--   modules  { { key, candidates = { <candidate>, ... },
--                current = { rates = { [want] = items/s }, cost = <points/s> } | nil,
--                size = <for ordering; bigger modules choose first> }, ... }
--            A candidate is a target.search result entry: it needs .rates and
--            .cost.total, and is handed back untouched.
--   targets  { { name, need = <items/s>, weight, keys }, ... }
--   opts     margin / passes / costTol
--
-- Returns:
--   { choices  = { { module, candidate | nil, action = "set" | "keep",
--                    coverage = <fleet coverage with it>, keepCoverage },
--                  ... }            -- one per module, in the order given
--     produced = { [want] = items/s }        -- the fleet as decided
--     served   = { [want] = 0..1 }           -- share of each want's rate covered
--     coverage, baseline, cost, maxCoverage, passes, changes }
function allocate.plan(modules, targets, opts)
    modules = modules or {}
    targets = targets or {}

    local maxCov = allocate.maxCoverage(targets)
    local margin = opt(opts, "margin")

    local choice = {}          -- module index -> candidate, or nil for KEEP
    local baseline = allocate.coverage(targets, producedBy(modules, choice, targets))

    local function score()
        return allocate.coverage(targets, producedBy(modules, choice, targets)),
               costOf(modules, choice)
    end

    -- Coverage differences this small are floating-point noise rather than a
    -- decision, so they count as equal and cost settles it. Scaled by the demand,
    -- since coverage is measured in weighted items a second and its magnitude is
    -- whatever the wants happen to be.
    local eps = 1e-9 * math.max(1, maxCov)

    local function better(cov, cost, bestCov, bestCost)
        if cov > bestCov + eps then return true end
        if bestCov > cov + eps then return false end
        return cost < bestCost
    end

    -- Bigger modules first: they have the most parallels and so the most influence
    -- on what is left for everyone else. Only the ORDER of the sweep, not the
    -- result's order, which stays the caller's.
    local order = {}
    for i = 1, #modules do order[i] = i end
    table.sort(order, function(a, b)
        local sa, sb = modules[a].size or 0, modules[b].size or 0
        if sa ~= sb then return sa > sb end
        return tostring(modules[a].key) < tostring(modules[b].key)
    end)

    local passes, changes = 0, 0
    for _ = 1, math.max(1, opt(opts, "passes")) do
        passes = passes + 1
        local moved = false
        for _, i in ipairs(order) do
            local m = modules[i]
            local was = choice[i]
            local best, bestCov, bestCost = was, score()

            local function offer(c)
                choice[i] = c
                local cov, cost = score()
                if better(cov, cost, bestCov, bestCost) then
                    best, bestCov, bestCost = c, cov, cost
                end
            end

            for _, c in ipairs(m.candidates or {}) do
                if c ~= was then offer(c) end
            end
            -- KEEP is always on the table, including as a way back.
            if was ~= nil then offer(nil) end

            choice[i] = best
            if best ~= was then
                moved = true
                changes = changes + 1
            end
        end
        if not moved then break end
    end

    -- ---- hysteresis: is the change worth stopping the module for? ----
    --
    -- The margin is applied to what THIS MODULE contributes, not to the fleet's
    -- total. That is the whole difficulty of the test: measured against the total, a
    -- module's contribution is one N-th of it, so on a fleet of ten a re-aim would
    -- have to add a quarter of everything the fleet does before it was allowed -- and
    -- nothing ever would. Automatic mode would look inert, and worse, would look
    -- inert only once the fleet was big enough to matter.
    --
    -- So the comparison is between two marginal contributions: what the module is
    -- worth now, and what it would be worth configured differently, both measured
    -- against the same fleet without it. That is scale-free -- "a quarter better than
    -- what this module is doing" means the same thing on a fleet of two and of ten.
    --
    -- Done in sweep order and recomputing as it goes, so a module that gives its
    -- change up hands its coverage back to the ones after it rather than leaving them
    -- deciding against a fleet that never happened.
    local decided = {}
    for _, i in ipairs(order) do
        local m = modules[i]
        local c = choice[i]
        if c and m.current then
            local others = {}
            for j, cj in pairs(choice) do others[j] = cj end
            -- The fleet WITHOUT this module at all: the baseline both options are
            -- measured from. Reached by giving it a candidate that produces nothing,
            -- since a nil choice means "keep", which is one of the things being
            -- measured.
            others[i] = { rates = {}, cost = { total = 0 } }
            local without = allocate.coverage(targets, producedBy(modules, others, targets))
            -- What it is worth as it stands...
            others[i] = nil
            local keepCov = allocate.coverage(targets, producedBy(modules, others, targets))
            -- ...against what it would be worth changed.
            others[i] = c
            local setCov = allocate.coverage(targets, producedBy(modules, others, targets))

            local keepGain, setGain = keepCov - without, setCov - without
            if setGain <= keepGain * (1 + margin) then
                choice[i] = nil          -- not worth an operation
                c = nil
            end
            decided[i] = { keepCoverage = keepCov, coverage = setCov,
                           keepGain = keepGain, gain = setGain }
        end
    end

    local produced = producedBy(modules, choice, targets)
    local served = {}
    for _, t in ipairs(targets) do
        local need = t.need or 0
        served[t.name] = (need > 0)
            and math.min(1, (produced[t.name] or 0) / need)
            or ((produced[t.name] or 0) > 0 and 1 or 0)
    end

    local choices = {}
    for i, m in ipairs(modules) do
        local d = decided[i] or {}
        choices[i] = {
            module = m,
            candidate = choice[i],
            action = choice[i] and "set" or "keep",
            coverage = d.coverage,
            keepCoverage = d.keepCoverage,
            -- What the module is worth now against what the change would be worth,
            -- both marginal. The pair the margin was applied to.
            keepGain = d.keepGain,
            gain = d.gain,
        }
    end

    return {
        choices = choices,
        produced = produced,
        served = served,
        coverage = allocate.coverage(targets, produced),
        baseline = baseline,
        maxCoverage = maxCov,
        cost = costOf(modules, choice),
        passes = passes,
        changes = changes,
    }
end

return allocate

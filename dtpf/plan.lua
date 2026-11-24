-- What the controller decides, as pure Lua: no component is touched here, so
-- it runs in any Lua 5.3 interpreter (see tools/test-dtpf.lua).
--
--   plan.prepare(snapshot)          normalise stack names once per read
--   plan.find(stacks, mats, spec)   how much of an ingredient there is
--   plan.check(variant, ctx)        can the array run this variant right now?
--   plan.demand(...)                how much of each product is wanted, counting
--                                   what the products downstream will consume
--   plan.choose(...)                which product the array should make next
--
-- The scheme, in short: every product has a target stock on the main net and
-- a priority. A product that another one is made from inherits the shortfall
-- of that other product as extra demand (MRP-style), so an intermediate is
-- pulled up before the thing made from it runs dry.
--
-- Demand keeps the priority of whoever wants it. A product's demand is a
-- stack of layers: its own target at its own priority, plus one layer per
-- priority inherited from downstream. Stock covers the layers highest
-- priority first. The array makes the RUNNABLE product with the most urgent
-- uncovered layer: highest priority first, then the lowest fill within that
-- layer. With all priorities equal this is simply the lowest stock /
-- effective target. Once every layer is covered, the lowest overall fill
-- wins (overproduction, spread by target).
--
-- Runnable means the stocker holds the inputs and the main net the catalyst;
-- a product whose inputs are missing is skipped, which is what makes the
-- upstream product (short, by the inheritance above) win.

local plan = {}

local SECTION = "\194\167"  -- the Minecraft colour-code character, UTF-8

-- Lower case, letters and digits only, a leading "molten" dropped.
function plan.norm(s)
    s = tostring(s or ""):lower():gsub(SECTION .. ".", ""):gsub("[^%w]", "")
    return (s:gsub("^molten", ""))
end

-- Material table: the game's (recipes.lua), plus the keys config.lua adds.
function plan.materials(base, extra)
    local mats = {}
    for id, m in pairs(base) do
        local keys = {}
        for _, k in ipairs(m.keys) do keys[plan.norm(k)] = true end
        local add = extra and extra[id]
        if add then
            for _, k in ipairs(add.keys or add) do keys[plan.norm(k)] = true end
        end
        mats[id] = { kind = m.kind, keys = keys }
    end
    return mats
end

-- Adds the normalised name and label to every stack of a snapshot
-- { items = {...}, fluids = {...} }. Returns the snapshot.
function plan.prepare(snap)
    for _, list in pairs(snap) do
        for _, s in ipairs(list) do
            s.nname, s.nlabel = plan.norm(s.name), plan.norm(s.label)
        end
    end
    return snap
end

local function matches(m, s)
    return m.keys[s.nname] == true or m.keys[s.nlabel] == true
end

-- Total amount of `spec` ({ mat, damage? }) in a prepared snapshot, and the
-- first matching stack (whose identity goes into the storage bus filter).
function plan.find(snap, mats, spec)
    local m = mats[spec.mat]
    if not m then return 0, nil end
    local list = (m.kind == "fluid" and snap.fluids or snap.items) or {}
    local total, first = 0, nil
    for _, s in ipairs(list) do
        if matches(m, s) and (spec.damage == nil or s.damage == spec.damage) then
            total = total + (s.amount or s.size or 0)
            first = first or s
        end
    end
    return total, first
end

-- The gates that do not depend on stock: disabled, catalyst not allowed, coil
-- heat, power. Returns nil when the variant passes, else why not.
function plan.gate(v, ctx)
    if ctx.disabled[v.id] then return "disabled in config" end
    if v.catalyst and not ctx.allowedCat[v.catalyst] then return v.catalyst .. " catalyst not allowed" end
    if (ctx.heat or 0) < v.heat then return string.format("needs %d K coils", v.heat) end
    if ctx.maxEUt and v.eut > ctx.maxEUt then return "needs more than cfg.maxEUt" end
    return nil
end

-- The catalyst one batch of `v` takes from the main net right now: the
-- recipe amount, plus what Convergence adds for perfect overclocks, times the
-- running-time discount. 0 for a recipe without catalyst.
function plan.catalystNeed(v, ctx)
    if not v.catalyst then return 0 end
    return math.ceil((v.catalystAmount + (ctx.catExtra or 0)) * (ctx.catFactor or 1))
end

-- The order a variant's inputs go into the filters: what is consumed first,
-- then what is not (circuits, Hypervisor Matrix, HiC). Recipes that share
-- everything else are told apart by their circuit, so it goes in last: after
-- the catalyst and every other input. plan.transition checks the rest.
function plan.writeOrder(v)
    local out = {}
    for _, inp in ipairs(v.inputs) do if inp.amount > 0 then out[#out + 1] = inp end end
    for _, inp in ipairs(v.inputs) do if inp.amount == 0 then out[#out + 1] = inp end end
    return out
end

-- Can the array run variant `v` right now?
-- ctx: mats, stock (prepared stocker snapshot), heat, maxEUt, catalysts
--      ({ key = L usable, reserve already taken off }), catFactor, catExtra,
--      allowedCat (set), disabled (set), minBatches
-- Returns { variant, ok, why, batches, items, fluids, catalyst, catalystNeed }.
-- items/fluids are the stacks to put into the storage bus filters.
function plan.check(v, ctx)
    local r = { variant = v, items = {}, fluids = {}, batches = 0 }
    r.why = plan.gate(v, ctx)
    if r.why then r.static = true; return r end

    -- Every problem is collected, not just the first, so the explanation of
    -- a product that cannot run is complete.
    -- In write order, so r.items and r.fluids are written in that order too.
    local batches, missing = math.huge, {}
    local seen = {}
    for _, inp in ipairs(plan.writeOrder(v)) do
        local have, stack = plan.find(ctx.stock, ctx.mats, inp)
        local need = inp.amount == 0 and 1 or inp.amount
        if inp.amount > 0 then batches = math.min(batches, math.floor(have / inp.amount)) end
        if have < need then
            missing[#missing + 1] = inp.mat .. (inp.damage and (" " .. inp.damage) or "")
                .. (inp.amount > 1 and have > 0 and string.format(" (%d of %d)", have, inp.amount) or "")
        end
        if stack then
            local id = (stack.name or "?") .. ":" .. tostring(stack.damage or "")
            if not seen[id] then
                seen[id] = true
                local list = ctx.mats[inp.mat].kind == "fluid" and r.fluids or r.items
                list[#list + 1] = stack
            end
        end
    end

    local problems, catShort = {}, false
    if #missing > 0 then problems[1] = "stocker has no " .. table.concat(missing, ", ") end
    if v.catalyst then
        local need = plan.catalystNeed(v, ctx)
        local have = ctx.catalysts[v.catalyst] or 0
        r.catalyst, r.catalystNeed = v.catalyst, need
        if need > 0 then batches = math.min(batches, math.floor(have / need)) end
        if have < need then
            catShort = true
            problems[#problems + 1] = string.format("main net has %d of %d L %s catalyst (after reserve)",
                math.floor(have), need, v.catalyst)
        end
    end
    r.batches = batches == math.huge and 0 or batches
    if #problems == 0 and r.batches < (ctx.minBatches or 1) then
        problems[1] = string.format("stocker holds %d batch(es), cfg.minBatches is %d", r.batches, ctx.minBatches)
    end
    -- How far from runnable: one per missing input, one for the catalyst.
    r.distance = #missing + (catShort and 1 or 0)
    r.why = #problems > 0 and table.concat(problems, "; ") or nil
    r.ok = r.why == nil
    return r
end

-- All variants of a product, checked. Returns
--   runnable  the first runnable check, or nil
--   planned   the variant demand is planned with: the best one that passes
--             the static gates, runnable or not (extras only if nothing else)
--   explain   when nothing runs, the check that best says why: the variant
--             closest to runnable, never an optional extra (combs) unless
--             there is nothing else. nil when no variant passes the gates.
--   checks    every variant's check, in order
function plan.product(variants, ctx)
    local runnable, planned, plannedExtra, explain, explainExtra
    local checks = {}
    for _, v in ipairs(variants or {}) do
        local r = plan.check(v, ctx)
        checks[#checks + 1] = r
        if r.ok and not runnable then runnable = r end
        if not r.static then
            if v.extra then
                plannedExtra = plannedExtra or v
                if not explainExtra or r.distance < explainExtra.distance then explainExtra = r end
            else
                planned = planned or v
                if not explain or r.distance < explain.distance then explain = r end
            end
        end
    end
    return runnable, planned or plannedExtra, explain or explainExtra, checks
end

-- ---- switching safety ---------------------------------------------------------------
-- A storage bus filter is written one slot per call, and the DTPFs may look
-- for a recipe between any two calls. So a switch passes through a series of
-- filter states, and in none of them may the exposed inputs + catalyst
-- complete a recipe other than the one running before or the one wanted
-- after: inf_t5 (circuit 4 + stellar) when inf_t3.5 is wanted, or the in-game
-- Awakened-coil recipe (circuit 4 + resplendent, R.hazards).
--
-- An exposure is { items = {spec...}, fluids = {spec...}, cats = {key=true} }:
-- the inputs in the slots of the item and fluid buses, slot 1 up, and the
-- catalysts that may be on the catalyst bus.

local function catSet(cat) return cat and { [cat] = true } or {} end

-- What the filters expose when they hold variant `v` (nil: blocked) in write
-- order, with catalyst `cat` (nil: none known).
function plan.exposure(v, mats, cat)
    local e = { items = {}, fluids = {}, cats = catSet(cat) }
    local seen = {}
    for _, inp in ipairs(v and plan.writeOrder(v) or {}) do
        local id = inp.mat .. ":" .. tostring(inp.damage)
        if not seen[id] then
            seen[id] = true
            local list = mats[inp.mat].kind == "fluid" and e.fluids or e.items
            list[#list + 1] = { mat = inp.mat, damage = inp.damage }
        end
    end
    return e
end

local function slice(list, a, b)
    local t = {}
    for i = a, b do t[#t + 1] = list[i] end
    return t
end

local function union(a, b)
    local t = {}
    for k in pairs(a) do t[k] = true end
    for k in pairs(b) do t[k] = true end
    return t
end

-- Every filter state on the way from exposure `from` to exposure `to`, in the
-- order apply() in main.lua writes: with `ingChanged`, block the item bus slot
-- by slot from slot 1, then the fluid bus; with `catChanged`, swap the
-- catalyst (both may be on the bus while its other slots are cleared); with
-- `ingChanged`, fill the item bus slot 1 up, then the fluid bus. `to.cats`
-- empty means the catalyst is left as it is. Returns the states and the
-- exposure at the end.
function plan.transition(from, to, ingChanged, catChanged)
    local states = {}
    local items, fluids, cats = from.items, from.fluids, from.cats
    local function add() states[#states + 1] = { items = items, fluids = fluids, cats = cats } end
    if ingChanged then
        for k = 1, #from.items do items = slice(from.items, k + 1, #from.items); add() end
        for k = 1, #from.fluids do fluids = slice(from.fluids, k + 1, #from.fluids); add() end
        items, fluids = {}, {}
    end
    if catChanged then
        cats = union(cats, to.cats); add()
        cats = to.cats; add()
    end
    if ingChanged then
        for k = 1, #to.items do items = slice(to.items, 1, k); add() end
        for k = 1, #to.fluids do fluids = slice(to.fluids, 1, k); add() end
    end
    return states, { items = items, fluids = fluids, cats = cats }
end

local function exposes(state, spec)
    for _, list in ipairs({ state.items, state.fluids }) do
        for _, s in ipairs(list) do
            if s.mat == spec.mat and (spec.damage == nil or s.damage == spec.damage) then return true end
        end
    end
    return false
end

-- Could recipe `r` start in filter state `state`? By presence only, never by
-- amount: an amount can change at any time, so this errs on the safe side.
function plan.completes(state, r)
    if r.catalyst and not state.cats[r.catalyst] then return false end
    for _, inp in ipairs(r.inputs) do
        if not exposes(state, inp) then return false end
    end
    return true
end

-- The first state in which a recipe of `recipes` (R.all) that is not in
-- `allowed` (a set of variant tables) could start. Returns that recipe and the
-- state, or nil when the switch is safe.
function plan.hazard(states, recipes, allowed)
    for _, st in ipairs(states) do
        for _, r in ipairs(recipes) do
            if not allowed[r] and plan.completes(st, r) then return r, st end
        end
    end
    return nil
end

-- A filter state as text, for the log.
function plan.describeState(st)
    local l = {}
    for _, list in ipairs({ st.items, st.fluids }) do
        for _, s in ipairs(list) do l[#l + 1] = s.mat .. (s.damage and (" " .. s.damage) or "") end
    end
    local c = {}
    for k in pairs(st.cats) do c[#c + 1] = k end
    table.sort(c)
    return (#l > 0 and table.concat(l, ", ") or "nothing") .. " + " .. (#c > 0 and table.concat(c, "/") or "no catalyst")
end

-- How much of `p` one batch of `v` makes, net of what it eats of itself.
local function netOutput(v, p)
    local out = v.outputs[p] or 0
    for _, inp in ipairs(v.inputs) do
        if inp.mat == p then out = out - inp.amount end
    end
    return out
end

-- Products ordered so that every product comes before the products it is made
-- from (by the planned variants). Ties keep the given order; a cycle, which
-- the game's recipes do not have, falls back to that order too.
function plan.topo(products, planned)
    local isProduct = {}
    for _, p in ipairs(products) do isProduct[p] = true end
    local consumers = {}   -- [q] = number of products made from q not yet placed
    for _, p in ipairs(products) do consumers[p] = 0 end
    local uses = {}        -- [p] = { q, ... } products p is made from
    for _, p in ipairs(products) do
        uses[p] = {}
        local v = planned[p]
        for _, inp in ipairs(v and v.inputs or {}) do
            if isProduct[inp.mat] and inp.mat ~= p then
                uses[p][#uses[p] + 1] = inp.mat
                consumers[inp.mat] = consumers[inp.mat] + 1
            end
        end
    end
    local order, placed = {}, {}
    local progress = true
    while progress do
        progress = false
        for _, p in ipairs(products) do
            if not placed[p] and consumers[p] == 0 then
                placed[p] = true
                order[#order + 1] = p
                for _, q in ipairs(uses[p]) do consumers[q] = consumers[q] - 1 end
                progress = true
            end
        end
    end
    for _, p in ipairs(products) do
        if not placed[p] then order[#order + 1] = p end
    end
    return order
end

-- Effective targets, priority layers and fills.
--   products  product names, config order
--   targets   [p] = { target = L, max = L or nil, priority = n (default 1) }
--   stockOf   [p] = L on the main net
--   planned   [p] = variant to model p with (nil: p cannot be made)
-- Returns [p] = { stock, target, priority, downstream, effective, short, fill,
--   capped, layers, level, levelFill }:
--   downstream  what the shortfalls of the products made from p will eat of it
--   layers      { {priority, amount, covered}, ... } highest priority first
--   level       priority of the most urgent uncovered layer (nil: all covered)
--   levelFill   how much of that layer the stock covers, 0..1
function plan.demand(products, targets, stockOf, planned)
    local down = {}   -- [q][priority] = L the shortfalls downstream need of q
    for _, p in ipairs(products) do down[p] = {} end
    local out = {}
    for _, p in ipairs(plan.topo(products, planned)) do
        local t = targets[p] or {}
        local target, prio = t.target or 0, t.priority or 1

        -- The layers: own target at own priority, plus what was inherited.
        local byPrio = {}
        if target > 0 then byPrio[prio] = target end
        local downstream = 0
        for pr, amount in pairs(down[p]) do
            byPrio[pr] = (byPrio[pr] or 0) + amount
            downstream = downstream + amount
        end
        local layers = {}
        for pr, amount in pairs(byPrio) do
            if amount > 0 then layers[#layers + 1] = { priority = pr, amount = amount } end
        end
        table.sort(layers, function(a, b) return a.priority > b.priority end)

        -- Stock covers the most important layers first; whatever a layer is
        -- short of flows on to p's inputs at that layer's priority.
        local stock = stockOf[p] or 0
        local left, eff, short, level, levelFill = stock, 0, 0, nil, nil
        local v = planned[p]
        local net = v and netOutput(v, p) or 0
        for _, l in ipairs(layers) do
            l.covered = math.min(left, l.amount)
            left = left - l.covered
            eff = eff + l.amount
            local miss = l.amount - l.covered
            if miss > 0 then
                short = short + miss
                if not level then level, levelFill = l.priority, l.covered / l.amount end
                if net > 0 then
                    local batches = miss / net
                    for _, inp in ipairs(v.inputs) do
                        local d = down[inp.mat]
                        if d and inp.mat ~= p then
                            d[l.priority] = (d[l.priority] or 0) + batches * inp.amount
                        end
                    end
                end
            end
        end

        out[p] = {
            stock = stock, target = target, priority = prio, downstream = downstream, effective = eff,
            short = short, fill = eff > 0 and stock / eff or math.huge,
            capped = t.max ~= nil and stock >= t.max,
            layers = layers, level = level, levelFill = levelFill,
        }
    end
    return out
end

-- Is candidate a more urgent than b? An uncovered layer beats none; a higher
-- priority layer beats a lower one; then the lower fill in that layer wins.
-- Fully covered products compare on their overall fill.
local function urgency(c)
    if c.level then return 1, c.level, c.levelFill end
    return 0, 0, c.fill
end

local function moreUrgent(a, b, margin)
    local ua, pa, fa = urgency(a)
    local ub, pb, fb = urgency(b)
    if ua ~= ub then return ua > ub end
    if pa ~= pb then return pa > pb end
    return fa < fb - (margin or 0)
end
plan.moreUrgent = moreUrgent

-- Why a candidate was picked, for the log.
local function reason(c)
    if c.level then
        return string.format("priority %d demand %d%% covered", c.level, math.floor(c.levelFill * 100 + 0.5))
    end
    return "every target met; lowest fill"
end

-- Picks the product to make.
--   prev      { product, since } or nil: what is selected now
--   cands     [p] = { ok, fill, level, levelFill, capped } (ok = has a
--             runnable variant; the rest from plan.demand)
--   products  config order, the tie-break
--   sel       cfg.selection: minDwell (s), switchMargin, keepBusy; plus pin
--   now       seconds
-- Returns the product name (or nil) and why.
function plan.choose(prev, cands, products, sel, now)
    if sel.pin then
        local c = cands[sel.pin]
        if c and c.ok then return sel.pin, "pinned by hand" end
    end

    local function best(allowCapped)
        local pick
        for _, p in ipairs(products) do
            local c = cands[p]
            if c and c.ok and (allowCapped or not c.capped) and (not pick or moreUrgent(c, cands[pick])) then
                pick = p
            end
        end
        return pick
    end
    local pick = best(false)
    local why = pick and reason(cands[pick])
    if not pick and sel.keepBusy then
        pick, why = best(true), "every product is at its max; keeping the array busy"
    end
    if not pick then return nil, "nothing is runnable" end

    -- Hysteresis: stay on a product that is still runnable for at least
    -- minDwell, and after that until another one is more urgent: a higher
    -- priority, or the same priority and a fill lower by switchMargin.
    local cur = prev and prev.product
    local c = cur and cands[cur]
    if cur and cur ~= pick and c and c.ok and (not c.capped or cands[pick].capped) then
        if now - prev.since < (sel.minDwell or 0) then return cur, "staying (min dwell)" end
        if not moreUrgent(cands[pick], c, sel.switchMargin) then return cur, "staying (within margin)" end
    end
    return pick, why
end

return plan

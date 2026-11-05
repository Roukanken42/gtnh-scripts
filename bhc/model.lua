-- The Black Hole Compressor, as far as the script can know it, plus the policy
-- that decides what to do about it. Pure Lua: no component is touched here, so
-- this file loads in any interpreter and can be exercised off-machine.
--
-- What the machine does (GT5-Unofficial, MTEBlackHoleCompressor), once a second
-- while a hole is open -- the same tick the Utility Hatch pulses:
--   * if stability > 0 and a spacetime hatch can give cost L: drain cost L,
--     stability unchanged; after every 30 drains the cost doubles. The cost and
--     the drain counter only reset when the hole closes.
--   * otherwise stability -= 1.
--   * stability <= 0: unstable, every running recipe's output is voided, and
--     spacetime can no longer stop the decay.
--   * stability <= -900 (15 min after hitting 0): the hole closes by itself.
-- Parallels: x2 below 50 stability, x4 below 20.
-- Seed and Collapser are taken from the input bus only at a recipe check (the
-- machine idle and allowed to work). A seed taken while a hole is open, or a
-- collapser taken while none is, is consumed for nothing.
-- The machine's stability is not readable over OpenComputers, so it is modelled
-- here from the hatch pulses and the hatch state the script itself set. The
-- spacetime hatch is an ME stocking input hatch switched by redstone: disabled,
-- it refuses every drain; enabled, a drain pulls exactly the cost from ME and
-- nothing is buffered. So "enabled at the drain tick, with the cost available"
-- is exactly "held". The tank is NOT used to count drains: a stock replenisher
-- refills it mid-hole. It is only read for how much spacetime there is.

local model = {}

model.START = 100
model.DOUBLE_EVERY = 30
model.CLOSE_AT = -900
model.COST_CAP = 2 ^ 30  -- the machine stops doubling past ~1e9

-- Parallel multiplier for a stability value (strict comparisons, as the machine).
function model.multiplier(S)
    if S == nil then return nil end
    if S < 20 then return 4 end
    if S < 50 then return 2 end
    return 1
end

function model.new()
    return {
        hole = "closed",   -- closed | open | unstable | unknown
        S = model.START,   -- stability (nil while unknown)
        counter = 0,       -- drains since the cost last doubled
        costMod = 1,       -- L per second to hold the hole
        held = 0,          -- seconds held by the hold stages, this hole
        vpHeld = 0,        -- seconds held by void protection, this hole
        stageHeld = {},    -- seconds held per hold stage, this hole
        spent = 0,         -- spacetime drained this hole (L)
        pulses = 0,        -- pulses seen this hole
        vp = false,        -- void protection engaged
        pending = nil,     -- { kind = "seed"|"collapser", since = t }
        fault = nil,       -- string: automation halted until restart
    }
end

local function resetHole(st)
    st.S = model.START
    st.counter, st.costMod = 0, 1
    st.held, st.stageHeld, st.spent, st.pulses = 0, {}, 0, 0
    st.vp, st.vpHeld, st.stage = false, 0, nil
end

-- A pulse arrived while we believed the hole closed: a seed was taken.
function model.open(st)
    resetHole(st)
    st.hole = "open"
end

function model.close(st)
    resetHole(st)
    st.hole = "closed"
end

-- One machine second. `fed`: the spacetime hatch was enabled, with the cost
-- available, for the drain that just happened. main.lua only passes true when
-- it is sure; any doubt counts as a decay, which reads stability LOWER than it
-- is -- the safe side.
-- Returns "drained", "decayed" or "closed".
function model.step(st, fed)
    st.pulses = st.pulses + 1
    local cost = st.costMod
    local stable = st.S ~= nil and st.S > 0
    local drained = stable and fed

    if st.S == nil then return "decayed" end  -- unknown: only counting pulses

    if drained then
        st.spent = st.spent + cost
        if st.vp then
            st.vpHeld = st.vpHeld + 1   -- void protection does not eat the hold limits
        else
            st.held = st.held + 1
            if st.stage then st.stageHeld[st.stage] = (st.stageHeld[st.stage] or 0) + 1 end
        end
        st.counter = st.counter + 1
        if st.counter >= model.DOUBLE_EVERY then
            if st.costMod <= model.COST_CAP then st.costMod = st.costMod * 2 end
            st.counter = 0
        end
    else
        st.S = st.S - 1
    end
    if st.S <= 0 then st.hole = "unstable" end
    if st.S <= model.CLOSE_AT then
        model.close(st)
        return "closed"
    end
    return drained and "drained" or "decayed"
end

-- Total L to hold for the next `n` seconds, from the current cost state.
function model.holdCost(st, n)
    local c, m, total = st.counter, st.costMod, 0
    for _ = 1, n do
        total = total + m
        c = c + 1
        if c >= model.DOUBLE_EVERY then m, c = m * 2, 0 end
    end
    return total
end

-- How many seconds can be held from now on: stops at `maxSeconds`, when the
-- per-second cost would exceed `maxCost`, or when `budget` L runs out.
function model.holdable(st, budget, maxCost, maxSeconds)
    local c, m, total, n = st.counter, st.costMod, 0, 0
    while n < maxSeconds and m <= maxCost and total + m <= budget and n < 36000 do
        total = total + m
        n = n + 1
        c = c + 1
        if c >= model.DOUBLE_EVERY then m, c = m * 2, 0 end
    end
    return n
end

-- Spacetime a fresh hole's whole hold plan costs, under the hold limits.
-- math.huge when the limits do not bound it.
function model.planCost(cfg)
    local hold = cfg.hold
    if not hold.enabled then return 0 end
    local secs = 0
    for _, s in ipairs(hold.stages or {}) do secs = secs + (s.seconds or math.huge) end
    secs = math.min(secs, hold.maxSeconds or math.huge)
    local fresh = model.new()
    local n = model.holdable(fresh, hold.maxSpend or math.huge, hold.maxCost or math.huge, secs)
    if n >= 36000 then return math.huge end
    return model.holdCost(fresh, n)
end

-- Hold stages, sorted from the highest stability down.
local function stagesOf(cfg)
    local list = {}
    for i, s in ipairs(cfg.hold.stages or {}) do
        list[#list + 1] = { index = i, at = s.at, seconds = s.seconds or math.huge }
    end
    table.sort(list, function(a, b) return a.at > b.at end)
    return list
end

-- The stage that applies at stability S: the lowest `at` that is still >= S.
local function currentStage(stages, S)
    local cur
    for _, s in ipairs(stages) do
        if S <= s.at then cur = s end
    end
    return cur
end

-- Seconds of hold the stages still allow from stability S downwards.
local function stageSecondsLeft(st, stages, S)
    local total = 0
    for _, s in ipairs(stages) do
        if s.at <= S or s == currentStage(stages, S) then
            total = total + math.max(0, s.seconds - (st.stageHeld[s.index] or 0))
        end
    end
    return total
end

-- Spacetime that must be in stock before a hole is opened.
function model.openNeed(cfg)
    local res = cfg.resources
    local need = res.minSpacetimeToOpen
    if need == "plan" then need = model.planCost(cfg) end
    return need + res.spacetimeReserve
end

-- Decides what to do this instant. Pure: returns actions, main.lua applies them.
--   inp = { requested, active, remaining (s, recipe in progress), recipeEst (s),
--           tank (L), seeds, collapsers }
-- Returns { spacetime = bool (feed on), work = bool,
--           insert = nil|"seed"|"collapser", why = string,
--           life = seconds|nil, canStart = bool }
function model.decide(st, inp, cfg)
    local a = { spacetime = false, work = false, why = "" }
    local res = cfg.resources
    st.stage = nil

    if st.fault then
        a.why = "FAULT: " .. st.fault
        return a
    end

    if st.hole == "closed" then
        a.work = true
        if st.pending then
            a.why = "waiting for the machine to take the " .. st.pending.kind
        elseif not inp.requested then
            a.why = "idle, nothing to craft"
        elseif inp.seeds <= res.keepSeeds then
            a.why = "work waiting, but out of seeds"
        elseif inp.tank < model.openNeed(cfg) then
            a.why = string.format("work waiting, but %.0f L spacetime < %.0f L needed to open",
                inp.tank, model.openNeed(cfg))
        else
            a.insert = "seed"
            a.why = "work waiting: opening a black hole"
        end
        return a
    end

    if st.hole == "unstable" or st.hole == "unknown" then
        -- No new recipe may start: it would be voided. A recipe already running
        -- finishes (disabling work never stops one), voided or not.
        local what = st.hole == "unknown" and "stability unknown" or "unstable"
        local left = st.S and (st.S - model.CLOSE_AT) or nil  -- seconds until it closes itself
        local col = cfg.collapser
        if st.pending and st.pending.kind == "collapser" then
            a.work = true  -- the collapser is taken first, before any recipe
            a.why = "collapsing"
        elseif not col.enabled then
            a.why = what .. ", waiting for it to close (collapser disabled)"
        elseif col.onlyWhenRequested and not inp.requested then
            a.why = what .. ", nothing to craft: letting it close by itself"
        elseif left and left < col.minSecondsSaved then
            a.why = what .. ", closes by itself soon"
        elseif inp.collapsers <= res.keepCollapsers then
            a.why = what .. ", out of collapsers"
        else
            a.insert = "collapser"
            a.work = true
            a.why = what .. ": collapsing it"
        end
        return a
    end

    -- Open and stable.
    local S = st.S
    local hold = cfg.hold
    local spendable = math.max(0, inp.tank - res.spacetimeReserve)
    local stages = stagesOf(cfg)
    local maxCost = hold.maxCost or math.huge
    local holdLeft = 0
    if hold.enabled then
        local maxSecs = math.min(stageSecondsLeft(st, stages, S), (hold.maxSeconds or math.huge) - st.held)
        local budget = math.min(spendable, (hold.maxSpend or math.huge) - st.spent)
        holdLeft = model.holdable(st, budget, maxCost, maxSecs)
    end
    -- Void protection: a recipe is running and the hole would die under it.
    -- It may dig into the reserve -- that is what the reserve is for.
    local vpc = cfg.voidProtection
    if st.vp and not inp.active then
        st.vp = false  -- the protected recipe finished
    end
    if vpc.enabled and inp.active and S <= vpc.margin and inp.remaining + 2 >= S then
        local secs = math.max(1, math.ceil(inp.remaining) - S + vpc.margin + 1)
        local cost = model.holdCost(st, secs)
        if cost <= inp.tank then
            st.vp = true
        elseif not st.vp then
            a.vpShort = cost
        end
    end

    a.life = S + holdLeft
    local need = inp.recipeEst + cfg.recipe.safety
    a.canStart = a.life > need and not st.vp
    local stage = currentStage(stages, S)
    local wantHold, why = false, nil
    if st.vp then
        wantHold, why = true, "void protection: holding until the recipe ends"
    elseif not hold.enabled then
        why = "holding disabled"
    elseif not stage then
        why = "decaying"
    elseif hold.onlyWithWork and not (inp.active or (inp.requested and a.canStart)) then
        why = "nothing to craft: letting it decay"
    elseif (st.stageHeld[stage.index] or 0) >= stage.seconds then
        why = "hold stage " .. stage.at .. "% used up"
    elseif st.held >= (hold.maxSeconds or math.huge) then
        why = "hold time used up"
    elseif st.costMod > maxCost then
        why = string.format("hold cost %d L/s over the %d L/s limit", st.costMod, maxCost)
    elseif st.spent + st.costMod > (hold.maxSpend or math.huge) then
        why = "hold spend limit reached"
    elseif spendable < st.costMod then
        why = "not enough spacetime to hold"
    else
        wantHold, why = true, "holding at " .. S .. "%"
        st.stage = stage.index
    end
    if st.vp then st.stage = nil end

    a.spacetime = wantHold
    a.work = a.canStart
    if not a.canStart and not st.vp then
        why = why .. "; no new recipes, the hole would not outlive them"
    end
    if a.vpShort then
        why = why .. "; NOT ENOUGH SPACETIME to protect the running recipe"
    end
    a.why = why
    return a
end

return model

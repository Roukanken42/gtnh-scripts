-- The demand side of automatic mode: what the fleet is for, and how badly.
--
-- wants.lua (the config) says which ore to keep and how much. This turns that,
-- plus what the main net actually holds, into the two things the rest of the
-- controller needs:
--
--   1. a DEMAND TABLE for target.search -- { [material] = { rate, weight } }, the
--      exact shape the targeter already takes. A deficit becomes a RATE (close it
--      within cfg.auto.horizon seconds) so the targeter's throttle mode picks the
--      slowest overdrive that covers it, rather than running flat out and burning
--      kits on ore nobody is waiting for.
--
--   2. VIEW ROWS -- what to show on the WANTS screen, and what to mark elsewhere.
--
-- Everything here is pure: hand it a stock table and it answers. Nothing reads a
-- component, so the arithmetic that decides where a fleet points can be exercised
-- off-machine.
--
-- ---- the shape of the pressure ----------------------------------------------
-- A want contributes two numbers, and they do different jobs:
--
--   rate    HOW MUCH is missing, as items/s. Sizes the fleet -- it is what says
--           whether one module can cover this or six cannot.
--   weight  HOW MUCH IT MATTERS relative to the others at the same moment. It is
--           what the targeter multiplies each material's rate by when it scores a
--           configuration, so it decides which pool wins when they compete.
--
-- The weight rises as stock falls (1 + the shortfall fraction, so a full want
-- barely pulls and an empty one pulls twice as hard), and is multiplied again once
-- a want drops under criticalAt -- "nearly out" is a different kind of problem
-- from "getting low", and the fleet should visibly lurch towards it.
--
-- HYSTERESIS, as supply.plan does it for kits: once a want is FULL it latches
-- satisfied and stops asking until it falls back under refillAt of the target.
-- Without that, a want hovering at its target would enter and leave the demand
-- table every heavy cycle, and every AUTO module would be re-aimed each time it
-- did -- each re-aim stopping a module mid-operation to write a parameter. The
-- latch is the difference between a fleet that settles and one that thrashes.

local meteors = require("lib.gtnh.meteors")

local wants = {}

wants.DEFAULTS = {
    -- Seconds to close a deficit in. Long on purpose: it converts "I am 60k short"
    -- into a rate the fleet can be asked for without demanding the whole shortfall
    -- at once, which no mining fleet could serve anyway. An hour means a want that
    -- is empty asks for want/3600 items a second.
    horizon = 3600,

    -- A satisfied want is left alone until it falls below this fraction of it.
    refillAt = 0.75,

    -- Below this share of the want, a material is CRITICAL and its weight is
    -- multiplied by criticalBoost.
    criticalAt = 0.15,
    criticalBoost = 3,
}

-- ---- what a meteor can actually yield ---------------------------------------

-- Every name the meteor tables can produce, as a set: the bare material
-- ("Dilithium"), the full oredict ("oreDilithium"), and the raw item id for the
-- item-only outputs ("gregtech:ZPM-battery"). This is exactly the set
-- target.resolveTargets will match a demand against, which is why validation
-- happens against it: a name outside it can never be mined, and a config that
-- names one should say so at startup rather than aim a module at nothing for ever.
local nameCache

function wants.names()
    if nameCache then return nameCache end
    nameCache = {}
    for _, m in ipairs(meteors.list) do
        for _, y in ipairs(m.yield) do
            nameCache[meteors.oredict(m, y)] = true
            if y.mat then nameCache[y.mat] = true end
        end
    end
    return nameCache
end

-- The same set as a sorted list, for a picker or an error message.
local listCache

function wants.nameList()
    if listCache then return listCache end
    listCache = {}
    for name in pairs(wants.names()) do listCache[#listCache + 1] = name end
    table.sort(listCache)
    return listCache
end

-- Every yield key `material` absorbs, as a set. A bare material name spans
-- prefixes -- "Platinum" covers dustPlatinum and oreEndstonePlatinum alike, which
-- is the whole reason the bare form is allowed -- so this is a set rather than one
-- string, and it is what the fleet's output is matched against.
function wants.keysOf(material)
    local keys = { [material] = true }
    for _, m in ipairs(meteors.list) do
        for _, y in ipairs(m.yield) do
            local key = meteors.oredict(m, y)
            if key == material or y.mat == material then
                keys[key] = true
                if y.mat then keys[y.mat] = true end
            end
        end
    end
    return keys
end

-- ---- loading the config -----------------------------------------------------

-- Validates the raw config and returns { entries, problems }.
--
-- A bad entry is DROPPED and reported rather than repaired. Automatic mode aims
-- real hardware at this list, so a typo that quietly became something else --
-- "Platinium" silently matching nothing, a want of "1000" as a string -- is worse
-- than an entry that is missing and named in the log.
--
-- Each surviving entry:
--   { material, labels = { <label>, ... }, want, weight, keys, produced, index }
function wants.load(raw)
    local entries, problems = {}, {}
    local items = (type(raw) == "table") and (raw.items or raw) or nil
    if type(items) ~= "table" then
        return entries, { "wants.lua does not return a table with an `items` list" }
    end

    local names = wants.names()
    local seen = {}

    for i, e in ipairs(items) do
        local where = "wants.items[" .. i .. "]"
        if type(e) ~= "table" then
            problems[#problems + 1] = where .. " is not a table"
        else
            local material = e.material
            local labels = {}
            if type(e.label) == "string" then labels = { e.label }
            elseif type(e.label) == "table" then
                for _, l in ipairs(e.label) do
                    if type(l) == "string" and l ~= "" then labels[#labels + 1] = l end
                end
            end

            local want = tonumber(e.want)
            local weight = tonumber(e.weight or 1)

            if type(material) ~= "string" or material == "" then
                problems[#problems + 1] = where .. " has no `material`"
            elseif not names[material] then
                problems[#problems + 1] = where .. ": no meteor yields '" .. material
                    .. "' -- check the spelling against the yield tables in "
                    .. "lib/gtnh/meteors.lua"
            elseif seen[material] then
                problems[#problems + 1] = where .. ": '" .. material
                    .. "' is already listed at entry " .. seen[material]
            elseif not want or want <= 0 then
                problems[#problems + 1] = where .. " ('" .. material
                    .. "'): `want` must be a positive number of items"
            elseif not weight or weight <= 0 then
                problems[#problems + 1] = where .. " ('" .. material
                    .. "'): `weight` must be a positive number"
            else
                seen[material] = i
                -- A missing label is not fatal: the material can still be mined,
                -- and the only thing lost is knowing when to stop. Reported, and
                -- the row says "stock unknown" rather than pretending to a figure.
                if #labels == 0 then
                    problems[#problems + 1] = where .. " ('" .. material
                        .. "'): no `label`, so its stock cannot be read -- it will "
                        .. "be treated as empty and mined for as long as it is listed"
                end
                entries[#entries + 1] = {
                    index = #entries + 1,
                    material = material,
                    labels = labels,
                    want = want,
                    weight = weight,
                    keys = wants.keysOf(material),
                }
            end
        end
    end

    return entries, problems
end

-- ---- what the fleet is producing --------------------------------------------

-- Sums a fleet ore breakdown (main.lua's fleetAggregate, keyed by `mat` or
-- oredict) into items/s per entry. An entry that spans prefixes collects all of
-- them, which is what makes the bare material form meaningful.
function wants.produced(entries, oreRates)
    local out = {}
    if type(oreRates) ~= "table" then return out end
    for _, e in ipairs(entries or {}) do
        local sum = 0
        for key, rate in pairs(oreRates) do
            if e.keys[key] then sum = sum + (rate or 0) end
        end
        out[e.material] = sum
    end
    return out
end

-- ---- fill, weight, demand ---------------------------------------------------

local function opt(opts, key)
    local v = opts and opts[key]
    if v == nil then return wants.DEFAULTS[key] end
    return v
end

-- What one entry holds, summed over its labels. Returns nil when the stock is
-- UNKNOWN -- no reading yet, or an entry with no label -- which is a different
-- thing from holding none of it and is never treated as critical.
function wants.have(entry, stock)
    if type(stock) ~= "table" or #entry.labels == 0 then return nil end
    local n = 0
    for _, label in ipairs(entry.labels) do n = n + (stock[label] or 0) end
    return n
end

-- The pull one want exerts, given how full it is. See the header for why it is
-- shaped like this.
function wants.weightOf(entry, fill, opts)
    local w = entry.weight or 1
    -- Unknown stock reads as empty (mine it) but never as critical: an unread
    -- network must not be able to fling the whole fleet at one material.
    if fill == nil then return w * 2, false end
    local critical = fill < opt(opts, "criticalAt")
    w = w * (1 + (1 - math.min(1, fill)))
    if critical then w = w * opt(opts, "criticalBoost") end
    return w, critical
end

-- Everything the controller and the screen need about the want list, in one pass.
--
--   entries     from wants.load
--   stock       { [label] = count } from the main net, or nil if unread
--   opts        cfg.auto (horizon / refillAt / criticalAt / criticalBoost)
--   satisfied   caller-owned latch table, carried across cycles (see the header)
--   oreRates    { [yield key] = items/s } the fleet currently produces, optional
--
-- Returns rows, demand, summary:
--   rows      one per entry, in config order, everything the screen shows
--   demand    { [material] = { rate, weight } } for target.search, or nil when
--             nothing is being asked for (every want full, or the list is empty)
--   summary   { n, demanded, satisfied, critical, unmined, fill, eta }
function wants.evaluate(entries, stock, opts, satisfied, oreRates)
    entries = entries or {}
    satisfied = satisfied or {}
    local horizon = math.max(1, opt(opts, "horizon"))
    local refillAt = opt(opts, "refillAt")

    local made = wants.produced(entries, oreRates)
    local rows, demand, n = {}, nil, 0
    local sumFill, counted = 0, 0
    local summary = { n = #entries, demanded = 0, satisfied = 0, critical = 0,
                      unmined = 0, fill = 0 }

    for _, e in ipairs(entries) do
        local have = wants.have(e, stock)
        local fill = (have ~= nil and e.want > 0) and (have / e.want) or nil
        local weight, critical = wants.weightOf(e, fill, opts)

        -- The latch. Note it is driven by `have`, not by the fill, so an unknown
        -- stock never satisfies anything.
        local full = have ~= nil and have >= e.want
        if full then
            satisfied[e.material] = true
        elseif satisfied[e.material] and have ~= nil and have >= refillAt * e.want then
            -- still latched: hovering under the target is not a reason to re-aim
        else
            satisfied[e.material] = false
        end
        local asking = satisfied[e.material] ~= true

        local deficit = math.max(0, e.want - (have or 0))
        local rate = asking and (deficit / horizon) or 0
        local rateOut = made[e.material] or 0

        local state, note
        if not next(e.keys) then state = "NOT MINED"
        elseif have == nil then state = "UNKNOWN"
        elseif full then state = "FULL"
        elseif critical then state = "CRITICAL"
        elseif fill < 0.5 then state = "LOW"
        else state = "OK" end

        -- The one number that says whether the fleet is actually serving this:
        -- how long the deficit would take to close at what it is producing now.
        local eta
        if deficit > 0 and rateOut > 0 then eta = deficit / rateOut end
        if rateOut <= 0 and deficit > 0 then note = "nothing is mining it" end

        if not asking then summary.satisfied = summary.satisfied + 1 end
        if critical then summary.critical = summary.critical + 1 end
        if fill ~= nil then
            sumFill = sumFill + math.min(1, fill)
            counted = counted + 1
        end

        rows[#rows + 1] = {
            material = e.material,
            label = table.concat(e.labels, ", "),
            labels = e.labels,
            want = e.want,
            have = have,
            fill = fill,
            weight = weight,
            critical = critical,
            satisfied = not asking,
            deficit = deficit,
            rate = rate,          -- items/s being asked for
            produced = rateOut,   -- items/s the fleet makes now
            covered = (rate > 0) and math.min(1, rateOut / rate) or (rateOut > 0 and 1 or 0),
            eta = eta,
            state = state,
            note = note,
        }

        if asking and rate > 0 then
            demand = demand or {}
            demand[e.material] = { rate = rate, weight = weight }
            n = n + 1
        end
    end

    summary.demanded = n
    summary.fill = (counted > 0) and (sumFill / counted) or 0
    return rows, demand, summary
end

-- Which of the fleet's yield keys are WANTED, as a set, so the ore and meteor
-- tables can mark them. Built from the entries rather than from the demand table
-- on purpose: a want that is currently full is still what the fleet is for, and
-- dimming it the moment it fills would make the marking flicker.
function wants.wantedKeys(entries)
    local set = {}
    for _, e in ipairs(entries or {}) do
        for key in pairs(e.keys) do set[key] = e.material end
    end
    return set
end

return wants

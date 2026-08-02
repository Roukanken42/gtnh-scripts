-- Keeps the LOCAL mining net stocked from the main net.
--
-- The modules burn consumables the local net has no source for: per meteor, 4
-- toolHeadDrill + 4 stick of the drone's material (together a "kit"), plus
-- plasma. The bridge is an ME Interface belonging to the MAIN net, carrying FAKE
-- CRAFTING PATTERNS: requesting one pushes that pattern's INPUTS into the
-- adjacent local-net block, and the Fake Crafting Card ends the job the moment
-- they are pushed. So for these patterns
--
--     the inputs are the payload; the output is a cosmetic handle
--
-- that exists only so there is something to name in a craft request. Everything
-- below reads the inputs and ignores the output except as a request key.
--
-- The interface needs its own OC Adapter. An adapter exposes whichever network
-- ITS OWN BLOCK belongs to, so that one hands us the full main-net API --
-- getCraftables / request included -- while localnet.lua stays the local-side
-- anchor for "what do we actually have".
--
-- API references (see GTNH-OC-Lua-Documentation):
--   me_interface.getInterfacePattern(i)   -> { inputs = {{name, count}, ...},
--                                              outputs = {{name, count}, ...} }
--                                            `name` is the LOCALIZED label only
--   me_interface.getCraftables(filter)    -> AECraftable[]  (filter has no wildcard)
--   craftable.request(n)                  -> AECraftingJob (isComputing/isDone/
--                                            hasFailed/isCanceled)
--   me_interface.storeInterfacePatternInput(i, idx, db, dbSlot)
--                                            escape hatch: real item metadata into
--                                            a database, if labels ever fall short
--
-- component is required lazily so the pure half of this module -- classify, the
-- kit arithmetic, plan -- can be exercised off-machine the way target.lua is.

local drones = require("drones")
local plasmas = require("plasmas")
local estimate = require("estimate")

local supply = {}

-- A kit is 4 rods AND 4 drill tips. Both consumables are therefore needed at the
-- same rate, which is precisely why nothing here ever has to tell a rod from a
-- drill tip: one `/ PER_KIT` converts in both directions.
local PER_KIT = estimate.KIT.rods
assert(PER_KIT == estimate.KIT.drillTips,
    "supply.lua assumes rods and drill tips are consumed at the same rate")

-- How many interface pattern slots to probe. An ME Interface has 9; probing well
-- past that is cheap and covers bigger variants.
supply.MAX_PATTERN_SLOTS = 36

-- ---- pure: identifying what a pattern supplies ------------------------------

-- The distinct drone materials, LONGEST FIRST. Order matters: "Naquadah Alloy
-- Rod" also starts with "Naquadah ", and the longer match is the correct one.
local function droneMaterials()
    local seen, list = {}, {}
    for tier = drones.MIN_TIER, drones.MAX_TIER do
        local m = drones.get(tier).material
        if m and not seen[m] then seen[m] = true; list[#list + 1] = m end
    end
    table.sort(list, function(a, b)
        if #a ~= #b then return #a > #b end
        return a < b
    end)
    return list
end

supply.MATERIALS = droneMaterials()

-- The drone material an item label belongs to, by GT's universal
-- "<Material> <Prefix>" label shape -- so this leans on the material name only,
-- never on how toolHeadDrill or stick happen to be localized. nil if none match.
function supply.materialOf(label, materials)
    if type(label) ~= "string" then return nil end
    for _, m in ipairs(materials or supply.MATERIALS) do
        if label:sub(1, #m + 1) == m .. " " then return m end
    end
    return nil
end

-- The plasma an item label refers to, matching on prefix so the ae2fc "drop"
-- wrapper around a fluid still resolves. nil if none match.
function supply.plasmaOf(label)
    if type(label) ~= "string" then return nil end
    for _, p in ipairs(plasmas.list) do
        if label:sub(1, #p.name) == p.name then return p end
    end
    return nil
end

-- Normalizes a pattern's inputs/outputs to a plain 1-based array. getAllStacks is
-- 0-indexed elsewhere in this codebase (see transport.lua), and the pattern slot
-- arrays have not been confirmed either way, so accept both.
local function slots(list)
    local out = {}
    if type(list) ~= "table" then return out end
    local keys = {}
    for k, s in pairs(list) do
        if type(k) == "number" and type(s) == "table" and s.name then keys[#keys + 1] = k end
    end
    -- Order by slot index rather than by name: for outputs the first slot is the
    -- primary one, which is the label a craft request has to be made against.
    table.sort(keys)
    for _, k in ipairs(keys) do
        out[#out + 1] = { name = list[k].name, count = list[k].count or 0 }
    end
    return out
end

-- What a pattern supplies, decided entirely from its INPUTS.
--   { label, index, inputs, kind, material|plasma|drone, reason }
-- kind is "kit" | "plasma" | "drone" | "unknown". Every input must agree; a
-- pattern that mixes materials, or contains anything unrecognised, comes back
-- "unknown" WITH A REASON rather than being guessed at.
function supply.classify(pattern, materials)
    materials = materials or supply.MATERIALS
    local outputs = slots(pattern.outputs)
    local entry = {
        label = outputs[1] and outputs[1].name,
        index = pattern.index,
        inputs = slots(pattern.inputs),
    }

    local function unknown(reason)
        entry.kind, entry.reason = "unknown", reason
        return entry
    end

    if not entry.label then return unknown("no output to name in a craft request") end
    if #entry.inputs == 0 then return unknown("no inputs, so nothing would be pushed") end

    local material, plasma, drone, mixed = nil, nil, nil, nil
    for _, i in ipairs(entry.inputs) do
        local d = drones.fromName(i.name)
        local p = not d and supply.plasmaOf(i.name) or nil
        local m = not d and not p and supply.materialOf(i.name, materials) or nil

        if d then
            if drone and drone.tier ~= d.tier then mixed = "drone tiers" end
            drone = drone or d
        elseif p then
            if plasma and plasma.tier ~= p.tier then mixed = "plasmas" end
            plasma = plasma or p
        elseif m then
            if material and material ~= m then mixed = "materials" end
            material = material or m
        else
            return unknown("input '" .. i.name .. "' is not a known drone, plasma or drone material")
        end
    end

    if mixed then return unknown("inputs mix " .. mixed) end

    local kinds = (material and 1 or 0) + (plasma and 1 or 0) + (drone and 1 or 0)
    if kinds > 1 then return unknown("inputs mix kits, plasma and/or drones") end

    if material then
        entry.kind, entry.material = "kit", material
        entry.perCraft = supply.kitsPerCraft(entry)
        if entry.perCraft < 1 then
            return unknown("delivers less than one whole kit (" .. PER_KIT .. " of each) per craft")
        end
    elseif plasma then
        entry.kind, entry.plasma = "plasma", plasma
        entry.perCraft = entry.inputs[1] and entry.inputs[1].count or 0
    else
        entry.kind, entry.drone = "drone", drone
        entry.perCraft = entry.inputs[1] and entry.inputs[1].count or 0
    end
    return entry
end

-- Whole kits delivered by one craft of a kit pattern: every input is needed
-- PER_KIT at a time, so the scarcest one sets the count. Batched patterns fall
-- out of this for free (64 + 64 -> 16 kits).
function supply.kitsPerCraft(entry)
    local n = math.huge
    for _, i in ipairs(entry.inputs) do
        n = math.min(n, math.floor((i.count or 0) / PER_KIT))
    end
    return (n == math.huge) and 0 or n
end

-- Whole kits the local net currently holds for a kit pattern. `stock` maps item
-- label -> count. Same identity as above: the scarcest input decides.
function supply.kitsInStock(entry, stock)
    local n = math.huge
    for _, i in ipairs(entry.inputs) do
        n = math.min(n, math.floor(((stock and stock[i.name]) or 0) / PER_KIT))
    end
    return (n == math.huge) and 0 or n
end

-- ---- pure: deciding what to request -----------------------------------------

-- What to request to bring the local net back to its targets.
--   catalog    entries from supply.classify
--   stock      { items = { [label] = count }, fluids = { [name] = litres } }
--   cfg        cfg.supply (target / plasma / plasmaPerCraft / lowWater / maxCrafts)
--   satisfied  caller-owned latch table, carried across cycles for hysteresis
-- Returns a list of { entry, key, have, target, deficit, crafts }, plus a list of
-- notes for anything that has a target but cannot be acted on.
--
-- Hysteresis matches pump/main.lua's computeNeedy: once a material reaches its
-- target it stays "satisfied" until it drops below lowWater * target, so a slow
-- drain cannot make this re-request every cycle.
function supply.plan(catalog, stock, cfg, satisfied)
    cfg = cfg or {}
    stock = stock or {}
    satisfied = satisfied or {}
    local lowWater = cfg.lowWater or 0.9
    local work, notes = {}, {}

    local function consider(entry, key, have, target, perCraft)
        if not target or target <= 0 then return end
        if have >= target then
            satisfied[key] = true
            return
        end
        if satisfied[key] and have >= lowWater * target then return end
        satisfied[key] = false

        if not perCraft or perCraft <= 0 then
            notes[#notes + 1] = key .. ": short " .. (target - have)
                .. ", but how much one craft delivers is unknown"
            return
        end
        local deficit = target - have
        local crafts = math.ceil(deficit / perCraft)
        if cfg.maxCrafts and crafts > cfg.maxCrafts then crafts = cfg.maxCrafts end
        work[#work + 1] = {
            entry = entry, key = key, have = have, target = target,
            deficit = deficit, crafts = crafts,
        }
    end

    for _, entry in ipairs(catalog) do
        if entry.kind == "kit" then
            consider(entry, entry.material,
                supply.kitsInStock(entry, stock.items),
                cfg.target and cfg.target[entry.material],
                entry.perCraft)
        elseif entry.kind == "plasma" then
            -- Targets are in litres, but one craft delivers an ae2fc "drop" whose
            -- litre value is not something the pattern tells us. Until it is
            -- measured once and written to cfg.supply.plasmaPerCraft, this reports
            -- the shortfall instead of guessing an amount.
            consider(entry, entry.plasma.name,
                (stock.fluids and stock.fluids[entry.plasma.name]) or 0,
                cfg.plasma and cfg.plasma[entry.plasma.name],
                cfg.plasmaPerCraft and cfg.plasmaPerCraft[entry.plasma.name])
        end
    end

    table.sort(work, function(a, b)
        local ra = a.target > 0 and a.have / a.target or 0
        local rb = b.target > 0 and b.have / b.target or 0
        if ra ~= rb then return ra < rb end      -- emptiest first
        return a.key < b.key
    end)
    return work, notes
end

-- ---- component edge ---------------------------------------------------------

local function components() return require("component") end

-- Reads every pattern in an interface. Probes each slot under pcall and CONTINUES
-- PAST GAPS -- patterns need not be contiguous, and an empty slot may error or
-- return nil depending on the build. Returns a list of raw patterns with .index.
function supply.readPatterns(itf, maxSlots)
    local out = {}
    if not itf or itf.getInterfacePattern == nil then return out end
    for i = 1, (maxSlots or supply.MAX_PATTERN_SLOTS) do
        local ok, p = pcall(itf.getInterfacePattern, i)
        if ok and type(p) == "table" and (p.inputs or p.outputs) then
            p.index = i
            out[#out + 1] = p
        end
    end
    return out
end

-- Finds the supply interface: the configured address, or else autodetected as the
-- one me_interface that HAS patterns (the per-module station interfaces in
-- transport.lua carry none). Ambiguity is an error naming the candidates rather
-- than a coin flip. Returns proxy, or nil + error.
function supply.find(address)
    local component = components()
    if address and address ~= "" then
        local full = address
        if #address < 36 then
            local ok, g = pcall(component.get, address)
            if ok and g then full = g end
        end
        local ok, p = pcall(component.proxy, full)
        if not ok or not p then return nil, "no component at '" .. address .. "'" end
        return p
    end

    local found = {}
    for addr in component.list("me_interface") do
        local p = component.proxy(addr)
        if #supply.readPatterns(p, 4) > 0 then found[#found + 1] = p end
    end
    if #found == 1 then return found[1] end
    if #found == 0 then
        return nil, "no me_interface with patterns found -- add an adapter to the "
            .. "main-net supply interface, or set cfg.supply.interface"
    end
    local addrs = {}
    for _, p in ipairs(found) do addrs[#addrs + 1] = p.address:sub(1, 8) end
    return nil, "several interfaces have patterns (" .. table.concat(addrs, ", ")
        .. ") -- set cfg.supply.interface"
end

-- Everything the supply interface can push, classified. Returns the usable
-- entries and, separately, the ones that could not be identified (each with a
-- .reason) so they can be shown rather than silently dropped.
function supply.catalog(itf)
    local usable, unknown = {}, {}
    for _, p in ipairs(supply.readPatterns(itf)) do
        local entry = supply.classify(p)
        if entry.kind == "unknown" then unknown[#unknown + 1] = entry
        else usable[#usable + 1] = entry end
    end
    table.sort(usable, function(a, b)
        if a.kind ~= b.kind then return a.kind < b.kind end
        return (a.material or a.label) < (b.material or b.label)
    end)
    return usable, unknown
end

-- Requests `crafts` of a catalog entry from the SUPPLY network, which pushes that
-- many lots of its inputs into the local net. Returns an AECraftingJob, or
-- nil + error. The label is re-checked after filtering because the ME filter's
-- matching semantics are not exact-only (localnet.lua guards the same way).
function supply.request(itf, entry, crafts)
    if not entry or not entry.label then return nil, "entry has no requestable output" end
    crafts = math.max(1, math.floor(crafts or 1))

    local ok, list = pcall(itf.getCraftables, { label = entry.label })
    if not ok or type(list) ~= "table" then
        return nil, "getCraftables failed for '" .. entry.label .. "'"
    end
    for _, c in ipairs(list) do
        local okStack, stack = pcall(c.getItemStack)
        if okStack and type(stack) == "table" and stack.label == entry.label then
            local okReq, job = pcall(c.request, crafts)
            if not okReq then return nil, "request failed: " .. tostring(job) end
            return job
        end
    end
    return nil, "'" .. entry.label .. "' is not craftable on the supply network"
end

-- State of a crafting job: "computing" | "done" | "failed" | "canceled".
-- Fake-crafting patterns finish as soon as their inputs are pushed, so this
-- settles quickly -- but it is still polled rather than waited on, so several
-- requests can be in flight together.
function supply.jobState(job)
    if type(job) ~= "table" and type(job) ~= "userdata" then return "failed" end
    local function ask(name)
        local ok, v = pcall(job[name])
        return ok and v == true
    end
    if ask("hasFailed") then return "failed" end
    if ask("isCanceled") then return "canceled" end
    if ask("isDone") then return "done" end
    if ask("isComputing") then return "computing" end
    return "computing"
end

-- Current local-net stock for a catalog, in the shape supply.plan expects:
--   { items = { [label] = count }, fluids = { [name] = litres } }
-- Only the labels the catalog actually mentions are looked up, so this stays a
-- handful of filtered queries rather than a whole-network dump.
function supply.stock(catalog, net)
    local items, fluids = {}, {}
    if not net then return { items = items, fluids = fluids } end

    for _, entry in ipairs(catalog) do
        if entry.kind == "kit" or entry.kind == "drone" then
            for _, i in ipairs(entry.inputs) do
                if items[i.name] == nil then
                    items[i.name] = 0
                    local ok, found = pcall(net.getItemsInNetwork, { label = i.name })
                    if ok and type(found) == "table" then
                        for _, it in ipairs(found) do
                            -- re-check: the filter is not reliably exact
                            if it and it.label == i.name then
                                items[i.name] = items[i.name] + (it.size or 0)
                            end
                        end
                    end
                end
            end
        end
    end

    local ok, found = pcall(net.getFluidsInNetwork)
    if ok and type(found) == "table" then
        for _, f in ipairs(found) do
            if f and f.label then fluids[f.label] = (fluids[f.label] or 0) + (f.amount or 0) end
        end
    end

    return { items = items, fluids = fluids }
end

supply.PER_KIT = PER_KIT

return supply

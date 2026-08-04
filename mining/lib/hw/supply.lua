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

local drones = require("lib.gtnh.drones")
local plasmas = require("lib.gtnh.plasmas")
local estimate = require("lib.calc.estimate")

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

-- ae2fc carries a fluid through a pattern as an item labelled "drop of <Fluid>",
-- and one drop is exactly one litre -- so a plasma input's COUNT is already its
-- volume, and nothing has to be measured or configured.
local DROP_PREFIX = "drop of "

-- The plasma an item label refers to, unwrapping the drop form first. A bare
-- fluid label still resolves, so this works either way. nil if none match.
function supply.plasmaOf(label)
    if type(label) ~= "string" then return nil end
    local name = label
    if name:sub(1, #DROP_PREFIX):lower() == DROP_PREFIX then
        name = name:sub(#DROP_PREFIX + 1)
    end
    for _, p in ipairs(plasmas.list) do
        if name:sub(1, #p.name) == p.name then return p end
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
        -- The original slot key is kept: storeInterfacePatternInput addresses
        -- inputs by it, and whether it counts from 0 or 1 is not documented.
        out[#out + 1] = { name = list[k].name, count = list[k].count or 0, index = k }
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
        -- The item TYPE's name, which is all a pattern slot reports. For a renamed
        -- fake output this is NOT what to request against -- supply.resolveOutput
        -- replaces it with the real label and moves this to entry.slotLabel.
        label = outputs[1] and outputs[1].name,
        outputIndex = outputs[1] and outputs[1].index,
        -- How many output items ONE craft of this pattern makes. Almost always 1, and
        -- it matters when it is not: a craft request asks AE2 for a number of ITEMS,
        -- so a pattern whose output is a stack of 64 turns a request for 13 into a
        -- single craft. See supply.request.
        outputCount = (outputs[1] and tonumber(outputs[1].count)) or 1,
        index = pattern.index,
        inputs = slots(pattern.inputs),
    }
    if entry.outputCount < 1 then entry.outputCount = 1 end

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
    else
        -- Both are counted straight off the inputs. For plasma that count is
        -- litres, one drop apiece; the inputs cannot disagree on which plasma or
        -- drone by this point, so summing them is safe.
        local total = 0
        for _, i in ipairs(entry.inputs) do total = total + i.count end
        entry.perCraft = total
        if plasma then entry.kind, entry.plasma = "plasma", plasma
        else entry.kind, entry.drone = "drone", drone end
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

-- Litres of plasma the local net holds for a plasma pattern. The drop form only
-- exists on the main net, where the Fluid Discretizer needs it to satisfy the
-- pattern; what arrives here is always the fluid itself.
function supply.plasmaInStock(entry, stock)
    return (stock and stock.fluids and stock.fluids[entry.plasma.name]) or 0
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

-- What the local net holds for each catalog entry, keyed the way plan and the
-- order book key things: the material for kits, the fluid name for plasma.
function supply.levels(catalog, stock)
    stock = stock or {}
    local out = {}
    for _, entry in ipairs(catalog or {}) do
        if entry.kind == "kit" then
            out[entry.material] = supply.kitsInStock(entry, stock.items)
        elseif entry.kind == "plasma" then
            out[entry.plasma.name] = supply.plasmaInStock(entry, stock)
        end
    end
    return out
end

-- What to request to bring the local net back to its targets.
--   catalog    entries from supply.classify
--   stock      { items = { [label] = count }, fluids = { [name] = litres } }
--   cfg        cfg.supply (target / plasma / plasmaPerCraft / lowWater / maxCrafts)
--   satisfied  caller-owned latch table, carried across cycles for hysteresis
-- Returns a list of { entry, key, have, target, deficit, crafts }, plus a list of
-- notes for anything that has a target but cannot be acted on.
--
-- This compares the target against WHAT IS ACTUALLY THERE, and nothing else. An
-- earlier version also counted what had been requested but not yet seen, to stop
-- the same shortfall being ordered every cycle -- but it had to guess when an
-- order had arrived by watching the stock rise, and the modules eat kits as fast
-- as they land, so a delivery that was immediately consumed never looked like a
-- delivery and the phantom order stuck around until it timed out.
--
-- Guessing was the mistake. The caller re-reads the stock the moment a craft
-- finishes, so by the time this runs again the answer is simply known. What stops
-- the re-requesting is a fresh reading, not a prediction.
--
-- Hysteresis stays, as pump/main.lua's computeNeedy does it: once a material
-- reaches its target it stays "satisfied" until it drops below lowWater * target,
-- so a slow drain cannot make this ask every cycle.
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
        local wanted = math.ceil(deficit / perCraft)
        local crafts, capped = wanted, nil
        if cfg.maxCrafts and crafts > cfg.maxCrafts then
            -- Reported, not just applied. A cap that quietly turns "3000 kits short"
            -- into one craft looks exactly like a supply line that is not working, and
            -- there is nothing on any screen to tell the two apart.
            crafts, capped = cfg.maxCrafts, wanted
        end
        work[#work + 1] = {
            entry = entry, key = key, have = have, target = target,
            deficit = deficit, crafts = crafts,
            -- What one craft delivers, and what the deficit really asked for: enough
            -- for a caller to say "13 crafts, 3328 kits" rather than just "13".
            perCraft = perCraft, wanted = wanted, capped = capped,
        }
    end

    local levels = supply.levels(catalog, stock)
    for _, entry in ipairs(catalog) do
        if entry.kind == "kit" then
            consider(entry, entry.material, levels[entry.material],
                cfg.target and cfg.target[entry.material], entry.perCraft)
        elseif entry.kind == "plasma" then
            -- Target and stock are both litres, and so is perCraft (one drop per
            -- litre), so this needs no conversion at all.
            consider(entry, entry.plasma.name, levels[entry.plasma.name],
                cfg.plasma and cfg.plasma[entry.plasma.name], entry.perCraft)
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

-- nil off-machine, so the pure half of this module stays loadable and callers
-- that need hardware can report it instead of throwing.
local function components()
    local ok, c = pcall(require, "component")
    if ok then return c end
    return nil
end

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
-- Returns proxy, how -- where `how` is "configured" or "found", so a caller can
-- say whether the stored address was any use. A configured address is CHECKED
-- rather than trusted: setup records the one it found, and an address that has
-- since moved would otherwise surface much later as "no kit pattern for
-- Neutronium", which points at entirely the wrong thing.
function supply.find(address)
    local component = components()
    if not component then return nil, "no component library (off-machine?)" end

    local stale
    if address and address ~= "" then
        local full = address
        if #address < 36 then
            local ok, g = pcall(component.get, address)
            if ok and g then full = g end
        end
        local ok, p = pcall(component.proxy, full)
        if ok and p and #supply.readPatterns(p, 4) > 0 then return p, "configured" end
        stale = (ok and p) and "the configured interface has no patterns"
            or "there is no component at the configured address"
    end

    local found = {}
    for addr in component.list("me_interface") do
        local p = component.proxy(addr)
        if #supply.readPatterns(p, 4) > 0 then found[#found + 1] = p end
    end
    if #found == 1 then return found[1], stale and "found (" .. stale .. ")" or "found" end
    if #found == 0 then
        return nil, (stale and (stale .. ", and ") or "")
            .. "no me_interface with patterns found -- add an adapter to the "
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
--
-- Pass a db.lua handle (or a database address) to resolve each pattern's true
-- output item. Without one, entry.label is only the output item TYPE's name,
-- which for a renamed fake output points at a different craftable entirely -- so
-- any caller that intends to REQUEST something must supply it.
function supply.catalog(itf, handle)
    if type(handle) == "string" then handle = require("lib.hw.db").open(handle) end

    local usable, unknown = {}, {}
    for _, p in ipairs(supply.readPatterns(itf)) do
        local entry = supply.classify(p)
        if entry.kind == "unknown" then unknown[#unknown + 1] = entry
        else
            if handle then
                local ok, err = supply.resolveOutput(itf, entry, handle)
                if not ok then entry.outputError = err end
            end
            usable[#usable + 1] = entry
        end
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
--
-- A CRAFT IS NOT AN ITEM. AECraftable.request takes a number of output ITEMS, and one
-- craft of a pattern makes entry.outputCount of them -- so asking for `crafts` items
-- of a pattern whose output is a stack of 64 gets you ceil(crafts/64) crafts, which
-- for any sane deficit is one. That is a silent shortfall: the job succeeds, the log
-- says thirteen crafts, and a fraction of the kits arrive.
--
-- Returns the job and the number of items asked for, so a caller can say what it did
-- in the units AE2 was actually given.
function supply.request(itf, entry, crafts)
    if not entry or not entry.label then return nil, "entry has no requestable output" end
    crafts = math.max(1, math.floor(crafts or 1))
    local items = crafts * math.max(1, entry.outputCount or 1)

    -- Without a resolved output we only have the item TYPE's name, which may name
    -- a completely different craftable -- a real "Steel Drill Tip" recipe rather
    -- than the fake pattern that pushes drill tips across. Refuse rather than
    -- craft the wrong thing into main-net storage.
    if not entry.output then
        return nil, "the output of pattern " .. tostring(entry.index) .. " has not been resolved"
            .. (entry.outputError and (" (" .. entry.outputError .. ")") or "")
            .. " -- catalog() needs a database to tell a renamed fake output from its base item"
    end
    local want = entry.output

    local ok, list = pcall(itf.getCraftables, { label = want.label })
    if not ok or type(list) ~= "table" then
        return nil, "getCraftables failed for '" .. tostring(want.label) .. "'"
    end

    -- Match on the whole identity. A renamed fake output shares its name and
    -- damage with the plain item, so the label is what separates them -- and the
    -- filter's matching is not reliably exact, hence the re-check.
    local found
    for _, c in ipairs(list) do
        local okStack, stack = pcall(c.getItemStack)
        if okStack and type(stack) == "table"
            and stack.label == want.label
            and (want.name == nil or stack.name == want.name)
            and (want.damage == nil or stack.damage == want.damage) then
            if found then
                return nil, "'" .. tostring(want.label) .. "' matches more than one craftable"
                    .. " -- give the fake pattern's output a name nothing else crafts"
            end
            found = c
        end
    end
    if not found then
        return nil, "'" .. tostring(want.label) .. "' is not craftable on the supply network"
    end

    local okReq, job = pcall(found.request, items)
    if not okReq then return nil, "request failed: " .. tostring(job) end
    return job, items
end

-- Copies one slot of a pattern into a database and hands back what landed there.
-- This is the only way to see a pattern slot's REAL item: getInterfacePattern
-- reports a slot's `name` as the item TYPE's localized name, which for a renamed
-- item is not its display label at all.
--
-- The store methods address slots by index and nothing says whether that counts
-- from 0 or 1, so the pattern's own key is tried first and its neighbours after;
-- the database is read back each time to see which took, because store() is
-- silent on failure (exactly as Station:ensureDbSlot found for items).
-- Returns the stack, or nil + error.
local function storePatternSlot(itf, method, patternIndex, slotIndex, handle, dbSlot)
    if itf[method] == nil then return nil, "interface has no " .. method end

    local base = slotIndex or 1
    for _, idx in ipairs({ base, base + 1, base - 1 }) do
        handle:clear(dbSlot)
        local ok = pcall(itf[method], patternIndex, idx, handle.address, dbSlot)
        if ok then
            local stack = handle:get(dbSlot)
            if stack then return stack end
        end
    end
    handle:clear(dbSlot)
    return nil, method .. " found nothing at pattern " .. tostring(patternIndex)
        .. " slot " .. tostring(base)
end

supply.storePatternSlot = storePatternSlot

-- Writes a plasma pattern's ae2fc DROP into a database slot, which is the form
-- setFluidInterfaceConfiguration wants -- and the only place to get one, since
-- the local net holds plasma as fluid and never as drops.
-- Returns true, or false + error.
-- The drop is long-lived -- a fluid interface keeps pointing at it -- so it gets
-- a permanent named slot rather than borrowing one. Returns the slot, or nil+err.
function supply.storePlasmaDrop(itf, entry, handle)
    if not entry or entry.kind ~= "plasma" then return nil, "not a plasma pattern" end
    local input = entry.inputs[1]
    if not input then return nil, "plasma pattern has no input to store" end

    local dbSlot, fresh = handle:slot("plasma:" .. entry.plasma.name)
    if not dbSlot then return nil, tostring(fresh) end
    if not fresh and handle:label(dbSlot) then return dbSlot end

    local stack, err = storePatternSlot(itf, "storeInterfacePatternInput",
        entry.index, input.index, handle, dbSlot)
    if not stack then
        return nil, "could not store the drop for " .. entry.plasma.name .. ": " .. tostring(err)
    end
    return dbSlot
end

-- Resolves a pattern's true OUTPUT item -- the thing a craft request has to be
-- made against. Needed because a fake pattern's output is usually a renamed item,
-- and the pattern slot only reports the underlying type: a "Mining Kit: Steel"
-- output reads back as "Steel Drill Tip", which is also a perfectly real craftable
-- on the main net. Requesting that would craft drill tips into main-net storage
-- and push nothing anywhere.
--
-- Fills entry.output = { label, name, damage, hasTag } and repoints entry.label at
-- the true label, keeping the type's name in entry.slotLabel for display.
-- Returns true, or false + error.
function supply.resolveOutput(itf, entry, handle)
    if not entry or not entry.outputIndex then return false, "entry has no output slot" end
    -- Scratch: read straight back, never depended on afterwards.
    local stack, err = storePatternSlot(itf, "storeInterfacePatternOutput",
        entry.index, entry.outputIndex, handle, handle:scratch())
    if not stack then return false, tostring(err) end

    entry.output = {
        label = stack.label, name = stack.name,
        damage = stack.damage, hasTag = stack.hasTag,
    }
    if type(stack.label) == "string" and stack.label ~= "" then
        entry.slotLabel = entry.label
        entry.label = stack.label
    end
    return true
end

-- ---- what the MAIN net holds ------------------------------------------------
--
-- Automatic mode is driven by the stock of the ore the fleet is FOR, and that ore
-- lives on the main net -- not the local one, which only ever holds consumables on
-- their way to a module. The supply interface's adapter reaches the main net (that
-- is the whole reason it is the bridge), so this asks it.
--
-- ---- NEVER LIST THE WHOLE NETWORK -------------------------------------------
-- The obvious implementation -- getItemsInNetwork() with no filter, once, and pick
-- the wanted labels out of the result -- does not work, and the way it fails is worth
-- recording because it looks like a bug in the call:
--
--     reading the main net failed: nil
--
-- A main net has thousands of item types. Materialising all of them as one Lua table
-- exceeds the MEMORY an OpenComputers computer is allowed, and OC's answer to running
-- out is to hand back nothing -- so the call returns nil rather than raising anything
-- that says "too big". No arrangement of arguments fixes it: the result is the
-- problem, not the request.
--
-- So every read here is FILTERED, and the network is never asked for more than the
-- wants. Two calls do it:
--
--   getItemsInNetwork({ label = ... })   resolve one label to its ITEM ID. Small
--                                        result (only stacks with that label), one
--                                        call per label -- but only ONCE, since an
--                                        item's id does not change.
--   getItemsInNetworkById({ id, ... })   the actual reading: all the wanted ids in a
--                                        single call, every cycle thereafter.
--
-- Which makes the steady-state cost one component call per heavy cycle regardless of
-- how long the want list is, and the startup cost one call per label. The ids are the
-- caller's to keep (see `ids` below) so the resolution is paid for once per run.
--
-- An id here is a stack's `name` -- "minecraft:clay", "gregtech:gt.metaitem.01" -- and
-- GregTech reuses one name across hundreds of items with different damage values. So
-- an id query can return far more than was asked for, and the LABEL is what decides
-- what counts. Same re-check the filtered form needs anyway (localnet.lua and
-- supply.request do it too, for the same reason).
--
-- Returns stock, info:
--   stock  { [label] = count } -- every wanted label, present or not
--   info   { how = "byId" | "byLabel", calls = <component calls made>,
--            found = <labels with any stock>, missing = { <label>, ... },
--            resolved = <ids learned this call>, unresolved = { <label>, ... } }
--          and .error if the network could not be read at all
--
-- A label in `missing` held nothing AND appeared nowhere in the network. AE2 does not
-- list a type it holds none of, so that is usually simply "you have none" -- but it
-- is also exactly what a mistyped label looks like, and the two are worth being able
-- to tell apart on screen. `unresolved` is the stronger signal: a label AE2 has never
-- heard of cannot even be given an id.

-- One call, with the outcome in words rather than as a bare nil: "returned nil" and
-- "errored" are different faults with different fixes.
local function askItems(itf, method, filter)
    if itf[method] == nil then return nil, "not available on this interface" end
    local ok, res = pcall(itf[method], filter)
    if not ok then return nil, "errored (" .. tostring(res) .. ")" end
    -- Some builds wrap a list in an object with getAll(), exactly as the transposers
    -- do for getAllStacks (see transport.lua's readStacks).
    if type(res) == "table" and res.getAll ~= nil then
        local okAll, arr = pcall(res.getAll)
        if okAll and type(arr) == "table" then return arr end
        return nil, "getAll() on the result failed"
    end
    if type(res) ~= "table" then return nil, "returned " .. type(res) end
    return res
end

-- `ids` is caller-owned and carried across cycles: { [label] = <item id> | false }.
--   nil     never looked -- resolved on this call
--   string  known, and read by id from here on
--   false   looked, and the network has never held it. NOT retried, because a
--           misspelled label would otherwise cost a component call every heavy cycle
--           for the life of the run. Clearing the falses is the caller's business
--           (main.lua does it occasionally), which is what lets an item be picked up
--           after it is made for the first time.
function supply.mainStock(itf, labels, ids)
    local want, out, missing, unresolved = {}, {}, {}, {}
    ids = ids or {}
    local n = 0
    for _, l in ipairs(labels or {}) do
        if type(l) == "string" and l ~= "" and not want[l] then want[l] = true; n = n + 1 end
    end
    if n == 0 then
        return out, { how = "none", calls = 0, found = 0, missing = missing,
                      resolved = 0, unresolved = unresolved }
    end

    if not itf or itf.getItemsInNetwork == nil then
        return nil, { calls = 0, found = 0, missing = missing, resolved = 0,
                      unresolved = unresolved,
                      error = "the supply interface cannot list the main net's items"
                          .. " -- it has no getItemsInNetwork" }
    end

    local calls, found, resolved = 0, 0, 0

    local function take(label, size)
        if want[label] then
            -- Summed, not assigned: the same label can appear more than once when the
            -- stacks differ in damage or NBT, and every one of them is stock.
            if out[label] == nil then found = found + 1 end
            out[label] = (out[label] or 0) + (size or 0)
        end
    end

    -- ---- resolve the labels we have no id for yet ----
    -- The filtered result carries the sizes too, so this doubles as the reading for
    -- whatever it resolves and the first cycle needs no second query for them.
    local failure, answered = nil, false
    for label in pairs(want) do
        if ids[label] == nil then
            local items, why = askItems(itf, "getItemsInNetwork", { label = label })
            calls = calls + 1
            if not items then
                failure = failure or ("getItemsInNetwork({label = ...}): " .. why)
            else
                answered = true
                for _, it in ipairs(items) do
                    if type(it) == "table" and it.label == label then
                        if it.name and ids[label] == nil then
                            ids[label] = it.name
                            resolved = resolved + 1
                        end
                        take(label, it.size)
                    end
                end
                if ids[label] == nil then
                    ids[label] = false          -- sought, never held; see the header
                end
            end
        end
        if ids[label] == false then unresolved[#unresolved + 1] = label end
    end

    -- ---- read everything we do have an id for, in one call ----
    local byId, idList = {}, {}
    for label in pairs(want) do
        local id = ids[label]
        -- Only the ones not already read above: those were resolved by a query that
        -- already reported their size. `false` is a label the net has never held.
        if id and id ~= false and out[label] == nil and not byId[id] then
            byId[id] = true
            idList[#idList + 1] = id
        end
    end
    table.sort(idList)

    local how = answered and "byLabel" or "cached"
    if #idList > 0 then
        local items, why = askItems(itf, "getItemsInNetworkById", idList)
        calls = calls + 1
        if items then
            how = "byId"
            for _, it in ipairs(items) do
                -- The id is shared by every damage value of a GregTech meta item, so
                -- the label is what says whether this stack is one of ours.
                if type(it) == "table" and it.label then take(it.label, it.size) end
            end
        else
            -- No id query on this build (or it refused). One call per label instead:
            -- slower, and the only other thing that is safe to ask for.
            failure = failure or ("getItemsInNetworkById: " .. why)
            for label in pairs(want) do
                if out[label] == nil and ids[label] then
                    local one, oneWhy = askItems(itf, "getItemsInNetwork", { label = label })
                    calls = calls + 1
                    if not one then
                        failure = "getItemsInNetwork({label = ...}): " .. oneWhy
                        break
                    end
                    how = "byLabel"
                    for _, it in ipairs(one) do
                        if type(it) == "table" and it.label == label then
                            take(label, it.size)
                        end
                    end
                end
            end
        end
    end

    -- Success is decided PER LABEL, not by whether some query worked. A read that
    -- resolved three wants and then lost the id query for the fourth would otherwise
    -- come back looking complete, with that want reading zero -- and a want that reads
    -- zero is a want the fleet throws everything at.
    --
    -- A label counts as read when it has a figure, or when it is marked `false`: the
    -- network was asked about that one on an earlier cycle and had never held any, so
    -- zero is knowledge rather than a gap.
    local unread = {}
    for label in pairs(want) do
        if out[label] == nil and ids[label] ~= false then unread[#unread + 1] = label end
    end
    if #unread > 0 then
        table.sort(unread)
        return nil, { calls = calls, found = 0, missing = missing, resolved = resolved,
                      unresolved = unresolved,
                      error = "the main net could not be read for "
                          .. table.concat(unread, ", ") .. ": "
                          .. tostring(failure or "no query worked") }
    end

    for label in pairs(want) do
        if out[label] == nil then
            out[label] = 0
            missing[#missing + 1] = label
        end
    end
    table.sort(missing)
    table.sort(unresolved)

    return out, { how = how, calls = calls, found = found, missing = missing,
                  resolved = resolved, unresolved = unresolved,
                  note = failure }
end

-- Litres of plasma a module's input hatch should hold. Expressed in METEORS'
-- worth, so it scales itself with the plasma tier -- 64 meteors is 52,800 L of
-- Helium but only 9,600 L of Plutonium-241, which is the whole point of running a
-- higher tier. A per-plasma litre figure in cfg.supply.hatchLitres overrides it.
function supply.hatchLitres(plasma, cfg)
    cfg = cfg or {}
    -- An absent override falls through to the meteor figure. config.lua lists
    -- every plasma with a nil value, so the key is visible to edit without
    -- meaning anything until a number replaces it.
    local override = cfg.hatchLitres and cfg.hatchLitres[plasma.name]
    if override then return override end
    return (cfg.hatchMeteors or 64) * plasma.consumed
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
--
-- ONE unfiltered sweep, not a filtered query per label. Nine kit patterns of two
-- inputs each meant eighteen queries a cycle, and an OpenComputers component call
-- that is not direct returns on the NEXT TICK -- so that was most of a second
-- spent asking eighteen questions one sweep already answers. This is a dedicated
-- mining subnet holding kits, drones and plasma, so the sweep is small.
function supply.stock(catalog, net)
    local items, fluids = {}, {}
    if not net then return { items = items, fluids = fluids } end

    -- Which labels are worth keeping out of the sweep. Seeding them at zero also
    -- distinguishes "the catalog wants this and the net has none" from "nobody
    -- asked", which is what plan() reads.
    for _, entry in ipairs(catalog) do
        -- Only item-bearing kinds are looked up here; plasma arrives as fluid.
        if entry.kind == "kit" or entry.kind == "drone" then
            for _, i in ipairs(entry.inputs) do
                if items[i.name] == nil then items[i.name] = 0 end
            end
        end
    end

    if next(items) ~= nil then
        local ok, found = pcall(net.getItemsInNetwork)
        if ok and type(found) == "table" then
            for _, it in ipairs(found) do
                local label = it and it.label
                -- Exact match on the label, as the filtered form re-checked: the
                -- sweep reports everything, and only these are ours.
                if label ~= nil and items[label] ~= nil then
                    items[label] = items[label] + (it.size or 0)
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

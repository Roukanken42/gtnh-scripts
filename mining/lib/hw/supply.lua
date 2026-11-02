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
local me = require("lib.hw.me")

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
    -- Since GTNH 2.9 each slot is a full OC item table: `name` is the registry id
    -- ("gregtech:gt.metaitem.02"), `label` the display name and `size` the
    -- amount. 2.8 gave only `name` (the display name) and `count`. Everything
    -- downstream works in display names, so the label wins whenever it is there.
    local function labelOf(s) return s.label or s.name end
    local keys = {}
    for k, s in pairs(list) do
        if type(k) == "number" and type(s) == "table" and labelOf(s) then keys[#keys + 1] = k end
    end
    -- Order by slot index rather than by name: for outputs the first slot is the
    -- primary one, which is the label a craft request has to be made against.
    table.sort(keys)
    for _, k in ipairs(keys) do
        -- The original slot key is kept: storeInterfacePatternInput addresses
        -- inputs by it, and whether it counts from 0 or 1 is not documented.
        local s = list[k]
        out[#out + 1] = { name = labelOf(s), count = s.size or s.count or 0, index = k }
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

-- The name a catalog entry is tracked under everywhere a level is compared with a
-- target: the material for kits, the fluid name for plasma. An entry of any other
-- kind has no target and so no key. plan, the order book and the CPU scan all key
-- on this, which is what lets the three be lined up against each other.
function supply.keyOf(entry)
    if type(entry) ~= "table" then return nil end
    if entry.kind == "kit" then return entry.material end
    if entry.kind == "plasma" then return entry.plasma and entry.plasma.name end
    return nil
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
--   coming     what is already on its way for each key -- either a plain number of
--              units, or a record { units, unknown, why, quiet }. supply.inFlight
--              reads the first two off the main net's crafting CPUs;
--              control.inFlight folds the controller's own outstanding orders in
--              on top, which is what covers a bank this cannot read. Omitting it
--              plans blind, exactly as before.
-- Returns a list of { entry, key, have, target, deficit, coming, crafts }, plus a
-- list of notes for anything that has a target but cannot be acted on.
--
-- ---- WHY `coming` EXISTS -----------------------------------------------------
-- The level in the local net is the only honest measure of what is THERE, and this
-- used to plan on it alone. That is right up until the main net gets busy: the
-- shortfall is real, it is ordered, and the order then sits on a crafting CPU for
-- minutes while the local net goes on reading empty. Every cycle after that reads
-- the same shortfall and orders it AGAIN -- and each order takes another CPU, so
-- the busier the main net gets the harder this pushes on it. It is a feedback loop
-- with the sign the wrong way round, and a fleet that is merely waiting for kits
-- can bury a crafting bank in duplicate jobs for the same kits.
--
-- An earlier version tried to fix this by remembering what had been requested and
-- not yet seen -- and it had to GUESS when an order had arrived, by watching the
-- stock rise. The modules eat kits as fast as they land, so a delivery that was
-- immediately consumed never looked like a delivery, and the phantom order stuck
-- around until it timed out. Guessing was the mistake.
--
-- `coming` is not a guess. It is read off the main net's own crafting CPUs, which
-- is the one place that knows what is genuinely still being made -- and knows it
-- across a controller restart, and about orders this controller never placed.
-- So the comparison here is now
--
--     short by      target - have          what the net is missing
--     minus         coming                 what is already on its way
--     equals        what to order now      which is nothing, in the normal case
--
-- and a rising target still gets served: the difference is ordered, and AE2 merges
-- it into the job already running for that output.
--
-- Hysteresis stays, as pump/main.lua's computeNeedy does it: once a material
-- reaches its target it stays "satisfied" until it drops below lowWater * target,
-- so a slow drain cannot make this ask every cycle. The latch tracks WHAT IS
-- THERE and nothing else -- a craft in flight is not stock, and letting it set the
-- latch would suppress the re-order that a failed craft has to be followed by.
function supply.plan(catalog, stock, cfg, satisfied, coming)
    cfg = cfg or {}
    stock = stock or {}
    satisfied = satisfied or {}
    local lowWater = cfg.lowWater or 0.9
    local work, notes = {}, {}

    -- Units already being made for a key, and whether the amount is unknowable.
    -- A bare number is accepted as well as inFlight's record, so the pure half of
    -- this module can be exercised without one.
    local function onTheWay(key)
        local c = coming and coming[key]
        if type(c) == "number" then return c, false end
        if type(c) == "table" then return c.units or 0, c.unknown == true, c.why, c.quiet end
        return 0, false
    end

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
        local onWay, unknown, why, quiet = onTheWay(key)
        if unknown then
            -- Something is demonstrably being made for this and how much cannot be
            -- read. Waiting is the only safe answer: ordering the whole deficit on
            -- top of an order of unknown size is precisely the runaway this guard is
            -- here to stop.
            --
            -- `quiet` is for the case where the unreadable order is the CONTROLLER'S
            -- OWN and the dashboard is already showing it -- the normal state of a
            -- supply line whose crafting bank has no monitor, and a line of log every
            -- cycle for it would drown everything that matters.
            if not quiet then
                notes[#notes + 1] = key .. ": short " .. deficit .. ", but "
                    .. (why or "a crafting CPU is already making it and will not say how much")
            end
            return
        end
        -- Covered by what is already on its way. Not a note and not a work item:
        -- this is the NORMAL state of a healthy supply line while a craft runs, and
        -- a line of log every cycle for it would drown everything that matters.
        if deficit - onWay <= 0 then return end

        local wanted = math.ceil((deficit - onWay) / perCraft)
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
            -- What is already being made for this key, so a caller can say "1,200
            -- short, 1,024 on the way, ordering the other 176" rather than leaving
            -- the small order looking like a miscalculation.
            coming = onWay,
            -- What one craft delivers, and how many crafts the RESIDUAL asked for:
            -- enough for a caller to say "13 crafts, 3328 kits" rather than just "13".
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

    -- Emptiest first, counting what is on its way as good as arrived: the caps in
    -- control.issue mean this order decides who is served now and who waits, and a
    -- material that is empty BUT ALREADY BEING MADE is not the one in trouble.
    table.sort(work, function(a, b)
        local ra = a.target > 0 and (a.have + (a.coming or 0)) / a.target or 0
        local rb = b.target > 0 and (b.have + (b.coming or 0)) / b.target or 0
        if ra ~= rb then return ra < rb end
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
-- one ME interface (item or fluid, see me.lua) that HAS patterns (the per-module station interfaces in
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
    for _, addr in ipairs(me.interfaces(component)) do
        local p = component.proxy(addr)
        if #supply.readPatterns(p, 4) > 0 then found[#found + 1] = p end
    end
    if #found == 1 then return found[1], stale and "found (" .. stale .. ")" or "found" end
    if #found == 0 then
        return nil, (stale and (stale .. ", and ") or "")
            .. "no ME interface with patterns found -- add an adapter to the "
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

-- Whether `stack` is the item a resolved pattern output names. The WHOLE identity
-- is compared, because a renamed fake output shares its name and damage with the
-- plain item and only the label tells the two apart.
--
-- Both the request and the CPU scan go through this, and they have to: one decides
-- what to ask AE2 for and the other decides whether that thing is already being
-- made, so a difference between them would show up as a restock loop that never
-- recognises its own order.
local function isOutput(want, stack)
    if type(want) ~= "table" or type(stack) ~= "table" then return false end
    if stack.label ~= want.label then return false end
    if want.name ~= nil and stack.name ~= want.name then return false end
    if want.damage ~= nil and stack.damage ~= want.damage then return false end
    return true
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

    -- The filter's matching is not reliably exact, hence the re-check.
    local found
    for _, c in ipairs(list) do
        local okStack, stack = pcall(c.getItemStack)
        if okStack and isOutput(want, stack) then
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

-- ---- what the MAIN net is already making ------------------------------------
--
-- The crafting CPUs, and which of them are busy making something this catalog
-- would otherwise ask for. This is the guard against re-ordering a shortfall that
-- is already being worked on -- see the long note on supply.plan for why that
-- matters and what it used to cost.
--
-- The AECraftingJob handle a request hands back is NOT a substitute for this. It
-- describes ONE request made by THIS run: it says nothing about an order the
-- player placed by hand, or one this controller placed before it was restarted,
-- and it is gone from memory the moment the process is. The CPU is the main net's
-- own record, and it outlives all of that.
--
-- ---- what a CPU can be asked ----
--   getCpus()          -> AECpuMetadata[] { name, busy, storage, coprocessors, cpu }
--                         ONE component call for the whole bank, and `busy` comes
--                         with it -- which is what makes this affordable.
--   cpu.finalOutput()  -> the ItemStack the whole job is FOR, not the sub-craft it
--                         happens to be running. A CPU making the Infinity ingots
--                         that a fake pattern needs still reports the fake
--                         pattern's output, which is exactly the attribution
--                         wanted here. Its `size` is what is LEFT to make, so it
--                         falls towards zero as the job delivers.
--
-- finalOutput is a component call PER BUSY CPU, and a call that is not direct
-- costs a tick. Idle CPUs are skipped on the `busy` flag that came free with the
-- listing, and the caller is expected to run this only on the cycles it actually
-- plans on (main.lua does).
--
-- The documentation warns that finalOutput needs a Crafting Monitor in the CPU
-- multiblock to answer at all. A busy CPU that will not say what it is making is
-- COUNTED AND REPORTED rather than assumed empty -- but it does not block
-- restocking, because a bank with no monitors anywhere would otherwise wedge the
-- supply line permanently, which is worse than the fault being fixed.
--
-- Returns coming, info:
--   coming  { [key] = { units, items, cpus, unknown } } -- only keys being made
--           units    in the units plan compares against: kits, or litres
--           items    the OUTPUT ITEMS still to come, which is what AE2 counts
--           unknown  a matching CPU would not say how much is left
--   info    { cpus, busy, matched, unreadable, blind, error,
--             jobs = { { cpu, label, size, key }, ... } }
--           jobs is one entry per BUSY cpu, in the order the bank reported them,
--           with `key` set only where it matched a catalog entry -- so `stock cpus`
--           shows exactly what the planner saw, rather than re-deriving it and
--           being subtly kinder than the code that matters.
--
-- ---- WHY `blind` EXISTS ------------------------------------------------------
-- An absent key in `coming` used to mean two very different things, and the caller
-- had no way to tell them apart:
--
--     nothing is being made for it            -> order away
--     this read could not find out             -> ordering is a shot in the dark
--
-- The second is not a corner case. finalOutput NEEDS A CRAFTING MONITOR in the CPU
-- multiblock, and a bank without one reports every busy CPU as unreadable -- so the
-- guard reads "nothing coming" for a bank that is flat out making exactly what was
-- just ordered, and the shortfall is ordered again, and again. That is the runaway
-- this whole file exists to prevent, wearing a disguise.
--
-- So `blind` is true whenever this read cannot be trusted to say NO: the bank could
-- not be listed, nothing could be recognised on it, or some busy CPU would not say
-- what it was making. A caller that is blind falls back on its own order book (see
-- control.inFlight) rather than on the absence of evidence.
function supply.inFlight(itf, catalog)
    local coming = {}
    local info = { cpus = 0, busy = 0, matched = 0, unreadable = 0, jobs = {} }

    if not itf or itf.getCpus == nil then
        info.error = "the supply interface cannot list the main net's crafting CPUs"
            .. " -- it has no getCpus"
        info.blind = true
        return coming, info
    end

    -- Only entries whose real output has been resolved can be recognised on a CPU:
    -- what the CPU reports is the item, and for a renamed fake output the pattern
    -- slot's own name is a different item entirely (see resolveOutput). An entry
    -- without one cannot be requested either, so nothing is lost by skipping it.
    local wanted = {}
    for _, e in ipairs(catalog or {}) do
        local key = supply.keyOf(e)
        if key and e.output and e.output.label then
            wanted[#wanted + 1] = { entry = e, key = key, want = e.output }
        end
    end
    if #wanted == 0 then
        info.note = "no catalog entry has a resolved output, so nothing on a CPU"
            .. " could be recognised -- catalog() needs a database"
        info.blind = true
        return coming, info
    end

    local ok, cpus = pcall(itf.getCpus)
    if not ok then
        info.error = "getCpus errored (" .. tostring(cpus) .. ")"
        info.blind = true
        return coming, info
    end
    if type(cpus) ~= "table" then
        info.error = "getCpus returned " .. type(cpus)
        info.blind = true
        return coming, info
    end

    for _, meta in pairs(cpus) do
        if type(meta) == "table" and meta.cpu ~= nil then
            info.cpus = info.cpus + 1
            -- `busy` rides along with the listing, so an idle CPU costs nothing.
            -- Where a build does not report it, ask -- one call, and still cheaper
            -- than reading the output of a CPU that is doing nothing.
            local busy = meta.busy
            if busy == nil then
                local okBusy, b = pcall(meta.cpu.isBusy)
                busy = okBusy and b == true
            end

            if busy then
                info.busy = info.busy + 1
                local seen = { cpu = meta.name }
                info.jobs[#info.jobs + 1] = seen

                local okOut, stack = pcall(meta.cpu.finalOutput)
                if not okOut or type(stack) ~= "table" then
                    info.unreadable = info.unreadable + 1
                else
                    seen.label, seen.size = stack.label, tonumber(stack.size)
                    for _, w in ipairs(wanted) do
                        if isOutput(w.want, stack) then
                            seen.key = w.key
                            local rec = coming[w.key]
                            if not rec then
                                rec = { units = 0, items = 0, cpus = 0, unknown = false }
                                coming[w.key] = rec
                            end
                            rec.cpus = rec.cpus + 1
                            info.matched = info.matched + 1

                            local size = seen.size
                            if size and size > 0 then
                                rec.items = rec.items + size
                                -- Items back into the units the target is set in. One
                                -- craft is worth perCraft of them and produces
                                -- outputCount items, so an output that stacks is
                                -- divided out here rather than being counted as one
                                -- craft apiece.
                                rec.units = rec.units
                                    + size * (w.entry.perCraft or 0)
                                        / math.max(1, w.entry.outputCount or 1)
                            else
                                -- Something IS being made and how much is the one
                                -- thing that cannot be inferred. Marked, so the
                                -- planner waits rather than ordering on top of it.
                                rec.unknown = true
                            end
                            break       -- one CPU makes one thing
                        end
                    end
                end
            end
        end
    end

    -- A busy CPU nobody could read might be making anything, this catalog's keys
    -- included -- so an empty `coming` proves nothing while one exists.
    info.blind = info.unreadable > 0
    return coming, info
end

-- State of a crafting job: "computing" | "done" | "failed" | "canceled".
-- Fake-crafting patterns finish as soon as their inputs are pushed, so this
-- settles quickly -- but it is still polled rather than waited on, so several
-- requests can be in flight together.
--
-- This tracks ONE request, and only until AE2 accepts it. What happens to the
-- goods afterwards is supply.inFlight's question, not this one's.
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

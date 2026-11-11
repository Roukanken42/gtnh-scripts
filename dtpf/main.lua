-- Dimensionally Transcendent Plasma Forge array: passive-recipe controller.
--
-- Active recipes reach the DTPFs from AE on demand and take precedence by
-- themselves. Whenever a DTPF has nothing else to do it pulls a passive recipe
-- from the stocker through two storage buses (items, fluids) and its catalyst
-- from the main net through a third. This script decides WHICH passive recipe
-- that is -- infinity, hypogen, spacetime or shirabon, and with which catalyst
-- -- by setting those three filters, so the array never idles (an idle DTPF
-- loses its running-time discount 100x faster than it earns it).
--
-- Run from this folder:   main
-- Keys: SPACE/P pause (filters left as they are), 1-4 pin a product (in the
--       order of cfg.products), A back to automatic, Q quit.

local event = require("event")
local computer = require("computer")
local keyboard = require("keyboard")

local cfg = require("config")
local R = require("recipes")
local plan = require("plan")
local hwlib = require("hw")
local ui = require("ui")

-- ---- log ----------------------------------------------------------------------

local messages = {}
local function log(msg)
    local line = os.date("%H:%M:%S") .. "  " .. msg
    messages[#messages + 1] = line
    if #messages > 60 then table.remove(messages, 1) end
    if not ui.active then print(line) end
end

local lastOnce = {}
local function logOnce(key, msg)
    if lastOnce[key] ~= msg then
        lastOnce[key] = msg
        if msg then log(msg) end
    end
end

-- ---- config, digested -------------------------------------------------------------

local function set(list)
    local s = {}
    for _, v in ipairs(list or {}) do s[v] = true end
    return s
end

local mats = plan.materials(R.materials, cfg.materials)
local disabled = set(cfg.disabledVariants)
local names, targets = {}, {}
for _, p in ipairs(cfg.products) do
    if not R.variants[p.name] then error("config: unknown product " .. tostring(p.name), 0) end
    if p.priority ~= nil and type(p.priority) ~= "number" then
        error("config: priority of " .. p.name .. " must be a number", 0)
    end
    names[#names + 1] = p.name
    targets[p.name] = { target = p.target or 0, max = p.max, priority = p.priority or 1 }
end
local perProduct = cfg.catalysts.perProduct or {}
local allowedFor = {}
for _, p in ipairs(names) do
    allowedFor[p] = set(perProduct[p] or cfg.catalysts.allowed)
end
local reserve = cfg.catalysts.reserve or {}

-- A typo in a catalyst or variant name would silently disable things; refuse.
do
    local bad = {}
    local function catKey(k, where)
        if k ~= nil and not R.catalystByKey[k] then bad[#bad + 1] = where .. ": unknown catalyst " .. tostring(k) end
    end
    for _, k in ipairs(cfg.catalysts.allowed or {}) do catKey(k, "catalysts.allowed") end
    for p, list in pairs(perProduct) do
        if not R.variants[p] then bad[#bad + 1] = "catalysts.perProduct: unknown product " .. tostring(p) end
        for _, k in ipairs(list) do catKey(k, "catalysts.perProduct." .. tostring(p)) end
    end
    for k in pairs(reserve) do catKey(k, "catalysts.reserve") end
    catKey(cfg.convergence and cfg.convergence.catalystForNoCatalystRecipes, "convergence")
    local ids = {}
    for _, list in pairs(R.variants) do for _, v in ipairs(list) do ids[v.id] = true end end
    for _, id in ipairs(cfg.disabledVariants or {}) do
        if not ids[id] then bad[#bad + 1] = "disabledVariants: unknown variant " .. tostring(id) end
    end
    if #bad > 0 then error("config.lua:\n  " .. table.concat(bad, "\n  "), 0) end
end
local sel = {
    minBatches = cfg.selection.minBatches or 1,
    minDwell = cfg.selection.minDwell or 0,
    switchMargin = cfg.selection.switchMargin or 0,
    keepBusy = cfg.selection.keepBusy ~= false,
}

-- The catalyst key a fluid name/label belongs to, or nil.
local function catalystKeyOf(stack)
    if not stack then return nil end
    local n, l = plan.norm(stack.name), plan.norm(stack.label)
    for _, c in ipairs(R.catalysts) do
        local keys = mats[c.mat].keys
        if keys[n] or keys[l] then return c.key end
    end
    return nil
end

-- ---- hardware ---------------------------------------------------------------------

-- The catalyst bus is found by holding a catalyst in its filter.
local hw, problems = hwlib.init(cfg, function(stack) return catalystKeyOf(stack) ~= nil end)
if not hw then
    io.stderr:write("Hardware not found:\n")
    for _, p in ipairs(problems) do io.stderr:write("  " .. p .. "\n") end
    io.stderr:write("Run `probe` and check config.lua.\n")
    return
end
local dry = cfg.dryRun
local now = computer.uptime

-- ---- state ------------------------------------------------------------------------

local forges = {}         -- latest hw.readForge per DTPF
local stocker, mainnet    -- prepared snapshots
local selection = nil     -- { product, since }
local result = nil        -- the last decision, for the view
local applied = {}        -- { ing = signature, cat = signature } last written
local busCatalyst = nil   -- catalyst key the catalyst bus holds now
local paused = false
local share = {}          -- seconds each product has been selected this session
local lastTick = now()

-- ---- reading ----------------------------------------------------------------------

local function readForges()
    for i, proxy in ipairs(hw.forges) do forges[i] = hwlib.readForge(proxy) end
end

local function readStock()
    local s, err = hw:readStocker()
    if s then
        stocker = plan.prepare(s)
        logOnce("stocker", nil)
    else
        logOnce("stocker", "ERROR " .. tostring(err))
    end
    local m, merr = hw:readMainnet()
    if m then
        mainnet = plan.prepare({ fluids = m, items = {} })
        logOnce("mainnet", nil)
    else
        logOnce("mainnet", "ERROR " .. tostring(merr))
    end
end

-- Coil heat to check against, the worst catalyst multiplier, the Convergence
-- extra, and whether any DTPF has Convergence.
local function arrayState()
    local minHeat, factor, extra, conv, formed = math.huge, nil, 0, false, 0
    for _, f in ipairs(forges) do
        -- A DTPF reporting 0 K is not formed: it can run nothing, so it
        -- neither limits the coils nor the catalyst discount.
        local isFormed = f.heat and f.heat > 0
        if isFormed then
            formed = formed + 1
            minHeat = math.min(minHeat, f.heat)
        end
        if isFormed and f.discount then
            factor = math.max(factor or 0, 1 - f.discount / 100)
        end
        if f.convergence then
            conv = true
            if f.discount and f.discount >= 50 then extra = math.max(extra, f.extra or 0) end
        end
    end
    local heat = cfg.heat
    if heat == "min" or heat == nil then heat = formed > 0 and minHeat or 0 end
    return { heat = heat, catFactor = factor or 1, catExtra = extra, convergence = conv, formed = formed }
end

-- ---- deciding ---------------------------------------------------------------------

local function decide()
    if not stocker or not mainnet then return nil end
    local arr = arrayState()

    local catalysts, catTotal = {}, {}
    for _, c in ipairs(R.catalysts) do
        local have = plan.find(mainnet, mats, { mat = c.mat })
        catTotal[c.key] = have
        catalysts[c.key] = math.max(0, have - (reserve[c.key] or 0))
    end
    local stockOf = {}
    for _, p in ipairs(names) do stockOf[p] = plan.find(mainnet, mats, { mat = p }) end

    local runs, planned, why = {}, {}, {}
    for _, p in ipairs(names) do
        local ctx = {
            mats = mats, stock = stocker, heat = arr.heat, maxEUt = cfg.maxEUt,
            catalysts = catalysts, catFactor = arr.catFactor, catExtra = arr.catExtra,
            allowedCat = allowedFor[p], disabled = disabled, minBatches = sel.minBatches,
        }
        local run, v, check = plan.product(R.variants[p], ctx)
        runs[p], planned[p] = run, v
        if not run then why[p] = check and check.why or "no variant passes heat/config" end
    end

    local demand = plan.demand(names, targets, stockOf, planned)
    local cands = {}
    for _, p in ipairs(names) do
        local d = demand[p]
        cands[p] = { ok = runs[p] ~= nil, fill = d.fill, level = d.level, levelFill = d.levelFill,
            capped = d.capped }
    end
    local pick, pickWhy = plan.choose(selection, cands, names, sel, now())
    return {
        arr = arr, catalysts = catalysts, catTotal = catTotal, demand = demand,
        runs = runs, why = why, pick = pick, pickWhy = pickWhy,
    }
end

-- ---- applying -----------------------------------------------------------------------

-- The filters for a decision. `cat` is the catalyst to put on the catalyst
-- bus, or nil to leave it as it is (a recipe without catalyst, or nothing
-- runnable): that bus is never emptied, see hw.writeCatalyst.
local function filtersFor(res)
    local items, fluids, cat = {}, {}, nil
    local run = res.pick and res.runs[res.pick]
    if not run then return items, fluids, nil end
    for _, s in ipairs(run.items) do items[#items + 1] = hwlib.detailOf(s, "item") end
    for _, s in ipairs(run.fluids) do fluids[#fluids + 1] = hwlib.detailOf(s, "fluid") end
    local key = run.catalyst
    if not key and res.arr.convergence then
        key = cfg.convergence.catalystForNoCatalystRecipes
        if key and (res.catalysts[key] or 0) <= 0 then key = nil end
    end
    if key then
        local _, stack = plan.find(mainnet, mats, { mat = R.catalystByKey[key].mat })
        if stack then cat = hwlib.detailOf(stack, "fluid") end
    end
    return items, fluids, cat
end

local function signature(list)
    local l = {}
    for _, d in ipairs(list) do l[#l + 1] = d.name .. ":" .. tostring(d.damage or "") end
    return table.concat(l, ",")
end

local function describe(list)
    local l = {}
    for _, d in ipairs(list) do l[#l + 1] = d.name .. (d.damage and d.damage ~= 0 and ("@" .. d.damage) or "") end
    return #l > 0 and table.concat(l, ", ") or "(blocked)"
end

-- Writes the filters of a decision.
--   ingredients changed: block both stocker buses, set the catalyst, then
--     write the new ingredients. While they appear one by one, nothing can
--     match but the intended variant: no two passive variants with the same
--     catalyst have inputs that are a subset of one another.
--   only the catalyst changed (hyp_v3 -> hyp_v4 use the same inputs): one
--     write into slot 1 of the catalyst bus switches the variant.
-- The catalyst bus is never blocked or emptied: it is on the main net.
local function apply(res)
    local items, fluids, cat = filtersFor(res)
    local ing = signature(items) .. " | " .. signature(fluids)
    local catSig = cat and signature({ cat }) or nil
    local ingChanged = ing ~= applied.ing
    local catChanged = catSig ~= nil and catSig ~= applied.cat
    if not ingChanged and not catChanged then return end
    if dry then
        if ingChanged then
            log("[dry] items: " .. describe(items))
            log("[dry] fluids: " .. describe(fluids))
        end
        if catChanged then log("[dry] catalyst: " .. cat.name) end
        applied.ing = ing
        if catSig then applied.cat, busCatalyst = catSig, catalystKeyOf(cat) end
        return
    end
    local b, block = hw.buses, cfg.blocker
    local function write(bus, list, blocker, label)
        local n, err = hwlib.writeFilter(bus, list, blocker)
        if not n then log("ERROR writing the " .. label .. " bus filter: " .. tostring(err)) end
        return n
    end
    if ingChanged then
        applied.ing = nil
        if not write(b.items, {}, block.item, "item") then return end
        if not write(b.fluids, {}, block.fluid, "fluid") then return end
    end
    if catChanged then
        local ok, err = hwlib.writeCatalyst(b.catalyst, cat)
        if not ok then
            -- A failed write leaves the old catalyst in place. Keep the
            -- ingredients blocked: they may need the catalyst we wanted.
            log("ERROR writing the catalyst bus filter: " .. tostring(err))
            applied.cat = nil
            return
        end
        applied.cat, busCatalyst = catSig, catalystKeyOf(cat)
    end
    if ingChanged then
        if not write(b.items, items, block.item, "item") then return end
        if not write(b.fluids, fluids, block.fluid, "fluid") then return end
        applied.ing = ing
    end
end

local function step()
    local res = decide()
    if not res then return end
    result = res
    if paused then return end
    local prev = selection and selection.product
    if res.pick ~= prev then
        if res.pick then
            local run = res.runs[res.pick]
            log(string.format("Making %s (%s%s): %s.", res.pick, run.variant.id,
                run.catalyst and (", " .. run.catalyst) or "", res.pickWhy))
            selection = { product = res.pick, since = now(), variant = run.variant.id }
        else
            log("Nothing is runnable: ingredient filters blocked, catalyst left as it is. "
                .. res.pickWhy .. ".")
            selection = nil
        end
    elseif res.pick and res.runs[res.pick].variant.id ~= selection.variant then
        local run = res.runs[res.pick]
        log(string.format("%s: switching to %s%s.", res.pick, run.variant.id,
            run.catalyst and (" (" .. run.catalyst .. ")") or ""))
        selection.variant = run.variant.id
    end
    logOnce("heat", res.arr.formed == 0 and "WARN: no formed DTPF reports a coil heat." or nil)
    apply(res)
end

-- ---- view ------------------------------------------------------------------------------

local function buildView()
    local products = {}
    if result then
        for i, p in ipairs(names) do
            local d, run = result.demand[p], result.runs[p]
            products[#products + 1] = {
                key = i, name = p, stock = d.stock, target = d.target, effective = d.effective,
                priority = d.priority, level = d.level, levelFill = d.levelFill,
                fill = d.fill, capped = d.capped, selected = selection and selection.product == p,
                variant = run and run.variant.id, catalyst = run and run.catalyst,
                batches = run and run.batches, why = result.why[p], share = share[p] or 0,
            }
        end
    end
    local cats = {}
    if result then
        for _, c in ipairs(R.catalysts) do
            cats[#cats + 1] = { key = c.key, total = result.catTotal[c.key] or 0, reserve = reserve[c.key] or 0 }
        end
    end
    return {
        dryRun = dry, paused = paused, pin = sel.pin, clock = os.date("%H:%M:%S"),
        forges = forges, arr = result and result.arr, products = products, catalysts = cats,
        pick = result and result.pick, pickWhy = result and result.pickWhy, messages = messages,
        busCatalyst = busCatalyst,
    }
end

-- ---- startup -------------------------------------------------------------------------

local function startup()
    for _, line in ipairs(hw:describe()) do log(line) end

    -- The catalyst bus must already hold a catalyst: with an empty filter it
    -- exposes the whole main net. It is only read here, never blocked, so the
    -- script needs that to be true from the start. (If the bus was found
    -- automatically, it was found by exactly this.)
    local slots = hwlib.readBus(hw.buses.catalyst)
    local filled, others = 0, false
    for slot = 1, hw.buses.catalyst.slots do
        local v = slots[slot]
        if v then
            filled = filled + 1
            local key = catalystKeyOf(v)
            if key then
                busCatalyst = busCatalyst or key
            else
                others = true
                log("WARN: catalyst bus slot " .. slot .. " holds " .. tostring(v.label or v.name)
                    .. ", which the main net now exposes. It is cleared on the first catalyst change.")
            end
        end
    end
    if not busCatalyst then
        log("FAULT: the catalyst bus filter holds no catalyst. The main net may be exposed to the DTPFs.")
        log("Put a catalyst into that bus's filter by hand, then start again.")
        return false
    end
    -- Exactly one catalyst in slot 1: that is what was "last written".
    -- Otherwise the first catalyst write puts one into slot 1 and then clears
    -- the rest; the filter is never empty on the way.
    local tidy = filled == 1 and slots[1] ~= nil and not others
    applied.cat = tidy and signature({ hwlib.detailOf(slots[1], "fluid") }) or nil
    log("Catalyst bus holds " .. busCatalyst .. (tidy and "" or " (among other slots)") .. ".")
    if dry then return true end

    -- The stocker's fluid bus must really keep a fluid filter. Start the
    -- stocker buses blocked: the first decision opens them.
    local ok, err = hwlib.verifyBus(hw.buses.fluids, cfg.blocker.fluid)
    if not ok then
        log("FAULT: the fluid bus does not take a fluid filter: " .. tostring(err))
        log("Put it on its own cable block, away from item storage buses (README, Hardware).")
        return false
    end
    local n, werr = hwlib.writeFilter(hw.buses.items, {}, cfg.blocker.item)
    if not n then
        log("FAULT: cannot write the item bus filter: " .. tostring(werr))
        return false
    end
    return true
end

-- ---- main loop -------------------------------------------------------------------------

local function loop()
    local nextForges, nextStock, nextRender = 0, 0, 0
    while true do
        local ev = { event.pull(0.25) }
        if ev[1] == "key_down" then
            local code, char = ev[4], ev[3]
            if code == keyboard.keys.space or code == keyboard.keys.p then
                paused = not paused
                log(paused and "PAUSED: filters left as they are." or "Resumed.")
            elseif code == keyboard.keys.q then
                return
            elseif code == keyboard.keys.a then
                sel.pin = nil
                log("Automatic selection.")
                nextStock = 0
            elseif char and char >= 49 and char <= 57 then
                local p = names[char - 48]
                if p then
                    sel.pin = p
                    log("Pinned to " .. p .. " (A for automatic).")
                    nextStock = 0
                end
            end
        end

        local t = now()
        if selection and not paused then
            share[selection.product] = (share[selection.product] or 0) + (t - lastTick)
        end
        lastTick = t
        if t >= nextForges then
            nextForges = t + cfg.timing.machines
            readForges()
        end
        if t >= nextStock then
            nextStock = t + cfg.timing.stock
            readStock()
            step()
        end
        if ui.active and t >= nextRender then
            nextRender = t + 1
            ui.render(buildView())
        end
    end
end

local uiActive = cfg.ui ~= false and ui.init()
log("DTPF controller starting" .. (dry and " [DRY RUN: no filter is written]" or "") .. ".")
if not startup() then
    if uiActive then
        ui.render(buildView())
        os.sleep(5)
        ui.shutdown()
        for _, m in ipairs(messages) do print(m) end
    end
    return
end
log("SPACE/P pause, 1-" .. #names .. " pin, A auto, Q quit.")
readForges()
if uiActive then ui.render(buildView()) end

local ok, err = pcall(loop)
-- The filters are left as they are on exit: the DTPFs keep making the last
-- pick while its inputs last, which beats idling.
ui.shutdown()
print("DTPF controller stopped; the storage bus filters are left as they were.")
if not ok then error(err, 0) end

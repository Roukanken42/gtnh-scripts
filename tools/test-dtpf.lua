-- Off-machine tests for dtpf/: the planner, the sensor parser and the filter
-- writer. Run from the repo root:   lua tools/test-dtpf.lua

package.path = "dtpf/?.lua;" .. package.path
-- hw.lua requires `component` at load; the tested functions never use it.
package.preload.component = function() return {} end

local R = require("recipes")
local plan = require("plan")
local hw = require("hw")

local failures, count = 0, 0
local function check(cond, msg)
    count = count + 1
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end
local function eq(a, b, msg) check(a == b, string.format("%s: expected %s, got %s", msg, tostring(b), tostring(a))) end

-- ---- norm -------------------------------------------------------------------------
eq(plan.norm("Molten Infinity"), "infinity", "norm label")
eq(plan.norm("molten.infinity"), "infinity", "norm name")
eq(plan.norm("Molten Cosmic Neutronium"), "cosmicneutronium", "norm keeps cosmic")
eq(plan.norm("\194\167aHypervisor Matrix (Fusion)\194\167r"), "hypervisormatrixfusion", "norm colour + brackets")

local mats = plan.materials(R.materials, { precious = { "molten.pma" } })
check(mats.precious.keys["pma"], "extra material keys merge")

-- ---- a stocker ----------------------------------------------------------------------
local function item(label, size, damage, name)
    return { name = name or ("mod:" .. plan.norm(label)), label = label, size = size, damage = damage or 0 }
end
local function fluid(label, amount, name)
    return { name = name or ("molten." .. plan.norm(label)), label = label, amount = amount }
end

local stock = plan.prepare({
    items = {
        item("Infinity Catalyst", 40, 5, "Avaritia:Resource"),
        item("Programmed Circuit", 1, 4, "gregtech:gt.integrated_circuit"),
        item("Programmed Circuit", 1, 5, "gregtech:gt.integrated_circuit"),
        item("Hypervisor Matrix (Fusion)", 1, 100),
        item("Energised Tesseract", 3),
        item("Hi-Computation Station Mk-V Finaltype", 1, 4),
    },
    fluids = {
        fluid("Molten Infinity", 100000),
        fluid("Molten Neutronium", 50000),
        fluid("Molten Cosmic Neutronium", 999999),
        fluid("Molten Quantum", 50000),
        fluid("Molten Hypogen", 2000),
        fluid("Dimensionally Transcendent Residue", 12000, "dimensionallytranscendentresidue"),
        fluid("Molten SpaceTime", 1000),
        fluid("Molten Metastable Oganesson", 5000),
        fluid("Molten Precious Metals Alloy", 5000),
        fluid("Molten Glass", 300000, "molten.glass"),
    },
})

local n = plan.find(stock, mats, { mat = "neutronium" })
eq(n, 50000, "neutronium is not cosmic neutronium")
local c4 = plan.find(stock, mats, { mat = "circuit", damage = 4 })
local c3 = plan.find(stock, mats, { mat = "circuit", damage = 3 })
eq(c4, 1, "circuit 4 present")
eq(c3, 0, "circuit 3 absent")

local function ctx(over)
    local c = {
        mats = mats, stock = stock, heat = 13500, catalysts = { stellar = 50000, exotic = 50000,
        resplendent = 100000, prosaic = 5000 }, catFactor = 1, catExtra = 0,
        allowedCat = { prosaic = true, resplendent = true, exotic = true, stellar = true },
        disabled = {}, minBatches = 1,
    }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

-- infinity: no combs, so the comb variant is skipped and t5 runs
local run, planned = plan.product(R.variants.infinity, ctx())
eq(run and run.variant.id, "inf_t5", "infinity picks t5 without combs")
eq(planned.id, "inf_t5", "infinity plans with the best allowed variant that is not an extra")
eq(run.batches, 4, "40 catalysts / 4 per batch, stellar 50000 / 11373")
eq(#run.items, 2, "infinity filter: catalyst item + circuit")
eq(run.catalyst, "stellar", "infinity catalyst")

-- low stellar: falls to exotic t4
run = plan.product(R.variants.infinity, ctx({ catalysts = { stellar = 100, exotic = 50000 } }))
eq(run and run.variant.id, "inf_t4", "infinity falls back to exotic")

-- discount halves the catalyst needed
run = plan.product(R.variants.infinity, ctx({ catalysts = { stellar = 6000 }, catFactor = 0.5 }))
eq(run and run.variant.id, "inf_t5", "50% discount lets 6000 L run a 11373 L recipe")

-- hypogen coils: no eternal variant, no comb, t3.5 needs circuit 5
run = plan.product(R.variants.infinity, ctx({ heat = 12600 }))
eq(run and run.variant.id, "inf_t35", "hypogen coils run t3.5")

-- hypogen: v4 (stellar, hypervisor, 11520 neutronium) -> stocker has 50000
run = plan.product(R.variants.hypogen, ctx())
eq(run and run.variant.id, "hyp_v4", "hypogen v4")
eq(#run.fluids, 3, "hypogen fluids: neutronium, quantum, infinity")
eq(#run.items, 1, "hypogen item: hypervisor")

-- spacetime v2 needs 5000 residue: 12000 -> 2 batches
run = plan.product(R.variants.spacetime, ctx())
eq(run and run.variant.id, "st_v2", "spacetime v2")
eq(run.batches, 2, "spacetime batches limited by residue")
check(run.catalyst == nil, "spacetime takes no catalyst")

-- shirabon
run = plan.product(R.variants.shirabon, ctx())
eq(run and run.variant.id, "sh_v1", "shirabon runs")
run, planned = plan.product(R.variants.shirabon, ctx({ heat = 12600 }))
check(run == nil and planned == nil, "shirabon needs eternal coils")

-- allowed catalysts
run = plan.product(R.variants.hypogen, ctx({ allowedCat = { resplendent = true } }))
eq(run and run.variant.id, "hyp_v2", "hypogen limited to resplendent")

-- ---- residue ------------------------------------------------------------------------
-- The data: residue = catalyst x 2^(tier-1) / 8 for every variant, floored.
local ids = {}
for p, list in pairs(R.variants) do
    for _, v in ipairs(list) do
        if v.catalyst then
            local tier = R.catalystByKey[v.catalyst].tier
            eq(v.outputs.residue, math.floor(v.catalystAmount * 2 ^ (tier - 1) / 8),
                p .. " " .. v.id .. " residue matches its catalyst")
        end
        ids[v.id] = true
    end
end
check(not ids.inf_t3 and not ids.inf_t3_comb, "the Awakened-coil infinity recipe is gone")
check(R.retired.inf_t3, "inf_t3 still accepted in an old config")
local function variantById(p, id)
    for _, v in ipairs(R.variants[p]) do if v.id == id then return v end end
end
check(variantById("residue", "inf_t35") == variantById("infinity", "inf_t35"), "residue's inf_t35 is infinity's")

-- Chromatic glass before inf_t3.5. The stocker has glass, Infinity Catalyst
-- and circuit 5; crude is not allowed here and prosaic 5000 < 61059, so
-- resplendent glass.
run, planned = plan.product(R.variants.residue, ctx())
eq(run and run.variant.id, "cg_t3", "residue runs chromatic glass before inf_t35")
eq(planned.id, "cg_t2", "residue planned with the first allowed tier")
eq(#run.fluids, 1, "chromatic glass filter: glass only")
eq(#run.items, 0, "chromatic glass filter: no items")
-- Crude allowed: the most residue per unit of catalyst energy.
local withCrude = { crude = true, prosaic = true, resplendent = true, exotic = true, stellar = true }
run = plan.product(R.variants.residue, ctx({ allowedCat = withCrude, catalysts = { crude = 1e6, resplendent = 1e5 } }))
eq(run and run.variant.id, "cg_t1", "crude first when allowed")
-- No glass: inf_t3.5, while infinity itself keeps its best variant.
run = plan.product(R.variants.residue, ctx({ stock = plan.prepare({ items = stock.items, fluids = {} }) }))
eq(run and run.variant.id, "inf_t35", "no glass: residue runs inf_t35")
eq((plan.product(R.variants.infinity, ctx())).variant.id, "inf_t5", "infinity keeps inf_t5")
-- No Infinity Catalyst either way: the glass tiers.
local noIC = plan.prepare({ items = {}, fluids = { fluid("Molten Glass", 300000, "molten.glass") } })
run = plan.product(R.variants.residue, ctx({ stock = noIC, catalysts = { prosaic = 100000, resplendent = 100000 } }))
eq(run and run.variant.id, "cg_t2", "prosaic first: the most residue per catalyst energy")
run = plan.product(R.variants.residue, ctx({ stock = noIC, catalysts = { crude = 1e9, exotic = 100000 } }))
eq(run and run.variant.id, "cg_t4", "crude not allowed: exotic")
-- Not enough glass for a resplendent batch (147456 L): prosaic's 73728 L fits.
local lowGlass = plan.prepare({ items = {}, fluids = { fluid("Molten Glass", 100000, "molten.glass") } })
run = plan.product(R.variants.residue, ctx({ stock = lowGlass, catalysts = { prosaic = 100000, resplendent = 100000 } }))
eq(run and run.variant.id, "cg_t2", "glass for a prosaic batch only")
run = plan.product(R.variants.residue, ctx({ stock = lowGlass, catalysts = { resplendent = 100000 } }))
check(run == nil, "no batch of glass for resplendent")

-- ---- a real stocker (probe output, GTNH 2.9) ----------------------------------------
-- 2.9 labels circuits "Programmed Circuit 4": they must match by registry name.
local real = plan.prepare({
    items = {
        { name = "gregtech:gt.integrated_circuit", damage = 4, label = "Programmed Circuit 4", size = 1 },
        { name = "Avaritia:Resource", damage = 5, label = "Infinity Catalyst", size = 2048 },
        { name = "gregtech:gt.metaitem.01", damage = 32417, label = "Energised Tesseract", size = 1024 },
    },
    fluids = {
        { name = "molten.infinity", label = "Molten Infinity", amount = 737488 },
        { name = "molten.quantum", label = "Molten Quantum", amount = 1658880 },
        { name = "molten.neutronium", label = "Molten Neutronium", amount = 3319004 },
        { name = "dimensionallytranscendentresidue", label = "Dimensionally Transcendent Residue", amount = 5120000 },
    },
})
eq((plan.find(real, mats, { mat = "circuit", damage = 4 })), 1, "2.9 circuit label matches by name")
eq((plan.find(real, mats, { mat = "circuit", damage = 5 })), 0, "circuit number still checked")
-- main net: no stellar; exotic, resplendent, prosaic, crude plentiful; 50 % discount
local realCtx = ctx({ stock = real, heat = 13501, catFactor = 0.5,
    catalysts = { exotic = 201054802, resplendent = 200046520, prosaic = 54362609, crude = 81503000 } })
run = plan.product(R.variants.infinity, realCtx)
eq(run and run.variant.id, "inf_t4", "real: infinity on exotic")
eq(#run.items, 2, "real: infinity filter is catalyst item + circuit 4")
eq(run.catalystNeed, 13122, "real: 26243 L exotic at 50 % discount")
run = plan.product(R.variants.hypogen, realCtx)
eq(run and run.variant.id, "hyp_v2", "real: no Hypervisor Matrix, hypogen falls to v2")
local _, _, stCheck = plan.product(R.variants.spacetime, realCtx)
run = plan.product(R.variants.spacetime, realCtx)
check(run == nil, "real: spacetime not runnable")
eq(stCheck.why, "stocker has no hypervisor", "real: spacetime blocked on the Hypervisor Matrix")
check(plan.product(R.variants.shirabon, realCtx) == nil, "real: shirabon not runnable")

-- The same stocker with the circuit unrecognised (what a 2.8 key did to the
-- 2.9 label): the explanation must name the circuit, not the optional comb.
local noCircuit = plan.prepare({ items = { real.items[2], real.items[3] }, fluids = real.fluids })
local r2, _, explain, all = plan.product(R.variants.infinity, ctx({ stock = noCircuit, heat = 13501,
    catFactor = 0.5, catalysts = realCtx.catalysts }))
check(r2 == nil, "no circuit: infinity cannot run")
eq(explain.variant.id, "inf_t4", "explained by the closest non-comb variant")
eq(explain.why, "stocker has no circuit 4", "names the circuit and its number")
eq(#all, #R.variants.infinity, "every variant checked")
check(all[1].why:find("infinityComb", 1, true) and all[1].why:find("stellar", 1, true),
    "a check lists all its problems: " .. tostring(all[1].why))

-- ---- demand -------------------------------------------------------------------------
local names = { "shirabon", "spacetime", "hypogen", "infinity" }
local plannedMap = {
    shirabon = R.variants.shirabon[1], spacetime = R.variants.spacetime[1],
    hypogen = R.variants.hypogen[1], infinity = R.variants.infinity[2],
}
local order = plan.topo(names, plannedMap)
eq(table.concat(order, ","), "shirabon,spacetime,hypogen,infinity", "topological order")
order = plan.topo({ "infinity", "hypogen", "spacetime", "shirabon" }, plannedMap)
local pos = {}
for i, p in ipairs(order) do pos[p] = i end
check(pos.shirabon < pos.spacetime and pos.spacetime < pos.infinity and pos.hypogen < pos.infinity,
    "consumers before producers whatever the config order: " .. table.concat(order, ","))

local targets = {
    shirabon = { target = 1440 }, spacetime = { target = 1000 },
    hypogen = { target = 0 }, infinity = { target = 10000, max = 50000 },
}
local d = plan.demand(names, targets, { shirabon = 0, spacetime = 1000, hypogen = 0, infinity = 60000 }, plannedMap)
eq(d.shirabon.short, 1440, "shirabon short")
eq(d.spacetime.downstream, 2880, "10 shirabon batches eat 2880 spacetime")
eq(d.spacetime.short, 2880, "spacetime short by its downstream need")
-- 2880 / 576 = 5 spacetime batches x 1152 infinity
eq(d.infinity.downstream, 5760, "spacetime shortfall pulls infinity")
eq(d.hypogen.downstream, 0, "st_v2 needs no hypogen")
eq(d.hypogen.fill, math.huge, "no hypogen wanted")
check(d.infinity.capped, "infinity over its max")

-- Residue: spacetime and shirabon pass their shortfall on to it.
local rnames = { "shirabon", "spacetime", "hypogen", "residue", "infinity" }
plannedMap.residue = variantById("residue", "cg_t2")
order = plan.topo({ "residue", "infinity", "hypogen", "spacetime", "shirabon" }, plannedMap)
pos = {}
for i, p in ipairs(order) do pos[p] = i end
check(pos.shirabon < pos.residue and pos.spacetime < pos.residue, "residue after its consumers: "
    .. table.concat(order, ","))
targets.residue = { target = 20000, priority = 2 }
d = plan.demand(rnames, targets, { shirabon = 0, spacetime = 1000, residue = 10000, infinity = 60000 }, plannedMap)
-- 10 shirabon batches x 5000 + 5 spacetime batches x 5000
eq(d.residue.downstream, 75000, "residue inherits shirabon's and spacetime's shortfall")
eq(d.residue.effective, 95000, "residue: own target + inherited")
eq(d.residue.short, 85000, "residue short")
plannedMap.residue, targets.residue = nil, nil

-- ---- priorities ---------------------------------------------------------------------
local sel = { minDwell = 60, switchMargin = 0.05, keepBusy = true }
-- Infinity at priority 1 (an extra source), spacetime at 2. Spacetime is 50k
-- short: 50000 / 576 batches x 1152 = 100000 L of infinity, asked at priority 2.
local ptargets = {
    shirabon = { target = 0 }, hypogen = { target = 0 },
    spacetime = { target = 100000, priority = 2 }, infinity = { target = 1000000, priority = 1 },
}
d = plan.demand(names, ptargets, { spacetime = 50000, infinity = 100000 }, plannedMap)
eq(#d.infinity.layers, 2, "infinity has two layers")
eq(d.infinity.layers[1].priority, 2, "inherited layer first")
eq(math.floor(d.infinity.layers[1].amount + 0.5), 100000, "inherited layer size")
eq(d.infinity.level, 1, "stock covers the priority-2 layer, own target is the uncovered one")
eq(d.spacetime.level, 2, "spacetime short at its priority")
local function cand(x, ok) return { ok = ok ~= false, fill = x.fill, level = x.level, levelFill = x.levelFill } end
local pc = { spacetime = cand(d.spacetime), infinity = cand(d.infinity),
    shirabon = cand(d.shirabon, false), hypogen = cand(d.hypogen, false) }
check(d.infinity.fill < d.spacetime.fill, "infinity has the lower overall fill...")
eq((plan.choose(nil, pc, names, sel, 0)), "spacetime", "...but spacetime's priority wins")

-- Infinity too low to feed spacetime: its priority-2 layer is 30% covered,
-- spacetime's is 50%, so infinity is made, at spacetime's priority.
d = plan.demand(names, ptargets, { spacetime = 50000, infinity = 30000 }, plannedMap)
eq(d.infinity.level, 2, "infinity short at the inherited priority")
pc = { spacetime = cand(d.spacetime), infinity = cand(d.infinity),
    shirabon = cand(d.shirabon, false), hypogen = cand(d.hypogen, false) }
local why
pc.pick, why = plan.choose(nil, pc, names, sel, 0)
eq(pc.pick, "infinity", "infinity made to feed spacetime")
check(why:find("priority 2", 1, true) ~= nil, "why names the priority: " .. tostring(why))

-- Spacetime not runnable: infinity's own low-priority target is worked on.
d = plan.demand(names, ptargets, { spacetime = 50000, infinity = 100000 }, plannedMap)
pc = { spacetime = cand(d.spacetime, false), infinity = cand(d.infinity),
    shirabon = cand(d.shirabon, false), hypogen = cand(d.hypogen, false) }
eq((plan.choose(nil, pc, names, sel, 0)), "infinity", "low priority runs when nothing else can")

-- A higher priority need takes over after the dwell even with a worse fill.
d = plan.demand(names, ptargets, { spacetime = 99000, infinity = 100000 }, plannedMap)
pc = { spacetime = cand(d.spacetime), infinity = cand(d.infinity),
    shirabon = cand(d.shirabon, false), hypogen = cand(d.hypogen, false) }
eq((plan.choose({ product = "infinity", since = 0 }, pc, names, sel, 100)), "spacetime",
    "priority beats the margin")

-- Everything covered: overall fill decides.
d = plan.demand(names, ptargets, { spacetime = 200000, infinity = 1500000 }, plannedMap)
check(d.spacetime.level == nil and d.infinity.level == nil, "all layers covered")
pc = { spacetime = cand(d.spacetime), infinity = cand(d.infinity),
    shirabon = cand(d.shirabon, false), hypogen = cand(d.hypogen, false) }
eq((plan.choose(nil, pc, names, sel, 0)), "infinity", "1.5 < 2.0 overall fill")

-- ---- choose -------------------------------------------------------------------------
local sel = { minDwell = 60, switchMargin = 0.05, keepBusy = true }
local cands = {
    shirabon = { ok = false, fill = 0 }, spacetime = { ok = true, fill = 0.3 },
    hypogen = { ok = true, fill = 0.5 }, infinity = { ok = true, fill = 0.1, capped = true },
}
eq((plan.choose(nil, cands, names, sel, 0)), "spacetime", "lowest runnable uncapped fill")
eq((plan.choose({ product = "hypogen", since = 0 }, cands, names, sel, 10)), "hypogen", "min dwell holds")
eq((plan.choose({ product = "hypogen", since = 0 }, cands, names, sel, 100)), "spacetime", "switch after dwell")
cands.spacetime.fill = 0.48
eq((plan.choose({ product = "hypogen", since = 0 }, cands, names, sel, 100)), "hypogen", "within margin stays")
cands.spacetime.ok, cands.hypogen.ok = false, false
eq((plan.choose(nil, cands, names, sel, 0)), "infinity", "keep busy with a capped product")
eq((plan.choose(nil, cands, names, { keepBusy = false }, 0)), nil, "no keep busy: nothing")
cands.hypogen.ok = true
eq((plan.choose(nil, cands, names, { pin = "hypogen" }, 0)), "hypogen", "pin")
eq((plan.choose({ product = "spacetime", since = 0 }, cands, names, sel, 1)), "hypogen", "unrunnable current is left")

-- ---- switching safety -----------------------------------------------------------------
-- The circuit goes in last.
local wo = plan.writeOrder(R.variants.infinity[2])
eq(wo[#wo].mat, "circuit", "inf_t5 writes its circuit last")
wo = plan.writeOrder(R.variants.hypogen[1])
eq(wo[#wo].mat, "hypervisor", "hyp_v4 writes the Hypervisor Matrix last")
run = plan.product(R.variants.infinity, ctx())
eq(run.items[#run.items].name, "gregtech:gt.integrated_circuit", "the checked filter list ends with the circuit")

local function expSig(e)
    local l = {}
    for _, list in ipairs({ e.items, e.fluids }) do
        for _, s in ipairs(list) do l[#l + 1] = s.mat .. ":" .. tostring(s.damage) end
        l[#l + 1] = "|"
    end
    return table.concat(l, ",")
end
-- One switch, as apply() makes it. Returns the offending recipe and state.
local function switch(old, oldCat, new, newCat)
    local from = plan.exposure(old, mats, oldCat)
    local to = plan.exposure(new, mats, newCat)
    local ingChanged = expSig(from) ~= expSig(to)
    local catChanged = newCat ~= nil and newCat ~= oldCat
    local states = plan.transition(from, to, ingChanged, catChanged)
    local allowed = {}
    if old then allowed[old] = true end
    if new then allowed[new] = true end
    return plan.hazard(states, R.all, allowed)
end

-- The case asked about: residue (inf_t3.5) <-> infinity (inf_t5). Never
-- circuit 4 + Infinity Catalyst with resplendent, nor circuit 5 with stellar.
local t5, t35 = variantById("infinity", "inf_t5"), variantById("residue", "inf_t35")
check(switch(t5, "stellar", t35, "resplendent") == nil, "inf_t5 -> inf_t35 is safe")
check(switch(t35, "resplendent", t5, "stellar") == nil, "inf_t35 -> inf_t5 is safe")
do
    local from, to = plan.exposure(t5, mats, "stellar"), plan.exposure(t35, mats, "resplendent")
    local states = plan.transition(from, to, true, true)
    for i, st in ipairs(states) do
        local hasC4 = false
        for _, s in ipairs(st.items) do if s.mat == "circuit" and s.damage == 4 then hasC4 = true end end
        check(not (hasC4 and st.cats.resplendent), "state " .. i .. " never has circuit 4 with resplendent: "
            .. plan.describeState(st))
    end
    -- The checker itself: swapping only the catalyst under inf_t5's inputs
    -- would complete the in-game Awakened-coil recipe, and must be caught.
    local bad = plan.hazard(plan.transition(from, plan.exposure(t5, mats, "resplendent"), false, true),
        R.all, { [t5] = true })
    eq(bad and bad.id, "inf_t3 (in-game)", "a catalyst-only swap to resplendent under circuit 4 is caught")
    -- Writing the circuit first, with the old catalyst still on the bus: caught too.
    local early = { { items = { { mat = "infinityCatalyst" }, { mat = "circuit", damage = 4 } }, fluids = {},
        cats = { stellar = true } } }
    bad = plan.hazard(early, R.all, { [t35] = true })
    eq(bad and bad.id, "inf_t5", "circuit 4 + Infinity Catalyst + stellar is caught when inf_t35 is wanted")
end

-- Every switch the controller can make: from any variant (or blocked) with
-- any catalyst on the bus, to any variant with its catalyst (or, for one
-- without, the bus left as it is or the Convergence catalyst).
local keys = {}
for _, c in ipairs(R.catalysts) do keys[#keys + 1] = c.key end
local olds = { false }
for _, v in ipairs(R.all) do if v.catalystAmount or v.outputs then olds[#olds + 1] = v end end
local news = { false }
for _, v in ipairs(R.all) do if v.outputs then news[#news + 1] = v end end
local switches, unsafe = 0, {}
for _, old in ipairs(olds) do
    old = old or nil
    local oldCats = (old and old.catalyst) and { old.catalyst } or keys
    for _, oldCat in ipairs(oldCats) do
        for _, new in ipairs(news) do
            new = new or nil
            local newCats = (new and new.catalyst) and { new.catalyst } or { false, table.unpack(keys) }
            for _, newCat in ipairs(newCats) do
                switches = switches + 1
                local bad, st = switch(old, oldCat, new, newCat or nil)
                if bad and #unsafe < 10 then
                    unsafe[#unsafe + 1] = string.format("%s(%s) -> %s(%s): %s completes %s",
                        old and old.id or "blocked", oldCat, new and new.id or "blocked", tostring(newCat),
                        plan.describeState(st), bad.id)
                end
            end
        end
    end
end
check(#unsafe == 0, "every switch is safe:\n    " .. table.concat(unsafe, "\n    "))
check(switches > 1000, "switches tried: " .. switches)

-- ---- sensor -------------------------------------------------------------------------
local f = hw.parseForgeSensor({
    "GT5U.multiblock.progress\\\\0\\\\0",
    "GT5U.EBF.heat.s\\\\13,500",
    "GT5U.infodata.plasma_forge.ticks_run_fuel_discount\\\\\194\167a576,000\194\167r\\\\\194\167c50\194\167r%\\\\1,234",
    "GT5U.infodata.plasma_forge.convergence\\\\\194\167aActive\194\167r, perfect convergence achieved",
})
eq(f.heat, 13500, "sensor heat")
eq(f.ticks, 576000, "sensor ticks")
eq(f.discount, 50, "sensor discount")
eq(f.extra, 1234, "sensor extra catalyst")
eq(f.convergence, true, "sensor convergence")
f = hw.parseForgeSensor({ "GT5U.infodata.plasma_forge.convergence\\\\\194\167cInactive" })
eq(f.convergence, false, "sensor convergence inactive")
f = hw.parseForgeSensor({ "Heat capacity: \194\167a12,600 \194\167rK",
    "Ticks run: 1,000, Fuel Discount: 2% (Extra catalyst use: 0L)" })
eq(f.heat, 12600, "english heat")
eq(f.ticks, 1000, "english ticks")
eq(f.discount, 2, "english discount")

-- ---- writeFilter ----------------------------------------------------------------------
local calls = {}
local bus = { side = 3, slots = 18, written = {}, proxy = {
    setStorageConfiguration = function(side, slot, d)
        calls[#calls + 1] = string.format("%d:%d:%s", side, slot, d and d.name or "clear")
        return true
    end,
} }
local wrote = hw.writeFilter(bus, {}, { name = "lava" })
eq(wrote, 18, "first write touches every slot")
eq(calls[1], "3:1:lava", "empty list writes the blocker")
calls = {}
wrote = hw.writeFilter(bus, { { name = "molten.infinity" }, { name = "molten.quantum" } }, { name = "lava" })
eq(wrote, 2, "only changed slots are written")
eq(calls[2], "3:2:molten.quantum", "slot 2")
calls = {}
wrote = hw.writeFilter(bus, { { name = "molten.infinity" } }, { name = "lava" })
eq(wrote, 1, "a dropped filter is cleared")
eq(calls[1], "3:2:clear", "slot 2 cleared")

print(string.format("%d checks, %d failed", count, failures))
if failures > 0 then os.exit(1) end

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
        disabled = { inf_t3 = true, inf_t3_comb = true }, minBatches = 1,
    }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

-- infinity: no combs, so the comb variant is skipped and t5 runs
local run, planned = plan.product(R.variants.infinity, ctx())
eq(run and run.variant.id, "inf_t5", "infinity picks t5 without combs")
eq(planned.id, "inf_t5_comb", "infinity plans with the best statically allowed variant")
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

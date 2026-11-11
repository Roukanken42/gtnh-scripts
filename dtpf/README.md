# dtpf — Dimensionally Transcendent Plasma Forge passive controller

Keeps a whole DTPF array busy with **passive** recipes: infinity, hypogen,
spacetime and shirabon. Active recipes reach the DTPFs from AE on demand and
take precedence by themselves. Whenever a DTPF has nothing else to do, it pulls
a passive recipe through three storage buses, and this script decides which
recipe that is by setting their filters:

- **Picks the product** that is furthest below its target, counting what the
  products downstream will consume (see [Which product](#which-product)).
- **Picks the variant**: the best one the coils, the catalysts on the main net
  and the stocker allow. Stellar infinity when there is stellar, exotic when
  there is not, and so on.
- **Checks the recipe first**: a product is only exposed when the stocker
  holds a full batch of every input, and the main net holds the catalyst
  (after your reserve, and the running-time discount).
- **Never idles the array** when something is runnable: an idle DTPF loses
  running time 100 times faster than it earns it.

## How the machine behaves

These rules come from GT5-Unofficial `MTEPlasmaForge` (GTNH 2.9.0) and the
script is built around them:

| | |
|---|---|
| Discount | Running time adds the length of every recipe started. The catalyst discount is `running time / 8 h × 50 %`, so it caps at 50 % after 8 hours. |
| Decay | Every tick the machine is idle, running time drops by **100 ticks**. One idle minute costs 100 minutes of discount. |
| Catalyst check | The discount is applied when the recipe is searched, so 50 % of the listed catalyst is enough to start. The script checks against the **least** discounted DTPF, because the input is shared. |
| Coils | A variant needs its coil heat: Awakened 10800 K, Infinity 11700 K, Hypogen 12600 K, Eternal 13500 K. The script checks against the coldest formed DTPF. |
| Variant choice | The variants of a product differ in catalyst (and some in a non-consumed item). One catalyst is exposed at a time, so only the intended variant can match. |
| Convergence | With Convergence at the full 50 %, a recipe takes extra catalyst for perfect overclocks. A recipe **without** catalyst (spacetime, shirabon) takes the type chosen in the GUI; set it in `cfg.convergence`. |

Sensor values are read from `getSensorInformation()`, which in 2.9 returns
translation keys (`GT5U.EBF.heat.s`, `GT5U.infodata.plasma_forge.*`), not
English text.

## The recipes

From NewHorizonsCoreMod `DTPFRecipes.java` and GT5-Unofficial
`RecipeLoader2.java`, in `recipes.lua`. Best variant first:

| Product | Variant | Catalyst | Coils | Per batch |
|---|---|---|---|---|
| Infinity | `inf_t5` | stellar 11373 | Eternal | 4 Infinity Catalyst → 36864 L (+ circuit 4) |
| | `inf_t4` | exotic 26243 | Eternal | 2 → 18432 L (+ circuit 4) |
| | `inf_t35` | resplendent 58932 | Hypogen | 1 → 9216 L (+ circuit 5) |
| | `inf_t3` | resplendent 920 | Awakened | 1 → 144 L (+ circuit 4), **off by default** |
| | `*_comb` | 15 % less | | the same, plus 1 Infinity Comb, half the time |
| Hypogen | `hyp_v4` | stellar 1000 | Eternal | 11520 neutronium, 5760 quantum, 1440 infinity → 11520 L (+ Hypervisor Matrix) |
| | `hyp_v3` | exotic 1000 | Eternal | 5760 / 5760 / 1440 → 5760 L (+ Hypervisor Matrix) |
| | `hyp_v2` | resplendent 1000 | Hypogen | 5760 / 5760 / 1440 → 2880 L |
| | `hyp_v1` | prosaic 1000 | Infinity | the same plus 144 hypogen → 1584 L |
| Spacetime | `st_v2` | none | Eternal | Energised Tesseract, 5000 residue, 1152 infinity → 576 L (+ Hypervisor Matrix) |
| | `st_v1` | none | Hypogen | Tesseract, 10000 residue, 2304 infinity, 1152 hypogen → 144 L |
| Shirabon | `sh_v1` | none | Eternal | 1152 metastable oganesson, 2304 precious metals alloy, 288 spacetime, 5000 residue → 144 L (+ HiC Mk-V) |

Items in brackets are not consumed: the stocker needs one, and keeps it.
Infinity and hypogen make the residue (DTR) that spacetime and shirabon eat.

## Which product

Every product has a target stock on the main net and a priority
(`cfg.products`). The scheme has three steps.

1. **Demand flows upstream, and keeps its priority.** A product inherits the
   shortfall of what is made from it. If shirabon is 1440 L short, that is
   10 batches, which eat 2880 L of spacetime. So spacetime gets 2880 L of
   extra demand *at shirabon's priority*. Spacetime's shortfall, both its own
   and the inherited part, passes on to infinity at those same priorities.
   This is plain MRP. It is modeled with the best variant your coils allow,
   so it knows `st_v2` needs no hypogen while `st_v1` does.
2. **Layers.** A product's demand is a stack of layers, one per priority: its
   own target at its own priority, plus what it inherited. Its stock covers
   the most important layers first.
3. **Pick.** The array makes the **runnable** product whose most important
   *uncovered* layer has the highest priority. Ties go to the lowest fill
   within that layer, then to the earlier product in `cfg.products`. Once
   every layer of every product is covered, the lowest overall fill
   (`stock / effective target`) wins.

With all priorities equal, this is simply "lowest stock / effective target".

**Priorities in practice.** Infinity is also made elsewhere, so the default
config gives it priority 1 and the others 2:

- While spacetime, hypogen or shirabon is short, infinity's *own* target is
  ignored. Its stock goes to covering what they will need.
- If that stock is not enough to feed them, infinity's uncovered layer is
  at **their** priority. It is then made at full urgency, as feedstock.
- Infinity's own top-up runs only when nothing more important is short and
  runnable. That includes the time when the others are blocked on some other
  input.

Why this gets the order right without special cases:

- When shirabon is short but there is no spacetime to make it from, shirabon
  is not runnable and is skipped. Spacetime, which inherited shirabon's
  shortfall at shirabon's priority, is now the most urgent. Production walks
  up the chain by itself and comes back down as the inputs appear.
- Spacetime and shirabon eat residue, which infinity and hypogen make. When
  residue runs out they stop being runnable, and a residue maker runs.
- When everything is at target, the lowest fill still wins. Overproduction
  is then spread in proportion to the targets. `max` caps a product. With
  `selection.keepBusy` (the default) the cap is still ignored when nothing
  else is runnable, because idling costs more than a little extra stock.

`selection.minDwell` and `selection.switchMargin` stop the filters from
flapping between two products with nearly the same fill. A more important
priority takes over as soon as the dwell is up, whatever the margin. A
product that stops being runnable is left at once, because the point is to
keep the array busy.

Keys **1–4** pin a product (in `cfg.products` order) while it is runnable,
**A** goes back to automatic.

## Hardware

| What | Where | Config |
|---|---|---|
| Adapter on every DTPF controller | | `cfg.forges` (auto: every `gt_machine` named `*plasmaforge*`) |
| Stocker | the inventory AE keeps stocked with the passive ingredients (items and fluids), with a **transposer** touching it | `cfg.stocker` (auto: the one side with both slots and tanks) |
| Item storage bus | on the stocker, on the DTPFs' input subnet | `cfg.buses.items` |
| Fluid storage bus | on the stocker, on the DTPFs' input subnet | `cfg.buses.fluids` |
| Catalyst storage bus | a fluid storage bus on a main-net interface, on the DTPFs' input subnet. Its filter must already hold a catalyst (see below) | `cfg.buses.catalyst` (auto: the one fluid bus whose filter holds a catalyst) |
| Main net | an Adapter on any ME interface/controller of the main net, for counting products and catalysts | `cfg.mainnet` |

The DTPFs take their passive inputs from that subnet, for example through ME
stocking input buses and hatches.

A storage bus is reached through an **Adapter touching the cable it sits
on**. The component is the cable, and the bus is addressed by the side of the
cable it is on. `probe buses` lists every one with its address and side.

**Give the item bus its own cable block.** OpenComputers' item storage bus
driver also matches fluid storage buses (the fluid part is a subclass), and on
a cable that carries both, the fluid driver wins every call. The item bus on
that cable is then unreachable. At startup the script writes a fluid into
the stocker's fluid bus and reads it back, and stops with a fault if that
does not work.

**An empty storage bus filter lets everything through.** The script therefore
never leaves one empty:

- **The stocker buses** get `cfg.blocker` (bedrock, lava) when nothing may
  pass. That only exposes what the stocker holds, and neither can complete a
  DTPF recipe alone.
- **The catalyst bus** sits on the main net, so an empty filter there, or
  anything but a catalyst, would expose the whole main net. It always holds a
  catalyst:
  - Put one into its filter by hand before the first run. That is also how
    the script finds it. At startup it only *reads* this bus, and refuses to
    start if no slot holds a catalyst.
  - It is never blocked or cleared. A change writes the new catalyst into
    slot 1, replacing the old one in one call, and only then clears any other
    slots. A failed write leaves the old catalyst in place.
  - When a recipe needs no catalyst (spacetime, shirabon), or nothing is
    runnable, the bus keeps the catalyst it has. With **Convergence**, a DTPF
    whose GUI type matches that catalyst may then use it for perfect
    overclocks. Set `cfg.convergence.catalystForNoCatalystRecipes` to control
    which catalyst sits there for those recipes.

**Switching recipes safely.** Because the catalyst cannot be withdrawn, a
change of ingredients first blocks both stocker buses, then sets the
catalyst, then writes the new ingredients. While they appear one by one,
nothing but the intended variant can match: no two passive variants with the
same catalyst have inputs that are a subset of one another. When only the
catalyst changes (hypogen v3 and v4 share their inputs), the single catalyst
write switches the variant.

## Install and first run

```
install dtpf
cd dtpf
probe              -- list components
probe buses        -- every storage bus: address and side for cfg.buses
probe sides        -- what the transposer sees; which side is the stocker
probe stock        -- the stocker's contents and the material each matches
probe mainnet      -- the main net's products and catalysts
probe forges       -- each DTPF's raw sensor lines and what was parsed
```

1. Make sure the catalyst bus filter holds a catalyst. `probe buses` marks
   that bus. Put any bus it cannot tell apart into `cfg.buses`, and set your
   targets.
2. Run `probe stock` with the stocker filled. Every ingredient should map to a
   material. A `-` means a label the script does not know: add its key under
   `cfg.materials`.
3. Run `main` with `cfg.dryRun = true` (the default). It reads everything,
   picks, and logs the filters it would set, without writing any.
4. Set `cfg.dryRun = false` and run `main`.

**SPACE/P** pauses: the filters stay as they are. **Q** quits, and also leaves
the filters as they are, so the array keeps making the last pick while its
inputs last.

## Tuning (`config.lua`)

| Setting | Meaning |
|---|---|
| `products` | `{ name, target, max, priority }`. Higher priority = more important; ties go to the earlier one. |
| `catalysts.allowed` | Catalysts passive recipes may use at all. |
| `catalysts.reserve` | L of each catalyst passive recipes leave for the active ones. |
| `catalysts.perProduct` | A narrower list per product, e.g. keep stellar for hypogen. |
| `disabledVariants` | Variant ids never to run. `inf_t3*` are off by default: they make 144 L instead of 9216 L per Infinity Catalyst, so enable them only while your coils are below Hypogen. |
| `heat` | `"min"` (the coldest formed DTPF) or a number in K. |
| `maxEUt` | Skip variants whose base EU/t is above this. |
| `selection.minBatches` | Batches the stocker must hold before a product counts as runnable. |
| `selection.minDwell`, `switchMargin` | Hysteresis, see above. |
| `selection.keepBusy` | Ignore `max` caps when nothing else is runnable. |
| `convergence.catalystForNoCatalystRecipes` | The catalyst type set in the DTPF GUIs, exposed with spacetime and shirabon. |

## Not verified in-game yet

These parts were written from the mod sources (OpenComputers 1.12.68-GTNH,
GT5-Unofficial 5.09.54.265, NewHorizonsCoreMod 2.9.99), not tested:

- Storage bus filters: `setStorageConfiguration(side, slot, {name, damage})`
  for items and `{name}` for fluids, slots counted from 1, and a missing third
  argument clears the slot. The stocker fluid bus is checked by a read-back at
  startup, and every catalyst write is read back too.
- Item labels the stocker is matched by: "Infinity Catalyst", "Infinity Comb",
  "Energised Tesseract", "Hypervisor Matrix (Fusion)", "Hi-Computation Station
  Mk-V Finaltype", "Programmed Circuit". `probe stock` shows whether they match.
- That a transposer can read both the items and the fluids of your stocker.
- Which DTPF a shared recipe goes to: with several idle machines, all of them
  can start the exposed recipe, and `minBatches = 1` only guarantees one batch.

## Files

| File | Role |
|---|---|
| `main.lua` | loop: reading, deciding, writing filters, keys |
| `plan.lua` | the decisions: recipe checks, demand, selection. Pure Lua, testable off-machine (`lua tools/test-dtpf.lua` from the repo root) |
| `recipes.lua` | the game data: variants, catalysts, coil heats, how stacks are recognised |
| `hw.lua` | every component call |
| `ui.lua` | dashboard (pure display; `cfg.ui`) |
| `probe.lua` | setup discovery |
| `config.lua` | your setup and policy (never overwritten by `install`) |

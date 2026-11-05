# bhc — Black Hole Compressor controller

Runs a **Pseudostable Black Hole Containment Field** (Black Hole Compressor)
on its own:

- **Opens** a black hole with a Black Hole Seed when the crafting net has work.
- **Holds** it with spacetime at the stability you choose, for the time and cost
  you allow. Lower stability means more parallels: x2 below 50%, x4 below 20%.
- **Void protection:** if the hole is about to go unstable under a running
  recipe, it holds the hole until that recipe finishes, and blocks new recipes
  that the hole would not outlive.
- **Collapses** a dead hole with a Black Hole Collapser when there is more work,
  or lets it close by itself (15 minutes) when there isn't, which saves the
  collapser.
- **Low-resource protection:** it does not open a hole without seeds, or with
  less spacetime than you set.

## How the machine behaves

These rules come from GT5-Unofficial `MTEBlackHoleCompressor`, and the script is
built around them:

| | |
|---|---|
| Decay | Stability starts at 100% and drops 1% per second, on the same tick the Utility Hatch pulses. |
| Holding | Each second, if stability > 0 and the spacetime hatch can give at least *cost* L, the machine drains exactly that and stability does not drop. The cost starts at 1 L/s and **doubles after every 30 seconds held**. The 30-second count belongs to the hole: it does not reset when you stop holding, only when the hole closes. |
| 0% | The hole becomes unstable, and **everything running is voided**. Spacetime no longer helps. It closes by itself 15 minutes later. |
| Seed / Collapser | Taken from the input bus **only at a recipe check**, which needs the machine idle and allowed to work. A seed taken while a hole is open is lost. So is a collapser taken while no hole is open. A collapser cannot save the recipe that is running. |
| Work disabled | A running recipe still finishes; no new one starts. The script uses this to keep new recipes out of a dying or unstable hole. |

OpenComputers cannot read the stability. The script **models it**: it counts
the pulses, and books a second as held when it had the spacetime hatch enabled
for that drain.

## Hardware

| What | Where | Config |
|---|---|---|
| Adapter | touching the BHC controller | `cfg.machine` (auto) |
| Transposer | touching the spacetime tank, the ME interface with seeds and collapsers, and a BHC input bus. Found automatically: the interface by its name, the tank by holding spacetime, the bus as the GregTech block | `cfg.transposer` (overrides only) |
| Black Hole Utility Hatch, **Pulse mode** | on the BHC, wired to a redstone input | `cfg.signals.pulse` |
| Work signal | redstone input, on while the crafting net has items for the BHC (for example a level emitter) | `cfg.signals.request` |
| Spacetime hatch | an ME stocking input hatch for spacetime, with a redstone cover that disables it unless the output is on | `cfg.signals.spacetime` |

Use a dedicated input bus for the seed and collapser, so recipe inputs never
fill it.

### The spacetime hatch

Use an **ME stocking input hatch**, and put the spacetime tank on the ME network
it stocks from (for example through a storage bus). This works because of how
the hatch behaves:

- Disabled, it refuses every drain.
- Enabled, a drain pulls exactly the cost straight out of ME. Nothing is
  buffered in the hatch, so the hold stops on the first second after the
  redstone goes off, and no pump throughput limits the cost.

The script only **enables** the hatch right after a pulse, which leaves it a
full second to switch before the next drain. It may disable the hatch at any
time; at worst the next drain is skipped. So the script always knows whether
a drain happened, and it counts held seconds from the hatch state it set, never
from the tank. That is deliberate: a stock replenisher can refill the tank in
the middle of a hole. A second only counts as held when the hatch had been on
for at least half a second before the pulse was handled, and the tank could pay
for it. Any doubt counts as a decay, so the model errs towards **lower**
stability, which is the safe direction.

The tank is read only to see how much spacetime there is. The script checks
it before opening a hole, and again before every hold and void protection.
`resources.minSpacetimeToOpen = "plan"` (the default) opens a hole only when
the tank can pay for its whole hold plan: 450 L with the default limits.

## Install and first run

```
install bhc
cd bhc
probe                 -- list components
probe sides           -- what each transposer side is, and what was recognised
probe redstone 10     -- which input pulses once a second (open a hole to see it)
probe machine         -- the BHC's gt_machine and its state
```

1. Put the three redstone sides (pulse, request, spacetime) in `config.lua`. The
   transposer and the BHC controller are found automatically.
2. Run `main` with `cfg.dryRun = true` (the default). The script follows the
   hole and logs what it would do, but touches nothing.
3. Set `cfg.dryRun = false` and run `main`.

If a hole is already open when you start, the script restores it from
`state.dat` and assumes it decayed for the whole time the script was off, which
errs low. With no saved state, it treats the hole as unstable. If you know the
stability (WAILA shows it), start with `main --stability=37`.

Keys: **SPACE/P** pauses. While paused the spacetime hatch is off, no items are
inserted, and the machine is left as it is. **Q** quits.

On exit (Q, Ctrl+C or an error) the script turns the spacetime hatch off and
**blocks new recipes**. With nobody watching, an open hole would go unstable and
void whatever arrives next. A running recipe still finishes. At startup it
blocks new recipes first and lets them through again once it knows the hole is
safe. It cannot do this if the computer loses power or crashes hard: the machine
keeps whatever state it had at that moment.

## Tuning (`config.lua`)

**Hold stages:** `cfg.hold.stages` is a list of `{ at = stability, seconds = max }`.
The default, `{ { at = 19, seconds = 300 } }`, runs at x4 parallels. Every stage
spends from the same doubling cost, so time held at 49% makes holding at 19%
more expensive later.

**Hold limits:** holding stops at the first limit reached:

| Limit | Meaning |
|---|---|
| `hold.maxCost` | Per-second cost cap, in L/s. `8` allows 30 s each at 1, 2, 4 and 8 L/s: 120 s for 450 L. `16` allows 150 s for 930 L. Each doubling adds 30 s and roughly doubles the spacetime spent. |
| `hold.maxSeconds` | Total time held, per hole. |
| `hold.maxSpend` | Total spacetime spent, per hole. |
| stage `seconds` | Time held at that stage. |

With `hold.onlyWithWork = true` the hole is held only while the machine is
running or work is waiting. When the crafting net runs dry, the hole is left to
decay and the spacetime is saved.

**Void protection:** `cfg.voidProtection.margin` is the stability at which void
protection takes over. It ignores the hold limits and may use the
`resources.spacetimeReserve`, but it is only attempted when the tank can hold
the hole to the end of the recipe.

**New recipes** start only while the hole, counting the hold budget it has left,
will outlive them by `recipe.safety` seconds. Recipe length is learned from the
machine: the longest of the last eight recipes, or `recipe.defaultSeconds` until
one has run.

**Collapser:** `collapser.onlyWhenRequested` collapses only when work is waiting.
`collapser.minSecondsSaved` skips the collapser when the hole would close by
itself sooner than that anyway.

**Resources:** `keepSeeds` and `keepCollapsers` are reserves the script never
uses. `minSpacetimeToOpen` sets the spacetime needed before a new hole is
opened: `"plan"`, a number of litres, or `0`. `spacetimeReserve` is added on
top. `cfg.meAddress` counts across the whole local ME net instead of only the
interface's stocked slots.

## Faults

The script stops automating (spacetime hatch off, no new recipes) and says why
when:

- a seed was taken but no pulse followed. The Utility Hatch is not in Pulse
  mode, or it is not wired to `signals.pulse`.
- a collapser was taken but the pulses went on.
- the input bus holds a catalyst it did not expect, for example a seed while it
  wanted to collapse.

Fix the cause and restart `main`. If a seed or collapser sits in the bus for
`timing.catalystTimeout` seconds, the script turns the machine off and on to
force a recipe check.

## Not handled

The Black Hole Stabilizer and the Supermassive Black Hole Seed. Keep them out of
the input bus the script uses.

## Files

| File | Role |
|---|---|
| `main.lua` | event loop: pulses, polling, applying decisions |
| `model.lua` | the machine model and the policy; pure Lua, testable off-machine |
| `hw.lua` | every component call |
| `ui.lua` | dashboard (pure display; `cfg.ui`) |
| `probe.lua` | setup discovery |
| `config.lua` | your setup and policy (never overwritten by `install`) |

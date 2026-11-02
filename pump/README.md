# pump — Space Elevator pumping-module regulator

Keeps demanded gases topped up in the AE2 network by switching the TecTech
parameters (planet + gas type) of one or more Space Elevator pumping modules,
allocating pumps to under-stocked gases in priority order.

## Install

```
wget https://gitlab.com/Roukanken/gtnh-scripts/-/raw/main/install.lua && install pump
cd pump
```

## First-time setup (in-game)

Needs an **Internet Card** (to install) and an **Adapter** on each pumping module.

1. **Discover the hardware/API** with the probe:
   ```
   probe                 -- list components + total count (component budget)
   probe gt_machine      -- methods+docs of a pump
   probe fluids          -- clean fluid labels (e.g. "Molten Redstone") for gases.lua
   ```
2. **Finalize the data/config** from that output:
   - `gases.lua` — the ~40 configs; each `name` must match the fluid label.
   - `config.lua` — your `cfg.demand` (targets in mB). Pumps are auto-discovered,
     so there are no addresses to configure.
   Then run `check` to verify every gas name matches an AE2 fluid label and to
   catch duplicate names / (planet, gas) pairs.

Pumps are found automatically: any `gt_machine` whose `getName()` is
`projectmodulepumptN` is treated as a tier-N pump (MK-1/2/3), and its thread and
parallels stats are recorded for allocation. `main` logs what it discovered on
startup.

The parameter layout is already set in `pumps.lua` (GTNH 2.9+): parameters are
written with `setParameter(key, value)` and read back with `getParameters()`,
and the pump is toggled with `setWorkAllowed(bool)`. Thread `i` uses the keys
`recipe<i>.planetType`, `recipe<i>.gasType` and `recipe<i>.parallel`, and each
thread is set independently (MK-1 has 1 thread, MK-2/3 have 4), so one pump can
serve several gases at once. Run `probe pump` to see a pump's live parameters.
3. **Dry run** (`cfg.dryRun = true`, the default): run `main` and confirm the
   logged allocation looks right — no pump is touched.
4. **Go live**: set `cfg.dryRun = false` and run `main`.

## How allocation works

The allocation unit is a **thread** (each pump contributes one per tier level:
MK-1 = 1, MK-2/3 = 4). Each cycle: read AE2 stock → find gases below target (with
hysteresis so a thread does not flap around the target) → rank them by a **score**
that blends priority with how empty the tank is:

```
score = priority * (1 + (criticalWeight - 1) * missingFraction^2)
```

A full tank scores `priority × 1`, an empty one `priority × criticalWeight`, so a
critically-low fluid can outrank a well-stocked but higher-priority one; the
square keeps the boost small until a tank is genuinely low. See `cfg.criticalWeight`
(a gas can override it with a `criticalWeight` field in its demand entry).

Threads are then assigned **score-weighted**: each thread goes to the gas with the
highest `score / (threadsAssigned + 1)`, so a higher-priority or emptier gas pulls
more threads while the diminishing `1/(threads + 1)` term still lets others in.
Each gas is capped at its estimated need (a thread makes `gas.amount × parallels`
mB/s), so no gas hoards threads it can't use this cycle.

Before that weighting runs, a **coverage floor** (`cfg.coverageFloor`, default 1)
guarantees the top-N scoring gases one thread each, so pure priority can't starve
them. Tune it to trade concentration against spread:

- `0` — pure priority: a dominant gas takes as many threads as its deficit needs
  before anything else is served.
- `1` — guarantee the single most-critical gas a thread, then weight the rest.
- large (≥ number of demanded gases) — spread one thread across as many gases as
  possible first (the previous breadth-first behaviour).

Threads already serving a gas are reused for it (sticky) to avoid reconfiguration;
unused threads are idled (parallels 0) and fully-idle pumps disabled.

## Pausing

Press **SPACE** (or **P**) at any time to pause the regulator: every pump is
disabled immediately and allocation is frozen, so nothing is pumped until you
resume. Press the key again to resume — a fresh cycle runs at once and re-applies
the allocation. The pause takes effect mid-cycle (you do not have to wait for the
next tick), and the dashboard shows a red **PAUSED** badge and status while
halted. Pausing is respected in dry-run mode too (there it only freezes the
logged plan, since no pump is ever touched). This needs a keyboard on the
controller; a headless machine with no keyboard simply runs uninterrupted.

## Dashboard

With a GPU + screen, `main` shows a live full-screen dashboard (`ui.lua`, toggle
with `cfg.ui`): a KPI strip (pumps, active threads, **parallels in use**, the
resulting **power draw** at 2,097,152 EU/t per parallel, and a **time-to-fill**
ETA), a fluids table with colour-coded fill bars / score / status, and a per-pump
thread panel showing what each thread is pumping. It runs headless with plain text
logging if there is no screen or `cfg.ui = false`. The display is pure render —
all state comes from `main.lua`, so the controller logic is unaffected.

The **log panel is hidden by default** so the fluids table gets the full screen
height; press **L** to toggle it. On a maxed tier-3 screen (160×50) that leaves
room for **40 detailed rows** — every gas in `gases.lua` — with the log hidden,
or ~33 with it shown (roughly `screenHeight − 10`). Messages keep accumulating
while hidden, and if the table still can't fit (smaller screen, or the log shown
with many gases) it falls back to a compact multi-column layout.

### Fill-time estimate

The dashboard shows a rough estimate of how long it will take to top every gas
back up to its target. Because pumps constantly switch between gases, a per-gas
*real* time is meaningless, so each fluid's `1P ETA` column shows the time for a
**single parallel** to cover that gas's deficit (`deficit ÷ mB-per-parallel-per-
second`) — a stable, comparable figure. The `TIME TO FILL` KPI sums those into an
overall one-parallel total (`1p …`) and also divides it by the fleet's total
parallel capacity for a rough **real-time** headline (assumes every parallel stays
busy on demand, so it is optimistic). It reads `DONE` when nothing is below target.
The compact fallback layout omits the per-fluid column but still shows the KPI.

The dashboard repaint is **decoupled** from the control cycle: it refreshes every
`cfg.uiRefresh` seconds (default `1`), re-polling AE2 stock so the fill bars,
clock, and log stay live, while pumps are only reallocated every `cfg.sleep`
(default `30`). Lower `cfg.uiRefresh` = smoother display at the cost of more
frequent AE2 reads. Each frame is **double-buffered** (drawn off-screen and
blitted in one operation) so refreshes don't flicker; it falls back to direct
drawing on GPUs that can't allocate a buffer.

## Files

| File | Role |
|------|------|
| `main.lua`   | control loop + demand/allocation logic |
| `ui.lua`     | full-screen dashboard (pure display; `cfg.ui`) |
| `pumps.lua`  | pump abstraction — the only place that drives TecTech hardware |
| `ae2.lua`    | reads gas stock from the AE2 network |
| `gases.lua`  | static data: the available pumping configurations |
| `config.lua` | your demand + tuning (never overwritten by updates) |
| `probe.lua`  | in-game discovery tool |
| `check.lua`  | validates gases.lua names/keys against the AE2 network |

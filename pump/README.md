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

The TecTech parameter layout is already set in `pumps.lua`: parameters are
written with `setParameters(hatch, id, value)` — planet `(0,0)`, gas `(0,1)`,
parallels `(1,0)` — and the pump is toggled with `setWorkAllowed(bool)`. The
layout generalizes to thread `i` as planet `(2i,0)`, gas `(2i,1)`, parallels
`(2i+1,0)`, and each thread is set independently (MK-1 has 1 thread, MK-2/3 have
4), so one pump can serve several gases at once.
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

Threads are then assigned **breadth-first by score**: every served gas gets one
thread before any gets a second, so with few threads and many gases only the top
scorers are served (no thrashing across all 40). Any leftover threads are shared
among the served gases in proportion to score, capped by each gas's estimated
need (a thread makes `gas.amount × parallels` mB/s). Threads already serving a gas
are reused for it (sticky) to avoid reconfiguration; unused threads are idled
(parallels 0) and fully-idle pumps disabled.

## Files

| File | Role |
|------|------|
| `main.lua`   | control loop + demand/allocation logic |
| `pumps.lua`  | pump abstraction — the only place that drives TecTech hardware |
| `ae2.lua`    | reads gas stock from the AE2 network |
| `gases.lua`  | static data: the available pumping configurations |
| `config.lua` | your demand + tuning (never overwritten by updates) |
| `probe.lua`  | in-game discovery tool |
| `check.lua`  | validates gases.lua names/keys against the AE2 network |

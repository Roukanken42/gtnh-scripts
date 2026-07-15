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
   - `gases.lua` — the ~40 configs (planet/gas ints, amounts, `fluid` labels).
   - `config.lua` — `cfg.pumps` addresses and your `cfg.demand` (targets in mB).

The TecTech parameter layout is already set in `pumps.lua`: parameters are
written with `setParameters(hatch, id, value)` — planet `(0,0)`, gas `(0,1)`,
parallels `(1,0)` — and the pump is toggled with `setWorkAllowed(bool)`. The
layout generalizes to thread `i` as planet `(2i,0)`, gas `(2i,1)`, parallels
`(2i+1,0)`. This MVP drives **one thread per pump**.
3. **Dry run** (`cfg.dryRun = true`, the default): run `main` and confirm the
   logged allocation looks right — no pump is touched.
4. **Go live**: set `cfg.dryRun = false` and run `main`.

## How allocation works

Each cycle: read AE2 stock → find gases below target (with hysteresis so a pump
does not flap around the target) → sort by priority, then deficit → give every
needy gas one pump first, then double leftover pumps onto the highest-priority
gases (up to `cfg.maxPumpsPerGas`). Pumps stay on their current gas when still
needed (sticky) to avoid needless reconfiguration.

## Files

| File | Role |
|------|------|
| `main.lua`   | control loop + demand/allocation logic |
| `pumps.lua`  | pump abstraction — the only place that drives TecTech hardware |
| `ae2.lua`    | reads gas stock from the AE2 network |
| `gases.lua`  | static data: the available pumping configurations |
| `config.lua` | your demand, pump addresses, tuning (never overwritten by updates) |
| `probe.lua`  | in-game discovery tool |

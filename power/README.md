# power — LSC power monitor & generator controller

Monitors the base battery (Lapotronic Supercapacitor / LSC) and the attached
wireless EU network, and switches power generators on/off via redstone using
**staged thresholds**: as the battery level falls, generators turn on in priority
order (cheapest first); as it recovers, they turn off in reverse. Each generator
has its own on/off band, so cheap base-load generators run most of the time and
expensive ones only kick in when the battery is genuinely low.

## Install

```
wget https://gitlab.com/Roukanken/gtnh-scripts/-/raw/main/install.lua && install power
cd power
```

## First-time setup (in-game)

Needs an **Internet Card** (to install), an **Adapter** touching the LSC, and a
**Redstone Card** (or Redstone I/O block) wired to your generators.

1. **Discover the hardware/API** with the probe (already this program's step 0):
   ```
   probe                 -- list components + each gt_machine's name; redstone snapshot
   probe <addr|name>     -- deep-probe one machine (live energy values + sensor lines)
   ```
   The LSC appears as a `gt_machine` named `multimachine.supercapacitor`; it is
   auto-discovered, so there is no address to configure.
2. **Wire your generators** to the redstone card. Each generator (or group) is
   driven by one redstone signal — either a plain side output or, via a bundled
   cable, one colour on a side.
3. **Configure `config.lua`** — one entry per generator:
   - `side` / `color` — where its redstone signal comes out.
   - `output` — how strong it is (EU/t; e.g. `"3.2M"`). Used for display totals.
   - `prio` — cost rank; **lower = cheaper = turned on first, off last**.
   - `onBelow` / `offAbove` — the battery-level band (0–1) at which it switches.
     Keep `onBelow < offAbove`; the gap is the hysteresis that prevents flapping.
   - `minOn` — optional minimum seconds to stay on once started.
4. **Dry run** (`cfg.dryRun = true`, the default): run `main` and confirm the
   dashboard + log show the switches it *would* make as the battery level moves —
   no redstone is touched.
5. **Go live**: set `cfg.dryRun = false` and run `main`.

## How control works

Each cycle (`cfg.sleep`, default 5 s) the controller reads the LSC, derives a
single **level** in 0–1, and applies each generator's threshold band:

- `level ≤ onBelow` → turn **on**
- `level ≥ offAbove` → turn **off** (unless still within its `minOn` time)
- in between → **hold** current state (hysteresis)

Because each generator has its own band and they are sorted by `prio`, generation
ramps up and sheds in priority order automatically — no central "how many
generators" decision, just independent staged bands.

### Control source (LSC vs wireless)

The LSC's stored EU exceeds 64-bit integers at high fill, and the **wireless EU
network total will exceed 2^64** (its capacity is effectively infinite). So large
values are read as **strings** — from the `getStoredEUString()` /
`getEUCapacityString()` getters and from `getSensorInformation()` text (the
wireless pool total has no getter) — and handled by `bignum.lua` as digit strings,
never through a clamping 64-bit int.

`cfg.source` chooses what the `level` is derived from:

- `"auto"` (default) — follow the LSC's wireless mode: when wireless is **enabled**
  (the network then fills/drains the LSC, so it is the real reservoir) the level is
  the **wireless pool**; otherwise it is the **local LSC fill %**.
- `"lsc"` — always the local LSC fill %.
- `"wireless"` — always the wireless pool.

The wireless pool has no real capacity, so its level is scaled between
`cfg.wireless.min` and `cfg.wireless.max` (absolute-EU strings, e.g. `"1E"`), your
chosen operating band. The same fractional `onBelow`/`offAbove` thresholds then
apply in either mode. The dashboard always shows **both** the LSC fill and the
wireless pool, marking which one is the active control source.

## Pausing

Press **SPACE** (or **P**) to pause: every generator is switched **off**
immediately and control is frozen until you resume. Press again to resume — a
fresh cycle runs at once. Respected in dry-run too (there it only freezes the
logged plan). Needs a keyboard; a headless machine runs uninterrupted.

**On exit** (quit / Ctrl-C / crash) redstone outputs are deliberately **left as
they are** — the controller never force-switches generators off on exit, since
cutting power unexpectedly could brown out the base. Only an explicit pause turns
them off.

## Dashboard

With a GPU + screen, `main` shows a live dashboard (`ui.lua`, toggle with
`cfg.ui`): a KPI strip (battery %, EU in/out, net flow, time-to-full/empty,
generators online + total EU/t), two fill bars (LSC and wireless pool, active
source starred), and a generators table (output / priority / on–off band / status
/ time-in-state). Huge EU values render via a length-based SI formatter so they
stay readable past 2^64. It runs headless with plain text logging if there is no
screen or `cfg.ui = false`. Repaints are decoupled from the control cycle
(`cfg.uiRefresh`, default 1 s) and double-buffered so they don't flicker.

## Files

| File | Role |
|------|------|
| `main.lua`       | control loop + staged-threshold logic |
| `ui.lua`         | full-screen dashboard (pure display; `cfg.ui`) |
| `lsc.lua`        | LSC read wrapper + sensor parser (the only battery reader) |
| `generators.lua` | generator abstraction — the only place that drives redstone |
| `bignum.lua`     | big-integer maths on decimal strings (values past 2^64) |
| `util.lua`       | small shared parsing helpers |
| `config.lua`     | your generators + tuning (never overwritten by updates) |
| `probe.lua`      | in-game LSC/redstone discovery tool |

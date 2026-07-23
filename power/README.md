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

Flow rates (EU in/out, net, and the fill/drain ETA) are read from the LSC's
**5-minute average**, not the instantaneous per-tick figure: power transported by
large lasers arrives in big bursts, so the per-tick / 5-second readings are far
too spiky to control or estimate on.

### Control source (LSC vs wireless)

The LSC's stored EU exceeds 64-bit integers at high fill, and the **wireless EU
network total will exceed 2^64** (its capacity is effectively infinite). So large
values are read as **strings** — from the `getStoredEUString()` /
`getEUCapacityString()` getters and from `getSensorInformation()` text (the
wireless pool total has no getter) — and handled by `bignum.lua` as digit strings,
never through a clamping 64-bit int.

`cfg.source` chooses what the `level` (and the single energy bar) is made of:

- `"auto"` (default) — follow the LSC's wireless mode: when wireless is **enabled**
  (the network fills/drains the LSC) the level is **LSC stored + wireless pool**;
  otherwise it is the **local LSC alone**.
- `"lsc"` — always the local LSC only.
- `"wireless"` — always LSC + wireless pool.

A single `cfg.max` is the "full" reference (100%) for whatever the level is made
of: `stored / cfg.max` with wireless off, or `(LSC stored + pool) / cfg.max` with
it on. Leave it `nil` to use the LSC's real capacity — handy default with wireless
off; set an EU string (e.g. `"500T"`, `"1E"`) to treat a smaller amount as full,
which is useful when the real capacity is so large the true fill % is always tiny,
and effectively required when wireless is on (the pool has no real capacity to
fall back on). The same fractional `onBelow`/`offAbove` thresholds apply either way.

### Wireless output cap

With wireless on, the LSC's stored energy is balanced toward a **wireless
threshold** every 5 minutes (from both above and below), so sustained wireless
output cannot exceed `threshold / 5 min`. The threshold is summed from the
high-tier capacitors in the multiblock — UHV 60T, UEV 6P, UIV 600P, UMV 60E each
— read from the sensor's "Capacitors detected" lines (values past 2^64, handled
as bignum strings). The dashboard shows this cap in EU/t and flags a red warning
(and logs one) when the 5-minute average output exceeds it — a sign the network
can't sustain the base's draw.

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
`cfg.ui`): a KPI strip (energy %, EU in/out over 5 min, net flow,
time-to-full/empty, generators online + total EU/t), one energy fill bar (LSC, or
LSC + wireless pool when wireless is on), and a generators table (output /
priority / on–off band / status / time-in-state). Huge EU values render via a
length-based SI formatter so they stay readable past 2^64. It runs headless with plain text logging if there is no
screen or `cfg.ui = false`. The dashboard repaints (and re-reads the LSC via a
single `getSensorInformation()` call) every `cfg.uiRefresh`, decoupled from the
control cycle; frames are double-buffered so they don't flicker.

Press **G** to swap the generators table for a **history** view: two stacked
charts sharing the time axis — the **energy level %** as an area (its height is
the reading; the fill-gradient colour is secondary) and the **net flow** as
points around a zero baseline (green above = charging, red below = draining,
peak-scaled). Both are drawn with **braille** characters (a 2×4 dot matrix per
cell), for 2× horizontal / 4× vertical sub-cell precision. One sample is recorded
per control cycle, so the window spans roughly `2 × graph width × cfg.sleep`. Two
different scales, so two charts rather than a dual axis.

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

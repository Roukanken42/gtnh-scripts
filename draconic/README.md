# draconic — Draconic Reactor controller

Runs a Draconic Reactor whose only job is turning **awakened draconium into
chaos shards**:

- **Feeds** it: a transposer moves awakened draconium blocks, ingots and
  nuggets from a **Super Stock Replenisher** (stocked from the main net) into a
  stabilizer. It fills the reactor before a run and tops it up while it runs.
- **Auto-starts**: once the reactor holds enough fuel (`cfg.autoStart.minBlocks`)
  it charges it, then activates it as soon as it reports *charged*. Optionally
  it also waits until the reactor plus the replenisher hold enough in total
  (`cfg.autoStart.minTotalBlocks`), which can be more than the reactor fits.
  That sets a minimum running time between shutdowns.
- **Stops safely**: it stops while enough fuel is left for the shutdown
  itself (see below), and keeps the wiki script's two rules as backstops: 20%
  chaos share and 20% containment field.
- **Dashboard** with gauges, shard counter, burn rate, predicted shutdown and a
  log. Touch buttons or keys: **S** start, **X** stop, **A** auto-start,
  **F** feeding, **Q** quit (twice).

Based on the safe-shutdown script on the
[GTNH wiki](https://wiki.gtnewhorizons.com/wiki/Draconic_Reactor) (credits
UltraProdigy, Fox).

## How the reactor behaves

From GTNewHorizons/Draconic-Evolution `TileReactorCore.java`, with GTNH's
`DraconicEvolution.cfg` (`cfg.game`):

| | |
|---|---|
| Fuel | nugget 2, ingot 18, block 162. The core holds 524,880 (3,240 blocks), counting chaos inside. Inserting more is not lost: it waits in a buffer. |
| Chaos | Converted fuel stays inside as chaos. Every 26,244 of it (162 blocks of draconium) is one chaos shard, shown in the reactor's single slot and taken out of a stabilizer. **While a shard waits there, nothing can be inserted.** |
| Charging | Containment field and saturation capacity are fixed from the fuel inside when charging begins. Charging cannot explode. `status` reads `charging`, then `charged`. |
| Running | Fuel use per tick = `tempDrainFactor x (1 - (saturation - 10%)^0.3) x 3.035`. `tempDrainFactor` is 1 between 2000 and 8000 C and grows with the square of the excess above 8000. |
| Stopping | The stabilizers stop drawing energy, so saturation climbs. From 99% saturation the temperature drops by `1 - c` per tick (c runs -0.3 to 1 as the chaos share goes 0 to 100%), **but only while unconverted fuel remains**. Otherwise it heats up. At 2001 C or below it is OFFLINE. Fuel keeps converting meanwhile. |
| Explosion | Containment field at 0, or a stabilizer or the injector removed at 2000 C or more. Running dry leads to the first: without fuel it cannot cool down, it gets hotter, and the field drain grows until the field is gone. |

## Why the reserve rule

The wiki script stops when the chaos share reaches 20%. That works because
shards are pulled out every 26,244 chaos: while there is plenty of fuel the
share stays under 5%, and only near the end does the leftover partial shard
become a big share. But the rule is relative. Right after a shard is pulled,
the partial shard is small, and the rule fires only when the unconverted fuel
is down to 4x that, which can be fewer than the ~1,000-5,000 fuel a shutdown
takes.

So every `simInterval` seconds the script runs the core's own `runTick` maths
forward from the current state (`physics.lua`) and gets how long a shutdown
would take and how much fuel it would use. It stops the reactor when the fuel
left drops below `reserveFactor x that + reserveBlocks`. If the simulation says
a shutdown would not finish at all, it stops at once. `probe reactor` prints
the same prediction.

Typical results, full reactor: about 5 to 6 minutes and 1,800 to 4,900 fuel
(the hotter, the more).

## Hardware

| What | Where | Config |
|---|---|---|
| Adapter | touching a Reactor Stabilizer or the Energy Injector | `cfg.reactor` (auto) |
| Transposer | touching the Super Stock Replenisher and one Reactor Stabilizer | `cfg.transposer` (auto by block name) |
| Shard extraction | an item conduit on a stabilizer, **or** an inventory on the transposer (`cfg.transposer.shardSide`) | |
| Screen + GPU | 80x25 or bigger (Tier 2+), keyboard | `cfg.ui` |

The power side is unchanged from the wiki: a flux gate into the injector and
one out of a stabilizer. The script does not control the flux gates.

## Setup

1. `install draconic`, then `cd draconic`.
2. `probe sides`: check it found the replenisher and the stabilizer. If not,
   set the sides in `config.lua`.
3. `probe stock`: the replenisher's draconium should show its fuel value.
4. `probe reactor`: the reactor answers, and the predicted shutdown.
5. `main`. To restart it after a reboot or server restart, add these lines to
   `/home/.shrc` (with the folder you installed into):
   ```
   cd /home/draconic
   main
   ```

**Q quits**. Unless `cfg.safety.stopOnQuit` is false, it stops the reactor
first, because nothing would feed or stop it afterwards. Ctrl+Alt+C takes the
same exit.

Auto-start turns itself **off** when you stop the reactor with X, when the
reactor is stopped from outside the script, and when the containment field
falls below 20%. **A** turns it back on.

## Files

| | |
|---|---|
| `main.lua` | The controller: reads the reactor, safety, auto-start, feeding, log. |
| `physics.lua` | The reactor's maths and the shutdown simulation. Pure, so it runs off-machine. |
| `hw.lua` | Every component call. |
| `ui.lua` | The dashboard. Renders a view table, decides nothing. |
| `probe.lua` | Setup checks. |
| `config.lua` | Settings. Never overwritten by `install`. |
| `state.dat`, `reactor.log` | Written on the machine: auto-start on/off and counters; starts, stops and faults. |

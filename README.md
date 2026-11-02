# gtnh-scripts

A collection of [OpenComputers](https://github.com/GTNewHorizons/OpenComputers)
Lua scripts for machines in **GregTech: New Horizons 2.8.4** (Minecraft 1.7.10).

OpenComputers has no `git`, so this repo ships a small **installer** that pulls
files straight from the GitHub repo onto a machine.

## Installing on an OpenComputers machine

Run this once in the machine's shell (needs an **Internet Card**):

```
wget https://raw.githubusercontent.com/Roukanken42/gtnh-scripts/main/install.lua && ./install
```

`install` reads the [`manifest`](manifest) file and downloads every listed file
into place, creating directories as needed.

- Re-run `install` any time to update a machine to the latest version, then
  **`reboot`** — OpenComputers caches required libraries, so updated modules do
  not take effect until the computer restarts.
- Install only part of the repo by passing a path prefix, e.g. `install aether`
  installs just the files under `aether/`.
- Files marked with `?` in the manifest (e.g. `config.lua`) are only fetched
  when missing, so a machine's local config is never overwritten by an update.

## Repo layout

```
install.lua              Bootstrap installer, run on the OC machine.
manifest                 Auto-generated list of files the installer downloads.
tools/                   Dev-machine helpers -- see below.
<program>/               One folder per program/machine (scripts, config, ...).
```

Inside a program folder, the split is by what a file *is*:

```
mining/
  main.lua               The controller. Aims the fleet at what you want, and
                         keeps it fed.
  setup.lua drone.lua    Programs you run. Every one takes --help and --verbose.
  plan.lua stock.lua
  plasma.lua
  config.lua             How the controller behaves. Never overwritten by
                         `install`.
  wants.lua              WHAT YOU WANT: the ore, and how much of it to keep.
                         Drives automatic mode; also never overwritten.
  lib/
    gtnh/                What the game gives us: meteor, plasma and drone data,
                         extracted from GTNH and regenerable (see each header).
    calc/                Pure maths over that data -- no components touched, so
                         it runs in any Lua interpreter. target.lua answers
                         "what should THIS module be set to"; wants.lua turns a
                         stock level into a demand; allocate.lua shares the
                         answers out over a fleet, which is a different question
                         and the one automatic mode actually asks.
    hw/                  Everything that talks to a component.
    control.lua          What the controller decides: what to stock, what to
                         request, and the plasma picker's keyboard.
    modes.lua            Which modules the controller may aim (AUTO/MANUAL).
    ui.lua               The dashboard. Renders a state table, decides nothing.
    profile.lua          Where each cycle's time goes, and how many component
                         calls it took to get there.
    cli.lua              Argument parsing, --help, and progress output.
    stations.lua         Where the generated station map lives.
  data/                  Generated on the machine by `setup` and by the
                         controller. Not in the repo.
```

Automatic mode is the reason `calc/` is split the way it is. A mining module
cannot be aimed at an item -- you set a distance, a drone and a plasma, and the
game rolls a weighted meteor -- so what a module produces has to be searched for
(`target.lua`), and because ore purity is dreadful when one material is targeted
alone, the useful configurations serve several wants at once. That makes the
fleet-level question a coverage problem rather than a ranking one: two modules
aimed differently frequently serve more of the list than two modules both aimed
at all of it. `allocate.lua` is where that is decided, and it stays pure so the
decision can be exercised off-machine.

Anything shared, or that the controller will want later, belongs in `lib/`. A
top-level script should be arguments, orchestration and output.

## Checking your work

The dev-machine tools catch the mistakes an OC machine only reports at runtime:

```
pwsh ./tools/build-manifest.ps1              regenerate `manifest` after adding files
lua tools/check-requires.lua mining          every require() resolves to a real file
lua tools/undefined-calls.lua mining/*.lua   nothing calls a function that isn't there
luac -p mining/**/*.lua                      syntax
```

The first two matter because Lua resolves both a `require` and a bare function
name only when the line actually runs. Move a module or delete a function and
everything still compiles; it fails in-game, in whichever branch reaches it
first. `lib/calc/` and most of `lib/hw/` also load in a plain interpreter, so
their logic can be tested off-machine.

## Adding or changing scripts

1. Add / edit `*.lua` files (put each program in its own folder).
2. Regenerate the manifest so the installer knows about the new files:
   ```
   pwsh ./tools/build-manifest.ps1
   ```
3. Commit and push. Machines pick up changes next time `install` is run.

### Config files

Name a program's user-editable config `config.lua`. The manifest generator
marks it with `?`, so `install` fetches it only when it does not already exist —
updates won't clobber a machine's settings. Ship defaults/examples in the file.

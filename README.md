# gtnh-scripts

A collection of [OpenComputers](https://github.com/GTNewHorizons/OpenComputers)
Lua scripts for machines in **GregTech: New Horizons 2.8.4** (Minecraft 1.7.10).

OpenComputers has no `git`, so this repo ships a small **installer** that pulls
files straight from the GitLab repo onto a machine.

## Installing on an OpenComputers machine

Run this once in the machine's shell (needs an **Internet Card**):

```
wget https://gitlab.com/Roukanken/gtnh-scripts/-/raw/main/install.lua && ./install
```

`install` reads the [`manifest`](manifest) file and downloads every listed file
into place, creating directories as needed.

- Re-run `install` any time to update a machine to the latest version.
- Install only part of the repo by passing a path prefix, e.g. `install aether`
  installs just the files under `aether/`.
- Files marked with `?` in the manifest (e.g. `config.lua`) are only fetched
  when missing, so a machine's local config is never overwritten by an update.

## Repo layout

```
install.lua              Bootstrap installer, run on the OC machine.
manifest                 Auto-generated list of files the installer downloads.
tools/build-manifest.ps1 Regenerates `manifest` (run on the dev machine).
<program>/               One folder per program/machine (scripts, config, ...).
```

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

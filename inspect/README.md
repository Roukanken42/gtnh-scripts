# inspect

An interactive, full-screen **component browser** for OpenComputers. Lists every
component wired to the computer and lets you drill into any one to read its
methods and their in-game documentation — a browsable version of the one-shot
`probe` tools that ship inside `power/` and `pump/`.

Use it to discover a machine's API before writing a script for it.

## Install

```
wget https://gitlab.com/Roukanken/gtnh-scripts/-/raw/main/install.lua && install inspect
```

Needs an **Internet Card** to install, plus a **GPU + screen + keyboard** to run
(with an **Adapter** touching whatever blocks you want to inspect). With no GPU
it falls back to printing a plain, non-interactive table.

## Run

From this folder:

```
main
```

### List screen

A scrollable table of every component: **type**, **address**, **slot**, method
count, and the **name** reported by `getName` / `getLabel` (when the component
has one).

| Key | Action |
| --- | --- |
| `W`/`S` or `Up`/`Down`     | move the selection |
| `A`/`D`, `Left`/`Right`, or `PgUp`/`PgDn` | page up / down |
| `Home` / `End`            | jump to first / last |
| `Enter`                   | open the selected component |
| `R`                       | rescan the component list |
| `Q` / `Esc`               | quit |

### Detail screen

A header card (address, type, slot, method count) above a scrollable list of the
component's methods. Each method shows its documentation string; direct-callable
methods are tagged `[direct]`.

| Key | Action |
| --- | --- |
| `W`/`S` or `Up`/`Down`      | scroll one line |
| `A`/`D` or `PgUp`/`PgDn`    | page |
| `Home` / `End`             | jump to top / bottom |
| `Q` / `Backspace`          | back to the list |

## How it works

`scan()` walks `component.list()`, and for each component records its type,
address, `component.slot`, and `component.methods` (the name → direct map). The
name column is filled by calling the first read-only getter the component
advertises (`getName`, then `getLabel`, then `getInventoryName`), each guarded by
`pcall` so a misbehaving method can't abort the scan. Method docs are fetched
lazily via `component.doc` only when a component is opened.

The UI mirrors the double-buffered, tier-3 rendering style used by the other
programs' dashboards, and degrades gracefully on smaller GPUs / screens.

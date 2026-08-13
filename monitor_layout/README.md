# Monitor Layout

Arrange multiple displays and change their resolutions from a Noctalia panel.
Migrated from the legacy v4 plugin by Mathew-D.

- **Service** (`service.luau`) reads the current display layout from Sway,
  Hyprland or Niri (auto-detected), keeps a live + draft copy, and applies the
  draft as a live script or exports it as a config-file snippet.
- **Bar widget** opens the layout panel. The icon color is configurable.
- **Control-center shortcut** toggles the layout panel.
- **Panel** edits the layout: a proportional arrangement strip, a selectable
  output list, and an inspector with resolution / position / scale controls.

## Interaction change from v4

The v4 panel let you drag displays around on a free-form canvas. Noctalia v5's
declarative UI has no absolute-positioning canvas and its drag-and-drop is
limited to list reordering, so the canvas was replaced with:

- an **arrangement strip** — tiles scaled by each output's logical size,
- a **position inspector** — numeric X/Y inputs (snapped to the grid size),
- a **resolution picker** and **scale slider** per output.

## Backends

| Backend | Detect | Query | Apply |
|---|---|---|---|
| Sway | `swaymsg` on PATH | `swaymsg -t get_outputs -r` | `swaymsg output <name> enable pos … res … scale …` |
| Hyprland | `hyprctl` on PATH | `hyprctl monitors -j` | `hyprctl keyword monitor NAME,RES,POS,SCALE` |
| Niri | `niri` on PATH | `niri msg -j outputs` | `niri msg output <name> position set … mode … scale … transform …` |

Detection prefers the running session's environment (`SWAYSOCK` /
`HYPRLAND_INSTANCE_SIGNATURE` / `NIRI_SOCKET` or `XDG_CURRENT_DESKTOP=niri`)
before falling back to PATH for Sway and Hyprland. The compositor can be forced
under Settings → Plugins.

Hyprland does not expose per-output mode lists over `hyprctl monitors -j`, so
the resolution picker seeds the current mode plus a deduplicated set of common
resolution/refresh presets; only the current mode is guaranteed to be valid.
Niri exposes real mode lists, but only permits modes the output actually
supports, and requires the first output to sit at logical position (0, 0) with
all outputs edge-adjacent — layouts that break that constraint are rejected by
Niri itself when applied.

## Requirements

- Noctalia v5 (plugin API 23).
- Sway (`swaymsg`), Hyprland (`hyprctl`), or Niri (`niri`), with the relevant
  session env vars.

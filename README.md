# Noctalia v5 plugins

Migrated Noctalia v5 (Luau) versions of plugins that previously shipped for the
legacy v4 (Quickshell) shell. Each plugin lives in its own subdirectory, as a
source-repo expects: add this directory as a plugin source and enable the
plugins you want.

```sh
noctalia msg plugins source add v5migration git <this-repo-url>
```

Or, for local development, drop the plugin folder under
`$XDG_DATA_HOME/noctalia/plugins/<plugin>/` and enable it once.

## Plugins

| Plugin | id | Entries |
|---|---|---|
| [Air Quality](./air_quality/README.md) | `simply-sharat/air_quality` | service, widget, panel, desktop widget |
| [Monitor Layout](./monitor_layout/README.md) | `simply-sharat/monitor_layout` | service, widget, shortcut, panel |
| [Privacy Indicator](./privacy_indicator/README.md) | `simply-sharat/privacy_indicator` | service, widget, panel |

## Layout

```
catalog.toml       index of every plugin in this repo
air_quality/       air quality service + bar widget + panel + desktop widget
monitor_layout/    display arrangement service + bar widget + control-center shortcut + panel
privacy_indicator/ capture-detection service + bar widget + access-history panel
```

Each plugin ships a `plugin.toml`, its entry scripts, a `README.md` and
`translations/en.json`.

## Requirements

- Noctalia v5 (plugin API 23 for all three plugins).
- Air Quality: an internet connection. Coordinates are resolved via IP
  (`auto_ip`, the default), custom lat/lon, or the shell's own `[location]`
  config when manual coordinates are set.
- Monitor Layout: either Sway (`swaymsg`) or Hyprland (`hyprctl`) with the
  backend auto-detected.
- Privacy Indicator: PipeWire with `pw-dump` on `PATH` (microphone and
  screen-sharing detection) and read access to `/dev/video*` (camera
  detection).

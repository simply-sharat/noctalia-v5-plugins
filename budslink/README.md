# BudsLink

Earbud battery, noise control and equalizer controls for the
[BudsLink](https://github.com/maniacx/BudsLink) service. Migrated from the
legacy v4 (Quickshell) plugin in the
[BudsLink-Companion](https://github.com/spadmanabhan/BudsLink-Companion) repo.

- **Service** (`service.luau`) spawns and keeps alive the GJS helper daemon
  (`helper/budslink-helper.js`) that watches BudsLink's D-Bus service, mirrors
  device state to `$XDG_RUNTIME_DIR/budslink/state.json`, and holds the service
  open with its `HoldService` heartbeat. The service polls that state file and
  publishes it under `budslink.data`; the UI sends actions back through
  `budslink.cmd`.
- **Bar widget** shows a device glyph (tinted by the configured active color)
  with an optional battery percentage. Left click opens the panel, middle
  click refreshes, right click opens the plugin settings.
- **Panel** shows the device header, per-earbud battery bars, the
  noise-control / equalizer toggles, and the device's active options box
  (radio group, slider, check buttons).

## Requirements

- Noctalia v5 (plugin API 23).
- `gjs` on `PATH` (the helper is a GJS script).
- The BudsLink app and its D-Bus service (`io.github.maniacx.BudsLink`). The
  bar shows a dimmed icon and the panel shows a "connect your earbuds" message
  when BudsLink is not running or no device is connected.

## Layout

```
budslink/
  plugin.toml            manifest: settings + bar widget + panel + service
  service.luau           helper lifecycle + state polling + action forwarding
  widget.luau            bar widget (glyph + battery, tooltip, click handlers)
  panel.luau             detail panel (battery bars, toggles, options box)
  helper/
    budslink-helper.js   GJS daemon: D-Bus watch, state mirror, HoldService
    budslink-open.sh     focus or launch the BudsLink app
  translations/en.json   UI strings
```

## Settings

Under Settings → Plugins:

| Setting | Default | Meaning |
|---|---|---|
| `update_interval` | 2000 | ms between state polls / helper keep-alive checks |
| `show_battery_text` | on | show the battery percentage next to the bar icon |
| `low_battery_threshold` | 20 | battery at or below this % is highlighted as low |
| `active_color` | `primary` | color of the headphones icon in the bar |

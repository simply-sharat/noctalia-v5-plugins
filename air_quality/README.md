# Air Quality

Live air quality (US EPA AQI or European AQI) in the bar, a details panel, and
a desktop widget. Migrated from the legacy v4 plugin by adriamartin91.

- **Service** (`service.luau`) fetches Open-Meteo or AQICN data on an interval
  and publishes it to shared state.
- **Bar widget** shows the AQI number colored by level. Left click opens the
  panel, middle click refreshes, right click opens settings.
- **Panel** shows the AQI hero, level, location, last update, and per-pollutant
  breakdown.
- **Desktop widget** shows the AQI number, level, location, and PM2.5/PM10.

## Location

Three modes under Settings → Plugins:

| Mode | How coordinates resolve |
|---|---|
| `auto_ip` (default) | Approximate coordinates from your public IP via ipapi.co |
| `custom` | Manual latitude / longitude fields |
| `shell` | Reads the shell's `[location]` manual coordinates (`location.latitude`/`longitude`) |

The shell resolves `auto_locate`/`address` at runtime and does not expose the
result to plugins, so the `shell` mode only works when manual coordinates are
set in the shell config.

## Data sources

- **Open-Meteo** (default, no key) — model-based air quality.
- **AQICN** — real station readings; requires a free token from
  aqicn.org/data-platform/token.

## Requirements

- Noctalia v5 (plugin API 26) — needs `noctalia.getSetting()` for the shell
  location mode.
- An internet connection.

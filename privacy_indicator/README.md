# Privacy Indicator

Shows when your microphone, camera, or screen is being captured, with a
history of which apps used them and when. Migrated from the legacy v4 plugin
by the Noctalia Team.

- **Service** (`service.luau`) polls `pw-dump` for the PipeWire node/link
  graph to detect active microphone and screen-sharing use, scans `/proc`
  file descriptors pointing at open `/dev/video*` devices for camera use, and
  keeps the access history (persisted in Noctalia's plugin data directory).
- **Bar widget** shows three icons (microphone, camera, screen share) that
  light up while that device is captured. Hover for the app list.
- **Panel** lists the access history with a clear button.

## Usage

Place the widget on a bar:

```toml
[widget.privacy]
type = "simply-sharat/privacy_indicator:bar"
```

- **Left click** opens the access-history panel.
- **Middle click** (the built-in settings binding) opens the plugin settings.
- **Right click** also opens the plugin settings.

Open the panel from the terminal:

```sh
noctalia msg panel-toggle simply-sharat/privacy_indicator:panel
```

## Interaction change from v4

v4 showed a right-click context menu and used shell *toast notices*. v5 uses
the standard widget gestures instead, and activation notices render as regular
notifications. The `remove_margins` setting is gone: v5 owns bar-widget
margins.

## How detection works

| Capture | Source | Method |
|---|---|---|
| Microphone | PipeWire | nodes with `media.class = Stream/Input/Audio` that are linked and not a capture sink |
| Camera | `/dev/video*` | apps holding an open video device fd, via `/sys/class/video4linux` + `/proc/*/fd` |
| Screen sharing | PipeWire | video-class nodes with a screen-cast / desktop-capture `media.name` |

The PipeWire graph is read by polling `pw-dump` every 2 seconds; the camera
scan runs on the same cadence. Filter patterns are **Lua patterns**, not
JavaScript regexes - `|` still separates alternatives, e.g.
`effect_input.rnnoise|easyeffects`.

## Requirements

- Noctalia v5 (plugin API 24).
- PipeWire, with `pw-dump` on `PATH` (microphone and screen-sharing
  detection).
- Read access to `/dev/video*` (camera detection).

## Settings

Plugin-level (Settings → Plugins):

- **Enable toast notifications** - notify when a capture starts.
- **Microphone filter pattern** / **Camera filter pattern** - exclude matching
  apps from detection entirely.

Widget-level (the bar widget's own settings):

- **Hide inactive states** - hide idle icons, and the whole widget when
  nothing is being captured.
- **Icon spacing** - spacing between the three icons in pixels.
- **Active / inactive icon color** - palette role for active and idle icons.

## Notes

- History is capped at the 50 most recent events and stored in the plugin
  data directory (`privacy_indicator/history.json`).
- The service spawns `pw-dump` and a short `/proc` scan every two seconds; no
  network access is used.

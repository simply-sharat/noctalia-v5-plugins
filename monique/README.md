# Monique

Monitor profile switcher for the bar, powered by [Monique](https://github.com/ToRvaLDz/monique).

## Description

Switches between saved monitor profiles directly from the bar. The plugin runs Monique's CLI in the background, tracks which profile is currently active, and shows it on the bar. Open the panel to pick another profile, or middle-click to launch the Monique editor.

## Features

- Bar widget with the active profile name (optional label)
- Panel listing all saved profiles with one-click switching
- Toast notification on switch (and on failure)
- Middle click opens the Monique editor
- Configurable refresh interval, icon color, and label visibility

## Dependencies

- [Monique](https://github.com/ToRvaLDz/monique) must be installed and available as `monique` in `PATH`

## Usage

- Left click: open the profile panel
- Middle click: open the Monique editor
- Right click: plugin settings

## Settings

- `Refresh interval` — how often to poll for the active profile (milliseconds)
- `Icon color` — color of the icon in the bar
- `Show profile name` — display the active profile name next to the icon

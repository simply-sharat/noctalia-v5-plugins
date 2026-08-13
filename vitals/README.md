# Vitals

System monitoring for the bar and a details panel: CPU, memory, GPU,
temperatures, voltages, fans, network, disk and battery. Ported from the
GNOME Shell extension Vitals.

- **Service** (`service.luau`) reads `/proc` and `/sys` kernel sensors on an
  interval, formats them, applies warning/critical colors, and publishes the
  result to shared state.
- **Bar widget** shows the enabled categories (CPU, memory, GPU, temperatures,
  fans, network, disk, battery, system load) as colored values with an icon in
  front of each. Left click opens the panel, middle click refreshes, right
  click opens settings.
- **Panel** shows every sensor grouped by category with a live summary line
  per category.

## Sensors

The bar contents are chosen with a toggle per category in the widget settings
(CPU, memory, GPU, temperatures, fans, network, disk, battery, system load).
For precise control, the advanced "Sensors in the bar" list overrides the
toggles with exact sensor keys. The service publishes the following keys under
`vitals.data.sensors`:

| Key | Meaning |
|---|---|
| `cpu_usage` | CPU usage (0–1) |
| `cpu_freq` | Average CPU frequency (Hz) |
| `cpu_core_N` | Per-core usage (0–1) |
| `mem_usage` / `mem_total` / `mem_available` / `mem_used` / `mem_cached` / `mem_free` | Memory (kB) and usage |
| `mem_swap_total` / `mem_swap_used` / `mem_swap_free` | Swap (kB) |
| `gpu_usage` / `gpu_temp` / `gpu_mem_used` / `gpu_mem_total` | GPU monitor probe |
| `temp_<label>` | hwmon temperatures (millidegrees) |
| `volt_<label>` | hwmon voltages (millivolts) |
| `fan_<label>` | hwmon fan speeds (RPM) |
| `net_rx` / `net_tx` | Current network rates (bytes/s) |
| `net_rx_total` / `net_tx_total` | Lifetime byte counters |
| `disk_usage` / `disk_total` / `disk_free` / `disk_used` | Monitored mount |
| `disk_read_rate` / `disk_write_rate` | Disk rates (bytes/s) |
| `load_1m` / `load_5m` / `load_15m` | Load averages |
| `uptime` | System uptime |
| `threads_active` / `threads_total` / `open_files` | Kernel counters |
| `battery_state` / `battery_percent` / `battery_power` / `battery_time_left` | Battery status |
| `pub_ip` | Public IP (only when enabled) |

## Notes

- The bar widget shows a category icon in front of each sensor ("Show metric
  icons" setting). CPU, memory, temperature, network, disk, fan, voltage, GPU,
  system and battery each get their own icon.
- By default each reading in the bar is padded (monospace) to the widest value
  it can display, so the bar never shifts as readings change. Disable the
  "Fixed width" setting to let each value size itself.
- Temperature thresholds in settings are always Celsius, regardless of the
  display unit.
- Disk rates and usage follow the "Storage mount" setting (default `/`).
- No external tools are required; everything is read from the kernel
  interfaces (procfs/sysfs) plus the optional host monitor GPU probe.

## Requirements

- Noctalia v5 (plugin API 23).

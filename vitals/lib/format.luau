--!nonstrict
-- Formatting helpers, ported from the GNOME Vitals extension's values.js
-- (_legible()). Turns raw sensor values into human-readable text and applies
-- the user's unit / precision preferences.
--
-- M.new(opts) returns a `format(value, formatType) -> string` function.
-- opts:
--   unit              "c" | "f"        temperature unit (default "c")
--   memory_decimal    bool             decimal vs binary memory units
--   storage_decimal   bool             decimal vs binary storage units
--   higher_precision  bool             use one extra decimal place
--   net_bps           bool             report network speed in bits/s
--   net_fixed_unit    0 | 1 | 2        0 auto, 1 force K, 2 force M
--
-- formatType mirrors Vitals' sensor "format" strings: percent, temp, fan, in,
-- hertz, memory, storage, speed, uptime, runtime, load, watt, watt-hour.

local M = {}

local DECIMAL = { "B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB" }
local BINARY = { "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB", "ZiB", "YiB" }
local HERTZ = { "Hz", "KHz", "MHz", "GHz", "THz", "PHz", "EHz", "ZHz" }

M.new = function(opts)
  opts = opts or {}
  local unit = opts.unit or "c"
  local memoryDecimal = opts.memory_decimal == true
  local storageDecimal = opts.storage_decimal == true
  local higher = opts.higher_precision == true
  local bps = opts.net_bps == true
  local netFixedUnit = tonumber(opts.net_fixed_unit) or 0

  local function fmtPercent(value)
    local v = value * 100
    if v > 100 then
      v = 100
    end
    if higher then
      return string.format("%.1f%s", v, "%")
    end
    return string.format("%d%s", math.floor(v + 0.5), "%")
  end

  local function fmtTemp(value)
    local v = value / 1000
    if unit == "f" then
      v = (9 / 5) * v + 32
    end
    if higher then
      return string.format("%.1f%s", v, unit == "f" and "°F" or "°C")
    end
    return string.format("%d%s", math.floor(v + 0.5), unit == "f" and "°F" or "°C")
  end

  local function fmtFan(value)
    return string.format("%d %s", value, "RPM")
  end

  local function fmtVoltage(value)
    local v = value / 1000
    return string.format(higher and "%+.2f %s" or "%+.1f %s", v, "V")
  end

  local function fmtHertz(value)
    local exp = 0
    if value > 0 then
      exp = math.max(0, math.floor(math.log(value) / math.log(1000)))
      if value >= math.pow(1000, exp) * (1000 - 0.05) then
        exp = exp + 1
      end
      value = value / math.pow(1000, exp)
    end
    return string.format(higher and "%.2f %s" or "%.1f %s", value, HERTZ[exp + 1] or "")
  end

  -- Input is kB (as reported by /proc/meminfo), like Vitals.
  local function fmtMemory(value)
    local u = memoryDecimal and 1000 or 1024
    local exp = 0
    if value > 0 then
      value = value * u
      exp = math.floor(math.log(value) / math.log(u))
      if value >= math.pow(u, exp) * (u - 0.05) then
        exp = exp + 1
      end
      value = value / math.pow(u, exp)
    end
    local endings = memoryDecimal and DECIMAL or BINARY
    return string.format(higher and "%.2f %s" or "%.1f %s", value, endings[exp + 1] or "")
  end

  -- Input is bytes.
  local function fmtStorage(value)
    local u = storageDecimal and 1000 or 1024
    local exp = 0
    if value > 0 then
      exp = math.floor(math.log(value) / math.log(u))
      if value >= math.pow(u, exp) * (u - 0.05) then
        exp = exp + 1
      end
      value = value / math.pow(u, exp)
    end
    local endings = storageDecimal and DECIMAL or BINARY
    return string.format(higher and "%.2f %s" or "%.1f %s", value, endings[exp + 1] or "")
  end

  -- Input is bytes/sec.
  local function fmtSpeed(value)
    local u = 1000
    local exp = 0
    if value > 0 then
      if bps then
        value = value * 8
      end
      if netFixedUnit > 0 then
        exp = netFixedUnit
        value = value / math.pow(u, exp)
      else
        exp = math.floor(math.log(value) / math.log(u))
        if value >= math.pow(u, exp) * (u - 0.05) then
          exp = exp + 1
        end
        value = value / math.pow(u, exp)
      end
    end
    local ending
    if bps then
      ending = (DECIMAL[exp + 1] or "B"):gsub("B", "bps")
    else
      ending = (DECIMAL[exp + 1] or "") .. "/s"
    end
    return string.format(higher and "%.1f %s" or "%.0f %s", value, ending)
  end

  local function fmtUptime(value, withSeconds)
    local divisors = withSeconds and { 86400, 3600, 60, 1 } or { 86400, 3600, 60 }
    local units = withSeconds and { "d ", "h ", "m ", "s " } or { "d ", "h ", "m " }
    local remaining = math.max(0, math.floor(value))
    local parts = {}
    local started = false
    for i, div in ipairs(divisors) do
      local count = math.floor(remaining / div)
      remaining = remaining % div
      if count > 0 then
        started = true
      end
      if started then
        table.insert(parts, tostring(count) .. units[i])
      end
    end
    if #parts == 0 then
      return "0m"
    end
    return table.concat(parts, ""):gsub("%s+$", "")
  end

  local function fmtLoad(value)
    return string.format(higher and "%.2f" or "%.1f", value)
  end

  -- Input is microwatts.
  local function fmtWatt(value)
    return string.format(higher and "%+.2f %s" or "%+.1f %s", value / 1000000, "W")
  end

  -- Input is microwatt-hours.
  local function fmtWattHour(value)
    return string.format(higher and "%.2f %s" or "%.1f %s", value / 1000000, "Wh")
  end

  local function fmtString(value)
    return tostring(value)
  end

  return function(value, formatType)
    if value == nil then
      return "N/A"
    end
    if formatType == "percent" then
      return fmtPercent(value)
    elseif formatType == "temp" then
      return fmtTemp(value)
    elseif formatType == "fan" then
      return fmtFan(value)
    elseif formatType == "in" then
      return fmtVoltage(value)
    elseif formatType == "hertz" then
      return fmtHertz(value)
    elseif formatType == "memory" then
      return fmtMemory(value)
    elseif formatType == "storage" then
      return fmtStorage(value)
    elseif formatType == "speed" then
      return fmtSpeed(value)
    elseif formatType == "uptime" then
      return fmtUptime(value, true)
    elseif formatType == "runtime" then
      return fmtUptime(value, false)
    elseif formatType == "load" then
      return fmtLoad(value)
    elseif formatType == "watt" then
      return fmtWatt(value)
    elseif formatType == "watt-hour" then
      return fmtWattHour(value)
    end
    return fmtString(value)
  end
end

return M

--!nonstrict
-- Hyprland backend for Monitor Layout. Pure data transforms: build the fetch
-- command, parse `hyprctl monitors -j`, build an apply script and a config-file
-- snippet. Mirrors the legacy v4 backends/HyprlandBackend.js.

local M = {}

local function formatHz(value)
  local text = string.format("%.2f", value)
  return text:gsub("%.?0+$", "")
end

local function modeIdFromRes(width, height, refresh)
  if refresh ~= nil and refresh > 0 then
    return tostring(width) .. "x" .. tostring(height) .. "@" .. formatHz(refresh)
  end
  return tostring(width) .. "x" .. tostring(height)
end

local function modeLabel(width, height, refresh)
  local text = tostring(width) .. "x" .. tostring(height)
  if refresh ~= nil and refresh > 0 then
    text = text .. " @ " .. formatHz(refresh) .. " Hz"
  end
  return text
end

local function sanitizeNumber(value)
  local numeric = tonumber(value)
  if numeric == nil or numeric <= 0 then
    return "1"
  end
  return string.format("%.2f", numeric):gsub("%.?0+$", "")
end

local function shellQuote(value)
  return "'" .. string.gsub(tostring(value), "'", "'\\''") .. "'"
end

local function describeMonitor(monitor)
  local parts = {}
  if monitor.make ~= nil and monitor.make ~= "" then
    table.insert(parts, monitor.make)
  end
  if monitor.model ~= nil and monitor.model ~= "" then
    table.insert(parts, monitor.model)
  end
  if monitor.serial ~= nil and monitor.serial ~= "" then
    table.insert(parts, monitor.serial)
  end
  return table.concat(parts, " ")
end

local function normalizeRefreshRate(refresh)
  local numeric = tonumber(refresh)
  if numeric == nil or numeric <= 0 then
    return 60
  end
  if numeric >= 1000 then
    return numeric / 1000
  end
  return numeric
end

-- "" when no usable rate, a "60"-style string when valid, nil when out of range.
local function formatRefreshForCommand(refresh)
  if refresh == nil or refresh == "" then
    return ""
  end
  local normalized = normalizeRefreshRate(refresh)
  if normalized < 1 or normalized > 1000 then
    return nil
  end
  return formatHz(normalized)
end

local COMMON_RESOLUTIONS = {
  { w = 1024, h = 768 },
  { w = 1280, h = 720 },
  { w = 1280, h = 800 },
  { w = 1280, h = 1024 },
  { w = 1366, h = 768 },
  { w = 1600, h = 900 },
  { w = 1680, h = 1050 },
  { w = 1920, h = 1080 },
  { w = 2560, h = 1440 },
  { w = 3440, h = 1440 },
  { w = 3840, h = 2160 },
  { w = 5120, h = 2880 },
}

local COMMON_REFRESH_RATES = { 30, 50, 60, 75, 90, 100, 120, 144, 165, 180, 200, 240 }

-- Hyprland does not expose per-output mode lists here, so seed the picker with
-- the current mode plus a deduplicated set of common presets.
local function buildCommonModes(currentWidth, currentHeight, currentRefresh)
  local normalizedRefresh = normalizeRefreshRate(currentRefresh)
  local modes = {}
  local seen = {}

  local function pushMode(width, height, refresh, preferred)
    local normalized = normalizeRefreshRate(refresh)
    local modeId = modeIdFromRes(width, height, normalized)
    if seen[modeId] then
      return
    end
    seen[modeId] = true
    table.insert(modes, {
      id = modeId,
      width = width,
      height = height,
      refresh = normalized,
      label = modeLabel(width, height, normalized),
      preferred = preferred,
    })
  end

  pushMode(currentWidth, currentHeight, normalizedRefresh, true)

  for _, res in ipairs(COMMON_RESOLUTIONS) do
    for _, hz in ipairs(COMMON_REFRESH_RATES) do
      local preferred = res.w == currentWidth
        and res.h == currentHeight
        and math.round(hz) == math.round(normalizedRefresh)
      pushMode(res.w, res.h, hz, preferred)
    end
  end

  return modes
end

function M.buildFetchCommand(cmd)
  return cmd .. " monitors -j"
end

function M.parseOutputs(rawText)
  local parsed, decodeErr = noctalia.json.decode(rawText or "[]")
  if decodeErr ~= nil or type(parsed) ~= "table" then
    return nil, "Failed to parse Hyprland monitor data."
  end

  local outputs = {}

  for _, monitor in ipairs(parsed) do
    if monitor ~= nil and not monitor.disabled then
      local width = monitor.width or 1920
      local height = monitor.height or 1080
      local refresh = normalizeRefreshRate(monitor.refreshRate)
      local scale = tonumber(monitor.scale) or 1
      local logicalWidth = math.max(1, math.round(width / scale))
      local logicalHeight = math.max(1, math.round(height / scale))
      local currentModeId = modeIdFromRes(width, height, refresh)

      table.insert(outputs, {
        output_id = monitor.name,
        name = monitor.name,
        make = monitor.make or "",
        model = monitor.model or "",
        serial = monitor.serial or "",
        active = not monitor.disabled,
        focused = monitor.focused == true,
        x = monitor.x or 0,
        y = monitor.y or 0,
        width = width,
        height = height,
        logical_width = logicalWidth,
        logical_height = logicalHeight,
        scale = scale,
        transform = tostring(monitor.transform or 0),
        refresh = refresh,
        mode_id = currentModeId,
        resolution_label = modeLabel(width, height, refresh),
        available_modes = buildCommonModes(width, height, refresh),
        description = describeMonitor(monitor),
      })
    end
  end

  table.sort(outputs, function(left, right)
    if left.active ~= right.active then
      return left.active
    end
    if left.x ~= right.x then
      return left.x < right.x
    end
    if left.y ~= right.y then
      return left.y < right.y
    end
    return left.name < right.name
  end)

  return outputs, nil
end

function M.buildApplyCommand(outputs, cmd)
  if #outputs == 0 then
    return nil, "No outputs available to apply."
  end

  local commands = {}
  for _, output in ipairs(outputs) do
    if output.active ~= false then
      local resolution = tostring(output.width) .. "x" .. tostring(output.height)
      local refresh = formatRefreshForCommand(output.refresh)
      if refresh == nil then
        return nil, "Refusing to apply an invalid refresh rate for output '" .. output.name .. "'."
      end
      if refresh ~= "" then
        resolution = resolution .. "@" .. refresh
      end

      local position = tostring(math.round(output.x)) .. "x" .. tostring(math.round(output.y))
      local scale = sanitizeNumber(output.scale or 1)

      -- hyprctl keyword monitor NAME,RESOLUTION,POSITION,SCALE
      local line = shellQuote(cmd) .. " keyword monitor "
        .. shellQuote(output.name) .. ","
        .. shellQuote(resolution) .. ","
        .. shellQuote(position) .. ","
        .. shellQuote(scale)
      table.insert(commands, line)
    end
  end

  if #commands == 0 then
    return nil, "There are no active outputs to configure."
  end

  return table.concat(commands, " && "), nil
end

function M.buildConfigContent(outputs)
  if #outputs == 0 then
    return nil, "No outputs available to configure."
  end

  local lines = {}
  for _, output in ipairs(outputs) do
    if output.active ~= false then
      local resolution = tostring(output.width) .. "x" .. tostring(output.height)
      local refresh = formatRefreshForCommand(output.refresh)
      if refresh == nil then
        return nil, "Refusing to generate config for invalid refresh rate for output '" .. output.name .. "'."
      end
      if refresh ~= "" then
        resolution = resolution .. "@" .. refresh
      end

      local position = tostring(math.round(output.x)) .. "x" .. tostring(math.round(output.y))
      local scale = sanitizeNumber(output.scale or 1)

      -- Hyprland config format: monitor=NAME,RESOLUTION,POSITION,SCALE
      table.insert(lines, "monitor=" .. output.name .. "," .. resolution .. "," .. position .. "," .. scale)
    end
  end

  if #lines == 0 then
    return nil, "There are no active outputs to configure."
  end

  return table.concat(lines, "\n"), nil
end

return M

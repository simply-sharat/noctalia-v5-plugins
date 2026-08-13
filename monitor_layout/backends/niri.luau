--!nonstrict
-- Niri backend for Monitor Layout. Pure data transforms: build the fetch
-- command, parse `niri msg -j outputs`, build an apply script and a
-- config-file snippet.

local M = {}

-- "60" for 60.00, "59.94" for 59.94, "59.9" for 59.90.
local function formatHz(value)
  local text = string.format("%.2f", value)
  return text:gsub("%.?0+$", "")
end

-- Niri reports refresh rates as milli-Hz integers (e.g. 60001 for 60.001 Hz)
-- and its mode selector matches the exact mode, so keep three decimals to
-- avoid truncating a 60.001 Hz laptop panel to a nonexistent "60" mode.
local function formatRefreshForCommand(value)
  if value == nil or value <= 0 then
    return ""
  end
  local text = string.format("%.3f", value):gsub("%.?0+$", "")
  if text == "" then
    text = "0"
  end
  return text
end

local function modeIdFromMode(width, height, refresh)
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

local function describeOutput(output)
  local parts = {}
  if output.make ~= nil and output.make ~= "" then
    table.insert(parts, output.make)
  end
  if output.model ~= nil and output.model ~= "" then
    table.insert(parts, output.model)
  end
  if output.serial ~= nil and output.serial ~= "" then
    table.insert(parts, output.serial)
  end
  return table.concat(parts, " ")
end

function M.buildFetchCommand(cmd)
  return cmd .. " msg -j outputs"
end

function M.parseOutputs(rawText)
  local parsed, decodeErr = noctalia.json.decode(rawText or "{}")
  if decodeErr ~= nil or type(parsed) ~= "table" then
    return nil, "Failed to parse Niri output data."
  end

  local outputs = {}

  for name, output in pairs(parsed) do
    if type(output) == "table" then
      local logical = output.logical or {}
      local modes = output.modes or {}
      local modeIndex = tonumber(output.current_mode)
      local currentMode = nil
      if modeIndex ~= nil and modeIndex >= 0 and modeIndex < #modes then
        currentMode = modes[modeIndex + 1]
      end

      local modeWidth = currentMode ~= nil and currentMode.width or logical.width or 1920
      local modeHeight = currentMode ~= nil and currentMode.height or logical.height or 1080
      local refresh = currentMode ~= nil and (currentMode.refresh_rate or 0) / 1000 or 0
      local scale = tonumber(logical.scale) or 1
      local transform = string.lower(logical.transform or "normal")
      local currentModeId = modeIdFromMode(modeWidth, modeHeight, refresh)

      local available = {}
      for _, mode in ipairs(modes) do
        local modeRefresh = (mode.refresh_rate or 0) / 1000
        table.insert(available, {
          id = modeIdFromMode(mode.width, mode.height, modeRefresh),
          width = mode.width,
          height = mode.height,
          refresh = modeRefresh,
          label = modeLabel(mode.width, mode.height, modeRefresh),
          preferred = mode.is_preferred == true,
        })
      end

      table.insert(outputs, {
        output_id = name,
        name = name,
        make = output.make or "",
        model = output.model or "",
        serial = output.serial or "",
        active = true,
        focused = false,
        x = tonumber(logical.x) or 0,
        y = tonumber(logical.y) or 0,
        width = modeWidth,
        height = modeHeight,
        logical_width = tonumber(logical.width) or modeWidth,
        logical_height = tonumber(logical.height) or modeHeight,
        scale = scale,
        transform = transform,
        refresh = refresh,
        mode_id = currentModeId,
        resolution_label = modeLabel(modeWidth, modeHeight, refresh),
        available_modes = available,
        description = describeOutput(output),
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
      if refresh ~= "" then
        resolution = resolution .. "@" .. refresh
      end

      local transform = tostring(output.transform or "normal")
      if transform == "" then
        transform = "normal"
      end

      local parts = {
        shellQuote(cmd),
        "msg",
        "output",
        shellQuote(output.name),
        "position",
        "set",
        tostring(math.round(output.x)),
        tostring(math.round(output.y)),
        "mode",
        shellQuote(resolution),
        "scale",
        sanitizeNumber(output.scale or 1),
        "transform",
        shellQuote(transform),
      }
      table.insert(commands, table.concat(parts, " "))
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

  local blocks = {}
  for _, output in ipairs(outputs) do
    if output.active ~= false then
      local resolution = tostring(output.width) .. "x" .. tostring(output.height)
      local refresh = formatRefreshForCommand(output.refresh)
      if refresh ~= "" then
        resolution = resolution .. "@" .. refresh
      end

      local transform = tostring(output.transform or "normal")
      if transform == "" then
        transform = "normal"
      end

      local lines = {
        "output " .. shellQuote(output.name) .. " {",
        "    mode " .. shellQuote(resolution),
        "    position { x = " .. tostring(math.round(output.x)) .. "; y = " .. tostring(math.round(output.y)) .. "; }",
        "    scale " .. sanitizeNumber(output.scale or 1),
        "    transform " .. shellQuote(transform),
        "}",
      }
      table.insert(blocks, table.concat(lines, "\n"))
    end
  end

  if #blocks == 0 then
    return nil, "There are no active outputs to configure."
  end

  return table.concat(blocks, "\n\n"), nil
end

return M

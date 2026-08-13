--!nonstrict
-- Sway backend for Monitor Layout. Pure data transforms: build the fetch
-- command, parse `swaymsg -t get_outputs -r`, build an apply script and a
-- config-file snippet. Mirrors the legacy v4 backends/SwayBackend.js.

local M = {}

-- "60" for 60.00, "59.94" for 59.94, "59.9" for 59.90.
local function formatHz(value)
  local text = string.format("%.2f", value)
  return text:gsub("%.?0+$", "")
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
  return cmd .. " -t get_outputs -r"
end

function M.parseOutputs(rawText)
  local parsed, decodeErr = noctalia.json.decode(rawText or "[]")
  if decodeErr ~= nil or type(parsed) ~= "table" then
    return nil, "Failed to parse Sway output data."
  end

  local outputs = {}

  for _, output in ipairs(parsed) do
    if output ~= nil and not output.non_desktop then
      local currentMode = output.current_mode or {}
      local rect = output.rect or {}
      local scale = tonumber(output.scale) or 1
      local modeWidth = currentMode.width or 0
      if modeWidth <= 0 then
        modeWidth = rect.width or 0
      end
      if modeWidth <= 0 then
        modeWidth = 1920
      end
      local modeHeight = currentMode.height or 0
      if modeHeight <= 0 then
        modeHeight = rect.height or 0
      end
      if modeHeight <= 0 then
        modeHeight = 1080
      end
      local logicalWidth = rect.width ~= nil and rect.width > 0 and rect.width or math.max(1, math.round(modeWidth / scale))
      local logicalHeight = rect.height ~= nil and rect.height > 0 and rect.height or math.max(1, math.round(modeHeight / scale))
      local refresh = (currentMode.refresh or 0) / 1000
      local currentModeId = modeIdFromMode(modeWidth, modeHeight, refresh)

      local modes = {}
      for _, mode in ipairs(output.modes or {}) do
        local modeRefresh = (mode.refresh or 0) / 1000
        table.insert(modes, {
          id = modeIdFromMode(mode.width, mode.height, modeRefresh),
          width = mode.width,
          height = mode.height,
          refresh = modeRefresh,
          label = modeLabel(mode.width, mode.height, modeRefresh),
          preferred = mode.preferred == true,
        })
      end

      if #modes == 0 then
        table.insert(modes, {
          id = currentModeId,
          width = modeWidth,
          height = modeHeight,
          refresh = refresh,
          label = modeLabel(modeWidth, modeHeight, refresh),
          preferred = true,
        })
      end

      table.insert(outputs, {
        output_id = output.name,
        name = output.name,
        make = output.make or "",
        model = output.model or "",
        serial = output.serial or "",
        active = output.active ~= false,
        focused = output.focused == true,
        x = rect.x or 0,
        y = rect.y or 0,
        width = modeWidth,
        height = modeHeight,
        logical_width = logicalWidth,
        logical_height = logicalHeight,
        scale = scale,
        transform = output.transform or "normal",
        refresh = refresh,
        mode_id = currentModeId,
        resolution_label = modeLabel(modeWidth, modeHeight, refresh),
        available_modes = modes,
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
      if output.refresh ~= nil and output.refresh > 0 then
        resolution = resolution .. "@" .. formatHz(output.refresh) .. "Hz"
      end

      local parts = {
        shellQuote(cmd),
        "--",
        "output",
        shellQuote(output.name),
        "enable",
        "pos",
        tostring(math.round(output.x)),
        tostring(math.round(output.y)),
        "res",
        shellQuote(resolution),
        "scale",
        sanitizeNumber(output.scale or 1),
        "transform",
        shellQuote(output.transform or "normal"),
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

  local lines = {}
  for _, output in ipairs(outputs) do
    if output.active ~= false then
      local resolution = tostring(output.width) .. "x" .. tostring(output.height)
      if output.refresh ~= nil and output.refresh > 0 then
        resolution = resolution .. "@" .. formatHz(output.refresh) .. "Hz"
      end

      local line = "output " .. output.name
        .. " mode " .. resolution
        .. " position " .. tostring(math.round(output.x)) .. "," .. tostring(math.round(output.y))
        .. " scale " .. sanitizeNumber(output.scale or 1)

      if output.transform ~= nil and output.transform ~= "normal" then
        line = line .. " transform " .. output.transform
      end

      table.insert(lines, line)
    end
  end

  if #lines == 0 then
    return nil, "There are no active outputs to configure."
  end

  return table.concat(lines, "\n"), nil
end

return M

--!nonstrict
-- Vitals [[widget]] bar widget.
--
-- A thin client of the service state ("vitals.data"): renders the configured
-- hot sensors as a row of colored labels, shows "--" for anything not sampled
-- yet, and exposes a rich hover tooltip. Click opens the panel, middle click
-- forces a refresh, right click opens the plugin settings (middle is freed
-- from the built-in settings binding in plugin.toml via [widget.actions]).

local hotSensors = noctalia.getConfig("hot_sensors") or {}
local showGlyph = noctalia.getConfig("show_glyph") ~= false
local glyphName = noctalia.getConfig("glyph") or "activity"
local showIcons = noctalia.getConfig("show_icons") ~= false

-- Bar contents: each category has a toggle setting that adds its headline
-- reading (the service's per-category group summary) to the bar. Order here is
-- the canonical bar order. An explicit hot_sensors list overrides the toggles.
local barCategories = {
  { setting = "show_cpu", category = "cpu" },
  { setting = "show_memory", category = "memory" },
  { setting = "show_gpu", category = "gpu" },
  { setting = "show_temp", category = "temp" },
  { setting = "show_fan", category = "fan" },
  { setting = "show_net", category = "net" },
  { setting = "show_disk", category = "disk" },
  { setting = "show_battery", category = "battery" },
  { setting = "show_system", category = "system" },
}

local data = nil

local function hotSensorKeys()
  if type(hotSensors) == "string" then
    local keys = {}
    for key in hotSensors:gmatch("[^,]+") do
      keys[#keys + 1] = key
    end
    return keys
  end
  return hotSensors or {}
end

-- Pad to a fixed monospace character width (cell width, not byte length, so
-- multi-byte glyphs like the network arrows count as one cell each).
local function padTo(text, width)
  if width == nil or width <= 0 then
    return text
  end
  local len = utf8 ~= nil and utf8.len ~= nil and utf8.len(text) or #text
  local pad = width - (len or #text)
  if pad <= 0 then
    return text
  end
  return text .. string.rep(" ", pad)
end

local function metricRow(category, text, width, color, fixedWidth)
  local row = {}
  if showIcons then
    local glyph = "info"
    if data ~= nil and data.category_glyphs ~= nil then
      glyph = data.category_glyphs[category] or "info"
    end
    row[#row + 1] = ui.glyph({ name = glyph, size = 12, color = "primary" })
  end
  local props = { text = text, fontSize = 11 }
  if fixedWidth then
    props.fontFamily = "monospace"
    props.text = padTo(text, width)
  end
  if color ~= nil then
    props.color = color
  end
  row[#row + 1] = ui.label(props)
  return ui.row({ gap = 4, align = "center" }, row)
end

local function render()
  local fixedWidth = noctalia.getConfig("fixed_width") ~= false
  local container = barWidget.isVertical() and ui.column or ui.row
  local children = {}

  if showGlyph then
    children[#children + 1] = ui.glyph({ name = glyphName, size = 14, color = "primary" })
  end

  local keys = hotSensorKeys()
  if #keys > 0 then
    for _, key in ipairs(keys) do
      local sensor = (data ~= nil and data.sensors[key]) or nil
      local category = (sensor ~= nil and sensor.category) or nil
      children[#children + 1] = metricRow(
        category,
        (sensor ~= nil and sensor.text) or "--",
        (sensor ~= nil and sensor.width_chars) or nil,
        (sensor ~= nil and sensor.color) or nil,
        fixedWidth
      )
    end
  else
    for _, item in ipairs(barCategories) do
      if noctalia.getConfig(item.setting) then
        local group = (data ~= nil and data.groups[item.category]) or nil
        if group ~= nil then
          children[#children + 1] = metricRow(
            item.category,
            group.text,
            (data ~= nil and data.group_width_chars ~= nil and data.group_width_chars[item.category]) or nil,
            group.color,
            fixedWidth
          )
        end
      end
    end
  end

  barWidget.render(container({ gap = 6, align = "center" }, children))
end

local function renderTooltip()
  if data == nil or #data.categories == 0 then
    barWidget.setTooltip(noctalia.tr("widget.tooltip"))
    return
  end

  local lines = {}
  for _, category in ipairs(data.categories) do
    local group = data.groups[category]
    if group ~= nil then
      lines[#lines + 1] = data.category_labels[category] .. ": " .. group.text
    end
  end
  if #lines == 0 then
    lines[1] = noctalia.tr("widget.loading")
  end

  local divider = "───────────────"
  lines[#lines + 1] = divider
  lines[#lines + 1] = noctalia.tr("panel.last_update") .. ": " .. data.last_update

  barWidget.setTooltip(table.concat(lines, "\n"))
end

noctalia.state.watch("vitals.data", function(value)
  if type(value) == "table" then
    data = value
    render()
    renderTooltip()
  end
end)

function onClick()
  noctalia.togglePanel("simply-sharat/vitals:panel")
end

function onMiddleClick()
  noctalia.state.set("vitals.cmd", "refresh")
end

function onRightClick()
  noctalia.openSettings()
end

data = noctalia.state.get("vitals.data")
render()
renderTooltip()

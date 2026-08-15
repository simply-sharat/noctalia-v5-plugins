--!nonstrict
-- BudsLink [[widget]] bar widget.
--
-- A thin client of the service state ("budslink.data"): a device glyph tinted
-- with the configured active color, an optional battery percentage, and a
-- rich hover tooltip. Click opens the panel, middle click forces a refresh,
-- right click opens the plugin settings (middle is freed from the built-in
-- settings binding in plugin.toml via [widget.actions]).

local showBatteryText = noctalia.getConfig("show_battery_text") ~= false
local activeColor = noctalia.getConfig("active_color") or "primary"

local data = nil

-- BudsLink device icons (config.commonIcon) mapped to Tabler glyph names.
local ICON_MAP = {
  ["audio-headphones"] = "headphones",
  ["headphone1"] = "headphones",
  ["audio-headset"] = "headset",
  ["earbuds-neckband"] = "headset",
  ["earbuds"] = "ear",
  ["earbuds-wingtip"] = "ear",
  ["earbuds-wingtip2"] = "ear",
  ["earbuds-stem"] = "ear",
  ["earbuds-stem2"] = "ear",
  ["earbuds-stem3"] = "ear",
  ["earbuds-bean"] = "ear",
}

local function firstDevice()
  return (data ~= nil and data.devices ~= nil and #data.devices > 0) and data.devices[1] or nil
end

local function deviceIcon()
  local device = firstDevice()
  if device == nil then
    return "headphones"
  end
  local icon = (device.config or {}).commonIcon
  return ICON_MAP[icon] or "headphones"
end

local function computedBattery()
  local device = firstDevice()
  if device == nil then
    return -1
  end
  return tonumber((device.state or {}).computedBatteryLevel) or -1
end

local function batteryText()
  local battery = computedBattery()
  return battery >= 0 and (tostring(battery) .. "%") or "..."
end

local function batteryStatusLine(name, level, status)
  if status == "not-reported" or status == "disconnected" then
    return nil
  end
  return string.format("  %s: %d%% %s", name, level, status)
end

local function renderTooltip()
  local device = firstDevice()
  if device == nil then
    barWidget.setTooltip(noctalia.tr("widget.tooltip_disconnected"))
    return
  end

  local s = device.state or {}
  local c = device.config or {}
  local lines = { (device.alias ~= nil and device.alias ~= "") and device.alias or "BudsLink" }

  local line
  line = batteryStatusLine(noctalia.tr("battery.left"), s.battery1Level, s.battery1Status)
  if line ~= nil then lines[#lines + 1] = line end
  line = batteryStatusLine(noctalia.tr("battery.right"), s.battery2Level, s.battery2Status)
  if line ~= nil then lines[#lines + 1] = line end
  line = batteryStatusLine(noctalia.tr("battery.case"), s.battery3Level, s.battery3Status)
  if line ~= nil then lines[#lines + 1] = line end

  if s.toggle1Visible and c.toggle1Title ~= nil then
    local name = c["toggle1Button" .. tostring(s.toggle1State or 0) .. "Name"]
    lines[#lines + 1] = string.format("  %s: %s", c.toggle1Title, name or "Off")
  end

  local box = tonumber(s.optionsBoxVisible or 0) or 0
  if box > 0 then
    local radioTitle = c["box" .. tostring(box) .. "RadioTitle"]
    local radioOptions = c["box" .. tostring(box) .. "RadioButton"] or {}
    local radioState = tonumber(s["box" .. tostring(box) .. "RadioButtonState"] or 0) or 0
    if radioTitle ~= nil and #radioOptions > 0 and radioState > 0 then
      lines[#lines + 1] = string.format("  %s: %s", radioTitle, radioOptions[radioState])
    end
    local sliderTitle = c["box" .. tostring(box) .. "SliderTitle"]
    local sliderValue = tonumber(s["box" .. tostring(box) .. "SliderValue"] or -1) or -1
    if sliderTitle ~= nil and sliderValue >= 0 then
      lines[#lines + 1] = string.format("  %s: %d", sliderTitle, sliderValue)
    end
  end

  for _, key in ipairs({ "labelIndicator1", "labelIndicator2", "labelIndicator3" }) do
    local label = s[key]
    if label ~= nil and #label > 0 then
      lines[#lines + 1] = "  " .. label
    end
  end

  barWidget.setTooltip(table.concat(lines, "\n"))
end

local function render()
  local connected = data ~= nil and data.connected == true

  local container = barWidget.isVertical() and ui.column or ui.row
  local children = {
    ui.glyph({
      name = deviceIcon(),
      size = 14,
      color = activeColor,
      opacity = connected and 1 or 0.45,
    }),
  }

  if connected and showBatteryText then
    children[#children + 1] = ui.label({
      text = batteryText(),
      fontSize = 11,
      color = activeColor,
    })
  end

  barWidget.render(container({ gap = 6, align = "center" }, children))
end

noctalia.state.watch("budslink.data", function(value)
  if type(value) == "table" then
    data = value
    render()
    renderTooltip()
  end
end)

function onClick()
  noctalia.togglePanel("simply-sharat/budslink:panel")
end

function onMiddleClick()
  noctalia.state.set("budslink.cmd", { action = "refresh" })
end

function onRightClick()
  noctalia.openSettings()
end

data = noctalia.state.get("budslink.data")
render()
renderTooltip()

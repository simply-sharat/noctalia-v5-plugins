--!nonstrict
-- Air Quality [[widget]] bar widget.
--
-- A thin client of the service state ("aq.data"): renders the AQI number in
-- its level color, shows "--" while there is nothing yet, and exposes a rich
-- hover tooltip. Click opens the panel, middle click forces a refresh, right
-- click opens the plugin settings (middle is freed from the built-in settings
-- binding in plugin.toml via [widget.actions]).

local scale = noctalia.getConfig("aqi_scale") or "us"
local boldText = noctalia.getConfig("bold_text")

local data = nil

local function aqiColor(value, aqiScale)
  if aqiScale == "eu" then
    if value <= 20 then return "#50F0E6" end
    if value <= 40 then return "#50CCAA" end
    if value <= 60 then return "#F0E641" end
    if value <= 80 then return "#FF5050" end
    if value <= 100 then return "#960032" end
    return "#7D2181"
  end
  if value <= 50 then return "#00E400" end
  if value <= 100 then return "#FFFF00" end
  if value <= 150 then return "#FF7E00" end
  if value <= 200 then return "#FF0000" end
  if value <= 300 then return "#8F3F97" end
  return "#7E0023"
end

local function aqiLevelKey(value, aqiScale)
  if aqiScale == "eu" then
    if value <= 20 then return "levels.good" end
    if value <= 40 then return "levels.fair" end
    if value <= 60 then return "levels.moderate" end
    if value <= 80 then return "levels.poor" end
    if value <= 100 then return "levels.very_poor" end
    return "levels.extremely_poor"
  end
  if value <= 50 then return "levels.good" end
  if value <= 100 then return "levels.moderate" end
  if value <= 150 then return "levels.unhealthy_sensitive" end
  if value <= 200 then return "levels.unhealthy" end
  if value <= 300 then return "levels.very_unhealthy" end
  return "levels.hazardous"
end

local function currentAqi()
  if data == nil or not data.has_data then
    return 0
  end
  return scale == "eu" and data.eu_aqi or data.us_aqi
end

local function locationLabel()
  if data == nil then
    return ""
  end
  if data.station_name ~= "" then
    return data.station_name
  end
  if data.location_name ~= "" then
    return data.location_name
  end
  if data.has_data then
    return noctalia.tr("location.custom")
  end
  return ""
end

local function render()
  local loading = data ~= nil and data.loading == true
  local hasData = data ~= nil and data.has_data == true
  local aqi = currentAqi()
  local color = hasData and aqiColor(aqi, scale) or "on_surface"

  local container = barWidget.isVertical() and ui.column or ui.row
  local children = {}

  if loading then
    table.insert(children, ui.glyph({ name = "loader", size = 14, color = "on_surface" }))
  else
    table.insert(children, ui.label({
      text = hasData and tostring(aqi) or "--",
      color = color,
      fontWeight = boldText and "bold" or "normal",
    }))
  end

  barWidget.render(container({ gap = 6, align = "center" }, children))
end

local function renderTooltip()
  if data == nil or not data.has_data then
    barWidget.setTooltip(noctalia.tr("widget.tooltip"))
    return
  end

  local aqi = currentAqi()
  local scaleLabel = noctalia.tr(scale == "eu" and "scale.eu" or "scale.us")
  local level = noctalia.tr(aqiLevelKey(aqi, scale))

  local lines = { scaleLabel .. ": " .. tostring(aqi) .. " — " .. level }

  local location = locationLabel()
  if location ~= "" then
    table.insert(lines, location)
  end

  local divider = "───────────────"
  table.insert(lines, divider)

  table.insert(lines, noctalia.tr("pollutants.pm25_value", { value = data.pm25 }))
  table.insert(lines, noctalia.tr("pollutants.pm10_value", { value = data.pm10 }))
  table.insert(lines, noctalia.tr("pollutants.ozone_value", { value = data.ozone }))
  table.insert(lines, noctalia.tr("pollutants.no2_value", { value = data.no2 }))
  table.insert(lines, noctalia.tr("pollutants.co_value", { value = data.co }))
  table.insert(lines, noctalia.tr("pollutants.so2_value", { value = data.so2 }))

  if data.last_update ~= "" then
    table.insert(lines, divider)
    table.insert(lines, noctalia.tr("panel.last_update") .. ": " .. data.last_update)
  end

  barWidget.setTooltip(table.concat(lines, "\n"))
end

noctalia.state.watch("aq.data", function(value)
  data = value
  render()
  renderTooltip()
end)

function onClick()
  noctalia.togglePanel("simply-sharat/air_quality:panel")
end

function onMiddleClick()
  noctalia.state.set("aq.cmd", "refresh")
end

function onRightClick()
  noctalia.openSettings()
end

data = noctalia.state.get("aq.data")
render()
renderTooltip()

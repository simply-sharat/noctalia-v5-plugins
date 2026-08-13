--!nonstrict
-- Air Quality [[desktop_widget]] entry.
--
-- A compact desktop tile mirroring the v4 widget: big AQI number, level label,
-- location, and PM2.5/PM10. The user places and sizes the tile in the
-- desktop-widgets editor; this script only renders content from "aq.data" and
-- offers refresh / settings glyph buttons.

local scale = noctalia.getConfig("aqi_scale") or "us"

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

local function formatValue(value)
  return string.format("%.1f", value)
end

local function render()
  local hasData = data ~= nil and data.has_data == true
  local aqi = currentAqi()
  local color = hasData and aqiColor(aqi, scale) or "on_surface_variant"

  desktopWidget.render(ui.column({ gap = 8, align = "center", fill = "transparent" }, {
    ui.label({
      text = hasData and tostring(aqi) or "--",
      fontSize = 40,
      fontWeight = "bold",
      color = color,
    }),
    ui.label({
      text = hasData and noctalia.tr(aqiLevelKey(aqi, scale)) or noctalia.tr("desktop.no_data"),
      fontSize = 13,
      color = color,
    }),
    ui.label({
      text = locationLabel(),
      fontSize = 11,
      color = "on_surface_variant",
      visible = hasData,
    }),
    ui.row({ gap = 14, align = "center", visible = hasData }, {
      ui.label({ text = noctalia.tr("pollutants.pm25_short", { value = formatValue(data.pm25) }), fontSize = 11, color = "on_surface_variant" }),
      ui.label({ text = noctalia.tr("pollutants.pm10_short", { value = formatValue(data.pm10) }), fontSize = 11, color = "on_surface_variant" }),
    }),
    ui.row({ gap = 6, justify = "center" }, {
      ui.button({ glyph = "refresh", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.refresh"), onClick = "onRefresh" }),
      ui.button({ glyph = "settings", variant = "ghost", controlSize = "sm", tooltip = noctalia.tr("panel.settings"), onClick = "onSettings" }),
    }),
  }))
end

noctalia.state.watch("aq.data", function(value)
  data = value
  render()
end)

function onRefresh()
  noctalia.state.set("aq.cmd", "refresh")
end

function onSettings()
  noctalia.openSettings()
end

data = noctalia.state.get("aq.data")
render()

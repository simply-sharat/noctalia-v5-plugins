--!nonstrict
-- Air Quality [[panel]] entry.
--
-- Declarative details panel: a hero AQI number with its level, the scale,
-- a location / last-update pill, and per-pollutant rows with level-colored
-- dots. Re-renders live from "aq.data"; refresh and settings are offered in
-- the header and footer.

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

local function pollutantColor(pollutant, value)
  local thresholds = {
    pm25 = { 12, 35.4, 55.4, 150.4, 250.4 },
    pm10 = { 54, 154, 254, 354, 424 },
    ozone = { 54, 70, 85, 105, 200 },
    no2 = { 53, 100, 360, 649, 1249 },
    co = { 4400, 9400, 12400, 15400, 30400 },
    so2 = { 35, 75, 185, 304, 604 },
  }
  local colors = { "#4CAF50", "#FFEB3B", "#FF9800", "#F44336", "#9C27B0", "#79000F" }
  local thresholdsList = thresholds[pollutant]
  if thresholdsList == nil then
    return colors[1]
  end
  for index, threshold in ipairs(thresholdsList) do
    if value <= threshold then
      return colors[index]
    end
  end
  return colors[#colors]
end

local pollutants = {
  { key = "pm25", label_key = "pollutants.pm25" },
  { key = "pm10", label_key = "pollutants.pm10" },
  { key = "ozone", label_key = "pollutants.ozone" },
  { key = "no2", label_key = "pollutants.no2" },
  { key = "co", label_key = "pollutants.co" },
  { key = "so2", label_key = "pollutants.so2" },
}

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

local function pollutantRows()
  local rows = {}
  for _, pollutant in ipairs(pollutants) do
    local value = data[pollutant.key] or 0
    table.insert(rows, ui.row({ key = "pollutant-" .. pollutant.key, gap = 10, align = "center", paddingV = 8 }, {
      ui.box({ width = 8, height = 8, radius = 4, fill = pollutantColor(pollutant.key, value) }),
      ui.label({ text = noctalia.tr(pollutant.label_key), color = "on_surface", flexGrow = 1 }),
      ui.label({ text = string.format("%.1f", value), color = "on_surface", fontWeight = "semi_bold" }),
      ui.label({ text = noctalia.tr("unit.ugm3"), color = "on_surface_variant", fontSize = 12 }),
    }))
  end
  return rows
end

local function render()
  local hasData = data ~= nil and data.has_data == true
  local aqi = currentAqi()
  local color = hasData and aqiColor(aqi, scale) or "on_surface_variant"

  local content = {}

  if hasData then
    local location = locationLabel()
    local metaParts = {}
    if location ~= "" then
      table.insert(metaParts, location)
    end
    if data.last_update ~= "" then
      table.insert(metaParts, noctalia.tr("panel.last_update") .. ": " .. data.last_update)
    end

    table.insert(content, ui.label({ text = tostring(aqi), fontSize = 56, fontWeight = "bold", color = color, textAlign = "center" }))
    table.insert(content, ui.label({ text = noctalia.tr(aqiLevelKey(aqi, scale)), fontSize = 16, fontWeight = "semi_bold", color = color, textAlign = "center" }))
    table.insert(content, ui.label({ text = noctalia.tr(scale == "eu" and "scale.eu" or "scale.us"), fontSize = 12, color = "on_surface_variant", textAlign = "center" }))

    if #metaParts > 0 then
      table.insert(content, ui.row({ fill = "surface_variant", radius = 999, paddingH = 16, paddingV = 6, align = "center" }, {
        ui.label({ text = table.concat(metaParts, " · "), fontSize = 12, color = "on_surface_variant" }),
      }))
    end

    table.insert(content, ui.separator({ spacing = 8 }))
    table.insert(content, ui.label({ text = noctalia.tr("panel.pollutants"), fontSize = 13, fontWeight = "bold", color = "on_surface_variant" }))

    for _, row in ipairs(pollutantRows()) do
      table.insert(content, row)
    end
  else
    local loading = data ~= nil and data.loading == true
    local message = noctalia.tr("panel.no_data")
    if loading then
      message = noctalia.tr("panel.loading")
    elseif data ~= nil and data.error ~= "" then
      message = data.error
    end
    table.insert(content, ui.label({ text = message, fontSize = 14, color = "on_surface_variant", textAlign = "center", maxWidth = 320 }))
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", gap = 6 }, {
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "refresh", variant = "ghost", tooltip = noctalia.tr("panel.refresh"), onClick = "onRefresh" }),
      ui.button({ glyph = "settings", variant = "ghost", tooltip = noctalia.tr("panel.settings"), onClick = "onSettings" }),
      ui.button({ glyph = "close", variant = "ghost", tooltip = noctalia.tr("panel.close"), onClick = "onClose" }),
    }),
    ui.scroll({ flexGrow = 1 }, content),
    ui.row({ gap = 10 }, {
      ui.button({ text = noctalia.tr("panel.refresh"), variant = "secondary", flexGrow = 1, onClick = "onRefresh" }),
      ui.button({ text = noctalia.tr("panel.settings"), flexGrow = 1, onClick = "onSettings" }),
    }),
  }))
end

noctalia.state.watch("aq.data", function(value)
  data = value
  render()
end)

function onOpen()
  render()
end

function onRefresh()
  noctalia.state.set("aq.cmd", "refresh")
end

function onSettings()
  noctalia.openSettings()
end

function onClose()
  panel.close()
end

data = noctalia.state.get("aq.data")

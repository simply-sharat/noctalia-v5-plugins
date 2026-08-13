--!nonstrict
-- Air Quality headless [[service]] entry.
--
-- Owns all network work: resolves coordinates (IP / custom / shell location),
-- fetches air quality from Open-Meteo or AQICN, and publishes plain data to
-- noctalia.state under "aq.data". The bar widget, panel and desktop widget
-- are thin UI clients that watch that state and send "refresh" commands back
-- through "aq.cmd".

local dataSource = noctalia.getConfig("data_source") or "open-meteo"
local aqicnToken = noctalia.getConfig("aqicn_token") or ""
local locationMode = noctalia.getConfig("location_mode") or "auto_ip"
local customLatitude = noctalia.getConfig("custom_latitude") or ""
local customLongitude = noctalia.getConfig("custom_longitude") or ""

local intervalSecs = tonumber(noctalia.getConfig("refresh_interval")) or 30
intervalSecs = math.max(5, math.min(3600, intervalSecs))

-- Cached IP-geolocated coordinates, so auto_ip only hits ipapi.co once.
local ipCoords = nil

-- Read the shell's `[location]` table from its config files. This is a
-- plugin_api 23 substitute for noctalia.getSetting("location.*") (API 26,
-- unreleased). settings.toml overrides config.toml, mirroring the shell's
-- effective-config merge. Both coordinates must be present for them to be
-- used, matching the shell's rule that partial manual coordinates are ignored.
local function parseLocationTable(text)
  if text == nil then
    return nil, nil
  end
  local inSection = false
  local lat, lon
  for line in string.gmatch(text, "[^\n]+") do
    local trimmed = noctalia.string.trim(line)
    if string.sub(trimmed, 1, 1) == "[" then
      inSection = trimmed == "[location]"
    elseif inSection and string.sub(trimmed, 1, 1) ~= "#" then
      local key, value = string.match(trimmed, "^([%w_]+)%s*=%s*(.+)$")
      if key ~= nil then
        value = string.match(value, '^"([^"]*)"') or string.match(value, "^([%d%.%-]+)")
        if key == "latitude" then
          lat = tonumber(value)
        elseif key == "longitude" then
          lon = tonumber(value)
        end
      end
    end
  end
  return lat, lon
end

local function readShellLocation()
  local configHome = noctalia.getenv("XDG_CONFIG_HOME")
  local base = (configHome ~= nil and configHome ~= "") and configHome or noctalia.expandPath("~/.config")
  local lat, lon = parseLocationTable(noctalia.readFile(base .. "/noctalia/config.toml"))
  local settingsLat, settingsLon = parseLocationTable(noctalia.readFile(base .. "/noctalia/settings.toml"))
  if settingsLat ~= nil then
    lat = settingsLat
  end
  if settingsLon ~= nil then
    lon = settingsLon
  end
  return lat, lon
end

local current = {
  has_data = false,
  loading = false,
  us_aqi = 0,
  eu_aqi = 0,
  pm25 = 0,
  pm10 = 0,
  ozone = 0,
  no2 = 0,
  co = 0,
  so2 = 0,
  station_name = "",
  location_name = "",
  last_update = "",
  error = "",
}

local function publish(partial)
  for key, value in pairs(partial) do
    current[key] = value
  end
  noctalia.state.set("aq.data", current)
end

-- cb(lat, lon, locationName) on success, cb(nil, nil, errorText) on failure.
local function resolveCoords(cb)
  if locationMode == "custom" then
    local lat = tonumber(noctalia.string.trim(customLatitude))
    local lon = tonumber(noctalia.string.trim(customLongitude))
    if lat == nil or lon == nil then
      cb(nil, nil, noctalia.tr("errors.coords_missing"))
      return
    end
    cb(lat, lon, "")
    return
  elseif locationMode == "shell" then
    local lat, lon = readShellLocation()
    if lat == nil or lon == nil then
      cb(nil, nil, noctalia.tr("errors.shell_location"))
      return
    end
    cb(lat, lon, "")
    return
  end

  -- auto_ip: resolve approximate coordinates from the public IP.
  if ipCoords ~= nil then
    cb(ipCoords.lat, ipCoords.lon, "")
    return
  end
  noctalia.http({ url = "https://ipapi.co/json/" }, function(res)
    if not res.ok or res.status ~= 200 then
      cb(nil, nil, noctalia.tr("errors.geolocate_failed"))
      return
    end
    local parsed, decodeErr = noctalia.json.decode(res.body)
    if decodeErr ~= nil or parsed == nil or parsed.latitude == nil or parsed.longitude == nil then
      cb(nil, nil, noctalia.tr("errors.geolocate_failed"))
      return
    end
    ipCoords = {
      lat = tonumber(parsed.latitude),
      lon = tonumber(parsed.longitude),
      city = parsed.city or "",
    }
    cb(ipCoords.lat, ipCoords.lon, "")
  end)
end

local function fetchOpenMeteo(lat, lon, locationName)
  local url = "https://air-quality-api.open-meteo.com/v1/air-quality?latitude="
    .. lat
    .. "&longitude="
    .. lon
    .. "&current=us_aqi,european_aqi,pm2_5,pm10,ozone,nitrogen_dioxide,carbon_monoxide,sulphur_dioxide&timezone=auto"

  noctalia.http({ url = url }, function(res)
    if not res.ok then
      publish({ loading = false, error = noctalia.tr("errors.fetch_failed") })
      return
    end
    local parsed, decodeErr = noctalia.json.decode(res.body)
    if decodeErr ~= nil or parsed == nil or parsed.current == nil then
      publish({ loading = false, error = noctalia.tr("errors.parse_failed") })
      return
    end
    local c = parsed.current
    publish({
      has_data = true,
      loading = false,
      error = "",
      us_aqi = c.us_aqi or 0,
      eu_aqi = c.european_aqi or 0,
      pm25 = c.pm2_5 or 0,
      pm10 = c.pm10 or 0,
      ozone = c.ozone or 0,
      no2 = c.nitrogen_dioxide or 0,
      co = c.carbon_monoxide or 0,
      so2 = c.sulphur_dioxide or 0,
      station_name = "",
      location_name = locationName,
      last_update = noctalia.formatTime("%H:%M"),
    })
  end)
end

local function fetchAqicn(lat, lon)
  if aqicnToken == "" then
    publish({ loading = false, error = noctalia.tr("errors.token_missing") })
    return
  end

  local url = "https://api.waqi.info/feed/geo:" .. lat .. ";" .. lon .. "/?token=" .. aqicnToken

  noctalia.http({ url = url }, function(res)
    if not res.ok then
      publish({ loading = false, error = noctalia.tr("errors.fetch_failed") })
      return
    end
    local parsed, decodeErr = noctalia.json.decode(res.body)
    if decodeErr ~= nil or parsed == nil or parsed.status ~= "ok" then
      publish({ loading = false, error = noctalia.tr("errors.aqicn_api_failed") })
      return
    end
    local data = parsed.data or {}
    local iaqi = data.iaqi or {}
    local function pollutantValue(name)
      local entry = iaqi[name]
      if entry == nil then
        return 0
      end
      return entry.v or 0
    end

    publish({
      has_data = true,
      loading = false,
      error = "",
      us_aqi = data.aqi or 0,
      eu_aqi = 0,
      pm25 = pollutantValue("pm25"),
      pm10 = pollutantValue("pm10"),
      ozone = pollutantValue("o3"),
      no2 = pollutantValue("no2"),
      co = pollutantValue("co"),
      so2 = pollutantValue("so2"),
      station_name = (data.city or {}).name or "",
      location_name = "",
      last_update = noctalia.formatTime("%H:%M"),
    })
  end)
end

local function refresh()
  if current.loading then
    return
  end

  publish({ loading = true, error = "" })

  resolveCoords(function(lat, lon, errorText)
    if lat == nil then
      publish({ loading = false, error = errorText })
      return
    end

    if dataSource == "aqicn" then
      fetchAqicn(lat, lon)
    else
      local locationName = ipCoords ~= nil and ipCoords.city or ""
      fetchOpenMeteo(lat, lon, locationName)
    end
  end)
end

noctalia.setUpdateInterval(intervalSecs * 60000)

noctalia.state.watch("aq.cmd", function(cmd)
  if cmd == "refresh" then
    refresh()
  end
end)

function update()
  refresh()
end

function onConfigChanged()
  dataSource = noctalia.getConfig("data_source") or "open-meteo"
  aqicnToken = noctalia.getConfig("aqicn_token") or ""
  locationMode = noctalia.getConfig("location_mode") or "auto_ip"
  customLatitude = noctalia.getConfig("custom_latitude") or ""
  customLongitude = noctalia.getConfig("custom_longitude") or ""

  local newInterval = tonumber(noctalia.getConfig("refresh_interval")) or 30
  newInterval = math.max(5, math.min(3600, newInterval))
  if newInterval ~= intervalSecs then
    intervalSecs = newInterval
    noctalia.setUpdateInterval(intervalSecs * 60000)
  end

  refresh()
end

function onIpc(event)
  if event == "refresh" then
    refresh()
  end
end

refresh()

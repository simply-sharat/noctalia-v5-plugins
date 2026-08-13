--!nonstrict
-- Vitals headless [[service]] entry.
--
-- Owns all the data work: reads the kernel sensors (lib/sensors.luau), formats
-- them (lib/format.luau), applies color thresholds, and publishes the result
-- to noctalia.state under "vitals.data". The bar widget and panel are thin UI
-- clients of that shared state and can force a refresh through "vitals.cmd".

local util = require("./lib/util.luau")
local fmtLib = require("./lib/format.luau")
local sensors = require("./lib/sensors.luau")

local config = {
  updateInterval = 2000,
  unit = "c",
  memoryDecimal = false,
  storageDecimal = false,
  higherPrecision = false,
  hideZeros = true,
  storagePath = "/",
  tempWarn = 80,
  tempCrit = 90,
  percentWarn = 80,
  percentCrit = 95,
  includePublicIp = false,
  publicIpProvider = "ipify",
  publicIpInterval = 30,
}

local state = {
  categories = {},
  category_labels = {},
  category_glyphs = {},
  groups = {},
  sensors = {},
  byCategory = {},
  last_update = "",
}

local COLORS = {
  warn = "#F5A623",
  crit = "#E5484D",
}

local formatter = fmtLib.new({})
local publicIp = ""
local lastPublicIpFetchMs = 0
local publicIpBusy = false
local currentCategory = nil
local collectBusy = false

local function readConfig()
  local interval = tonumber(noctalia.getConfig("update_interval")) or 2000
  config.updateInterval = math.max(1000, math.min(30000, interval))
  config.unit = noctalia.getConfig("unit") or "c"
  config.memoryDecimal = noctalia.getConfig("memory_measurement") == "decimal"
  config.storageDecimal = noctalia.getConfig("storage_measurement") == "decimal"
  config.higherPrecision = noctalia.getConfig("use_higher_precision") == true
  config.hideZeros = noctalia.getConfig("hide_zeros") ~= false
  config.storagePath = noctalia.getConfig("storage_path") or "/"
  config.tempWarn = tonumber(noctalia.getConfig("temp_warn")) or 80
  config.tempCrit = tonumber(noctalia.getConfig("temp_crit")) or 90
  config.percentWarn = tonumber(noctalia.getConfig("percent_warn")) or 80
  config.percentCrit = tonumber(noctalia.getConfig("percent_crit")) or 95
  config.includePublicIp = noctalia.getConfig("include_public_ip") == true
  config.publicIpProvider = noctalia.getConfig("public_ip_provider") or "ipify"
  config.publicIpInterval = tonumber(noctalia.getConfig("public_ip_interval")) or 30

  formatter = fmtLib.new({
    unit = config.unit,
    memory_decimal = config.memoryDecimal,
    storage_decimal = config.storageDecimal,
    higher_precision = config.higherPrecision,
  })
  noctalia.setUpdateInterval(config.updateInterval)
end

local function pushCategory(category, labelKey, glyph)
  currentCategory = category
  if state.byCategory[category] == nil then
    table.insert(state.categories, category)
    state.byCategory[category] = {}
    state.category_labels[category] = noctalia.tr(labelKey)
    state.category_glyphs[category] = glyph
  end
end

local function sensorColor(formatType, value)
  if value == nil then
    return nil
  end
  if formatType == "temp" then
    local celsius = value / 1000
    if celsius >= config.tempCrit then
      return COLORS.crit
    end
    if celsius >= config.tempWarn then
      return COLORS.warn
    end
  elseif formatType == "percent" then
    local percent = value * 100
    if percent >= config.percentCrit then
      return COLORS.crit
    end
    if percent >= config.percentWarn then
      return COLORS.warn
    end
  end
  return nil
end

local function addSensor(key, label, value, formatType)
  if value == nil then
    return
  end
  if state.sensors[key] ~= nil then
    key = key .. "_" .. tostring(#state.byCategory[currentCategory] + 1)
  end
  state.sensors[key] = {
    key = key,
    category = currentCategory,
    label = label,
    text = formatter(value, formatType),
    value = value,
    format = formatType,
    color = sensorColor(formatType, value),
  }
  table.insert(state.byCategory[currentCategory], key)
end

local function groupFor(category, text, color)
  if text ~= nil then
    state.groups[category] = { text = text, color = color }
  end
end

local function batteryStateLabel(status)
  if status == "Charging" then
    return noctalia.tr("labels.battery_charging")
  elseif status == "Discharging" then
    return noctalia.tr("labels.battery_discharging")
  elseif status == "Full" then
    return noctalia.tr("labels.battery_full")
  elseif status == "Not charging" then
    return noctalia.tr("labels.battery_not_charging")
  elseif status == "Unknown" or status == "" then
    return noctalia.tr("labels.battery_unknown")
  end
  return status
end

local function build(raw)
  state.categories = {}
  state.category_labels = {}
  state.category_glyphs = {}
  state.groups = {}
  state.sensors = {}
  state.byCategory = {}
  currentCategory = nil

  -- CPU
  pushCategory("cpu", "categories.cpu", "cpu")
  local cpuUsage = raw.cpu.usage
  if cpuUsage == nil then
    local sum, count = 0, 0
    for num = 0, 1023 do
      local usage = raw.cpu.cores[num]
      if usage == nil then
        break
      end
      sum = sum + usage
      count = count + 1
    end
    if count > 0 then
      cpuUsage = sum / count
    end
  end
  addSensor("cpu_usage", noctalia.tr("labels.cpu_usage"), cpuUsage, "percent")
  addSensor("cpu_freq", noctalia.tr("labels.cpu_freq"), raw.cpu.freq, "hertz")
  for num = 0, 1023 do
    local usage = raw.cpu.cores[num]
    if usage == nil then
      break
    end
    addSensor("cpu_core_" .. num, noctalia.tr("labels.cpu_core", { index = num }), usage, "percent")
  end
  groupFor("cpu", cpuUsage ~= nil and formatter(cpuUsage, "percent") or nil, sensorColor("percent", cpuUsage))

  -- Memory
  pushCategory("memory", "categories.memory", "device-desktop")
  local mem = raw.memory
  local memUsed = (mem.total ~= nil and mem.available ~= nil) and (mem.total - mem.available) or nil
  local memUsage = (mem.total ~= nil and memUsed ~= nil and mem.total > 0) and (memUsed / mem.total) or nil
  addSensor("mem_usage", noctalia.tr("labels.mem_usage"), memUsage, "percent")
  addSensor("mem_total", noctalia.tr("labels.mem_total"), mem.total, "memory")
  addSensor("mem_available", noctalia.tr("labels.mem_available"), mem.available, "memory")
  addSensor("mem_used", noctalia.tr("labels.mem_used"), memUsed, "memory")
  addSensor("mem_cached", noctalia.tr("labels.mem_cached"), mem.cached, "memory")
  addSensor("mem_free", noctalia.tr("labels.mem_free"), mem.free, "memory")
  if mem.swap_total ~= nil then
    addSensor("mem_swap_total", noctalia.tr("labels.mem_swap_total"), mem.swap_total, "memory")
    addSensor("mem_swap_used", noctalia.tr("labels.mem_swap_used"), mem.swap_total - mem.swap_free, "memory")
    addSensor("mem_swap_free", noctalia.tr("labels.mem_swap_free"), mem.swap_free, "memory")
  end
  groupFor("memory", memUsage ~= nil and formatter(memUsage, "percent") or nil, sensorColor("percent", memUsage))

  -- GPU
  if raw.gpu ~= nil then
    pushCategory("gpu", "categories.gpu", "device-desktop-analytics")
    addSensor("gpu_usage", noctalia.tr("labels.gpu_usage"), raw.gpu.usage, "percent")
    addSensor("gpu_temp", noctalia.tr("labels.gpu_temp"), raw.gpu.temp_c ~= nil and raw.gpu.temp_c * 1000 or nil, "temp")
    addSensor("gpu_mem_used", noctalia.tr("labels.gpu_mem_used"), raw.gpu.vram_used, "storage")
    addSensor("gpu_mem_total", noctalia.tr("labels.gpu_mem_total"), raw.gpu.vram_total, "storage")
    groupFor("gpu", raw.gpu.usage ~= nil and formatter(raw.gpu.usage, "percent") or nil, sensorColor("percent", raw.gpu.usage))
  end

  -- Hwmon temperatures / voltages / fans
  local usedKeys = {}
  if #raw.hwmon.temp > 0 then
    pushCategory("temp", "categories.temp", "thermometer")
    local sum, count = 0, 0
    for index, s in ipairs(raw.hwmon.temp) do
      local base = "temp_" .. util.sanitizeKey(s.label)
      local key = base
      local n = 1
      while usedKeys[key] ~= nil do
        key = base .. "_" .. tostring(n)
        n = n + 1
      end
      usedKeys[key] = true
      addSensor(key, s.label, s.value, "temp")
      sum = sum + s.value
      count = count + 1
    end
    if count > 0 then
      local avg = sum / count
      groupFor("temp", formatter(avg, "temp"), sensorColor("temp", avg))
    end
  end
  if #raw.hwmon.volt > 0 then
    pushCategory("volt", "categories.volt", "bolt")
    local sum, count = 0, 0
    for index, s in ipairs(raw.hwmon.volt) do
      local base = "volt_" .. util.sanitizeKey(s.label)
      local key = base
      local n = 1
      while usedKeys[key] ~= nil do
        key = base .. "_" .. tostring(n)
        n = n + 1
      end
      usedKeys[key] = true
      addSensor(key, s.label, s.value, "in")
      sum = sum + s.value
      count = count + 1
    end
    if count > 0 then
      groupFor("volt", formatter(sum / count, "in"))
    end
  end
  if #raw.hwmon.fan > 0 then
    pushCategory("fan", "categories.fan", "car-fan")
    local sum, count = 0, 0
    for index, s in ipairs(raw.hwmon.fan) do
      local base = "fan_" .. util.sanitizeKey(s.label)
      local key = base
      local n = 1
      while usedKeys[key] ~= nil do
        key = base .. "_" .. tostring(n)
        n = n + 1
      end
      usedKeys[key] = true
      addSensor(key, s.label, s.value, "fan")
      sum = sum + s.value
      count = count + 1
    end
    if count > 0 then
      groupFor("fan", formatter(sum / count, "fan"))
    end
  end

  -- Network
  pushCategory("net", "categories.net", "network")
  local net = raw.net
  addSensor("net_rx", noctalia.tr("labels.net_rx"), net.rx, "speed")
  addSensor("net_tx", noctalia.tr("labels.net_tx"), net.tx, "speed")
  addSensor("net_rx_total", noctalia.tr("labels.net_rx_total"), net.rx_total, "storage")
  addSensor("net_tx_total", noctalia.tr("labels.net_tx_total"), net.tx_total, "storage")
  if config.includePublicIp and publicIp ~= "" then
    addSensor("pub_ip", noctalia.tr("labels.pub_ip"), publicIp, "string")
  end
  if net.rx ~= nil or net.tx ~= nil then
    groupFor(
      "net",
      "↓ " .. formatter(net.rx or 0, "speed") .. "  ↑ " .. formatter(net.tx or 0, "speed")
    )
  end

  -- Disk
  pushCategory("disk", "categories.disk", "database")
  local disk = raw.disk
  addSensor("disk_usage", noctalia.tr("labels.disk_usage"), disk.usage, "percent")
  addSensor("disk_total", noctalia.tr("labels.disk_total"), disk.total, "storage")
  addSensor("disk_free", noctalia.tr("labels.disk_free"), disk.free, "storage")
  addSensor("disk_used", noctalia.tr("labels.disk_used"), disk.used, "storage")
  addSensor("disk_read_rate", noctalia.tr("labels.disk_read_rate"), disk.read_rate, "speed")
  addSensor("disk_write_rate", noctalia.tr("labels.disk_write_rate"), disk.write_rate, "speed")
  groupFor("disk", disk.usage ~= nil and formatter(disk.usage, "percent") or nil, sensorColor("percent", disk.usage))

  -- System
  pushCategory("system", "categories.system", "server")
  local sys = raw.system
  addSensor("load_1m", noctalia.tr("labels.load_1m"), sys.load1, "load")
  addSensor("load_5m", noctalia.tr("labels.load_5m"), sys.load5, "load")
  addSensor("load_15m", noctalia.tr("labels.load_15m"), sys.load15, "load")
  addSensor("uptime", noctalia.tr("labels.uptime"), sys.uptime, "uptime")
  addSensor("threads_active", noctalia.tr("labels.threads_active"), sys.threads_active, "string")
  addSensor("threads_total", noctalia.tr("labels.threads_total"), sys.threads_total, "string")
  addSensor("open_files", noctalia.tr("labels.open_files"), sys.open_files, "string")
  groupFor("system", sys.load1 ~= nil and formatter(sys.load1, "load") or nil)

  -- Battery
  if raw.battery ~= nil then
    pushCategory("battery", "categories.battery", "battery")
    local b = raw.battery
    addSensor("battery_state", noctalia.tr("labels.battery_state"), batteryStateLabel(b.STATUS or ""), "string")
    local energyFull = tonumber(b.ENERGY_FULL) or tonumber(b.CHARGE_FULL)
    local energyNow = tonumber(b.ENERGY_NOW) or tonumber(b.CHARGE_NOW)
    local powerNow = tonumber(b.POWER_NOW)
    local fraction = nil
    if energyFull ~= nil and energyFull > 0 and energyNow ~= nil then
      fraction = math.max(0, math.min(1, energyNow / energyFull))
      addSensor("battery_percent", noctalia.tr("labels.battery_percent"), fraction, "percent")
    end
    if powerNow ~= nil and powerNow > 0 then
      addSensor("battery_power", noctalia.tr("labels.battery_power"), powerNow, "watt")
    end
    if energyNow ~= nil and powerNow ~= nil and powerNow > 0 then
      addSensor("battery_time_left", noctalia.tr("labels.battery_time_left"), energyNow * 3600 / powerNow, "runtime")
    end
    groupFor("battery", fraction ~= nil and formatter(fraction, "percent") or nil, sensorColor("percent", fraction))
  end

  -- Drop categories that produced no sensors this tick (e.g. battery on a
  -- desktop, GPU probe disabled).
  local filtered = {}
  local filteredBy = {}
  for _, category in ipairs(state.categories) do
    if #state.byCategory[category] > 0 then
      table.insert(filtered, category)
      filteredBy[category] = state.byCategory[category]
    else
      state.category_labels[category] = nil
      state.category_glyphs[category] = nil
      state.groups[category] = nil
    end
  end
  state.categories = filtered
  state.byCategory = filteredBy
end

local function publish()
  state.last_update = noctalia.formatTime("%H:%M:%S")
  noctalia.state.set("vitals.data", state)
end

local function providerUrl()
  if config.publicIpProvider == "myip" then
    return "https://api.my-ip.io/ip"
  elseif config.publicIpProvider == "corecoding" then
    return "https://api.corecoding.io/api/ip"
  end
  return "https://api.ipify.org"
end

local function fetchPublicIp()
  if publicIpBusy or not config.includePublicIp then
    return
  end
  publicIpBusy = true
  noctalia.http({ url = providerUrl() }, function(res)
    publicIpBusy = false
    if res.ok and res.status == 200 and res.body ~= nil then
      if config.publicIpProvider == "corecoding" then
        local parsed, err = noctalia.json.decode(res.body)
        if err == nil and parsed ~= nil and parsed.ip ~= nil then
          publicIp = tostring(parsed.ip)
        end
      else
        publicIp = util.trim(res.body)
      end
    end
  end)
end

local function refresh()
  if collectBusy then
    return
  end
  collectBusy = true
  sensors.collect(
    {
      dwell = config.updateInterval / 1000,
      hide_zeros = config.hideZeros,
      storage_path = config.storagePath,
    },
    function(raw)
      collectBusy = false
      build(raw)
      publish()
      if config.includePublicIp then
        local now = noctalia.nowMs()
        if now - lastPublicIpFetchMs >= config.publicIpInterval * 60000 then
          lastPublicIpFetchMs = now
          fetchPublicIp()
        end
      end
    end
  )
end

noctalia.state.watch("vitals.cmd", function(cmd)
  if cmd == "refresh" then
    lastPublicIpFetchMs = 0
    refresh()
  end
end)

function update()
  refresh()
end

function onConfigChanged()
  readConfig()
  refresh()
  if config.includePublicIp then
    lastPublicIpFetchMs = 0
    fetchPublicIp()
  end
end

function onIpc(event)
  if event == "refresh" then
    lastPublicIpFetchMs = 0
    refresh()
  end
end

readConfig()
refresh()
if config.includePublicIp then
  lastPublicIpFetchMs = 0
  fetchPublicIp()
end

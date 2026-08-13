--!nonstrict
-- Raw sensor collection, ported from the GNOME Vitals extension's sensors.js.
--
-- Reads /proc and /sys with noctalia.readFileAsync: that API is designed for
-- sysfs/procfs (bounded to 4 MiB per file and at most 4 outstanding reads per
-- runtime, served outside the plugin VM worker). A per-tick synchronous read
-- of many kernel files would blow the entry callback's CPU budget, so every
-- file read here is queued through a small scheduler and the snapshot is
-- assembled once all reads complete. listDir() is a cheap host call and stays
-- synchronous.
--
-- M.collect(opts, done) queues all reads and then calls done(raw), where raw
-- has the same shape as the old synchronous version: cpu / memory / hwmon /
-- net / disk / battery / system / gpu.

local util = require("./util.luau")

local M = {}

local MAX_OUTSTANDING = 4

local BATTERY_CANDIDATES = { "BAT0", "BAT1", "BAT2", "BATT", "CMB0", "CMB1", "CMB2", "macsmc-battery" }

local HWMON_TYPES = {
  temp = "temp",
  ["in"] = "volt",
  fan = "fan",
}

local state = {
  lastStat = nil, -- /proc/stat snapshot: { [name] = { total, busy } }
  lastNet = nil, -- network byte counters (excluding lo)
  lastDisk = nil, -- disk byte counters for the mount's device
  hwmon = nil, -- discovered hwmon sensor specs, or nil while unbuilt
  batteryPath = nil, -- uevent path, or false when no battery exists
  mountDevice = nil, -- storage device node name, or false when unknown
}

local function listDir(path)
  local results = table.pack(pcall(noctalia.listDir, path))
  if results[1] and type(results[2]) == "table" then
    return results[2]
  end
  return nil
end

--- A scheduler that keeps at most MAX_OUTSTANDING reads in flight and calls
--- onComplete once every queued read has finished (successfully or not).
local function startQueue(onComplete)
  local q = {
    jobs = {},
    index = 1,
    running = 0,
    onComplete = onComplete,
  }

  local pump
  pump = function()
    while q.running < MAX_OUTSTANDING and q.index <= #q.jobs do
      local job = q.jobs[q.index]
      q.index = q.index + 1
      q.running = q.running + 1
      local ok = noctalia.readFileAsync(job.path, function(content, err)
        q.running = q.running - 1
        job.cb(content, err)
        if q.index > #q.jobs and q.running == 0 then
          q.onComplete()
        else
          pump()
        end
      end)
      if not ok then
        -- The host queue was full (unexpected at our cap); complete the job
        -- with an error rather than deadlock the pipeline.
        q.running = q.running - 1
        q.index = q.index - 1
        job.cb(nil, "read queue full")
      end
    end
  end

  return {
    read = function(path, cb)
      q.jobs[#q.jobs + 1] = { path = path, cb = cb }
    end,
    run = function()
      pump()
    end,
  }
end

--- Parse /proc/stat into per-CPU busy/total jiffies.
local function parseProcStat(content)
  local stats = {}
  for line in (content or ""):gmatch("[^\r\n]+") do
    local name = line:match("^(%S+)")
    if name and name:match("^cpu%d*$") then
      local rest = line:match("^%S+%s+(.+)$") or ""
      local total, idle = 0, 0
      local idx = 0
      for token in rest:gmatch("%d+") do
        local v = tonumber(token) or 0
        total = total + v
        if idx == 3 or idx == 4 then
          idle = idle + v -- idle (3) and iowait (4)
        end
        idx = idx + 1
      end
      stats[name] = { total = total, busy = total - idle }
    end
  end
  return stats
end

--- hwmon specs from a discovery buffer: { group = "temp"|"volt"|"fan",
--- label = "...", path = "<...>_input" }.
local function buildHwmonSpecs(buf, chipDirs)
  local specs = { temp = {}, volt = {}, fan = {} }
  for _, dir in ipairs(chipDirs) do
    local moduleName = (buf[dir .. "/name"] or ""):match("^%s*(.-)%s*$") or ""
    if moduleName ~= "" then
      local files = listDir(dir) or {}
      local tris = {}
      for _, f in ipairs(files) do
        local prefix, idx, kind = f:match("^(%a+)(%d+)_(%a+)$")
        if prefix and kind and (kind == "input" or kind == "label") then
          local group = HWMON_TYPES[prefix]
          if group then
            local key = group .. tonumber(idx)
            if not tris[key] then
              tris[key] = {
                group = group,
                input = dir .. "/" .. prefix .. idx .. "_input",
                label = dir .. "/" .. prefix .. idx .. "_label",
              }
            end
            if kind == "label" then
              tris[key].hasLabel = true
            end
          end
        end
      end
      for _, s in pairs(tris) do
        local labelText = moduleName
        if s.hasLabel then
          local custom = (buf[s.label] or ""):match("^%s*(.-)%s*$") or ""
          if custom ~= "" then
            labelText = moduleName .. " " .. custom
          end
        end
        table.insert(specs[s.group], { label = labelText, path = s.input })
      end
    end
  end
  return specs
end

local function collectCpuFromBuffer(buf)
  local out = { usage = nil, cores = {}, freq = nil }
  local stats = parseProcStat(buf["/proc/stat"])
  if next(stats) ~= nil then
    if state.lastStat then
      for name, cur in pairs(stats) do
        local prev = state.lastStat[name]
        if prev then
          local dTotal = cur.total - prev.total
          local dBusy = cur.busy - prev.busy
          if dTotal > 0 then
            local usage = dBusy / dTotal
            if name == "cpu" then
              out.usage = usage
            else
              local num = tonumber(name:match("^cpu(%d+)$"))
              if num then
                out.cores[num] = usage
              end
            end
          end
        end
      end
    end
    state.lastStat = stats
  end

  local freqs = {}
  for core = 0, 1023 do
    local content = buf["/sys/devices/system/cpu/cpu" .. core .. "/cpufreq/scaling_cur_freq"]
    if content == nil then
      break
    end
    local v = tonumber(content)
    if v then
      freqs[#freqs + 1] = v
    end
  end
  if #freqs > 0 then
    local sum = 0
    for _, f in ipairs(freqs) do
      sum = sum + f
    end
    out.freq = (sum / #freqs) * 1000
  end

  return out
end

--- /proc/meminfo values are all in kB.
local function collectMemoryFromBuffer(buf)
  local out = { total = nil, available = nil, cached = nil, free = nil, swap_total = nil, swap_free = nil }
  local content = buf["/proc/meminfo"]
  if not content then
    return out
  end
  for line in content:gmatch("[^\r\n]+") do
    local key, val = line:match("^(%S+):%s*(%d+)")
    if key and val then
      local v = tonumber(val) or 0
      if key == "MemTotal" then
        out.total = v
      elseif key == "MemAvailable" then
        out.available = v
      elseif key == "Cached" then
        out.cached = v
      elseif key == "MemFree" then
        out.free = v
      elseif key == "SwapTotal" then
        out.swap_total = v
      elseif key == "SwapFree" then
        out.swap_free = v
      end
    end
  end
  return out
end

--- Network byte counters (excluding lo) and rates in bytes/sec.
local function collectNetworkFromBuffer(buf, dwell)
  local out = { rx = nil, tx = nil, rx_total = 0, tx_total = 0 }
  local rxTotal, txTotal = 0, 0
  for _, iface in ipairs(state.ifaces) do
    local rx = buf["/sys/class/net/" .. iface .. "/statistics/rx_bytes"]
    local tx = buf["/sys/class/net/" .. iface .. "/statistics/tx_bytes"]
    if rx and tonumber(rx) then
      rxTotal = rxTotal + tonumber(rx)
    end
    if tx and tonumber(tx) then
      txTotal = txTotal + tonumber(tx)
    end
  end
  if state.lastNet and dwell and dwell > 0 then
    out.rx = math.max(0, (rxTotal - state.lastNet.rx) / dwell)
    out.tx = math.max(0, (txTotal - state.lastNet.tx) / dwell)
  end
  state.lastNet = { rx = rxTotal, tx = txTotal }
  out.rx_total = rxTotal
  out.tx_total = txTotal
  return out
end

--- Storage usage plus read/write rates (bytes/sec) from /proc/diskstats.
local function collectDiskFromBuffer(buf, storagePath, dwell)
  local out = { usage = nil, total = nil, free = nil, used = nil, read_rate = nil, write_rate = nil }
  local diskResults = table.pack(pcall(noctalia.diskStats, storagePath))
  local stats = diskResults[1] and diskResults[2] or nil
  if stats then
    out.total = stats.totalBytes
    out.free = stats.freeBytes
    out.used = (stats.totalBytes or 0) - (stats.freeBytes or 0)
    out.usage = (stats.usagePercent or 0) / 100
  end

  local dev = state.mountDevice
  if dev ~= nil and dev ~= false then
    local content = buf["/proc/diskstats"]
    if content then
      local read, write = nil, nil
      for line in content:gmatch("[^\r\n]+") do
        local fields = {}
        for w in line:gmatch("%S+") do
          fields[#fields + 1] = w
        end
        if fields[3] == dev then
          read = (tonumber(fields[6]) or 0) * 512
          write = (tonumber(fields[10]) or 0) * 512
          break
        end
      end
      if read and write and state.lastDisk and dwell and dwell > 0 then
        out.read_rate = math.max(0, (read - state.lastDisk.read) / dwell)
        out.write_rate = math.max(0, (write - state.lastDisk.write) / dwell)
      end
      if read and write then
        state.lastDisk = { read = read, write = write }
      end
    end
  end

  return out
end

--- Battery uevent dictionary (raw POWER_SUPPLY_* keys), or nil.
local function collectBatteryFromBuffer(buf)
  local path = state.batteryPath
  if path == false then
    return nil
  end
  if path == nil then
    -- Prefer a real listing, then fall back to the known candidates.
    for _, name in ipairs(state.batteryCandidates or {}) do
      local candidate = "/sys/class/power_supply/" .. name .. "/uevent"
      if buf[candidate] then
        path = candidate
        state.batteryPath = path
        break
      end
    end
    if path == nil then
      for _, name in ipairs(BATTERY_CANDIDATES) do
        local candidate = "/sys/class/power_supply/" .. name .. "/uevent"
        if buf[candidate] then
          path = candidate
          state.batteryPath = path
          break
        end
      end
    end
    if path == nil then
      state.batteryPath = false
      return nil
    end
  end

  local content = buf[path]
  if not content then
    return nil
  end
  local out = {}
  for line in content:gmatch("[^\r\n]+") do
    local k, v = line:match("^POWER_SUPPLY_([%w_]+)=(.*)$")
    if k then
      out[k] = v
    end
  end
  return out
end

--- System stats: load averages, uptime, thread and open-file counts.
local function collectSystemFromBuffer(buf)
  local out = { load1 = nil, load5 = nil, load15 = nil, uptime = nil, threads_active = nil, threads_total = nil, open_files = nil }
  local loadavg = buf["/proc/loadavg"]
  if loadavg then
    local a, b, c, d = loadavg:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
    out.load1 = a and tonumber(a) or nil
    out.load5 = b and tonumber(b) or nil
    out.load15 = c and tonumber(c) or nil
    if d then
      local active, total = d:match("(%d+)/(%d+)")
      out.threads_active = active and tonumber(active) or nil
      out.threads_total = total and tonumber(total) or nil
    end
  end
  local uptime = buf["/proc/uptime"]
  if uptime then
    local up = uptime:match("^(%S+)")
    out.uptime = up and tonumber(up) or nil
  end
  local fileNr = buf["/proc/sys/fs/file-nr"]
  if fileNr then
    local n = fileNr:match("^(%d+)")
    out.open_files = n and tonumber(n) or nil
  end
  return out
end

--- Host monitor probe: CPU temperature and GPU usage/temp/vram.
local function collectHostProbe()
  local out = { cpu_temp_c = nil, gpu = nil }
  local statsResults = table.pack(pcall(noctalia.systemStats))
  local stats = statsResults[1] and statsResults[2] or nil
  if type(stats) ~= "table" then
    return out
  end
  if type(stats.cpu) == "table" and stats.cpu.tempC ~= nil then
    out.cpu_temp_c = stats.cpu.tempC
  end
  if type(stats.gpu) == "table" then
    local g = stats.gpu
    if g.tempC ~= nil or g.usagePercent ~= nil or g.vramUsedBytes ~= nil then
      out.gpu = {
        temp_c = g.tempC,
        usage = g.usagePercent ~= nil and (g.usagePercent / 100) or nil,
        vram_used = g.vramUsedBytes,
        vram_total = g.vramTotalBytes,
      }
    end
  end
  return out
end

--- Resolve the device node backing the monitored mount from /proc/mounts.
local function resolveMountDevice(buf, storagePath)
  if state.mountDevice ~= nil then
    return
  end
  local content = buf["/proc/mounts"]
  if content then
    for line in content:gmatch("[^\r\n]+") do
      local source, point = line:match("^(%S+)%s+(%S+)")
      if point == storagePath and source and source:match("^/dev/") then
        state.mountDevice = source:match("^/dev/(.+)$")
        return
      end
    end
  end
  state.mountDevice = false
end

--- Collect a raw snapshot asynchronously. opts: { dwell, hide_zeros,
--- storage_path }. Calls done(raw) once all reads have completed.
function M.collect(opts, done)
  opts = opts or {}
  local dwell = opts.dwell or 2
  local hideZeros = opts.hide_zeros == true
  local storagePath = opts.storage_path or "/"

  local buf = {}
  local chipDirs = {}

  -- Structural discovery is synchronous (cheap host calls).
  local topHwmon = listDir("/sys/class/hwmon")
  if topHwmon then
    for _, entry in ipairs(topHwmon) do
      if entry:match("^hwmon%d+$") then
        table.insert(chipDirs, "/sys/class/hwmon/" .. entry)
      end
    end
  end

  local ifaces = {}
  local topNet = listDir("/sys/class/net")
  if topNet then
    for _, iface in ipairs(topNet) do
      if iface ~= "lo" then
        table.insert(ifaces, iface)
      end
    end
  end
  state.ifaces = ifaces

  local batteryCandidates = {}
  local topPsu = listDir("/sys/class/power_supply")
  if topPsu then
    for _, name in ipairs(topPsu) do
      if name:match("^BAT") or name:match("^CMB") or name:match("^BATT") or name:match("battery") then
        table.insert(batteryCandidates, name)
      end
    end
  end
  state.batteryCandidates = batteryCandidates

  local cores = {}
  local topCpu = listDir("/sys/devices/system/cpu")
  if topCpu then
    for _, entry in ipairs(topCpu) do
      local n = entry:match("^cpu(%d+)$")
      if n and tonumber(n) then
        table.insert(cores, tonumber(n))
      end
    end
    table.sort(cores)
  end

  local q = startQueue(function()
    -- First collect: build and cache hwmon specs from the discovery reads.
    if state.hwmon == nil then
      state.hwmon = buildHwmonSpecs(buf, chipDirs)
    end

    resolveMountDevice(buf, storagePath)

    local raw = {
      cpu = collectCpuFromBuffer(buf),
      memory = collectMemoryFromBuffer(buf),
      hwmon = { temp = {}, volt = {}, fan = {} },
      net = collectNetworkFromBuffer(buf, dwell),
      disk = collectDiskFromBuffer(buf, storagePath, dwell),
      battery = collectBatteryFromBuffer(buf),
      system = collectSystemFromBuffer(buf),
      gpu = nil,
    }

    -- hwmon values: temp*_input in millidegrees, in*_input in millivolts,
    -- fan*_input in RPM.
    for group, list in pairs(state.hwmon) do
      for _, s in ipairs(list) do
        local content = buf[s.path]
        if content and tonumber(content) then
          local value = tonumber(content)
          if value > 0 or not hideZeros or group == "fan" then
            table.insert(raw.hwmon[group], { label = s.label, value = value })
          end
        end
      end
    end

    -- Fall back to the host monitor's CPU temperature probe when the kernel
    -- hwmon scan found nothing.
    local probe = collectHostProbe()
    if #raw.hwmon.temp == 0 and probe.cpu_temp_c ~= nil then
      table.insert(raw.hwmon.temp, { label = "CPU", value = probe.cpu_temp_c * 1000 })
    end
    raw.gpu = probe.gpu

    done(raw)
  end)

  -- Queue every read. Async reads happen outside the plugin VM worker, so a
  -- full tick of kernel reads no longer competes with the callback CPU budget.
  if state.hwmon == nil then
    for _, dir in ipairs(chipDirs) do
      q.read(dir .. "/name", function(content)
        buf[dir .. "/name"] = content
      end)
    end
    for _, dir in ipairs(chipDirs) do
      local files = listDir(dir) or {}
      local tris = {}
      for _, f in ipairs(files) do
        local prefix, idx, kind = f:match("^(%a+)(%d+)_(%a+)$")
        if prefix and kind and (kind == "input" or kind == "label") then
          local group = HWMON_TYPES[prefix]
          if group then
            local key = group .. tonumber(idx)
            if not tris[key] then
              tris[key] = {
                input = dir .. "/" .. prefix .. idx .. "_input",
                label = dir .. "/" .. prefix .. idx .. "_label",
              }
            end
            if kind == "label" then
              tris[key].hasLabel = true
            end
          end
        end
      end
      for _, s in pairs(tris) do
        q.read(s.input, function(content)
          buf[s.input] = content
        end)
        if s.hasLabel then
          q.read(s.label, function(content)
            buf[s.label] = content
          end)
        end
      end
    end
  else
    for group, list in pairs(state.hwmon) do
      for _, s in ipairs(list) do
        q.read(s.path, function(content)
          buf[s.path] = content
        end)
      end
    end
  end

  q.read("/proc/stat", function(content)
    buf["/proc/stat"] = content
  end)
  q.read("/proc/meminfo", function(content)
    buf["/proc/meminfo"] = content
  end)
  q.read("/proc/loadavg", function(content)
    buf["/proc/loadavg"] = content
  end)
  q.read("/proc/uptime", function(content)
    buf["/proc/uptime"] = content
  end)
  q.read("/proc/sys/fs/file-nr", function(content)
    buf["/proc/sys/fs/file-nr"] = content
  end)
  q.read("/proc/mounts", function(content)
    buf["/proc/mounts"] = content
  end)
  q.read("/proc/diskstats", function(content)
    buf["/proc/diskstats"] = content
  end)

  for _, iface in ipairs(ifaces) do
    q.read("/sys/class/net/" .. iface .. "/statistics/rx_bytes", function(content)
      buf["/sys/class/net/" .. iface .. "/statistics/rx_bytes"] = content
    end)
    q.read("/sys/class/net/" .. iface .. "/statistics/tx_bytes", function(content)
      buf["/sys/class/net/" .. iface .. "/statistics/tx_bytes"] = content
    end)
  end

  for _, core in ipairs(cores) do
    q.read("/sys/devices/system/cpu/cpu" .. core .. "/cpufreq/scaling_cur_freq", function(content)
      buf["/sys/devices/system/cpu/cpu" .. core .. "/cpufreq/scaling_cur_freq"] = content
    end)
  end

  if state.batteryPath == nil then
    local candidates = #batteryCandidates > 0 and batteryCandidates or BATTERY_CANDIDATES
    for _, name in ipairs(candidates) do
      q.read("/sys/class/power_supply/" .. name .. "/uevent", function(content)
        buf["/sys/class/power_supply/" .. name .. "/uevent"] = content
      end)
    end
  end

  q.run()
end

return M

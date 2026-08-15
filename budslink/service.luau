--!nonstrict
-- BudsLink headless [[service]] entry.
--
-- BudsLink's D-Bus service is watched by the GJS helper (helper/
-- budslink-helper.js), which mirrors device state to state.json and keeps the
-- service alive with its HoldService heartbeat. This entry owns that helper:
-- it spawns it detached (the helper's pidfile prevents duplicates), keeps it
-- running, polls state.json and publishes it under "budslink.data" for the
-- widget and panel. The UI sends commands back through "budslink.cmd".

local uid = noctalia.getenv("UID") or "1000"
local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR") or ("/run/user/" .. uid)
local base = runtimeDir .. "/budslink"
local statePath = base .. "/state.json"
local pidPath = base .. "/helper.pid"

local helperPath = noctalia.pluginDir() .. "/helper/budslink-helper.js"
local openScriptPath = noctalia.pluginDir() .. "/helper/budslink-open.sh"

local intervalMs = 2000
local daemonCheckCounter = 0
local DAEMON_CHECK_EVERY = 15 -- respawn check roughly every 30s at 2s ticks

local function shellQuote(value)
  return "'" .. string.gsub(tostring(value), "'", "'\\''") .. "'"
end

-- The helper daemon writes its pid to helper.pid and removes it on clean
-- exit. A crashed daemon leaves a stale pidfile, so verify the process is
-- really alive before trusting the lock.
local function daemonAlive()
  local raw = noctalia.readFile(pidPath)
  if raw == nil then
    return false
  end
  local pid = noctalia.string.trim(raw)
  if pid == "" or tonumber(pid) == nil then
    return false
  end
  local cmdline = noctalia.readFile("/proc/" .. pid .. "/cmdline")
  return cmdline ~= nil and string.find(cmdline, "budslink-helper", 1, true) ~= nil
end

-- Spawn the daemon if it is not already running. runAsync without a callback
-- starts a detached process and returns immediately; the helper's own pidfile
-- lock makes the spawn idempotent.
local function ensureDaemon()
  if not daemonAlive() then
    noctalia.runAsync(shellQuote(helperPath))
  end
end

local function stopDaemon()
  local raw = noctalia.readFile(pidPath)
  if raw == nil then
    return
  end
  local pid = noctalia.string.trim(raw)
  if pid ~= "" and tonumber(pid) ~= nil then
    noctalia.runAsync("kill " .. pid)
  end
end

local function poll()
  local raw = noctalia.readFile(statePath)
  if raw == nil then
    return
  end
  local ok, data = pcall(noctalia.json.decode, raw)
  if ok and type(data) == "table" then
    noctalia.state.set("budslink.data", data)
  end
end

local function refresh()
  ensureDaemon()
  poll()
end

-- Actions arrive as { action = name, value = number }. "refresh" re-reads
-- state; "open" focuses/launches the BudsLink app; anything else is forwarded
-- to the helper's --action mode (UiAction on the first device).
noctalia.state.watch("budslink.cmd", function(cmd)
  if type(cmd) ~= "table" or cmd.action == nil then
    return
  end
  if cmd.action == "refresh" then
    refresh()
  elseif cmd.action == "open" then
    noctalia.runAsync(shellQuote(openScriptPath))
  elseif string.match(cmd.action, "^[A-Za-z0-9_]+$") ~= nil then
    local value = tonumber(cmd.value) or 0
    noctalia.runAsync(shellQuote(helperPath) .. " --action " .. cmd.action .. " " .. tostring(value))
  end
end)

function update()
  poll()
  daemonCheckCounter = daemonCheckCounter + 1
  if daemonCheckCounter >= DAEMON_CHECK_EVERY then
    daemonCheckCounter = 0
    ensureDaemon()
  end
end

function onConfigChanged()
  local interval = tonumber(noctalia.getConfig("update_interval")) or 2000
  if interval < 1000 then
    interval = 1000
  elseif interval > 10000 then
    interval = 10000
  end
  if interval ~= intervalMs then
    intervalMs = interval
    noctalia.setUpdateInterval(intervalMs)
  end
end

-- Keep the daemon running across shell reloads; stop it when the plugin is
-- disabled or the shell shuts down so the BudsLink service is released.
function onExit(_signal, reason)
  if reason ~= "reload" then
    stopDaemon()
  end
end

onConfigChanged()
refresh()

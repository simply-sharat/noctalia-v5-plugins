--!nonstrict
-- Privacy Indicator headless [[service]] entry.
--
-- Detects when the microphone, camera, or screen is being captured and keeps
-- an access history. Microphone and screen-share states come from the
-- PipeWire graph, read by polling `pw-dump`; the camera state comes from a
-- shell scan of /proc fds pointing at open /dev/video* devices. Everything is
-- published under the "privacy.data" and "privacy.history" state keys; the
-- panel sends commands through the "privacy.cmd" channel ("clear").

local config = {
  enableToast = true,
  micFilter = "",
  camFilter = "",
}

local state = {
  available = false,
  mic_active = false,
  cam_active = false,
  scr_active = false,
  mic_apps = {},
  cam_apps = {},
  scr_apps = {},
  error = "",
}

local history = {}
local historyPath = ""
local prevMic = {}
local prevCam = {}
local prevScr = {}
local prevMicActive = false
local prevCamActive = false
local prevScrActive = false

local pwBusy = false
local cameraBusy = false

local CAMERA_SCRIPT = [[
for dev in /sys/class/video4linux/video*; do [ -e "$dev/name" ] && grep -qv 'Metadata' "$dev/name" && dev_name=$(basename "$dev") && find /proc/[0-9]*/fd -lname "/dev/$dev_name" 2>/dev/null; done | cut -d/ -f3 | xargs -r ps -o comm= -p | sort -u | tr '\n' ',' | sed 's/,$//'
]]

local SCREEN_PREFIXES = {
  "xdph-streaming", "gsr-default", "game capture", "screen",
  "desktop", "display", "cast", "webrtc", "v4l2",
}

local SCREEN_SUBSTRINGS = {
  "screen-cast", "screen-capture", "desktop-capture",
  "monitor-capture", "window-capture", "game-capture",
}

local function readConfig()
  local toast = noctalia.getConfig("enable_toast")
  config.enableToast = toast ~= nil and toast or true
  config.micFilter = noctalia.getConfig("mic_filter_regex") or ""
  config.camFilter = noctalia.getConfig("cam_filter_regex") or ""
end

local function trim(text)
  return string.gsub(text or "", "^%s*(.-)%s*$", "%1")
end

local function split(text, sep)
  local parts = {}
  local start = 1
  while true do
    local s, e = string.find(text, sep, start, true)
    if s == nil then
      table.insert(parts, string.sub(text, start))
      break
    end
    table.insert(parts, string.sub(text, start, s - 1))
    start = e + 1
  end
  return parts
end

local function contains(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

local function cloneList(list)
  local encoded, err = noctalia.json.encode(list or {})
  if err ~= nil then
    return {}
  end
  local decoded, decodeErr = noctalia.json.decode(encoded)
  if decodeErr ~= nil then
    return {}
  end
  return decoded
end

-- Filters are Lua patterns; `|` separates alternatives (a literal character
-- in Lua patterns, so splitting is safe and preserves the v4 alternation
-- syntax). Invalid patterns are ignored rather than crashing the scan.
local function matchesFilter(name, filter)
  if filter == "" or name == "" then
    return false
  end
  for part in string.gmatch(filter, "([^|]+)") do
    local pattern = trim(part)
    if pattern ~= "" then
      local ok, found = pcall(string.find, name, pattern)
      if ok and found ~= nil then
        return true
      end
    end
  end
  return false
end

local function nodeAppName(info)
  local props = info and info.props or {}
  return props["application.name"] or props["node.nickname"] or props["node.name"] or ""
end

local function hasLink(nodeId, links)
  for _, link in ipairs(links) do
    local props = link.info and link.info.props or {}
    if props["link.output.node.id"] == nodeId or props["link.input.node.id"] == nodeId then
      return true
    end
  end
  return false
end

local function isScreenShareNode(props)
  if props == nil then
    return false
  end
  local mediaClass = props["media.class"] or ""
  if mediaClass == "" then
    return false
  end
  if mediaClass:find("Audio", 1, true) ~= nil or mediaClass:find("Video", 1, true) == nil then
    return false
  end
  local mediaName = string.lower(props["media.name"] or "")
  if mediaName == "gsr-default_output" then
    return true
  end
  for _, prefix in ipairs(SCREEN_PREFIXES) do
    if string.sub(mediaName, 1, #prefix) == prefix then
      return true
    end
  end
  for _, fragment in ipairs(SCREEN_SUBSTRINGS) do
    if mediaName:find(fragment, 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function saveHistory()
  if historyPath == "" then
    return
  end
  local encoded, err = noctalia.json.encode(history)
  if err ~= nil then
    return
  end
  noctalia.writeFile(historyPath, encoded)
end

local function loadHistory()
  if historyPath == "" then
    return
  end
  local raw = noctalia.readFile(historyPath)
  if raw == nil then
    return
  end
  local loaded, err = noctalia.json.decode(raw)
  if err ~= nil or type(loaded) ~= "table" then
    return
  end
  history = loaded
  while #history > 50 do
    table.remove(history)
  end
end

local function historyTime()
  local fmt = noctalia.timeFormat()
  if fmt == "" then
    fmt = "{:%H:%M}"
  end
  return noctalia.formatTime(fmt)
end

local function addToHistory(app, appType, icon, action)
  local entry = {
    app = app,
    type = appType,
    icon = icon,
    action = action,
    time = historyTime(),
    timestamp = noctalia.nowMs(),
  }
  table.insert(history, 1, entry)
  while #history > 50 do
    table.remove(history)
  end
  saveHistory()
end

local function checkAppChanges(newApps, oldApps, appType, icon)
  if type(newApps) ~= "table" then
    newApps = {}
  end
  if type(oldApps) ~= "table" then
    oldApps = {}
  end
  for _, app in ipairs(newApps) do
    if not contains(oldApps, app) then
      addToHistory(app, appType, icon, "started")
    end
  end
  for _, app in ipairs(oldApps) do
    if not contains(newApps, app) then
      addToHistory(app, appType, icon, "stopped")
    end
  end
end

local function notifyEdges()
  if config.enableToast then
    if state.mic_active and not prevMicActive then
      noctalia.notify(noctalia.tr("toast.mic"), table.concat(state.mic_apps, ", "))
    end
    if state.cam_active and not prevCamActive then
      noctalia.notify(noctalia.tr("toast.cam"), table.concat(state.cam_apps, ", "))
    end
    if state.scr_active and not prevScrActive then
      noctalia.notify(noctalia.tr("toast.screen"), table.concat(state.scr_apps, ", "))
    end
  end
  prevMicActive = state.mic_active
  prevCamActive = state.cam_active
  prevScrActive = state.scr_active
end

local function publish()
  noctalia.state.set("privacy.data", state)
  noctalia.state.set("privacy.history", history)
end

-- Diff the freshly computed states against the previous scan, log started /
-- stopped history entries, fire activation notices, then publish. Mic and
-- screen come from the pw-dump poll; camera from the device scan. Each scan
-- updates only its own fields, so running this after either scan is safe: the
-- untouched fields diff to nothing.
local function commit()
  checkAppChanges(state.mic_apps, prevMic, "Microphone", "microphone")
  checkAppChanges(state.cam_apps, prevCam, "Camera", "camera")
  checkAppChanges(state.scr_apps, prevScr, "Screen", "screen-share")
  prevMic = cloneList(state.mic_apps)
  prevCam = cloneList(state.cam_apps)
  prevScr = cloneList(state.scr_apps)
  notifyEdges()
  publish()
end

local function updateMic(nodes, links)
  local appNames = {}
  for _, node in ipairs(nodes) do
    local info = node.info
    if info ~= nil then
      local props = info.props or {}
      if props["media.class"] == "Stream/Input/Audio"
        and props["stream.capture.sink"] ~= "true"
        and hasLink(node.id, links) then
        local appName = nodeAppName(info)
        if appName ~= "" and not matchesFilter(appName, config.micFilter) and not contains(appNames, appName) then
          table.insert(appNames, appName)
        end
      end
    end
  end
  state.mic_apps = appNames
  state.mic_active = #appNames > 0
end

local function updateScreenShare(nodes, links)
  local appNames = {}
  for _, node in ipairs(nodes) do
    local info = node.info
    if info ~= nil and hasLink(node.id, links) then
      local appName = nodeAppName(info)
      if appName ~= "" and isScreenShareNode(info.props) and not contains(appNames, appName) then
        table.insert(appNames, appName)
      end
    end
  end
  state.scr_apps = appNames
  state.scr_active = #appNames > 0
end

local function pollPipeWire()
  if pwBusy then
    return
  end
  pwBusy = true
  noctalia.runAsync({ "pw-dump" }, function(result)
    pwBusy = false
    if result.exitCode ~= 0 then
      if state.available or state.error == "" then
        state.available = false
        state.error = noctalia.tr("errors.pw_dump")
        publish()
      end
      return
    end
    local objects, err = noctalia.json.decode(result.stdout)
    if err ~= nil then
      return
    end
    local nodes = {}
    local links = {}
    for _, obj in ipairs(objects or {}) do
      if type(obj) == "table" then
        if obj.type == "PipeWire:Interface:Node" then
          table.insert(nodes, obj)
        elseif obj.type == "PipeWire:Interface:Link" then
          table.insert(links, obj)
        end
      end
    end
    state.available = true
    state.error = ""
    updateMic(nodes, links)
    updateScreenShare(nodes, links)
    commit()
  end)
end

local function runCameraScan()
  if cameraBusy then
    return
  end
  cameraBusy = true
  noctalia.runAsync({ "sh", "-c", CAMERA_SCRIPT }, function(result)
    cameraBusy = false
    if result.exitCode ~= 0 then
      state.cam_apps = {}
      state.cam_active = false
      commit()
      return
    end
    local appNames = {}
    local raw = trim(result.stdout)
    if raw ~= "" then
      for _, name in ipairs(split(raw, ",")) do
        local app = trim(name)
        if app ~= "" and not matchesFilter(app, config.camFilter) and not contains(appNames, app) then
          table.insert(appNames, app)
        end
      end
    end
    state.cam_apps = appNames
    state.cam_active = #appNames > 0
    commit()
  end)
end

noctalia.state.watch("privacy.cmd", function(cmd)
  if cmd ~= "clear" then
    return
  end
  history = {}
  saveHistory()
  publish()
  noctalia.state.set("privacy.cmd", "")
end)

noctalia.setUpdateInterval(2000)

function update()
  pollPipeWire()
  runCameraScan()
end

function onConfigChanged()
  readConfig()
end

readConfig()
local dir = noctalia.pluginDataDir()
if dir ~= nil then
  historyPath = dir .. "/history.json"
end
loadHistory()
pollPipeWire()
runCameraScan()

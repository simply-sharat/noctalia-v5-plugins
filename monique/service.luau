--!nonstrict
-- Monique headless [[service]] entry.
--
-- Monique (https://github.com/ToRvaLDz/monique) is a CLI that manages saved
-- monitor profiles. This service checks that it is installed, polls the active
-- profile and the profile list, and publishes them under "monique.data"; the
-- panel sends commands through the "monique.cmd" channel ({ action =
-- "refresh" | "switch", profile = "..." }).

local config = {
  refreshInterval = 5000,
}

local state = {
  available = false,
  active_profile = "",
  profiles = {},
  status = "", -- "" | "loading" | "ready" | "switching"
  error = "",
}

local currentBusy = false
local listBusy = false
local switchBusy = false

local function trim(text)
  return string.gsub(text or "", "^%s*(.-)%s*$", "%1")
end

local function shellQuote(value)
  return "'" .. string.gsub(tostring(value), "'", "'\\''") .. "'"
end

local function readConfig()
  local interval = tonumber(noctalia.getConfig("refresh_interval")) or 5000
  if interval < 1000 then
    interval = 1000
  end
  if interval > 30000 then
    interval = 30000
  end
  config.refreshInterval = interval
  noctalia.setUpdateInterval(config.refreshInterval)
end

local function publish()
  noctalia.state.set("monique.data", state)
end

local function refreshCurrentProfile()
  if currentBusy then
    return
  end
  currentBusy = true
  noctalia.runAsync("monique --current-profile", function(result)
    currentBusy = false
    if result.exitCode == 0 then
      state.active_profile = trim(result.stdout)
    elseif result.exitCode == 1 then
      -- monique exits 1 when no profile is currently applied.
      state.active_profile = ""
    end
    if not switchBusy then
      state.status = "ready"
    end
    publish()
  end)
end

local function refreshProfiles()
  if listBusy then
    return
  end
  listBusy = true
  noctalia.runAsync("monique --list-profiles", function(result)
    listBusy = false
    if result.exitCode == 0 then
      local parsed, err = nil, nil
      pcall(function()
        parsed, err = noctalia.json.decode(result.stdout or "[]")
      end)
      if err == nil and type(parsed) == "table" then
        state.profiles = parsed
      end
    end
    publish()
  end)
end

local function refresh()
  if not state.available then
    return
  end
  refreshCurrentProfile()
  refreshProfiles()
end

local function switchProfile(name)
  if not state.available or name == nil or name == "" or switchBusy then
    return
  end
  switchBusy = true
  state.status = "switching"
  publish()
  noctalia.runAsync("monique --switch-profile " .. shellQuote(name), function(result)
    switchBusy = false
    if result.exitCode == 0 then
      state.active_profile = name
      state.status = "ready"
      noctalia.notify(noctalia.tr("toast.title"), noctalia.tr("toast.switched", { profile = name }))
      publish()
      refreshCurrentProfile()
    else
      state.status = "ready"
      local err = trim(result.stderr)
      noctalia.notify(noctalia.tr("toast.title"), err ~= "" and err or noctalia.tr("toast.error"))
      publish()
    end
  end)
end

noctalia.state.watch("monique.cmd", function(cmd)
  if type(cmd) ~= "table" or cmd.action == nil then
    return
  end
  if cmd.action == "refresh" then
    refresh()
  elseif cmd.action == "switch" and type(cmd.profile) == "string" then
    switchProfile(cmd.profile)
  end
end)

function onConfigChanged()
  readConfig()
end

function update()
  refresh()
end

readConfig()
state.available = noctalia.commandExists("monique")
if state.available then
  state.status = "loading"
  publish()
  refresh()
else
  state.error = noctalia.tr("errors.monique_not_found")
  publish()
end

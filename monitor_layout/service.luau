--!nonstrict
-- Monitor Layout headless [[service]] entry.
--
-- Owns the output state: reads the current layout from Sway or Hyprland
-- (auto-detected), keeps live + draft copies, and applies the draft as a
-- shell script. Publishes everything to noctalia.state under "layout.data";
-- the bar widget, control-center shortcut and panel send commands through the
-- "layout.cmd" channel ({ action = "refresh" | "apply" | "reset" | "select" |
-- "set_position" | "set_resolution" | "set_scale", ... }).

local sway = require("./backends/sway.luau")
local hyprland = require("./backends/hyprland.luau")

local config = {
  backend = "auto",
  swayCommand = "swaymsg",
  hyprctlCommand = "hyprctl",
  snapToGrid = true,
  gridSize = 40,
}

local function readConfig()
  config.backend = noctalia.getConfig("backend") or "auto"
  config.swayCommand = noctalia.getConfig("sway_command") or "swaymsg"
  config.hyprctlCommand = noctalia.getConfig("hyprctl_command") or "hyprctl"
  config.snapToGrid = noctalia.getConfig("snap_to_grid")
  if config.snapToGrid == nil then
    config.snapToGrid = true
  end
  config.gridSize = tonumber(noctalia.getConfig("grid_size")) or 40
  if config.gridSize < 1 then
    config.gridSize = 40
  end
end

local function detectBackend()
  if config.backend == "sway" then
    return "sway"
  end
  if config.backend == "hyprland" then
    return "hyprland"
  end

  if noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE") ~= nil
    and noctalia.commandExists(config.hyprctlCommand) then
    return "hyprland"
  end
  if noctalia.getenv("SWAYSOCK") ~= nil
    and noctalia.commandExists(config.swayCommand) then
    return "sway"
  end
  if noctalia.commandExists("hyprctl") then
    return "hyprland"
  end
  if noctalia.commandExists("swaymsg") then
    return "sway"
  end
  return "unsupported"
end

local state = {
  backend = "",
  live_outputs = {},
  draft_outputs = {},
  selected_id = "",
  is_refreshing = false,
  is_applying = false,
  status = "",
  status_count = 0,
  error = "",
  pending = false,
  config_content = "",
}

local function backendModule()
  if state.backend == "sway" then
    return sway
  elseif state.backend == "hyprland" then
    return hyprland
  end
  return nil
end

local function buildConfigContent()
  local module = backendModule()
  if module == nil then
    return ""
  end
  local content, err = module.buildConfigContent(state.draft_outputs)
  if err ~= nil then
    return ""
  end
  return content
end

local function listsEqual(left, right)
  local encodedLeft, leftErr = noctalia.json.encode(left)
  local encodedRight, rightErr = noctalia.json.encode(right)
  if leftErr ~= nil or rightErr ~= nil then
    return false
  end
  return encodedLeft == encodedRight
end

local function publish()
  state.pending = not listsEqual(state.draft_outputs, state.live_outputs)
  state.config_content = buildConfigContent()
  noctalia.state.set("layout.data", state)
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

local function findIndex(list, outputId)
  for index, output in ipairs(list) do
    if output.output_id == outputId then
      return index
    end
  end
  return -1
end

local function roundCoordinate(value, snap)
  local rounded = math.round(value)
  if not snap or not config.snapToGrid then
    return rounded
  end
  local step = config.gridSize
  return math.round(rounded / step) * step
end

local function setOutputPosition(outputId, x, y, snap)
  local index = findIndex(state.draft_outputs, outputId)
  if index == -1 then
    return
  end

  local nextDraft = cloneList(state.draft_outputs)
  nextDraft[index].x = roundCoordinate(x, snap)
  nextDraft[index].y = roundCoordinate(y, snap)
  state.draft_outputs = nextDraft
  state.selected_id = outputId
  state.status = "dirty"
  publish()
end

local function setOutputResolution(outputId, modeId)
  local index = findIndex(state.draft_outputs, outputId)
  if index == -1 then
    return
  end

  local nextDraft = cloneList(state.draft_outputs)
  local output = nextDraft[index]
  for _, mode in ipairs(output.available_modes or {}) do
    if mode.id == modeId then
      output.mode_id = mode.id
      output.width = mode.width
      output.height = mode.height
      output.refresh = mode.refresh
      output.resolution_label = mode.label
      break
    end
  end

  state.draft_outputs = nextDraft
  state.selected_id = outputId
  state.status = "dirty"
  publish()
end

local function setOutputScale(outputId, scaleValue)
  local parsed = tonumber(scaleValue)
  if parsed == nil or parsed <= 0 then
    return
  end

  local index = findIndex(state.draft_outputs, outputId)
  if index == -1 then
    return
  end

  local clamped = math.max(0.25, math.min(8, parsed))
  local nextDraft = cloneList(state.draft_outputs)
  local output = nextDraft[index]
  output.scale = math.round(clamped * 100) / 100
  output.logical_width = math.max(1, math.round(output.width / output.scale))
  output.logical_height = math.max(1, math.round(output.height / output.scale))

  state.draft_outputs = nextDraft
  state.selected_id = outputId
  state.status = "dirty"
  publish()
end

local function resetDraftOutputs()
  state.draft_outputs = cloneList(state.live_outputs)
  state.status = "reset"
  state.error = ""
  if state.selected_id == "" or findIndex(state.draft_outputs, state.selected_id) == -1 then
    state.selected_id = #state.draft_outputs > 0 and state.draft_outputs[1].output_id or ""
  end
  publish()
end

local function refresh()
  if state.is_refreshing then
    return
  end

  state.is_refreshing = true
  state.error = ""
  state.status = "refreshing"
  publish()

  local module = backendModule()
  if module == nil then
    state.is_refreshing = false
    state.error = noctalia.tr("errors.unsupported_backend")
    state.status = ""
    publish()
    return
  end

  local command = state.backend == "sway" and config.swayCommand or config.hyprctlCommand
  local argv = module.buildFetchCommand(command)

  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      state.is_refreshing = false
      state.error = result.stderr ~= "" and result.stderr or noctalia.tr("errors.fetch_failed")
      state.status = ""
      publish()
      return
    end

    local outputs, err = module.parseOutputs(result.stdout)
    if err ~= nil then
      state.is_refreshing = false
      state.error = err
      state.status = ""
      publish()
      return
    end

    state.live_outputs = outputs
    state.draft_outputs = cloneList(outputs)
    state.is_refreshing = false
    state.error = ""
    state.status = "ready"
    state.status_count = #outputs

    if state.selected_id == "" or findIndex(state.draft_outputs, state.selected_id) == -1 then
      state.selected_id = #outputs > 0 and outputs[1].output_id or ""
    end

    publish()
  end)
end

local function applyLayout()
  if state.is_applying then
    return
  end

  local module = backendModule()
  if module == nil then
    state.error = noctalia.tr("errors.unsupported_backend")
    state.status = ""
    publish()
    return
  end

  local command = state.backend == "sway" and config.swayCommand or config.hyprctlCommand
  local script, err = module.buildApplyCommand(state.draft_outputs, command)
  if err ~= nil then
    state.error = err
    state.status = ""
    publish()
    return
  end

  state.is_applying = true
  state.error = ""
  state.status = "applying"
  publish()

  noctalia.runAsync(script, function(result)
    state.is_applying = false
    if result.exitCode == 0 then
      state.status = "applied"
      state.error = ""
      publish()
      refresh()
    else
      state.status = ""
      state.error = result.stderr ~= "" and result.stderr or noctalia.tr("errors.apply_failed")
      publish()
    end
  end)
end

noctalia.state.watch("layout.cmd", function(cmd)
  if type(cmd) ~= "table" or cmd.action == nil then
    return
  end

  local action = cmd.action
  if action == "refresh" then
    refresh()
  elseif action == "apply" then
    applyLayout()
  elseif action == "reset" then
    resetDraftOutputs()
  elseif action == "select" then
    if cmd.id ~= nil then
      state.selected_id = cmd.id
      publish()
    end
  elseif action == "set_position" then
    local x = tonumber(cmd.x)
    local y = tonumber(cmd.y)
    if cmd.id ~= nil and x ~= nil and y ~= nil then
      setOutputPosition(cmd.id, x, y, true)
    end
  elseif action == "set_resolution" then
    if cmd.id ~= nil and cmd.mode_id ~= nil then
      setOutputResolution(cmd.id, cmd.mode_id)
    end
  elseif action == "set_scale" then
    if cmd.id ~= nil and cmd.scale ~= nil then
      setOutputScale(cmd.id, cmd.scale)
    end
  end
end)

function onOutputsChanged()
  refresh()
end

function onConfigChanged()
  readConfig()
  state.backend = detectBackend()
  refresh()
end

function onIpc(event)
  if event == "refresh" then
    refresh()
  elseif event == "apply" then
    applyLayout()
  end
end

readConfig()
state.backend = detectBackend()
state.status = "refreshing"
publish()
refresh()

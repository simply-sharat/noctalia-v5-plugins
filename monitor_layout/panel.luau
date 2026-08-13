--!nonstrict
-- Monitor Layout [[panel]] entry.
--
-- The legacy v4 panel used a free-form drag canvas to position displays. v5's
-- declarative UI has no absolute-positioning canvas and its drag-and-drop is
-- limited to list reordering, so this migration replaces the canvas with:
--   * a proportional arrangement strip (tiles sized by logical resolution),
--   * a selectable output list,
--   * a numeric inspector (resolution, X/Y, scale) for the selected output.
-- Apply / Reset / Refresh and a copyable config snippet are preserved.

local PREVIEW_WIDTH = 600
local PREVIEW_HEIGHT = 110

local data = nil
local activeTab = "control"
local editX = ""
local editY = ""
local localNotice = ""

local function send(cmd)
  noctalia.state.set("layout.cmd", cmd)
end

local function sendSelect(id)
  send({ action = "select", id = id })
end

local function sendSetPosition(id, x, y)
  send({ action = "set_position", id = id, x = x, y = y })
end

local function sendSetResolution(id, modeId)
  send({ action = "set_resolution", id = id, mode_id = modeId })
end

local function sendSetScale(id, scale)
  send({ action = "set_scale", id = id, scale = scale })
end

local function selectedOutput()
  if data == nil then
    return nil
  end
  for _, output in ipairs(data.draft_outputs or {}) do
    if output.output_id == data.selected_id then
      return output
    end
  end
  return nil
end

local function parseCoord(text, fallback)
  local value = tonumber(text)
  if value == nil then
    return fallback
  end
  return math.round(value)
end

local function applyPosition()
  local sel = selectedOutput()
  if sel == nil then
    return
  end
  local x = parseCoord(editX, sel.x)
  local y = parseCoord(editY, sel.y)
  sendSetPosition(sel.output_id, x, y)
end

local function statusText()
  if data == nil then
    return ""
  end
  if data.status == "" then
    return ""
  end
  if data.status == "ready" then
    return noctalia.tr("status.ready", { count = tostring(data.status_count) })
  end
  return noctalia.tr("status." .. data.status)
end

local function statusBanners()
  local rows = {}
  if data ~= nil and data.error ~= "" then
    table.insert(rows, ui.label({ text = data.error, fontSize = 12, color = "error", textAlign = "center" }))
  end
  if data ~= nil and data.pending then
    table.insert(rows, ui.label({ text = noctalia.tr("panel.pending_changes"), fontSize = 12, color = "primary", textAlign = "center" }))
  end
  local status = statusText()
  if status ~= "" then
    table.insert(rows, ui.label({ text = status, fontSize = 12, color = "primary", textAlign = "center" }))
  end
  if localNotice ~= "" then
    table.insert(rows, ui.label({ text = localNotice, fontSize = 12, color = "primary", textAlign = "center" }))
  end
  return rows
end

local function previewChildren()
  local outputs = data ~= nil and data.draft_outputs or {}
  if #outputs == 0 then
    return {}
  end

  local totalWidth = 0
  local maxHeight = 0
  for _, output in ipairs(outputs) do
    totalWidth = totalWidth + (output.logical_width or 1)
    if (output.logical_height or 0) > maxHeight then
      maxHeight = output.logical_height
    end
  end

  local scale = math.min(1, PREVIEW_WIDTH / totalWidth, PREVIEW_HEIGHT / maxHeight)

  local children = {}
  for _, output in ipairs(outputs) do
    local selected = output.output_id == data.selected_id
    table.insert(children, ui.column({
      key = "tile-" .. output.output_id,
      width = math.max(24, (output.logical_width or 1) * scale),
      height = math.max(16, (output.logical_height or 1) * scale),
      radius = 6,
      border = selected and "primary" or "outline",
      borderWidth = selected and 2 or 1,
      fill = selected and "primary/0.12" or "surface_variant/0.5",
      align = "center",
      onClick = function()
        sendSelect(output.output_id)
      end,
    }, {
      ui.label({ text = output.name, fontSize = 9, color = "on_surface", maxLines = 1 }),
    }))
  end
  return children
end

local function outputList()
  local outputs = data ~= nil and data.draft_outputs or {}
  if #outputs == 0 then
    return { ui.label({ text = noctalia.tr("panel.empty"), fontSize = 12, color = "on_surface_variant", textAlign = "center" }) }
  end

  local rows = {}
  for _, output in ipairs(outputs) do
    local selected = output.output_id == data.selected_id
    table.insert(rows, ui.row({
      key = "output-" .. output.output_id,
      gap = 8,
      align = "center",
      paddingH = 10,
      paddingV = 8,
      radius = 8,
      fill = selected and "primary/0.12" or "transparent",
      border = selected and "primary" or "outline",
      borderWidth = selected and 1 or 0,
      onClick = function()
        sendSelect(output.output_id)
      end,
    }, {
      ui.box({ width = 6, height = 6, radius = 3, fill = output.active and "primary" or "outline" }),
      ui.label({
        text = output.name,
        fontWeight = selected and "bold" or "normal",
        color = "on_surface",
        flexGrow = 1,
      }),
      ui.label({ text = output.resolution_label, fontSize = 11, color = "on_surface_variant" }),
    }))
  end
  return rows
end

local function inspectorChildren()
  local sel = selectedOutput()
  if sel == nil then
    return { ui.label({ text = noctalia.tr("panel.selection_hint"), fontSize = 12, color = "on_surface_variant" }) }
  end

  local children = {
    ui.label({ text = sel.name, fontSize = 13, fontWeight = "bold", color = "on_surface" }),
    ui.label({
      text = sel.description ~= "" and sel.description or "-",
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 1,
    }),
    ui.separator({ spacing = 4 }),
  }

  -- Resolution picker
  table.insert(children, ui.label({ text = noctalia.tr("panel.resolution"), fontSize = 11, color = "on_surface_variant" }))
  local modeLabels = {}
  local modeIds = {}
  local selectedIndex = -1
  for index, mode in ipairs(sel.available_modes or {}) do
    table.insert(modeLabels, mode.label)
    table.insert(modeIds, mode.id)
    if mode.id == sel.mode_id then
      selectedIndex = index - 1
    end
  end
  if #modeIds > 0 then
    table.insert(children, ui.select({
      options = modeLabels,
      selectedIndex = selectedIndex,
      controlSize = "sm",
      onChange = function(index)
        local modeId = modeIds[index + 1]
        if modeId ~= nil then
          sendSetResolution(sel.output_id, modeId)
        end
      end,
    }))
  end

  -- Position inputs
  table.insert(children, ui.label({ text = noctalia.tr("panel.position"), fontSize = 11, color = "on_surface_variant" }))
  table.insert(children, ui.row({ gap = 8 }, {
    ui.input({
      key = "posx-" .. sel.output_id,
      value = tostring(sel.x),
      placeholder = noctalia.tr("panel.position_x"),
      controlSize = "sm",
      flexGrow = 1,
      onChange = function(value) editX = value end,
      onSubmit = function() applyPosition() end,
    }),
    ui.input({
      key = "posy-" .. sel.output_id,
      value = tostring(sel.y),
      placeholder = noctalia.tr("panel.position_y"),
      controlSize = "sm",
      flexGrow = 1,
      onChange = function(value) editY = value end,
      onSubmit = function() applyPosition() end,
    }),
    ui.button({
      text = noctalia.tr("panel.set_position"),
      controlSize = "sm",
      onClick = function() applyPosition() end,
    }),
  }))

  -- Scale slider
  table.insert(children, ui.label({ text = noctalia.tr("panel.scale"), fontSize = 11, color = "on_surface_variant" }))
  table.insert(children, ui.slider({
    key = "scale-" .. sel.output_id,
    min = 0.5,
    max = 3,
    step = 0.05,
    value = sel.scale,
    controlSize = "sm",
    onDragEnd = function(value)
      sendSetScale(sel.output_id, value)
    end,
  }))
  table.insert(children, ui.label({ text = noctalia.tr("panel.scale_desc"), fontSize = 11, color = "on_surface_variant" }))

  table.insert(children, ui.separator({ spacing = 4 }))
  table.insert(children, ui.row({ gap = 12, justify = "space_between" }, {
    ui.label({ text = noctalia.tr("panel.transform") .. ": " .. tostring(sel.transform), fontSize = 11, color = "on_surface_variant" }),
    ui.label({ text = noctalia.tr("panel.backend") .. ": " .. tostring(data.backend), fontSize = 11, color = "on_surface_variant" }),
  }))

  return children
end

local function actionButtons()
  local busy = data ~= nil and (data.is_refreshing == true or data.is_applying == true)
  local pending = data ~= nil and data.pending == true

  return {
    ui.row({ gap = 8 }, {
      ui.button({
        text = noctalia.tr("actions.refresh"),
        variant = "secondary",
        flexGrow = 1,
        enabled = not busy,
        onClick = function() send({ action = "refresh" }) end,
      }),
      ui.button({
        text = noctalia.tr("actions.reset"),
        flexGrow = 1,
        enabled = pending and not busy,
        onClick = function() send({ action = "reset" }) end,
      }),
      ui.button({
        text = noctalia.tr("actions.apply"),
        variant = "primary",
        flexGrow = 1,
        enabled = pending and not busy,
        onClick = function() send({ action = "apply" }) end,
      }),
    }),
  }
end

local function controlContent()
  local children = {}
  for _, banner in ipairs(statusBanners()) do
    table.insert(children, banner)
  end

  table.insert(children, ui.label({ text = noctalia.tr("panel.arrangement"), fontSize = 13, fontWeight = "bold", color = "on_surface" }))
  if #previewChildren() > 0 then
    table.insert(children, ui.column({ fill = "surface_variant/0.3", radius = 8, padding = 10, align = "center" }, {
      ui.row({ gap = 8, align = "center" }, previewChildren()),
    }))
  end

  table.insert(children, ui.label({ text = noctalia.tr("panel.outputs"), fontSize = 13, fontWeight = "bold", color = "on_surface" }))
  for _, row in ipairs(outputList()) do
    table.insert(children, row)
  end

  table.insert(children, ui.label({ text = noctalia.tr("panel.inspector_title"), fontSize = 13, fontWeight = "bold", color = "on_surface" }))
  for _, child in ipairs(inspectorChildren()) do
    table.insert(children, child)
  end

  for _, button in ipairs(actionButtons()) do
    table.insert(children, button)
  end

  return children
end

local function configContent()
  local children = {}

  table.insert(children, ui.label({ text = noctalia.tr("panel.config_title"), fontSize = 13, fontWeight = "bold", color = "on_surface" }))
  table.insert(children, ui.label({ text = noctalia.tr("panel.config_description"), fontSize = 11, color = "on_surface_variant" }))

  if data ~= nil and data.error ~= "" then
    table.insert(children, ui.label({ text = data.error, fontSize = 12, color = "error" }))
  end

  local script = data ~= nil and data.config_content or ""
  if script == "" then
    script = noctalia.tr("panel.config_empty")
  end
  table.insert(children, ui.column({ fill = "surface_variant/0.5", radius = 8, padding = 10, flexGrow = 1 }, {
    ui.label({ text = script, fontSize = 11, color = "on_surface_variant" }),
  }))

  table.insert(children, ui.row({ gap = 8 }, {
    ui.button({
      text = noctalia.tr("actions.copy_config"),
      variant = "primary",
      flexGrow = 1,
      enabled = data ~= nil and data.config_content ~= "",
      onClick = function() onCopyConfig() end,
    }),
    ui.button({
      text = noctalia.tr("actions.refresh"),
      variant = "secondary",
      flexGrow = 1,
      enabled = data ~= nil and not data.is_refreshing and not data.is_applying,
      onClick = function() send({ action = "refresh" }) end,
    }),
  }))

  for _, banner in ipairs(statusBanners()) do
    table.insert(children, banner)
  end

  return children
end

local function render()
  local content = activeTab == "control" and controlContent() or configContent()

  panel.render(ui.column({ padding = 16, gap = 10, fill = "surface", radius = 14 }, {
    ui.row({ align = "center", gap = 6 }, {
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({ glyph = "close", variant = "ghost", tooltip = noctalia.tr("panel.close"), onClick = function() panel.close() end }),
    }),
    ui.row({ gap = 6 }, {
      ui.button({
        text = noctalia.tr("panel.tab_control"),
        variant = activeTab == "control" and "secondary" or "ghost",
        onClick = function() activeTab = "control"; render() end,
      }),
      ui.button({
        text = noctalia.tr("panel.tab_configuration"),
        variant = activeTab == "config" and "secondary" or "ghost",
        onClick = function() activeTab = "config"; render() end,
      }),
    }),
    ui.scroll({ flexGrow = 1, fill = "transparent", gap = 8 }, content),
  }))
end

function onCopyConfig()
  if data == nil or data.config_content == "" then
    localNotice = noctalia.tr("errors.unsupported_backend")
    render()
    return
  end
  local header = "# " .. data.backend .. " monitor configuration\n"
  noctalia.copyToClipboard(header .. data.config_content, "text/plain")
  localNotice = noctalia.tr("status.config_copied")
  render()
end

noctalia.state.watch("layout.data", function(value)
  data = value
  render()
end)

function onOpen()
  render()
end

data = noctalia.state.get("layout.data")

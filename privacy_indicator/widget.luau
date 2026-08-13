--!nonstrict
-- Privacy Indicator [[widget]] bar widget: three glyphs (microphone, camera,
-- screen share) that light up while that device is captured, rendered
-- declaratively so the gap follows the icon_spacing setting. Reads widget
-- settings with noctalia.getConfig and capture state from the [[service]]
-- via noctalia.state.

local data = nil

local function anyActive()
  if data == nil then
    return false
  end
  return data.mic_active == true or data.cam_active == true or data.scr_active == true
end

local function activeColor()
  return noctalia.getConfig("active_color") or "primary"
end

local function inactiveColor()
  local value = noctalia.getConfig("inactive_color") or "none"
  if value == "none" then
    return "on_surface/0.3"
  end
  return value
end

local function buildTooltip()
  if data == nil then
    return ""
  end
  local parts = {}
  if #(data.mic_apps or {}) > 0 then
    table.insert(parts, noctalia.tr("tooltip.mic", { apps = table.concat(data.mic_apps, ", ") }))
  end
  if #(data.cam_apps or {}) > 0 then
    table.insert(parts, noctalia.tr("tooltip.cam", { apps = table.concat(data.cam_apps, ", ") }))
  end
  if #(data.scr_apps or {}) > 0 then
    table.insert(parts, noctalia.tr("tooltip.screen", { apps = table.concat(data.scr_apps, ", ") }))
  end
  return table.concat(parts, "\n")
end

local function render()
  local hideInactive = noctalia.getConfig("hide_inactive") == true
  local visible = not hideInactive or anyActive()
  barWidget.setVisible(visible)
  if not visible then
    return
  end

  local micOn = data ~= nil and data.mic_active == true
  local camOn = data ~= nil and data.cam_active == true
  local scrOn = data ~= nil and data.scr_active == true

  local showMic = not hideInactive or micOn
  local showCam = not hideInactive or camOn
  local showScr = not hideInactive or scrOn

  local spacing = tonumber(noctalia.getConfig("icon_spacing")) or 4
  local container = barWidget.isVertical() and ui.column or ui.row

  local glyphs = {}
  if showMic then
    table.insert(glyphs, ui.glyph({ name = micOn and "microphone" or "microphone-off", color = micOn and activeColor() or inactiveColor() }))
  end
  if showCam then
    table.insert(glyphs, ui.glyph({ name = camOn and "camera" or "camera-off", color = camOn and activeColor() or inactiveColor() }))
  end
  if showScr then
    table.insert(glyphs, ui.glyph({ name = scrOn and "screen-share" or "screen-share-off", color = scrOn and activeColor() or inactiveColor() }))
  end

  if #glyphs > 0 then
    barWidget.render(container({ gap = math.max(0, spacing), align = "center" }, glyphs))
  end
  barWidget.setTooltip(buildTooltip())
end

function onClick()
  noctalia.togglePanel("simply-sharat/privacy_indicator:panel")
end

function onRightClick()
  noctalia.openSettings()
end

noctalia.state.watch("privacy.data", function(value)
  data = value
  render()
end)

data = noctalia.state.get("privacy.data")
render()

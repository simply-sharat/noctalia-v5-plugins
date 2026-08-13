--!nonstrict
-- Monique [[widget]] bar widget. Shows a display icon (tinted with
-- active_color, defaulting to "primary") and, optionally, the active profile
-- name. Left click opens the profile panel, middle click opens the Monique
-- editor, right click opens plugin settings.

local showLabel = noctalia.getConfig("show_profile_label")
local activeColor = noctalia.getConfig("active_color") or "primary"

local data = nil

local function render()
  local hasProfile = data ~= nil and data.active_profile ~= ""

  local container = barWidget.isVertical() and ui.column or ui.row
  local children = {
    ui.glyph({ name = "device-desktop", size = 14, color = activeColor }),
  }
  if showLabel and hasProfile then
    table.insert(children, ui.label({ text = data.active_profile, fontSize = 11, color = activeColor }))
  end

  barWidget.render(container({ gap = 6, align = "center" }, children))
end

local function renderTooltip()
  if data == nil then
    barWidget.setTooltip(noctalia.tr("widget.tooltip"))
    return
  end
  if not data.available then
    barWidget.setTooltip(noctalia.tr("errors.monique_not_found"))
    return
  end
  if data.active_profile ~= "" then
    barWidget.setTooltip(data.active_profile)
  else
    barWidget.setTooltip(noctalia.tr("widget.no_profile"))
  end
end

noctalia.state.watch("monique.data", function(value)
  if type(value) == "table" then
    data = value
    render()
    renderTooltip()
  end
end)

function onClick()
  noctalia.togglePanel("simply-sharat/monique:panel")
end

function onMiddleClick()
  if data ~= nil and data.available then
    noctalia.runAsync("monique")
  end
end

function onRightClick()
  noctalia.openSettings()
end

data = noctalia.state.get("monique.data")
render()
renderTooltip()

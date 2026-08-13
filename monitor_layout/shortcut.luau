--!nonstrict
-- Monitor Layout [[shortcut]] control-center tile. Toggles the layout panel.

local function render()
  shortcut.setLabel(noctalia.tr("widget.tooltip"))
  shortcut.setIcon("device-desktop")
  shortcut.setActive(false)
end

render()

function onClick()
  noctalia.togglePanel("simply-sharat/monitor_layout:panel")
end

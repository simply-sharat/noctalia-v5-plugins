--!nonstrict
-- Monitor Layout [[widget]] bar widget. An icon button that opens the layout
-- panel; right click opens the plugin settings.

local iconColor = noctalia.getConfig("icon_color") or "primary"

barWidget.setGlyph("device-desktop")
barWidget.setGlyphColor(iconColor)
barWidget.setTooltip(noctalia.tr("widget.tooltip"))

function onClick()
  noctalia.togglePanel("simply-sharat/monitor_layout:panel")
end

function onRightClick()
  noctalia.openSettings()
end

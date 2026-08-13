--!nonstrict
-- Privacy Indicator [[panel]]: the access history - who used the microphone,
-- camera, or screen share, when, and whether it started or stopped. History
-- is produced and persisted by the [[service]]; this panel reads it from
-- noctalia.state and sends "clear" back through the "privacy.cmd" channel.

local history = {}

local TYPE_COLORS = {
  Microphone = "primary",
  Camera = "secondary",
  Screen = "tertiary",
}

local function sendClear()
  noctalia.state.set("privacy.cmd", "clear")
end

local function historyRow(index, entry)
  local color = TYPE_COLORS[entry.type] or "primary"
  local stopped = entry.action == "stopped"
  local actionKey = stopped and "history.action.stopped" or "history.action.started"

  return ui.row({
    key = "history-" .. index .. "-" .. tostring(entry.timestamp),
    gap = 10,
    align = "center",
    paddingH = 10,
    paddingV = 8,
    radius = 8,
    fill = "surface_variant/0.5",
  }, {
    ui.glyph({ name = entry.icon or "shield", color = color }),
    ui.column({ gap = 2, flexGrow = 1 }, {
      ui.label({ text = entry.app or "", fontSize = 13, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
      ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = entry.time or "", fontSize = 11, color = "on_surface_variant" }),
        ui.label({ text = noctalia.tr(actionKey), fontSize = 11, fontWeight = "bold", color = stopped and "error" or color }),
      }),
    }),
  })
end

local function render()
  local rows = {}
  if #history == 0 then
    rows = {
      ui.label({
        text = noctalia.tr("history.empty"),
        fontSize = 12,
        color = "on_surface_variant",
        textAlign = "center",
      }),
    }
  else
    for index, entry in ipairs(history) do
      table.insert(rows, historyRow(index, entry))
    end
  end

  panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "shield-check", color = "primary" }),
      ui.label({ text = noctalia.tr("history.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.button({
        glyph = "trash",
        variant = "ghost",
        tooltip = noctalia.tr("history.clear"),
        onClick = function() sendClear() end,
      }),
    }),
    ui.separator({ spacing = 4 }),
    ui.scroll({ flexGrow = 1, gap = 8 }, rows),
  }))
end

noctalia.state.watch("privacy.history", function(value)
  if type(value) == "table" then
    history = value
    render()
  end
end)

function onOpen()
  render()
end

history = noctalia.state.get("privacy.history") or {}

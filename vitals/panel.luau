--!nonstrict
-- Vitals [[panel]] entry. A thin client of the service state ("vitals.data"):
-- scrollable per-category sections with a section header (glyph + name + group
-- summary) and a label/value row per sensor, tinted with the warning/critical
-- colors the service assigned.

local data = nil

local function section(category)
  local group = (data ~= nil and data.groups[category]) or nil
  local keys = data.byCategory[category] or {}

  local children = {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = data.category_glyphs[category] or "info", size = 14, color = "primary" }),
      ui.label({
        text = data.category_labels[category] or category,
        fontSize = 13,
        fontWeight = "bold",
        color = "on_surface",
        flexGrow = 1,
        maxLines = 1,
      }),
      group ~= nil
          and ui.label({
            text = group.text,
            fontSize = 11,
            color = group.color or "on_surface_variant",
            maxLines = 1,
          })
        or nil,
    }),
  }

  for _, key in ipairs(keys) do
    local sensor = data.sensors[key]
    if sensor ~= nil then
      children[#children + 1] = ui.row({ gap = 8, align = "center", paddingH = 12 }, {
        ui.label({
          text = sensor.label,
          fontSize = 11,
          color = "on_surface_variant",
          flexGrow = 1,
          maxLines = 1,
        }),
        ui.label({
          text = sensor.text,
          fontSize = 11,
          fontWeight = "bold",
          color = sensor.color or "on_surface",
          maxLines = 1,
        }),
      })
    end
  end

  return ui.column({ gap = 4, paddingH = 8, paddingV = 6 }, children)
end

local function render()
  if data == nil or #data.categories == 0 then
    -- The panel surface is host-owned (background, corners and shadow are
    -- painted by the host to match), so the root tree adds gaps only — no
    -- self-drawn fill/radius/padding, which would mismatch the drop shadow.
    panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
      ui.label({
        text = noctalia.tr("panel.loading"),
        fontSize = 12,
        color = "on_surface_variant",
        textAlign = "center",
      }),
    }))
    return
  end

  local sections = {}
  for _, category in ipairs(data.categories) do
    sections[#sections + 1] = section(category)
  end

  panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "activity", color = "primary" }),
      ui.label({
        text = noctalia.tr("panel.title"),
        fontSize = 16,
        fontWeight = "bold",
        color = "on_surface",
        flexGrow = 1,
      }),
      ui.label({
        text = data.last_update,
        fontSize = 11,
        color = "on_surface_variant",
        maxLines = 1,
      }),
    }),
    ui.separator({ spacing = 4 }),
    ui.scroll({ flexGrow = 1, gap = 8 }, sections),
  }))
end

noctalia.state.watch("vitals.data", function(value)
  if type(value) == "table" then
    data = value
    render()
  end
end)

function onOpen()
  render()
end

data = noctalia.state.get("vitals.data")
render()

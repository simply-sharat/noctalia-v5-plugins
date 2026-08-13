--!nonstrict
-- Monique [[panel]] entry. Shows the active profile, a warning when monique
-- is not installed, and the list of saved profiles. Clicking a profile
-- switches to it through the "monique.cmd" channel.

local data = nil

local function send(cmd)
  noctalia.state.set("monique.cmd", cmd)
end

local function profileRow(index, profile)
  local active = profile == (data and data.active_profile)
  local rowProps = {
    key = "profile-" .. index,
    gap = 8,
    align = "center",
    paddingH = 10,
    paddingV = 8,
    radius = 8,
    onClick = function()
      send({ action = "switch", profile = profile })
      panel.close()
    end,
  }
  if active then
    rowProps.fill = "primary/0.12"
  end

  return ui.row(rowProps, {
    ui.glyph({ name = active and "check" or "device-desktop", color = active and "primary" or "on_surface_variant" }),
    ui.label({
      text = profile,
      fontWeight = active and "bold" or "normal",
      color = active and "primary" or "on_surface",
      flexGrow = 1,
      maxLines = 1,
    }),
  })
end

local function bodyRows()
  if data ~= nil and not data.available then
    return {
      ui.label({
        text = noctalia.tr("errors.monique_not_found"),
        fontSize = 12,
        color = "error",
        textAlign = "center",
        wrap = true,
      }),
    }
  end
  if data ~= nil and data.status == "loading" then
    return {
      ui.label({ text = noctalia.tr("panel.loading"), fontSize = 12, color = "on_surface_variant", textAlign = "center" }),
    }
  end
  local profiles = (data ~= nil and data.profiles) or {}
  if #profiles == 0 then
    return {
      ui.label({ text = noctalia.tr("panel.no_profiles"), fontSize = 12, color = "on_surface_variant", textAlign = "center", wrap = true }),
    }
  end
  local rows = {}
  for index, profile in ipairs(profiles) do
    table.insert(rows, profileRow(index, profile))
  end
  return rows
end

local function render()
  local activeProfile = (data ~= nil and data.active_profile ~= "") and data.active_profile or nil

  -- The panel surface is host-owned (background, corners and shadow are
  -- painted by the host to match), so the root tree adds gaps only — no
  -- self-drawn fill/radius/padding, which would mismatch the drop shadow.
  panel.render(ui.column({ flexGrow = 1, gap = 10 }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "device-desktop", color = "primary" }),
      ui.label({ text = noctalia.tr("panel.title"), fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
      ui.label({
        text = activeProfile or noctalia.tr("panel.no_profile"),
        fontSize = 12,
        fontWeight = activeProfile ~= nil and "bold" or "normal",
        color = activeProfile ~= nil and "primary" or "on_surface_variant",
        maxLines = 1,
      }),
    }),
    ui.separator({ spacing = 4 }),
    ui.scroll({ flexGrow = 1, gap = 8 }, bodyRows()),
  }))
end

noctalia.state.watch("monique.data", function(value)
  if type(value) == "table" then
    data = value
    render()
  end
end)

function onOpen()
  render()
end

data = noctalia.state.get("monique.data")
render()

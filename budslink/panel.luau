--!nonstrict
-- BudsLink [[panel]] entry. A thin client of the service state
-- ("budslink.data"): device header, per-earbud battery bars, noise-control /
-- equalizer toggles, and the active options box (radio group, slider, check
-- buttons). Actions are sent through the "budslink.cmd" channel.

local data = nil

-- Local draft for the options slider so a drag stays smooth while the
-- device round-trips the value; cleared once the published state catches up.
local boxSliderDraft = nil

local function send(cmd)
  noctalia.state.set("budslink.cmd", cmd)
end

local function firstDevice()
  return (data ~= nil and data.devices ~= nil and #data.devices > 0) and data.devices[1] or nil
end

local function deviceState()
  local device = firstDevice()
  return (device ~= nil and device.state ~= nil and device.state) or {}
end

local function deviceConfig()
  local device = firstDevice()
  return (device ~= nil and device.config ~= nil and device.config) or {}
end

local function toggleButtons(prefix)
  local s = deviceState()
  local c = deviceConfig()
  local active = tonumber(s[prefix .. "State"] or 0) or 0
  local out = {}
  for i = 1, 4 do
    local name = c[prefix .. "Button" .. tostring(i) .. "Name"]
    if name ~= nil and #name > 0 then
      out[#out + 1] = { index = i, name = name, active = active == i }
    end
  end
  return out
end

local function optionsBoxNumber()
  return tonumber(deviceState().optionsBoxVisible or 0) or 0
end

local function boxRadioButtons()
  local box = optionsBoxNumber()
  local c = deviceConfig()
  local s = deviceState()
  local options = c["box" .. tostring(box) .. "RadioButton"] or {}
  local active = tonumber(s["box" .. tostring(box) .. "RadioButtonState"] or 0) or 0
  local out = {}
  for i, name in ipairs(options) do
    out[#out + 1] = { index = i, name = name, active = active == i }
  end
  return out
end

local function boxCheckButtons()
  local box = optionsBoxNumber()
  local c = deviceConfig()
  local s = deviceState()
  local names = c["box" .. tostring(box) .. "CheckButton"] or {}
  local out = {}
  for i, title in ipairs(names) do
    out[#out + 1] = {
      index = i,
      title = title,
      checked = (tonumber(s["box" .. tostring(box) .. "CheckButton" .. tostring(i) .. "State"] or 0) or 0) == 1,
    }
  end
  return out
end

local function labels()
  local s = deviceState()
  local out = {}
  for _, key in ipairs({ "labelIndicator1", "labelIndicator2", "labelIndicator3" }) do
    local text = s[key]
    if text ~= nil and #text > 0 then
      out[#out + 1] = text
    end
  end
  return out
end

local function section(title, control)
  local children = {}
  if title ~= nil and #title > 0 then
    children[#children + 1] = ui.label({
      text = title,
      fontSize = 12,
      fontWeight = "medium",
      color = "on_surface_variant",
    })
  end
  children[#children + 1] = control
  return ui.column({ gap = 8 }, children)
end

local function batteryRow(name, level, status)
  if status == "not-reported" or status == "disconnected" then
    return nil
  end
  local levelN = tonumber(level) or 0
  local threshold = tonumber(noctalia.getConfig("low_battery_threshold")) or 20
  local color = levelN <= threshold and "error" or "primary"
  local children = {
    ui.label({ text = name, fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
    ui.progress({
      progress = levelN / 100,
      fill = color,
      track = "surface_variant",
      width = 120,
      height = 6,
      radius = 3,
    }),
    ui.label({ text = string.format("%d%%", levelN), fontSize = 11, fontWeight = "bold", color = color, maxLines = 1 }),
  }
  if status == "charging" then
    children[#children + 1] = ui.label({ text = noctalia.tr("battery.charging"), fontSize = 11, color = "primary", maxLines = 1 })
  end
  return ui.row({ gap = 8, align = "center" }, children)
end

local function toggleSection(prefix, title, buttons)
  local rows = {}
  for _, b in ipairs(buttons) do
    rows[#rows + 1] = ui.button({
      key = prefix .. "-" .. tostring(b.index),
      text = b.name,
      glyph = b.active and "check" or "",
      variant = b.active and "secondary" or "default",
      onClick = function()
        send({ action = prefix .. "State", value = b.index })
        panel.close()
      end,
    })
  end
  return section(title, ui.column({ gap = 6 }, rows))
end

local function render()
  local device = firstDevice()
  local connected = data ~= nil and data.connected == true
  local s = deviceState()
  local c = deviceConfig()

  local content = {}

  if not connected then
    content[#content + 1] = ui.label({
      text = noctalia.tr("panel.no_device"),
      fontSize = 13,
      color = "on_surface_variant",
      textAlign = "center",
      wrap = true,
    })
  else
    local battery = tonumber(s.computedBatteryLevel or -1) or -1
    content[#content + 1] = ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "battery", size = 16, color = "primary" }),
      ui.label({
        text = battery >= 0 and (noctalia.tr("battery.total") .. ": " .. battery .. "%") or noctalia.tr("panel.no_battery"),
        fontSize = 13,
        fontWeight = "bold",
        color = "on_surface",
        flexGrow = 1,
      }),
      ui.button({ text = noctalia.tr("panel.open_app"), onClick = function() send({ action = "open" }) end }),
    })

    local rows = {
      batteryRow(noctalia.tr("battery.left"), s.battery1Level, s.battery1Status),
      batteryRow(noctalia.tr("battery.right"), s.battery2Level, s.battery2Status),
      batteryRow(noctalia.tr("battery.case"), s.battery3Level, s.battery3Status),
    }
    local present = {}
    for _, row in ipairs(rows) do
      if row ~= nil then
        present[#present + 1] = row
      end
    end
    if #present > 0 then
      content[#content + 1] = ui.column({ gap = 6 }, present)
    end

    local t1 = toggleButtons("toggle1")
    if s.toggle1Visible and #t1 > 0 then
      content[#content + 1] = toggleSection("toggle1", c.toggle1Title or "", t1)
    end

    local t2 = toggleButtons("toggle2")
    if s.toggle2Visible and #t2 > 0 then
      content[#content + 1] = toggleSection("toggle2", c.toggle2Title or "", t2)
    end

    local box = optionsBoxNumber()
    if box > 0 then
      local boxSections = {}

      local radios = boxRadioButtons()
      if #radios > 0 then
        local radioRows = {}
        for _, r in ipairs(radios) do
          radioRows[#radioRows + 1] = ui.button({
            key = "radio-" .. tostring(r.index),
            text = r.name,
            glyph = r.active and "circle-check" or "circle",
            variant = r.active and "secondary" or "default",
            onClick = function()
              send({ action = "box" .. tostring(box) .. "RadioButtonState", value = r.index })
              panel.close()
            end,
          })
        end
        boxSections[#boxSections + 1] = section(c["box" .. tostring(box) .. "RadioTitle"] or "", ui.column({ gap = 6 }, radioRows))
      end

      local sliderTitle = c["box" .. tostring(box) .. "SliderTitle"] or ""
      local sliderValue = tonumber(s["box" .. tostring(box) .. "SliderValue"] or -1) or -1
      if sliderValue >= 0 and boxSliderDraft ~= nil then
        sliderValue = boxSliderDraft
      end
      if sliderTitle ~= "" and sliderValue >= 0 then
        boxSections[#boxSections + 1] = section(
          string.format("%s: %d%%", sliderTitle, sliderValue),
          ui.slider({
            min = 0,
            max = 100,
            step = 1,
            value = sliderValue,
            onChange = function(value)
              local v = math.floor(tonumber(value) or 0)
              boxSliderDraft = v
              send({ action = "box" .. tostring(box) .. "SliderValue", value = v })
            end,
          })
        )
      end
      -- Once the published state matches the draft, the round-trip is done.
      if boxSliderDraft ~= nil and (tonumber(s["box" .. tostring(box) .. "SliderValue"] or -1) or -1) == boxSliderDraft then
        boxSliderDraft = nil
      end

      for _, ch in ipairs(boxCheckButtons()) do
        boxSections[#boxSections + 1] = ui.row({ key = "check-" .. tostring(ch.index), gap = 8, align = "center" }, {
          ui.toggle({
            checked = ch.checked,
            onChange = function(value)
              send({ action = "box" .. tostring(box) .. "CheckButton" .. tostring(ch.index) .. "State", value = value == "true" and 1 or 0 })
            end,
          }),
          ui.label({ text = ch.title, fontSize = 11, color = "on_surface", flexGrow = 1, maxLines = 1 }),
        })
      end

      if #boxSections > 0 then
        content[#content + 1] = ui.column({ gap = 10 }, boxSections)
      end
    end

    local labelList = labels()
    if #labelList > 0 then
      local labelRows = {}
      for _, text in ipairs(labelList) do
        labelRows[#labelRows + 1] = ui.row({ gap = 8, align = "center" }, {
          ui.box({ width = 6, height = 6, radius = 3, fill = "primary" }),
          ui.label({ text = text, fontSize = 11, color = "on_surface", flexGrow = 1, maxLines = 1 }),
        })
      end
      content[#content + 1] = ui.column({ gap = 6 }, labelRows)
    end
  end

  panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = "headphones", size = 18, color = "primary" }),
        ui.label({
          text = (device ~= nil and device.alias ~= nil and device.alias ~= "") and device.alias or noctalia.tr("panel.title"),
          fontSize = 16,
          fontWeight = "bold",
          color = "on_surface",
          maxLines = 1,
        }),
      }),
      ui.button({ glyph = "close", variant = "ghost", tooltip = noctalia.tr("panel.close"), onClick = function() panel.close() end }),
    }),
    ui.separator({ spacing = 4 }),
    ui.scroll({ flexGrow = 1, gap = 10 }, content),
    ui.row({ gap = 10 }, {
      ui.button({ text = noctalia.tr("panel.refresh"), variant = "secondary", flexGrow = 1, onClick = function() send({ action = "refresh" }) end }),
      ui.button({ text = noctalia.tr("panel.open_app"), flexGrow = 1, onClick = function() send({ action = "open" }) end }),
    }),
  }))
end

noctalia.state.watch("budslink.data", function(value)
  if type(value) == "table" then
    data = value
    render()
  end
end)

function onOpen(_context)
  render()
end

data = noctalia.state.get("budslink.data")
render()

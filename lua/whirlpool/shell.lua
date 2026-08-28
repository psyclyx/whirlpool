-- Tidepool/Shoal behavior expressed as an ordinary Whirlpool retained tree.
-- The host provides desktop snapshots; widget policy and system polling live
-- here and remain identical for River shell and portable layer-shell roles.

local theme = require("whirlpool.theme")
local Status = require("whirlpool.status")

local BAR_HEIGHT = 38
local SPARK_COUNT = 15
local CLEAR = { 0, 0, 0, 0 }

local function meter(parent, color, initial)
  local column = parent:column({ width = 8, height = BAR_HEIGHT })
  column:spacer({ flex = 1 })
  local fill = column:shape({ width = 8, height = 2, fill = color })
  local function update(percent, next_color)
    fill:set("height", math.max(2, math.floor(BAR_HEIGHT * math.min(100, math.max(0, percent or 0)) / 100 + 0.5)))
    if next_color then fill:set("fill", next_color) end
  end
  update(initial or 0)
  return update
end

local function section(parent, width, background)
  local panel = parent:stack({ width = width, height = BAR_HEIGHT })
  panel:shape({ fill = background })
  return panel:row({ padding = { 0, 9, 0, 5 }, gap = 6 })
end

local function sparkline(parent, color)
  local row = parent:row({ height = BAR_HEIGHT, gap = 2 })
  local bars = {}
  for index = 1, SPARK_COUNT do
    local column = row:column({ width = 3, height = BAR_HEIGHT })
    column:spacer({ flex = 1 })
    bars[index] = column:shape({ width = 3, height = 2, fill = color })
  end
  return function(values)
    for index, bar in ipairs(bars) do
      local value = values[index] or 0
      bar:set("height", math.max(2, math.floor((BAR_HEIGHT - 2) * math.min(1, math.max(0, value)) + 0.5)))
    end
  end
end

local function build(parent)
  local status = Status.new()
  local state = {
    role = "shell",
    selected = 1,
    occupied = {},
    focused_output = true,
    app_id = "",
    title = "",
    columns = {},
  }

  local root = parent:stack()

  -- Full-output River shell: the flexible spacer pins the bar to the bottom.
  -- A 38px portable layer surface naturally collapses that spacer to zero.
  local shell = root:column()
  shell:spacer({ flex = 1 })
  local bar = shell:stack({ height = BAR_HEIGHT })
  bar:shape({ fill = theme.bg })
  local bar_row = bar:row({ height = BAR_HEIGHT })

  local left = bar_row:row({ flex = 1, height = BAR_HEIGHT, gap = 8, padding = { 0, 8, 0, 0 } })
  local workspace_cells = {}
  for index = 1, 9 do
    local cell = left:stack({ width = index == 1 and 30 or 1, height = BAR_HEIGHT, opacity = index == 1 and 1 or 0 })
    local background = cell:shape({ fill = index == 1 and theme.accent or CLEAR })
    local label = cell:column({ padding = { 9, 9, 0, 10 } }):text({
      text = tostring(index),
      font_size = 16,
      text_color = index == 1 and theme.bg or theme.text,
    })
    workspace_cells[index] = { cell = cell, background = background, label = label }
  end

  local minimap = left:row({ height = BAR_HEIGHT, gap = 2, padding = { 3, 6, 3, 6 } })
  local minimap_columns = {}
  for index = 1, 10 do
    local column = minimap:column({ width = 1, height = 32, gap = 2, opacity = 0 })
    local pieces = {}
    for leaf = 1, 4 do pieces[leaf] = column:shape({ width = 6, height = 5, fill = theme.overlay }) end
    minimap_columns[index] = { column = column, pieces = pieces }
  end

  local center = bar_row:row({ flex = 1, height = BAR_HEIGHT, gap = 7 })
  center:spacer({ flex = 1 })
  local app_label = center:text({ text = "", font_size = 14, text_color = theme.muted, padding = { 10, 0, 0, 0 } })
  local title_label = center:text({ text = "", font_size = 17, text_color = theme.text, padding = { 8, 0, 0, 0 } })
  center:spacer({ flex = 1 })

  local right = bar_row:row({ height = BAR_HEIGHT })

  local cpu = section(right, 112, theme.blend(theme.yellow))
  local update_cpu_spark = sparkline(cpu, theme.yellow)
  cpu:text({ text = "CPU", font_size = 12, text_color = theme.yellow, padding = { 11, 0, 0, 0 } })

  local network = section(right, 178, theme.blend(theme.cyan))
  local net_spark = network:row({ height = BAR_HEIGHT, gap = 1 })
  local rx_bars, tx_bars = {}, {}
  for index = 1, SPARK_COUNT do
    local pair = net_spark:column({ width = 2, height = BAR_HEIGHT })
    rx_bars[index] = pair:shape({ width = 2, height = 2, fill = theme.green })
    tx_bars[index] = pair:shape({ width = 2, height = 2, fill = theme.cyan })
  end
  local net_text = network:column({ gap = 1, padding = { 4, 0, 0, 0 } })
  local rx_label = net_text:text({ text = "rx 0B", font_size = 12, text_color = theme.green })
  local tx_label = net_text:text({ text = "tx 0B", font_size = 12, text_color = theme.cyan })

  local audio = section(right, 44, theme.blend(theme.purple))
  local update_audio = meter(audio, theme.purple, 0)
  local audio_label = audio:text({ text = "A", font_size = 14, text_color = theme.purple, padding = { 10, 0, 0, 0 } })

  local memory = section(right, 44, theme.blend(theme.green))
  local update_memory = meter(memory, theme.green, 0)
  memory:text({ text = "M", font_size = 14, text_color = theme.green, padding = { 10, 0, 0, 0 } })

  local disk = section(right, 44, theme.blend(theme.orange))
  local update_disk = meter(disk, theme.orange, 0)
  disk:text({ text = "D", font_size = 14, text_color = theme.orange, padding = { 10, 0, 0, 0 } })

  local battery_panel = right:stack({ width = 1, height = BAR_HEIGHT, opacity = 0 })
  battery_panel:shape({ fill = theme.blend(theme.red) })
  local battery = battery_panel:row({ padding = { 0, 9, 0, 5 }, gap = 6 })
  local update_battery = meter(battery, theme.red, 0)
  local battery_label = battery:text({ text = "B", font_size = 14, text_color = theme.red, padding = { 10, 0, 0, 0 } })

  local clock = section(right, 126, theme.blend(theme.blue))
  local clock_column = clock:column({ gap = 1, padding = { 3, 0, 0, 0 } })
  local clock_line = clock_column:row({ gap = 5 })
  local time_label = clock_line:text({ text = "--:--", font_size = 16, text_color = theme.bright })
  local dow_label = clock_line:text({ text = "---", font_size = 11, text_color = theme.text, padding = { 5, 0, 0, 0 } })
  local date_label = clock_column:text({ text = "---- -- --", font_size = 11, text_color = theme.muted })

  -- Volume OSD shares the full-output River shell instead of requiring a
  -- second native surface role. It remains transparent on portable bars.
  local osd_layer = root:column({ opacity = 0 })
  osd_layer:spacer({ height = 80 })
  local osd_row = osd_layer:row({ height = 120 })
  osd_row:spacer({ flex = 1 })
  local osd = osd_row:stack({ width = 320, height = 120 })
  osd:shape({ fill = theme.bg, radius = 12 })
  local osd_content = osd:column({ padding = { 20, 20, 20, 20 }, gap = 10 })
  osd_content:text({ text = "Volume", font_size = 14, text_color = theme.text })
  local osd_meter = osd_content:stack({ width = 280, height = 8 })
  osd_meter:shape({ fill = theme.surface, radius = 4 })
  local osd_fill = osd_meter:shape({ width = 2, height = 8, fill = theme.accent, radius = 4 })
  local osd_value = osd_content:text({ text = "0%", font_size = 22, text_color = theme.bright })
  osd_row:spacer({ flex = 1 })

  local function update_desktop(values)
    state.selected = math.floor(tonumber(values[1]) or state.selected)
    state.occupied = type(values[2]) == "table" and values[2] or state.occupied
    state.focused_output = values[3] ~= false
    state.app_id = tostring(values[4] or "")
    state.title = tostring(values[5] or "")
    state.columns = type(values[6]) == "table" and values[6] or {}

    for index, item in ipairs(workspace_cells) do
      local active = index == state.selected
      local visible = active or state.occupied[index] == true
      item.cell:set("width", visible and 30 or 1)
      item.cell:set("opacity", visible and 1 or 0)
      item.background:set("fill", active and theme.accent or CLEAR)
      item.label:set("text_color", active and theme.bg or theme.text)
    end
    for index, item in ipairs(minimap_columns) do
      local column = state.columns[index]
      if column then
        local width = math.max(4, math.min(28, math.floor((tonumber(column[1]) or 0.5) * 18)))
        local leaves = math.max(1, math.min(4, math.floor(tonumber(column[2]) or 1)))
        item.column:set("width", width)
        item.column:set("opacity", 1)
        for leaf, piece in ipairs(item.pieces) do
          piece:set("height", leaf <= leaves and math.max(2, math.floor((30 - 2 * (leaves - 1)) / leaves)) or 2)
          piece:set("opacity", leaf <= leaves and 1 or 0)
          piece:set("fill", column[3] and theme.accent or theme.overlay)
        end
      else
        item.column:set("width", 1)
        item.column:set("opacity", 0)
      end
    end
    local show_title = state.focused_output and state.title ~= ""
    title_label:set("text", show_title and state.title or "")
    app_label:set("text", show_title and state.app_id ~= state.title and state.app_id or "")
  end

  local function update_status()
    local now = status:update()
    update_cpu_spark(status.cpu.history)
    rx_label:set("text", "rx " .. Status.format_rate(status.network.rx))
    tx_label:set("text", "tx " .. Status.format_rate(status.network.tx))
    for index = 1, SPARK_COUNT do
      rx_bars[index]:set("height", math.max(2, math.floor(17 * (status.network.rx_history[index] or 0) + 0.5)))
      tx_bars[index]:set("height", math.max(2, math.floor(17 * (status.network.tx_history[index] or 0) + 0.5)))
    end
    local audio_color = status.audio.muted and theme.red or (status.audio.percent >= 100 and theme.yellow or theme.purple)
    update_audio(status.audio.percent, audio_color)
    audio_label:set("text", status.audio.muted and "X" or "A")
    audio_label:set("text_color", audio_color)
    update_memory(status.memory.percent)
    update_disk(status.disk.percent)
    if status.battery.present then
      local battery_color = status.battery.charging and theme.green
        or (status.battery.percent < 15 and theme.red or (status.battery.percent < 50 and theme.orange or theme.accent))
      battery_panel:set("width", 44)
      battery_panel:set("opacity", 1)
      update_battery(status.battery.percent, battery_color)
      battery_label:set("text", status.battery.charging and "+" or "B")
      battery_label:set("text_color", battery_color)
    else
      battery_panel:set("width", 1)
      battery_panel:set("opacity", 0)
    end
    time_label:set("text", status.clock.time)
    dow_label:set("text", status.clock.dow)
    date_label:set("text", status.clock.date)

    local visible = state.role == "shell" and Status.audio_visible(status, now)
    osd_layer:set("opacity", visible and 0.96 or 0)
    if visible then
      osd_fill:set("width", math.max(2, math.floor(2.8 * math.min(100, status.audio.percent))))
      osd_fill:set("fill", status.audio.muted and theme.red or audio_color)
      osd_value:set("text", status.audio.muted and (tostring(status.audio.percent) .. " (muted)") or (tostring(status.audio.percent) .. "%"))
    end
  end

  return {
    update = function(_, service, values)
      if service == "surface-role" then
        state.role = tostring(values[1] or "shell")
      elseif service == "desktop" then
        update_desktop(values)
      end
      if state.role == "shell" then update_status() end
    end,
  }
end

return build

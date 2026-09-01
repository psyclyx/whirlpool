-- Tidepool/Shoal behavior expressed as an ordinary Whirlpool retained tree.
-- The host provides desktop and asynchronously acquired status snapshots;
-- retained-tree policy remains identical for River and layer-shell roles.

local theme = require("whirlpool.theme")
local Status = require("whirlpool.status")

local BAR_HEIGHT = 38
local SPARK_COUNT = 15
local NETWORK_SAMPLE_COUNT = 16
local NETWORK_SAMPLE_MS = 500
local NETWORK_BAR_WIDTH = 2
local NETWORK_BAR_GAP = 1
local NETWORK_HALF_HEIGHT = BAR_HEIGHT / 2
local NETWORK_ZOOM_FLOOR = 128 * 1024
local NETWORK_HEADROOM = 0.78
local SLANT = 0.30
local CLEAR = { 0, 0, 0, 0 }

local function with_alpha(color, alpha)
  return { color[1], color[2], color[3], alpha }
end

-- The motif is Lua policy. Whirlpool only supplies box-relative polygons;
-- this helper chooses a constant physical slope and permits the top edge to
-- extend into the following panel so adjacent sections share one diagonal.
local function angled_points(width, height, slant)
  local shift = (slant or SLANT) * height / math.max(1, width)
  return { { shift, 0 }, { 1 + shift, 0 }, { 1, 1 }, { 0, 1 } }
end

local function angled_shape(parent, width, height, color)
  return parent:polygon({ fill = color, points = angled_points(width, height) })
end

local function resize_angled(node, width, height)
  node:set("width", width)
  node:set("height", height)
  node:set("points", angled_points(width, height))
end

local function visual_center_shift(height)
  return SLANT * height * 0.5
end

local function ellipsis(text, limit)
  text = tostring(text or "")
  local byte_length = #text
  local byte_index = 1
  local characters = 0
  local function continuation(index)
    local byte = string.byte(text, index)
    return byte and byte >= 0x80 and byte <= 0xbf
  end
  while byte_index <= byte_length and characters < limit do
    local byte = string.byte(text, byte_index)
    local width = 1
    if byte >= 0xc2 and byte <= 0xdf and continuation(byte_index + 1) then
      width = 2
    elseif byte >= 0xe0 and byte <= 0xef
      and continuation(byte_index + 1) and continuation(byte_index + 2) then
      width = 3
    elseif byte >= 0xf0 and byte <= 0xf4
      and continuation(byte_index + 1) and continuation(byte_index + 2) and continuation(byte_index + 3) then
      width = 4
    end
    byte_index = byte_index + width
    characters = characters + 1
  end
  if byte_index > byte_length then return text end
  return string.sub(text, 1, byte_index - 1) .. "…"
end

local function meter(parent, color, initial)
  local column = parent:column({ width = 8, height = BAR_HEIGHT })
  column:spacer({ flex = 1 })
  local fill = column:polygon({
    width = 8, height = 2, fill = color, points = angled_points(8, 2),
  })
  local function update(percent, next_color)
    local height = math.max(2, math.floor(BAR_HEIGHT * math.min(100, math.max(0, percent or 0)) / 100 + 0.5))
    resize_angled(fill, 8, height)
    if next_color then fill:set("fill", next_color) end
  end
  update(initial or 0)
  return update
end

local function section(parent, width, background)
  local panel = parent:stack({ width = width, height = BAR_HEIGHT })
  angled_shape(panel, width, BAR_HEIGHT, background)
  return panel:row({ padding = { 0, 12, 0, 2 }, gap = 8, offset_x = visual_center_shift(BAR_HEIGHT) })
end

local function sparkline(parent, color)
  local row = parent:row({ height = BAR_HEIGHT, gap = 2 })
  local bars = {}
  for index = 1, SPARK_COUNT do
    local column = row:column({ width = 3, height = BAR_HEIGHT })
    column:spacer({ flex = 1 })
    bars[index] = column:polygon({
      width = 3, height = 2, fill = color, points = angled_points(3, 2),
    })
  end
  return function(values)
    for index, bar in ipairs(bars) do
      local value = values[index] or 0
      local height = math.max(2, math.floor((BAR_HEIGHT - 2) * math.min(1, math.max(0, value)) + 0.5))
      resize_angled(bar, 3, height)
    end
  end
end

local function build(parent)
  local state = {
    role = "shell",
    selected = 1,
    occupied = {},
    items = {},
    item_count = 0,
    frame_ms = 0,
    network_sample_ms = 0,
    network_sequence = 0,
    network_rx = {},
    network_tx = {},
    network_zoom = NETWORK_ZOOM_FLOOR,
    network_zoom_target = NETWORK_ZOOM_FLOOR,
  }

  local root = parent:stack()

  -- Full-output River shell: the flexible spacer pins the bar to the bottom.
  -- A 38px portable layer surface naturally collapses that spacer to zero.
  local shell = root:column()
  shell:spacer({ flex = 1 })
  local bar_layer = shell:stack({ height = BAR_HEIGHT })
  bar_layer:shape({ fill = theme.bg })
  local bar = bar_layer:row({ height = BAR_HEIGHT })

  local workspaces = bar:row({ height = BAR_HEIGHT, gap = 8, padding = { 0, 8, 0, 0 } })
  local workspace_cells = {}
  for index = 1, 9 do
    local cell = workspaces:stack({ width = index == 1 and 30 or 1, height = BAR_HEIGHT, opacity = index == 1 and 1 or 0 })
    local background = angled_shape(cell, 30, BAR_HEIGHT, index == 1 and theme.accent or CLEAR)
    local label = cell:column({
      padding = { 9, 9, 0, 10 }, offset_x = visual_center_shift(BAR_HEIGHT),
    }):text({
      text = tostring(index),
      font_size = 16,
      text_color = index == 1 and theme.bg or theme.text,
    })
    workspace_cells[index] = { cell = cell, background = background, label = label }
  end

  local strip = bar:stack({ height = BAR_HEIGHT, flex = 1, clip = true })
  local strip_content = strip:stack({ width = 1, height = BAR_HEIGHT })
  local window_layer = strip_content:stack({ height = BAR_HEIGHT })
  local marker_layer = strip_content:stack({ height = BAR_HEIGHT })
  local display_items = {}
  local function create_display_item()
    local cell = window_layer:stack({ width = 1, height = BAR_HEIGHT, opacity = 0 })
    local background = cell:polygon({ fill = CLEAR, points = angled_points(1, BAR_HEIGHT) })
    local window = cell:row({
      gap = 6, padding = { 7, 9, 7, 7 },
      offset_x = visual_center_shift(BAR_HEIGHT),
    })
    local mark = window:text({ text = "", width = 1, font_size = 11, text_color = theme.accent, opacity = 0 })
    local icon = window:icon({ icon_source = "", width = 20, height = 20 })
    local labels = window:column({ gap = 1 })
    local app_id = labels:text({ text = "", height = 12, font_size = 11, text_color = theme.text })
    local title = labels:text({ text = "", height = 10, font_size = 9, text_color = theme.muted })
    local marker = marker_layer:stack({ width = 3, height = BAR_HEIGHT, opacity = 0 })
    local marker_column = marker:column({ width = 3, height = BAR_HEIGHT })
    marker_column:spacer({ flex = 1 })
    local marker_line = marker_column:polygon({
      width = 3, height = 24, fill = theme.blue, points = angled_points(3, 24),
    })
    marker_column:spacer({ flex = 1 })
    display_items[#display_items + 1] = {
      cell = cell,
      background = background,
      window = window,
      mark = mark,
      icon = icon,
      app_id = app_id,
      title = title,
      marker = marker,
      marker_line = marker_line,
    }
  end

  local left_fade = strip:stack({ width = 1, height = BAR_HEIGHT, opacity = 0, clip = true })
  local left_gradient = left_fade:row({ width = 24, height = BAR_HEIGHT })
  local right_fade = strip:row({ height = BAR_HEIGHT })
  right_fade:spacer({ flex = 1 })
  local right_clip = right_fade:stack({ width = 1, height = BAR_HEIGHT, opacity = 0, clip = true })
  local right_gradient = right_clip:row({ width = 24, height = BAR_HEIGHT, offset_x = -23 })
  for index = 1, 8 do
    left_gradient:shape({ width = 3, height = BAR_HEIGHT, fill = with_alpha(theme.bg, (9 - index) / 8) })
    right_gradient:shape({ width = 3, height = BAR_HEIGHT, fill = with_alpha(theme.bg, index / 8) })
  end

  local right = bar:row({ height = BAR_HEIGHT })

  local cpu = section(right, 112, theme.blend(theme.yellow))
  local update_cpu_spark = sparkline(cpu, theme.yellow)
  cpu:text({ text = "CPU", font_size = 12, text_color = theme.yellow, padding = { 11, 0, 0, 0 } })

  local network = section(right, 178, theme.blend(theme.cyan))
  local network_view_width = SPARK_COUNT * NETWORK_BAR_WIDTH + (SPARK_COUNT - 1) * NETWORK_BAR_GAP
  local network_content_width = NETWORK_SAMPLE_COUNT * NETWORK_BAR_WIDTH
    + (NETWORK_SAMPLE_COUNT - 1) * NETWORK_BAR_GAP
  local net_spark = network:stack({ width = network_view_width, height = BAR_HEIGHT, clip = true })
  local net_content = net_spark:row({ width = network_content_width, height = BAR_HEIGHT, gap = NETWORK_BAR_GAP })
  local rx_bars, tx_bars = {}, {}
  for index = 1, NETWORK_SAMPLE_COUNT do
    local pair = net_content:column({ width = NETWORK_BAR_WIDTH, height = BAR_HEIGHT })
    local upper = pair:column({ width = NETWORK_BAR_WIDTH, height = NETWORK_HALF_HEIGHT })
    upper:spacer({ flex = 1 })
    rx_bars[index] = upper:polygon({
      width = NETWORK_BAR_WIDTH, height = 1, fill = theme.green,
      points = angled_points(NETWORK_BAR_WIDTH, 1), opacity = 0,
    })
    local lower = pair:column({ width = NETWORK_BAR_WIDTH, height = NETWORK_HALF_HEIGHT })
    tx_bars[index] = lower:polygon({
      width = NETWORK_BAR_WIDTH, height = 1, fill = theme.cyan,
      points = angled_points(NETWORK_BAR_WIDTH, 1), opacity = 0,
    })
    lower:spacer({ flex = 1 })
  end
  local net_text = network:column({ gap = 1, padding = { 4, 0, 0, 0 } })
  local rx_label = net_text:text({ text = "rx 0B", font_size = 12, text_color = theme.green })
  local tx_label = net_text:text({ text = "tx 0B", font_size = 12, text_color = theme.cyan })

  local function draw_network(now_ms)
    now_ms = math.max(state.frame_ms, tonumber(now_ms) or 0)
    local elapsed = math.max(0, now_ms - state.frame_ms)
    state.frame_ms = now_ms
    local tau = state.network_zoom_target > state.network_zoom and 800 or 6000
    local blend = elapsed > 0 and (1 - math.exp(-elapsed / tau)) or 0
    state.network_zoom = state.network_zoom
      + (state.network_zoom_target - state.network_zoom) * blend
    local progress = math.max(0, math.min(0.99,
      (now_ms - state.network_sample_ms) / NETWORK_SAMPLE_MS))
    net_content:set("offset_x", -(NETWORK_BAR_WIDTH + NETWORK_BAR_GAP) * progress)
    for index = 1, NETWORK_SAMPLE_COUNT do
      local rx = math.max(0, tonumber(state.network_rx[index]) or 0)
      local tx = math.max(0, tonumber(state.network_tx[index]) or 0)
      local rx_height = math.max(1, math.floor(NETWORK_HALF_HEIGHT * math.min(1, rx / state.network_zoom) + 0.5))
      local tx_height = math.max(1, math.floor(NETWORK_HALF_HEIGHT * math.min(1, tx / state.network_zoom) + 0.5))
      local edge_opacity = index == 1 and (1 - progress)
        or index == NETWORK_SAMPLE_COUNT and progress
        or 1
      resize_angled(rx_bars[index], NETWORK_BAR_WIDTH, rx_height)
      resize_angled(tx_bars[index], NETWORK_BAR_WIDTH, tx_height)
      rx_bars[index]:set("opacity", rx > 0 and edge_opacity or 0)
      tx_bars[index]:set("opacity", tx > 0 and edge_opacity or 0)
    end
  end

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
  angled_shape(battery_panel, 44, BAR_HEIGHT, theme.blend(theme.red))
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
    state.items = type(values[3]) == "table" and values[3] or {}
    while #display_items < #state.items do create_display_item() end

    for index, item in ipairs(workspace_cells) do
      local active = index == state.selected
      local visible = active or state.occupied[index] == true
      item.cell:set("width", visible and 30 or 1)
      item.cell:set("opacity", visible and 1 or 0)
      item.background:set("fill", active and theme.accent or CLEAR)
      item.label:set("text_color", active and theme.bg or theme.text)
    end
    for index = 1, math.max(state.item_count, #state.items) do
      local view = display_items[index]
      local item = state.items[index]
      if item then
        local style = tostring(item[1] or "")
        local is_window = style == "window"
        local is_insertion = style == "insertion"
        local is_group = style == "group-open" or style == "group-close"
        local focused = item[5] == true
        local group_kind = tostring(item[2] or "")
        local detail = tostring(item[8] or "")
        local marked = detail ~= ""
        local app_id = tostring(item[3] or "")
        local title = tostring(item[4] or "")
        local x = tonumber(item[9]) or 0
        local width = math.max(1, math.floor(tonumber(item[6]) or 1))
        view.cell:set("width", width)
        view.cell:set("offset_x", x)
        view.cell:set("opacity", is_window and 1 or 0)
        resize_angled(view.background, width, BAR_HEIGHT)
        view.background:set("fill", focused and theme.blend(theme.accent, 112)
          or theme.blend(theme.surface, 96))
        local app_limit = math.max(4, math.floor((width - 58) / 7))
        local title_limit = math.max(5, math.floor((width - 58) / 6))
        view.icon:set("icon_source", is_window and tostring(item[7] or "") or "")
        view.mark:set("text", detail)
        view.mark:set("width", marked and math.max(10, #detail * 7) or 1)
        view.mark:set("opacity", marked and 1 or 0)
        view.app_id:set("text", is_window and ellipsis(app_id, app_limit) or "")
        view.app_id:set("text_color", focused and theme.bright or theme.text)
        view.title:set("text", is_window and ellipsis(title, title_limit) or "")
        view.title:set("text_color", focused and theme.text or theme.muted)
        view.marker:set("offset_x", x - 1.5)
        view.marker:set("opacity", (is_insertion or is_group) and 1 or 0)
        local marker_height = is_insertion and 34 or 24
        resize_angled(view.marker_line, 3, marker_height)
        view.marker_line:set("fill", is_insertion and theme.accent
          or marked and theme.purple
          or focused and theme.bright
          or group_kind == "float" and theme.purple
          or group_kind == "full" and theme.orange
          or group_kind == "scratch" and theme.cyan
          or group_kind == "t" and theme.purple
          or group_kind == "v" and theme.cyan
          or style == "group-open" and theme.blue
          or theme.muted)
      else
        view.cell:set("width", 1)
        view.cell:set("opacity", 0)
        view.marker:set("opacity", 0)
      end
    end
    state.item_count = #state.items
    strip_content:set("width", math.max(1, math.floor(tonumber(values[5]) or 1)))
    strip_content:set("offset_x", -math.max(0, math.floor(tonumber(values[4]) or 0)))
    local left_cut = math.max(0, math.min(24, math.floor(tonumber(values[6]) or 0)))
    local right_cut = math.max(0, math.min(24, math.floor(tonumber(values[7]) or 0)))
    left_fade:set("width", math.max(1, left_cut))
    left_fade:set("opacity", left_cut > 0 and 1 or 0)
    right_clip:set("width", math.max(1, right_cut))
    right_clip:set("opacity", right_cut > 0 and 1 or 0)
    right_gradient:set("offset_x", right_cut - 24)
  end

  local function update_status(values)
    local cpu_history = type(values[5]) == "table" and values[5] or {}
    local rx_history = type(values[10]) == "table" and values[10] or {}
    local tx_history = type(values[11]) == "table" and values[11] or {}
    local network_sequence = math.floor(tonumber(values[18]) or 0)
    local audio_percent = tonumber(values[12]) or 0
    local audio_muted = values[13] == true
    local battery_present = values[15] == true
    local battery_percent = tonumber(values[16]) or 0
    local battery_charging = values[17] == true

    update_cpu_spark(cpu_history)
    rx_label:set("text", "rx " .. Status.format_rate(values[8]))
    tx_label:set("text", "tx " .. Status.format_rate(values[9]))
    if network_sequence ~= state.network_sequence then
      state.network_sequence = network_sequence
      state.network_sample_ms = state.frame_ms
      state.network_rx = rx_history
      state.network_tx = tx_history
      local peak = NETWORK_ZOOM_FLOOR
      for index = 1, NETWORK_SAMPLE_COUNT do
        peak = math.max(peak, tonumber(rx_history[index]) or 0, tonumber(tx_history[index]) or 0)
      end
      state.network_zoom_target = math.max(NETWORK_ZOOM_FLOOR, peak / NETWORK_HEADROOM)
    end
    draw_network(state.frame_ms)
    local audio_color = audio_muted and theme.red or (audio_percent >= 100 and theme.yellow or theme.purple)
    update_audio(audio_percent, audio_color)
    audio_label:set("text", audio_muted and "X" or "A")
    audio_label:set("text_color", audio_color)
    update_memory(tonumber(values[6]) or 0)
    update_disk(tonumber(values[7]) or 0)
    if battery_present then
      local battery_color = battery_charging and theme.green
        or (battery_percent < 15 and theme.red or (battery_percent < 50 and theme.orange or theme.accent))
      battery_panel:set("width", 44)
      battery_panel:set("opacity", 1)
      update_battery(battery_percent, battery_color)
      battery_label:set("text", battery_charging and "+" or "B")
      battery_label:set("text_color", battery_color)
    else
      battery_panel:set("width", 1)
      battery_panel:set("opacity", 0)
    end
    time_label:set("text", tostring(values[1] or "--:--"))
    dow_label:set("text", tostring(values[2] or "---"))
    date_label:set("text", tostring(values[3] or "----------"))

    local visible = state.role == "shell" and values[14] == true
    osd_layer:set("opacity", visible and 0.96 or 0)
    if visible then
      osd_fill:set("width", math.max(2, math.floor(2.8 * math.min(100, audio_percent))))
      osd_fill:set("fill", audio_muted and theme.red or audio_color)
      osd_value:set("text", audio_muted and (tostring(audio_percent) .. " (muted)") or (tostring(audio_percent) .. "%"))
    end
  end

  return {
    update = function(_, service, values)
      if service == "surface-role" then
        state.role = tostring(values[1] or "shell")
      elseif service == "desktop" then
        update_desktop(values)
      elseif service == "status" then
        update_status(values)
      elseif service == "frame" then
        draw_network(tonumber(values[1]) or state.frame_ms)
      end
    end,
  }
end

return build

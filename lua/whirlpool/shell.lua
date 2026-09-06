-- Tidepool/Shoal behavior expressed as an ordinary Whirlpool retained tree.
-- The host provides desktop and asynchronously acquired status snapshots;
-- retained-tree policy remains identical for River and layer-shell roles.

local theme = require("whirlpool.theme")
local Status = require("whirlpool.status")

local BAR_HEIGHT = 38
local CPU_HISTORY_COUNT = 24
local CPU_SAMPLE_MS = 500
local CPU_CORE_DISPLAY_COUNT = 16
local CPU_CORE_COLUMNS = 8
local CPU_CORE_CELL_WIDTH = 3
local CPU_CORE_CELL_GAP = 2
local NETWORK_SAMPLE_COUNT = 24
local NETWORK_SAMPLE_MS = 500
local NETWORK_HALF_HEIGHT = BAR_HEIGHT / 2
local NETWORK_FALLBACK_CAPACITY = 125 * 1000 * 1000
local HISTORY_SAMPLE_WIDTH = 4
local ENVELOPE_POINTS_PER_CHUNK = 14
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

-- A filled envelope reads as one signal at 1x instead of a row of tiny,
-- unrelated needles. Chunks only exist because retained polygons have a
-- deliberately small vertex cap; opaque chunks meet at the same sample.
local function history_envelope(parent, sample_count, height, color)
  local content_width = (sample_count - 1) * HISTORY_SAMPLE_WIDTH
  local view_width = (sample_count - 2) * HISTORY_SAMPLE_WIDTH
  local view = parent:stack({ width = view_width, height = height, clip = true })
  local content = view:stack({ width = content_width, height = height })
  local chunks = {}
  local first = 1
  while first < sample_count do
    local last = math.min(sample_count, first + ENVELOPE_POINTS_PER_CHUNK - 1)
    local x1 = (first - 1) / (sample_count - 1)
    local x2 = (last - 1) / (sample_count - 1)
    chunks[#chunks + 1] = {
      first = first,
      last = last,
      node = content:polygon({
        width = content_width,
        height = height,
        fill = color,
        points = { { x1, 1 }, { x1, 1 }, { x2, 1 } },
      }),
    }
    if last == sample_count then break end
    -- Overlap one full segment so the antialiased closing edge is painted
    -- over identical fill instead of showing as a hairline seam at 1x.
    first = last - 1
  end
  return { content = content, chunks = chunks, sample_count = sample_count }
end

local function update_envelope(envelope, values, fraction, lower)
  local baseline = lower and 0 or 1
  for _, chunk in ipairs(envelope.chunks) do
    local points = { { (chunk.first - 1) / (envelope.sample_count - 1), baseline } }
    for index = chunk.first, chunk.last do
      local level = math.min(1, math.max(0, fraction(values[index] or 0)))
      points[#points + 1] = {
        (index - 1) / (envelope.sample_count - 1),
        lower and level or (1 - level),
      }
    end
    points[#points + 1] = { (chunk.last - 1) / (envelope.sample_count - 1), baseline }
    chunk.node:set("points", points)
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
    cpu_sample_ms = 0,
    cpu_sequence = -1,
    cpu_count = 1,
    cpu_history = {},
    cpu_core_levels = {},
    cpu_core_targets = {},
    network_sequence = -1,
    network_rx = {},
    network_tx = {},
    network_capacity = NETWORK_FALLBACK_CAPACITY,
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

  -- CPU history is expressed in busy-core equivalents on a fixed logarithmic
  -- scale. On a 32-thread machine, one saturated core therefore remains
  -- visible instead of collapsing to a misleading 3% sliver.
  local cpu = section(right, 205, theme.blend(theme.yellow))
  local cpu_history_envelope = history_envelope(
    cpu, CPU_HISTORY_COUNT, BAR_HEIGHT, theme.blend(theme.yellow, 220))

  -- The heat field shows the hottest sixteen logical cores, sorted by load.
  -- One bright cell means single-thread saturation; a filled field means
  -- genuinely parallel work, independent of the machine's total core count.
  local cpu_core_field_width = CPU_CORE_COLUMNS * CPU_CORE_CELL_WIDTH
    + (CPU_CORE_COLUMNS - 1) * CPU_CORE_CELL_GAP
  local cpu_core_field = cpu:column({ width = cpu_core_field_width, height = BAR_HEIGHT, gap = 2, padding = { 9, 0, 9, 0 } })
  local cpu_core_cells = {}
  for row_index = 1, 2 do
    local row = cpu_core_field:row({ width = cpu_core_field_width, height = 8, gap = CPU_CORE_CELL_GAP })
    for column_index = 1, CPU_CORE_COLUMNS do
      local index = (row_index - 1) * CPU_CORE_COLUMNS + column_index
      cpu_core_cells[index] = row:shape({
        width = CPU_CORE_CELL_WIDTH, height = 8, radius = 1,
        fill = theme.yellow, opacity = 0.10,
      })
      state.cpu_core_levels[index] = 0
      state.cpu_core_targets[index] = 0
    end
  end
  local cpu_text = cpu:column({ gap = 1, padding = { 4, 0, 0, 0 } })
  local cpu_total_label = cpu_text:text({ text = "0.0c", font_size = 12, text_color = theme.yellow })
  local cpu_peak_label = cpu_text:text({ text = "0% · 1", font_size = 9, text_color = theme.muted })

  local network = section(right, 190, theme.blend(theme.cyan))
  local net_graph = network:column({ height = BAR_HEIGHT })
  local rx_envelope = history_envelope(
    net_graph, NETWORK_SAMPLE_COUNT, NETWORK_HALF_HEIGHT, theme.blend(theme.green, 220))
  local tx_envelope = history_envelope(
    net_graph, NETWORK_SAMPLE_COUNT, NETWORK_HALF_HEIGHT, theme.blend(theme.cyan, 220))
  local net_text = network:column({ gap = 1, padding = { 4, 0, 0, 0 } })
  local rx_label = net_text:text({ text = "↓ 0B", font_size = 12, text_color = theme.green })
  local tx_label = net_text:text({ text = "↑ 0B", font_size = 12, text_color = theme.cyan })

  local function logarithmic_fraction(value, ceiling)
    value = math.max(0, tonumber(value) or 0)
    ceiling = math.max(1, tonumber(ceiling) or 1)
    return math.min(1, math.log(1 + value) / math.log(1 + ceiling))
  end

  local function draw_cpu(now_ms, elapsed)
    local blend = elapsed > 0 and (1 - math.exp(-elapsed / 140)) or 0
    for index = 1, CPU_CORE_DISPLAY_COUNT do
      local level = state.cpu_core_levels[index]
        + (state.cpu_core_targets[index] - state.cpu_core_levels[index]) * blend
      state.cpu_core_levels[index] = level
      cpu_core_cells[index]:set("opacity", 0.10 + 0.90 * math.min(1, math.max(0, level)))
    end
    local progress = math.max(0, math.min(0.99,
      (now_ms - state.cpu_sample_ms) / CPU_SAMPLE_MS))
    cpu_history_envelope.content:set("offset_x", -HISTORY_SAMPLE_WIDTH * progress)
  end

  local function draw_network(now_ms)
    local progress = math.max(0, math.min(0.99,
      (now_ms - state.network_sample_ms) / NETWORK_SAMPLE_MS))
    local offset = -HISTORY_SAMPLE_WIDTH * progress
    rx_envelope.content:set("offset_x", offset)
    tx_envelope.content:set("offset_x", offset)
  end

  local function draw_frame(now_ms)
    now_ms = math.max(state.frame_ms, tonumber(now_ms) or 0)
    local elapsed = math.max(0, now_ms - state.frame_ms)
    state.frame_ms = now_ms
    draw_cpu(now_ms, elapsed)
    draw_network(now_ms)
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
    local cpu_count = math.max(1, math.floor(tonumber(values[19]) or 1))
    local cpu_equivalents = math.max(0, tonumber(values[20])
      or ((tonumber(values[4]) or 0) * cpu_count / 100))
    local cpu_cores = type(values[21]) == "table" and values[21] or { tonumber(values[4]) or 0 }
    local cpu_sequence = math.floor(tonumber(values[22]) or 0)
    local rx_history = type(values[10]) == "table" and values[10] or {}
    local tx_history = type(values[11]) == "table" and values[11] or {}
    local network_sequence = math.floor(tonumber(values[18]) or 0)
    local audio_percent = tonumber(values[12]) or 0
    local audio_muted = values[13] == true
    local battery_present = values[15] == true
    local battery_percent = tonumber(values[16]) or 0
    local battery_charging = values[17] == true

    if cpu_sequence ~= state.cpu_sequence then
      state.cpu_sequence = cpu_sequence
      state.cpu_sample_ms = state.frame_ms
      state.cpu_count = cpu_count
      state.cpu_history = cpu_history
      update_envelope(cpu_history_envelope, cpu_history,
        function(value) return logarithmic_fraction(value, cpu_count) end, false)
      local sorted = {}
      for index = 1, #cpu_cores do sorted[index] = math.max(0, tonumber(cpu_cores[index]) or 0) end
      table.sort(sorted, function(left, right) return left > right end)
      for index = 1, CPU_CORE_DISPLAY_COUNT do
        state.cpu_core_targets[index] = math.min(1, (sorted[index] or 0) / 100)
      end
      local peak = sorted[1] or 0
      cpu_total_label:set("text", string.format("%.1fc", cpu_equivalents))
      cpu_peak_label:set("text", string.format("%.0f%% · %d", peak, cpu_count))
    end
    rx_label:set("text", "↓ " .. Status.format_rate(values[8]))
    tx_label:set("text", "↑ " .. Status.format_rate(values[9]))
    state.network_capacity = math.max(1, tonumber(values[23]) or NETWORK_FALLBACK_CAPACITY)
    if network_sequence ~= state.network_sequence then
      state.network_sequence = network_sequence
      state.network_sample_ms = state.frame_ms
      state.network_rx = rx_history
      state.network_tx = tx_history
      update_envelope(rx_envelope, rx_history,
        function(value) return logarithmic_fraction(value, state.network_capacity) end, false)
      update_envelope(tx_envelope, tx_history,
        function(value) return logarithmic_fraction(value, state.network_capacity) end, true)
    end
    draw_frame(state.frame_ms)
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
        draw_frame(tonumber(values[1]) or state.frame_ms)
      end
    end,
  }
end

return build

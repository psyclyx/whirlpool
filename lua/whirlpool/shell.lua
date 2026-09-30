-- Tidepool/Shoal behavior expressed as an ordinary Whirlpool retained tree.
-- The host provides desktop and asynchronously acquired status snapshots;
-- retained-tree policy remains identical for River and layer-shell roles.
--
-- Layout vocabulary: `whirlpool.angled` supplies slanted panels whose cells
-- expose an inscribed rectangle, so text and icons are simply placed and
-- aligned inside them; `whirlpool.graph` draws history plots that follow the
-- slant.
--
-- Units: memory and disk sizes are binary (GiB/TiB, shown as G/T, as htop, df
-- and zfs do); network throughput is bits per second (Mb/s, the unit link
-- speeds and speed tests use); disk throughput is bytes per second (MB/s).

local theme = require("whirlpool.theme")
local Status = require("whirlpool.status")
local Angled = require("whirlpool.angled")
local Graph = require("whirlpool.graph")

local BAR_HEIGHT = 38
local CPU_HISTORY_COUNT = 24
local CPU_SAMPLE_MS = 500
local CPU_CORE_DISPLAY_COUNT = 16
local CPU_CORE_COLUMNS = 8
local NETWORK_SAMPLE_COUNT = 24
local NETWORK_SAMPLE_MS = 500
-- Below this the chart stays flat instead of magnifying idle noise.
local NETWORK_SCALE_FLOOR = 64 * 1024
local NETWORK_SCALE_DECAY_MS = 2500
local RATE_READOUT_MS = 1000
local FRAME_TICK_MS = 100
local MAX_DISK_CHIPS = 5
-- Alternative history plots, drawn beside the real ones so the styles can be
-- compared on live data. Set to false once one is chosen.
local SHOWCASE_CHARTS = true
local CLEAR = { 0, 0, 0, 0 }

local function with_alpha(color, alpha)
  return { color[1], color[2], color[3], alpha }
end

-- Secondary text on the coloured panels: theme.muted is too dark against them.
local DIM = with_alpha(theme.text, 0.62)

local function rectangle(u, v, width, height)
  return { { u, v }, { u + width, v }, { u + width, v + height }, { u, v + height } }
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

local function clamp01(value)
  return math.min(1, math.max(0, value))
end

-- A vertical level indicator drawn flush against the left edge of its cell:
-- a dim track with the value filled from the bottom. `bands` stacks several
-- segments (bottom first) for values with more than one part.
local function level_bar(cell, spec)
  local u, width = spec.u or 0, spec.width or 8
  local height = cell.height
  local track = cell:polygon({ fill = with_alpha(spec.color, 0.16), points = rectangle(u, 0, width, height) })
  local bands = {}
  for index = 1, spec.bands or 1 do
    bands[index] = cell:polygon({ fill = spec.color, points = rectangle(u, height - 1, width, 1) })
  end
  track:set("opacity", spec.track == false and 0 or 1)
  return function(parts)
    local filled = 0
    for index, band in ipairs(bands) do
      local part = parts[index] or { 0, spec.color }
      local rows = math.floor(height * clamp01(part[1]) + 0.5)
      if part[1] > 0 then rows = math.max(1, rows) end
      rows = math.min(rows, height - filled)
      cell:set_polygon(band, rectangle(u, height - filled - math.max(rows, 0), width, math.max(rows, 0.01)))
      band:set("fill", part[2])
      band:set("opacity", rows > 0 and 1 or 0)
      filled = filled + rows
    end
  end
end

local function text_cell(cell, lines, options)
  options = options or {}
  local column = cell.body:column({ gap = options.gap or 1 })
  column:spacer({ flex = 1 })
  local nodes = {}
  for index, line in ipairs(lines) do
    nodes[index] = column:text({
      text = line.text or "",
      font_size = line.size,
      height = line.height or line.size,
      text_color = line.color,
      text_align = line.align or options.align or "start",
      text_valign = "middle",
    })
  end
  column:spacer({ flex = 1 })
  return nodes
end

-- A throughput readout with a fixed shape: label, number, unit. The number is
-- right-aligned in its own slot and the unit sits in another, so the unit
-- never moves and only the digits change. The figure is held until it has
-- moved by more than a tenth (or the unit changes), and is re-read at most
-- once a second, so the display reads as a steady value rather than shimmering.
--   spec.parts(value) -> number text, unit text
local function rate_slots(row, spec)
  local size = spec.size or 12
  local function slot(text, width, align)
    return row:text({
      text = text, width = width, height = spec.height or 13, font_size = size, text_color = spec.color,
      text_align = align, text_valign = "middle",
    })
  end
  if spec.label then slot(spec.label, spec.label_width or 12, "start") end
  local number = slot("0", spec.number_width or 26, "end")
  -- `merged` puts number and unit in one right-aligned slot ("4.0M"): the unit
  -- is then always at the slot's right edge, which keeps it fixed in less room.
  local unit = not spec.merged and slot("", spec.unit_width or 32, "start") or nil
  local shown, shown_ms = nil, -RATE_READOUT_MS
  return function(value, now_ms)
    value = math.max(0, tonumber(value) or 0)
    if now_ms - shown_ms < RATE_READOUT_MS then return end
    shown_ms = now_ms
    if shown and math.abs(value - shown) <= 0.1 * math.max(value, shown) then return end
    shown = value
    local number_text, unit_text = spec.parts(value)
    if unit then
      number:set("text", number_text)
      unit:set("text", unit_text)
    else
      number:set("text", number_text .. unit_text)
    end
  end
end

local function rate_readouts(cell, specs)
  local column = cell.body:column({ gap = 1 })
  column:spacer({ flex = 1 })
  local updaters = {}
  for index, spec in ipairs(specs) do
    updaters[index] = rate_slots(column:row({ height = spec.height or 13 }), spec)
  end
  column:spacer({ flex = 1 })
  return function(index, value, now_ms) updaters[index](value, now_ms) end
end

-- Hand-drawn glyphs. Coordinates are rectangular drawing space; the cell
-- shears them so they lean with the panel.
local function speaker_icon(cell, u, v, color)
  local body = cell:polygon({ fill = color, points = {
    { u, v + 4 }, { u + 4, v + 4 }, { u + 8, v }, { u + 8, v + 14 }, { u + 4, v + 10 }, { u, v + 10 },
  } })
  local near = cell:polygon({ fill = color, points = rectangle(u + 10, v + 4, 1.6, 6) })
  local far = cell:polygon({ fill = color, points = rectangle(u + 13, v + 1, 1.6, 12) })
  local cross_a = cell:polygon({ fill = color, points = {
    { u + 10, v + 4 }, { u + 11.6, v + 4 }, { u + 14.6, v + 10 }, { u + 13, v + 10 },
  } })
  local cross_b = cell:polygon({ fill = color, points = {
    { u + 13, v + 4 }, { u + 14.6, v + 4 }, { u + 11.6, v + 10 }, { u + 10, v + 10 },
  } })
  return function(percent, muted, tint)
    for _, node in ipairs({ body, near, far, cross_a, cross_b }) do node:set("fill", tint) end
    near:set("opacity", muted and 0 or (percent > 0 and 1 or 0.3))
    far:set("opacity", muted and 0 or (percent > 45 and 1 or 0.3))
    cross_a:set("opacity", muted and 1 or 0)
    cross_b:set("opacity", muted and 1 or 0)
  end
end

local function chip_icon(cell, u, v, color)
  cell:polygon({ fill = color, points = rectangle(u + 2, v + 2, 8, 8) })
  for _, y in ipairs({ 3, 7 }) do
    cell:polygon({ fill = color, points = rectangle(u, v + y, 2, 1.6) })
    cell:polygon({ fill = color, points = rectangle(u + 10, v + y, 2, 1.6) })
  end
  for _, x in ipairs({ 3.2, 6.8 }) do
    cell:polygon({ fill = color, points = rectangle(u + x, v, 1.6, 2) })
    cell:polygon({ fill = color, points = rectangle(u + x, v + 10, 1.6, 2) })
  end
end

local function disk_icon(cell, u, v, color)
  cell:polygon({ fill = with_alpha(color, 0.55), points = rectangle(u, v + 3, 14, 8) })
  cell:polygon({ fill = color, points = rectangle(u + 9, v + 6, 3, 2) })
end

local function battery_icon(cell, u, v, color)
  cell:polygon({ fill = with_alpha(color, 0.30), points = rectangle(u, v + 2, 12, 10) })
  cell:polygon({ fill = color, points = rectangle(u + 12, v + 5, 2, 4) })
  local fill = cell:polygon({ fill = color, points = rectangle(u + 1, v + 3, 1, 8) })
  return function(fraction, tint)
    cell:set_polygon(fill, rectangle(u + 1, v + 3, math.max(0.5, 10 * clamp01(fraction)), 8))
    fill:set("fill", tint)
  end
end

-- Swap is unremarkable until it is actually being used.
local function swap_color(used, total)
  if total <= 0 or used <= 0 then return DIM end
  local fraction = used / total
  if fraction >= 0.75 then return theme.red end
  if fraction >= 0.25 then return theme.orange end
  return theme.yellow
end

local function fullness_color(fraction)
  if fraction >= 0.9 then return theme.red end
  if fraction >= 0.75 then return theme.yellow end
  return theme.orange
end

local function build(parent)
  local state = {
    role = "shell",
    monitor_focused = true,
    selected = 1,
    occupied = {},
    items = {},
    item_count = 0,
    frame_ms = 0,
    cpu_sample_ms = 0,
    cpu_sequence = -1,
    cpu_count = 1,
    cpu_core_levels = {},
    cpu_core_shown = {},
    cpu_core_targets = {},
    network_sample_ms = 0,
    network_sequence = -1,
    network_scale = NETWORK_SCALE_FLOOR,
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
    local tag = Angled.section(workspaces, {
      height = BAR_HEIGHT,
      overlap = 0,
      fill = index == 1 and theme.accent or CLEAR,
      cells = { { width = index == 1 and 30 or 1, band = { 11, 27 } } },
    })
    local label = tag.cells[1].body:text({
      text = tostring(index),
      font_size = 16,
      text_color = index == 1 and theme.bg or theme.text,
      text_align = "center",
      text_valign = "middle",
    })
    tag.frame:set("opacity", index == 1 and 1 or 0)
    workspace_cells[index] = { section = tag, label = label }
  end

  local strip = bar:stack({ height = BAR_HEIGHT, flex = 1, clip = true })
  local strip_content = strip:stack({ width = 1, height = BAR_HEIGHT })
  local window_layer = strip_content:stack({ height = BAR_HEIGHT })
  local marker_layer = strip_content:stack({ height = BAR_HEIGHT })
  local display_items = {}
  local function create_display_item()
    local item = Angled.section(window_layer, {
      height = BAR_HEIGHT,
      fill = CLEAR,
      cells = { { width = 1, band = { 4, 34 }, inset = 9 } },
    })
    item.frame:set("opacity", 0)
    local row = item.cells[1].body:row({})
    local mark = row:text({
      text = "", width = 1, font_size = 11, text_color = theme.accent, opacity = 0,
      text_valign = "middle",
    })
    local icon_column = row:column({ width = 20 })
    icon_column:spacer({ flex = 1 })
    local icon = icon_column:icon({ icon_source = "", width = 20, height = 20 })
    icon_column:spacer({ flex = 1 })
    local labels = row:column({ gap = 1, padding = { 0, 0, 0, 8 } })
    labels:spacer({ flex = 1 })
    local app_id = labels:text({
      text = "", height = 12, font_size = 11, text_color = theme.text, text_valign = "middle",
    })
    local title = labels:text({
      text = "", height = 10, font_size = 9, text_color = theme.muted, text_valign = "middle",
    })
    labels:spacer({ flex = 1 })
    local marker = marker_layer:stack({ width = 3, height = BAR_HEIGHT, opacity = 0 })
    local marker_column = marker:column({ width = 3, height = BAR_HEIGHT })
    marker_column:spacer({ flex = 1 })
    local marker_line = marker_column:polygon({
      width = 3, height = 24, fill = theme.blue, points = Angled.points(3, 24),
    })
    marker_column:spacer({ flex = 1 })
    display_items[#display_items + 1] = {
      section = item,
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

  -- History plots that are redrawn as data and time move.
  local cpu_plots = {}
  local network_plots = {}

  -- Alternative history styles beside the real plots, for comparison.
  if SHOWCASE_CHARTS then
    local cpu_styles = { "area", "steps", "line", "columns", "ticks", "mirror", "heat" }
    local cells = {}
    for index = 1, #cpu_styles do cells[index] = { width = 96, band = { 2, 12 }, inset = 4 } end
    local showcase = Angled.section(right, {
      height = BAR_HEIGHT, fill = theme.blend(theme.yellow, 60), cells = cells,
    })
    for index, style in ipairs(cpu_styles) do
      local cell = showcase.cells[index]
      cpu_plots[#cpu_plots + 1] = Graph.new(cell, {
        samples = CPU_HISTORY_COUNT, fill = theme.blend(theme.yellow, 220), direction = "up",
        style = style, inset = 4,
      })
      cell.body:text({
        text = style, font_size = 8, text_color = DIM, text_valign = "top", text_align = "start",
      })
    end

    local net_styles = {
      { label = "columns", style = "columns" },
      { label = "lines", style = "line" },
      { label = "heat", style = "heat" },
      { label = "steps", style = "steps" },
    }
    local net_cells = {}
    for index = 1, #net_styles do net_cells[index] = { width = 96, band = { 2, 12 }, inset = 4 } end
    local net_showcase = Angled.section(right, {
      height = BAR_HEIGHT, fill = theme.blend(theme.cyan, 60), cells = net_cells,
    })
    local middle = BAR_HEIGHT / 2
    for index, entry in ipairs(net_styles) do
      local cell = net_showcase.cells[index]
      network_plots[#network_plots + 1] = { side = "rx", graph = Graph.new(cell, {
        samples = NETWORK_SAMPLE_COUNT, fill = theme.blend(theme.green, 220), direction = "up",
        region = { 0, middle }, style = entry.style, inset = 4,
      }) }
      network_plots[#network_plots + 1] = { side = "tx", graph = Graph.new(cell, {
        samples = NETWORK_SAMPLE_COUNT, fill = theme.blend(theme.cyan, 220), direction = "down",
        region = { middle, BAR_HEIGHT }, style = entry.style, inset = 4,
      }) }
      cell.body:text({
        text = entry.label, font_size = 8, text_color = DIM, text_valign = "top", text_align = "start",
      })
    end
  end

  -- CPU history is expressed in busy-core equivalents on a fixed logarithmic
  -- scale. On a 32-thread machine, one saturated core therefore remains
  -- visible instead of collapsing to a misleading 3% sliver.
  local cpu = Angled.section(right, {
    height = BAR_HEIGHT,
    fill = theme.blend(theme.yellow),
    cells = {
      { width = 100 },
      { width = 44 },
      { width = 70, band = { 5, 33 }, inset = 2 },
    },
  })
  cpu_plots[#cpu_plots + 1] = Graph.new(cpu.cells[1], {
    samples = CPU_HISTORY_COUNT, fill = theme.blend(theme.yellow, 220), direction = "up",
  })

  -- The heat field shows the hottest sixteen logical cores, sorted by load.
  -- One bright cell means single-thread saturation; a filled field means
  -- genuinely parallel work, independent of the machine's total core count.
  local cpu_core_cells = {}
  for index = 1, CPU_CORE_DISPLAY_COUNT do
    local column = (index - 1) % CPU_CORE_COLUMNS
    local row_index = math.floor((index - 1) / CPU_CORE_COLUMNS)
    cpu_core_cells[index] = cpu.cells[2]:polygon({
      fill = theme.yellow,
      points = rectangle(3 + column * 5, 10 + row_index * 10, 3, 8),
    })
    cpu_core_cells[index]:set("opacity", 0.10)
    state.cpu_core_levels[index] = 0
    state.cpu_core_shown[index] = 0
    state.cpu_core_targets[index] = 0
  end
  local cpu_lines = text_cell(cpu.cells[3], {
    { text = "0.0/1", size = 12, color = theme.yellow },
    { text = "peak 0%", size = 9, color = DIM },
  })

  local network = Angled.section(right, {
    height = BAR_HEIGHT,
    fill = theme.blend(theme.cyan),
    cells = {
      { width = 100 },
      { width = 92, band = { 5, 33 }, inset = 2 },
    },
  })
  local half = BAR_HEIGHT / 2
  network_plots[#network_plots + 1] = { side = "rx", graph = Graph.new(network.cells[1], {
    samples = NETWORK_SAMPLE_COUNT, fill = theme.blend(theme.green, 220),
    direction = "up", region = { 0, half },
  }) }
  network_plots[#network_plots + 1] = { side = "tx", graph = Graph.new(network.cells[1], {
    samples = NETWORK_SAMPLE_COUNT, fill = theme.blend(theme.cyan, 220),
    direction = "down", region = { half, BAR_HEIGHT },
  }) }
  local network_readout = rate_readouts(network.cells[2], {
    { label = "↓", color = theme.green, parts = Status.bit_rate_parts, unit_width = 34 },
    { label = "↑", color = theme.cyan, parts = Status.bit_rate_parts, unit_width = 34 },
  })

  local function logarithmic_fraction(value, ceiling)
    value = math.max(0, tonumber(value) or 0)
    ceiling = math.max(1, tonumber(ceiling) or 1)
    return math.min(1, math.log(1 + value) / math.log(1 + ceiling))
  end

  local audio = Angled.section(right, {
    height = BAR_HEIGHT,
    fill = theme.blend(theme.purple),
    cells = { { width = 11 }, { width = 34 } },
  })
  local update_audio_bar = level_bar(audio.cells[1], { color = theme.purple, width = 8 })
  local update_speaker = speaker_icon(audio.cells[2], 5, 12, theme.purple)

  -- Memory: how much programs hold out of the total, how much of the rest is
  -- cache, and (separately) swap and zswap.
  local memory = Angled.section(right, {
    height = BAR_HEIGHT,
    fill = theme.blend(theme.green),
    cells = {
      { width = 8 },
      { width = 5 },
      { width = 26 },
      { width = 74, band = { 5, 33 }, inset = 2 },
      { width = 84, band = { 5, 33 }, inset = 2 },
    },
  })
  local update_memory_bar = level_bar(memory.cells[1], { color = theme.green, width = 8, bands = 3 })
  local update_swap_bar = level_bar(memory.cells[2], { color = theme.orange, width = 3 })
  chip_icon(memory.cells[3], 6, 13, theme.green)
  local memory_lines = text_cell(memory.cells[4], {
    { text = "0/0", size = 12, color = theme.green },
    { text = "0B cache", size = 9, color = DIM },
  })
  local swap_lines = text_cell(memory.cells[5], {
    { text = "", size = 12, color = DIM },
    { text = "", size = 9, color = DIM },
  })

  -- Storage: one chip per pool or filesystem, each with its own usage bar
  -- (beside the name it belongs to), free space, and read/write throughput.
  local disk_cells = { { width = 26 } }
  for _ = 1, MAX_DISK_CHIPS do disk_cells[#disk_cells + 1] = { width = 118, band = { 3, 35 }, inset = 10 } end
  local disk = Angled.section(right, {
    height = BAR_HEIGHT,
    fill = theme.blend(theme.orange),
    cells = disk_cells,
  })
  disk_icon(disk.cells[1], 6, 12, theme.orange)
  local chips = {}
  for index = 1, MAX_DISK_CHIPS do
    local cell = disk.cells[index + 1]
    local bar = level_bar(cell, { color = theme.orange, width = 6, u = 1 })
    local column = cell.body:column({ gap = 1 })
    column:spacer({ flex = 1 })
    local head = column:row({ height = 12 })
    local name = head:text({
      text = "", width = 52, height = 12, font_size = 11, text_color = theme.text, text_valign = "middle",
    })
    local free = head:text({
      text = "", width = 32, height = 12, font_size = 11, text_color = theme.bright,
      text_align = "end", text_valign = "middle",
    })
    local io_row = column:row({ height = 10, gap = 4 })
    local read = rate_slots(io_row, {
      label = "R", label_width = 7, number_width = 32, merged = true, size = 9, height = 10,
      color = theme.green, parts = Status.compact_rate_parts,
    })
    local write = rate_slots(io_row, {
      label = "W", label_width = 9, number_width = 32, merged = true, size = 9, height = 10,
      color = theme.cyan, parts = Status.compact_rate_parts,
    })
    column:spacer({ flex = 1 })
    chips[index] = { cell = cell, bar = bar, name = name, free = free, read = read, write = write }
    disk:set_cell_width(index + 1, 1)
    cell.frame:set("opacity", 0)
  end

  local battery = Angled.section(right, {
    height = BAR_HEIGHT,
    fill = theme.blend(theme.red),
    cells = { { width = 11 }, { width = 24 }, { width = 34, band = { 10, 28 } } },
  })
  local update_battery_bar = level_bar(battery.cells[1], { color = theme.red, width = 8 })
  local update_battery_icon = battery_icon(battery.cells[2], 4, 12, theme.red)
  local battery_label = battery.cells[3].body:text({
    text = "", font_size = 12, text_color = theme.red, text_align = "center", text_valign = "middle",
  })
  battery.frame:set("width", 1)
  battery.frame:set("opacity", 0)

  local clock = Angled.section(right, {
    height = BAR_HEIGHT,
    fill = theme.blend(theme.blue),
    cells = { { width = 126, band = { 3, 35 }, inset = 12 } },
  })
  local clock_column = clock.cells[1].body:column({ gap = 1 })
  clock_column:spacer({ flex = 1 })
  local clock_line = clock_column:row({ gap = 5, height = 18 })
  local time_label = clock_line:text({
    text = "--:--", font_size = 16, text_color = theme.bright, text_valign = "middle",
  })
  local dow_label = clock_line:text({
    text = "---", font_size = 11, text_color = theme.text, text_valign = "middle", padding = { 0, 0, 0, 5 },
  })
  local date_label = clock_column:text({
    text = "---- -- --", height = 11, font_size = 11, text_color = DIM, text_valign = "middle",
  })
  clock_column:spacer({ flex = 1 })

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

  local function draw_cpu(now_ms, elapsed)
    local blend = elapsed > 0 and (1 - math.exp(-elapsed / 140)) or 0
    for index = 1, CPU_CORE_DISPLAY_COUNT do
      local level = state.cpu_core_levels[index]
        + (state.cpu_core_targets[index] - state.cpu_core_levels[index]) * blend
      state.cpu_core_levels[index] = level
      -- Repaint only when the visible shade (in twelfths) changes.
      local shade = math.floor(clamp01(level) * 12 + 0.5)
      if shade ~= state.cpu_core_shown[index] then
        state.cpu_core_shown[index] = shade
        cpu_core_cells[index]:set("opacity", 0.10 + 0.90 * shade / 12)
      end
    end
    local phase = math.max(0, math.min(0.99, (now_ms - state.cpu_sample_ms) / CPU_SAMPLE_MS))
    local function level(value) return logarithmic_fraction(value, state.cpu_count) end
    for _, plot in ipairs(cpu_plots) do plot:draw(phase, level, state.cpu_count) end
  end

  -- The chart ceiling follows the data. It rises at once, so a burst is never
  -- clipped, and decays slowly so the plot does not breathe with every sample.
  -- Heights use a square root: a gigabit burst and a few idle kilobytes both
  -- stay legible on one chart. The ceiling moves in 5% steps so an unchanged
  -- plot is not redrawn.
  local function draw_network(now_ms, elapsed)
    local peak = 0
    for _, value in ipairs(state.network_rx or {}) do peak = math.max(peak, value) end
    for _, value in ipairs(state.network_tx or {}) do peak = math.max(peak, value) end
    local target = math.max(NETWORK_SCALE_FLOOR, peak * 1.15)
    if target >= state.network_scale then
      state.network_scale = target
    elseif elapsed > 0 then
      state.network_scale = state.network_scale
        + (target - state.network_scale) * (1 - math.exp(-elapsed / NETWORK_SCALE_DECAY_MS))
    end
    local step = math.floor(math.log(state.network_scale) * 20)
    local scale = math.exp(step / 20)
    local function level(value) return math.sqrt(math.max(0, tonumber(value) or 0) / scale) end
    local phase = math.max(0, math.min(0.99, (now_ms - state.network_sample_ms) / NETWORK_SAMPLE_MS))
    for _, plot in ipairs(network_plots) do plot.graph:draw(phase, level, step) end
  end

  local function draw_frame(now_ms, force)
    now_ms = math.max(state.frame_ms, tonumber(now_ms) or 0)
    -- Animations advance on a shared 100ms grid: every plot steps on the same
    -- ticks, so a quiet bar is redrawn ten times a second at most rather than
    -- whenever any one plot happens to cross a pixel.
    now_ms = math.floor(now_ms / FRAME_TICK_MS) * FRAME_TICK_MS
    if not force and now_ms <= state.frame_ms and state.frame_ms > 0 then return end
    now_ms = math.max(now_ms, state.frame_ms)
    local elapsed = math.max(0, now_ms - state.frame_ms)
    state.frame_ms = now_ms
    draw_cpu(now_ms, elapsed)
    draw_network(now_ms, elapsed)
  end

  local function update_desktop(values)
    state.selected = math.floor(tonumber(values[1]) or state.selected)
    state.occupied = type(values[2]) == "table" and values[2] or state.occupied
    state.items = type(values[3]) == "table" and values[3] or {}
    -- Whether this bar's monitor is the focused one (it may hold no window).
    state.monitor_focused = values[8] ~= false
    while #display_items < #state.items do create_display_item() end

    for index, tag in ipairs(workspace_cells) do
      local active = index == state.selected
      local visible = active or state.occupied[index] == true
      tag.section:resize(visible and 30 or 1)
      tag.section.frame:set("opacity", visible and 1 or 0)
      -- The active tag is bright on the focused monitor and dim elsewhere.
      local active_fill = state.monitor_focused and theme.accent or theme.overlay
      tag.section:set_fill(active and active_fill or CLEAR)
      tag.label:set("text_color", active and (state.monitor_focused and theme.bg or theme.bright) or theme.text)
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
        view.section:resize(width)
        view.section.frame:set("offset_x", x)
        view.section.frame:set("opacity", is_window and 1 or 0)
        view.section:set_fill(focused and theme.blend(theme.accent, 112) or theme.blend(theme.surface, 96))
        local app_limit = math.max(4, math.floor((width - 66) / 7))
        local title_limit = math.max(5, math.floor((width - 66) / 6))
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
        view.marker_line:set("height", marker_height)
        view.marker_line:set("points", Angled.points(3, marker_height))
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
        view.section.frame:set("opacity", 0)
        view.section:resize(1)
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

  -- Status arrives grouped by subsystem:
  --   1 time, 2 weekday, 3 date,
  --   4 cpu      { percent, core_equivalents, core_count, cores[], history[], sequence }
  --   5 network  { rx_rate, tx_rate, rx_history[], tx_history[], sequence }   bytes/s
  --   6 audio    { percent, muted, visible }
  --   7 memory   { total, used, cache, arc, free, swap_total, swap_used, zswap_stored, zswap_compressed }
  --   8 disks    { { label, total, used, avail, read_rate, write_rate } ... }
  --   9 battery  { present, percent, charging }
  --  10 osd visible
  local function update_cpu(cpu_values)
    local cpu_count = math.max(1, math.floor(tonumber(cpu_values[3]) or 1))
    local equivalents = math.max(0, tonumber(cpu_values[2]) or 0)
    local cores = type(cpu_values[4]) == "table" and cpu_values[4] or {}
    local history = type(cpu_values[5]) == "table" and cpu_values[5] or {}
    local sequence = math.floor(tonumber(cpu_values[6]) or 0)
    if sequence == state.cpu_sequence then return end
    state.cpu_sequence = sequence
    state.cpu_sample_ms = state.frame_ms
    state.cpu_count = cpu_count
    for _, plot in ipairs(cpu_plots) do plot:set_samples(history) end
    local sorted = {}
    for index = 1, #cores do sorted[index] = math.max(0, tonumber(cores[index]) or 0) end
    table.sort(sorted, function(left, right) return left > right end)
    for index = 1, CPU_CORE_DISPLAY_COUNT do
      state.cpu_core_targets[index] = math.min(1, (sorted[index] or 0) / 100)
    end
    cpu_lines[1]:set("text", string.format("%.1f/%d", equivalents, cpu_count))
    cpu_lines[2]:set("text", string.format("peak %.0f%%", sorted[1] or 0))
  end

  local function update_network(net_values)
    local rx_history = type(net_values[3]) == "table" and net_values[3] or {}
    local tx_history = type(net_values[4]) == "table" and net_values[4] or {}
    local sequence = math.floor(tonumber(net_values[5]) or 0)
    if sequence ~= state.network_sequence then
      state.network_sequence = sequence
      state.network_sample_ms = state.frame_ms
      state.network_rx, state.network_tx = rx_history, tx_history
      for _, plot in ipairs(network_plots) do
        plot.graph:set_samples(plot.side == "rx" and rx_history or tx_history)
      end
    end
    network_readout(1, net_values[1], state.frame_ms)
    network_readout(2, net_values[2], state.frame_ms)
  end

  local function update_memory(memory_values)
    local total = math.max(1, tonumber(memory_values[1]) or 1)
    local used = math.max(0, tonumber(memory_values[2]) or 0)
    local cache = math.max(0, tonumber(memory_values[3]) or 0)
    local arc = math.max(0, tonumber(memory_values[4]) or 0)
    local swap_total = math.max(0, tonumber(memory_values[6]) or 0)
    local swap_used = math.max(0, tonumber(memory_values[7]) or 0)
    local zswap_stored = math.max(0, tonumber(memory_values[8]) or 0)
    -- Bands, bottom up: memory programs actually hold, the ZFS ARC (evictable
    -- but not page cache), then page cache and buffers.
    update_memory_bar({
      { used / total, theme.green },
      { arc / total, theme.cyan },
      { cache / total, with_alpha(theme.green, 0.45) },
    })
    update_swap_bar({ { swap_total > 0 and swap_used / swap_total or 0, theme.orange } })
    memory_lines[1]:set("text", Status.format_ratio(used, total))
    memory_lines[2]:set("text", Status.format_bytes(cache + arc) .. " cache")
    if swap_total > 0 then
      swap_lines[1]:set("text", Status.format_ratio(swap_used, swap_total))
      swap_lines[1]:set("text_color", swap_color(swap_used, swap_total))
      swap_lines[2]:set("text", zswap_stored > 0 and ("swap · zs " .. Status.format_bytes(zswap_stored)) or "swap")
    else
      swap_lines[1]:set("text", "")
      swap_lines[2]:set("text", "no swap")
    end
  end

  local function update_disks(disks)
    for index = 1, MAX_DISK_CHIPS do
      local chip = chips[index]
      local entry = disks[index]
      local present = entry ~= nil
      disk:set_cell_width(index + 1, present and 118 or 1)
      chip.cell.frame:set("opacity", present and 1 or 0)
      if present then
        local total = math.max(1, tonumber(entry[2]) or 1)
        local fraction = (tonumber(entry[3]) or 0) / total
        chip.bar({ { fraction, fullness_color(fraction) } })
        chip.name:set("text", ellipsis(entry[1], 8))
        chip.name:set("text_color", fraction >= 0.9 and theme.red or theme.text)
        chip.free:set("text", Status.format_bytes(entry[4]))
        chip.read(entry[5], state.frame_ms)
        chip.write(entry[6], state.frame_ms)
      end
    end
  end

  local function update_status(values)
    local audio_values = type(values[6]) == "table" and values[6] or {}
    local audio_percent = tonumber(audio_values[1]) or 0
    local audio_muted = audio_values[2] == true
    local battery_values = type(values[9]) == "table" and values[9] or {}
    local battery_present = battery_values[1] == true
    local battery_percent = tonumber(battery_values[2]) or 0
    local battery_charging = battery_values[3] == true

    update_cpu(type(values[4]) == "table" and values[4] or {})
    update_network(type(values[5]) == "table" and values[5] or {})
    draw_frame(state.frame_ms, true)

    local audio_color = audio_muted and theme.red or (audio_percent >= 100 and theme.yellow or theme.purple)
    update_audio_bar({ { audio_percent / 100, audio_color } })
    update_speaker(audio_percent, audio_muted, audio_color)
    update_memory(type(values[7]) == "table" and values[7] or {})
    update_disks(type(values[8]) == "table" and values[8] or {})

    if battery_present then
      local battery_color = battery_charging and theme.green
        or (battery_percent < 15 and theme.red or (battery_percent < 50 and theme.orange or theme.accent))
      battery.frame:set("width", 69)
      battery.frame:set("opacity", 1)
      battery:set_fill(theme.blend(battery_color))
      update_battery_bar({ { battery_percent / 100, battery_color } })
      update_battery_icon(battery_percent / 100, battery_color)
      battery_label:set("text", string.format("%d%%", battery_percent))
      battery_label:set("text_color", battery_color)
    else
      battery.frame:set("width", 1)
      battery.frame:set("opacity", 0)
    end
    time_label:set("text", tostring(values[1] or "--:--"))
    dow_label:set("text", tostring(values[2] or "---"))
    date_label:set("text", tostring(values[3] or "----------"))

    local visible = state.role == "shell" and values[10] == true
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

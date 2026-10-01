-- The status bar: tags, the windows on this output's tag, system status and a
-- clock, in angled panels along the bottom of each output, plus a volume OSD.
--
-- Everything is laid out by the layout engine: panels and items size to their
-- content and nothing here computes a position. Data arrives from the host's
-- services: `desktop` (tags and the layout's window list) and one measurement
-- source per panel, registered in the configuration (`whirlpool.source`):
-- cpu, network, audio, memory, disks, battery. Units: memory and disk sizes
-- are binary (G = GiB, as htop, df and zfs show them); network throughput is
-- bits per second (as link speeds are quoted); disk throughput is bytes.

local surface = require("whirlpool.surface")
local Pointer = require("whirlpool.pointer")
local Scroll = require("whirlpool.scroll")
local series = require("whirlpool.series")
local format = require("whirlpool.format")
local theme = require("lib.theme")
local Angled = require("lib.angled")
local Graph = require("lib.graph")

local HEIGHT = 38
local CLEAR = { 0, 0, 0, 0 }
-- How much history the plots show, and how far behind the newest sample they
-- run (about one sample period, so new data slides in from the right edge).
local PLOT_SPAN_MS = 12000
local PLOT_DELAY_MS = 500
-- Plots and meters redraw on a shared tick: often on mains power, rarely on
-- battery. Scrolling and the OSD follow every frame.
local TICK_AC_MS = 33
local TICK_BATTERY_MS = 125
-- The network scale follows the data: it rises fast enough to fit a burst
-- before it scrolls into view, and falls slowly so the chart does not breathe.
local NETWORK_SCALE_FLOOR = 1024 * 1024
local NETWORK_SCALE_ATTACK_MS = 125
local NETWORK_SCALE_DECAY_MS = 2500
-- Readouts average over longer than the plots, so they are steady enough to read.
local READOUT_WINDOW_MS = 4000
local PLOT_WINDOW_MS = 1000
local OSD_MS = 1500
local CPU_CORE_CELLS = 16
local MAX_DISKS = 5
-- The window list keeps at least this much room; status detail gives way.
local MIN_LIST_WIDTH = 320

local function with_alpha(color, alpha)
  return { color[1], color[2], color[3], alpha }
end

-- Secondary text on the coloured panels: theme.muted is too dark against them.
local DIM = with_alpha(theme.text, 0.62)

local function clamp01(value)
  return math.min(1, math.max(0, value))
end

local function lighten(color, amount)
  return {
    color[1] + (1 - color[1]) * amount, color[2] + (1 - color[2]) * amount,
    color[3] + (1 - color[3]) * amount, color[4] or 1,
  }
end

-- A column of text lines centred vertically: { text, size, color, width }.
local function lines(parent, specs, options)
  options = options or {}
  local column = parent:column({ gap = 1, justify = "center", width = options.width })
  local nodes = {}
  for index, line in ipairs(specs) do
    nodes[index] = column:text({
      text = line.text or "", font_size = line.size, height = line.size + 1,
      text_color = line.color, text_valign = "middle", text_overflow = "ellipsis",
      text_align = options.align or "start",
    })
  end
  return nodes, column
end

-- A figure with a steady shape: the number right-aligned in a fixed slot and
-- the unit in another, so only digits move. It is re-read at most once a
-- second, and only when it has moved by more than a tenth.
local function readout(parent, spec)
  local row = parent:row({ height = spec.size + 1, gap = 1 })
  if spec.label then
    row:text({ text = spec.label, width = spec.label_width or 10, font_size = spec.size, text_color = spec.color, text_valign = "middle" })
  end
  local number = row:text({
    text = "0", width = spec.number_width, font_size = spec.size, text_color = spec.color,
    text_align = "end", text_valign = "middle",
  })
  local unit = spec.unit_width and row:text({
    text = "", width = spec.unit_width, font_size = spec.size, text_color = spec.color, text_valign = "middle",
  })
  local shown, shown_ms
  return function(value, now)
    value = math.max(0, value or 0)
    if shown_ms and now - shown_ms < 1000 then return end
    shown_ms = now
    if shown and math.abs(value - shown) <= 0.1 * math.max(value, shown) then return end
    shown = value
    local digits, suffix = spec.parts(value)
    if unit then
      number:set("text", digits)
      unit:set("text", suffix)
    else
      number:set("text", digits .. suffix)
    end
  end
end

-- A vertical meter on a canvas: a dim track filled from the bottom, in
-- stacked bands (each { fraction, colour }).
local function meter(canvas, u, width, color, bands)
  local height = canvas.height
  canvas:polygon({ fill = with_alpha(color, 0.16), points = Angled.rectangle(u, 0, width, height) })
  local nodes = {}
  for index = 1, bands or 1 do
    nodes[index] = canvas:polygon({ fill = color, points = Angled.rectangle(u, height - 1, width, 1) })
  end
  return function(parts)
    local filled = 0
    for index, node in ipairs(nodes) do
      local part = parts[index] or { 0, color }
      local rows = math.min(math.floor(height * clamp01(part[1]) + 0.5), height - filled)
      if part[1] > 0 then rows = math.max(1, rows) end
      canvas:set_polygon(node, Angled.rectangle(u, height - filled - rows, width, math.max(rows, 0.01)))
      node:set("fill", part[2])
      node:set("opacity", rows > 0 and 1 or 0)
      filled = filled + rows
    end
  end
end

-- Hand-drawn glyphs, in upright canvas pixels.
local function speaker(canvas, u, v, color)
  local rect = Angled.rectangle
  local parts = {
    body = canvas:polygon({ fill = color, points = {
      { u, v + 4 }, { u + 4, v + 4 }, { u + 8, v }, { u + 8, v + 14 }, { u + 4, v + 10 }, { u, v + 10 },
    } }),
    near = canvas:polygon({ fill = color, points = rect(u + 10, v + 4, 1.6, 6) }),
    far = canvas:polygon({ fill = color, points = rect(u + 13, v + 1, 1.6, 12) }),
    cross_a = canvas:polygon({ fill = color, points = { { u + 10, v + 4 }, { u + 11.6, v + 4 }, { u + 14.6, v + 10 }, { u + 13, v + 10 } } }),
    cross_b = canvas:polygon({ fill = color, points = { { u + 13, v + 4 }, { u + 14.6, v + 4 }, { u + 11.6, v + 10 }, { u + 10, v + 10 } } }),
  }
  return function(percent, muted, tint)
    for _, node in pairs(parts) do node:set("fill", tint) end
    parts.near:set("opacity", muted and 0 or (percent > 0 and 1 or 0.3))
    parts.far:set("opacity", muted and 0 or (percent > 45 and 1 or 0.3))
    parts.cross_a:set("opacity", muted and 1 or 0)
    parts.cross_b:set("opacity", muted and 1 or 0)
  end
end

local function chip(canvas, u, v, color)
  local rect = Angled.rectangle
  canvas:polygon({ fill = color, points = rect(u + 2, v + 2, 8, 8) })
  for _, y in ipairs({ 3, 7 }) do
    canvas:polygon({ fill = color, points = rect(u, v + y, 2, 1.6) })
    canvas:polygon({ fill = color, points = rect(u + 10, v + y, 2, 1.6) })
  end
  for _, x in ipairs({ 3.2, 6.8 }) do
    canvas:polygon({ fill = color, points = rect(u + x, v, 1.6, 2) })
    canvas:polygon({ fill = color, points = rect(u + x, v + 10, 1.6, 2) })
  end
end

local function drive(canvas, u, v, color)
  canvas:polygon({ fill = with_alpha(color, 0.55), points = Angled.rectangle(u, v + 3, 14, 8) })
  canvas:polygon({ fill = color, points = Angled.rectangle(u + 9, v + 6, 3, 2) })
end

local function battery_glyph(canvas, u, v, color)
  canvas:polygon({ fill = with_alpha(color, 0.30), points = Angled.rectangle(u, v + 2, 12, 10) })
  canvas:polygon({ fill = color, points = Angled.rectangle(u + 12, v + 5, 2, 4) })
  local level = canvas:polygon({ fill = color, points = Angled.rectangle(u + 1, v + 3, 1, 8) })
  return function(fraction, tint)
    canvas:set_polygon(level, Angled.rectangle(u + 1, v + 3, math.max(0.5, 10 * clamp01(fraction)), 8))
    level:set("fill", tint)
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

return function(root)
  local pointer = Pointer.new()
  surface.on("pointer", function(event) pointer:handle(event) end)

  local now_ms, tick_ms, drawn_ms = 0, TICK_AC_MS, nil
  local redraws = {} -- per-tick drawing, by panel

  -- On a full-output River shell the spacer pins the bar to the bottom; on a
  -- bar-sized layer surface it is empty.
  local shell = root:column()
  shell:spacer({ flex = 1 })
  local bar_layer = shell:stack({ height = HEIGHT })
  bar_layer:shape({ fill = theme.bg })
  local bar = bar_layer:row({ height = HEIGHT, align = "center" })

  ---------------------------------------------------------------------------
  -- Tags: one per tag that is active or holds windows. Click to show it; the
  -- wheel over them steps through tags.
  local tags_row = bar:row({ height = HEIGHT, gap = 4, padding = { 0, 8, 0, 0 } })
  local tags, tag_state = {}, { active = 1, count = 0, focused = true }

  local function paint_tag(index)
    local tag = tags[index]
    local active = index == tag_state.active
    local hovered = pointer:hovering(tag.panel.frame)
    local fill = active and (tag_state.focused and theme.accent or theme.overlay) or CLEAR
    if hovered then fill = active and lighten(fill, 0.2) or theme.blend(theme.surface, 160) end
    tag.panel:set_fill(fill)
    tag.label:set("text_color", active and (tag_state.focused and theme.bg or theme.bright) or theme.text)
  end

  local function tag_node(index)
    if tags[index] then return tags[index] end
    local panel = Angled.panel(tags_row, { height = HEIGHT, top = 11, pad = 4, fill = CLEAR })
    local label = panel.row:text({
      text = tostring(index), font_size = 16, min_width = 10, text_color = theme.text,
      text_align = "center", text_valign = "middle",
    })
    tags[index] = { panel = panel, label = label }
    pointer:region(panel.frame, {
      click = function() surface.act("layout", "focus-tag", index) end,
      hover = function() paint_tag(index) end,
    })
    return tags[index]
  end

  pointer:region(tags_row, {
    scroll = function(event)
      local step = (event.dy > 0) and 1 or -1
      local target = math.max(1, math.min(tag_state.count, tag_state.active + step))
      if target ~= tag_state.active then surface.act("layout", "focus-tag", target) end
    end,
  })

  ---------------------------------------------------------------------------
  -- Windows: the layout's list for this output's tag, scrolled to keep the
  -- focused window in view; the wheel scrolls it by hand until focus moves.
  local list_area = bar:stack({ flex = 1, height = HEIGHT, clip = true })
  local viewport = list_area:row({ clip = true })
  local strip = viewport:row({ height = HEIGHT, gap = 4, align = "center" })
  local view = Scroll.new(viewport, strip)
  local fades = list_area:row({ height = HEIGHT })
  local function fade(reversed)
    local edge = fades:row({ width = 24, height = HEIGHT, opacity = 0 })
    for step = 1, 8 do
      local alpha = reversed and step / 8 or (9 - step) / 8
      edge:shape({ width = 3, fill = with_alpha(theme.bg, alpha) })
    end
    return edge
  end
  local left_fade = fade(false)
  fades:spacer({ flex = 1 })
  local right_fade = fade(true)

  local items, item_views, focused_view = {}, {}, nil
  local following = true

  local function paint_item(index)
    local view_item, item = item_views[index], items[index]
    if not item or item.kind ~= "window" then return end
    local hovered = pointer:hovering(view_item.panel.frame)
    local fill = item.focused and theme.blend(theme.accent, 112) or theme.blend(theme.surface, 96)
    if hovered then fill = lighten(fill, 0.12) end
    view_item.panel:set_fill(fill)
  end

  local function item_view(index)
    if item_views[index] then return item_views[index] end
    local panel = Angled.panel(strip, { height = HEIGHT, top = 4, pad = 6, gap = 8 })
    local mark = panel.row:text({ text = "", font_size = 11, text_color = theme.accent, text_valign = "middle", visible = false })
    local icon = panel.row:icon({ icon_source = "", width = 20, height = 20 })
    local labels = panel.row:column({ gap = 1, justify = "center", max_width = 150 })
    local app = labels:text({ text = "", height = 12, font_size = 11, text_color = theme.text, text_valign = "middle", text_overflow = "ellipsis" })
    local title = labels:text({ text = "", height = 10, font_size = 9, text_color = theme.muted, text_valign = "middle", text_overflow = "ellipsis" })
    -- Group boundaries and the insertion point are thin slanted bars.
    local marker = strip:stack({ width = 4, height = 34, visible = false })
    local marker_line = marker:polygon({ fill = theme.blue, points = Angled.points(34, nil, 0) })
    local entry = { panel = panel, mark = mark, icon = icon, app = app, title = title, marker = marker, marker_line = marker_line }
    item_views[index] = entry
    pointer:region(panel.frame, {
      click = function()
        local item = items[index]
        if item and item.action ~= "" then surface.act("layout", item.action, table.unpack(item.args)) end
      end,
      hover = function() paint_item(index) end,
    })
    return entry
  end

  pointer:region(viewport, {
    scroll = function(event)
      following = false
      view:by((event.dy ~= 0 and event.dy or event.dx) * 3)
    end,
  })

  local group_colors = { float = theme.purple, full = theme.orange, scratch = theme.cyan, t = theme.purple, v = theme.cyan }

  local function show_items(list)
    items = list
    local focused
    for index = 1, math.max(#items, #item_views) do
      local item = items[index]
      local entry = item and item_view(index) or item_views[index]
      local is_window = item and item.kind == "window"
      local is_marker = item and not is_window
      entry.panel:set_visible(is_window == true)
      entry.marker:set("visible", is_marker == true)
      if is_window then
        entry.icon:set("icon_source", item.icon)
        entry.app:set("text", item.app_id ~= "" and item.app_id or "window")
        entry.app:set("text_color", item.focused and theme.bright or theme.text)
        entry.title:set("text", item.title)
        entry.title:set("text_color", item.focused and theme.text or theme.muted)
        entry.mark:set("text", item.detail)
        entry.mark:set("visible", item.detail ~= "")
        paint_item(index)
        if item.focused then focused = entry.panel.frame end
      elseif is_marker then
        local insertion = item.kind == "insertion"
        local tall = insertion and 34 or 24
        entry.marker:set("height", tall)
        entry.marker_line:set("points", Angled.points(tall, nil, 0))
        entry.marker_line:set("fill", insertion and theme.accent
          or item.detail ~= "" and theme.purple
          or item.focused and theme.bright
          or group_colors[item.label]
          or item.kind == "group-open" and theme.blue
          or theme.muted)
      end
    end
    if focused ~= focused_view then
      focused_view, following = focused, true
    end
  end

  local function step_list(now)
    -- Keep the focused window in view (as items and widths change) until the
    -- wheel takes over; it resumes when focus moves.
    if following and focused_view then view:reveal(focused_view, 24) end
    local moving = view:step(now)
    local left, right = view:clipped()
    left_fade:set("opacity", clamp01(left / 24))
    right_fade:set("opacity", clamp01(right / 24))
    return moving
  end

  surface.on("desktop", function(desktop)
    tag_state.active, tag_state.focused, tag_state.count = desktop.tag, desktop.focused, #desktop.tags
    for index, tag in ipairs(desktop.tags) do
      local node = tag_node(index)
      node.panel:set_visible(tag.active or tag.occupied)
      paint_tag(index)
    end
    for index = #desktop.tags + 1, #tags do tags[index].panel:set_visible(false) end
    show_items(desktop.items)
  end)

  ---------------------------------------------------------------------------
  -- Status panels, right of the window list.
  local status = bar:row({ height = HEIGHT })

  -- Detail that can give way on a narrow output, in the order it goes. Each
  -- shows when it has data and has not been dropped for room.
  local optional = {}
  local function optional_node(node, data)
    local entry = { node = node, data = data ~= false, dropped = false }
    function entry.apply() node:set("visible", entry.data and not entry.dropped) end
    function entry.set_data(value) entry.data = value; entry.apply() end
    return entry
  end

  -- CPU: history in busy cores on a logarithmic scale, so one saturated core
  -- on a many-core machine is still visible; the hottest cores as a heat
  -- field (one bright cell is single-thread load, a lit field is parallel).
  local cpu_panel = Angled.panel(status, { height = HEIGHT, fill = theme.blend(theme.yellow), gap = 4, pad = 2 })
  local cpu_canvas = Angled.canvas(cpu_panel.row, { width = 96, height = HEIGHT })
  local cpu_plot = Graph.new(cpu_canvas, {
    span = PLOT_SPAN_MS, delay = PLOT_DELAY_MS, style = "area", fill = theme.blend(theme.yellow, 220),
  })
  local cores_canvas = Angled.canvas(cpu_panel.row, { width = 40, height = HEIGHT })
  local cores_optional = optional_node(cores_canvas.node)
  local cores = {}
  for index = 1, CPU_CORE_CELLS do
    local column, row = (index - 1) % 8, (index - 1) // 8
    cores[index] = {
      node = cores_canvas:polygon({ fill = theme.yellow, points = Angled.rectangle(column * 5, 10 + row * 10, 3, 8) }),
      level = 0, target = 0, shade = -1,
    }
  end
  local cpu_text = lines(cpu_panel.row, {
    { text = "0.0/1", size = 12, color = theme.yellow },
    { text = "peak 0%", size = 9, color = DIM },
  }, { width = 56 })
  local cpu_count = 1

  surface.on("cpu", function(cpu)
    cpu_count = math.max(1, cpu.count)
    cpu_plot:set(cpu.t, cpu.busy)
    local sorted = {}
    for index, value in ipairs(cpu.cores) do sorted[index] = value end
    table.sort(sorted, function(a, b) return a > b end)
    for index, core in ipairs(cores) do core.target = math.min(1, (sorted[index] or 0) / 100) end
    cpu_text[1]:set("text", string.format("%.1f/%d", series.last(cpu.busy, 0), cpu_count))
    cpu_text[2]:set("text", string.format("peak %.0f%%", sorted[1] or 0))
  end)

  redraws.cpu = function(now, elapsed)
    local function level(value) return math.log(1 + value) / math.log(1 + cpu_count) end
    cpu_plot:draw(now, level, cpu_count)
    local blend = 1 - math.exp(-elapsed / 140)
    for _, core in ipairs(cores) do
      core.level = core.level + (core.target - core.level) * blend
      local shade = math.floor(core.level * 12 + 0.5)
      if shade ~= core.shade then
        core.shade = shade
        core.node:set("opacity", 0.10 + 0.90 * shade / 12)
      end
    end
  end

  -- Network: receive (top) and send (bottom) as heat strips on a shared,
  -- smoothly adapting square-root scale, with steady readouts.
  local net_panel = Angled.panel(status, { height = HEIGHT, fill = theme.blend(theme.cyan), gap = 4, pad = 2 })
  local net_canvas = Angled.canvas(net_panel.row, { width = 96, height = HEIGHT })
  local net_base = theme.blend(theme.cyan)
  local rx_plot = Graph.new(net_canvas, {
    span = PLOT_SPAN_MS, delay = PLOT_DELAY_MS, style = "heat", region = { 0, HEIGHT / 2 },
    fill = theme.blend(theme.green, 220), base = net_base,
  })
  local tx_plot = Graph.new(net_canvas, {
    span = PLOT_SPAN_MS, delay = PLOT_DELAY_MS, style = "heat", region = { HEIGHT / 2, HEIGHT },
    fill = theme.blend(theme.cyan, 220), base = net_base,
  })
  local net_column = net_panel.row:column({ gap = 1, justify = "center" })
  local rx_readout = readout(net_column, { label = "↓", size = 12, color = theme.green, number_width = 26, unit_width = 34, parts = format.bit_rate_parts })
  local tx_readout = readout(net_column, { label = "↑", size = 12, color = theme.cyan, number_width = 26, unit_width = 34, parts = format.bit_rate_parts })
  local network = { rx = {}, tx = {}, t = {}, scale = NETWORK_SCALE_FLOOR }

  surface.on("network", function(net)
    network.t = net.t
    network.rx = series.rates(net.t, net.rx, PLOT_WINDOW_MS)
    network.tx = series.rates(net.t, net.tx, PLOT_WINDOW_MS)
    rx_plot:set(net.t, network.rx)
    tx_plot:set(net.t, network.tx)
    network.rx_now = series.rate(net.t, net.rx, READOUT_WINDOW_MS)
    network.tx_now = series.rate(net.t, net.tx, READOUT_WINDOW_MS)
  end)

  redraws.network = function(now, elapsed)
    local since = now - PLOT_SPAN_MS - PLOT_DELAY_MS
    local peak = math.max(series.peak(network.t, network.rx, since), series.peak(network.t, network.tx, since))
    local target = math.max(NETWORK_SCALE_FLOOR, peak * 1.15)
    local current, wanted = math.log(network.scale), math.log(target)
    local tau = wanted > current and NETWORK_SCALE_ATTACK_MS or NETWORK_SCALE_DECAY_MS
    network.scale = math.exp(current + (wanted - current) * (1 - math.exp(-elapsed / tau)))
    -- The scale moves in 2.5% steps, so a quiet chart is not redrawn.
    local step = math.floor(math.log(network.scale) * 40)
    local scale = math.exp(step / 40)
    local function level(value) return math.sqrt(math.max(0, value) / scale) end
    rx_plot:draw(now, level, step)
    tx_plot:draw(now, level, step)
    rx_readout(network.rx_now, now)
    tx_readout(network.tx_now, now)
  end

  -- Audio: a level meter and a speaker; changes also show the OSD.
  local audio_panel = Angled.panel(status, { height = HEIGHT, fill = theme.blend(theme.purple), gap = 2, pad = 2 })
  local audio_meter_canvas = Angled.canvas(audio_panel.row, { width = 8, height = HEIGHT })
  local audio_meter = meter(audio_meter_canvas, 0, 8, theme.purple)
  local speaker_canvas = Angled.canvas(audio_panel.row, { width = 22, height = HEIGHT })
  local show_speaker = speaker(speaker_canvas, 4, 12, theme.purple)
  audio_panel:set_visible(false)

  local osd = { until_ms = 0 }
  local osd_layer = root:column({ opacity = 0 })
  osd_layer:spacer({ height = 80 })
  local osd_row = osd_layer:row({ height = 120, justify = "center" })
  local osd_box = osd_row:stack({ width = 320, height = 120 })
  osd_box:shape({ fill = theme.bg, radius = 12 })
  local osd_content = osd_box:column({ padding = 20, gap = 10 })
  osd_content:text({ text = "Volume", font_size = 14, text_color = theme.text })
  local osd_track = osd_content:stack({ width = 280, height = 8 })
  osd_track:shape({ fill = theme.surface, radius = 4 })
  local osd_fill = osd_track:shape({ width = 2, fill = theme.accent, radius = 4 })
  local osd_value = osd_content:text({ text = "0%", font_size = 22, text_color = theme.bright })
  local last_audio

  surface.on("audio", function(audio)
    local percent, muted = series.last(audio.percent), series.last(audio.muted, 0) == 1
    if not percent then return end
    audio_panel:set_visible(true)
    local color = muted and theme.red or (percent >= 100 and theme.yellow or theme.purple)
    audio_meter({ { percent / 100, color } })
    show_speaker(percent, muted, color)
    local key = percent .. (muted and "m" or "")
    if last_audio and key ~= last_audio then
      osd.until_ms = now_ms + OSD_MS
      osd_fill:set("width", math.max(2, math.floor(2.8 * math.min(100, percent))))
      osd_fill:set("fill", color)
      osd_value:set("text", muted and (percent .. "% (muted)") or (percent .. "%"))
    end
    last_audio = key
  end)

  -- Memory: what programs hold, the ZFS ARC, and page cache, out of the
  -- total; swap beside it once there is any.
  local memory_panel = Angled.panel(status, { height = HEIGHT, fill = theme.blend(theme.green), gap = 4, pad = 2 })
  local memory_meters = Angled.canvas(memory_panel.row, { width = 14, height = HEIGHT })
  local memory_meter = meter(memory_meters, 0, 8, theme.green, 3)
  local swap_meter = meter(memory_meters, 10, 3, theme.orange)
  local chip_canvas = Angled.canvas(memory_panel.row, { width = 14, height = HEIGHT })
  chip(chip_canvas, 1, 13, theme.green)
  local memory_text = lines(memory_panel.row, {
    { text = "0/0", size = 12, color = theme.green },
    { text = "0B cache", size = 9, color = DIM },
  }, { width = 72 })
  local swap_text, swap_column = lines(memory_panel.row, {
    { text = "", size = 12, color = DIM },
    { text = "", size = 9, color = DIM },
  }, { width = 80 })
  local swap_optional = optional_node(swap_column)
  memory_panel:set_visible(false)

  surface.on("memory", function(memory)
    local total = series.last(memory.total)
    if not total or total <= 0 then return end
    memory_panel:set_visible(true)
    local used, cache, arc = series.last(memory.used, 0), series.last(memory.cache, 0), series.last(memory.arc, 0)
    local swap_total, swap_used = series.last(memory.swap_total, 0), series.last(memory.swap_used, 0)
    local zswap = series.last(memory.zswap_stored, 0)
    memory_meter({
      { used / total, theme.green },
      { arc / total, theme.cyan },
      { cache / total, with_alpha(theme.green, 0.45) },
    })
    swap_meter({ { swap_total > 0 and swap_used / swap_total or 0, theme.orange } })
    memory_text[1]:set("text", format.format_ratio(used, total))
    memory_text[2]:set("text", format.format_bytes(cache + arc) .. " cache")
    if swap_total > 0 then
      swap_text[1]:set("text", format.format_ratio(swap_used, swap_total))
      swap_text[1]:set("text_color", swap_color(swap_used, swap_total))
      swap_text[2]:set("text", zswap > 0 and ("swap · zs " .. format.format_bytes(zswap)) or "swap")
    else
      swap_text[1]:set("text", "")
      swap_text[2]:set("text", "no swap")
    end
  end)

  -- Storage: one chip per pool or filesystem: how full, free space, and
  -- read/write throughput.
  local disk_panel = Angled.panel(status, { height = HEIGHT, fill = theme.blend(theme.orange), gap = 6, pad = 2 })
  local drive_canvas = Angled.canvas(disk_panel.row, { width = 16, height = HEIGHT })
  drive(drive_canvas, 1, 12, theme.orange)
  local disks, disk_data = {}, nil
  for index = 1, MAX_DISKS do
    local cell = disk_panel.row:row({ gap = 4, visible = false })
    local bar_canvas = Angled.canvas(cell, { width = 6, height = HEIGHT })
    local fill_meter = meter(bar_canvas, 0, 6, theme.orange)
    local column = cell:column({ gap = 1, justify = "center" })
    local head = column:row({ height = 12, gap = 4 })
    local name = head:text({ text = "", width = 52, font_size = 11, text_color = theme.text, text_valign = "middle", text_overflow = "ellipsis" })
    local free = head:text({ text = "", width = 34, font_size = 11, text_color = theme.bright, text_align = "end", text_valign = "middle" })
    local io = column:row({ height = 10, gap = 4 })
    local read = readout(io, { label = "R", label_width = 7, size = 9, number_width = 32, color = theme.green, parts = format.compact_rate_parts })
    local write = readout(io, { label = "W", label_width = 9, size = 9, number_width = 32, color = theme.cyan, parts = format.compact_rate_parts })
    disks[index] = { cell = cell, optional = optional_node(cell, false), meter = fill_meter, name = name, free = free, read = read, write = write }
  end
  disk_panel:set_visible(false)

  surface.on("disks", function(data)
    disk_data = data
    disk_panel:set_visible(#data.disks > 0)
    for index, chip_view in ipairs(disks) do
      local entry = data.disks[index]
      chip_view.optional.set_data(entry ~= nil)
      if entry then
        local fraction = entry.used / math.max(1, entry.total)
        chip_view.meter({ { fraction, fullness_color(fraction) } })
        chip_view.name:set("text", entry.label)
        chip_view.name:set("text_color", fraction >= 0.9 and theme.red or theme.text)
        chip_view.free:set("text", format.format_bytes(entry.avail))
      end
    end
  end)

  redraws.disks = function(now)
    if not disk_data then return end
    for index, chip_view in ipairs(disks) do
      local entry = disk_data.disks[index]
      if entry then
        chip_view.read(series.rate(disk_data.t, entry.read, READOUT_WINDOW_MS), now)
        chip_view.write(series.rate(disk_data.t, entry.write, READOUT_WINDOW_MS), now)
      end
    end
  end

  -- Battery, when there is one; plots also slow down while discharging.
  local battery_panel = Angled.panel(status, { height = HEIGHT, fill = theme.blend(theme.red), gap = 4, pad = 2 })
  local battery_meter_canvas = Angled.canvas(battery_panel.row, { width = 8, height = HEIGHT })
  local battery_meter = meter(battery_meter_canvas, 0, 8, theme.red)
  local battery_glyph_canvas = Angled.canvas(battery_panel.row, { width = 16, height = HEIGHT })
  local show_battery = battery_glyph(battery_glyph_canvas, 1, 12, theme.red)
  local battery_label = battery_panel.row:text({ text = "", width = 34, font_size = 12, text_color = theme.red, text_align = "center", text_valign = "middle" })
  battery_panel:set_visible(false)

  surface.on("battery", function(battery)
    local present = series.last(battery.present, 0) == 1
    tick_ms = series.last(battery.on_ac, 1) == 0 and TICK_BATTERY_MS or TICK_AC_MS
    battery_panel:set_visible(present)
    if not present then return end
    local percent = series.last(battery.percent, 0)
    local charging = series.last(battery.charging, 0) == 1
    local color = charging and theme.green
      or (percent < 15 and theme.red or (percent < 50 and theme.orange or theme.accent))
    battery_panel:set_fill(theme.blend(color))
    battery_meter({ { percent / 100, color } })
    show_battery(percent / 100, color)
    battery_label:set("text", string.format("%d%%", percent))
    battery_label:set("text_color", color)
  end)

  -- Clock, read from the system clock (no service needed).
  local clock_panel = Angled.panel(status, { height = HEIGHT, fill = theme.blend(theme.blue), top = 3, pad = 10 })
  local clock_column = clock_panel.row:column({ gap = 1, justify = "center" })
  local clock_line = clock_column:row({ height = 18, gap = 5 })
  local time_label = clock_line:text({ text = "--:--", font_size = 16, text_color = theme.bright, text_valign = "middle" })
  local day_label = clock_line:text({ text = "---", font_size = 11, text_color = theme.text, text_valign = "middle" })
  local date_label = clock_column:text({ text = "", height = 11, font_size = 11, text_color = DIM, text_valign = "middle" })
  local shown_minute

  redraws.clock = function()
    local minute = os.date("%Y-%m-%d %H:%M")
    if minute == shown_minute then return end
    shown_minute = minute
    time_label:set("text", os.date("%H:%M"))
    day_label:set("text", os.date("%a"))
    date_label:set("text", os.date("%Y-%m-%d"))
  end

  -- Drop order: the last disks first, then swap, then the core field.
  for index = MAX_DISKS, 1, -1 do optional[#optional + 1] = disks[index].optional end
  optional[#optional + 1] = swap_optional
  optional[#optional + 1] = cores_optional

  -- Give the window list its room: drop one piece of detail while it is too
  -- narrow, and bring the last dropped back once it would fit again.
  local function fit()
    local list = list_area:bounds()
    if not list then return end
    if list.width < MIN_LIST_WIDTH then
      for _, entry in ipairs(optional) do
        if entry.data and not entry.dropped then
          local box = entry.node:bounds()
          entry.width = box and box.width or 0
          entry.dropped = true
          entry.apply()
          return
        end
      end
    else
      for index = #optional, 1, -1 do
        local entry = optional[index]
        if entry.dropped then
          if list.width - (entry.width or 0) >= MIN_LIST_WIDTH then
            entry.dropped = false
            entry.apply()
          end
          return
        end
      end
    end
  end

  ---------------------------------------------------------------------------
  -- Frames: scrolling and the OSD every frame, everything else on the tick.
  surface.on("frame", function(frame)
    now_ms = frame.now
    fit()
    step_list(now_ms)
    osd_layer:set("opacity", now_ms < osd.until_ms and 0.96 or 0)
    local due = math.floor(now_ms / tick_ms) * tick_ms
    if drawn_ms and due <= drawn_ms then return end
    local elapsed = drawn_ms and (due - drawn_ms) or 0
    drawn_ms = due
    for _, redraw in pairs(redraws) do redraw(due, elapsed) end
  end)
end

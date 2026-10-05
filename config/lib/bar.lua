-- The status bar: tags, the windows on this output's tag, system status and a
-- clock, in angled panels along the bottom of each output. On an output
-- showing a fullscreen window it draws nothing, so its surface is unmapped
-- and the window has the output to itself (and can be scanned out directly).
--
-- Everything is laid out by the layout engine: panels and items size to their
-- content and nothing here computes a position. Data arrives from the host's
-- services: `desktop` (tags and the layout's window list) and one measurement
-- source per panel, registered in the configuration (lib.sources): cpu,
-- network, disks, memory, sensors, gpu, audio, battery. Units: memory and disk sizes
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

local Scale = require("whirlpool.scale")

local CLEAR = { 0, 0, 0, 0 }

-- What the bar does unless the configuration says otherwise: pass any subset
-- as the surface's `options` (nested tables merge; colours are { r, g, b, a }).
local defaults = {
  -- Must match the surface's registered height.
  height = 38,
  -- How much history plots show, and how far behind the newest sample they
  -- run (about one sample period, so new data slides in from the right edge).
  plot = { span = 12000, delay = 500 },
  -- Plots and meters redraw together on a shared tick, in milliseconds. Each
  -- redraw is a frame the compositor composites on every output, so the tick
  -- is about as long as a plot takes to move one pixel (12.5 s across 64
  -- pixels), and twice that on battery. Scrolling follows every frame, but
  -- only while it moves.
  tick = { ac = 190, battery = 380 },
  -- How much traffic the charts' scales follow (sources keep at least this).
  scale_history = 30000,
  -- Rate readouts average over this long, so they are steady enough to read.
  readout_window = 4000,
  -- The window list keeps at least this much room; status detail gives way.
  min_list_width = 320,
  -- At most this many pixels of per-core field, for at most this many cores.
  cpu = { width = 128, max_cores = 64 },
  network = {
    -- Each plotted sample is the rate over this many milliseconds.
    rate_window = 1000,
    -- The strips' scale (see whirlpool.scale), in bytes a second: it fits
    -- typical traffic between 8 Mb/s and 400 Mb/s, and anything above that
    -- climbs to full brightness at 10 Gb/s, a fast link's capacity.
    scale = {
      floor = 1e6, ceiling = 50e6, peak = 1.25e9,
      percentile = 0.9, headroom = 1.5, decay = 8000, curve = "sqrt",
    },
    -- Tunnels whose addresses are shown, after the default route's.
    tunnels = 1,
  },
  disks = {
    max = 5,
    -- Traffic is plotted as the rate over this many milliseconds (disks are
    -- bursty: a longer window reads as load rather than flicker), on a scale
    -- that fits typical traffic between 16 MiB/s and 512 MiB/s; only more
    -- than that climbs towards bright, fully at 4 GiB/s. Routine writeback
    -- stays well inside the usual range.
    rate_window = 2000,
    scale = {
      floor = 16 * 1024 * 1024, ceiling = 512 * 1024 * 1024, peak = 4 * 1024 * 1024 * 1024,
      percentile = 0.95, headroom = 1.5, decay = 8000, curve = "sqrt",
    },
    -- A pool's name brightens while it moves this many bytes a second.
    busy = 1024 * 1024,
  },
}

-- `defaults` with `options` laid over it. Arrays (lists, colours) are values,
-- not merged element by element.
local function merge(base, options)
  if type(base) ~= "table" or type(options) ~= "table" or base[1] ~= nil or options[1] ~= nil then
    if options == nil then return base end
    return options
  end
  local result = {}
  for key, value in pairs(base) do result[key] = value end
  for key, value in pairs(options) do result[key] = merge(base[key], value) end
  return result
end

local function with_alpha(color, alpha)
  return { color[1], color[2], color[3], alpha }
end

-- The type scale: every text on the bar is one of these sizes, each with a
-- line tall enough for its descenders. Nothing is smaller than `small`.
local TYPE = {
  large = { size = 18, line = 20 }, -- the time, tag numbers
  value = { size = 15, line = 17 }, -- a panel's main figure, window titles
  small = { size = 12, line = 14 }, -- names, details, paired figures
}

-- Every status panel is the same raised surface: what it shows is told by
-- its name and figures, not its colour. Data is drawn in the accent; other
-- hues only flag a state.
local PANEL = theme.raised
local DIM = theme.subtle
local DATA = theme.data

-- A text node at a size of the type scale (`type`, default small), in the
-- theme's font, or its monospace one for figures (`mono`), whose digits then
-- keep their places.
local function label(parent, spec)
  local size = TYPE[spec.type or "small"]
  local mono = spec.mono
  spec.type, spec.mono = nil, nil
  spec.font_family = spec.font_family or (mono and theme.font_mono or theme.font)
  spec.font_size = spec.font_size or size.size
  spec.height = spec.height or size.line
  spec.text_valign = spec.text_valign or "middle"
  return parent:text(spec)
end

local function clamp01(value)
  return math.min(1, math.max(0, value))
end

-- A panel's figures: its main figure above, with a second (`aside`: a
-- temperature) beside it, and below them the panel's name and a detail;
-- callers may add more to `bottom`. `width` keeps the panel steady.
local function stat(parent, spec)
  local column = parent:column({ gap = 1, justify = "center", width = spec.width })
  local top = column:row({ height = TYPE.value.line, gap = 8 })
  local value = label(top, { text = "", type = "value", mono = true, text_color = theme.text })
  local aside = label(top, { text = "", type = "value", text_color = theme.text, visible = false })
  local bottom = column:row({ height = TYPE.small.line, gap = 5 })
  local name = label(bottom, { text = spec.name or "", text_color = DIM })
  local detail = label(bottom, { text = "", text_color = theme.text })
  return { column = column, value = value, aside = aside, bottom = bottom, name = name, detail = detail }
end


-- A figure with a steady shape: the number right-aligned in a fixed slot and
-- the unit in another, so only digits move. It is re-read at most once a
-- second, and only when it has moved by more than a tenth.
local function readout(parent, spec)
  local row = parent:row({ height = TYPE.small.line, gap = 2 })
  local color = spec.color or theme.text
  if spec.label then label(row, { text = spec.label, width = 10, text_color = DIM }) end
  local number = label(row, { text = "0", width = spec.number_width, mono = true, text_color = color, text_align = "end" })
  local unit = spec.unit_width and label(row, { text = "", width = spec.unit_width, text_color = DIM })
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

-- How hot is too hot: a chip's stated critical temperature, else typical
-- limits for that kind of part (warning, then critical).
local HEAT = { cpu = { 80, 90 }, gpu = { 80, 90 }, drive = { 65, 75 } }
local function temperature_color(reading)
  local warn, alarm = table.unpack(HEAT[reading.kind] or HEAT.cpu)
  if (reading.critical or 0) > 0 then warn, alarm = reading.critical - 15, reading.critical - 5 end
  if reading.celsius >= alarm then return theme.ink.red end
  if reading.celsius >= warn then return theme.ink.yellow end
  return theme.text
end
-- Show `reading` ({ celsius, kind, critical }, or nil for none) on `node`.
local function show_temperature(node, reading)
  node:set("visible", reading ~= nil)
  if not reading then return end
  node:set("text", string.format("%.0f°", reading.celsius))
  node:set("text_color", temperature_color(reading))
end

-- Whether a block device (`nvme0n1p3`, `sda1`) is on the drive a sensor is
-- named for (`nvme0`, `sda`).
local function on_drive(device, drive)
  if device:sub(1, #drive) ~= drive then return false end
  local next = device:sub(#drive + 1, #drive + 1)
  if next == "" then return true end
  if drive:match("^nvme") then return next == "n" end
  return next:match("%d") ~= nil
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
  if fraction >= 0.75 then return theme.ink.red end
  if fraction >= 0.25 then return theme.ink.orange end
  return DIM
end

local function fullness_color(fraction)
  if fraction >= 0.9 then return theme.ink.red end
  if fraction >= 0.75 then return theme.ink.yellow end
  return DATA
end

return function(root, options)
  local o = merge(defaults, options)
  local HEIGHT = o.height
  local pointer = Pointer.new()
  surface.on("pointer", function(event) pointer:handle(event) end)

  local now_ms, tick_ms, drawn_ms = 0, o.tick.ac, nil
  local redraws = {} -- per-tick drawing, by panel

  -- The surface is the bar's size; `shell` is everything it draws.
  local shell = root:column()
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
    local fill = active and (tag_state.focused and theme.accent or theme.selected) or CLEAR
    -- Hovered: the light accent (or the next surface step) of the same role.
    if hovered then fill = active and (tag_state.focused and theme.light.blue or theme.selected) or theme.raised end
    tag.panel:set_fill(fill)
    tag.label:set("text_color", active and theme.bright or theme.text)
  end

  local function tag_node(index)
    if tags[index] then return tags[index] end
    local panel = Angled.panel(tags_row, { height = HEIGHT, top = 11, pad = 4, fill = CLEAR })
    local label = label(panel.row, {
      text = tostring(index), type = "large", min_width = 10, text_color = theme.text,
      text_align = "center",
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
  -- Items sliding past either end are cut along the same diagonal as the
  -- panels beside the list, and fade out in slanted slices.
  local list_area = bar:stack({ flex = 1, height = HEIGHT })
  Angled.clip(list_area, HEIGHT)
  local viewport = list_area:row({})
  local strip = viewport:row({ height = HEIGHT, align = "center" })
  local view = Scroll.new(viewport, strip)
  local fades = list_area:row({ height = HEIGHT })
  local function fade(reversed)
    local edge = fades:row({ width = 24, height = HEIGHT, opacity = 0 })
    for step = 1, 8 do
      local alpha = reversed and step / 8 or (9 - step) / 8
      -- Slanted slices tile without overlapping, so no alpha doubles up.
      edge:stack({ width = 3 }):polygon({ fill = with_alpha(theme.bg, alpha), points = Angled.points(HEIGHT, nil, 0) })
    end
    return edge
  end
  local left_fade = fade(false)
  fades:spacer({ flex = 1 })
  local right_fade = fade(true)
  -- Where a window dragged along the list would go: a slanted line in a gap.
  local drop_layer = list_area:row({ height = HEIGHT, align = "center", visible = false })
  local drop_line = drop_layer:stack({ width = 4, height = 34 })
  drop_line:polygon({ fill = theme.data, points = Angled.points(34, nil, 0) })

  local items, item_views, focused_view = {}, {}, nil
  local following = true
  local dragging -- the index of the window being dragged in the list

  -- The entries a dragged window can be placed among, in order, with where
  -- each is: windows and the bounds of groups and rows (not groups that are
  -- not places in the tree).
  local function places()
    local result = {}
    for index, item in ipairs(items) do
      local view_item = item_views[index]
      local node = item.kind == "window" and view_item.panel.frame or view_item.marker
      local box = node:bounds()
      if box and (item.kind == "window" or (item.key or "") ~= "") then
        result[#result + 1] = { item = item, middle = box.x + box.width / 2, left = box.x, right = box.x + box.width }
      end
    end
    return result
  end
  -- The gap nearest `x`: what is before and after it, and where between.
  local function gap_at(x)
    local list = places()
    local position = 0
    for index, place in ipairs(list) do if place.middle < x then position = index end end
    local before, after = list[position], list[position + 1]
    local at = before and after and (before.right + after.left) / 2 or before and before.right + 2 or after and after.left - 2
    return before and before.item, after and after.item, at
  end
  -- The place in the tree a gap stands for, as `place-window` names it.
  local function placement(before, after)
    if after and after.kind == "window" then return "before", after.key end
    if before and before.kind == "window" then return "after", before.key end
    if before and before.kind == "group-open" then return "first", before.key end
    if after and after.kind == "group-close" then return "last", after.key end
    if before and before.kind == "group-close" and before.key:match("^node:") then return "after", before.key end
    if after and after.kind == "group-open" and after.key:match("^node:") then return "before", after.key end
  end
  local function drag_item(index, phase, event)
    local item = items[index]
    if not item or item.kind ~= "window" then return end
    local panel = item_views[index].panel.frame
    if phase == "start" then
      dragging, following = index, false
      panel:set("opacity", 0.45)
    end
    if phase == "start" or phase == "move" then
      local _, _, at = gap_at(event.x)
      local area = list_area:bounds()
      drop_layer:set("visible", at ~= nil)
      if at and area then drop_line:set("offset_x", at - area.x - 2) end
      return
    end
    panel:set("opacity", 1)
    drop_layer:set("visible", false)
    dragging = nil
    if phase == "drop" then
      local relation, key = placement(gap_at(event.x))
      if relation and key and key ~= item.key then
        surface.act("layout", "place-window", item.window, relation, key)
      end
    end
  end

  -- Grouping shows as spacing: windows in a group sit close, a group boundary
  -- leaves a wider gap, and rows (and the floating, fullscreen and scratchpad
  -- sets) are set apart by a slanted rule. A run of one application within a
  -- group sits closer still and shows its icon and name once. A line along
  -- the bottom joins the members of each group, in the accent for the focused
  -- group or row; the focused window has the accent along its top.
  local SAME_APP, SIBLING, BOUNDARY, RULE = 2, 5, 9, 12
  local EDGE = 2 -- the thickness of those lines

  local function paint_item(index)
    local view_item, item = item_views[index], items[index]
    if not item or item.kind ~= "window" then return end
    local hovered = pointer:hovering(view_item.panel.frame)
    local fill = (item.focused or hovered) and theme.selected or theme.raised
    view_item.panel:set_fill(fill)
  end

  -- A band `thickness` high along the top or bottom of a window panel's
  -- parallelogram; along the bottom it reaches `reach` pixels past the end.
  local function band(thickness, top, reach)
    local inset = Angled.SLANT * thickness
    if top then
      local shift = Angled.SLANT * HEIGHT
      return { { 0, 0, shift, 0 }, { 1, 0, shift, 0 }, { 1, 0, shift - inset, thickness }, { 0, 0, shift - inset, thickness } }
    end
    return { { 0, 1, inset, -thickness }, { 1, 1, inset + reach, -thickness }, { 1, 1, reach, 0 }, { 0, 1, 0, 0 } }
  end

  local function item_view(index)
    if item_views[index] then return item_views[index] end
    -- The space before the item: how its grouping shows.
    local lead = strip:spacer({ width = 0 })
    local panel = Angled.panel(strip, { height = HEIGHT, top = 4, pad = 6, gap = 8, overlap = 0 })
    local focus_line = panel.frame:polygon({ fill = theme.data, points = band(EDGE, true, 0), visible = false })
    local group_line = panel.frame:polygon({ fill = theme.subtle, points = band(EDGE, false, 0), visible = false })
    local mark = label(panel.row, { text = "", text_color = theme.ink.purple, visible = false })
    local icon = panel.row:icon({ icon_source = "", width = 20, height = 20 })
    local labels = panel.row:column({ gap = 1, justify = "center", max_width = 180 })
    local primary = label(labels, { text = "", type = "value", text_color = theme.text, text_overflow = "ellipsis" })
    local secondary = label(labels, { text = "", text_color = theme.subtle, text_overflow = "ellipsis" })
    -- A group or row boundary: the rule between rows, the name of a set that
    -- is not a row, and a group's or row's mark.
    local marker = strip:row({ height = HEIGHT, align = "center", gap = 4 })
    local rule = marker:stack({ width = 4, height = 22, visible = false })
    rule:polygon({ fill = theme.selected, points = Angled.points(22, nil, 0) })
    local marker_label = label(marker, { text = "", text_color = theme.subtle, visible = false })
    local entry = {
      lead = lead, panel = panel, focus_line = focus_line, group_line = group_line, mark = mark, icon = icon,
      primary = primary, secondary = secondary, marker = marker, rule = rule, marker_label = marker_label,
    }
    item_views[index] = entry
    pointer:region(panel.frame, {
      click = function()
        local item = items[index]
        if item and item.action ~= "" then surface.act("layout", item.action, table.unpack(item.args)) end
      end,
      hover = function() paint_item(index) end,
      drag = function(phase, event) drag_item(index, phase, event) end,
    })
    return entry
  end

  pointer:region(viewport, {
    scroll = function(event)
      following = false
      view:by((event.dy ~= 0 and event.dy or event.dx) * 3)
    end,
  })

  -- Rows are keyed `strip:`; the floating, fullscreen and scratchpad sets have
  -- no key. Anything else that opens is a group within a row.
  local function is_row(item)
    local key = item.key or ""
    return key == "" or key:match("^strip:") ~= nil
  end
  -- What makes two windows the same application to the eye: their icon.
  local function app_of(item)
    if (item.icon or "") ~= "" then return item.icon end
    return item.app_id or ""
  end

  -- Where each item stands. A window: its outermost group, the focused group
  -- or row it is in, and whether it repeats the application just before it.
  -- A boundary: the space it leaves and what it shows. Every item: the space
  -- before it (`lead`) and after it (`trail`).
  local function arrange(list)
    local open, layout = {}, {}
    local previous -- the window just before, with no boundary between
    local rows = 0
    for index, item in ipairs(list) do
      local place = { lead = 0, trail = 0, text = "" }
      layout[index] = place
      if item.kind == "window" then
        for _, group in ipairs(open) do
          if not place.group and not is_row(group) then place.group = group end
          if group.focused then place.focused_group = group end
        end
        place.repeat_app = previous ~= nil and app_of(item) ~= "" and app_of(item) == app_of(previous)
        place.lead = previous and (place.repeat_app and SAME_APP or SIBLING) or 0
        previous = item
      elseif item.kind == "group-open" then
        open[#open + 1] = item
        previous = nil
        if is_row(item) then
          rows = rows + 1
          -- The first row needs no rule before it.
          place.rule = rows > 1
          place.lead = rows > 1 and RULE or 0
          place.trail = rows > 1 and RULE or 0
          if (item.key or "") == "" then place.text = item.label end
        else
          place.lead = BOUNDARY
        end
        if item.detail ~= "" then place.text = place.text ~= "" and (place.text .. " " .. item.detail) or item.detail end
      elseif item.kind == "group-close" then
        local closed = table.remove(open)
        previous = nil
        place.lead = closed and not is_row(closed) and BOUNDARY or 0
      end
    end
    -- A window's bottom line, and how far it reaches: across the gap to the
    -- next window when that is in the same group.
    for index, item in ipairs(list) do
      local place = layout[index]
      if item.kind == "window" then
        local joined = place.focused_group or place.group
        place.line = place.focused_group and theme.data or place.group and theme.subtle or nil
        local gap = 0
        for next_index = index + 1, #list do
          local next_place = layout[next_index]
          gap = gap + next_place.lead
          if list[next_index].kind == "window" then
            if joined and (next_place.focused_group == joined or next_place.group == joined) then place.reach = gap end
            break
          end
          gap = gap + next_place.trail
        end
      end
    end
    return layout
  end

  local function show_items(list)
    items = list
    local layout = arrange(items)
    local focused
    for index = 1, math.max(#items, #item_views) do
      local item, place = items[index], layout[index]
      local entry = item and item_view(index) or item_views[index]
      local is_window = item and item.kind == "window"
      local is_marker = item and not is_window
      entry.panel:set_visible(is_window == true)
      entry.marker:set("visible", is_marker == true)
      entry.lead:set("width", place and place.lead or 0)
      if is_window then
        local repeated = place.repeat_app
        entry.icon:set("icon_source", item.icon)
        entry.icon:set("visible", not repeated)
        -- The window's title above the application's name (its desktop
        -- entry's, else its id); a window without a title shows just the
        -- name, and a run of one application names it once.
        local name = (item.name or "") ~= "" and item.name or item.app_id
        if name == "" then name = "window" end
        local titled = (item.title or "") ~= ""
        entry.primary:set("text", titled and item.title or name)
        entry.primary:set("text_color", item.focused and theme.bright or theme.text)
        entry.secondary:set("text", titled and name or "")
        entry.secondary:set("visible", titled and not repeated)
        entry.mark:set("text", item.detail)
        entry.mark:set("visible", item.detail ~= "")
        entry.focus_line:set("visible", item.focused)
        entry.group_line:set("visible", place.line ~= nil)
        if place.line then
          entry.group_line:set("fill", place.line)
          entry.group_line:set("points", band(EDGE, false, place.reach or 0))
        end
        paint_item(index)
        if item.focused then focused = entry.panel.frame end
      elseif is_marker then
        entry.rule:set("visible", place.rule == true)
        entry.marker_label:set("text", place.text)
        entry.marker_label:set("visible", place.text ~= "")
        entry.marker_label:set("text_color", item.detail ~= "" and theme.ink.purple
          or item.focused and theme.data or theme.subtle)
        entry.marker:set("padding", { 0, place.trail, 0, 0 })
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
    shell:set("visible", not desktop.fullscreen)
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
  -- Status panels, right of the window list. Each is a graphic (a plot, a
  -- meter) beside a stat: its main figure, and below it the panel's name
  -- and detail. Temperatures sit with what they measure: the CPU's in the
  -- CPU panel, the GPU's in the GPU panel, each drive's beside its pools.
  local status = bar:row({ height = HEIGHT, gap = 3 })

  -- Detail that can give way on a narrow output, in the order it goes. Each
  -- shows when it has data and has not been dropped for room.
  local optional = {}
  local function optional_node(node, data)
    local entry = { node = node, data = data ~= false, dropped = false }
    function entry.apply() node:set("visible", entry.data and not entry.dropped) end
    function entry.set_data(value) entry.data = value; entry.apply() end
    return entry
  end

  local function panel(spec)
    spec.height, spec.fill = HEIGHT, PANEL
    spec.gap, spec.pad = spec.gap or 6, spec.pad or 8
    return Angled.panel(status, spec)
  end

  -- The latest temperatures, by kind; drives by kernel name (`nvme0`).
  local temperatures = { drives = {} }
  local temperature_listeners = {}

  -- CPU: every core as a cell of a field, lit by its load, busiest first (one
  -- bright cell is a single thread working, a lit field is parallel load),
  -- with the clock speed and temperature beside it, and how many cores'
  -- worth are busy.
  local cpu_panel = panel({ flush = true })
  local cores_holder = cpu_panel.row:row({ height = HEIGHT })
  local cpu_stat = stat(cpu_panel.row, { name = "cpu" })
  local cpu_busy = label(cpu_stat.bottom, { text = "", mono = true, text_color = theme.text })
  local cores, cpu_count = {}, 1

  -- The field, made once the source has reported its cores: two rows (four
  -- past 32 cores), as wide as fits `o.cpu.width`.
  local function make_cores(count)
    local rows = count > 32 and 4 or (count > 8 and 2 or 1)
    local columns = math.ceil(count / rows)
    local pitch = math.max(4, o.cpu.width // columns)
    local top, bottom, gap = 6, HEIGHT - 6, 2
    local cell = (bottom - top - gap * (rows - 1)) / rows
    local canvas = Angled.canvas(cores_holder, { width = pitch * columns - gap, height = HEIGHT })
    for index = 1, count do
      local column, row = (index - 1) % columns, (index - 1) // columns
      cores[index] = {
        node = canvas:polygon({ fill = DATA, points = Angled.rectangle(column * pitch, top + row * (cell + gap), pitch - gap, cell) }),
        level = 0, target = 0, shade = -1,
      }
    end
  end

  surface.on("cpu", function(cpu)
    -- The first update can come before the first sample, with no cores yet.
    if (cpu.count or 0) == 0 or #(cpu.cores or {}) == 0 then return end
    cpu_count = cpu.count
    if #cores == 0 then make_cores(math.min(cpu_count, o.cpu.max_cores)) end
    local sorted = {}
    for index, value in ipairs(cpu.cores) do sorted[index] = value end
    table.sort(sorted, function(a, b) return a > b end)
    for index, core in ipairs(cores) do core.target = math.min(1, (sorted[index] or 0) / 100) end
    local mhz = series.last(cpu.mhz, 0)
    cpu_stat.value:set("text", mhz > 0 and string.format("%.2fGHz", mhz / 1000) or "")
    cpu_busy:set("text", string.format("%.1f/%d", series.last(cpu.busy, 0), cpu_count))
  end)
  temperature_listeners[#temperature_listeners + 1] = function()
    show_temperature(cpu_stat.aside, temperatures.cpu)
  end

  redraws.cpu = function(_, elapsed)
    local blend = 1 - math.exp(-elapsed / 140)
    for _, core in ipairs(cores) do
      core.level = core.level + (core.target - core.level) * blend
      local shade = math.floor(core.level * 16 + 0.5)
      if shade ~= core.shade then
        core.shade = shade
        core.node:set("opacity", 0.12 + 0.88 * shade / 16)
      end
    end
  end

  -- GPU: how busy, its temperature and memory, when there is one to ask.
  local gpu_panel = panel({ flush = true })
  local gpu_canvas = Angled.canvas(gpu_panel.row, { width = 48, height = HEIGHT })
  local gpu_plot = Graph.new(gpu_canvas, {
    span = o.plot.span, delay = o.plot.delay, style = "area", fill = DATA, smooth = 4, region = { 7, HEIGHT - 7 },
  })
  local gpu_stat = stat(gpu_panel.row, { name = "gpu" })
  gpu_panel:set_visible(false)

  surface.on("gpu", function(gpu)
    if #gpu.t == 0 then return end
    gpu_panel:set_visible(true)
    gpu_plot:set(gpu.t, gpu.busy)
    gpu_stat.value:set("text", string.format("%.0f%%", series.last(gpu.busy, 0)))
    show_temperature(gpu_stat.aside, { celsius = series.last(gpu.temperature, 0), kind = "gpu" })
    gpu_stat.detail:set("text", format.format_ratio(series.last(gpu.memory_used, 0), series.last(gpu.memory_total, 0)))
  end)

  redraws.gpu = function(now)
    gpu_plot:draw(now, function(value) return value / 100 end, 1)
  end

  -- Memory: what programs hold, the ZFS ARC, and page cache, out of the
  -- total; swap is the thin meter beside it, coloured once it is filling.
  local memory_panel = panel({ flush = true })
  local memory_meters = Angled.canvas(memory_panel.row, { width = 14, height = HEIGHT })
  local memory_meter = meter(memory_meters, 0, 8, DATA, 3)
  local swap_meter = meter(memory_meters, 10, 3, DATA)
  local memory_stat = stat(memory_panel.row, { name = "mem" })
  memory_panel:set_visible(false)

  surface.on("memory", function(memory)
    local total = series.last(memory.total)
    if not total or total <= 0 then return end
    memory_panel:set_visible(true)
    local used, cache, arc = series.last(memory.used, 0), series.last(memory.cache, 0), series.last(memory.arc, 0)
    local swap_total, swap_used = series.last(memory.swap_total, 0), series.last(memory.swap_used, 0)
    memory_meter({
      -- What programs hold in full, what can be reclaimed fainter.
      { used / total, DATA },
      { arc / total, with_alpha(DATA, 0.6) },
      { cache / total, with_alpha(DATA, 0.35) },
    })
    local swapped = swap_color(swap_used, swap_total)
    swap_meter({ { swap_total > 0 and swap_used / swap_total or 0, swapped == DIM and DATA or swapped } })
    memory_stat.value:set("text", format.format_ratio(used, total))
    memory_stat.detail:set("text", format.format_bytes(cache + arc) .. " cache")
  end)

  -- Traffic in two directions as two heat strips, the first above the
  -- second, on one scale: the colour flows from the panel's at nothing to
  -- the accent across the usual range, and on to bright for a peak. The
  -- scale follows `scale_history` of traffic, more than the strips show, so
  -- it does not lurch as samples scroll off.
  local function strips(canvas, spec)
    local half = HEIGHT / 2
    local function strip(region)
      return Graph.new(canvas, {
        span = o.plot.span, delay = o.plot.delay, style = "heat", region = region,
        fill = DATA, base = PANEL, hot = theme.bright,
      })
    end
    local first, second = strip({ 0, half - 0.5 }), strip({ half + 0.5, HEIGHT })
    local scale = Scale.new(spec.scale)
    local data = { t = {}, first = {}, second = {} }
    local function level(value) return scale:level(value) end
    return {
      set = function(t, first_values, second_values)
        data.t, data.first, data.second = t, first_values, second_values
        first:set(t, first_values)
        second:set(t, second_values)
      end,
      draw = function(now, elapsed)
        scale:update(elapsed, data.t, now - o.scale_history, data.first, data.second)
        first:draw(now, level, scale.version)
        second:draw(now, level, scale.version)
      end,
    }
  end

  -- Network: receive above, send below, with steady readouts; then where
  -- this machine is: the IPv4 addresses of the default route's interface
  -- and of any tunnel, and below them the interface's IPv6 address.
  local net_panel = panel({ flush = true })
  local net_chart = strips(Angled.canvas(net_panel.row, { width = 64, height = HEIGHT }), { scale = o.network.scale })
  local net_column = net_panel.row:column({ gap = 1, justify = "center" })
  local rx_readout = readout(net_column, { label = "↓", number_width = 32, unit_width = 34, parts = format.bit_rate_parts })
  local tx_readout = readout(net_column, { label = "↑", number_width = 32, unit_width = 34, parts = format.bit_rate_parts })
  local address_column = net_panel.row:column({ gap = 1, justify = "center" })
  local address_optional = optional_node(address_column)
  local ipv4_row = address_column:row({ height = TYPE.small.line, gap = 5 })
  local ipv4 = {}
  for index = 1, 1 + o.network.tunnels do
    ipv4[index] = {
      interface = label(ipv4_row, { text = "", text_color = DIM, visible = false }),
      address = label(ipv4_row, { text = "", mono = true, text_color = theme.text, visible = false }),
    }
  end
  local ipv6 = label(address_column, { text = "", mono = true, text_color = theme.text })
  local network = {}

  surface.on("network", function(net)
    local times, rx = series.rates(net.t, net.rx, o.network.rate_window)
    local _, tx = series.rates(net.t, net.tx, o.network.rate_window)
    net_chart.set(times, rx, tx)
    network.rx_now = series.rate(net.t, net.rx, o.readout_window)
    network.tx_now = series.rate(net.t, net.tx, o.readout_window)
    local shown = {}
    if (net.address or "") ~= "" then shown[1] = { net.interface, net.address } end
    for _, tunnel in ipairs(net.tunnels or {}) do shown[#shown + 1] = { tunnel.interface, tunnel.address } end
    for index, slot in ipairs(ipv4) do
      local entry = shown[index]
      slot.interface:set("visible", entry ~= nil)
      slot.address:set("visible", entry ~= nil)
      if entry then
        slot.interface:set("text", entry[1])
        slot.address:set("text", entry[2])
      end
    end
    ipv6:set("text", net.address6 or "")
    ipv6:set("visible", (net.address6 or "") ~= "")
    address_optional.set_data(#shown > 0 or (net.address6 or "") ~= "")
  end)

  redraws.network = function(now, elapsed)
    net_chart.draw(now, elapsed)
    rx_readout(network.rx_now, now)
    tx_readout(network.tx_now, now)
  end

  -- Storage: all traffic as one chart (read above, write below) with
  -- readouts; then the pools and filesystems, two to a column: how full (the
  -- meter), free space, the temperature of the hottest drive under it, and
  -- any trouble its pool reports. A name brightens while its pool is busy.
  local disk_panel = panel({ flush = true })
  local disk_chart = strips(Angled.canvas(disk_panel.row, { width = 48, height = HEIGHT }), { scale = o.disks.scale })
  local io_column = disk_panel.row:column({ gap = 1, justify = "center" })
  local read_readout = readout(io_column, { label = "R", number_width = 30, unit_width = 10, parts = format.compact_rate_parts })
  local write_readout = readout(io_column, { label = "W", number_width = 30, unit_width = 10, parts = format.compact_rate_parts })
  local disks, disk_data, traffic = {}, nil, {}
  local pool_columns = {}
  for index = 1, o.disks.max do
    local column_index = (index + 1) // 2
    pool_columns[column_index] = pool_columns[column_index] or disk_panel.row:column({ gap = 1, justify = "center" })
    local row = pool_columns[column_index]:row({ height = TYPE.small.line, gap = 5, visible = false })
    local fill_meter = meter(Angled.canvas(row, { width = 3, height = TYPE.small.line }), 0, 3, DATA)
    local name = label(row, { text = "", width = 54, text_color = DIM, text_overflow = "ellipsis" })
    local free = label(row, { text = "", min_width = 40, mono = true, text_color = theme.text, text_align = "end" })
    local heat = label(row, { text = "", width = 28, text_color = theme.text, text_align = "end" })
    disks[index] = { optional = optional_node(row, false), meter = fill_meter, name = name, heat = heat, free = free }
  end
  disk_panel:set_visible(false)

  -- "scratchpool" reads as "scratch": a pool's name, without the suffix
  -- everyone gives pools, when enough is left.
  local function short_name(text)
    local stem = text:match("^(.-)%-?pool$")
    return stem and #stem >= 3 and stem or text
  end
  -- The hottest of the drives a filesystem is on.
  local function drive_temperature(devices)
    local hottest
    for _, device in ipairs(devices or {}) do
      for drive, reading in pairs(temperatures.drives) do
        if on_drive(device, drive) and (not hottest or reading.celsius > hottest.celsius) then hottest = reading end
      end
    end
    return hottest
  end
  local function show_disks()
    if not disk_data then return end
    for index, view in ipairs(disks) do
      local entry = disk_data.disks[index]
      view.optional.set_data(entry ~= nil)
      if entry then
        local fraction = entry.used / math.max(1, entry.total)
        local trouble = (entry.state or "") ~= "" and entry.state ~= "ONLINE" and entry.state:lower()
          or (entry.data_errors or 0) > 0 and string.format("%d %s", entry.data_errors, entry.data_errors == 1 and "error" or "errors")
        view.meter({ { fraction, fullness_color(fraction) } })
        view.name:set("text", short_name(entry.label))
        view.name:set("text_color", trouble and theme.ink.red or view.busy and theme.text or DIM)
        -- Trouble takes the place of the free space and temperature until
        -- it is dealt with.
        view.free:set("text", trouble or format.format_bytes(entry.avail))
        view.free:set("text_color", (trouble or fraction >= 0.9) and theme.ink.red or theme.text)
        show_temperature(view.heat, not trouble and drive_temperature(entry.devices) or nil)
      end
    end
  end
  temperature_listeners[#temperature_listeners + 1] = show_disks

  surface.on("disks", function(data)
    disk_data = data
    disk_panel:set_visible(#data.disks > 0)
    -- All traffic together: the counters add up sample by sample.
    local read, write = {}, {}
    for index = 1, #data.t do
      read[index], write[index] = 0, 0
      for _, entry in ipairs(data.disks) do
        read[index] = read[index] + (entry.read[index] or 0)
        write[index] = write[index] + (entry.write[index] or 0)
      end
    end
    local times, reads = series.rates(data.t, read, o.disks.rate_window)
    local _, writes = series.rates(data.t, write, o.disks.rate_window)
    disk_chart.set(times, reads, writes)
    traffic.read_now = series.rate(data.t, read, o.readout_window)
    traffic.write_now = series.rate(data.t, write, o.readout_window)
    for index, view in ipairs(disks) do
      local entry = data.disks[index]
      view.busy = entry ~= nil and (series.rate(data.t, entry.read, o.readout_window)
        + series.rate(data.t, entry.write, o.readout_window)) >= o.disks.busy
    end
    show_disks()
  end)

  redraws.disks = function(now, elapsed)
    disk_chart.draw(now, elapsed)
    read_readout(traffic.read_now, now)
    write_readout(traffic.write_now, now)
  end

  surface.on("sensors", function(data)
    temperatures = { drives = {} }
    for _, sensor in ipairs(data.sensors or {}) do
      local reading = { celsius = series.last(sensor.temperature, 0), kind = sensor.kind, critical = sensor.critical }
      if sensor.kind == "drive" then temperatures.drives[sensor.label] = reading
      elseif not temperatures[sensor.kind] then temperatures[sensor.kind] = reading end
    end
    for _, listener in ipairs(temperature_listeners) do listener() end
  end)

  -- Audio: the volume, and a speaker that shows it (crossed out when
  -- muted). Changes also show in lib.osd, the volume popup.
  local audio_panel = panel({ flush = true, gap = 2 })
  local speaker_canvas = Angled.canvas(audio_panel.row, { width = 22, height = HEIGHT })
  local show_speaker = speaker(speaker_canvas, 4, 12, DIM)
  local volume_label = label(audio_panel.row, { text = "", type = "value", mono = true, text_color = theme.text, width = 38 })
  audio_panel:set_visible(false)


  surface.on("audio", function(audio)
    local percent, muted = series.last(audio.percent), series.last(audio.muted, 0) == 1
    if not percent then return end
    audio_panel:set_visible(true)
    local color = muted and theme.ink.red or (percent >= 100 and theme.ink.yellow or DATA)
    show_speaker(percent, muted, muted and color or DIM)
    volume_label:set("text", string.format("%.0f%%", percent))
    volume_label:set("text_color", muted and theme.ink.red or theme.text)
  end)

  -- Battery, when there is one; plots also slow down while discharging.
  local battery_panel = panel({ flush = true })
  local battery_glyph_canvas = Angled.canvas(battery_panel.row, { width = 16, height = HEIGHT })
  local show_battery = battery_glyph(battery_glyph_canvas, 1, 12, DIM)
  local battery_stat = stat(battery_panel.row, { name = "bat", width = 56 })
  battery_panel:set_visible(false)

  surface.on("battery", function(battery)
    local present = series.last(battery.present, 0) == 1
    tick_ms = series.last(battery.on_ac, 1) == 0 and o.tick.battery or o.tick.ac
    battery_panel:set_visible(present)
    if not present then return end
    local percent = series.last(battery.percent, 0)
    local charging = series.last(battery.charging, 0) == 1
    -- Charging is good news; running low a warning, then critical.
    local color = charging and theme.ink.green or (percent < 15 and theme.ink.red or (percent < 30 and theme.ink.yellow or DATA))
    show_battery(percent / 100, color)
    battery_stat.value:set("text", string.format("%d%%", percent))
    battery_stat.value:set("text_color", color == DATA and theme.text or color)
    battery_stat.detail:set("text", charging and "charging" or series.last(battery.on_ac, 1) == 1 and "on AC" or "")
  end)

  -- Clock, read from the system clock (no service needed).
  local clock_panel = panel({ top = 3, pad = 10 })
  local clock_column = clock_panel.row:column({ gap = 1, justify = "center" })
  local clock_line = clock_column:row({ height = TYPE.large.line, gap = 5 })
  local time_label = label(clock_line, { text = "--:--", type = "large", text_color = theme.bright })
  local day_label = label(clock_line, { text = "---", text_color = theme.text })
  local date_label = label(clock_column, { text = "", text_color = DIM })
  local shown_minute

  redraws.clock = function()
    local minute = os.date("%Y-%m-%d %H:%M")
    if minute == shown_minute then return end
    shown_minute = minute
    time_label:set("text", os.date("%H:%M"))
    day_label:set("text", os.date("%a"))
    date_label:set("text", os.date("%Y-%m-%d"))
  end

  -- Drop order: pools beyond the first two (last first), then addresses,
  -- then the core field.
  for index = o.disks.max, 3, -1 do optional[#optional + 1] = disks[index].optional end
  optional[#optional + 1] = address_optional
  optional[#optional + 1] = cores_optional

  -- Give the window list its room: drop one piece of detail while it is too
  -- narrow, and bring the last dropped back once it would fit again.
  local function fit()
    local list = list_area:bounds()
    if not list then return end
    if list.width < o.min_list_width then
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
          if list.width - (entry.width or 0) >= o.min_list_width then
            entry.dropped = false
            entry.apply()
          end
          return
        end
      end
    end
  end

  ---------------------------------------------------------------------------
  -- Frames: scrolling every frame, everything else on the tick.
  surface.on("frame", function(frame)
    now_ms = frame.now
    fit()
    step_list(now_ms)
    local due = math.floor(now_ms / tick_ms) * tick_ms
    if drawn_ms and due <= drawn_ms then return end
    local elapsed = drawn_ms and (due - drawn_ms) or 0
    drawn_ms = due
    for _, redraw in pairs(redraws) do redraw(due, elapsed) end
  end)
end

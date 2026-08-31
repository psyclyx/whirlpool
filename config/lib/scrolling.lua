-- Example scrolling layout provider. This is user configuration, not
-- Whirlpool's installed standard library: replace this file to replace the
-- layout algorithm.

local peek = 16
local inner_gap = 8
local outer_gap = 4
local border_width = 4
local decoration_height = 28
local min_column_width = 0.05
local max_column_width = 4
local animation_duration_ms = 180

-- Motion is layout policy. Whirlpool supplies only monotonic time and another
-- transaction when this provider asks for one.
local camera_motion = {}
local window_motion = {}

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function ease_out_cubic(progress)
  local remaining = 1 - progress
  return 1 - remaining * remaining * remaining
end

local function sample_number(motion, now)
  if motion.from == motion.to then return motion.to, false end
  local progress = clamp((now - motion.started) / animation_duration_ms, 0, 1)
  if progress >= 1 then
    motion.from = motion.to
    return motion.to, false
  end
  local eased = ease_out_cubic(progress)
  return motion.from + (motion.to - motion.from) * eased, true
end

local function animate_number(motion, target, now)
  local current = sample_number(motion, now)
  if target ~= motion.to then
    motion.from, motion.to, motion.started = current, target, now
  end
  return sample_number(motion, now)
end

local function sample_point(motion, now)
  if motion.from_x == motion.to_x and motion.from_y == motion.to_y then
    return motion.to_x, motion.to_y, false
  end
  local progress = clamp((now - motion.started) / animation_duration_ms, 0, 1)
  if progress >= 1 then
    motion.from_x, motion.from_y = motion.to_x, motion.to_y
    return motion.to_x, motion.to_y, false
  end
  local eased = ease_out_cubic(progress)
  return motion.from_x + (motion.to_x - motion.from_x) * eased,
    motion.from_y + (motion.to_y - motion.from_y) * eased, true
end

local function animate_point(motions, id, target, now, enabled)
  local motion = motions[id]
  if not motion or not enabled then
    motions[id] = {
      from_x = target.x, from_y = target.y,
      to_x = target.x, to_y = target.y, started = now,
    }
    return target.x, target.y, false
  end
  local current_x, current_y = sample_point(motion, now)
  if target.x ~= motion.to_x or target.y ~= motion.to_y then
    motion.from_x, motion.from_y = current_x, current_y
    motion.to_x, motion.to_y, motion.started = target.x, target.y, now
  end
  return sample_point(motion, now)
end

local function leaf_minimum(window)
  if window.placement ~= "tiled" then return { width = 0, height = 0 } end
  local hints = window.size_hints or {}
  local width = math.max(0, hints.min_width or 0)
  local height = math.max(0, hints.min_height or 0)
  local actual, proposed = window.actual, window.proposed
  -- An actual size larger than the proposal is a confirmed lower bound, not
  -- merely the stale size from before a resize. Each axis is independent.
  if actual and (not proposed or actual.width > proposed.width) then
    width = math.max(width, actual.width)
  end
  if actual and (not proposed or actual.height > proposed.height) then
    height = math.max(height, actual.height)
  end
  return {
    width = width > 0 and width + 2 * border_width or 0,
    height = height > 0 and height + decoration_height + 2 * border_width or 0,
  }
end

local function measure(node)
  if node.window then return leaf_minimum(node.window) end
  local width, height = 0, 0
  if node.mode == "tabbed" then
    for _, child in ipairs(node.children) do
      local child_min = measure(child.node)
      width = math.max(width, child_min.width)
      height = math.max(height, child_min.height)
    end
    return { width = width, height = height }
  end
  local horizontal = node.axis == "horizontal"
  for index, child in ipairs(node.children) do
    local child_min = measure(child.node)
    if horizontal then
      width = width + child_min.width
      height = math.max(height, child_min.height)
    else
      width = math.max(width, child_min.width)
      height = height + child_min.height
    end
    if index > 1 then
      if horizontal then width = width + inner_gap else height = height + inner_gap end
    end
  end
  return { width = width, height = height }
end

local function constrained_sizes(children, available, horizontal)
  local minimums, minimum_total, weight_total = {}, 0, 0
  for index, child in ipairs(children) do
    local child_min = measure(child.node)
    local minimum = horizontal and child_min.width or child_min.height
    minimums[index] = minimum
    minimum_total = minimum_total + minimum
    weight_total = weight_total + child.weight
  end
  assert(weight_total > 0, "split weight must be positive")
  local distributable = math.max(minimum_total, available) - minimum_total
  local result, used = {}, 0
  for index, child in ipairs(children) do
    local extent = minimums[index] + math.floor(distributable * child.weight / weight_total)
    result[index], used = extent, used + extent
  end
  local remainder = math.max(minimum_total, available) - used
  local index = 1
  while remainder > 0 do
    result[index] = result[index] + 1
    remainder, index = remainder - 1, index % #children + 1
  end
  return result
end

local function contains_tiled(node)
  if node.window then
    return node.window.lifecycle == "managed"
      and node.window.placement ~= "floating" and node.window.placement ~= "scratchpad"
  end
  for _, child in ipairs(node.children) do
    if contains_tiled(child.node) then return true end
  end
  return false
end

local function walk(node, column, rect, active, entries, node_columns)
  node_columns[node.id] = column.id
  if node.window then
    local window = node.window
    local floating = window.placement == "floating"
    local virtual = floating and {
      x = window.floating.x, y = window.floating.y,
      width = window.floating.width, height = window.floating.height,
    } or {
      x = rect.x, y = rect.y + decoration_height,
      width = math.max(1, rect.width - 2 * border_width),
      height = math.max(1, rect.height - decoration_height - 2 * border_width),
    }
    entries[#entries + 1] = {
      window = window.id,
      column = column.id,
      placement = window.placement,
      virtual = virtual,
      actual = window.actual,
      visible = active and window.lifecycle == "managed"
        and window.placement ~= "scratchpad",
      focus_serial = window.focus_serial,
    }
    return
  end

  if node.mode == "tabbed" then
    for index, child in ipairs(node.children) do
      walk(child.node, column, rect, active and index == node.active, entries, node_columns)
    end
    return
  end

  local horizontal = node.axis == "horizontal"
  local available = horizontal and rect.width or rect.height
  local gap = math.min(inner_gap, math.max(0, math.floor(available)))
  local usable = math.max(0, available - gap * math.max(0, #node.children - 1))
  local sizes = constrained_sizes(node.children, usable, horizontal)
  local cursor = horizontal and rect.x or rect.y
  for index, child in ipairs(node.children) do
    local extent = sizes[index]
    local child_rect
    if horizontal then
      child_rect = { x = cursor, y = rect.y, width = extent, height = rect.height }
    else
      child_rect = { x = rect.x, y = cursor, width = rect.width, height = extent }
    end
    walk(child.node, column, child_rect, active, entries, node_columns)
    cursor = cursor + extent + gap
  end
end

local function clipped(screen, usable)
  local left = math.max(screen.x, usable.x)
  local top = math.max(screen.y, usable.y)
  local right = math.min(screen.x + screen.width, usable.x + usable.width)
  local bottom = math.min(screen.y + screen.height, usable.y + usable.height)
  if right <= left or bottom <= top then return { x = 0, y = 0, width = 0, height = 0 } end
  return { x = left - screen.x, y = top - screen.y, width = right - left, height = bottom - top }
end

return function(snapshot, sampled_camera)
  local usable = snapshot.output.usable
  local now = snapshot.clock.monotonic_ms
  assert(usable.width > 0 and usable.height > 0, "empty usable output")
  local entries, metrics, node_columns = {}, {}, {}
  local base_width = math.max(1, usable.width
    - 2 * (outer_gap + peek + border_width + inner_gap))
  local virtual_x = outer_gap
  for index, column in ipairs(snapshot.tag.columns) do
    if column.root and contains_tiled(column.root) then
      local minimum = measure(column.root)
      local requested = math.floor(base_width
        * clamp(column.width, min_column_width, max_column_width) + 0.5)
      local width = math.max(1, requested, minimum.width)
      metrics[#metrics + 1] = { id = column.id, x = virtual_x, width = width }
      local content_height = math.max(usable.height - outer_gap * 2 - border_width, minimum.height)
      assert(content_height > 0, "layout bounds too small")
      walk(column.root, column, {
        x = virtual_x, y = outer_gap + border_width, width = width, height = content_height,
      }, true, entries, node_columns)
      virtual_x = virtual_x + width + inner_gap
    elseif column.root then
      walk(column.root, column, { x = 0, y = 0, width = 1, height = 1 }, true, entries, node_columns)
    end
  end
  local strip_width = #metrics == 0 and outer_gap * 2
    or virtual_x - inner_gap + outer_gap

  local fullscreen, fullscreen_serial
  for _, entry in ipairs(entries) do
    if entry.visible and entry.placement == "fullscreen"
      and (not fullscreen or entry.focus_serial >= fullscreen_serial) then
      fullscreen, fullscreen_serial = entry, entry.focus_serial
    end
  end
  if fullscreen then
    for _, entry in ipairs(entries) do
      entry.visible = entry == fullscreen
      if entry == fullscreen then
        entry.virtual = { x = 0, y = 0, width = usable.width, height = usable.height }
      end
    end
  end

  local focused_column = snapshot.tag.focused and node_columns[snapshot.tag.focused] or nil
  local focused_metric, focused_index
  for index, metric in ipairs(metrics) do
    if metric.id == focused_column then
      focused_metric, focused_index = metric, index
      break
    end
  end
  local camera = camera_motion[snapshot.tag.id]
  if not camera then
    camera = { from = sampled_camera, to = sampled_camera, started = now }
    camera_motion[snapshot.tag.id] = camera
  end
  local camera_current = sample_number(camera, now)
  local target = camera_current
  if fullscreen then
    target = 0
  elseif focused_metric then
    local peek_total = peek + border_width
    local required_left = focused_index > 1
      and focused_metric.x - inner_gap - peek_total or focused_metric.x
    local required_right = focused_index < #metrics
      and focused_metric.x + focused_metric.width + inner_gap + peek_total
      or focused_metric.x + focused_metric.width
    local needed_left = required_left - outer_gap
    local needed_right = required_right + outer_gap
    if needed_right - needed_left > usable.width then
      target = focused_metric.x + (focused_metric.width - usable.width) / 2
    else
      if target + usable.width < needed_right then target = needed_right - usable.width end
      if target > needed_left then target = needed_left end
    end
    target = clamp(target, 0, math.max(0, strip_width - usable.width))
  else
    target = 0
  end

  local camera_active = false
  if fullscreen then
    camera.from, camera.to, camera.started = 0, 0, now
    camera_current = 0
  else
    camera_current, camera_active = animate_number(camera, target, now)
  end

  local motions = window_motion[snapshot.tag.id]
  if not motions then
    motions = {}
    window_motion[snapshot.tag.id] = motions
  end
  local seen, window_active = {}, false
  for _, entry in ipairs(entries) do
    local virtual = entry.virtual
    local floating = entry.placement == "floating"
    seen[entry.window] = true
    local animated_x, animated_y, active = animate_point(
      motions, entry.window, virtual, now,
      entry.visible and entry.placement == "tiled")
    window_active = window_active or active
    local left = floating and virtual.x or usable.x + animated_x - camera_current
    local top = floating and virtual.y or usable.y + animated_y
    local rendered = entry.actual or virtual
    entry.screen = {
      x = math.floor(left), y = math.floor(top),
      width = math.ceil(math.max(0, rendered.width)),
      height = math.ceil(math.max(0, rendered.height)),
    }
    entry.clip = entry.visible and clipped(entry.screen, usable)
      or { x = 0, y = 0, width = 0, height = 0 }
    entry.propose = entry.visible and entry.placement ~= "scratchpad"
      and entry.placement ~= "fullscreen"
    entry.focus_serial = nil
  end
  for id in pairs(motions) do
    if not seen[id] then motions[id] = nil end
  end

  return {
    epoch = snapshot.epoch,
    tag = snapshot.tag.id,
    camera_current = camera_current,
    camera_target = target,
    strip_width = strip_width,
    entries = entries,
    needs_frame = camera_active or window_active,
  }
end

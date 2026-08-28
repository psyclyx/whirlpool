-- Example scrolling layout provider. This is user configuration, not
-- Whirlpool's installed standard library: replace this file to replace the
-- layout algorithm.

local peek = 16
local inner_gap = 8
local outer_gap = 12
local min_column_width = 0.05
local max_column_width = 4

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function walk(node, column, rect, active, entries, node_columns)
  node_columns[node.id] = column.id
  if node.window then
    local window = node.window
    entries[#entries + 1] = {
      window = window.id,
      column = column.id,
      placement = window.placement,
      virtual = rect,
      visible = active and window.lifecycle == "managed"
        and window.placement ~= "floating" and window.placement ~= "scratchpad",
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

  local weight_sum = 0
  for _, child in ipairs(node.children) do weight_sum = weight_sum + child.weight end
  assert(weight_sum > 0, "split weight must be positive")
  local horizontal = node.axis == "horizontal"
  local available = horizontal and rect.width or rect.height
  local gap = math.min(inner_gap, math.max(0, math.floor(available)))
  local usable = math.max(0, available - gap * math.max(0, #node.children - 1))
  local cursor = horizontal and rect.x or rect.y
  for _, child in ipairs(node.children) do
    local extent = usable * child.weight / weight_sum
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
  assert(usable.width > 0 and usable.height > 0, "empty usable output")
  local entries, metrics, node_columns = {}, {}, {}
  local virtual_x = outer_gap
  for index, column in ipairs(snapshot.tag.columns) do
    local width = math.max(1, usable.width * clamp(column.width, min_column_width, max_column_width))
    if index ~= 1 then virtual_x = virtual_x + outer_gap end
    metrics[#metrics + 1] = { id = column.id, x = virtual_x, width = width }
    local content_height = usable.height - outer_gap * 2
    assert(content_height > 0, "layout bounds too small")
    if column.root then
      walk(column.root, column, {
        x = virtual_x, y = outer_gap, width = width, height = content_height,
      }, true, entries, node_columns)
    end
    virtual_x = virtual_x + width
  end
  local strip_width = virtual_x + outer_gap

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
  local focused_metric = metrics[1]
  for _, metric in ipairs(metrics) do
    if metric.id == focused_column then focused_metric = metric break end
  end
  local target = 0
  if focused_metric then
    local minimum = focused_metric.x + focused_metric.width - (usable.width - peek)
    local maximum = focused_metric.x - peek
    if minimum <= maximum then
      target = clamp(snapshot.tag.camera.current, minimum, maximum)
    else
      target = focused_metric.x + (focused_metric.width - usable.width) / 2
    end
    target = clamp(target, 0, math.max(0, strip_width - usable.width))
  end

  for _, entry in ipairs(entries) do
    local virtual = entry.virtual
    local left = usable.x + virtual.x - sampled_camera
    local top = usable.y + virtual.y
    entry.screen = {
      x = math.floor(left), y = math.floor(top),
      width = math.ceil(math.max(0, virtual.width)),
      height = math.ceil(math.max(0, virtual.height)),
    }
    entry.clip = entry.visible and clipped(entry.screen, usable)
      or { x = 0, y = 0, width = 0, height = 0 }
    entry.propose = entry.visible and entry.placement ~= "floating" and entry.placement ~= "scratchpad"
    entry.focus_serial = nil
  end

  return {
    epoch = snapshot.epoch,
    tag = snapshot.tag.id,
    camera_current = sampled_camera,
    camera_target = target,
    strip_width = strip_width,
    entries = entries,
  }
end

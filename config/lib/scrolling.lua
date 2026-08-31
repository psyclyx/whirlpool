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
-- Presentation is expressed in logical axes. Switching the main axis or
-- either direction does not change strip, focus, movement, or camera policy.
local main_axis = "horizontal"
local main_reverse = false
local cross_reverse = false

-- Motion is layout policy. Whirlpool supplies only monotonic time and another
-- transaction when this provider asks for one.
local window_y_motion = {}
local tag_layouts = {}
local layout_marks = {}

local function new_strip(state)
  local strip = { id = state.next_strip_id, columns = {} }
  state.next_strip_id = state.next_strip_id + 1
  return strip
end

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

local function animate_window_y(motions, id, target, now, enabled)
  local motion = motions[id]
  if not motion or not enabled then
    motions[id] = { from = target, to = target, started = now }
    return target, false
  end
  return animate_number(motion, target, now)
end

local function leaf_minimum(window)
  if window.placement ~= "tiled" then return { width = 0, height = 0 } end
  local hints = window.size_hints or {}
  local width = math.max(0, hints.min_width or 0)
  local height = math.max(0, hints.min_height or 0)
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

local function clipped_window(screen, usable)
  local frame = {
    x = screen.x - border_width,
    y = screen.y - decoration_height - border_width,
    width = screen.width + 2 * border_width,
    height = screen.height + decoration_height + 2 * border_width,
  }
  local left = math.max(frame.x, usable.x)
  local top = math.max(frame.y, usable.y)
  local right = math.min(frame.x + frame.width, usable.x + usable.width)
  local bottom = math.min(frame.y + frame.height, usable.y + usable.height)
  if right <= left or bottom <= top then return { x = 0, y = 0, width = 0, height = 0 } end
  -- River's whole-window clip is relative to the content origin; negative
  -- coordinates retain the title surface and borders above/left of content.
  return { x = left - screen.x, y = top - screen.y, width = right - left, height = bottom - top }
end

local function walk_nodes(node, visit, parent)
  visit(node, parent)
  for _, child in ipairs(node.children) do walk_nodes(child.node, visit, node) end
end

local function index_snapshot(snapshot)
  local index = { columns = {}, nodes = {}, windows = {}, node_columns = {}, parents = {} }
  for _, column in ipairs(snapshot.tag.columns) do
    index.columns[column.id] = column
    if column.root then
      walk_nodes(column.root, function(node, parent)
        index.nodes[node.id] = node
        index.parents[node.id] = parent and parent.id or nil
        index.node_columns[node.id] = column.id
        if node.window then index.windows[node.window.id] = node end
      end)
    end
  end
  return index
end

local function strip_location(state, column_id)
  for strip_index, strip in ipairs(state.strips) do
    for column_index, candidate in ipairs(strip.columns) do
      if candidate == column_id then return strip_index, column_index end
    end
  end
end

local function remove_column(state, column_id)
  local strip_index, column_index = strip_location(state, column_id)
  if strip_index then table.remove(state.strips[strip_index].columns, column_index) end
end

local function compact_strips(state)
  local kept = {}
  for _, strip in ipairs(state.strips) do
    if #strip.columns > 0 then kept[#kept + 1] = strip end
  end
  if #kept == 0 then kept[1] = new_strip(state) end
  state.strips = kept
  local current_kept = false
  for _, strip in ipairs(kept) do if strip == state.current then current_kept = true end end
  if not current_kept then state.current = kept[1] end
end

local function column_contains_window(column, window_id)
  local found = false
  if column.root then walk_nodes(column.root, function(node)
    if node.window and node.window.id == window_id then found = true end
  end) end
  return found
end

local function sync_topology(snapshot)
  local state = tag_layouts[snapshot.tag.id]
  local created = false
  if not state then
    state = { strips = {}, pending = {}, next_strip_id = 1 }
    state.strips[1] = new_strip(state)
    state.current = state.strips[1]
    tag_layouts[snapshot.tag.id] = state
    created = true
  end
  local index = index_snapshot(snapshot)
  if created then
    for _, column in ipairs(snapshot.tag.columns) do
      state.strips[1].columns[#state.strips[1].columns + 1] = column.id
    end
    return state, index
  end
  for _, strip in ipairs(state.strips) do
    local kept = {}
    for _, column_id in ipairs(strip.columns) do
      if index.columns[column_id] then kept[#kept + 1] = column_id end
    end
    strip.columns = kept
  end
  local focused_column = snapshot.tag.focused and index.node_columns[snapshot.tag.focused] or nil
  local focused_strip = focused_column and strip_location(state, focused_column) or nil
  if focused_strip then state.current = state.strips[focused_strip] end
  for _, column in ipairs(snapshot.tag.columns) do
    if not strip_location(state, column.id) then
      local destination
      for window_id, strip in pairs(state.pending) do
        if column_contains_window(column, window_id) then
          destination, state.pending[window_id] = strip, nil
          break
        end
      end
      if destination then
        for window_id, strip in pairs(state.pending) do
          if strip == destination and column_contains_window(column, window_id) then
            state.pending[window_id] = nil
          end
        end
      end
      if not destination then
        destination = state.current or state.strips[1]
      end
      local insert_at = #destination.columns + 1
      if focused_column then
        local focused_strip, focused_index = strip_location(state, focused_column)
        if focused_strip and state.strips[focused_strip] == destination then insert_at = focused_index + 1 end
      end
      table.insert(destination.columns, insert_at, column.id)
      if focused_column == column.id then state.current = destination end
    end
  end
  compact_strips(state)
  return state, index
end

local function collect_leaves(node, leaves, visible_only, active)
  if node.window then
    if not visible_only or active then leaves[#leaves + 1] = node end
    return
  end
  if node.mode == "tabbed" then
    for child_index, child in ipairs(node.children) do
      collect_leaves(child.node, leaves, visible_only, active and child_index == node.active)
    end
  else
    for _, child in ipairs(node.children) do collect_leaves(child.node, leaves, visible_only, active) end
  end
end

local function column_leaves(column, visible_only)
  local leaves = {}
  if column and column.root then collect_leaves(column.root, leaves, visible_only, true) end
  return leaves
end

local function direction_step(name)
  local physical, motion = name:match("^(focus)%-(.+)$")
  if not physical then physical, motion = name:match("^(swap)%-(.+)$") end
  if not physical then return end
  local horizontal = main_axis == "horizontal"
  local axis, step
  if motion == "left" then axis, step = horizontal and "main" or "cross", -1
  elseif motion == "right" then axis, step = horizontal and "main" or "cross", 1
  elseif motion == "up" then axis, step = horizontal and "cross" or "main", -1
  elseif motion == "down" then axis, step = horizontal and "cross" or "main", 1
  else return end
  if axis == "main" and main_reverse then step = -step end
  if axis == "cross" and cross_reverse then step = -step end
  return physical, axis, step
end

local function focus_operation(node)
  return node and { name = "focus-window", window = node.window.id } or nil
end

local function strip_by_id(state, id)
  for index, strip in ipairs(state.strips) do if strip.id == id then return strip, index end end
end

local function leaves_for_node(node)
  local leaves = {}
  if node then collect_leaves(node, leaves, false, true) end
  return leaves
end

local function tiled_roots(node, result)
  if node.window then
    if node.window.lifecycle == "managed" and node.window.placement == "tiled" then
      result[#result + 1] = node
      return true
    end
    return false
  end
  local child_results, all_tiled, has_tiled = {}, true, false
  for _, child in ipairs(node.children) do
    local roots = {}
    local child_all = tiled_roots(child.node, roots)
    child_results[#child_results + 1] = roots
    all_tiled = all_tiled and child_all
    has_tiled = has_tiled or #roots > 0
  end
  if all_tiled and has_tiled then
    result[#result + 1] = node
    return true
  end
  for _, roots in ipairs(child_results) do
    for _, root in ipairs(roots) do result[#result + 1] = root end
  end
  return false
end

local function selected_nodes(state, index, focused)
  local selection = state.selection
  if not selection then return focused and { focused } or {} end
  if selection.kind == "node" then
    local node = index.nodes[selection.id]
    if not node then return {} end
    if node.window then return { node } end
    local nodes = {}
    tiled_roots(node, nodes)
    return nodes
  end
  if selection.kind == "strip" then
    local strip = strip_by_id(state, selection.id)
    local nodes = {}
    if strip then for _, column_id in ipairs(strip.columns) do
      local column = index.columns[column_id]
      if column and column.root then tiled_roots(column.root, nodes) end
    end end
    return nodes
  end
  if selection.kind == "placement" then
    local nodes = {}
    for _, node in pairs(index.nodes) do
      if node.window and node.window.placement == selection.placement then nodes[#nodes + 1] = node end
    end
    table.sort(nodes, function(a, b) return a.window.focus_serial < b.window.focus_serial end)
    return nodes
  end
  return {}
end

local function selection_windows(state, index, focused)
  local windows, seen = {}, {}
  for _, node in ipairs(selected_nodes(state, index, focused)) do
    for _, leaf in ipairs(leaves_for_node(node)) do
      if leaf.window and not seen[leaf.window.id] then
        windows[#windows + 1], seen[leaf.window.id] = leaf.window.id, true
      end
    end
  end
  return windows
end

local function select_parent(state, index, focused)
  local selection = state.selection
  if not selection then
    if not focused then return end
    if focused.window and focused.window.placement ~= "tiled" then
      state.selection = { kind = "placement", placement = focused.window.placement }
    elseif index.parents[focused.id] and index.nodes[index.parents[focused.id]] then
      state.selection = { kind = "node", id = index.parents[focused.id] }
    else
      local strip_index = strip_location(state, index.node_columns[focused.id])
      if strip_index then state.selection = { kind = "strip", id = state.strips[strip_index].id } end
    end
    return
  end
  if selection.kind == "node" then
    local node = index.nodes[selection.id]
    local parent = node and index.parents[node.id] or nil
    if parent and index.nodes[parent] then
      state.selection = { kind = "node", id = parent }
    elseif node then
      local strip_index = strip_location(state, index.node_columns[node.id])
      if strip_index then state.selection = { kind = "strip", id = state.strips[strip_index].id } end
    else state.selection = nil end
  else
    state.selection = nil
  end
end

local function select_child(state, index, focused)
  local selection = state.selection
  if not selection then return end
  if selection.kind == "strip" then
    local column_id = focused and index.node_columns[focused.id]
    local strip = strip_by_id(state, selection.id)
    if strip and column_id then
      local in_strip = strip_location({ strips = { strip } }, column_id)
      local column = in_strip and index.columns[column_id]
      if column and column.root then state.selection = { kind = "node", id = column.root.id } end
    end
  elseif selection.kind == "placement" then
    if focused then state.selection = { kind = "node", id = focused.id } end
  elseif selection.kind == "node" then
    local node = index.nodes[selection.id]
    if node and not node.window and node.children[node.active] then
      state.selection = { kind = "node", id = node.children[node.active].node.id }
    else
      state.selection = nil
    end
  end
end

local function handle_structural_action(snapshot, request, state, index, focused)
  if request.name == "select-parent" then
    select_parent(state, index, focused)
    return {}
  elseif request.name == "select-child" then
    select_child(state, index, focused)
    return {}
  elseif request.name == "clear-selection" then
    state.selection = nil
    return {}
  elseif request.name == "close-selection" then
    local operations = {}
    for _, window in ipairs(selection_windows(state, index, focused)) do
      operations[#operations + 1] = { name = "close-window", window = window }
    end
    state.selection = nil
    return operations
  elseif request.name == "mark" then
    local name = tostring(request.args[1] or "primary")
    local nodes, windows = selected_nodes(state, index, focused), selection_windows(state, index, focused)
    if #nodes > 0 then
      local node_ids = {}
      for _, node in ipairs(nodes) do node_ids[#node_ids + 1] = node.id end
      layout_marks[name] = { nodes = node_ids, windows = windows }
    end
    return {}
  elseif request.name == "focus-mark" then
    local mark = layout_marks[tostring(request.args[1] or "primary")]
    return mark and mark.windows[1] and { { name = "focus-window", window = mark.windows[1] } } or {}
  elseif request.name == "summon" then
    local mark = layout_marks[tostring(request.args[1] or "primary")]
    if not mark then return {} end
    local destination = state.current or state.strips[1]
    for _, window in ipairs(mark.windows) do state.pending[window] = destination end
    local operations = {}
    for _, node in ipairs(mark.nodes) do
      operations[#operations + 1] = { name = "summon-node", node = node, output = snapshot.output.id }
    end
    state.selection = nil
    return operations
  end
end

local function action(snapshot, request)
  local state, index = sync_topology(snapshot)
  local focused = snapshot.tag.focused and index.nodes[snapshot.tag.focused] or nil
  local structural = handle_structural_action(snapshot, request, state, index, focused)
  if structural then return structural end
  local kind, axis, step = direction_step(request.name)
  if not kind then return {} end
  if not focused or not focused.window then return {} end
  if kind == "focus" then state.selection = nil end
  if kind == "swap" and state.selection then
    if state.selection.kind == "strip" then
      if axis ~= "cross" then return {} end
      local _, source = strip_by_id(state, state.selection.id)
      local destination = source and source + step or nil
      if destination and destination >= 1 and destination <= #state.strips then
        state.strips[source], state.strips[destination] = state.strips[destination], state.strips[source]
      end
      return {}
    elseif state.selection.kind ~= "node" then
      return {}
    end
    local selected = index.nodes[state.selection.id]
    if selected and not selected.window then
      local selected_column_id = index.node_columns[selected.id]
      local selected_strip, selected_column = strip_location(state, selected_column_id)
      if not selected_strip then return {} end
      local projected = selected_nodes(state, index, focused)
      if #projected ~= 1 or projected[1].id ~= selected.id then
        local destination = state.strips[selected_strip]
        if axis == "cross" then
          destination = state.strips[selected_strip + step]
          if not destination then
            destination = new_strip(state)
            if selected_strip + step < 1 then table.insert(state.strips, 1, destination)
            else state.strips[#state.strips + 1] = destination end
          end
        end
        local operations = {}
        for _, node in ipairs(projected) do
          local leaves = leaves_for_node(node)
          if leaves[1] and leaves[1].window then
            state.pending[leaves[1].window.id] = destination
            operations[#operations + 1] = {
              name = "expel", node = node.id, direction = step < 0 and "left" or "right",
            }
          end
        end
        return operations
      end
      local column = index.columns[selected_column_id]
      local is_root = column and column.root and column.root.id == selected.id
      if axis == "main" and is_root then
        local columns = state.strips[selected_strip].columns
        local destination = selected_column + step
        if destination >= 1 and destination <= #columns then
          columns[selected_column], columns[destination] = columns[destination], columns[selected_column]
        end
        return {}
      end
      if axis == "cross" and is_root then
        local destination_index = selected_strip + step
        local destination = state.strips[destination_index]
        if not destination then
          destination = new_strip(state)
          if destination_index < 1 then
            table.insert(state.strips, 1, destination)
            selected_strip = selected_strip + 1
          else state.strips[#state.strips + 1] = destination end
        end
        table.remove(state.strips[selected_strip].columns, selected_column)
        table.insert(destination.columns, selected_column_id)
        state.current = destination
        compact_strips(state)
        return {}
      end
      local leaves = leaves_for_node(selected)
      if leaves[1] and leaves[1].window then
        local destination = axis == "cross" and state.strips[selected_strip + step] or state.strips[selected_strip]
        if not destination then
          destination = new_strip(state)
          if selected_strip + step < 1 then table.insert(state.strips, 1, destination)
          else state.strips[#state.strips + 1] = destination end
        end
        state.pending[leaves[1].window.id] = destination
        return { { name = "expel", node = selected.id, direction = step < 0 and "left" or "right" } }
      end
      return {}
    end
  end
  local column_id = index.node_columns[focused.id]
  local strip_index, column_index = strip_location(state, column_id)
  if not strip_index then return {} end
  local column = index.columns[column_id]
  local leaves = column_leaves(column, true)
  local leaf_index
  for candidate, node in ipairs(leaves) do if node.id == focused.id then leaf_index = candidate end end
  if not leaf_index then return {} end

  local target
  if axis == "main" then
    local target_column_id = state.strips[strip_index].columns[column_index + step]
    local target_leaves = column_leaves(index.columns[target_column_id], true)
    target = step < 0 and target_leaves[#target_leaves] or target_leaves[1]
  else
    target = leaves[leaf_index + step]
    if not target and kind == "focus" then
      local target_strip = state.strips[strip_index + step]
      if target_strip then
        local target_column_id = target_strip.columns[clamp(column_index, 1, #target_strip.columns)]
        local target_leaves = column_leaves(index.columns[target_column_id], true)
        target = step < 0 and target_leaves[#target_leaves] or target_leaves[1]
      end
    end
  end

  if kind == "focus" then
    local operation = focus_operation(target)
    return operation and { operation } or {}
  end
  if target then return { { name = "swap-nodes", first = focused.id, second = target.id } } end
  if axis ~= "cross" then return {} end

  local destination_index = strip_index + step
  local destination = state.strips[destination_index]
  if not destination then
    destination = new_strip(state)
    if destination_index < 1 then
      table.insert(state.strips, 1, destination)
      strip_index, destination_index = strip_index + 1, 1
    else
      state.strips[#state.strips + 1] = destination
      destination_index = #state.strips
    end
  end
  local all_leaves = column_leaves(column, false)
  if #all_leaves == 1 then
    table.remove(state.strips[strip_index].columns, column_index)
    table.insert(destination.columns, clamp(column_index, 1, #destination.columns + 1), column_id)
    compact_strips(state)
    return {}
  end
  state.pending[focused.window.id] = destination
  return { { name = "expel", node = focused.id, direction = "right" } }
end

local function axis_extent(rect, axis)
  if axis == "main" then return main_axis == "horizontal" and rect.width or rect.height end
  return main_axis == "horizontal" and rect.height or rect.width
end

local function logical_rect(main, cross, main_size, cross_size)
  if main_axis == "horizontal" then
    return { x = main, y = cross, width = main_size, height = cross_size }
  end
  return { x = cross, y = main, width = cross_size, height = main_size }
end

local function logical_components(rect)
  if main_axis == "horizontal" then return rect.x, rect.y, rect.width, rect.height end
  return rect.y, rect.x, rect.height, rect.width
end

local function screen_rect(virtual, usable, main_camera, cross_camera)
  local main, cross, main_size, cross_size = logical_components(virtual)
  main, cross = main - main_camera, cross - cross_camera
  local viewport_main, viewport_cross = axis_extent(usable, "main"), axis_extent(usable, "cross")
  if main_reverse then main = viewport_main - main - main_size end
  if cross_reverse then cross = viewport_cross - cross - cross_size end
  local rect = logical_rect(main, cross, main_size, cross_size)
  rect.x, rect.y = rect.x + usable.x, rect.y + usable.y
  return rect
end

local function target_for_metric(current, metric, index, count, total, viewport)
  if not metric then return 0 end
  local peek_total = peek + border_width
  local required_start = index > 1 and metric.start - inner_gap - peek_total or metric.start
  local required_end = index < count and metric.start + metric.size + inner_gap + peek_total
    or metric.start + metric.size
  local needed_start, needed_end = required_start - outer_gap, required_end + outer_gap
  local target = current
  if needed_end - needed_start > viewport then
    target = metric.start + (metric.size - viewport) / 2
  else
    if target + viewport < needed_end then target = needed_end - viewport end
    if target > needed_start then target = needed_start end
  end
  return clamp(target, 0, math.max(0, total - viewport))
end

local function ensure_camera(owner, key, initial, now)
  if not owner[key] then owner[key] = { from = initial, to = initial, started = now } end
  return owner[key]
end

local function layout(snapshot, sampled_camera)
  local usable = snapshot.output.usable
  local now = snapshot.clock.monotonic_ms
  assert(usable.width > 0 and usable.height > 0, "empty usable output")
  local state, index = sync_topology(snapshot)
  local entries, node_columns, strip_metrics = {}, {}, {}
  local viewport_main = axis_extent(usable, "main")
  local viewport_cross = axis_extent(usable, "cross")
  local base_main = math.max(1, viewport_main - 2 * (outer_gap + peek + border_width + inner_gap))
  local base_cross = math.max(1, #state.strips > 1
    and viewport_cross - 2 * (outer_gap + peek + border_width + inner_gap)
    or viewport_cross - outer_gap * 2 - border_width)
  local cross_cursor = outer_gap

  for strip_index, strip in ipairs(state.strips) do
    local main_cursor, metrics = outer_gap, {}
    local strip_cross = base_cross
    for _, column_id in ipairs(strip.columns) do
      local column = index.columns[column_id]
      if column and column.root and contains_tiled(column.root) then
        local minimum = measure(column.root)
        strip_cross = math.max(strip_cross,
          main_axis == "horizontal" and minimum.height or minimum.width)
      end
    end
    for _, column_id in ipairs(strip.columns) do
      local column = index.columns[column_id]
      if column and column.root and contains_tiled(column.root) then
        local minimum = measure(column.root)
        local minimum_main = main_axis == "horizontal" and minimum.width or minimum.height
        local requested = math.floor(base_main
          * clamp(column.width, min_column_width, max_column_width) + 0.5)
        local main_size = math.max(1, requested, minimum_main)
        metrics[#metrics + 1] = { id = column.id, start = main_cursor, size = main_size }
        local entry_start = #entries + 1
        local rect = logical_rect(main_cursor, cross_cursor + border_width, main_size, strip_cross)
        walk(column.root, column, rect, true, entries, node_columns)
        for entry_index = entry_start, #entries do entries[entry_index].strip_index = strip_index end
        main_cursor = main_cursor + main_size + inner_gap
      elseif column and column.root then
        local entry_start = #entries + 1
        walk(column.root, column, { x = 0, y = 0, width = 1, height = 1 }, true, entries, node_columns)
        for entry_index = entry_start, #entries do entries[entry_index].strip_index = strip_index end
      end
    end
    local total = #metrics == 0 and outer_gap * 2 or main_cursor - inner_gap + outer_gap
    strip.metrics, strip.total = metrics, total
    strip_metrics[strip_index] = { start = cross_cursor, size = strip_cross }
    cross_cursor = cross_cursor + strip_cross + inner_gap
  end
  local cross_total = #state.strips == 0 and outer_gap * 2 or cross_cursor - inner_gap + outer_gap

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
      if entry == fullscreen then entry.virtual = { x = 0, y = 0, width = usable.width, height = usable.height } end
    end
  end

  local focused_column = snapshot.tag.focused and node_columns[snapshot.tag.focused] or nil
  local focused_strip = focused_column and strip_location(state, focused_column) or nil
  local main_active, focused_main_current, focused_main_target, focused_main_total = false, 0, 0, viewport_main
  for strip_index, strip in ipairs(state.strips) do
    local camera = ensure_camera(strip, "camera", strip_index == 1 and sampled_camera or 0, now)
    local current = sample_number(camera, now)
    local metric, metric_index
    if strip_index == focused_strip then
      for candidate_index, candidate in ipairs(strip.metrics) do
        if candidate.id == focused_column then metric, metric_index = candidate, candidate_index end
      end
    end
    local target
    if fullscreen then
      target = 0
    elseif strip_index == focused_strip then
      target = target_for_metric(
        current, metric, metric_index or 0, #strip.metrics, strip.total, viewport_main)
    else
      target = camera.to
    end
    local active
    if fullscreen then
      camera.from, camera.to, camera.started, current, active = 0, 0, now, 0, false
    else current, active = animate_number(camera, target, now) end
    strip.camera_current, strip.camera_target = current, target
    main_active = main_active or active
    if strip_index == focused_strip then
      focused_main_current, focused_main_target, focused_main_total = current, target, strip.total
    end
  end

  local cross_camera = ensure_camera(state, "cross_camera", 0, now)
  local cross_current = sample_number(cross_camera, now)
  local cross_target = fullscreen and 0 or target_for_metric(
    cross_current, focused_strip and strip_metrics[focused_strip] or nil,
    focused_strip or 0, #state.strips, cross_total, viewport_cross)
  local cross_active
  if fullscreen then
    cross_camera.from, cross_camera.to, cross_camera.started, cross_current, cross_active = 0, 0, now, 0, false
  else cross_current, cross_active = animate_number(cross_camera, cross_target, now) end

  local motions = window_y_motion[snapshot.tag.id]
  if not motions then motions = {}; window_y_motion[snapshot.tag.id] = motions end
  local seen, window_active = {}, false
  for _, entry in ipairs(entries) do
    local virtual = entry.virtual
    local floating = entry.placement == "floating"
    seen[entry.window] = true
    local strip = state.strips[entry.strip_index or focused_strip or 1]
    local screen = floating and {
      x = virtual.x, y = virtual.y, width = virtual.width, height = virtual.height,
    } or screen_rect(virtual, usable, strip and strip.camera_current or 0, cross_current)
    local animated_y, active = animate_window_y(
      motions, entry.window, screen.y, now,
      main_axis == "horizontal" and #state.strips == 1
        and entry.visible and entry.placement == "tiled")
    window_active = window_active or active
    if main_axis == "horizontal" and not floating then screen.y = animated_y end
    local rendered = entry.actual or virtual
    entry.screen = {
      x = math.floor(screen.x), y = math.floor(screen.y),
      width = math.ceil(math.max(0, rendered.width)),
      height = math.ceil(math.max(0, rendered.height)),
    }
    entry.clip = entry.visible and clipped(entry.screen, usable)
      or { x = 0, y = 0, width = 0, height = 0 }
    entry.window_clip = entry.visible and clipped_window(entry.screen, usable)
      or { x = 0, y = 0, width = 0, height = 0 }
    entry.propose = entry.visible and entry.placement ~= "scratchpad"
      and entry.placement ~= "fullscreen"
    entry.focus_serial, entry.strip_index = nil, nil
  end
  for id in pairs(motions) do if not seen[id] then motions[id] = nil end end
  return {
    epoch = snapshot.epoch,
    tag = snapshot.tag.id,
    camera_current = focused_main_current,
    camera_target = focused_main_target,
    strip_width = focused_main_total,
    entries = entries,
    needs_frame = main_active or cross_active or window_active,
  }
end

local function projection_marks()
  local nodes, windows = {}, {}
  local names = {}
  for name in pairs(layout_marks) do names[#names + 1] = name end
  table.sort(names)
  local function add_badge(target, id, name)
    local badge = name == "primary" and "*" or name
    target[id] = target[id] and (target[id] .. "," .. badge) or badge
  end
  for _, name in ipairs(names) do
    local mark = layout_marks[name]
    for _, id in ipairs(mark.nodes) do add_badge(nodes, id, name) end
    for _, id in ipairs(mark.windows) do add_badge(windows, id, name) end
  end
  return nodes, windows
end

local function project_node(tokens, node, state, marked_nodes, marked_windows)
  if node.window then
    local window = node.window
    if window.lifecycle ~= "managed" or window.placement ~= "tiled" then return false end
    tokens[#tokens + 1] = {
      kind = "window", window = window.id,
      focused = state.focused_node == node.id,
      selected = state.selection and state.selection.kind == "node" and state.selection.id == node.id,
      mark = marked_windows[window.id],
    }
    return true
  end
  local start = #tokens
  tokens[#tokens + 1] = {
    kind = "group_open",
    label = node.mode == "tabbed" and "t" or node.axis == "horizontal" and "h" or "v",
    selected = state.selection and state.selection.kind == "node" and state.selection.id == node.id,
    mark = marked_nodes[node.id],
  }
  local has_window = false
  for _, child in ipairs(node.children) do
    has_window = project_node(tokens, child.node, state, marked_nodes, marked_windows) or has_window
  end
  if not has_window then
    while #tokens > start do table.remove(tokens) end
    return false
  end
  tokens[#tokens + 1] = { kind = "group_close" }
  return true
end

local function project(snapshot)
  local state, index = sync_topology(snapshot)
  state.focused_node = snapshot.tag.focused
  local tokens = {}
  local marked_nodes, marked_windows = projection_marks()
  local focused_column = snapshot.tag.focused and index.node_columns[snapshot.tag.focused] or nil

  for _, strip in ipairs(state.strips) do
    local start = #tokens
    local strip_marked = false
    for _, column_id in ipairs(strip.columns) do
      local column = index.columns[column_id]
      if column and column.root and marked_nodes[column.root.id] then
        strip_marked = strip_marked and (strip_marked .. "," .. marked_nodes[column.root.id])
          or marked_nodes[column.root.id]
      end
    end
    tokens[#tokens + 1] = {
      kind = "group_open", label = main_axis == "horizontal" and "h" or "v",
      selected = state.selection and state.selection.kind == "strip" and state.selection.id == strip.id,
      mark = strip_marked or nil,
    }
    local inserted = false
    for _, column_id in ipairs(strip.columns) do
      local column = index.columns[column_id]
      if column and column.root then project_node(tokens, column.root, state, marked_nodes, marked_windows) end
      if strip == state.current and column_id == focused_column then
        tokens[#tokens + 1] = { kind = "insertion", label = "+" }
        inserted = true
      end
    end
    if strip == state.current and not inserted then tokens[#tokens + 1] = { kind = "insertion", label = "+" } end
    if #tokens == start + 1 and strip ~= state.current then
      table.remove(tokens)
    else
      tokens[#tokens + 1] = { kind = "group_close" }
    end
  end

  for _, group in ipairs({
    { placement = "floating", label = "float" },
    { placement = "fullscreen", label = "full" },
    { placement = "scratchpad", label = "scratch" },
  }) do
    local group_start = #tokens
    tokens[#tokens + 1] = {
      kind = "group_open", label = group.label,
      selected = state.selection and state.selection.kind == "placement"
        and state.selection.placement == group.placement,
    }
    local has_window = false
    for _, column in ipairs(snapshot.tag.columns) do
      if column.root then walk_nodes(column.root, function(node)
        if node.window and node.window.lifecycle == "managed" and node.window.placement == group.placement then
          has_window = true
          tokens[#tokens + 1] = {
            kind = "window", window = node.window.id,
            focused = snapshot.tag.focused == node.id,
            selected = state.selection and state.selection.kind == "node" and state.selection.id == node.id,
            mark = marked_windows[node.window.id],
          }
        end
      end) end
    end
    if has_window then tokens[#tokens + 1] = { kind = "group_close" }
    else while #tokens > group_start do table.remove(tokens) end end
  end
  return tokens
end

return { layout = layout, action = action, project = project }

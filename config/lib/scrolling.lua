-- Example scrolling layout provider. This is user configuration, not
-- Whirlpool's installed standard library. The host supplies flat compositor
-- facts; every relationship between windows below is retained Lua state.

local peek, inner_gap, outer_gap = 16, 8, 4
local border_width, decoration_height = 4, 28
local min_root_width, max_root_width = 0.05, 4
local animation_duration_ms = 180
local main_axis, main_reverse, cross_reverse = "horizontal", false, false

local model = {
  tags = {}, nodes = {}, window_nodes = {}, windows = {}, marks = {},
  next_node_id = 1, next_strip_id = 1,
}
local action_checkpoint

local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function copy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local result = {}
  seen[value] = result
  for key, child in pairs(value) do result[copy(key, seen)] = copy(child, seen) end
  return result
end

local function node(id) return id and model.nodes[id] or nil end
local function new_node(kind)
  local id = model.next_node_id
  model.next_node_id = id + 1
  local result = { id = id, kind = kind, parent = nil }
  model.nodes[id] = result
  return result
end
local function new_leaf(window)
  local result = new_node("window")
  result.window = window
  model.window_nodes[window] = result.id
  return result
end
local function new_group(mode, axis)
  local result = new_node("group")
  result.mode, result.axis, result.active, result.children = mode or "split", axis or "vertical", 1, {}
  return result
end
local function new_strip()
  local result = { id = model.next_strip_id, roots = {} }
  model.next_strip_id = model.next_strip_id + 1
  return result
end
local function tag_state(id)
  if model.tags[id] then return model.tags[id] end
  local strip = new_strip()
  local result = { id = id, strips = { strip }, current = strip }
  model.tags[id] = result
  return result
end

local function child_index(parent, child_id)
  if not parent or parent.kind ~= "group" then return nil end
  for index, child in ipairs(parent.children) do if child.node == child_id then return index end end
end
local function walk(root_id, visit)
  local current = node(root_id)
  if not current then return end
  visit(current)
  if current.kind == "group" then for _, child in ipairs(current.children) do walk(child.node, visit) end end
end
local function leaves(root_id, visible_only, active, result)
  result = result or {}
  local current = node(root_id)
  if not current then return result end
  if current.kind == "window" then
    if not visible_only or active ~= false then result[#result + 1] = current end
  else
    for index, child in ipairs(current.children) do
      leaves(child.node, visible_only,
        active ~= false and (current.mode ~= "tabbed" or index == current.active), result)
    end
  end
  return result
end
local function active_leaf(root_id)
  local current = node(root_id)
  while current and current.kind == "group" do
    local child = current.children[clamp(current.active, 1, #current.children)]
    current = child and node(child.node) or nil
  end
  return current
end
local function is_ancestor(ancestor_id, candidate_id)
  local current = node(candidate_id)
  while current and current.parent do
    if current.parent == ancestor_id then return true end
    current = node(current.parent)
  end
  return false
end

local function root_location(wanted)
  for _, state in pairs(model.tags) do
    for strip_index, strip in ipairs(state.strips) do
      for root_index, slot in ipairs(strip.roots) do
        if slot.node == wanted then return state, strip, strip_index, root_index, slot end
      end
    end
  end
end
local function containing_root(id)
  local current = node(id)
  while current and current.parent do current = node(current.parent) end
  return current
end
local function location_for_node(id)
  local root = containing_root(id)
  if root then return root_location(root.id) end
end
local function replace_position(old_id, replacement_id)
  local old, replacement = node(old_id), node(replacement_id)
  if not old or not replacement then return false end
  if old.parent then
    local parent = node(old.parent)
    local index = child_index(parent, old.id)
    if not index then return false end
    parent.children[index].node, replacement.parent = replacement.id, parent.id
  else
    local _, _, _, _, slot = root_location(old.id)
    if not slot then return false end
    slot.node, replacement.parent = replacement.id, nil
  end
  return true
end
local function retire_group(group, replacement)
  model.nodes[group.id] = nil
  for _, mark in pairs(model.marks) do
    if mark.target and mark.target.kind == "node" and mark.target.id == group.id then
      mark.target = replacement and (replacement.kind == "window"
        and { kind = "window", window = replacement.window }
        or { kind = "node", id = replacement.id }) or nil
    end
  end
end
local function normalize(group_id)
  local group = node(group_id)
  if not group or group.kind ~= "group" then return end
  if #group.children > 1 then group.active = clamp(group.active, 1, #group.children); return end
  if #group.children == 1 then
    local only = node(group.children[1].node)
    local parent_id = group.parent
    if only and replace_position(group.id, only.id) then retire_group(group, only); normalize(parent_id) end
    return
  end
  local parent_id = group.parent
  if parent_id then
    local parent = node(parent_id)
    local index = child_index(parent, group.id)
    if index then table.remove(parent.children, index) end
  else
    local _, strip, _, index = root_location(group.id)
    if strip and index then table.remove(strip.roots, index) end
  end
  retire_group(group)
  normalize(parent_id)
end
local function detach(id)
  local current = node(id)
  if not current then return nil end
  if current.parent then
    local parent = node(current.parent)
    local index = child_index(parent, current.id)
    if not index then return nil end
    local child = table.remove(parent.children, index)
    current.parent = nil
    if parent.active > #parent.children then parent.active = math.max(1, #parent.children) end
    normalize(parent.id)
    return { node = current.id, weight = child.weight or 1 }
  end
  local _, strip, _, index, slot = root_location(current.id)
  if not strip then return { node = current.id, width = 0.5 } end
  table.remove(strip.roots, index)
  return { node = current.id, width = slot.width or 0.5 }
end
local function attach_root(state, strip, id, index, width)
  local current = node(id)
  if not current then return end
  current.parent = nil
  table.insert(strip.roots, clamp(index or #strip.roots + 1, 1, #strip.roots + 1), {
    node = id, width = clamp(width or 0.5, min_root_width, max_root_width),
  })
  state.current = strip
end
local function compact_strips(state)
  local kept = {}
  for _, strip in ipairs(state.strips) do
    if #strip.roots > 0 or strip == state.current then kept[#kept + 1] = strip end
  end
  if #kept == 0 then kept[1] = new_strip() end
  local found = false
  for _, strip in ipairs(kept) do if strip == state.current then found = true end end
  state.strips = kept
  if not found then state.current = kept[1] end
end
local function strip_by_id(state, id)
  for index, strip in ipairs(state.strips) do if strip.id == id then return strip, index end end
end

local function classify(fact)
  if fact.state and fact.state ~= "unplaced" then return fact.state end
  local hints = fact.size_hints or {}
  local minimum = hints.min or { width = hints.min_width or 0, height = hints.min_height or 0 }
  local maximum = hints.max or { width = hints.max_width or 0, height = hints.max_height or 0 }
  local fixed = minimum.width > 0 and minimum.height > 0
    and minimum.width == maximum.width and minimum.height == maximum.height
  if fact.transient or fixed then return "floating" end
  return "tiled"
end
local function remove_window(window)
  local leaf = node(model.window_nodes[window])
  if leaf then detach(leaf.id); model.nodes[leaf.id] = nil end
  model.window_nodes[window], model.windows[window] = nil, nil
  for name, mark in pairs(model.marks) do if mark.anchor_window == window then model.marks[name] = nil end end
end
local function current_insertion(state, focused_window)
  local strip, index = state.current, #state.current.roots + 1
  local root = containing_root(focused_window and model.window_nodes[focused_window])
  if root then
    local owner, candidate, _, root_index = root_location(root.id)
    if owner == state then strip, index = candidate, root_index + 1 end
  end
  return strip, index
end
local function sync(snapshot)
  local seen = {}
  for _, fact in ipairs(snapshot.windows or {}) do
    seen[fact.id], model.windows[fact.id] = true, fact
    if fact.lifecycle ~= "closed" then
      local leaf = node(model.window_nodes[fact.id]) or new_leaf(fact.id)
      leaf.state = leaf.state or classify(fact)
      leaf.tag = leaf.tag or fact.tag
      local state = tag_state(fact.tag)
      local owner = location_for_node(leaf.id)
      if leaf.state == "tiled" and not owner then
        local strip, index = current_insertion(state,
          snapshot.tag.id == fact.tag and snapshot.tag.focused_window or nil)
        attach_root(state, strip, leaf.id, index, 0.5)
      elseif leaf.state ~= "tiled" and owner then
        local root = containing_root(leaf.id)
        if root then detach(root.id) end
      end
    end
  end
  local stale = {}
  for window in pairs(model.windows) do if not seen[window] then stale[#stale + 1] = window end end
  for _, window in ipairs(stale) do remove_window(window) end
  for _, state in pairs(model.tags) do compact_strips(state) end
  local state, focused = tag_state(snapshot.tag.id), snapshot.tag.focused_window
  if state.focus and state.focus_anchor ~= focused then state.focus, state.focus_anchor = nil, nil end
  if focused then
    local current = node(model.window_nodes[focused])
    while current and current.parent do
      local parent = node(current.parent)
      parent.active = child_index(parent, current.id) or parent.active
      current = parent
    end
    local owner, strip = location_for_node(model.window_nodes[focused])
    if owner == state and strip then state.current = strip end
  end
  return state
end

local function focused_descriptor(state, snapshot)
  return state.focus or (snapshot.tag.focused_window and {
    kind = "window", window = snapshot.tag.focused_window,
  } or nil)
end
local function descriptor_node(target)
  if not target then return nil end
  if target.kind == "window" then return node(model.window_nodes[target.window]) end
  if target.kind == "node" then return node(target.id) end
end
local function descriptor_roots(state, target)
  if not target then return {} end
  local current = descriptor_node(target)
  if current then return { current.id } end
  local result = {}
  if target.kind == "strip" then
    local strip = strip_by_id(state, target.id)
    if strip then for _, slot in ipairs(strip.roots) do result[#result + 1] = slot.node end end
  elseif target.kind == "state" then
    for window, fact in pairs(model.windows) do
      local leaf = node(model.window_nodes[window])
      if leaf and leaf.tag == state.id and leaf.state == target.state then result[#result + 1] = leaf.id end
    end
  end
  return result
end
local function target_windows(state, target)
  local result, seen = {}, {}
  for _, root_id in ipairs(descriptor_roots(state, target)) do
    for _, leaf in ipairs(leaves(root_id, false, true)) do
      if not seen[leaf.window] then result[#result + 1], seen[leaf.window] = leaf.window, true end
    end
  end
  return result
end
local function set_focus(state, target, snapshot)
  state.focus, state.focus_anchor = target and copy(target) or nil,
    target and snapshot.tag.focused_window or nil
end
local function focus_parent(state, snapshot)
  local target, current = focused_descriptor(state, snapshot)
  current = descriptor_node(target)
  if current and current.parent then set_focus(state, { kind = "node", id = current.parent }, snapshot)
  elseif current then
    if current.state ~= "tiled" then
      set_focus(state, { kind = "state", state = current.state }, snapshot)
    else
      local _, strip = location_for_node(current.id)
      if strip then set_focus(state, { kind = "strip", id = strip.id }, snapshot) end
    end
  elseif target and target.kind == "state" then set_focus(state, nil, snapshot) end
end
local function focus_child(state, snapshot)
  local target = state.focus
  if not target then return end
  if target.kind == "strip" then
    local strip = strip_by_id(state, target.id)
    local leaf = strip and strip.roots[1] and active_leaf(strip.roots[1].node)
    set_focus(state, leaf and { kind = "window", window = leaf.window } or nil, snapshot)
  elseif target.kind == "node" then
    local current = node(target.id)
    local child = current and current.children[current.active]
    local next_node = child and node(child.node)
    set_focus(state, next_node and (next_node.kind == "window"
      and { kind = "window", window = next_node.window } or { kind = "node", id = next_node.id }) or nil, snapshot)
  elseif target.kind == "state" then
    local windows = target_windows(state, target)
    set_focus(state, windows[1] and { kind = "window", window = windows[1] } or nil, snapshot)
  else set_focus(state, nil, snapshot) end
end

local function physical_axis(direction)
  local horizontal, axis, step = main_axis == "horizontal"
  if direction == "left" then axis, step = horizontal and "main" or "cross", -1
  elseif direction == "right" then axis, step = horizontal and "main" or "cross", 1
  elseif direction == "up" then axis, step = horizontal and "cross" or "main", -1
  elseif direction == "down" then axis, step = horizontal and "cross" or "main", 1 end
  if axis == "main" and main_reverse then step = -step end
  if axis == "cross" and cross_reverse then step = -step end
  return axis, step
end
local function neighbor(state, start_id, direction)
  local axis, step = physical_axis(direction)
  local owner, strip, strip_index, root_index = location_for_node(start_id)
  if owner ~= state then return nil end
  local root = containing_root(start_id)
  if axis == "main" then
    local slot = strip.roots[root_index + step]
    return slot and active_leaf(slot.node), false, strip, root_index + step
  end
  local visible, leaf_index = leaves(root.id, true, true)
  for index, leaf in ipairs(visible) do if leaf.id == start_id then leaf_index = index end end
  if leaf_index and visible[leaf_index + step] then
    return visible[leaf_index + step], false, strip, root_index
  end
  local target_strip = state.strips[strip_index + step]
  local slot = target_strip and target_strip.roots[clamp(root_index, 1, #target_strip.roots)]
  return slot and active_leaf(slot.node), target_strip ~= nil, target_strip, root_index
end
local function swap_positions(first_id, second_id)
  if first_id == second_id or is_ancestor(first_id, second_id) or is_ancestor(second_id, first_id) then return end
  local first, second = node(first_id), node(second_id)
  if not first or not second then return end
  local first_parent, second_parent = node(first.parent), node(second.parent)
  local first_index = first_parent and child_index(first_parent, first.id)
  local second_index = second_parent and child_index(second_parent, second.id)
  local _, _, _, _, first_slot = root_location(first.id)
  local _, _, _, _, second_slot = root_location(second.id)
  if first_parent then first_parent.children[first_index].node = second.id else first_slot.node = second.id end
  if second_parent then second_parent.children[second_index].node = first.id else second_slot.node = first.id end
  first.parent, second.parent = second_parent and second_parent.id or nil, first_parent and first_parent.id or nil
end
local function wrap_pair(focused_id, other_id, axis, other_first)
  local focused, other = node(focused_id), node(other_id)
  if not focused or not other then return end
  local parent_id = focused.parent
  local _, _, _, _, slot = root_location(focused.id)
  detach(other.id)
  local group = new_group("split", axis)
  if parent_id then
    local parent = node(parent_id)
    parent.children[child_index(parent, focused.id)].node, group.parent = group.id, parent.id
  elseif slot then slot.node = group.id else retire_group(group); return end
  focused.parent, other.parent = group.id, group.id
  local a, b = { node = focused.id, weight = 1 }, { node = other.id, weight = 1 }
  group.children, group.active = other_first and { b, a } or { a, b }, other_first and 2 or 1
end
local function reparent(id, target_id)
  if id == target_id or is_ancestor(id, target_id) then return end
  local moved, target = node(id), node(target_id)
  if not moved or not target then return end
  local saved = detach(moved.id)
  if target.kind == "group" then
    moved.parent = target.id
    target.children[#target.children + 1] = { node = moved.id, weight = saved.weight or 1 }
    target.active = #target.children
  elseif target.parent then
    local parent = node(target.parent)
    local index = child_index(parent, target.id)
    moved.parent = parent.id
    table.insert(parent.children, index + 1, { node = moved.id, weight = saved.weight or 1 })
    parent.active = index + 1
  else
    local state, strip, _, index = root_location(target.id)
    if state then attach_root(state, strip, moved.id, index + 1, saved.width) end
  end
end
local function move_target(source, target, destination, strip, after)
  local roots, windows = descriptor_roots(source, target), target_windows(source, target)
  local index = after or #strip.roots + 1
  for _, id in ipairs(roots) do
    local saved = detach(id)
    local current = node(id)
    if saved and not (current.kind == "window" and current.state ~= "tiled") then
      attach_root(destination, strip, id, index, saved.width)
      index = index + 1
    end
    walk(id, function(candidate)
      if candidate.kind == "window" then candidate.tag = destination.id end
    end)
  end
  compact_strips(source); compact_strips(destination)
  return windows
end
local function move_effects(windows, tag, output)
  local result = {}
  for _, window in ipairs(windows) do
    result[#result + 1] = { name = "move-window", window = window, tag = tag, output = output }
  end
  return result
end

local function resolve_tag(snapshot, ordinal)
  local value = snapshot.tags and snapshot.tags[tonumber(ordinal)] or tonumber(ordinal)
  return type(value) == "table" and value.id or value
end

local function mutate_action(snapshot, request)
  local state = sync(snapshot)
  local target, name = focused_descriptor(state, snapshot), request.name
  if name == "focus-window" then
    local window = tonumber(request.args[1])
    if not window or not model.window_nodes[window] then return {} end
    set_focus(state, nil, snapshot)
    return { { name = "focus-window", window = window } }
  end
  if name == "focus-parent" then focus_parent(state, snapshot); return {} end
  if name == "focus-child" then focus_child(state, snapshot); return {} end
  if name == "close-focused" then
    local result = {}
    for _, window in ipairs(target_windows(state, target)) do result[#result + 1] = { name = "close-window", window = window } end
    return result
  end
  if name == "mark" then
    local mark_name = tostring(request.args[1] or "")
    if mark_name ~= "" and target then
      local windows = target_windows(state, target)
      model.marks[mark_name] = { tag = state.id, target = copy(target), anchor_window = windows[1] }
    end
    return {}
  end
  if name == "clear-mark" then model.marks[tostring(request.args[1] or "")] = nil; return {} end
  if name == "focus-mark" then
    local mark = model.marks[tostring(request.args[1] or "")]
    if not mark or not mark.anchor_window then return {} end
    local destination = tag_state(mark.tag)
    destination.focus, destination.focus_anchor = copy(mark.target), mark.anchor_window
    local result = {}
    if mark.tag ~= state.id then result[#result + 1] = { name = "set-active-tag", output = snapshot.output.id, tag = mark.tag } end
    result[#result + 1] = { name = "focus-window", window = mark.anchor_window }
    return result
  end
  if name == "summon-mark" then
    local mark = model.marks[tostring(request.args[1] or "")]
    if not mark or not mark.target then return {} end
    local windows = move_target(tag_state(mark.tag), mark.target, state, state.current)
    mark.tag, state.focus, state.focus_anchor = state.id, copy(mark.target), mark.anchor_window
    local result = move_effects(windows, state.id, snapshot.output.id)
    if mark.anchor_window then result[#result + 1] = { name = "focus-window", window = mark.anchor_window } end
    return result
  end
  if name == "send-to-mark" then
    local mark = model.marks[tostring(request.args[1] or "")]
    if not mark or not mark.target then return {} end
    for _, window in ipairs(target_windows(state, target)) do
      if window == mark.anchor_window then return {} end
    end
    local destination = tag_state(mark.tag)
    local marked, strip, marked_index = descriptor_node(mark.target)
    if marked then local _; _, strip, _, marked_index = location_for_node(marked.id) end
    strip = strip or destination.current
    local windows = move_target(state, target, destination, strip, marked_index and marked_index + 1)
    set_focus(state, nil, snapshot)
    return move_effects(windows, destination.id, destination.id == state.id and snapshot.output.id or nil)
  end
  if name == "focus-tag" then
    local id = resolve_tag(snapshot, request.args[1])
    if not id then return {} end
    local destination, result = tag_state(id), { { name = "set-active-tag", output = snapshot.output.id, tag = id } }
    local windows = target_windows(destination, destination.focus)
    if windows[1] then result[#result + 1] = { name = "focus-window", window = windows[1] } end
    return result
  end
  if name == "send-to-tag" then
    local id = resolve_tag(snapshot, request.args[1])
    if not id then return {} end
    local destination = tag_state(id)
    return move_effects(move_target(state, target, destination, destination.current), id, nil)
  end
  if name == "cycle-container-mode" then
    local current = descriptor_node(target)
    local group = current and (current.kind == "group" and current or node(current.parent))
    if group then
      if group.mode == "tabbed" then group.mode, group.axis = "split", "horizontal"
      elseif group.axis == "horizontal" then group.axis = "vertical"
      else group.mode, group.axis = "tabbed", "vertical" end
    end
    return {}
  end
  if name == "focus-tab-next" or name == "focus-tab-prev" then
    local current = descriptor_node(target)
    local group = current and node(current.parent)
    if group and group.mode == "tabbed" and #group.children > 1 then
      local step = name == "focus-tab-next" and 1 or -1
      group.active = (group.active - 1 + step) % #group.children + 1
      local leaf = active_leaf(group.children[group.active].node)
      return leaf and { { name = "focus-window", window = leaf.window } } or {}
    end
    return {}
  end
  if name == "grow-width" or name == "shrink-width" then
    local current, slot = descriptor_node(target)
    local root = current and containing_root(current.id)
    if root then local _; _, _, _, _, slot = root_location(root.id) end
    if slot then
      local presets, nearest = { 0.25, 0.5, 0.75, 1, 1.5, 2 }, 1
      for index, value in ipairs(presets) do
        if math.abs(value - slot.width) < math.abs(presets[nearest] - slot.width) then nearest = index end
      end
      nearest = clamp(nearest + (name == "grow-width" and 1 or -1), 1, #presets)
      slot.width = presets[nearest]
    end
    return {}
  end
  if name == "toggle-float" or name == "toggle-fullscreen" then
    local desired, result = name == "toggle-fullscreen" and "fullscreen" or "floating", {}
    for _, window in ipairs(target_windows(state, target)) do
      local leaf = node(model.window_nodes[window])
      local next_state = leaf.state == desired and "tiled" or desired
      if next_state ~= "tiled" then
        local root = containing_root(leaf.id); if root then detach(root.id) end
      elseif not location_for_node(leaf.id) then attach_root(state, state.current, leaf.id, nil, 0.5) end
      leaf.state = next_state
      result[#result + 1] = { name = "set-window-state", window = window, state = next_state }
    end
    return result
  end
  if name == "focus-output-next" or name == "focus-output-prev" then
    local outputs, current_index = snapshot.outputs or {}, nil
    for index, output in ipairs(outputs) do if output.id == snapshot.output.id then current_index = index end end
    if not current_index or #outputs < 2 then return {} end
    local step = name == "focus-output-next" and 1 or -1
    local destination = outputs[(current_index - 1 + step) % #outputs + 1]
    local destination_state = tag_state(destination.active_tag)
    local windows = target_windows(destination_state, destination_state.focus)
    local wanted = windows[1]
    if not wanted then for _, tag in ipairs(snapshot.tags or {}) do
      if tag.id == destination.active_tag then wanted = tag.focused_window end
    end end
    return wanted and { { name = "focus-window", window = wanted } } or {}
  end

  local verb, direction = name:match("^(focus)%-(.+)$")
  if not verb then verb, direction = name:match("^(swap)%-(.+)$") end
  if direction ~= "left" and direction ~= "right" and direction ~= "up" and direction ~= "down" then
    verb, direction = nil, nil
  end
  if verb then
    local current = descriptor_node(target)
    local start = current and (current.kind == "window" and current or active_leaf(current.id))
    local adjacent, crossed, crossed_strip, crossed_index
    if start then adjacent, crossed, crossed_strip, crossed_index = neighbor(state, start.id, direction) end
    if verb == "focus" then
      set_focus(state, nil, snapshot)
      return adjacent and { { name = "focus-window", window = adjacent.window } } or {}
    end
    if not current then return {} end
    if crossed then
      local saved = detach(current.id)
      if saved then attach_root(state, crossed_strip, current.id, crossed_index, saved.width) end
      compact_strips(state)
      return {}
    end
    if adjacent then swap_positions(current.id, adjacent.id); return {} end
    local axis, step = physical_axis(direction)
    if axis == "cross" then
      local _, _, strip_index, root_index = location_for_node(current.id)
      local destination = state.strips[strip_index + step]
      if not destination then
        destination = new_strip()
        table.insert(state.strips, clamp(strip_index + step, 1, #state.strips + 1), destination)
      end
      local saved = detach(current.id)
      if saved then attach_root(state, destination, current.id, root_index, saved.width) end
      compact_strips(state)
    end
    return {}
  end

  local structural, direction = name:match("^(absorb)%-(.+)$")
  if not structural then structural, direction = name:match("^(expel)%-(.+)$") end
  if direction ~= "left" and direction ~= "right" and direction ~= "up" and direction ~= "down" then
    structural, direction = nil, nil
  end
  local current = descriptor_node(target)
  if structural == "absorb" and current then
    local start = current.kind == "window" and current or active_leaf(current.id)
    local adjacent = start and neighbor(state, start.id, direction)
    if adjacent then
      local axis, step = physical_axis(direction)
      local split_axis = axis == "main" and (main_axis == "horizontal" and "vertical" or "horizontal")
        or (main_axis == "horizontal" and "horizontal" or "vertical")
      wrap_pair(current.id, adjacent.id, split_axis, step < 0)
    end
    return {}
  end
  if (name == "eject" or structural == "expel") and current then
    if not current.parent then return {} end
    local _, strip, _, root_index = location_for_node(current.id)
    local saved = detach(current.id)
    local step = 1
    if direction then local _; _, step = physical_axis(direction) end
    if saved and strip then attach_root(state, strip, current.id, root_index + (step > 0 and 1 or 0), 0.5) end
    return {}
  end
  if name == "reparent" then
    local mark = model.marks[tostring(request.args[1] or "")]
    local destination = mark and descriptor_node(mark.target)
    if current and destination then reparent(current.id, destination.id) end
    return {}
  end
  return {}
end

-- Structural actions stage the complete controller graph. A Lua error cannot
-- leave half of a mutation behind, and the host acknowledges the complete
-- action batch only after every returned leaf effect has applied atomically.
local function begin_actions()
  assert(action_checkpoint == nil, "action batch already active")
  action_checkpoint = model
end
local function action(snapshot, request)
  local previous = model
  model = copy(model)
  local ok, result = pcall(mutate_action, snapshot, request)
  if not ok then
    model = previous
    error(result)
  end
  return result
end
local function finish_actions(commit)
  assert(action_checkpoint ~= nil, "no action batch active")
  if not commit then model = action_checkpoint end
  action_checkpoint = nil
end

local function ease_out_cubic(progress)
  local remaining = 1 - progress
  return 1 - remaining * remaining * remaining
end
local function sample_motion(motion, now)
  if motion.from == motion.to then return motion.to, false end
  local progress = clamp((now - motion.started) / animation_duration_ms, 0, 1)
  if progress >= 1 then motion.from = motion.to; return motion.to, false end
  return motion.from + (motion.to - motion.from) * ease_out_cubic(progress), true
end
local function animate(owner, key, target, now)
  local motion = owner[key]
  if not motion then motion = { from = target, to = target, started = now }; owner[key] = motion end
  local current = sample_motion(motion, now)
  if target ~= motion.to then motion.from, motion.to, motion.started = current, target, now end
  return sample_motion(motion, now)
end

local function window_minimum(fact)
  local hints = fact.size_hints or {}
  local minimum = hints.min or { width = hints.min_width or 0, height = hints.min_height or 0 }
  local width, height = minimum.width or 0, minimum.height or 0
  -- An actual size larger than the last proposal is an observed constraint,
  -- not merely stale geometry. Feed it back through the same recursive
  -- constraint calculation so every sibling sharing that extent agrees.
  if fact.actual and fact.proposed then
    if fact.actual.width > fact.proposed.width then width = math.max(width, fact.actual.width) end
    if fact.actual.height > fact.proposed.height then height = math.max(height, fact.actual.height) end
  end
  return {
    width = width > 0 and width + 2 * border_width or 0,
    height = height > 0 and height + decoration_height + 2 * border_width or 0,
  }
end
local function minimum_for(root_id)
  local current = node(root_id)
  if not current then return { width = 0, height = 0 } end
  if current.kind == "window" then return window_minimum(model.windows[current.window] or {}) end
  local width, height = 0, 0
  for index, child in ipairs(current.children) do
    local child_minimum = minimum_for(child.node)
    if current.mode == "tabbed" then
      width, height = math.max(width, child_minimum.width), math.max(height, child_minimum.height)
    elseif current.axis == "horizontal" then
      width, height = width + child_minimum.width, math.max(height, child_minimum.height)
      if index > 1 then width = width + inner_gap end
    else
      width, height = math.max(width, child_minimum.width), height + child_minimum.height
      if index > 1 then height = height + inner_gap end
    end
  end
  return { width = width, height = height }
end
local function distribute(children, available, horizontal)
  local sizes, minimums, minimum_total, weight_total = {}, {}, 0, 0
  for index, child in ipairs(children) do
    local minimum = minimum_for(child.node)
    minimums[index] = horizontal and minimum.width or minimum.height
    minimum_total = minimum_total + minimums[index]
    weight_total = weight_total + (child.weight or 1)
  end
  assert(weight_total > 0, "non-empty group must have positive weight")
  local total, used = math.max(minimum_total, available), 0
  for index, child in ipairs(children) do
    sizes[index] = minimums[index]
      + math.floor((total - minimum_total) * (child.weight or 1) / weight_total)
    used = used + sizes[index]
  end
  local index = 1
  while used < total do
    sizes[index], used, index = sizes[index] + 1, used + 1, index % #sizes + 1
  end
  return sizes
end
local function layout_node(root_id, rect, active, entries, z)
  local current = node(root_id)
  if not current then return z end
  if current.kind == "window" then
    local fact = model.windows[current.window]
    if not fact then return z end
    entries[#entries + 1] = {
      window = current.window, state = current.state, frame = rect,
      propose = {
        width = math.max(1, rect.width - 2 * border_width),
        height = math.max(1, rect.height - decoration_height - 2 * border_width),
      },
      visible = active and fact.lifecycle == "managed", z = z,
    }
    return z + 1
  end
  if current.mode == "tabbed" then
    for index, child in ipairs(current.children) do
      z = layout_node(child.node, rect, active and index == current.active, entries, z)
    end
    return z
  end
  local horizontal = current.axis == "horizontal"
  local available = horizontal and rect.width or rect.height
  local gap = math.min(inner_gap, math.max(0, available))
  local sizes = distribute(current.children,
    math.max(0, available - gap * math.max(0, #current.children - 1)), horizontal)
  local cursor = horizontal and rect.x or rect.y
  for index, child in ipairs(current.children) do
    local extent = sizes[index]
    local child_rect = horizontal
      and { x = cursor, y = rect.y, width = extent, height = rect.height }
      or { x = rect.x, y = cursor, width = rect.width, height = extent }
    z = layout_node(child.node, child_rect, active, entries, z)
    cursor = cursor + extent + gap
  end
  return z
end

local function logical_rect(main, cross, main_size, cross_size)
  if main_axis == "horizontal" then
    return { x = main, y = cross, width = main_size, height = cross_size }
  end
  return { x = cross, y = main, width = cross_size, height = main_size }
end
local function components(rect)
  if main_axis == "horizontal" then return rect.x, rect.y, rect.width, rect.height end
  return rect.y, rect.x, rect.height, rect.width
end
local function axis_extent(rect, axis)
  if axis == "main" then return main_axis == "horizontal" and rect.width or rect.height end
  return main_axis == "horizontal" and rect.height or rect.width
end
local function screen_rect(target, usable, main_camera, cross_camera)
  local main, cross, main_size, cross_size = components(target)
  main, cross = main - main_camera, cross - cross_camera
  if main_reverse then main = axis_extent(usable, "main") - main - main_size end
  if cross_reverse then cross = axis_extent(usable, "cross") - cross - cross_size end
  local result = logical_rect(main, cross, main_size, cross_size)
  result.x, result.y = result.x + usable.x, result.y + usable.y
  return result
end
local function content_rect(frame)
  return {
    x = frame.x + border_width,
    y = frame.y + decoration_height + border_width,
    width = math.max(1, frame.width - 2 * border_width),
    height = math.max(1, frame.height - decoration_height - 2 * border_width),
  }
end
local function camera_target(current, metric, index, count, total, viewport)
  if not metric then return 0 end
  local extra = peek + border_width
  local first = index > 1 and metric.start - inner_gap - extra or metric.start
  local last = index < count and metric.start + metric.size + inner_gap + extra
    or metric.start + metric.size
  local result = current
  if last - first > viewport then result = metric.start + (metric.size - viewport) / 2
  else
    if result + viewport < last + outer_gap then result = last + outer_gap - viewport end
    if result > first - outer_gap then result = first - outer_gap end
  end
  return clamp(result, 0, math.max(0, total - viewport))
end
local function clipped(screen, usable, chrome)
  local frame = chrome and {
    x = screen.x - border_width, y = screen.y - decoration_height - border_width,
    width = screen.width + 2 * border_width,
    height = screen.height + decoration_height + 2 * border_width,
  } or screen
  local left, top = math.max(frame.x, usable.x), math.max(frame.y, usable.y)
  local right = math.min(frame.x + frame.width, usable.x + usable.width)
  local bottom = math.min(frame.y + frame.height, usable.y + usable.height)
  if right <= left or bottom <= top then return { x = 0, y = 0, width = 0, height = 0 } end
  return { x = left - screen.x, y = top - screen.y, width = right - left, height = bottom - top }
end

local function layout(snapshot)
  local state = sync(snapshot)
  local usable, now = snapshot.output.usable, snapshot.clock.monotonic_ms
  assert(usable.width > 0 and usable.height > 0, "empty usable output")
  local viewport_main, viewport_cross = axis_extent(usable, "main"), axis_extent(usable, "cross")
  local base_main = math.max(1, viewport_main - 2 * (outer_gap + peek + border_width + inner_gap))
  local base_cross = math.max(1, #state.strips > 1
    and viewport_cross - 2 * (outer_gap + peek + border_width + inner_gap)
    or viewport_cross - 2 * outer_gap - border_width)
  local entries, strip_metrics, cross_cursor, z = {}, {}, outer_gap, 1
  for strip_index, strip in ipairs(state.strips) do
    local strip_cross, main_cursor, metrics = base_cross, outer_gap, {}
    for _, slot in ipairs(strip.roots) do
      local minimum = minimum_for(slot.node)
      strip_cross = math.max(strip_cross,
        main_axis == "horizontal" and minimum.height or minimum.width)
    end
    for _, slot in ipairs(strip.roots) do
      local minimum = minimum_for(slot.node)
      local minimum_main = main_axis == "horizontal" and minimum.width or minimum.height
      local size = math.max(1,
        math.floor(base_main * clamp(slot.width, min_root_width, max_root_width) + 0.5), minimum_main)
      metrics[#metrics + 1] = { node = slot.node, start = main_cursor, size = size }
      z = layout_node(slot.node,
        logical_rect(main_cursor, cross_cursor, size, strip_cross), true, entries, z)
      main_cursor = main_cursor + size + inner_gap
    end
    strip.metrics = metrics
    strip.total = #metrics == 0 and 2 * outer_gap or main_cursor - inner_gap + outer_gap
    strip_metrics[strip_index] = { start = cross_cursor, size = strip_cross }
    cross_cursor = cross_cursor + strip_cross + inner_gap
  end
  local cross_total = cross_cursor - inner_gap + outer_gap
  local focused_root = containing_root(snapshot.tag.focused_window
    and model.window_nodes[snapshot.tag.focused_window])
  local focused_strip, focused_strip_index
  if focused_root then
    local _
    _, focused_strip, focused_strip_index = root_location(focused_root.id)
  end
  local active = false
  for _, strip in ipairs(state.strips) do
    local metric, metric_index
    if strip == focused_strip then
      for index, candidate in ipairs(strip.metrics) do
        if candidate.node == focused_root.id then metric, metric_index = candidate, index end
      end
    end
    local current = strip.camera and sample_motion(strip.camera, now) or 0
    local target = strip == focused_strip
      and camera_target(current, metric, metric_index or 0, #strip.metrics, strip.total, viewport_main)
      or (strip.camera and strip.camera.to or 0)
    local moving
    strip.camera_current, moving = animate(strip, "camera", target, now)
    active = active or moving
  end
  local cross_current = state.cross_camera and sample_motion(state.cross_camera, now) or 0
  local cross_target = camera_target(cross_current,
    focused_strip_index and strip_metrics[focused_strip_index] or nil,
    focused_strip_index or 0, #state.strips, cross_total, viewport_cross)
  local cross_moving
  cross_current, cross_moving = animate(state, "cross_camera", cross_target, now)
  active = active or cross_moving

  local fullscreen, fullscreen_serial = nil, -1
  for window, fact in pairs(model.windows) do
    local leaf = node(model.window_nodes[window])
    if leaf and leaf.tag == state.id and leaf.state ~= "tiled" then
      local geometry = leaf.state == "fullscreen" and copy(usable) or copy(fact.floating or {
        x = usable.x + math.floor(usable.width / 4), y = usable.y + math.floor(usable.height / 4),
        width = math.max(1, math.floor(usable.width / 2)),
        height = math.max(1, math.floor(usable.height / 2)),
      })
      entries[#entries + 1] = {
        window = window, state = leaf.state, frame = geometry,
        propose = leaf.state == "fullscreen" and { width = geometry.width, height = geometry.height } or nil,
        visible = leaf.state ~= "scratchpad" and fact.lifecycle == "managed", z = z,
      }
      z = z + 1
      if leaf.state == "fullscreen" and (fact.focus_serial or 0) >= fullscreen_serial then
        fullscreen, fullscreen_serial = window, fact.focus_serial or 0
      end
    end
  end
  if fullscreen then for _, entry in ipairs(entries) do entry.visible = entry.window == fullscreen end end
  for _, entry in ipairs(entries) do
    local fact = model.windows[entry.window] or {}
    local leaf = node(model.window_nodes[entry.window])
    local root = containing_root(model.window_nodes[entry.window])
    local strip
    if root then local _; _, strip = root_location(root.id) end
    local frame = entry.frame
    if entry.state == "tiled" and leaf then
      local moving_x, moving_y
      frame = copy(frame)
      frame.x, moving_x = animate(leaf, "frame_x", frame.x, now)
      frame.y, moving_y = animate(leaf, "frame_y", frame.y, now)
      active = active or moving_x or moving_y
    end
    local target = entry.state == "tiled"
      and screen_rect(content_rect(frame), usable, strip and strip.camera_current or 0, cross_current)
      or frame
    local actual = fact.actual or entry.propose or { width = target.width, height = target.height }
    entry.screen = {
      x = math.floor(target.x), y = math.floor(target.y),
      width = math.max(1, math.ceil(actual.width)), height = math.max(1, math.ceil(actual.height)),
    }
    entry.clip = entry.visible and clipped(entry.screen, usable, false)
      or { x = 0, y = 0, width = 0, height = 0 }
    entry.window_clip = entry.visible and clipped(entry.screen, usable, true)
      or { x = 0, y = 0, width = 0, height = 0 }
    local focused = entry.window == snapshot.tag.focused_window
    entry.border = {
      edges = 0xf, width = border_width,
      rgba = focused
        and { 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff }
        or { 0x64646464, 0x64646464, 0x64646464, 0xffffffff },
    }
    entry.decoration_height = decoration_height
    entry.frame = nil
  end
  return {
    epoch = snapshot.epoch, output = snapshot.output.id, tag = snapshot.tag.id,
    entries = entries, needs_frame = active,
  }
end

local function mark_badges()
  local nodes, windows, strips, names = {}, {}, {}, {}
  for name in pairs(model.marks) do names[#names + 1] = name end
  table.sort(names)
  local function add(target, id, name)
    if not id then return end
    target[id] = string.sub(target[id] and (target[id] .. "," .. name) or name, 1, 24)
  end
  for _, name in ipairs(names) do
    local target = model.marks[name].target
    if target then
      if target.kind == "window" then add(windows, target.window, name)
      elseif target.kind == "node" then add(nodes, target.id, name)
      elseif target.kind == "strip" then add(strips, target.id, name) end
    end
  end
  return nodes, windows, strips
end
local function append_item(items, style, text, focused, detail, window, width, action)
  items[#items + 1] = {
    style = style, text = text or "", focused = focused == true,
    detail = detail or "", window = window, width = width, action = action,
    args = action and window and { tostring(window) } or nil,
  }
end
local function append_open(items, label, selected, mark)
  local text = "( " .. label .. (mark and mark ~= "" and " " .. mark or "")
  append_item(items, "group", text, selected, "", nil, math.max(46, 24 + #text * 9))
end
local function append_close(items)
  append_item(items, "group", ")", false, "", nil, 18)
end
local function project_node(items, id, focus, node_marks, window_marks)
  local current = node(id)
  if not current then return end
  if current.kind == "window" then
    append_item(items, "window", "",
      focus and focus.kind == "window" and focus.window == current.window,
      window_marks[current.window], current.window, 148, "focus-window")
    return
  end
  append_open(items,
    current.mode == "tabbed" and "t" or current.axis == "horizontal" and "h" or "v",
    focus and focus.kind == "node" and focus.id == current.id,
    node_marks[current.id])
  for _, child in ipairs(current.children) do
    project_node(items, child.node, focus, node_marks, window_marks)
  end
  append_close(items)
end
local function project(snapshot)
  local state = sync(snapshot)
  local focus = focused_descriptor(state, snapshot)
  local node_marks, window_marks, strip_marks = mark_badges()
  local items = {}
  local focused_root = containing_root(snapshot.tag.focused_window
    and model.window_nodes[snapshot.tag.focused_window])
  for _, strip in ipairs(state.strips) do
    append_open(items, main_axis == "horizontal" and "h" or "v",
      focus and focus.kind == "strip" and focus.id == strip.id,
      strip_marks[strip.id])
    local inserted = false
    for _, slot in ipairs(strip.roots) do
      project_node(items, slot.node, focus, node_marks, window_marks)
      if strip == state.current and focused_root and slot.node == focused_root.id then
        append_item(items, "insertion", "+", false, "", nil, 18)
        inserted = true
      end
    end
    if strip == state.current and not inserted then
      append_item(items, "insertion", "+", false, "", nil, 18)
    end
    append_close(items)
  end
  for _, wanted in ipairs({
    { state = "floating", label = "float" },
    { state = "fullscreen", label = "full" },
    { state = "scratchpad", label = "scratch" },
  }) do
    local start = #items
    append_open(items, wanted.label,
      focus and focus.kind == "state" and focus.state == wanted.state)
    for window, fact in pairs(model.windows) do
      local leaf = node(model.window_nodes[window])
      if leaf and leaf.tag == state.id and leaf.state == wanted.state then
        append_item(items, "window", "",
          focus and focus.kind == "window" and focus.window == window,
          window_marks[window], window, 148, "focus-window")
      end
    end
    if #items == start + 1 then table.remove(items)
    else append_close(items) end
  end
  return items
end

return {
  layout = layout, action = action, project = project,
  begin_actions = begin_actions, finish_actions = finish_actions,
}

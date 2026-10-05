-- Example scrolling layout provider. This is user configuration, not
-- Whirlpool's installed standard library. The host supplies flat compositor
-- facts; every relationship between windows below is retained Lua state.

local peek, inner_gap, outer_gap = 16, 8, 4
local border_width, decoration_height = 4, 28
local min_root_width, max_root_width = 0.05, 4
-- Column widths, as fractions of the viewport, that width actions step through
-- (`options.widths`).
local widths = { 0.25, 1 / 3, 0.5, 2 / 3, 0.75, 1 }
local animation_duration_ms = 180
-- When the focused window itself moves, the camera follows this much later, so
-- the window is seen to move rather than everything else around it.
local camera_lag_ms = 90
-- When a window moves to another strip, the strip it left closes the gap this
-- much later, once it has gone, while the strip it joins makes room at once.
local stagger_ms = 90
-- Above every other window: the one being dragged by its title bar.
local dragged_z = 100000
-- While dragging, the pointer held this close to a monitor's edge (having
-- moved towards it) acts after `edge_dwell_ms`, and again sooner each time it
-- stays, down to `edge_repeat_min_ms`: along the rows the view steps one
-- window that way; across them the window moves to the next row.
local edge_zone = 64
local edge_dwell_ms, edge_repeat_min_ms = 450, 150
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
-- Whether a window is drawn. A closing window keeps its place until River
-- destroys it: the client may decline (to ask about unsaved work, say).
local function shown(fact)
  return fact.lifecycle == "managed" or fact.lifecycle == "closing"
end
local function remove_window(window)
  local leaf = node(model.window_nodes[window])
  if leaf then detach(leaf.id); model.nodes[leaf.id] = nil end
  model.window_nodes[window], model.windows[window] = nil, nil
  if model.screens then model.screens[window] = nil end
  if model.drag and model.drag.window == window then model.drag = nil end
  for name, mark in pairs(model.marks) do if mark.anchor_window == window then model.marks[name] = nil end end
end
-- A new tiled window opens just before `anchor_window`, at its level: beside
-- it in its group, or as a column before its column. Without an anchor in this
-- tag's strips it opens at the end of the current strip.
local function insert_new(state, leaf_id, anchor_window)
  local anchor = node(anchor_window and model.window_nodes[anchor_window])
  local owner, strip, _, root_index = nil, nil, nil, nil
  if anchor then owner, strip, _, root_index = location_for_node(anchor.id) end
  if owner ~= state then attach_root(state, state.current, leaf_id, nil, 0.5); return end
  if not anchor.parent then attach_root(state, strip, leaf_id, root_index, 0.5); return end
  local parent, leaf = node(anchor.parent), node(leaf_id)
  local index = child_index(parent, anchor.id)
  table.insert(parent.children, index, { node = leaf_id, weight = 1 })
  leaf.parent = parent.id
  -- The tab shown stays shown; focus, not insertion, decides what is active.
  if parent.active >= index then parent.active = parent.active + 1 end
  state.current = strip
end

-- Persistence -------------------------------------------------------------
-- The retained model can be written out and read back so a restart of the
-- window manager keeps the arrangement. Windows are named by the compositor's
-- stable identifier, never by our own ids (which do not survive a restart).
-- Loading is best effort: whatever no longer matches is simply dropped, and
-- windows the file does not know about are placed as new windows are.

-- Nodes are written as they are: every plain field (string, number, boolean) they
-- carry goes into the file, so a field added to nodes later is persisted without
-- touching this code. Only what refers to this process (ids, parent links, the
-- window and its tag) is left out or translated. Reading applies the same rule
-- in reverse, then checks the fields it knows the meaning of.
local RUNTIME_FIELDS = {
  id = true, parent = true, tag = true, kind = true, window = true, children = true, node = true,
  automatic = true, anchor = true, strip = true,
}

local function plain_fields(source)
  local out = {}
  for key, value in pairs(source) do
    local kind = type(value)
    if type(key) == "string" and not RUNTIME_FIELDS[key]
      and (kind == "string" or kind == "number" or kind == "boolean") then
      out[key] = value
    end
  end
  return out
end

local function apply_fields(target, saved)
  for key, value in pairs(plain_fields(saved)) do target[key] = value end
end

local function serialize_tree(id)
  local current = node(id)
  if not current then return nil end
  local out = plain_fields(current)
  if current.kind == "window" then
    local fact = model.windows[current.window]
    if not fact or (fact.identifier or "") == "" then return nil end
    out.window = fact.identifier
    return out
  end
  local children = {}
  for _, child in ipairs(current.children) do
    local saved = serialize_tree(child.node)
    if saved then
      local entry = plain_fields(child)
      entry.node = saved
      children[#children + 1] = entry
    end
  end
  if #children == 0 then return nil end
  out.children = children
  out.active = clamp(current.active or 1, 1, #children)
  return out
end

-- The file is JSON: a real, dumb format with a real reader. Nothing in it is
-- ever executed. Encoding sorts keys, so identical models give identical text and
-- an unchanged one is never rewritten.
local function json_encode(value, out)
  local kind = type(value)
  if kind == "string" then
    out[#out + 1] = '"' .. value:gsub('[%c"\\]', function(c)
      return string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif kind == "number" then out[#out + 1] = string.format("%.17g", value)
  elseif kind == "boolean" then out[#out + 1] = tostring(value)
  elseif kind == "table" then
    if value[1] ~= nil or next(value) == nil then
      out[#out + 1] = "["
      for index, item in ipairs(value) do
        if index > 1 then out[#out + 1] = "," end
        json_encode(item, out)
      end
      out[#out + 1] = "]"
    else
      local keys = {}
      for key in pairs(value) do keys[#keys + 1] = key end
      table.sort(keys)
      out[#out + 1] = "{"
      for index, key in ipairs(keys) do
        if index > 1 then out[#out + 1] = "," end
        json_encode(key, out)
        out[#out + 1] = ":"
        json_encode(value[key], out)
      end
      out[#out + 1] = "}"
    end
  else out[#out + 1] = "null" end
end

local MAX_STATE_BYTES = 1024 * 1024
local MAX_JSON_DEPTH = 64
local json_escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

-- Returns the decoded value, or nil for anything that is not well-formed JSON
-- (or is too large or too deeply nested to be ours).
local function json_decode(text)
  if type(text) ~= "string" or #text > MAX_STATE_BYTES then return nil end
  local position, depth = 1, 0
  local function fail() error("bad json", 0) end
  local function skip() position = text:find("[^ \t\r\n]", position) or #text + 1 end
  local function peek() return text:sub(position, position) end
  local function read_string()
    local out = {}
    position = position + 1
    while true do
      local stop = text:find('["\\]', position)
      if not stop then fail() end
      out[#out + 1] = text:sub(position, stop - 1)
      if text:sub(stop, stop) == '"' then
        position = stop + 1
        return table.concat(out)
      end
      local code = text:sub(stop + 1, stop + 1)
      if code == "u" then
        local hex = text:match("^%x%x%x%x", stop + 2)
        if not hex then fail() end
        out[#out + 1] = utf8 and utf8.char(tonumber(hex, 16)) or "?"
        position = stop + 6
      else
        out[#out + 1] = json_escapes[code] or fail()
        position = stop + 2
      end
    end
  end
  local read_value
  local function read_container(close, item)
    depth = depth + 1
    if depth > MAX_JSON_DEPTH then fail() end
    position = position + 1
    skip()
    if peek() == close then
      position = position + 1
      depth = depth - 1
      return
    end
    while true do
      item()
      skip()
      local separator = peek()
      position = position + 1
      if separator == close then break elseif separator ~= "," then fail() end
    end
    depth = depth - 1
  end
  function read_value()
    skip()
    local c = peek()
    if c == "{" then
      local result = {}
      read_container("}", function()
        skip()
        if peek() ~= '"' then fail() end
        local key = read_string()
        skip()
        if peek() ~= ":" then fail() end
        position = position + 1
        result[key] = read_value()
      end)
      return result
    elseif c == "[" then
      local result, count = {}, 0
      read_container("]", function()
        count = count + 1
        result[count] = read_value()
      end)
      return result
    elseif c == '"' then return read_string()
    elseif text:find("^true", position) then position = position + 4; return true
    elseif text:find("^false", position) then position = position + 5; return false
    elseif text:find("^null", position) then position = position + 4; return nil end
    local number = text:match("^-?%d+%.?%d*[eE]?[+-]?%d*", position)
    local parsed = number and tonumber(number)
    if not parsed then fail() end
    position = position + #number
    return parsed
  end
  local ok, result = pcall(function()
    local value = read_value()
    skip()
    if position <= #text then fail() end
    return value
  end)
  if ok then return result end
  return nil
end

local function serialize_model()
  local data = { version = 1, tags = {}, states = {}, marks = {} }
  local ordinals = {}
  for tag_id, state in pairs(model.tags) do
    local ordinal = model.tag_ordinal and model.tag_ordinal[tag_id]
    if ordinal then
      local strips, current = {}, 1
      for _, strip in ipairs(state.strips) do
        local roots = {}
        for _, slot in ipairs(strip.roots) do
          local saved = serialize_tree(slot.node)
          if saved then
            local entry = plain_fields(slot)
            entry.node = saved
            roots[#roots + 1] = entry
          end
        end
        if #roots > 0 then
          strips[#strips + 1] = { roots = roots }
          if strip == state.current then current = #strips end
        end
      end
      if #strips > 0 then
        ordinals[#ordinals + 1] = ordinal
        data.tags[ordinal] = { ordinal = ordinal, current = current, strips = strips }
      end
    end
  end
  for window, fact in pairs(model.windows) do
    local leaf = node(model.window_nodes[window])
    if leaf and leaf.state ~= "tiled" and (fact.identifier or "") ~= "" then
      data.states[fact.identifier] = leaf.state
    end
  end
  for name, mark in pairs(model.marks) do
    local target = mark.target
    local fact = target and target.kind == "window" and model.windows[target.window]
    local ordinal = model.tag_ordinal and model.tag_ordinal[mark.tag]
    if fact and (fact.identifier or "") ~= "" and ordinal then
      data.marks[name] = { window = fact.identifier, tag = ordinal }
    end
  end
  -- Tags are a list in ordinal order, not a sparse table.
  table.sort(ordinals)
  local tags = {}
  for _, ordinal in ipairs(ordinals) do tags[#tags + 1] = data.tags[ordinal] end
  data.tags = tags
  local out = {}
  json_encode(data, out)
  return table.concat(out)
end

-- The text to persist, or nil when nothing worth writing has changed.
local function save()
  if not model.dirty then return nil end
  model.dirty = false
  local text = serialize_model()
  if text == model.saved_text then return nil end
  model.saved_text = text
  return text
end

-- Read a previous session's file.
local function restore(text)
  local data = json_decode(text)
  if type(data) ~= "table" or data.version ~= 1 then return false end
  model.saved = data
  return true
end

-- Rebuild the saved arrangement over the windows that are present now. This is
-- best effort, piece by piece: a tag, a subtree, a mark or a window's state that
-- makes no sense is skipped and everything else still applies.
local function restore_saved_unchecked(snapshot)
  local saved = model.saved
  local present = {}
  for _, fact in ipairs(snapshot.windows or {}) do
    if (fact.identifier or "") ~= "" then present[fact.identifier] = fact end
  end
  -- Windows may not have been announced yet; keep waiting for the first batch.
  if next(present) == nil then return end
  model.saved = nil

  -- Numbers from a file may be anything; keep them finite and in range.
  local function number_in(value, low, high, fallback)
    if type(value) ~= "number" or value ~= value then return fallback end
    return clamp(value, low, high)
  end
  local function list(value) return type(value) == "table" and value or {} end
  local known_states = { tiled = true, floating = true, fullscreen = true }
  local used = {} -- a window has one place; repeats in the file are dropped

  local function build(tree, tag_id, depth)
    if type(tree) ~= "table" or depth > MAX_JSON_DEPTH then return nil end
    if tree.window ~= nil then
      local fact = present[tree.window]
      -- A window now on another tag has lost its place here.
      if not fact or fact.tag ~= tag_id or used[fact.id] then return nil end
      used[fact.id] = true
      local leaf = node(model.window_nodes[fact.id]) or new_leaf(fact.id)
      apply_fields(leaf, tree)
      if not known_states[leaf.state] then leaf.state = classify(fact) end
      leaf.tag = fact.tag
      return leaf
    end
    local children = {}
    for _, child in ipairs(list(tree.children)) do
      local built = type(child) == "table" and build(child.node, tag_id, depth + 1)
      if built then
        local entry = { node = built.id }
        apply_fields(entry, child)
        entry.weight = number_in(entry.weight, 0.2, 5, 1)
        children[#children + 1] = entry
      end
    end
    if #children == 0 then return nil end
    if #children == 1 then
      local only = node(children[1].node)
      only.parent = nil
      return only
    end
    local group = new_group()
    apply_fields(group, tree)
    group.mode = group.mode == "tabbed" and "tabbed" or "split"
    group.axis = group.axis == "horizontal" and "horizontal" or "vertical"
    group.children, group.active = children, math.floor(number_in(group.active, 1, #children, 1))
    for _, child in ipairs(children) do node(child.node).parent = group.id end
    return group
  end

  local function restore_tag(saved_tag)
    local tag_id = model.tag_by_ordinal and model.tag_by_ordinal[saved_tag.ordinal]
    if not tag_id then return end
    local strips, current = {}, nil
    for index, saved_strip in ipairs(list(saved_tag.strips)) do
      local strip = new_strip()
      for _, saved_root in ipairs(list(list(saved_strip).roots)) do
        local built = type(saved_root) == "table" and build(saved_root.node, tag_id, 1)
        if built then
          local slot = { node = built.id }
          apply_fields(slot, saved_root)
          slot.width = number_in(slot.width, min_root_width, max_root_width, 0.5)
          strip.roots[#strip.roots + 1] = slot
        end
      end
      if #strip.roots > 0 then
        strips[#strips + 1] = strip
        if index == saved_tag.current then current = strip end
      end
    end
    if #strips > 0 then
      local state = tag_state(tag_id)
      state.strips, state.current = strips, current or strips[1]
    end
  end

  for _, saved_tag in ipairs(list(saved.tags)) do
    if type(saved_tag) == "table" then
      -- If one tag's data defeats us, forget what it built and carry on with the rest.
      local first_node = model.next_node_id
      local before = {}
      for id in pairs(used) do before[id] = true end
      if not pcall(restore_tag, saved_tag) then
        for id, item in pairs(model.nodes) do
          if id >= first_node then
            model.nodes[id] = nil
            if item.kind == "window" then model.window_nodes[item.window] = nil end
          end
        end
        for id in pairs(used) do if not before[id] then used[id] = nil end end
      end
    end
  end
  -- Windows that were floating or fullscreen have no place in a strip.
  for identifier, state_name in pairs(list(saved.states)) do
    local fact = present[identifier]
    if fact and not node(model.window_nodes[fact.id]) then
      local leaf = new_leaf(fact.id)
      leaf.state, leaf.tag = known_states[state_name] and state_name or classify(fact), fact.tag
    end
  end
  for name, mark in pairs(list(saved.marks)) do
    local fact = type(mark) == "table" and present[mark.window]
    if fact then
      model.marks[name] = { tag = fact.tag, target = { kind = "window", window = fact.id }, anchor_window = fact.id }
    end
  end
end

-- Last resort, for a failure the piecewise handling above did not anticipate:
-- throw away whatever was built and start as a new session.
local function restore_saved(snapshot)
  local ok = pcall(restore_saved_unchecked, snapshot)
  if ok then return end
  model.saved = nil
  model.tags, model.nodes, model.window_nodes, model.marks = {}, {}, {}, {}
end


-- The window nearest `leaf_id` other than `excluded` ones; defined with the
-- navigation helpers below.
local nearest_window

local function sync(snapshot)
  -- Tag ordinals are what persist across restarts (ids do not).
  model.tag_ordinal, model.tag_by_ordinal = {}, {}
  for ordinal, tag in ipairs(snapshot.tags or {}) do
    model.tag_ordinal[tag.id], model.tag_by_ordinal[ordinal] = ordinal, tag.id
  end
  -- Window facts only change when the world does, and every output asks with the
  -- same epoch, so reconciling the model with them happens once per change
  -- rather than once per call (per output, per animation frame).
  if model.synced_epoch ~= snapshot.epoch then
    model.synced_epoch = snapshot.epoch
    model.dirty = true
    if model.saved then restore_saved(snapshot) end
    local seen = {}
    -- Which roots are already placed in a strip, found in one pass: asking
    -- root_location per window would scan every strip for each of them.
    local placed = {}
    for _, state in pairs(model.tags) do
      for _, strip in ipairs(state.strips) do
        for _, slot in ipairs(strip.roots) do placed[slot.node] = true end
      end
    end
    for _, fact in ipairs(snapshot.windows or {}) do
      seen[fact.id], model.windows[fact.id] = true, fact
      local leaf = node(model.window_nodes[fact.id]) or new_leaf(fact.id)
      -- A window's place follows what it says of itself until something places
      -- it otherwise: a parent or fixed size can arrive after it first appears.
      local automatic = classify(fact)
      if not leaf.state or leaf.state == leaf.automatic then leaf.state = automatic end
      leaf.automatic = automatic
      leaf.tag = leaf.tag or fact.tag
      local state = tag_state(fact.tag)
      local root = containing_root(leaf.id)
      local owner = root and placed[root.id]
      if leaf.state == "tiled" and not owner then
        -- The anchor is the window focused before this one appeared: a new
        -- window is usually focused already, before it has a place.
        if leaf.anchor == nil then
          local focused = snapshot.tag.id == fact.tag and snapshot.tag.focused_window or nil
          local focused_root = containing_root(focused and model.window_nodes[focused])
          leaf.anchor = focused_root and placed[focused_root.id] and focused or state.last_focused or false
        end
        -- Tiled only by guess, it waits for its answer to a first proposal:
        -- only then does a dialog without a parent say its size is fixed.
        if fact.actual or (fact.state and fact.state ~= "unplaced") then
          insert_new(state, leaf.id, leaf.anchor or nil)
          leaf.anchor = nil
          placed[leaf.id] = true
        end
      elseif leaf.state ~= "tiled" and owner then
        detach(root.id)
        placed[root.id] = nil
      end
    end
    local stale = {}
    for window in pairs(model.windows) do if not seen[window] then stale[#stale + 1] = window end end
    for _, window in ipairs(stale) do
      -- Focus that leaves with its window passes to the window nearest it.
      local leaf = node(model.window_nodes[window])
      local owner = leaf and leaf.tag and model.tags[leaf.tag]
      if owner and owner.last_focused == window then
        owner.last_focused = nearest_window(owner, leaf.id, { [window] = true })
      end
      remove_window(window)
    end
  end
  for _, state in pairs(model.tags) do compact_strips(state) end
  local state, focused = tag_state(snapshot.tag.id), snapshot.tag.focused_window
  if state.focus and state.focus_anchor ~= focused then state.focus, state.focus_anchor = nil, nil end
  if focused then
    state.last_focused = focused
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
-- The window focus passes to when `leaf_id` goes: the one taking its place
-- (the next in its container, else those before it), else another from the
-- container above, and so on up the tree; at the top, the column taking its
-- place in the row, else the one before; then the nearest other rows.
nearest_window = function(state, leaf_id, excluded)
  local function usable(id)
    local active = active_leaf(id)
    if active and active.window and not excluded[active.window] then return active.window end
    for _, leaf in ipairs(leaves(id)) do
      if leaf.window and not excluded[leaf.window] then return leaf.window end
    end
  end
  local function from(list, index)
    for position = index + 1, #list do
      local window = usable(list[position].node)
      if window then return window end
    end
    for position = index - 1, 1, -1 do
      local window = usable(list[position].node)
      if window then return window end
    end
  end
  local current = node(leaf_id)
  while current and current.parent do
    local parent = node(current.parent)
    local window = parent and from(parent.children, child_index(parent, current.id) or 0)
    if window then return window end
    current = parent
  end
  local owner, strip, strip_index, root_index = nil, nil, nil, nil
  if current then owner, strip, strip_index, root_index = root_location(current.id) end
  if owner ~= state or not strip then return nil end
  local window = from(strip.roots, root_index)
  if window then return window end
  for distance = 1, #state.strips do
    for _, step in ipairs({ distance, -distance }) do
      local other = state.strips[strip_index + step]
      if other then
        local nearest = math.min(root_index, #other.roots)
        window = other.roots[nearest] and usable(other.roots[nearest].node) or from(other.roots, nearest)
        if window then return window end
      end
    end
  end
end
-- Dragging by the title bar ---------------------------------------------------
-- A dragged tiled window follows the pointer while the others make room, as in
-- a sortable list (`drag_reorder`); the cameras hold, panning near the edges.
-- The right button cancels, putting everything back.
-- A tile's window, inside its title bar and borders.
local function content_rect(frame)
  return {
    x = frame.x + border_width,
    y = frame.y + decoration_height + border_width,
    width = math.max(1, frame.width - 2 * border_width),
    height = math.max(1, frame.height - decoration_height - 2 * border_width),
  }
end
-- `model.screens` holds where each tiled window's tile (title bar and borders
-- included) rests on screen, as last laid out.
local function inside(rect, x, y)
  return x >= rect.x and x < rect.x + rect.width and y >= rect.y and y < rect.y + rect.height
end
local function container_horizontal(parent)
  if parent then return parent.mode == "tabbed" or parent.axis == "horizontal" end
  return main_axis == "horizontal"
end
-- Whether a container's children run against the screen axis they lie on.
local function reversed(horizontal)
  local main = horizontal == (main_axis == "horizontal")
  return main and main_reverse or (not main and cross_reverse)
end
-- The pointer at (x, y) during a drag of `leaf`, over another tile. Its
-- leading or trailing quarter along the rows puts the window beside that
-- tile's column, there and then; its middle proposes stacking the two in that
-- column, the window taking the half the pointer is in (`model.drag.group`),
-- done on the drop. Over the window's own tile, or nothing, nothing changes;
-- a move never leaves the pointer over a place that would undo it.
local function drag_reorder(state, leaf, x, y)
  local drag, screens = model.drag, model.screens or {}
  local own = screens[leaf.window]
  if not own or not drag then return end
  if drag.group and model.drop_slot and inside(model.drop_slot, x, y) then return end
  if inside(own, x, y) then drag.group = nil; return end
  local over, rect
  for window, candidate_rect in pairs(screens) do
    local candidate = window ~= leaf.window and node(model.window_nodes[window])
    if candidate and candidate.tag == leaf.tag and candidate.state == "tiled"
      and inside(candidate_rect, x, y) then over, rect = candidate, candidate_rect; break end
  end
  if not over then drag.group = nil; return end
  local along_x = main_axis == "horizontal"
  local start, extent = along_x and rect.x or rect.y, along_x and rect.width or rect.height
  local fraction = ((along_x and x or y) - start) / extent
  if fraction > 0.25 and fraction < 0.75 then
    local cross_start = along_x and rect.y or rect.x
    local cross_extent = along_x and rect.height or rect.width
    drag.group = { target = over.window, first = (along_x and y or x) < cross_start + cross_extent / 2 }
    return
  end
  drag.group = nil
  local after = (fraction >= 0.75) ~= main_reverse
  if not leaf.parent then
    local _, strip, _, from = root_location(leaf.id)
    local _, over_strip, _, over_index = root_location(containing_root(over.id).id)
    if strip and strip == over_strip then
      local to = over_index + (after and 1 or 0)
      if from < to then to = to - 1 end
      if to ~= from then table.insert(strip.roots, to, table.remove(strip.roots, from)) end
      return
    end
  end
  local saved = detach(leaf.id)
  if not saved then return end
  -- Leaving a group can dissolve it: find `over`'s column afresh.
  local _, strip, _, index = root_location(containing_root(over.id).id)
  if strip then attach_root(state, strip, leaf.id, index + (after and 1 or 0), saved.width) end
  compact_strips(state)
end
-- Drop `leaf` stacked with `target` in its column, first or second on screen.
local function stack_with(state, leaf, target, first)
  if not target or target == leaf then return end
  if not detach(leaf.id) then return end
  local axis = main_axis == "horizontal" and "vertical" or "horizontal"
  local before = first ~= reversed(axis == "horizontal")
  local parent = target.parent and node(target.parent)
  if parent and parent.mode ~= "tabbed" and parent.axis == axis then
    local index = child_index(parent, target.id) + (before and 0 or 1)
    table.insert(parent.children, index, { node = leaf.id, weight = 1 })
    leaf.parent = parent.id
    parent.active = index
  else
    local group = new_group("split", axis)
    replace_position(target.id, group.id)
    target.parent, leaf.parent = group.id, group.id
    group.children = before and { { node = leaf.id, weight = 1 }, { node = target.id, weight = 1 } }
      or { { node = target.id, weight = 1 }, { node = leaf.id, weight = 1 } }
    group.active = before and 1 or 2
  end
  compact_strips(state)
end
-- Move the dragged `leaf` to the next row `direction` (-1, 1) of its own, a
-- new one past the last, under the pointer at `along` on the rows' axis.
local function shift_row(state, leaf, direction, along)
  local root = containing_root(leaf.id)
  local _, strip, strip_index = root_location(root.id)
  if not strip then return end
  local destination = state.strips[strip_index + direction]
  if not destination then
    destination = new_strip()
    table.insert(state.strips, direction > 0 and #state.strips + 1 or 1, destination)
  end
  local index = #destination.roots + 1
  for position, metric in ipairs(destination.metrics or {}) do
    if along < metric.start + metric.size / 2 then index = position; break end
  end
  local saved = detach(leaf.id)
  if saved then attach_root(state, destination, leaf.id, index, saved.width) end
  compact_strips(state)
end
-- Whether the pointer has now been held at an edge (`direction` not 0) long
-- enough to act there, timing each edge (`key`) separately.
local function dwelled(drag, key, direction, now)
  local edge = drag[key]
  if direction == 0 then drag[key] = nil; return false end
  if not edge or edge.direction ~= direction then
    drag[key] = { direction = direction, since = now, count = 0 }
    return false
  end
  if now - edge.since < math.max(edge_repeat_min_ms, edge_dwell_ms * 0.75 ^ edge.count) then return false end
  edge.since, edge.count = now, edge.count + 1
  return true
end
-- The window `direction` (left, right, up, down) of `from` on screen: of the
-- tiles lying that way, one sharing some of its extent across the motion, the
-- nearest, then the one sharing most; failing any, the least out of line.
-- Only tiles laid out on screen count, so a hidden tab is never chosen;
-- and only on tag `tag` (default: `from`'s). Positions are global, so this
-- also finds where focus enters a neighbouring monitor.
local function toward(from, direction, tag)
  local screens = model.screens or {}
  local origin = screens[from.window]
  if not origin then return nil end
  local horizontal = direction == "left" or direction == "right"
  local forward = direction == "right" or direction == "down"
  local best, best_overlap, best_gap
  for window, rect in pairs(screens) do
    local candidate = window ~= from.window and node(model.window_nodes[window])
    if candidate and candidate.tag == (tag or from.tag) and candidate.state == "tiled" then
      local gap
      if horizontal then
        gap = forward and rect.x - (origin.x + origin.width) or origin.x - (rect.x + rect.width)
      else
        gap = forward and rect.y - (origin.y + origin.height) or origin.y - (rect.y + rect.height)
      end
      if gap > -inner_gap then
        local overlap = horizontal
          and math.min(origin.y + origin.height, rect.y + rect.height) - math.max(origin.y, rect.y)
          or math.min(origin.x + origin.width, rect.x + rect.width) - math.max(origin.x, rect.x)
        local better
        if not best then
          better = true
        elseif (overlap > 0) ~= (best_overlap > 0) then
          better = overlap > 0
        elseif overlap > 0 then
          better = gap < best_gap - 0.5 or (math.abs(gap - best_gap) <= 0.5 and overlap > best_overlap)
        else
          better = overlap > best_overlap or (overlap == best_overlap and gap < best_gap)
        end
        if better then best, best_overlap, best_gap = candidate, overlap, gap end
      end
    end
  end
  return best and best.window
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

-- Focus moves to `output`: to the window last focused on its active tag (where
-- its camera is centred), else its first window. If the monitor has no window it is focused on
-- its own (keyboard focus clears). Only windows the compositor actually shows
-- there qualify (a window is on whichever output shows its tag).
local function focus_output(snapshot, output, exclude)
  local visible, first = {}, nil
  for _, fact in ipairs(snapshot.windows or {}) do
    if fact.lifecycle == "managed" and fact.tag == output.active_tag and not (exclude and exclude[fact.id]) then
      visible[fact.id] = true
      first = first or fact.id
    end
  end
  local state = tag_state(output.active_tag)
  local wanted = state.last_focused and visible[state.last_focused] and state.last_focused or nil
  local strips = { state.current }
  for _, strip in ipairs(state.strips) do strips[#strips + 1] = strip end
  for _, strip in ipairs(strips) do
    if wanted then break end
    for _, slot in ipairs(strip.roots) do
      local leaf = active_leaf(slot.node)
      if leaf and leaf.window and visible[leaf.window] then wanted = leaf.window; break end
    end
  end
  wanted = wanted or first
  if wanted then return { { name = "focus-window", window = wanted } } end
  return { { name = "focus-output", output = output.id } }
end

-- Monitors in physical reading order, so "next" means the one to the right.
local function outputs_by_position(snapshot)
  local list = {}
  for _, output in ipairs(snapshot.outputs or {}) do list[#list + 1] = output end
  table.sort(list, function(a, b)
    if a.bounds.x ~= b.bounds.x then return a.bounds.x < b.bounds.x end
    if a.bounds.y ~= b.bounds.y then return a.bounds.y < b.bounds.y end
    return a.id < b.id
  end)
  return list
end

-- The nearest monitor in `direction` from the focused one, preferring one
-- that shares an edge over one that only lies that way.
local function output_toward(snapshot, direction)
  local from = snapshot.output.bounds
  local horizontal = direction == "left" or direction == "right"
  local best, best_key
  for _, output in ipairs(snapshot.outputs or {}) do
    if output.id ~= snapshot.output.id then
      local b = output.bounds
      local distance
      if direction == "left" then distance = from.x - (b.x + b.width)
      elseif direction == "right" then distance = b.x - (from.x + from.width)
      elseif direction == "up" then distance = from.y - (b.y + b.height)
      else distance = b.y - (from.y + from.height) end
      if distance >= 0 then
        local low = math.max(horizontal and from.y or from.x, horizontal and b.y or b.x)
        local high = math.min(horizontal and from.y + from.height or from.x + from.width,
          horizontal and b.y + b.height or b.x + b.width)
        local overlap = math.max(0, high - low)
        local key = { overlap > 0 and 0 or 1, distance, -overlap }
        local better = not best_key
        if best_key then
          for i = 1, 3 do
            if key[i] ~= best_key[i] then better = key[i] < best_key[i]; break end
          end
        end
        if better then best, best_key = output, key end
      end
    end
  end
  return best
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
  -- The host's report of a title-bar drag: the pointer's total motion since
  -- the press, then "drop" on release.
  -- `place-window <window> before|after|first|last <key>`: move a tiled
  -- window to a place named by a projected item's key (`window:<id>`,
  -- `node:<id>`, `strip:<id>`), as the bar does when a window is dragged in it.
  if name == "place-window" then
    local leaf = node(model.window_nodes[tonumber(request.args[1])])
    local relation, key = request.args[2], request.args[3] or ""
    if not leaf or leaf.state ~= "tiled" then return {} end
    local kind, id = key:match("^(%a+):(%d+)$")
    id = tonumber(id)
    local target
    if kind == "window" then target = node(model.window_nodes[id])
    elseif kind == "node" then target = node(id)
    elseif kind == "strip" then target = strip_by_id(state, id) end
    if not target or target == leaf then return {} end
    -- Taking the window out can dissolve the group it is placed against
    -- (its own, left with one member): that member takes the group's place.
    local parent = leaf.parent and node(leaf.parent)
    local survivor
    if parent and target == parent and #parent.children == 2 then
      for _, child in ipairs(parent.children) do
        if child.node ~= leaf.id then survivor = node(child.node) end
      end
    end
    local saved = detach(leaf.id)
    if not saved then return {} end
    if kind ~= "strip" and not node(target.id) then
      target = survivor
      if relation == "first" then relation = "before" elseif relation == "last" then relation = "after" end
    end
    if not target then attach_root(state, state.current, leaf.id, nil, saved.width); return {} end
    if kind == "strip" then
      attach_root(state, target, leaf.id, relation == "first" and 1 or nil, saved.width)
    elseif (relation == "first" or relation == "last") and target.kind == "group" then
      local index = relation == "first" and 1 or #target.children + 1
      table.insert(target.children, index, { node = leaf.id, weight = 1 })
      leaf.parent = target.id
    elseif target.parent then
      local group = node(target.parent)
      local index = child_index(group, target.id) + (relation == "after" and 1 or 0)
      table.insert(group.children, index, { node = leaf.id, weight = 1 })
      leaf.parent = group.id
      if group.active >= index then group.active = group.active + 1 end
    else
      local _, strip, _, index = root_location(target.id)
      if strip then attach_root(state, strip, leaf.id, index + (relation == "after" and 1 or 0), saved.width) end
    end
    compact_strips(state)
    return {}
  end
  if name == "drag-window" then
    -- `drag-window <window> <dx> <dy> move|drop|cancel [<x> <y>]`: the
    -- pointer's motion since the press at (x, y) on the window's title bar.
    local window = tonumber(request.args[1])
    local dx, dy = tonumber(request.args[2]) or 0, tonumber(request.args[3]) or 0
    local phase = request.args[4]
    local leaf, fact = node(model.window_nodes[window]), model.windows[window]
    if not leaf or not fact then model.drag = nil; return {} end
    local drag = model.drag
    if not drag or drag.window ~= window then
      local tile = model.screens and model.screens[window]
      local origin = tile and content_rect(tile)
      local grab_x, grab_y = tonumber(request.args[5]), tonumber(request.args[6])
      drag = {
        window = window, floating = fact.floating and copy(fact.floating), origin = origin,
        -- Everything as it was, for a cancel.
        saved = copy(model),
        pointer = origin and {
          x = grab_x and origin.x - border_width + grab_x or origin.x + origin.width / 2,
          y = grab_y and origin.y - border_width - decoration_height + grab_y or origin.y + origin.height / 2,
        },
      }
      model.drag = drag
    end
    drag.dx, drag.dy = dx, dy
    if phase == "cancel" then
      local shift = leaf.drag_shift
      model = drag.saved
      model.synced_epoch = nil
      local restored = node(model.window_nodes[window])
      if restored and restored.state == "tiled" then restored.settle = shift end
      if leaf.state == "floating" and drag.floating then
        return { { name = "set-floating-geometry", window = window, geometry = drag.floating } }
      end
      return {}
    end
    local result, owner = {}, model.tags[leaf.tag]
    if leaf.state == "floating" and drag.floating then
      local geometry = copy(drag.floating)
      geometry.x, geometry.y = geometry.x + dx, geometry.y + dy
      result[1] = { name = "set-floating-geometry", window = window, geometry = geometry }
    elseif leaf.state == "tiled" and drag.pointer and owner then
      drag_reorder(owner, leaf, drag.pointer.x + dx, drag.pointer.y + dy)
    end
    if phase == "drop" then
      if leaf.state == "tiled" and drag.group and owner then
        stack_with(owner, leaf, node(model.window_nodes[drag.group.target]), drag.group.first)
      end
      leaf.settle = leaf.drag_shift
      leaf.drag_shift, model.drag = nil, nil
    end
    return result
  end
  -- `pan-<direction>`: move the view a window (along the rows) or a row
  -- (across them) that way on screen, and keep it there while focus stays
  -- put; `recenter` brings it back to the focused window.
  local pan = name:match("^pan%-(%a+)$")
  if pan == "left" or pan == "right" or pan == "up" or pan == "down" then
    local horizontal = pan == "left" or pan == "right"
    local axis = horizontal == (main_axis == "horizontal") and "main" or "cross"
    local forward = (pan == "right" or pan == "down") ~= (axis == "main" and main_reverse or axis == "cross" and cross_reverse)
    state.pan, state.pinned = { axis = axis, step = forward and 1 or -1 }, true
    return {}
  end
  if name == "recenter" then state.pinned, state.pan = nil, nil; return {} end
  -- The host's report that the focused window went away on its own (the
  -- client exited): focus passes to where it was, as on close-focused.
  if name == "focus-successor" then
    if snapshot.tag.focused_window then return {} end
    return focus_output(snapshot, snapshot.output)
  end
  if name == "focus-parent" then focus_parent(state, snapshot); return {} end
  if name == "focus-child" then focus_child(state, snapshot); return {} end
  if name == "close-focused" then
    local result, closing = {}, {}
    for _, window in ipairs(target_windows(state, target)) do
      result[#result + 1] = { name = "close-window", window = window }
      closing[window] = true
    end
    if not next(closing) then return result end
    -- Focus moves to the nearest window that stays: one sharing the column,
    -- then a neighbouring column, else whatever this monitor would focus.
    local current = descriptor_node(target)
    local start = current and (current.kind == "window" and current or active_leaf(current.id))
    local successor = start and nearest_window(state, start.id, closing)
    set_focus(state, nil, snapshot)
    if successor then
      result[#result + 1] = { name = "focus-window", window = successor }
    else
      for _, effect in ipairs(focus_output(snapshot, snapshot.output, closing)) do result[#result + 1] = effect end
    end
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
    -- A tag is shown on one output at a time: asking for one that another
    -- output shows just moves focus there.
    for _, output in ipairs(snapshot.outputs or {}) do
      if output.id ~= snapshot.output.id and output.active_tag == id then
        return focus_output(snapshot, output)
      end
    end
    local destination, result = tag_state(id), { { name = "set-active-tag", output = snapshot.output.id, tag = id } }
    local windows = target_windows(destination, destination.focus)
    if windows[1] then result[#result + 1] = { name = "focus-window", window = windows[1] } end
    return result
  end
  if name == "send-to-tag" then
    local id = resolve_tag(snapshot, request.args[1])
    if not id then return {} end
    local destination = tag_state(id)
    local moved = move_target(state, target, destination, destination.current)
    local result = move_effects(moved, id, nil)
    if id ~= snapshot.tag.id then
      -- The windows leave this monitor; keyboard focus stays on it.
      local leaving = {}
      for _, window in ipairs(moved) do leaving[window] = true end
      for _, effect in ipairs(focus_output(snapshot, snapshot.output, leaving)) do result[#result + 1] = effect end
    end
    return result
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
  if name == "cycle-width" or name == "grow-width" or name == "shrink-width" then
    local current, slot = descriptor_node(target)
    local root = current and containing_root(current.id)
    if root then local _; _, _, _, _, slot = root_location(root.id) end
    if slot then
      -- Step from the preset nearest the current width. Cycling wraps around;
      -- growing and shrinking stop at the ends.
      local nearest = 1
      for index, value in ipairs(widths) do
        if math.abs(value - slot.width) < math.abs(widths[nearest] - slot.width) then nearest = index end
      end
      if name == "cycle-width" then nearest = nearest % #widths + 1
      else nearest = clamp(nearest + (name == "grow-width" and 1 or -1), 1, #widths) end
      slot.width = widths[nearest]
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
    local outputs, current_index = outputs_by_position(snapshot), nil
    for index, output in ipairs(outputs) do if output.id == snapshot.output.id then current_index = index end end
    if not current_index or #outputs < 2 then return {} end
    local step = name == "focus-output-next" and 1 or -1
    local destination = outputs[(current_index - 1 + step) % #outputs + 1]
    return focus_output(snapshot, destination)
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
      local window = start and toward(start, direction)
      if window then return { { name = "focus-window", window = window } } end
      -- Past the last window this way: continue onto the neighbouring
      -- monitor, at the window beside this one there.
      local monitor = output_toward(snapshot, direction)
      if not monitor then return {} end
      local entering = start and toward(start, direction, monitor.active_tag)
      if entering then return { { name = "focus-window", window = entering } } end
      return focus_output(snapshot, monitor)
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
  if commit then model.dirty = true end
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
-- `delay`: a new target is started toward only this many milliseconds later.
local function animate(owner, key, target, now, delay)
  local motion = owner[key]
  if not motion then motion = { from = target, to = target, started = now }; owner[key] = motion end
  local current = sample_motion(motion, now)
  if target ~= motion.to then motion.from, motion.to, motion.started = current, target, now + (delay or 0) end
  return sample_motion(motion, now)
end
-- Put a camera at `value` at once: panning moves it a little every frame.
local function place(owner, key, value, now)
  owner[key] = { from = value, to = value, started = now }
  return value
end

local function window_minimum(fact)
  local hints = fact.size_hints or {}
  local minimum = hints.min or { width = hints.min_width or 0, height = hints.min_height or 0 }
  -- The host folds sizes a window has actually refused into its minimum, so
  -- `actual` is never read here: until a window answers a proposal, its actual
  -- size is just its previous one (say, fullscreen), not a constraint.
  local width, height = minimum.width or 0, minimum.height or 0
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
-- A stack proposed while dragging, for this layout: a slot made for the
-- dragged window beside `target`, the windows around it making room. Its
-- `frame` is filled in as the tree is laid out.
local stack_preview
local function layout_node(root_id, rect, active, entries, z)
  local current = node(root_id)
  if not current then return z end
  if current.kind == "window" then
    local fact = model.windows[current.window]
    if not fact then return z end
    local preview = stack_preview
    if preview and current.window == preview.target and not preview.group then
      -- Alone where it is: it gives up half its place to the slot.
      local horizontal = preview.axis == "horizontal"
      local available = horizontal and rect.width or rect.height
      local gap = math.min(inner_gap, math.max(0, available))
      local half = math.floor((available - gap) / 2)
      local first = horizontal and { x = rect.x, y = rect.y, width = half, height = rect.height }
        or { x = rect.x, y = rect.y, width = rect.width, height = half }
      local second = horizontal
        and { x = rect.x + half + gap, y = rect.y, width = available - half - gap, height = rect.height }
        or { x = rect.x, y = rect.y + half + gap, width = rect.width, height = available - half - gap }
      preview.frame, rect = preview.before and first or second, preview.before and second or first
    end
    entries[#entries + 1] = {
      window = current.window, state = current.state, frame = rect,
      propose = {
        width = math.max(1, rect.width - 2 * border_width),
        height = math.max(1, rect.height - decoration_height - 2 * border_width),
      },
      visible = active and shown(fact), shown = active, z = z,
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
  -- The proposed stack is this one: it makes room for one more.
  local children = current.children
  local preview = stack_preview
  if preview and preview.group == current.id then
    children = {}
    for _, child in ipairs(current.children) do children[#children + 1] = child end
    table.insert(children, clamp(preview.index, 1, #children + 1), { weight = 1, slot = true })
  end
  local sizes = distribute(children,
    math.max(0, available - gap * math.max(0, #children - 1)), horizontal)
  local cursor = horizontal and rect.x or rect.y
  for index, child in ipairs(children) do
    local extent = sizes[index]
    local child_rect = horizontal
      and { x = cursor, y = rect.y, width = extent, height = rect.height }
      or { x = rect.x, y = cursor, width = rect.width, height = extent }
    if child.slot then
      preview.frame = child_rect
    else
      z = layout_node(child.node, child_rect, active, entries, z)
    end
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
  stack_preview = nil
  do
    local proposal = model.drag and model.drag.group
    local target = proposal and node(model.window_nodes[proposal.target])
    if target and target.tag == state.id and target.state == "tiled" then
      local axis = main_axis == "horizontal" and "vertical" or "horizontal"
      local before = proposal.first ~= reversed(axis == "horizontal")
      local parent = target.parent and node(target.parent)
      local stacked = parent and parent.mode ~= "tabbed" and parent.axis == axis
      stack_preview = {
        target = target.window, before = before, axis = axis,
        group = stacked and parent.id or nil,
        index = stacked and child_index(parent, target.id) + (before and 0 or 1) or nil,
      }
    end
  end
  local screens = model.screens or {}
  model.screens = screens
  for window in pairs(model.windows) do
    local leaf = node(model.window_nodes[window])
    if leaf and leaf.tag == state.id then screens[window] = nil end
  end
  local usable, now = snapshot.output.usable, snapshot.clock.monotonic_ms
  assert(usable.width > 0 and usable.height > 0, "empty usable output")
  local viewport_main, viewport_cross = axis_extent(usable, "main"), axis_extent(usable, "cross")
  local base_main = math.max(1, viewport_main - 2 * (outer_gap + peek + border_width + inner_gap))
  local base_cross = math.max(1, #state.strips > 1
    and viewport_cross - 2 * (outer_gap + peek + border_width + inner_gap)
    or viewport_cross - 2 * outer_gap - border_width)
  local entries, strip_metrics, cross_cursor, z = {}, {}, outer_gap, 1
  -- Which strip holds each root, recorded as strips are laid out so placing an
  -- entry never has to search for it.
  local strip_of_root = {}
  for strip_index, strip in ipairs(state.strips) do
    local strip_cross, main_cursor, metrics = base_cross, outer_gap, {}
    for _, slot in ipairs(strip.roots) do strip_of_root[slot.node] = strip end
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
  -- Windows waiting to be placed (see `sync`): hidden, proposed the size of a
  -- new column so they can answer.
  for window, fact in pairs(model.windows) do
    local leaf = node(model.window_nodes[window])
    if leaf and leaf.tag == state.id and leaf.state == "tiled" and not strip_of_root[leaf.id]
      and not leaf.parent then
      local size = math.max(1, math.floor(base_main * 0.5 + 0.5))
      local frame = logical_rect(outer_gap, outer_gap, size, base_cross)
      entries[#entries + 1] = {
        window = window, state = "tiled", frame = frame, pending = true, visible = false, z = z,
        propose = {
          width = math.max(1, frame.width - 2 * border_width),
          height = math.max(1, frame.height - decoration_height - 2 * border_width),
        },
      }
      z = z + 1
    end
  end
  local focused_root = containing_root(snapshot.tag.focused_window
    and model.window_nodes[snapshot.tag.focused_window])
  local focused_strip, focused_strip_index
  if focused_root then
    local _
    _, focused_strip, focused_strip_index = root_location(focused_root.id)
  end
  local active = false
  -- The focused window moved within the layout (not focus moving to another
  -- window): the camera follows a little later.
  local focused_window = snapshot.tag.focused_window
  local lag
  if focused_window and state.camera_window == focused_window then
    local leaf = node(model.window_nodes[focused_window])
    for _, entry in ipairs(entries) do
      if entry.window == focused_window and entry.state == "tiled" and leaf and leaf.frame_x and leaf.frame_y
        and (leaf.frame_x.to ~= entry.frame.x or leaf.frame_y.to ~= entry.frame.y) then
        lag = camera_lag_ms
      end
    end
  end
  -- Focus moving to another window ends a pan: the camera follows it again.
  if state.camera_window ~= focused_window then state.pinned = nil end
  state.camera_window = focused_window
  -- One camera along the rows and one across them, for the whole tag: rows
  -- scroll together.
  local main_total = 0
  for _, strip in ipairs(state.strips) do main_total = math.max(main_total, strip.total) end
  local main_limit = math.max(0, main_total - viewport_main)
  local main_current = state.camera and sample_motion(state.camera, now) or 0
  local cross_current = state.cross_camera and sample_motion(state.cross_camera, now) or 0
  local main_target = state.camera and state.camera.to or 0
  local cross_target = state.cross_camera and state.cross_camera.to or 0
  -- The camera along the rows, moved from `target` to bring the next window of
  -- `strip` beyond the view `direction` (-1, 1) into it.
  local function step_along(strip, target, direction)
    local metrics, step = strip.metrics or {}, nil
    if direction > 0 then
      for index, metric in ipairs(metrics) do
        if metric.start + metric.size > target + viewport_main - outer_gap + 1 then step = index; break end
      end
    else
      for index = #metrics, 1, -1 do
        if metrics[index].start < target + outer_gap - 1 then step = index; break end
      end
    end
    return step and camera_target(target, metrics[step], step, #metrics, main_total, viewport_main) or target
  end
  -- A tiled window being dragged here: the cameras stop following focus. The
  -- pointer held at an edge steps the view along the rows, or moves the
  -- window to the next row; the camera across the rows keeps its row in view.
  local drag = model.drag
  local dragged = drag and drag.pointer and node(model.window_nodes[drag.window])
  if not (dragged and dragged.tag == state.id and dragged.state == "tiled") then dragged = nil end
  local pointer, shift_edge
  if dragged then
    pointer = { x = drag.pointer.x + (drag.dx or 0), y = drag.pointer.y + (drag.dy or 0) }
    local along_x = main_axis == "horizontal"
    local main_at = along_x and pointer.x - usable.x or pointer.y - usable.y
    local cross_at = along_x and pointer.y - usable.y or pointer.x - usable.x
    local main_moved = (along_x and drag.dx or drag.dy) or 0
    local cross_moved = (along_x and drag.dy or drag.dx) or 0
    -- Only towards an edge the drag has moved towards: a title bar is always
    -- near the top, and grabbing one should not shift rows.
    local function edge(at, extent, moved)
      if moved < -8 and at < edge_zone then return -1 end
      if moved > 8 and at > extent - edge_zone then return 1 end
      return 0
    end
    local main_edge = edge(main_at, viewport_main, main_moved)
    local cross_edge = edge(cross_at, viewport_cross, cross_moved)
    shift_edge = cross_edge ~= 0 and cross_edge or nil
    if main_reverse then main_edge = -main_edge end
    if cross_reverse then cross_edge = -cross_edge end
    if main_edge ~= 0 or cross_edge ~= 0 then active = true end
    local root = containing_root(dragged.id)
    local _, strip, strip_index = root_location(root.id)
    if dwelled(drag, "main_edge", main_edge, now) and strip then
      main_target = step_along(strip, main_target, main_edge)
    end
    if dwelled(drag, "cross_edge", cross_edge, now) then
      local along = (main_reverse and viewport_main - main_at or main_at) + main_current
      shift_row(state, dragged, cross_edge, along)
      drag.group, active = nil, true
      root = containing_root(dragged.id)
      _, strip, strip_index = root_location(root.id)
    end
    if strip_index and strip_metrics[strip_index] then
      cross_target = camera_target(cross_current, strip_metrics[strip_index],
        strip_index, #state.strips, cross_total, viewport_cross)
    end
  elseif state.pinned then
    -- Panned by hand: the cameras stay where they were put, stepping a
    -- window along the rows or a row across them per request.
    local pan = state.pan
    state.pan = nil
    local middle, middle_index = nil, nil
    for index, metric in ipairs(strip_metrics) do
      if cross_target + viewport_cross / 2 >= metric.start then middle, middle_index = state.strips[index], index end
    end
    if pan and pan.axis == "main" and middle then
      main_target = step_along(middle, main_target, pan.step)
    elseif pan and pan.axis == "cross" and middle_index then
      local index = clamp(middle_index + pan.step, 1, #state.strips)
      cross_target = camera_target(cross_target, strip_metrics[index], index, #state.strips, cross_total, viewport_cross)
    end
  else
    if focused_strip then
      local metric, metric_index
      for index, candidate in ipairs(focused_strip.metrics) do
        if candidate.node == focused_root.id then metric, metric_index = candidate, index end
      end
      main_target = camera_target(main_current, metric, metric_index or 0,
        #focused_strip.metrics, main_total, viewport_main)
    end
    -- With nothing focused here (focus is on another monitor) the cameras
    -- hold rather than snapping back to the first window.
    if focused_strip_index then
      cross_target = camera_target(cross_current, strip_metrics[focused_strip_index],
        focused_strip_index, #state.strips, cross_total, viewport_cross)
    end
  end
  local main_moving, cross_moving
  main_current, main_moving = animate(state, "camera", clamp(main_target, 0, main_limit), now,
    not dragged and lag or nil)
  cross_current, cross_moving = animate(state, "cross_camera", cross_target, now, not dragged and lag or nil)
  active = active or main_moving or cross_moving

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
        visible = leaf.state ~= "scratchpad" and shown(fact), z = z,
      }
      z = z + 1
      if leaf.state == "fullscreen" and (fact.focus_serial or 0) >= fullscreen_serial then
        fullscreen, fullscreen_serial = window, fact.focus_serial or 0
      end
    end
  end
  if fullscreen then for _, entry in ipairs(entries) do entry.visible = entry.window == fullscreen end end
  -- The proposed stack's slot on screen, while the pointer is over it the
  -- proposal stands (`drag_reorder`).
  local drop_slot = stack_preview and stack_preview.frame
    and screen_rect(stack_preview.frame, usable, main_current, cross_current)
  model.drop_slot = drop_slot
  -- Where each tile rests on screen, title bar and borders included, for
  -- dragging and directional focus (a hidden tab has none): all of them
  -- before any is placed, as the dragged window's size can depend on another's.
  for _, entry in ipairs(entries) do
    if entry.state == "tiled" and not entry.pending and entry.shown ~= false then
      screens[entry.window] = screen_rect(entry.frame, usable, main_current, cross_current)
    end
  end
  -- Strips a window has left since the last layout: they close up late.
  local left = {}
  for _, entry in ipairs(entries) do
    local leaf = entry.state == "tiled" and node(model.window_nodes[entry.window])
    local root = leaf and containing_root(leaf.id)
    local strip = root and strip_of_root[root.id]
    if strip and leaf.strip and leaf.strip ~= strip.id then left[leaf.strip] = true end
  end
  for _, entry in ipairs(entries) do
    local fact = model.windows[entry.window] or {}
    local leaf = node(model.window_nodes[entry.window])
    local root = containing_root(model.window_nodes[entry.window])
    local strip = root and strip_of_root[root.id]
    local frame = entry.frame
    if entry.state == "tiled" and leaf and leaf.settle and not entry.pending then
      -- Dropped: ease in from where the pointer left it.
      local shift_x = (main_axis == "horizontal" and main_reverse or main_axis ~= "horizontal" and cross_reverse) and -1 or 1
      local shift_y = (main_axis == "horizontal" and cross_reverse or main_axis ~= "horizontal" and main_reverse) and -1 or 1
      leaf.frame_x = { from = frame.x + shift_x * leaf.settle.x, to = frame.x, started = now }
      leaf.frame_y = { from = frame.y + shift_y * leaf.settle.y, to = frame.y, started = now }
      leaf.settle = nil
    end
    if entry.state == "tiled" and leaf and not entry.pending then
      local moving_x, moving_y
      local closing = strip and leaf.strip == strip.id and left[strip.id] and stagger_ms or nil
      frame = copy(frame)
      frame.x, moving_x = animate(leaf, "frame_x", frame.x, now, closing)
      frame.y, moving_y = animate(leaf, "frame_y", frame.y, now, closing)
      active = active or moving_x or moving_y
      leaf.strip = strip and strip.id or leaf.strip
    end
    local target = entry.state == "tiled"
      and screen_rect(content_rect(frame), usable, main_current, cross_current)
      or frame
    if entry.state == "tiled" and not entry.pending then
      local resting = screen_rect(content_rect(entry.frame), usable, main_current, cross_current)
      if drag and drag.window == entry.window and drag.origin and leaf then
        target = copy(resting)
        target.x, target.y = drag.origin.x + drag.dx, drag.origin.y + drag.dy
        leaf.drag_shift = { x = target.x - resting.x, y = target.y - resting.y }
        entry.z = dragged_z
        -- Over a proposed stack, it takes the size of its slot.
        local half = drop_slot
        if half then
          entry.propose = {
            width = math.max(1, half.width - 2 * border_width),
            height = math.max(1, half.height - decoration_height - 2 * border_width),
          }
        end
      end
    end
    local actual = fact.actual or entry.propose or { width = target.width, height = target.height }
    entry.screen = {
      x = math.floor(target.x), y = math.floor(target.y),
      width = math.max(1, math.ceil(actual.width)), height = math.max(1, math.ceil(actual.height)),
    }
    entry.clip = entry.visible and clipped(entry.screen, usable, false)
      or { x = 0, y = 0, width = 0, height = 0 }
    entry.window_clip = entry.visible and clipped(entry.screen, usable, true)
      or { x = 0, y = 0, width = 0, height = 0 }
    -- River treats an empty clip box as "no clip", so a window with nothing
    -- left inside this monitor would be drawn in full on its neighbour. Hide it.
    if entry.visible and (entry.clip.width == 0 or entry.window_clip.width == 0) then
      entry.visible = false
    end
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
  -- A stepping camera carries other windows under a pointer that has not
  -- moved; their places on screen are now this frame's.
  if dragged and main_moving then drag_reorder(state, dragged, pointer.x, pointer.y) end
  -- Marks a surface may draw (`placement = "mark"`), just under the dragged
  -- window: `drop` where it lands if dropped now (its half of a proposed
  -- stack, or its place); `shift` along an edge where holding it moves it to
  -- the next row.
  local marks
  if dragged then
    marks = {}
    local function mark(name, rect)
      if not rect then return end
      marks[#marks + 1] = {
        name = name, z = dragged_z - 1,
        rect = {
          x = math.floor(rect.x), y = math.floor(rect.y),
          width = math.max(1, math.floor(rect.width)), height = math.max(1, math.floor(rect.height)),
        },
      }
    end
    mark("drop", drop_slot or screens[dragged.window])
    if shift_edge then
      local band = math.floor(edge_zone / 2)
      local along_x = main_axis == "horizontal"
      mark("shift", along_x
        and { x = usable.x, y = shift_edge < 0 and usable.y or usable.y + usable.height - band, width = usable.width, height = band }
        or { x = shift_edge < 0 and usable.x or usable.x + usable.width - band, y = usable.y, width = band, height = usable.height })
    end
  end
  -- Sizes are whole pixels: halves and shares of odd sizes are not.
  for _, entry in ipairs(entries) do
    if entry.propose then
      entry.propose.width = math.max(1, math.floor(entry.propose.width))
      entry.propose.height = math.max(1, math.floor(entry.propose.height))
    end
  end
  return {
    epoch = snapshot.epoch, output = snapshot.output.id, tag = snapshot.tag.id,
    entries = entries, marks = marks, needs_frame = active,
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
local function append_item(items, style, text, focused, detail, window, width, action, overlay, key)
  items[#items + 1] = {
    key = key, style = style, text = text or "", focused = focused == true,
    detail = detail or "", window = window, width = width, action = action,
    args = action and window and { tostring(window) } or nil,
    overlay = overlay == true,
  }
end
local function append_open(items, label, selected, mark, key)
  append_item(items, "group-open", label, selected, mark, nil, 3, nil, true, key)
end
local function append_close(items, key)
  append_item(items, "group-close", "", false, "", nil, 3, nil, true, key)
end
local function project_node(items, id, focus, node_marks, window_marks)
  local current = node(id)
  if not current then return end
  if current.kind == "window" then
    append_item(items, "window", "",
      focus and focus.kind == "window" and focus.window == current.window,
      window_marks[current.window], current.window, 148, "focus-window", nil, "window:" .. current.window)
    return
  end
  local key = "node:" .. current.id
  append_open(items,
    current.mode == "tabbed" and "t" or current.axis == "horizontal" and "h" or "v",
    focus and focus.kind == "node" and focus.id == current.id,
    node_marks[current.id], key)
  for _, child in ipairs(current.children) do
    project_node(items, child.node, focus, node_marks, window_marks)
  end
  append_close(items, key)
end
local function project(snapshot)
  local state = sync(snapshot)
  local focus = focused_descriptor(state, snapshot)
  local node_marks, window_marks, strip_marks = mark_badges()
  local items = {}
  for _, strip in ipairs(state.strips) do
    append_open(items, main_axis == "horizontal" and "h" or "v",
      focus and focus.kind == "strip" and focus.id == strip.id,
      strip_marks[strip.id], "strip:" .. strip.id)
    for _, slot in ipairs(strip.roots) do
      project_node(items, slot.node, focus, node_marks, window_marks)
    end
    append_close(items, "strip:" .. strip.id)
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

local controller = {
  layout = layout, action = action, project = project,
  begin_actions = begin_actions, finish_actions = finish_actions,
  save = save, restore = restore,
}

-- `whirlpool.layout("lib.scrolling", options)` constructs the controller.
function controller.new(options)
  options = options or {}
  if options.widths then
    assert(#options.widths > 0, "widths must list at least one width")
    widths = options.widths
  end
  return controller
end

return controller

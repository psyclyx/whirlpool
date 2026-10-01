-- Pointer regions over retained nodes.
--
-- A region is a node plus handlers; where it is comes from layout
-- (`node:bounds()`), so moving or resizing a node moves its region. Events go to
-- the innermost region (smallest box) under the pointer that handles them, so a
-- clickable item inside a scrollable list gets clicks while the list gets the
-- wheel. Wire it to the host's events once:
--
--   local pointer = require("whirlpool.pointer").new()
--   surface.on("pointer", function(event) pointer:handle(event) end)
--   pointer:region(button, { click = function() ... end,
--                            hover = function(inside) ... end })
--
-- Handlers (all optional), each given the event:
--   click(event)        a button pressed and released over the region
--   press(event)        a button pressed over it
--   scroll(event)       wheel motion over it (event.dx, event.dy)
--   hover(inside, event) the pointer entered (true) or left (false) it

local Pointer = {}
Pointer.__index = Pointer

function Pointer.new()
  return setmetatable({ regions = {}, inside = {}, pressed = nil, x = nil, y = nil }, Pointer)
end

-- Handle `node`'s pointer events with `handlers`, replacing any it had; nil
-- stops handling them.
function Pointer:region(node, handlers)
  local previous = self.regions[node]
  if previous and not handlers and self.inside[node] and previous.hover then previous.hover(false, {}) end
  if not handlers then self.inside[node] = nil end
  self.regions[node] = handlers
end

local function area(box)
  return box.width * box.height
end

-- Regions under (x, y): node -> box.
function Pointer:hits(x, y)
  local result = {}
  if not x then return result end
  for node in pairs(self.regions) do
    local box = node:bounds()
    if box and x >= box.x and y >= box.y and x < box.x + box.width and y < box.y + box.height then
      result[node] = box
    end
  end
  return result
end

-- The innermost region under the pointer that has handler `name`.
function Pointer:target(hits, name)
  local best, best_area
  for node, box in pairs(hits) do
    local handlers = self.regions[node]
    if handlers and handlers[name] and (not best or area(box) < best_area) then
      best, best_area = node, area(box)
    end
  end
  return best
end

function Pointer:handle(event)
  if event.type == "leave" then
    self.x, self.y, self.pressed = nil, nil, nil
  else
    self.x, self.y = event.x, event.y
  end
  local hits = self:hits(self.x, self.y)

  -- Hover follows the set of regions under the pointer.
  for node in pairs(self.inside) do
    if not hits[node] then
      self.inside[node] = nil
      local handlers = self.regions[node]
      if handlers and handlers.hover then handlers.hover(false, event) end
    end
  end
  for node in pairs(hits) do
    if not self.inside[node] then
      self.inside[node] = true
      local handlers = self.regions[node]
      if handlers.hover then handlers.hover(true, event) end
    end
  end

  if event.type == "button" then
    if event.pressed then
      local target = self:target(hits, "press")
      if target then self.regions[target].press(event) end
      self.pressed = self:target(hits, "click")
    else
      local target = self:target(hits, "click")
      if target and target == self.pressed then self.regions[target].click(event) end
      self.pressed = nil
    end
  elseif event.type == "scroll" then
    local target = self:target(hits, "scroll")
    if target then self.regions[target].scroll(event) end
  end
end

-- Whether the pointer is over `node`'s region.
function Pointer:hovering(node)
  return self.inside[node] == true
end

-- Linux input button codes, for comparing with `event.button`.
Pointer.LEFT, Pointer.RIGHT, Pointer.MIDDLE = 0x110, 0x111, 0x112

return Pointer

-- A horizontally scrolling view.
--
-- `viewport` is a clipped row and `content` its single child row, laid out at
-- its natural width (it may be wider than the viewport). The view moves the
-- content with `offset_x`, keeps the offset in range as either size changes,
-- and eases towards where it was asked to go. Geometry comes from layout, so
-- nothing here knows what the content is.
--
--   local view = Scroll.new(viewport, content)
--   view:by(-event.dy * 2)       -- wheel
--   view:reveal(item, 24)        -- bring an item (and 24px around it) into view
--   view:step(now)               -- each frame; returns true while still moving

local Scroll = {}
Scroll.__index = Scroll

function Scroll.new(viewport, content, options)
  options = options or {}
  return setmetatable({
    viewport = viewport,
    content = content,
    -- Milliseconds for an eased move to cover most of its distance.
    duration = options.duration or 160,
    offset = 0,
    target = 0,
    shown = nil,
    stepped_ms = nil,
  }, Scroll)
end

-- How far the content can move: 0 when it fits.
function Scroll:range()
  local viewport, content = self.viewport:bounds(), self.content:bounds()
  if not viewport or not content then return 0, 0 end
  return math.max(0, content.width - viewport.width), viewport.width
end

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

-- Scroll by `delta` pixels (positive moves the content left).
function Scroll:by(delta)
  local limit = self:range()
  self.target = clamp(self.target + delta, 0, limit)
end

-- Scroll as little as possible so `node` (with `margin` pixels either side) is
-- inside the viewport; if it cannot fit, show its start.
function Scroll:reveal(node, margin)
  margin = margin or 0
  local box, content = node:bounds(), self.content:bounds()
  if not box or not content then return end
  local limit, width = self:range()
  -- Where the node sits in the content, independent of the current offset.
  local start = box.x - content.x - margin
  local finish = box.x - content.x + box.width + margin
  local target = self.target
  if finish - start > width or start < target then target = start
  elseif finish > target + width then target = finish - width end
  self.target = clamp(target, 0, limit)
end

-- Advance towards the target; returns whether it is still moving.
function Scroll:step(now)
  local limit = self:range()
  self.target = clamp(self.target, 0, limit)
  local elapsed = self.stepped_ms and math.max(0, now - self.stepped_ms) or 0
  self.stepped_ms = now
  local remaining = self.target - self.offset
  if math.abs(remaining) < 0.5 then
    self.offset = self.target
  else
    self.offset = self.offset + remaining * (1 - math.exp(-elapsed / (self.duration / 3)))
  end
  local shown = math.floor(self.offset + 0.5)
  if shown ~= self.shown then
    self.shown = shown
    self.content:set("offset_x", -shown)
  end
  return self.offset ~= self.target
end

-- Pixels of content hidden past each edge: left, right.
function Scroll:clipped()
  local limit = self:range()
  local offset = self.shown or 0
  return offset, math.max(0, limit - offset)
end

return Scroll

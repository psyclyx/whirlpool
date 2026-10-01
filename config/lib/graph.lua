-- History plots drawn on an angled canvas, placed by time.
--
-- A sample taken `age` milliseconds ago sits that fraction of `span` left of
-- the plot's right edge. Nothing assumes samples are evenly spaced or arrive
-- on time: a late sample is simply drawn where its time puts it, and the plot
-- moves smoothly between samples because only `now` changes. The newest sample
-- is held back by `delay` (about its source's period) so new data enters at
-- the right edge rather than appearing mid-plot.
--
-- Styles:
--   area   a filled envelope (`direction` "up" grows from the bottom)
--   heat   one full-height cell per sample interval, shaded by level; with
--          `base` (the opaque colour behind the plot) cells mix from base to
--          fill instead of fading in, so overlapping edges never double up.
--          With `hot`, levels above 1 continue on a second ramp from fill to
--          hot (full at 2): room to single out peaks above the usual range.
local Graph = {}
Graph.__index = Graph

-- Retained polygons have at most 16 vertices; long outlines are drawn as
-- chunks sharing an edge.
local MAX_POINTS = 13
local MAX_CHUNKS = 6
local SHADES = 32

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function clamp01(value)
  return math.min(1, math.max(0, value))
end

--   canvas     an Angled canvas
--   span       milliseconds of history across the plot
--   delay      milliseconds the newest sample is held back (default 0)
--   region     { top, bottom } rows of the canvas (default all of it)
--   inset      margin between the canvas edges and the plot
--   style      "area" or "heat"
--   direction  "up" or "down" (area)
--   fill       colour; base: see heat above
--   cells      most heat cells visible at once (default 48)
function Graph.new(canvas, spec)
  local self = setmetatable({}, Graph)
  self.canvas = canvas
  self.span = spec.span
  self.delay = spec.delay or 0
  self.top = spec.region and spec.region[1] or 0
  self.bottom = spec.region and spec.region[2] or canvas.height
  self.left = spec.inset or 0
  self.right = canvas.width - (spec.inset or 0)
  self.style = spec.style or "area"
  self.direction = spec.direction or "up"
  self.fill = spec.fill
  self.base = spec.base
  self.hot = spec.hot
  self.t, self.values = {}, {}
  self.drawn_key = nil
  self.pool, self.shown = {}, {}
  local pool_size = self.style == "heat" and (spec.cells or 48) or MAX_CHUNKS
  local empty = { { 0, self.bottom }, { 0, self.bottom }, { 0, self.bottom } }
  for index = 1, pool_size do
    self.pool[index] = canvas:polygon({ fill = spec.fill, points = empty })
    self.pool[index]:set("opacity", 0)
    self.shown[index] = false
  end
  return self
end

-- Samples, oldest first: `t` times and the matching `values`.
function Graph:set(t, values)
  self.t, self.values = t, values
  self.drawn_key = nil
end

function Graph:show(index, visible)
  if self.shown[index] ~= visible then
    self.shown[index] = visible
    self.pool[index]:set("opacity", visible and 1 or 0)
  end
end

function Graph:hide_from(first)
  for index = first, #self.pool do self:show(index, false) end
end

-- Where a sample taken at `time` is drawn, for the plot at `now`.
function Graph:x(time, now)
  local width = self.right - self.left
  return self.right - (now - self.delay - time) / self.span * width
end

-- Redraw for time `now`. `level(value)` maps a sample to 0..1; pass a
-- `version` that changes whenever `level` does, so an unchanged plot is not
-- rebuilt. The plot moves in quarter pixels.
function Graph:draw(now, level, version)
  local width = self.right - self.left
  local key = math.floor(now / self.span * width * 4) .. ":" .. tostring(version)
  if key == self.drawn_key then return end
  self.drawn_key = key
  if self.style == "heat" then self:draw_heat(now, level) else self:draw_area(now, level) end
end

function Graph:row(fraction)
  local span = self.bottom - self.top
  if self.direction == "down" then return self.top + fraction * span end
  return self.bottom - fraction * span
end

function Graph:draw_heat(now, level)
  local t, values = self.t, self.values
  local used = 0
  -- Each interval between consecutive samples is one cell, shaded by its end.
  for index = 2, #t do
    local x1, x2 = self:x(t[index - 1], now), self:x(t[index], now)
    -- Run a pixel under the next cell, which is drawn later and covers it.
    x2 = x2 + (self.base and 1 or 0.6)
    x1, x2 = math.max(self.left, x1), math.min(self.right, x2)
    if x2 - x1 > 0.2 and used < #self.pool then
      used = used + 1
      local node = self.pool[used]
      self.canvas:set_polygon(node, {
        { x1, self.top }, { x2, self.top }, { x2, self.bottom }, { x1, self.bottom },
      })
      local value = level(values[index])
      local shade = math.floor(clamp01(value) * SHADES + 0.5) / SHADES
      local heat = self.hot and math.floor(clamp01(value - 1) * SHADES + 0.5) / SHADES or 0
      if heat > 0 then
        local fill, hot = self.fill, self.hot
        node:set("fill", { lerp(fill[1], hot[1], heat), lerp(fill[2], hot[2], heat), lerp(fill[3], hot[3], heat), 1 })
        node:set("opacity", 1)
        self.shown[used] = true
      elseif self.base then
        local base, fill = self.base, self.fill
        node:set("fill", { lerp(base[1], fill[1], shade), lerp(base[2], fill[2], shade), lerp(base[3], fill[3], shade), 1 })
        self:show(used, true)
      else
        node:set("fill", self.fill)
        node:set("opacity", shade)
        self.shown[used] = shade > 0
      end
    end
  end
  self:hide_from(used + 1)
end

-- Group vertices into chunks of at most `size`, neighbours sharing a vertex.
local function chunk_ranges(total, size)
  local ranges, cursor = {}, 1
  while cursor < total and #ranges < MAX_CHUNKS do
    local last = math.min(total, cursor + size - 1)
    ranges[#ranges + 1] = { cursor, last }
    if last == total then break end
    cursor = last
  end
  return ranges
end

function Graph:draw_area(now, level)
  local t, values = self.t, self.values
  -- The visible outline, clipped to the plot's ends.
  local curve = {}
  for index = 2, #t do
    local x1, x2 = self:x(t[index - 1], now), self:x(t[index], now)
    if x2 > self.left and x1 < self.right and x2 > x1 then
      local l1, l2 = clamp01(level(values[index - 1])), clamp01(level(values[index]))
      local a, la, b, lb = x1, l1, x2, l2
      if x1 < self.left then a, la = self.left, lerp(l1, l2, (self.left - x1) / (x2 - x1)) end
      if x2 > self.right then b, lb = self.right, lerp(l1, l2, (self.right - x1) / (x2 - x1)) end
      if #curve == 0 then curve[1] = { a, la } end
      curve[#curve + 1] = { b, lb }
    end
  end
  if #curve < 2 then
    self:hide_from(1)
    return
  end
  local baseline = self.direction == "down" and self.top or self.bottom
  local ranges = chunk_ranges(#curve, MAX_POINTS)
  for chunk, range in ipairs(ranges) do
    local points = { { curve[range[1]][1], baseline } }
    for index = range[1], range[2] do
      points[#points + 1] = { curve[index][1], self:row(curve[index][2]) }
    end
    -- Run a pixel under the next chunk (drawn later, same opaque fill) so
    -- their shared edge is not antialiased twice into a visible seam.
    local last = curve[range[2]]
    if chunk < #ranges then points[#points + 1] = { last[1] + 1, self:row(last[2]) } end
    points[#points + 1] = { last[1] + (chunk < #ranges and 1 or 0), baseline }
    self.canvas:set_polygon(self.pool[chunk], points)
    self:show(chunk, true)
  end
  self:hide_from(#ranges + 1)
end

return Graph

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
--   area   a filled envelope (`direction` "up" grows from the bottom); with
--          `smooth`, a monotone curve through the samples rather than
--          straight lines, so bursty data reads as a shape, not a sawtooth
--   heat   a strip whose colour at each sample's place is its level, and
--          flows smoothly between samples (one gradient-filled polygon):
--          from `base` (the opaque colour behind the plot) at 0 to `fill`
--          at 1, and with `hot`, on to `hot` at 2: room to single out peaks
--          above the usual range. Isolines lean with the canvas.
local Graph = {}
Graph.__index = Graph

-- Retained polygons have at most 16 vertices; long outlines are drawn as
-- chunks sharing an edge.
local MAX_POINTS = 13
local MAX_CHUNKS = 8
-- Gradient stops a heat strip may use (the renderer's limit).
local MAX_STOPS = 64

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
--   smooth     points drawn per sample interval on an area's curve (default 1)
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
  self.smooth = spec.smooth or 1
  self.t, self.values = {}, {}
  self.drawn_key = nil
  self.pool, self.shown = {}, {}
  local pool_size = self.style == "heat" and 1 or MAX_CHUNKS
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
-- rebuilt. The plot moves in whole pixels: every redraw is a frame the
-- compositor must show, so it moves only as far as can be seen.
function Graph:draw(now, level, version)
  local width = self.right - self.left
  local key = math.floor(now / self.span * width) .. ":" .. tostring(version)
  if key == self.drawn_key then return end
  self.drawn_key = key
  if self.style == "heat" then self:draw_heat(now, level) else self:draw_area(now, level) end
end

function Graph:row(fraction)
  local span = self.bottom - self.top
  if self.direction == "down" then return self.top + fraction * span end
  return self.bottom - fraction * span
end

-- The colour of a heat level: base to fill over 0..1, fill to hot over 1..2.
function Graph:heat_color(value)
  local from, to, amount = self.base, self.fill, clamp01(value)
  if self.hot and value > 1 then from, to, amount = self.fill, self.hot, clamp01(value - 1) end
  return { lerp(from[1], to[1], amount), lerp(from[2], to[2], amount), lerp(from[3], to[3], amount), 1 }
end

function Graph:draw_heat(now, level)
  local t, values = self.t, self.values
  -- Stops at the samples in view, and at each end of the strip the level
  -- there (between the samples either side), so the strip starts and ends
  -- on the right colour. It starts where the data does.
  local stops = {}
  local function stop(x, value) stops[#stops + 1] = { x, self:heat_color(value) } end
  for index = 1, #t do
    local x = self:x(t[index], now)
    local previous = index > 1 and self:x(t[index - 1], now)
    local value = level(values[index])
    if x >= self.left and #stops == 0 then
      if previous and previous < self.left then
        stop(self.left, lerp(level(values[index - 1]), value, (self.left - previous) / (x - previous)))
      end
    end
    if x > self.right then
      if previous and previous <= self.right and #stops > 0 then
        stop(self.right, lerp(level(values[index - 1]), value, (self.right - previous) / (x - previous)))
      end
      break
    end
    if x >= self.left then stop(x, value) end
  end
  -- Too many samples for the renderer: keep an even spread, ends included.
  if #stops > MAX_STOPS then
    local kept = {}
    for slot = 0, MAX_STOPS - 1 do
      kept[#kept + 1] = stops[1 + math.floor(slot * (#stops - 1) / (MAX_STOPS - 1) + 0.5)]
    end
    stops = kept
  end
  local node = self.pool[1]
  if #stops < 2 then
    self:show(1, false)
    return
  end
  local x1, x2 = stops[1][1], stops[#stops][1]
  self.canvas:set_polygon(node, { { x1, self.top }, { x2, self.top }, { x2, self.bottom }, { x1, self.bottom } })
  node:set("gradient", { slant = self.canvas.slant, stops = stops })
  self:show(1, true)
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

-- Monotone cubic (Fritsch-Carlson) through `points` ({ x, level }), with
-- `steps` points per interval: it passes through every sample and never
-- overshoots between them, so a curve stays within the data's range.
local function smoothed(points, steps)
  local count = #points
  if count < 3 or steps <= 1 then return points end
  local slopes, tangents = {}, {}
  for index = 1, count - 1 do
    local dx = points[index + 1][1] - points[index][1]
    slopes[index] = dx > 0 and (points[index + 1][2] - points[index][2]) / dx or 0
  end
  tangents[1], tangents[count] = slopes[1], slopes[count - 1]
  for index = 2, count - 1 do
    tangents[index] = slopes[index - 1] * slopes[index] <= 0 and 0 or (slopes[index - 1] + slopes[index]) / 2
  end
  for index = 1, count - 1 do
    if slopes[index] == 0 then
      tangents[index], tangents[index + 1] = 0, 0
    else
      local a, b = tangents[index] / slopes[index], tangents[index + 1] / slopes[index]
      local length = a * a + b * b
      if length > 9 then
        local scale = 3 / math.sqrt(length)
        tangents[index], tangents[index + 1] = scale * a * slopes[index], scale * b * slopes[index]
      end
    end
  end
  local out = { points[1] }
  for index = 1, count - 1 do
    local x0, y0, x1, y1 = points[index][1], points[index][2], points[index + 1][1], points[index + 1][2]
    local h = x1 - x0
    for step = 1, steps do
      local t = step / steps
      local t2, t3 = t * t, t * t * t
      local y = (2 * t3 - 3 * t2 + 1) * y0 + (t3 - 2 * t2 + t) * h * tangents[index]
        + (-2 * t3 + 3 * t2) * y1 + (t3 - t2) * h * tangents[index + 1]
      out[#out + 1] = { x0 + h * t, clamp01(y) }
    end
  end
  return out
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
  -- As smooth as the polygons' vertex budget allows.
  local budget = MAX_CHUNKS * (MAX_POINTS - 1)
  curve = smoothed(curve, math.min(self.smooth, budget // (#curve - 1)))
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

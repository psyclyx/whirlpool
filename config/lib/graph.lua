-- Scrolling history plots drawn inside an angled cell.
--
-- Samples are evenly spaced in time and the whole plot slides left between
-- sample arrivals. The plot lives in the cell's own rectangular (u, v) space;
-- `Cell:polygon` shears it so verticals lean with the panel, and the left and
-- right ends are clipped analytically in that rectangular space, so the ends
-- follow the slant instead of being cut off by a rectangular clip.
--
-- Scrolling is quantised to whole pixels: a plot only changes when it has
-- actually moved, so redrawing it every frame costs nothing between steps.
--
-- Styles (all take the same samples):
--   area      filled envelope (the default)
--   steps     sample-and-hold staircase, filled
--   line      thin stroke over a faint fill
--   columns   one bar per sample
--   ticks     narrow bars, like a bar code
--   mirror    envelope mirrored about the middle (a waveform)
--   heat      one full-height cell per sample, shaded by level

local Graph = {}
Graph.__index = Graph

-- Retained polygons deliberately carry a small vertex cap (16), so long
-- outlines are built from overlapping chunks that share identical fill.
local MAX_POINTS = 14
local MAX_CHUNKS = 6

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function clamp01(value)
  return math.min(1, math.max(0, value))
end

--   cell       an Angled cell whose canvas hosts the plot
--   samples    number of history samples supplied to `set_samples`
--   region     { top, bottom } rows of the cell the plot occupies (default all)
--   inset      horizontal margin between the cell edges and the plot
--   direction  "up" grows from the region's bottom, "down" from its top
--   fill       colour
--   base       heat only: the opaque colour behind the plot (see `Graph:shade`)
--   style      see the list above
function Graph.new(cell, spec)
  local self = setmetatable({}, Graph)
  self.cell = cell
  self.count = spec.samples
  self.top = spec.region and spec.region[1] or 0
  self.bottom = spec.region and spec.region[2] or cell.height
  self.left = spec.inset or 0
  self.right = cell.width - (spec.inset or 0)
  self.direction = spec.direction or "up"
  self.style = spec.style or "area"
  self.fill = spec.fill
  self.base = spec.base
  self.values = {}
  self.drawn_key = nil

  -- Pools of polygon nodes, created once. Unused ones are hidden.
  local pool_size = MAX_CHUNKS
  if self.style == "columns" or self.style == "ticks" or self.style == "heat" then
    pool_size = spec.samples
  end
  self.pool = {}
  self.pool_visible = {}
  for index = 1, pool_size do
    self.pool[index] = cell:polygon({
      fill = spec.fill,
      points = { { 0, cell.height }, { 0, cell.height }, { 1, cell.height } },
    })
    self.pool[index]:set("opacity", 0)
    self.pool_visible[index] = 0
  end
  if self.style == "line" then
    -- A second pool: the faint fill under the stroke. Translucent fills must not
    -- overlap themselves, so it is a single polygon (see `resample`).
    self.under = {}
    self.under_visible = {}
    for index = 1, 1 do
      self.under[index] = cell:polygon({
        fill = spec.fill,
        points = { { 0, cell.height }, { 0, cell.height }, { 1, cell.height } },
      })
      self.under[index]:set("opacity", 0)
      self.under_visible[index] = 0
    end
  end
  return self
end

-- `values` holds raw samples oldest first.
function Graph:set_samples(values)
  self.values = values
  self.drawn_key = nil
end

-- Reduce a curve to at most `count` vertices spaced evenly in u, so it fits one
-- polygon.
local function resample(curve, count)
  if #curve <= count then return curve end
  local first, last = curve[1][1], curve[#curve][1]
  local out = {}
  local cursor = 1
  for step = 0, count - 1 do
    local u = first + (last - first) * step / (count - 1)
    while cursor < #curve - 1 and curve[cursor + 1][1] < u do cursor = cursor + 1 end
    local a, b = curve[cursor], curve[cursor + 1]
    local span = b[1] - a[1]
    local t = span > 0 and (u - a[1]) / span or 0
    out[#out + 1] = { u, lerp(a[2], b[2], math.min(1, math.max(0, t))) }
  end
  return out
end

local function show(pool, visible, index, opacity)
  if visible[index] ~= opacity then
    visible[index] = opacity
    pool[index]:set("opacity", opacity)
  end
end

local function hide_from(pool, visible, first)
  for index = first, #pool do show(pool, visible, index, 0) end
end

-- Group vertices into chunks of at most `size` points, overlapping by one
-- vertex so neighbouring chunks share an edge (no hairline seams).
local function chunk_ranges(total, size)
  local ranges = {}
  local cursor = 1
  while cursor < total and #ranges < MAX_CHUNKS do
    local last = math.min(total, cursor + size - 1)
    ranges[#ranges + 1] = { cursor, last }
    if last == total then break end
    cursor = last - 1
  end
  return ranges
end

-- Shade heat cell `index` for `level` (0..1) in 1/32 steps. With a `base`
-- (the colour behind the plot) the cell is an opaque mix of base and fill;
-- without one it falls back to fill opacity.
local SHADES = 32
function Graph:shade(index, level)
  local shade = math.floor(level * SHADES + 0.5)
  if self.pool_visible[index] == shade then return end
  self.pool_visible[index] = shade
  local node = self.pool[index]
  if not self.base then
    node:set("opacity", shade / SHADES)
    return
  end
  local amount, fill, base = shade / SHADES, self.fill, self.base
  node:set("fill", {
    lerp(base[1], fill[1], amount), lerp(base[2], fill[2], amount), lerp(base[3], fill[3], amount), 1,
  })
  node:set("opacity", 1)
end

-- Redraw with the plot advanced `phase` (0..1) of a sample spacing.
-- `level(value)` maps a sample to 0..1 and may change between calls (the
-- caller passes a `version` that changes whenever it does, so unchanged plots
-- are not rebuilt).
function Graph:draw(phase, level, version)
  local count = self.count
  local width = self.right - self.left
  local spacing = width / math.max(1, count - 2)
  -- Whole-pixel scrolling: snap the phase to the pixel grid.
  local pixel_phase = math.floor(phase * spacing + 0.5) / math.max(0.001, spacing)
  local key = pixel_phase * 1e6 + (version or 0)
  if key == self.drawn_key then return end
  self.drawn_key = key
  phase = pixel_phase

  local span = self.bottom - self.top
  local down = self.direction == "down"
  local function row(fraction)
    if down then return self.top + fraction * span end
    return self.bottom - fraction * span
  end
  local baseline = down and self.top or self.bottom
  local first_index = count - #self.values + 1
  local function sample_level(index)
    local value = self.values[index - first_index + 1]
    return clamp01(level(value or 0))
  end
  local function position(index)
    return (index - 1 - phase) * spacing
  end

  local style = self.style
  if style == "columns" or style == "ticks" or style == "heat" then
    local gap = style == "columns" and 0.3 or (style == "ticks" and 0.6 or 0)
    for index = 1, count do
      local sample_index = index
      local u1 = position(sample_index)
      local u2 = u1 + spacing * (1 - gap)
      -- Heat cells run one pixel under their right neighbour, which is drawn
      -- later and opaque, so no seam shows and nothing is blended twice.
      if style == "heat" then u2 = u1 + spacing + (self.base and 1 or 0.6) end
      u1, u2 = math.max(0, u1), math.min(width, u2)
      if sample_index >= first_index and u2 - u1 > 0.2 then
        local l = sample_level(sample_index)
        local x1, x2 = self.left + u1, self.left + u2
        if style == "heat" then
          self.cell:set_polygon(self.pool[index], {
            { x1, self.top }, { x2, self.top }, { x2, self.bottom }, { x1, self.bottom },
          })
          self:shade(index, l)
        else
          local y = row(math.max(l, 0.04))
          self.cell:set_polygon(self.pool[index], {
            { x1, y }, { x2, y }, { x2, baseline }, { x1, baseline },
          })
          show(self.pool, self.pool_visible, index, 1)
        end
      else
        show(self.pool, self.pool_visible, index, 0)
      end
    end
    return
  end

  -- Visible vertices of the curve, clipped to the plot's left/right edges.
  local curve = {}
  for index = math.max(1, first_index), count - 1 do
    local u1, u2 = position(index), position(index + 1)
    if u2 > 0 and u1 < width then
      local l1, l2 = sample_level(index), sample_level(index + 1)
      local a, la, b, lb = u1, l1, u2, l2
      if u1 < 0 then
        a, la = 0, lerp(l1, l2, (0 - u1) / (u2 - u1))
      end
      if u2 > width then
        b, lb = width, lerp(l1, l2, (width - u1) / (u2 - u1))
      end
      if style == "steps" then
        -- Hold each sample until the next one arrives.
        if #curve == 0 then curve[1] = { a, la } end
        curve[#curve + 1] = { b, la }
        curve[#curve + 1] = { b, lb }
      else
        if #curve == 0 then curve[1] = { a, la } end
        curve[#curve + 1] = { b, lb }
      end
    end
  end

  local function fill_area(pool, visible, ranges)
    for chunk, range in ipairs(ranges) do
      local points = { { self.left + curve[range[1]][1], baseline } }
      for index = range[1], range[2] do
        points[#points + 1] = { self.left + curve[index][1], row(curve[index][2]) }
      end
      points[#points + 1] = { self.left + curve[range[2]][1], baseline }
      self.cell:set_polygon(pool[chunk], points)
      show(pool, visible, chunk, 1)
    end
    hide_from(pool, visible, #ranges + 1)
  end

  if #curve < 2 then
    hide_from(self.pool, self.pool_visible, 1)
    if self.under then hide_from(self.under, self.under_visible, 1) end
    return
  end

  if style == "area" or style == "steps" then
    fill_area(self.pool, self.pool_visible, chunk_ranges(#curve, MAX_POINTS))
  elseif style == "line" then
    do
      local under = resample(curve, MAX_POINTS)
      local points = { { self.left + under[1][1], baseline } }
      for _, vertex in ipairs(under) do points[#points + 1] = { self.left + vertex[1], row(vertex[2]) } end
      points[#points + 1] = { self.left + under[#under][1], baseline }
      self.cell:set_polygon(self.under[1], points)
      show(self.under, self.under_visible, 1, 0.22)
    end
    -- A ribbon: the curve offset up and down by half the stroke, out and back.
    local half = 0.9
    local ranges = chunk_ranges(#curve, MAX_POINTS // 2)
    for chunk, range in ipairs(ranges) do
      local points = {}
      for index = range[1], range[2] do
        points[#points + 1] = { self.left + curve[index][1], row(curve[index][2]) - half }
      end
      for index = range[2], range[1], -1 do
        points[#points + 1] = { self.left + curve[index][1], row(curve[index][2]) + half }
      end
      self.cell:set_polygon(self.pool[chunk], points)
      show(self.pool, self.pool_visible, chunk, 1)
    end
    hide_from(self.pool, self.pool_visible, #ranges + 1)
  elseif style == "mirror" then
    local middle = (self.top + self.bottom) / 2
    local half_span = span / 2
    local ranges = chunk_ranges(#curve, MAX_POINTS // 2)
    for chunk, range in ipairs(ranges) do
      local points = {}
      for index = range[1], range[2] do
        points[#points + 1] = { self.left + curve[index][1], middle - curve[index][2] * half_span }
      end
      for index = range[2], range[1], -1 do
        points[#points + 1] = { self.left + curve[index][1], middle + curve[index][2] * half_span }
      end
      self.cell:set_polygon(self.pool[chunk], points)
      show(self.pool, self.pool_visible, chunk, 1)
    end
    hide_from(self.pool, self.pool_visible, #ranges + 1)
  end
end

return Graph

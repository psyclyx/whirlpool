-- The angled design language as a container abstraction.
--
-- Every panel is a parallelogram: its bottom edge spans the layout box and its
-- top edge is shifted right by `slant * height`, so a slanted edge at height y
-- (measured from the top) sits `slant * (height - y)` right of the box's left
-- edge. The far side of a panel may therefore overlap its neighbour, letting
-- adjacent panels share one diagonal.
--
-- Content never needs to know this. A cell exposes:
--   * `body`   a plain rectangle inscribed in the parallelogram for the band
--              of rows the content occupies. Put rows, columns, aligned text
--              and icons in it as you would in any rectangle.
--   * `canvas` the raw layout box, for free-form vector drawing through
--              `cell:polygon`, which shears rectangular coordinates so the
--              drawing follows the slant of the surrounding panel.

local Angled = { SLANT = 0.30 }

local floor = math.floor

local function whole(value)
  return math.max(1, floor(value + 0.5))
end

-- Vertices of the panel outline, normalized to a `width` x `height` box.
-- `overlap` pixels of extra reach on the far edge let a panel tuck under its
-- right-hand neighbour: two abutting antialiased edges otherwise leave a faint
-- seam of whatever is behind them.
function Angled.points(width, height, slant, overlap)
  local shift = (slant or Angled.SLANT) * height / math.max(1, width)
  local reach = (overlap or 0) / math.max(1, width)
  return { { shift, 0 }, { 1 + shift + reach, 0 }, { 1 + reach, 1 }, { 0, 1 } }
end

-- Horizontal distance from the box's left edge to the slanted edge at `y`.
function Angled.edge(y, height, slant)
  return (slant or Angled.SLANT) * (height - y)
end

-- Convert rectangular drawing coordinates (u across, v down; both in pixels
-- within the cell) into polygon points normalized to the cell box, applying the
-- shear that keeps the drawing parallel to the panel's slanted edges.
function Angled.shear(points, width, height, slant)
  slant = slant or Angled.SLANT
  local out = {}
  for index, point in ipairs(points) do
    out[index] = { (point[1] + slant * (height - point[2])) / width, point[2] / height }
  end
  return out
end

-- The rectangle inscribed in the panel for content confined to rows
-- [top, bottom]: its left edge clears the slanted edge at the top of the band
-- and its right edge stays inside the far slanted edge at the bottom.
function Angled.inscribed(width, height, band, inset, slant)
  slant = slant or Angled.SLANT
  local top, bottom = band[1], band[2]
  inset = inset or 0
  return {
    x = slant * (height - top) + inset,
    y = top,
    width = whole(width - slant * (bottom - top) - 2 * inset),
    height = whole(bottom - top),
  }
end

local Cell = {}
Cell.__index = Cell

function Cell:polygon(spec)
  local points = spec.points
  local node = self.canvas:polygon({
    width = self.width,
    height = self.height,
    fill = spec.fill,
    points = Angled.shear(points, self.width, self.height, self.slant),
  })
  return node
end

-- Re-point a polygon created by `Cell:polygon`.
function Cell:set_polygon(node, points)
  node:set("points", Angled.shear(points, self.width, self.height, self.slant))
end

function Cell:resize(width)
  width = whole(width)
  if width == self.width then return end
  self.width = width
  self.frame:set("width", width)
  local box = Angled.inscribed(width, self.height, self.band, self.inset, self.slant)
  self.body:set("width", box.width)
  self.body:set("offset_x", box.x)
end

local Section = {}
Section.__index = Section

-- A section is one background panel holding a row of cells.
--   height  panel height
--   fill    background colour (nil for transparent)
--   slant   overrides the default slant
--   cells   { { width = w, band = { top, bottom }, inset = px }, ... }
-- The default band is the middle two thirds of the panel.
function Angled.section(parent, spec)
  local slant = spec.slant or Angled.SLANT
  local height = spec.height
  local overlap = spec.overlap or 1.5
  local width = 0
  for _, cell in ipairs(spec.cells) do width = width + whole(cell.width) end

  local frame = parent:stack({ width = width, height = height })
  local background = frame:polygon({
    fill = spec.fill or { 0, 0, 0, 0 },
    points = Angled.points(width, height, slant, overlap),
  })
  local row = frame:row({ height = height })
  local cells = {}
  for index, cell_spec in ipairs(spec.cells) do
    local cell_width = whole(cell_spec.width)
    local band = cell_spec.band or { floor(height / 6), height - floor(height / 6) }
    local inset = cell_spec.inset or 0
    local cell_frame = row:stack({ width = cell_width, height = height })
    local box = Angled.inscribed(cell_width, height, band, inset, slant)
    local column = cell_frame:column({ padding = { box.y, 0, 0, 0 } })
    local body = column:stack({ width = box.width, height = box.height, offset_x = box.x })
    cells[index] = setmetatable({
      frame = cell_frame,
      canvas = cell_frame,
      body = body,
      width = cell_width,
      height = height,
      slant = slant,
      band = band,
      inset = inset,
    }, Cell)
  end
  return setmetatable({
    frame = frame,
    background = background,
    cells = cells,
    width = width,
    height = height,
    slant = slant,
    overlap = overlap,
  }, Section)
end

function Section:set_fill(color)
  self.background:set("fill", color)
end

-- Change one cell's width (a cell of width 1 is effectively hidden) and refit the
-- panel behind the row.
function Section:set_cell_width(index, width)
  self.cells[index]:resize(width)
  local total = 0
  for _, cell in ipairs(self.cells) do total = total + cell.width end
  if total == self.width then return end
  self.width = total
  self.frame:set("width", total)
  self.background:set("points", Angled.points(total, self.height, self.slant, self.overlap))
end

-- Resize a single-cell section (window indicators, tags).
function Section:resize(width)
  width = whole(width)
  if width == self.width then return end
  self.width = width
  self.frame:set("width", width)
  self.background:set("points", Angled.points(width, self.height, self.slant, self.overlap))
  self.cells[1]:resize(width)
end

return Angled

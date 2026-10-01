-- The angled design language.
--
-- Every panel is a parallelogram: its top edge is shifted right of its bottom
-- edge by `slant * height` pixels, so panels laid side by side share one
-- diagonal. Panels size to whatever they hold; nothing here needs a width.
--
--   panel   a slanted background behind a row of content, padded so content
--           clears the slanted left edge
--   canvas  a fixed-size drawing area whose drawings lean with the panels:
--           draw in upright (u, v) pixels and they are sheared to match

local Angled = { SLANT = 0.30 }

local function slant_of(spec)
  return spec and spec.slant or Angled.SLANT
end

-- A parallelogram filling its box (vertices as box fractions plus pixel
-- offsets). `overlap` extra pixels on the far side tuck under the next panel:
-- two abutting antialiased edges would otherwise show a faint seam.
function Angled.points(height, slant, overlap)
  local shift = (slant or Angled.SLANT) * height
  overlap = overlap or 1.5
  return { { 0, 0, shift, 0 }, { 1, 0, shift + overlap, 0 }, { 1, 1, overlap, 0 }, { 0, 1, 0, 0 } }
end

-- How far the slanted left edge is from the box's left at row `y`.
function Angled.edge(height, y, slant)
  return (slant or Angled.SLANT) * (height - y)
end

local Panel = {}
Panel.__index = Panel

-- A panel in `parent`:
--   height   panel height
--   fill     background colour
--   gap      space between children
--   pad      padding inside each end (beyond what clears the slant)
--   top      the highest row content reaches (default height / 6), which sets
--            how far in content starts
-- `panel.row` takes the content.
function Angled.panel(parent, spec)
  local height = spec.height
  local frame = parent:stack({ height = height })
  local background = frame:polygon({
    fill = spec.fill or { 0, 0, 0, 0 },
    points = Angled.points(height, spec.slant, spec.overlap),
  })
  local top = spec.top or math.floor(height / 6)
  local pad = spec.pad or 0
  local row = frame:row({
    height = height, gap = spec.gap or 0, align = "center",
    padding = { 0, pad, 0, math.ceil(Angled.edge(height, top, spec.slant)) + pad },
  })
  return setmetatable({ frame = frame, background = background, row = row, height = height }, Panel)
end

function Panel:set_fill(color)
  self.background:set("fill", color)
end

function Panel:set_visible(visible)
  self.frame:set("visible", visible)
end

local Canvas = {}
Canvas.__index = Canvas

-- A drawing area `width` x `height` in `parent`. Its box is wider by the slant
-- so leaning drawings stay inside it.
function Angled.canvas(parent, spec)
  local slant = slant_of(spec)
  local node = parent:stack({ width = math.ceil(spec.width + slant * spec.height), height = spec.height })
  return setmetatable({ node = node, width = spec.width, height = spec.height, slant = slant }, Canvas)
end

-- Upright pixel points to box-relative points that lean with the panels.
function Canvas:shear(points)
  local out = {}
  for index, point in ipairs(points) do
    local u, v = point[1], point[2]
    out[index] = { 0, 0, u + self.slant * (self.height - v), v }
  end
  return out
end

function Canvas:polygon(spec)
  return self.node:polygon({ fill = spec.fill, points = self:shear(spec.points) })
end

function Canvas:set_polygon(node, points)
  node:set("points", self:shear(points))
end

-- An upright rectangle as polygon points.
function Angled.rectangle(u, v, width, height)
  return { { u, v }, { u + width, v }, { u + width, v + height }, { u, v + height } }
end

return Angled

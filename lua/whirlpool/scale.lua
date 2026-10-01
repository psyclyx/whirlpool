-- An adaptive value scale for charts.
--
-- Maps values to levels: 0..1 is the usual range, and, when `peak_range` is
-- set, 1..2 is how far a peak rises above it. The scale itself follows the
-- data: it targets the `percentile` of recent samples times `headroom`, so
-- typical values fill the usual range and only notable peaks go beyond it,
-- and it eases towards that target (quickly up, slowly down) so a chart does
-- not breathe with every sample. It draws nothing; what a level looks like is
-- up to the chart.
--
--   local scale = Scale.new({ floor = 1024 * 1024, curve = "sqrt" })
--   scale:update(elapsed, t, since, rx, tx)     -- once per redraw
--   cell_level = scale:level(value)
--   if scale.version ~= drawn_version then ... end

local series = require("whirlpool.series")

local Scale = {}
Scale.__index = Scale

Scale.defaults = {
  -- The scale never goes below this (quiet data reads quiet, not magnified).
  floor = 1,
  -- What share of recent samples the usual range should hold.
  percentile = 0.8,
  -- How far above that percentile the usual range reaches.
  headroom = 1.25,
  -- With a number, levels above 1 continue to 2 as a peak reaches this many
  -- times the scale (logarithmically); without, levels stop at 1.
  peak_range = nil,
  -- Milliseconds for the scale to move most of the way up / down.
  attack = 1000,
  decay = 2500,
  -- How a value maps into the usual range: "linear", "sqrt" (quiet values
  -- stay visible), or "log".
  curve = "sqrt",
  -- The scale changes in steps of 1/steps in log space, so an unchanged
  -- chart is not redrawn for imperceptible movements.
  steps = 40,
}

function Scale.new(options)
  local self = setmetatable({}, Scale)
  for key, value in pairs(Scale.defaults) do self[key] = value end
  for key, value in pairs(options or {}) do self[key] = value end
  self.current = self.floor
  self.version = math.floor(math.log(self.current) * self.steps)
  self.value = math.exp(self.version / self.steps)
  return self
end

-- Move towards the target set by the samples (series sharing times `t`) taken
-- after `since`, `elapsed` milliseconds after the last update.
function Scale:update(elapsed, t, since, ...)
  local typical = series.percentile(self.percentile, t, since, ...)
  local target = math.max(self.floor, typical * self.headroom)
  local current, wanted = math.log(self.current), math.log(target)
  local tau = wanted > current and self.attack or self.decay
  if elapsed > 0 then
    self.current = math.exp(current + (wanted - current) * (1 - math.exp(-elapsed / tau)))
  end
  self.version = math.floor(math.log(self.current) * self.steps)
  self.value = math.exp(self.version / self.steps)
end

local curves = {
  linear = function(ratio) return ratio end,
  sqrt = math.sqrt,
  log = function(ratio) return math.log(1 + ratio * 9) / math.log(10) end,
}

function Scale:level(value)
  local ratio = math.max(0, value) / self.value
  if ratio <= 1 then return curves[self.curve](ratio) end
  if not self.peak_range then return 1 end
  return 1 + math.min(1, math.log(ratio) / math.log(self.peak_range))
end

return Scale

-- Where a dragged window lands if dropped now: a translucent wash of the light
-- accent, a little stronger towards the middle. Drawn on the layout's `drop`
-- mark, so the surface is the space itself; nothing here knows about windows.

local theme = require("lib.theme")

-- `color` at opacity `alpha` (0..1).
local function faded(color, alpha)
  return { color[1], color[2], color[3], alpha }
end

return function(root)
  local inset = root:stack({ padding = { 6, 6, 6, 6 } })
  inset:shape({
    fill = faded(theme.light.blue, 0.10),
    fill_center = faded(theme.light.blue, 0.22),
    radius = 10,
  })
end

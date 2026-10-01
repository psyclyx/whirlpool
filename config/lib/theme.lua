-- Catppuccin Mocha, expressed in Whirlpool's normalized RGBA format.

local function rgb(hex)
  return {
    tonumber(hex:sub(1, 2), 16) / 255,
    tonumber(hex:sub(3, 4), 16) / 255,
    tonumber(hex:sub(5, 6), 16) / 255,
    1,
  }
end

local theme = {
  bg = rgb("1e1e2e"),
  surface = rgb("313244"),
  overlay = rgb("45475a"),
  muted = rgb("585b70"),
  text = rgb("cdd6f4"),
  bright = rgb("f5e0dc"),
  accent = rgb("89b4fa"),
  red = rgb("f38ba8"),
  orange = rgb("fab387"),
  yellow = rgb("f9e2af"),
  green = rgb("a6e3a1"),
  cyan = rgb("94e2d5"),
  blue = rgb("89b4fa"),
  purple = rgb("cba6f7"),
}

function theme.blend(color, alpha)
  local amount = (alpha or 100) / 255
  local inverse = 1 - amount
  return {
    color[1] * amount + theme.bg[1] * inverse,
    color[2] * amount + theme.bg[2] * inverse,
    color[3] * amount + theme.bg[3] * inverse,
    1,
  }
end

return theme

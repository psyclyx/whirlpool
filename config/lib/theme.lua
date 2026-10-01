-- The example configuration's colours, in Whirlpool's normalized RGBA.
--
-- With Stylix, home-manager provides the current scheme as the `stylix`
-- module (see services.whirlpool.modules), and roles map from its base16
-- slots as in the base16 styling guide: base00 background, base05 text,
-- base08..base0E accents. base24 schemes also have light accents
-- (base12..base17), which `theme.light` uses; a scheme without them has only
-- the plain accents there. Without Stylix the palette is Catppuccin Mocha.

local function rgb(hex)
  hex = hex:gsub("^#", "")
  return {
    tonumber(hex:sub(1, 2), 16) / 255,
    tonumber(hex:sub(3, 4), 16) / 255,
    tonumber(hex:sub(5, 6), 16) / 255,
    1,
  }
end

-- Catppuccin Mocha as a base16 scheme.
local mocha = {
  base00 = "1e1e2e", base01 = "313244", base02 = "45475a", base03 = "585b70",
  base04 = "a6adc8", base05 = "cdd6f4", base06 = "f5e0dc", base07 = "f5e0dc",
  base08 = "f38ba8", base09 = "fab387", base0A = "f9e2af", base0B = "a6e3a1",
  base0C = "94e2d5", base0D = "89b4fa", base0E = "cba6f7", base0F = "f2cdcd",
}

local found, stylix = pcall(require, "stylix")
local scheme = found and type(stylix) == "table" and stylix.colors or mocha

local function slot(name, fallback)
  return rgb(scheme[name] or mocha[name] or fallback)
end

local theme = {
  bg = slot("base00"),
  surface = slot("base01"),
  overlay = slot("base02"),
  muted = slot("base03"),
  text = slot("base05"),
  bright = slot("base07"),
  red = slot("base08"),
  orange = slot("base09"),
  yellow = slot("base0A"),
  green = slot("base0B"),
  cyan = slot("base0C"),
  blue = slot("base0D"),
  purple = slot("base0E"),
}
theme.accent = theme.blue

-- The light accents: a terminal's "bright" colours.
theme.light = {
  red = slot("base12", scheme.base08),
  yellow = slot("base13", scheme.base0A),
  green = slot("base14", scheme.base0B),
  cyan = slot("base15", scheme.base0C),
  blue = slot("base16", scheme.base0D),
  purple = slot("base17", scheme.base0E),
}

-- `color` at `alpha` (0..255) over the background, as an opaque colour.
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

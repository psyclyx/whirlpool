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
  -- Secondary text: base03 is for comments, too faint on a raised surface.
  subtle = slot("base04"),
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

-- Roles for each accent hue, so a configuration asks for a purpose rather
-- than a slot:
--   theme.green        the accent: lines, meters, plot fills
--   theme.light.green  the light accent: peaks and highlights
--   theme.panel.green  a background tinted with the hue
--   theme.ink.green    foreground in the hue (text, icons, meters) that
--                      reads on that background or the plain one: the light
--                      accent on a dark scheme, the accent on a light one
theme.polarity = found and type(stylix) == "table" and stylix.polarity or "dark"
theme.hues = { "red", "orange", "yellow", "green", "cyan", "blue", "purple" }
theme.panel, theme.ink = {}, {}
for _, hue in ipairs(theme.hues) do
  theme.panel[hue] = theme.blend(theme[hue])
  theme.ink[hue] = theme.polarity == "light" and theme[hue] or theme.light[hue] or theme[hue]
end

-- What the bar and title bars draw with:
--   bg        the bar itself
--   raised    panels on it, and title bars: base02, as base01 is barely
--             apart from base00 in many dark schemes
--   selected  the focused or hovered panel
--   text, subtle, bright  primary, secondary and emphasised text on those
--   data      plots, meters and focus lines: the accent as ink, which reads
--             on a panel where the plain accent may be too dark
--   accent    a fill behind bright text (the active tag)
-- The other hues only signal a state (good, warning, critical), never which
-- panel something is in.
theme.raised = theme.overlay
theme.selected = theme.muted
theme.data = theme.ink.blue

-- Fonts: Stylix's, else the renderer's default (empty names). `font` is for
-- labels; `font_mono` for figures, whose digits then keep their places.
local fonts = found and type(stylix) == "table" and stylix.fonts or {}
theme.font = fonts.sans or ""
theme.font_mono = fonts.monospace or ""

return theme

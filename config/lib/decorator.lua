-- Window title bars: the window's title on a strip that brightens when the
-- window has focus.

local surface = require("whirlpool.surface")
local theme = require("lib.theme")

return function(root)
  local bar = root:stack()
  local background = bar:shape({ fill = theme.blend(theme.surface, 120) })
  local row = bar:row({ padding = { 0, 12, 0, 10 }, align = "center" })
  local title = row:text({
    font_family = theme.font,
    text = "", font_size = 14, flex = 1, text_color = theme.text,
    text_valign = "middle", text_overflow = "ellipsis",
  })

  surface.on("decoration", function(window)
    title:set("text", window.title ~= "" and window.title or window.app_id)
    title:set("text_color", window.focused and theme.bright or theme.text)
    background:set("fill", window.focused and theme.blend(theme.accent, 80) or theme.blend(theme.surface, 120))
  end)
end

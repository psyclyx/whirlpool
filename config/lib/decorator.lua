-- Window title bars: the application's icon and the window's title on a
-- strip that is raised, with the accent along its top, when the window has
-- focus (as the bar shows the focused window). Dragging the strip drags the window (the layout's
-- `drag-window` decides what that means).

local surface = require("whirlpool.surface")
local Pointer = require("whirlpool.pointer")
local theme = require("lib.theme")

return function(root)
  local pointer = Pointer.new()
  surface.on("pointer", function(event) pointer:handle(event) end)

  local bar = root:stack()
  local background = bar:shape({ fill = theme.raised })
  local focus_line = bar:column():shape({ height = 2, fill = theme.data, visible = false })
  local row = bar:row({ padding = { 0, 12, 0, 8 }, gap = 6, align = "center" })
  local icon = row:icon({ icon_source = "", width = 18, height = 18, visible = false })
  local title = row:text({
    font_family = theme.font,
    -- The bar's `value` size (lib/bar.lua's type scale).
    text = "", font_size = 13, flex = 1, text_color = theme.text,
    text_valign = "middle", text_overflow = "ellipsis",
  })

  pointer:region(bar, {
    press = function(event)
      -- Where it was grabbed, so the window follows that point (right
      -- button cancels).
      if event.button == Pointer.LEFT then
        surface.act("pointer-operation", "drag-window", math.floor(event.x), math.floor(event.y))
      end
    end,
  })

  surface.on("decoration", function(window)
    local name = (window.name or "") ~= "" and window.name or window.app_id
    icon:set("icon_source", window.icon or "")
    icon:set("visible", (window.icon or "") ~= "")
    title:set("text", window.title ~= "" and window.title or name)
    title:set("text_color", window.focused and theme.bright or theme.text)
    background:set("fill", window.focused and theme.selected or theme.raised)
    focus_line:set("visible", window.focused == true)
  end)
end

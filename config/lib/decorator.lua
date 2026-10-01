local theme = require("lib.theme")

return function(parent)
  local root = parent:stack()
  local background = root:shape({ fill = theme.blend(theme.surface, 120) })
  local title = root:column({ padding = { 7, 12, 0, 10 } }):text({
    text = "",
    font_size = 14,
    text_color = theme.text,
  })
  local tabs = root:row({ opacity = 0 })
  local tab_cells = {}
  for index = 1, 8 do
    local cell = tabs:stack({ flex = 1, opacity = 0 })
    local fill = cell:shape({ fill = theme.blend(theme.muted, 60) })
    local label = cell:column({ padding = { 7, 8, 0, 8 } }):text({ text = "", font_size = 13, text_color = theme.text })
    tab_cells[index] = { cell = cell, fill = fill, label = label }
  end

  return {
    update = function(_, service, values)
      if service ~= "decoration" then return end
      local focused = values[2] == true
      local names = type(values[4]) == "table" and values[4] or {}
      local active = math.floor(tonumber(values[5]) or 1)
      title:set("text", tostring(values[1] or ""))
      title:set("text_color", focused and theme.bright or theme.text)
      background:set("fill", focused and theme.blend(theme.accent, 80) or theme.blend(theme.surface, 120))
      local tabbed = #names > 1
      title:set("opacity", tabbed and 0 or 1)
      tabs:set("opacity", tabbed and 1 or 0)
      for index, cell in ipairs(tab_cells) do
        local visible = tabbed and names[index] ~= nil
        cell.cell:set("opacity", visible and 1 or 0)
        cell.cell:set("flex", visible and 1 or 0)
        cell.label:set("text", visible and tostring(names[index]) or "")
        cell.label:set("text_color", index == active and theme.bright or theme.text)
        cell.fill:set("fill", index == active and theme.blend(theme.accent, 80) or theme.blend(theme.muted, 60))
      end
    end,
  }
end

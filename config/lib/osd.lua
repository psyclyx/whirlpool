-- The volume popup: a box with the volume as a level and a figure, shown for
-- a moment when the volume changes. Between changes it draws nothing at all,
-- so its surface is unmapped and nothing is composited for it.
--
-- Options (all optional): `duration`, how long it stays, in milliseconds.

local surface = require("whirlpool.surface")
local series = require("whirlpool.series")
local theme = require("lib.theme")

return function(root, options)
  local duration = options and options.duration or 1500
  local box = root:stack({ visible = false })
  box:shape({ fill = theme.bg, radius = 12 })
  local content = box:column({ padding = 20, gap = 10 })
  content:text({
    text = "Volume", font_family = theme.font, font_size = 15, height = 17,
    text_color = theme.subtle, text_valign = "middle",
  })
  local track = content:stack({ height = 8 })
  track:shape({ fill = theme.raised, radius = 4 })
  -- The fill is a fraction of the track: a row whose first child grows by
  -- the volume and the second by the rest.
  local level_row = track:row({})
  local filled = level_row:shape({ flex = 1, fill = theme.data, radius = 4 })
  local rest = level_row:spacer({ flex = 1 })
  local value = content:text({
    text = "", font_family = theme.font, font_size = 22, height = 26,
    text_color = theme.bright, text_valign = "middle",
  })

  local shown, until_ms, now_ms = nil, 0, 0

  surface.on("audio", function(audio)
    local percent, muted = series.last(audio.percent), series.last(audio.muted, 0) == 1
    if not percent then return end
    local key = percent .. (muted and "m" or "")
    -- The first reading is the volume as it was: no change to show.
    if shown and key ~= shown then
      local level = math.max(0, math.min(100, percent))
      filled:set("flex", math.max(1, math.floor(level)))
      rest:set("flex", math.max(0, 100 - math.floor(level)))
      filled:set("fill", muted and theme.ink.red or (percent >= 100 and theme.ink.yellow or theme.data))
      value:set("text", string.format(muted and "%.0f%% (muted)" or "%.0f%%", percent))
      until_ms = now_ms + duration
      box:set("visible", true)
    end
    shown = key
  end)

  surface.on("frame", function(frame)
    now_ms = frame.now
    if now_ms >= until_ms then box:set("visible", false) end
  end)
end

-- Whirlpool equivalent of the Tidepool/Shoal setup.
--
-- Everything is registered by key: a later `bind`, `surface` or `layout` call
-- replaces an earlier one, so a configuration can start from another and
-- override pieces of it.

local wp = require("whirlpool")
local marks = require("lib.marks")

local spawn, act = wp.spawn, wp.layout_action
local super = { "super" }
local super_shift = { "super", "shift" }
local super_ctrl = { "super", "ctrl" }
local super_ctrl_shift = { "super", "ctrl", "shift" }

wp.layout("lib.scrolling", {
  -- Column widths, as fractions of the screen, that Super+R steps through.
  widths = { 0.25, 1 / 3, 0.5, 2 / 3, 0.75, 1 },
})

wp.surface("bar", {
  provider = "river", role = "shell", placement = "all-outputs",
  edge = "bottom", height = 38, exclusive_zone = 38,
  content = "lib.bar",
})
-- The same bar as a portable layer-shell panel, for other compositors.
wp.surface("bar-portable", {
  provider = "layer-shell", role = "shell", placement = "default-output",
  edge = "bottom", height = 38, exclusive_zone = 38,
  content = "lib.bar",
})
wp.surface("titles", {
  provider = "river", role = "decoration", placement = "windows",
  edge = "top", height = 28,
  content = "lib.decorator",
})

-- Programs
wp.bind(super, "Return", spawn("foot"))
wp.bind(super, "d", spawn("fuzzel"))
wp.bind(super, "p", spawn("rofi-rbw-wayland"))
wp.bind(super, "s", spawn("whirlpool-screenshot-menu"))
wp.bind(super_shift, "q", act("close-focused"))

-- Focus, and moving windows, by direction
for key, direction in pairs({ h = "left", j = "down", k = "up", l = "right" }) do
  wp.bind(super, key, act("focus-" .. direction))
  wp.bind(super_shift, key, act("swap-" .. direction))
  -- Join the neighbour into a group.
  wp.bind(super_ctrl, key, act("absorb-" .. direction))
end
wp.bind(super_ctrl, "space", act("eject"))
wp.bind(super_ctrl_shift, "h", act("expel-left"))
wp.bind(super_ctrl_shift, "l", act("expel-right"))

-- Containers: the layout's logical focus may be a window or a group of them.
wp.bind(super, "g", act("focus-parent"))
wp.bind(super_shift, "g", act("focus-child"))
wp.bind(super, "space", act("cycle-container-mode"))
wp.bind(super, "t", act("cycle-container-mode"))
wp.bind(super, "Tab", act("focus-tab-next"))
wp.bind(super_shift, "Tab", act("focus-tab-prev"))

-- Sizes and states
wp.bind(super, "r", act("cycle-width"))
wp.bind(super_ctrl, "Left", act("shrink-width"))
wp.bind(super_ctrl, "Right", act("grow-width"))
wp.bind(super, "slash", act("toggle-fullscreen"))
wp.bind(super, "f", act("toggle-float"))

-- Monitors and tags
wp.bind(super, "comma", act("focus-output-prev"))
wp.bind(super, "period", act("focus-output-next"))
for tag = 1, 5 do
  wp.bind(super, tostring(tag), act("focus-tag", tag))
  wp.bind(super_shift, tostring(tag), act("send-to-tag", tag))
end

-- Marks: Super+M sets one, Super+' jumps to it, and so on.
marks.bind({
  mark = { super, "m" },
  ["focus-mark"] = { super, "'" },
  ["summon-mark"] = { super_shift, "m" },
  ["send-to-mark"] = { super_ctrl, "m" },
  ["clear-mark"] = { super_ctrl_shift, "m" },
})

-- Media keys
local sink = "@DEFAULT_SINK@"
wp.bind({}, "XF86AudioRaiseVolume", spawn("pactl", "set-sink-volume", sink, "+5%"))
wp.bind({}, "XF86AudioLowerVolume", spawn("pactl", "set-sink-volume", sink, "-5%"))
wp.bind({}, "XF86AudioMute", spawn("pactl", "set-sink-mute", sink, "toggle"))
wp.bind({}, "XF86AudioPlay", spawn("playerctl", "play-pause"))
wp.bind({}, "XF86AudioNext", spawn("playerctl", "next"))
wp.bind({}, "XF86AudioPrev", spawn("playerctl", "previous"))
wp.bind({}, "XF86AudioStop", spawn("playerctl", "stop"))

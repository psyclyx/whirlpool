-- Whirlpool equivalent of the current Tidepool/Shoal setup.
--
-- The compositor modifier is Alt throughout.  The old resize bindings used
-- Super+Alt; those become Alt+Ctrl with arrow keys here so the second
-- modifier remains meaningful without colliding with Alt+Ctrl absorb.

local whirlpool = require("whirlpool")
local Workspace = require("whirlpool.workspace")
local function action(name, ...)
  return { name = name, args = { ... } }
end

local alt = { "alt" }
local alt_ctrl = { "alt", "ctrl" }
local alt_ctrl_shift = { "alt", "ctrl", "shift" }

local bindings = {
  { modifiers = alt, key = "Return", action = action("spawn", "foot") },
  { modifiers = alt, key = "d", action = action("spawn", "fuzzel") },
  { modifiers = { "alt", "shift" }, key = "q", action = action("close-focused") },

  -- Directional focus
  { modifiers = alt, key = "h", action = action("focus-left") },
  { modifiers = alt, key = "l", action = action("focus-right") },
  { modifiers = alt, key = "j", action = action("focus-down") },
  { modifiers = alt, key = "k", action = action("focus-up") },

  -- Directional swap
  { modifiers = { "alt", "shift" }, key = "h", action = action("swap-left") },
  { modifiers = { "alt", "shift" }, key = "l", action = action("swap-right") },
  { modifiers = { "alt", "shift" }, key = "j", action = action("swap-down") },
  { modifiers = { "alt", "shift" }, key = "k", action = action("swap-up") },

  -- Absorb / eject / expel
  { modifiers = alt_ctrl, key = "h", action = action("absorb-left") },
  { modifiers = alt_ctrl, key = "l", action = action("absorb-right") },
  { modifiers = alt_ctrl, key = "k", action = action("absorb-up") },
  { modifiers = alt_ctrl, key = "j", action = action("absorb-down") },
  { modifiers = alt_ctrl, key = "space", action = action("eject") },
  { modifiers = alt_ctrl_shift, key = "h", action = action("expel-left") },
  { modifiers = alt_ctrl_shift, key = "l", action = action("expel-right") },

  -- Width, tabs, and outputs
  { modifiers = alt, key = "r", action = action("grow") },
  { modifiers = alt, key = "space", action = action("cycle-container-mode") },
  { modifiers = alt, key = "Tab", action = action("focus-tab-next") },
  { modifiers = { "alt", "shift" }, key = "Tab", action = action("focus-tab-prev") },
  { modifiers = alt, key = "comma", action = action("focus-output-prev") },
  { modifiers = alt, key = "period", action = action("focus-output-next") },

  -- Tags
  { modifiers = alt, key = "1", action = Workspace.focus(1) },
  { modifiers = alt, key = "2", action = Workspace.focus(2) },
  { modifiers = alt, key = "3", action = Workspace.focus(3) },
  { modifiers = alt, key = "4", action = Workspace.focus(4) },
  { modifiers = alt, key = "5", action = Workspace.focus(5) },
  { modifiers = { "alt", "shift" }, key = "1", action = Workspace.send(1) },
  { modifiers = { "alt", "shift" }, key = "2", action = Workspace.send(2) },
  { modifiers = { "alt", "shift" }, key = "3", action = Workspace.send(3) },
  { modifiers = { "alt", "shift" }, key = "4", action = Workspace.send(4) },
  { modifiers = { "alt", "shift" }, key = "5", action = Workspace.send(5) },

  -- Fullscreen and floating windows
  { modifiers = alt, key = "slash", action = action("toggle-fullscreen") },
  { modifiers = alt, key = "f", action = action("toggle-focus-float") },
  { modifiers = { "alt", "shift" }, key = "f", action = action("toggle-float") },

  -- Resize (Super+Alt in Tidepool becomes Alt+Ctrl here). Arrow keys keep
  -- these distinct from Alt+Ctrl+h/j/k/l absorb bindings.
  { modifiers = alt_ctrl, key = "Left", action = action("shrink-width") },
  { modifiers = alt_ctrl, key = "Right", action = action("grow-width") },

  -- Media
  { key = "XF86AudioRaiseVolume", action = action("spawn", "pactl", "set-sink-volume", "@DEFAULT_SINK@", "+5%") },
  { key = "XF86AudioLowerVolume", action = action("spawn", "pactl", "set-sink-volume", "@DEFAULT_SINK@", "-5%") },
  { key = "XF86AudioMute", action = action("spawn", "pactl", "set-sink-mute", "@DEFAULT_SINK@", "toggle") },
  { key = "XF86AudioPlay", action = action("spawn", "playerctl", "play-pause") },
  { key = "XF86AudioNext", action = action("spawn", "playerctl", "next") },
  { key = "XF86AudioPrev", action = action("spawn", "playerctl", "previous") },
  { key = "XF86AudioStop", action = action("spawn", "playerctl", "stop") },

  -- Launchers
  { modifiers = alt, key = "p", action = action("spawn", "rofi-rbw-wayland") },
  { modifiers = alt, key = "s", action = action("spawn", "whirlpool-screenshot-menu") },
  { modifiers = { "alt", "shift" }, key = "s", action = action("spawn", "tidepool-sign-clipboard") },
  { modifiers = { "alt", "shift" }, key = "e", action = action("spawn", "tidepool-power-menu") },
}

local shell_content = [[return require("whirlpool.shell")]]
local decoration_content = [[return require("whirlpool.decorator")]]

return whirlpool.program {
  api_version = 1,
  layout = "lib/scrolling.lua",
  bindings = bindings,
  surfaces = {
    {
      provider = "river",
      role = "shell",
      placement = "all-outputs",
      edge = "bottom",
      height = 38,
      exclusive_zone = 38,
      content = shell_content,
    },
    {
      provider = "layer-shell",
      role = "shell",
      placement = "default-output",
      edge = "bottom",
      height = 38,
      exclusive_zone = 38,
      content = shell_content,
    },
    {
      provider = "river",
      role = "decoration",
      placement = "windows",
      edge = "top",
      height = 28,
      content = decoration_content,
    },
  },
}

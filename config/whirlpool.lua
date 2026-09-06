-- Whirlpool equivalent of the current Tidepool/Shoal setup.
--
-- The compositor modifier is Alt throughout.  The old resize bindings used
-- Super+Alt; those become Alt+Ctrl with arrow keys here so the second
-- modifier remains meaningful without colliding with Alt+Ctrl absorb.

local whirlpool = require("whirlpool")
local function action(name, ...)
  return { name = name, args = { ... } }
end
local function layout(name, ...)
  return action("layout", name, ...)
end

local alt = { "alt" }
local alt_ctrl = { "alt", "ctrl" }
local alt_ctrl_shift = { "alt", "ctrl", "shift" }

local bindings = {
  { modifiers = alt, key = "Return", action = action("spawn", "foot") },
  { modifiers = alt, key = "d", action = action("spawn", "fuzzel") },
  { modifiers = { "alt", "shift" }, key = "q", action = layout("close-focused") },

  -- Directional focus
  { modifiers = alt, key = "h", action = layout("focus-left") },
  { modifiers = alt, key = "l", action = layout("focus-right") },
  { modifiers = alt, key = "j", action = layout("focus-down") },
  { modifiers = alt, key = "k", action = layout("focus-up") },

  -- Directional swap
  { modifiers = { "alt", "shift" }, key = "h", action = layout("swap-left") },
  { modifiers = { "alt", "shift" }, key = "l", action = layout("swap-right") },
  { modifiers = { "alt", "shift" }, key = "j", action = layout("swap-down") },
  { modifiers = { "alt", "shift" }, key = "k", action = layout("swap-up") },

  -- Sway-style container focus. River keeps keyboard focus on the active leaf;
  -- the layout's single logical focus may be that leaf or one of its parents.
  { modifiers = alt, key = "g", action = layout("focus-parent") },
  { modifiers = { "alt", "shift" }, key = "g", action = layout("focus-child") },

  -- Vim-style, one-shot mark prefixes. The following unmodified letter is
  -- captured only while the corresponding mode is active.
  { modifiers = alt, key = "m", action = action("enter-mode", "mark") },
  { modifiers = alt, key = "'", action = action("enter-mode", "focus-mark") },
  { modifiers = { "alt", "shift" }, key = "m", action = action("enter-mode", "summon-mark") },
  { modifiers = alt_ctrl, key = "m", action = action("enter-mode", "send-to-mark") },
  { modifiers = alt_ctrl_shift, key = "m", action = action("enter-mode", "clear-mark") },

  -- These names are opaque to Whirlpool. The selected layout controller owns
  -- their topology and movement semantics.
  { modifiers = alt_ctrl, key = "h", action = layout("absorb-left") },
  { modifiers = alt_ctrl, key = "l", action = layout("absorb-right") },
  { modifiers = alt_ctrl, key = "k", action = layout("absorb-up") },
  { modifiers = alt_ctrl, key = "j", action = layout("absorb-down") },
  { modifiers = alt_ctrl, key = "space", action = layout("eject") },
  { modifiers = alt_ctrl_shift, key = "h", action = layout("expel-left") },
  { modifiers = alt_ctrl_shift, key = "l", action = layout("expel-right") },

  -- Width, tabs, and outputs
  { modifiers = alt, key = "r", action = layout("grow-width") },
  { modifiers = alt, key = "space", action = layout("cycle-container-mode") },
  { modifiers = alt, key = "Tab", action = layout("focus-tab-next") },
  { modifiers = { "alt", "shift" }, key = "Tab", action = layout("focus-tab-prev") },
  { modifiers = alt, key = "comma", action = layout("focus-output-prev") },
  { modifiers = alt, key = "period", action = layout("focus-output-next") },

  -- Tags
  { modifiers = alt, key = "1", action = layout("focus-tag", 1) },
  { modifiers = alt, key = "2", action = layout("focus-tag", 2) },
  { modifiers = alt, key = "3", action = layout("focus-tag", 3) },
  { modifiers = alt, key = "4", action = layout("focus-tag", 4) },
  { modifiers = alt, key = "5", action = layout("focus-tag", 5) },
  { modifiers = { "alt", "shift" }, key = "1", action = layout("send-to-tag", 1) },
  { modifiers = { "alt", "shift" }, key = "2", action = layout("send-to-tag", 2) },
  { modifiers = { "alt", "shift" }, key = "3", action = layout("send-to-tag", 3) },
  { modifiers = { "alt", "shift" }, key = "4", action = layout("send-to-tag", 4) },
  { modifiers = { "alt", "shift" }, key = "5", action = layout("send-to-tag", 5) },

  -- Fullscreen and floating windows
  { modifiers = alt, key = "slash", action = layout("toggle-fullscreen") },
  { modifiers = alt, key = "f", action = layout("toggle-float") },
  { modifiers = { "alt", "shift" }, key = "f", action = layout("toggle-float") },

  -- Resize (Super+Alt in Tidepool becomes Alt+Ctrl here). Arrow keys keep
  -- these distinct from Alt+Ctrl+h/j/k/l absorb bindings.
  { modifiers = alt_ctrl, key = "Left", action = layout("shrink-width") },
  { modifiers = alt_ctrl, key = "Right", action = layout("grow-width") },

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
}

local mark_modes = { "mark", "focus-mark", "summon-mark", "send-to-mark", "clear-mark" }
for letter in string.gmatch("abcdefghijklmnopqrstuvwxyz", ".") do
  for _, mode in ipairs(mark_modes) do
    bindings[#bindings + 1] = { mode = mode, key = letter, action = layout(mode, letter) }
  end
end
for _, mode in ipairs(mark_modes) do
  bindings[#bindings + 1] = {
    mode = mode, key = "Escape", action = action("enter-mode", "default"),
  }
end

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

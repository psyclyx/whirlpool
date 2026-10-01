-- Whirlpool equivalent of the current Tidepool/Shoal setup.
--
-- The compositor modifier is Super (`mod` below), as in Tidepool. The old resize bindings used
-- Super+Alt; those become Super+Ctrl with arrow keys here so the second
-- modifier remains meaningful without colliding with Super+Ctrl absorb.

local whirlpool = require("whirlpool")
local function action(name, ...)
  return { name = name, args = { ... } }
end
local function layout(name, ...)
  return action("layout", name, ...)
end

local mod = "super"
local mod_only = { mod }
local mod_ctrl = { mod, "ctrl" }
local mod_ctrl_shift = { mod, "ctrl", "shift" }

local bindings = {
  { modifiers = mod_only, key = "Return", action = action("spawn", "foot") },
  { modifiers = mod_only, key = "d", action = action("spawn", "fuzzel") },
  { modifiers = { mod, "shift" }, key = "q", action = layout("close-focused") },

  -- Directional focus
  { modifiers = mod_only, key = "h", action = layout("focus-left") },
  { modifiers = mod_only, key = "l", action = layout("focus-right") },
  { modifiers = mod_only, key = "j", action = layout("focus-down") },
  { modifiers = mod_only, key = "k", action = layout("focus-up") },

  -- Directional swap
  { modifiers = { mod, "shift" }, key = "h", action = layout("swap-left") },
  { modifiers = { mod, "shift" }, key = "l", action = layout("swap-right") },
  { modifiers = { mod, "shift" }, key = "j", action = layout("swap-down") },
  { modifiers = { mod, "shift" }, key = "k", action = layout("swap-up") },

  -- Sway-style container focus. River keeps keyboard focus on the active leaf;
  -- the layout's single logical focus may be that leaf or one of its parents.
  { modifiers = mod_only, key = "g", action = layout("focus-parent") },
  { modifiers = { mod, "shift" }, key = "g", action = layout("focus-child") },

  -- Vim-style, one-shot mark prefixes. The following unmodified letter is
  -- captured only while the corresponding mode is active.
  { modifiers = mod_only, key = "m", action = action("enter-mode", "mark") },
  { modifiers = mod_only, key = "'", action = action("enter-mode", "focus-mark") },
  { modifiers = { mod, "shift" }, key = "m", action = action("enter-mode", "summon-mark") },
  { modifiers = mod_ctrl, key = "m", action = action("enter-mode", "send-to-mark") },
  { modifiers = mod_ctrl_shift, key = "m", action = action("enter-mode", "clear-mark") },

  -- These names are opaque to Whirlpool. The selected layout controller owns
  -- their topology and movement semantics.
  { modifiers = mod_ctrl, key = "h", action = layout("absorb-left") },
  { modifiers = mod_ctrl, key = "l", action = layout("absorb-right") },
  { modifiers = mod_ctrl, key = "k", action = layout("absorb-up") },
  { modifiers = mod_ctrl, key = "j", action = layout("absorb-down") },
  { modifiers = mod_ctrl, key = "space", action = layout("eject") },
  { modifiers = mod_ctrl_shift, key = "h", action = layout("expel-left") },
  { modifiers = mod_ctrl_shift, key = "l", action = layout("expel-right") },

  -- Width, tabs, and outputs
  { modifiers = mod_only, key = "r", action = layout("cycle-width") },
  { modifiers = mod_only, key = "space", action = layout("cycle-container-mode") },
  { modifiers = mod_only, key = "t", action = layout("cycle-container-mode") },
  { modifiers = mod_only, key = "Tab", action = layout("focus-tab-next") },
  { modifiers = { mod, "shift" }, key = "Tab", action = layout("focus-tab-prev") },
  { modifiers = mod_only, key = "comma", action = layout("focus-output-prev") },
  { modifiers = mod_only, key = "period", action = layout("focus-output-next") },

  -- Tags
  { modifiers = mod_only, key = "1", action = layout("focus-tag", 1) },
  { modifiers = mod_only, key = "2", action = layout("focus-tag", 2) },
  { modifiers = mod_only, key = "3", action = layout("focus-tag", 3) },
  { modifiers = mod_only, key = "4", action = layout("focus-tag", 4) },
  { modifiers = mod_only, key = "5", action = layout("focus-tag", 5) },
  { modifiers = { mod, "shift" }, key = "1", action = layout("send-to-tag", 1) },
  { modifiers = { mod, "shift" }, key = "2", action = layout("send-to-tag", 2) },
  { modifiers = { mod, "shift" }, key = "3", action = layout("send-to-tag", 3) },
  { modifiers = { mod, "shift" }, key = "4", action = layout("send-to-tag", 4) },
  { modifiers = { mod, "shift" }, key = "5", action = layout("send-to-tag", 5) },

  -- Fullscreen and floating windows
  { modifiers = mod_only, key = "slash", action = layout("toggle-fullscreen") },
  { modifiers = mod_only, key = "f", action = layout("toggle-float") },
  { modifiers = { mod, "shift" }, key = "f", action = layout("toggle-float") },

  -- Resize (Super+Alt in Tidepool becomes Super+Ctrl here). Arrow keys keep
  -- these distinct from Super+Ctrl+h/j/k/l absorb bindings.
  { modifiers = mod_ctrl, key = "Left", action = layout("shrink-width") },
  { modifiers = mod_ctrl, key = "Right", action = layout("grow-width") },

  -- Media
  { key = "XF86AudioRaiseVolume", action = action("spawn", "pactl", "set-sink-volume", "@DEFAULT_SINK@", "+5%") },
  { key = "XF86AudioLowerVolume", action = action("spawn", "pactl", "set-sink-volume", "@DEFAULT_SINK@", "-5%") },
  { key = "XF86AudioMute", action = action("spawn", "pactl", "set-sink-mute", "@DEFAULT_SINK@", "toggle") },
  { key = "XF86AudioPlay", action = action("spawn", "playerctl", "play-pause") },
  { key = "XF86AudioNext", action = action("spawn", "playerctl", "next") },
  { key = "XF86AudioPrev", action = action("spawn", "playerctl", "previous") },
  { key = "XF86AudioStop", action = action("spawn", "playerctl", "stop") },

  -- Launchers
  { modifiers = mod_only, key = "p", action = action("spawn", "rofi-rbw-wayland") },
  { modifiers = mod_only, key = "s", action = action("spawn", "whirlpool-screenshot-menu") },
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

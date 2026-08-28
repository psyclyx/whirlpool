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
  { modifiers = alt, key = "Return", action = action("spawn", "xdg-terminal-exec") },
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
  { modifiers = alt_ctrl, key = "space", action = action("eject") },
  { modifiers = alt_ctrl_shift, key = "h", action = action("expel-left") },
  { modifiers = alt_ctrl_shift, key = "l", action = action("expel-right") },

  -- Width, tabs, and outputs
  { modifiers = alt, key = "r", action = action("grow") },
  { modifiers = alt, key = "t", action = action("toggle-split-tabbed") },
  { modifiers = alt, key = "Tab", action = action("focus-tab-next") },
  { modifiers = { "alt", "shift" }, key = "Tab", action = action("focus-tab-prev") },

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

local shell_content = [[
return function(parent)
  local Workspace = require("whirlpool.workspace")
  local workspaces = Workspace.new({ count = 9 })

  local cyan = { 0.20, 0.70, 0.95, 1 }
  local ink = { 0.025, 0.035, 0.055, 0.96 }
  local quiet = { 0.62, 0.68, 0.74, 1 }
  local clear = { 0, 0, 0, 0 }

  -- This is ordinary retained UI. The host only supplies a surface; the bar
  -- placement and appearance remain replaceable Lua policy.
  local bar = parent:stack({ height = 36 })
  bar:shape({ fill = ink })
  local layers = bar:column()
  local strip = layers:row({ height = 34, gap = 5, padding = { 5, 10, 5, 10 } })
  strip:text({ text = "whirlpool", font_size = 14, text_color = cyan })

  local cells = {}
  for index = 1, workspaces.count do
    local cell = strip:stack({ width = 24, height = 24 })
    local background = cell:shape({ fill = clear })
    local inset = cell:column({ padding = { 4, 7, 3, 8 } })
    local label = inset:text({ text = tostring(index), font_size = 13, text_color = quiet })
    cells[index] = { background = background, label = label }
  end
  layers:shape({ height = 2, fill = cyan })

  workspaces:subscribe(function(state)
    for index, cell in ipairs(cells) do
      local active = index == state.selected
      cell.background:set("fill", active and cyan or clear)
      cell.label:set("text_color", active and ink or quiet)
    end
  end)
  return {
    update = function(_, service, values)
      workspaces:update(service, values)
    end,
  }
end
]]

return whirlpool.program {
  api_version = 1,
  layout = "lib/scrolling.lua",
  bindings = bindings,
  surfaces = {
    {
      provider = "river",
      role = "shell",
      placement = "all-outputs",
      content = shell_content,
    },
    {
      provider = "layer-shell",
      role = "shell",
      placement = "default-output",
      content = shell_content,
    },
  },
}

-- Application icons for the shell window strip. The default Skia typeface in
-- the sample environment is a Nerd Font, so these remain ordinary text.

local mappings = {
  { "alacritty", "\239\132\160" },
  { "kitty", "\239\132\160" },
  { "foot", "\239\132\160" },
  { "wezterm", "\239\132\160" },
  { "terminal", "\239\132\160" },
  { "firefox", "\239\137\169" },
  { "chromium", "\239\137\168" },
  { "chrome", "\239\137\168" },
  { "emacs", "\238\152\178" },
  { "code", "\243\176\168\158" },
  { "zed", "\243\176\172\161" },
  { "thunar", "\239\129\187" },
  { "nautilus", "\239\129\187" },
  { "spotify", "\239\134\188" },
  { "discord", "\239\142\146" },
  { "slack", "\239\134\152" },
}

local Icons = {}

function Icons.for_app(app_id)
  local normalized = string.lower(tostring(app_id or ""))
  for _, mapping in ipairs(mappings) do
    if string.find(normalized, mapping[1], 1, true) then return mapping[2] end
  end
  return "\239\139\144"
end

return Icons

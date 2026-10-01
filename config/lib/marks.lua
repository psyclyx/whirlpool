-- Vim-style marks as one-shot binding modes: a prefix chord enters a mode, the
-- next letter names the mark, and the mode ends. What a mark means (set, focus,
-- summon, send to, clear) is the layout's business; this only wires the keys.

local whirlpool = require("whirlpool")

local Marks = {}

Marks.modes = { "mark", "focus-mark", "summon-mark", "send-to-mark", "clear-mark" }

-- `prefixes` maps each mode to the chord that enters it:
--   { mark = { { "super" }, "m" }, ["focus-mark"] = { { "super" }, "'" }, ... }
function Marks.bind(prefixes)
  for _, mode in ipairs(Marks.modes) do
    local prefix = prefixes[mode]
    if prefix then whirlpool.bind(prefix[1], prefix[2], whirlpool.enter_mode(mode)) end
    for letter in string.gmatch("abcdefghijklmnopqrstuvwxyz", ".") do
      whirlpool.bind({}, letter, whirlpool.layout_action(mode, letter), { mode = mode })
    end
    whirlpool.bind({}, "Escape", whirlpool.enter_mode("default"), { mode = mode })
  end
end

return Marks

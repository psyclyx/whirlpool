-- Tidepool/Shoal behavior expressed as an ordinary Whirlpool retained tree.
-- The host provides desktop and asynchronously acquired status snapshots;
-- retained-tree policy remains identical for River and layer-shell roles.

local theme = require("whirlpool.theme")
local Status = require("whirlpool.status")

local BAR_HEIGHT = 38
local SPARK_COUNT = 15
local CLEAR = { 0, 0, 0, 0 }

local function with_alpha(color, alpha)
  return { color[1], color[2], color[3], alpha }
end

local function ellipsis(text, limit)
  text = tostring(text or "")
  local byte_length = #text
  local byte_index = 1
  local characters = 0
  local function continuation(index)
    local byte = string.byte(text, index)
    return byte and byte >= 0x80 and byte <= 0xbf
  end
  while byte_index <= byte_length and characters < limit do
    local byte = string.byte(text, byte_index)
    local width = 1
    if byte >= 0xc2 and byte <= 0xdf and continuation(byte_index + 1) then
      width = 2
    elseif byte >= 0xe0 and byte <= 0xef
      and continuation(byte_index + 1) and continuation(byte_index + 2) then
      width = 3
    elseif byte >= 0xf0 and byte <= 0xf4
      and continuation(byte_index + 1) and continuation(byte_index + 2) and continuation(byte_index + 3) then
      width = 4
    end
    byte_index = byte_index + width
    characters = characters + 1
  end
  if byte_index > byte_length then return text end
  return string.sub(text, 1, byte_index - 1) .. "…"
end

local function meter(parent, color, initial)
  local column = parent:column({ width = 8, height = BAR_HEIGHT })
  column:spacer({ flex = 1 })
  local fill = column:shape({ width = 8, height = 2, fill = color })
  local function update(percent, next_color)
    fill:set("height", math.max(2, math.floor(BAR_HEIGHT * math.min(100, math.max(0, percent or 0)) / 100 + 0.5)))
    if next_color then fill:set("fill", next_color) end
  end
  update(initial or 0)
  return update
end

local function section(parent, width, background)
  local panel = parent:stack({ width = width, height = BAR_HEIGHT })
  panel:shape({ fill = background })
  return panel:row({ padding = { 0, 9, 0, 5 }, gap = 6 })
end

local function sparkline(parent, color)
  local row = parent:row({ height = BAR_HEIGHT, gap = 2 })
  local bars = {}
  for index = 1, SPARK_COUNT do
    local column = row:column({ width = 3, height = BAR_HEIGHT })
    column:spacer({ flex = 1 })
    bars[index] = column:shape({ width = 3, height = 2, fill = color })
  end
  return function(values)
    for index, bar in ipairs(bars) do
      local value = values[index] or 0
      bar:set("height", math.max(2, math.floor((BAR_HEIGHT - 2) * math.min(1, math.max(0, value)) + 0.5)))
    end
  end
end

local function build(parent)
  local state = {
    role = "shell",
    selected = 1,
    occupied = {},
    tokens = {},
    token_count = 0,
  }

  local root = parent:stack()

  -- Full-output River shell: the flexible spacer pins the bar to the bottom.
  -- A 38px portable layer surface naturally collapses that spacer to zero.
  local shell = root:column()
  shell:spacer({ flex = 1 })
  local bar_layer = shell:stack({ height = BAR_HEIGHT })
  bar_layer:shape({ fill = theme.bg })
  local bar = bar_layer:row({ height = BAR_HEIGHT })

  local workspaces = bar:row({ height = BAR_HEIGHT, gap = 8, padding = { 0, 8, 0, 0 } })
  local workspace_cells = {}
  for index = 1, 9 do
    local cell = workspaces:stack({ width = index == 1 and 30 or 1, height = BAR_HEIGHT, opacity = index == 1 and 1 or 0 })
    local background = cell:shape({ fill = index == 1 and theme.accent or CLEAR })
    local label = cell:column({ padding = { 9, 9, 0, 10 } }):text({
      text = tostring(index),
      font_size = 16,
      text_color = index == 1 and theme.bg or theme.text,
    })
    workspace_cells[index] = { cell = cell, background = background, label = label }
  end

  local strip = bar:stack({ height = BAR_HEIGHT, flex = 1, clip = true })
  local strip_content = strip:row({ width = 1, height = BAR_HEIGHT, gap = 4 })
  local window_tokens = {}
  local function create_window_token()
    local cell = strip_content:stack({ width = 1, height = BAR_HEIGHT, opacity = 0, clip = true })
    local background = cell:shape({ fill = CLEAR, radius = 3 })
    local group_label = cell:text({ text = "", font_size = 14, text_color = theme.muted, padding = { 10, 3, 0, 3 } })
    local window = cell:row({ gap = 6, padding = { 7, 7, 7, 7 }, opacity = 0 })
    local icon = window:icon({ icon_source = "", width = 20, height = 20 })
    local labels = window:column({ gap = 1 })
    local app_id = labels:text({ text = "", height = 12, font_size = 11, text_color = theme.text })
    local title = labels:text({ text = "", height = 10, font_size = 9, text_color = theme.muted })
    window_tokens[#window_tokens + 1] = {
      cell = cell,
      background = background,
      group_label = group_label,
      window = window,
      icon = icon,
      app_id = app_id,
      title = title,
    }
  end

  local left_fade = strip:row({ width = 24, height = BAR_HEIGHT, opacity = 0 })
  local right_fade = strip:row({ height = BAR_HEIGHT, opacity = 0 })
  right_fade:spacer({ flex = 1 })
  for index = 1, 8 do
    left_fade:shape({ width = 3, height = BAR_HEIGHT, fill = with_alpha(theme.bg, (9 - index) / 8) })
    right_fade:shape({ width = 3, height = BAR_HEIGHT, fill = with_alpha(theme.bg, index / 8) })
  end

  local right = bar:row({ height = BAR_HEIGHT })

  local cpu = section(right, 112, theme.blend(theme.yellow))
  local update_cpu_spark = sparkline(cpu, theme.yellow)
  cpu:text({ text = "CPU", font_size = 12, text_color = theme.yellow, padding = { 11, 0, 0, 0 } })

  local network = section(right, 178, theme.blend(theme.cyan))
  local net_spark = network:row({ height = BAR_HEIGHT, gap = 1 })
  local rx_bars, tx_bars = {}, {}
  for index = 1, SPARK_COUNT do
    local pair = net_spark:column({ width = 2, height = BAR_HEIGHT })
    rx_bars[index] = pair:shape({ width = 2, height = 2, fill = theme.green })
    tx_bars[index] = pair:shape({ width = 2, height = 2, fill = theme.cyan })
  end
  local net_text = network:column({ gap = 1, padding = { 4, 0, 0, 0 } })
  local rx_label = net_text:text({ text = "rx 0B", font_size = 12, text_color = theme.green })
  local tx_label = net_text:text({ text = "tx 0B", font_size = 12, text_color = theme.cyan })

  local audio = section(right, 44, theme.blend(theme.purple))
  local update_audio = meter(audio, theme.purple, 0)
  local audio_label = audio:text({ text = "A", font_size = 14, text_color = theme.purple, padding = { 10, 0, 0, 0 } })

  local memory = section(right, 44, theme.blend(theme.green))
  local update_memory = meter(memory, theme.green, 0)
  memory:text({ text = "M", font_size = 14, text_color = theme.green, padding = { 10, 0, 0, 0 } })

  local disk = section(right, 44, theme.blend(theme.orange))
  local update_disk = meter(disk, theme.orange, 0)
  disk:text({ text = "D", font_size = 14, text_color = theme.orange, padding = { 10, 0, 0, 0 } })

  local battery_panel = right:stack({ width = 1, height = BAR_HEIGHT, opacity = 0 })
  battery_panel:shape({ fill = theme.blend(theme.red) })
  local battery = battery_panel:row({ padding = { 0, 9, 0, 5 }, gap = 6 })
  local update_battery = meter(battery, theme.red, 0)
  local battery_label = battery:text({ text = "B", font_size = 14, text_color = theme.red, padding = { 10, 0, 0, 0 } })

  local clock = section(right, 126, theme.blend(theme.blue))
  local clock_column = clock:column({ gap = 1, padding = { 3, 0, 0, 0 } })
  local clock_line = clock_column:row({ gap = 5 })
  local time_label = clock_line:text({ text = "--:--", font_size = 16, text_color = theme.bright })
  local dow_label = clock_line:text({ text = "---", font_size = 11, text_color = theme.text, padding = { 5, 0, 0, 0 } })
  local date_label = clock_column:text({ text = "---- -- --", font_size = 11, text_color = theme.muted })

  -- Volume OSD shares the full-output River shell instead of requiring a
  -- second native surface role. It remains transparent on portable bars.
  local osd_layer = root:column({ opacity = 0 })
  osd_layer:spacer({ height = 80 })
  local osd_row = osd_layer:row({ height = 120 })
  osd_row:spacer({ flex = 1 })
  local osd = osd_row:stack({ width = 320, height = 120 })
  osd:shape({ fill = theme.bg, radius = 12 })
  local osd_content = osd:column({ padding = { 20, 20, 20, 20 }, gap = 10 })
  osd_content:text({ text = "Volume", font_size = 14, text_color = theme.text })
  local osd_meter = osd_content:stack({ width = 280, height = 8 })
  osd_meter:shape({ fill = theme.surface, radius = 4 })
  local osd_fill = osd_meter:shape({ width = 2, height = 8, fill = theme.accent, radius = 4 })
  local osd_value = osd_content:text({ text = "0%", font_size = 22, text_color = theme.bright })
  osd_row:spacer({ flex = 1 })

  local function update_desktop(values)
    state.selected = math.floor(tonumber(values[1]) or state.selected)
    state.occupied = type(values[2]) == "table" and values[2] or state.occupied
    state.tokens = type(values[3]) == "table" and values[3] or {}
    while #window_tokens < #state.tokens do create_window_token() end

    for index, item in ipairs(workspace_cells) do
      local active = index == state.selected
      local visible = active or state.occupied[index] == true
      item.cell:set("width", visible and 30 or 1)
      item.cell:set("opacity", visible and 1 or 0)
      item.background:set("fill", active and theme.accent or CLEAR)
      item.label:set("text_color", active and theme.bg or theme.text)
    end
    for index = 1, math.max(state.token_count, #state.tokens) do
      local item = window_tokens[index]
      local token = state.tokens[index]
      if token then
        local kind = math.floor(tonumber(token[1]) or 0)
        local is_window = kind == 2
        local focused = token[5] == true
        local app_id = tostring(token[3] or "")
        local title = tostring(token[4] or "")
        item.cell:set("width", math.max(1, math.floor(tonumber(token[6]) or 1)))
        item.cell:set("opacity", 1)
        item.group_label:set("text", is_window and "" or tostring(token[2] or ""))
        item.group_label:set("opacity", is_window and 0 or 1)
        item.window:set("opacity", is_window and 1 or 0)
        item.background:set("fill", focused and theme.blend(theme.accent, 72) or CLEAR)
        local width = math.max(1, math.floor(tonumber(token[6]) or 1))
        local app_limit = math.max(4, math.floor((width - 48) / 7))
        local title_limit = math.max(5, math.floor((width - 48) / 6))
        item.icon:set("icon_source", is_window and tostring(token[7] or "") or "")
        item.app_id:set("text", is_window and ellipsis(app_id, app_limit) or "")
        item.app_id:set("text_color", focused and theme.bright or theme.text)
        item.title:set("text", is_window and ellipsis(title, title_limit) or "")
        item.title:set("text_color", focused and theme.text or theme.muted)
      else
        item.cell:set("width", 1)
        item.cell:set("opacity", 0)
      end
    end
    state.token_count = #state.tokens
    strip_content:set("width", math.max(1, math.floor(tonumber(values[5]) or 1)))
    strip_content:set("offset_x", -math.max(0, math.floor(tonumber(values[4]) or 0)))
    left_fade:set("opacity", values[6] == true and 1 or 0)
    right_fade:set("opacity", values[7] == true and 1 or 0)
  end

  local function update_status(values)
    local cpu_history = type(values[5]) == "table" and values[5] or {}
    local rx_history = type(values[10]) == "table" and values[10] or {}
    local tx_history = type(values[11]) == "table" and values[11] or {}
    local audio_percent = tonumber(values[12]) or 0
    local audio_muted = values[13] == true
    local battery_present = values[15] == true
    local battery_percent = tonumber(values[16]) or 0
    local battery_charging = values[17] == true

    update_cpu_spark(cpu_history)
    rx_label:set("text", "rx " .. Status.format_rate(values[8]))
    tx_label:set("text", "tx " .. Status.format_rate(values[9]))
    for index = 1, SPARK_COUNT do
      rx_bars[index]:set("height", math.max(2, math.floor(17 * (rx_history[index] or 0) + 0.5)))
      tx_bars[index]:set("height", math.max(2, math.floor(17 * (tx_history[index] or 0) + 0.5)))
    end
    local audio_color = audio_muted and theme.red or (audio_percent >= 100 and theme.yellow or theme.purple)
    update_audio(audio_percent, audio_color)
    audio_label:set("text", audio_muted and "X" or "A")
    audio_label:set("text_color", audio_color)
    update_memory(tonumber(values[6]) or 0)
    update_disk(tonumber(values[7]) or 0)
    if battery_present then
      local battery_color = battery_charging and theme.green
        or (battery_percent < 15 and theme.red or (battery_percent < 50 and theme.orange or theme.accent))
      battery_panel:set("width", 44)
      battery_panel:set("opacity", 1)
      update_battery(battery_percent, battery_color)
      battery_label:set("text", battery_charging and "+" or "B")
      battery_label:set("text_color", battery_color)
    else
      battery_panel:set("width", 1)
      battery_panel:set("opacity", 0)
    end
    time_label:set("text", tostring(values[1] or "--:--"))
    dow_label:set("text", tostring(values[2] or "---"))
    date_label:set("text", tostring(values[3] or "----------"))

    local visible = state.role == "shell" and values[14] == true
    osd_layer:set("opacity", visible and 0.96 or 0)
    if visible then
      osd_fill:set("width", math.max(2, math.floor(2.8 * math.min(100, audio_percent))))
      osd_fill:set("fill", audio_muted and theme.red or audio_color)
      osd_value:set("text", audio_muted and (tostring(audio_percent) .. " (muted)") or (tostring(audio_percent) .. "%"))
    end
  end

  return {
    update = function(_, service, values)
      if service == "surface-role" then
        state.role = tostring(values[1] or "shell")
      elseif service == "desktop" then
        update_desktop(values)
      elseif service == "status" then
        update_status(values)
      end
    end,
  }
end

return build

-- Small, dependency-free status providers for retained Whirlpool surfaces.
-- Polling is deliberately throttled here: the host supplies only a heartbeat,
-- while Lua owns which desktop facts it wants and how often to refresh them.

local Status = {}
Status.__index = Status

local function read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local value = file:read("*a")
  file:close()
  return value
end

local function command_line(command)
  local ok, pipe = pcall(io.popen, command, "r")
  if not ok or not pipe then return nil end
  local value = pipe:read("*l")
  pipe:close()
  return value
end

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function numbers(line)
  local result = {}
  for value in (line or ""):gmatch("%d+") do result[#result + 1] = tonumber(value) end
  return result
end

local function push_history(history, value, count)
  history[#history + 1] = clamp(value or 0, 0, 1)
  while #history > count do table.remove(history, 1) end
  while #history < count do table.insert(history, 1, 0) end
end

local function default_interface()
  local routes = read_file("/proc/net/route") or ""
  for line in routes:gmatch("[^\n]+") do
    local interface, destination = line:match("^(%S+)%s+(%S+)")
    if destination == "00000000" then return interface end
  end
  return nil
end

local function battery_path()
  local line = command_line("for p in /sys/class/power_supply/*; do [ \"$(cat \"$p/type\" 2>/dev/null)\" = Battery ] && printf '%s\\n' \"$p\" && break; done")
  if line and line ~= "" then return line end
  return nil
end

function Status.new()
  return setmetatable({
    clock = { time = "--:--", dow = "---", date = "---- -- --" },
    cpu = { percent = 0, history = {} },
    memory = { percent = 0 },
    disk = { percent = 0 },
    network = { rx = 0, tx = 0, rx_history = {}, tx_history = {} },
    audio = { percent = 0, muted = false },
    battery = { present = false, percent = 0, charging = false },
    due = {},
    previous_cpu = nil,
    previous_network = nil,
    interface = nil,
    battery_path = nil,
    last_audio = nil,
    audio_changed_at = nil,
  }, Status)
end

function Status:poll_clock(now)
  self.clock.time = os.date("%H:%M")
  self.clock.dow = os.date("%a")
  self.clock.date = os.date("%Y-%m-%d")
  self.due.clock = now + 1
end

function Status:poll_cpu(now)
  local line = (read_file("/proc/stat") or ""):match("([^\n]+)")
  local values = numbers(line)
  if #values >= 5 then
    local total = 0
    for _, value in ipairs(values) do total = total + value end
    local idle = values[4] + values[5]
    if self.previous_cpu then
      local delta_total = total - self.previous_cpu.total
      local delta_idle = idle - self.previous_cpu.idle
      if delta_total > 0 then
        self.cpu.percent = math.floor(100 * (delta_total - delta_idle) / delta_total + 0.5)
      end
    end
    self.previous_cpu = { total = total, idle = idle }
  end
  push_history(self.cpu.history, self.cpu.percent / 100, 15)
  self.due.cpu = now + 2
end

function Status:poll_memory(now)
  local data = read_file("/proc/meminfo") or ""
  local total = tonumber(data:match("MemTotal:%s+(%d+)"))
  local available = tonumber(data:match("MemAvailable:%s+(%d+)"))
  if total and available and total > 0 then
    self.memory.percent = math.floor(100 * (total - available) / total + 0.5)
  end
  self.due.memory = now + 5
end

function Status:poll_disk(now)
  local line = command_line("df -P / 2>/dev/null | tail -n 1")
  local percent = line and tonumber(line:match("(%d+)%%"))
  if percent then self.disk.percent = percent end
  self.due.disk = now + 30
end

function Status:poll_network(now)
  self.interface = self.interface or default_interface()
  local data = read_file("/proc/net/dev") or ""
  local rx, tx
  if self.interface then
    for line in data:gmatch("[^\n]+") do
      local name, rest = line:match("^%s*([^:]+):%s*(.*)")
      if name == self.interface then
        local values = numbers(rest)
        rx, tx = values[1], values[9]
        break
      end
    end
  end
  if rx and tx and self.previous_network then
    local elapsed = math.max(1, now - self.previous_network.time)
    self.network.rx = math.max(0, (rx - self.previous_network.rx) / elapsed)
    self.network.tx = math.max(0, (tx - self.previous_network.tx) / elapsed)
  end
  if rx and tx then self.previous_network = { rx = rx, tx = tx, time = now } end
  local peak = math.max(128 * 1024, self.network.rx, self.network.tx)
  push_history(self.network.rx_history, self.network.rx / peak, 15)
  push_history(self.network.tx_history, self.network.tx / peak, 15)
  self.due.network = now + 1
end

function Status:poll_audio(now)
  local line = command_line("wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null") or ""
  local volume = tonumber(line:match("Volume:%s+([%d%.]+)"))
  if volume then
    local current = { percent = math.floor(volume * 100 + 0.5), muted = line:find("%[MUTED%]") ~= nil }
    if self.last_audio and (current.percent ~= self.last_audio.percent or current.muted ~= self.last_audio.muted) then
      self.audio_changed_at = now
    end
    self.audio = current
    self.last_audio = { percent = current.percent, muted = current.muted }
  end
  self.due.audio = now + 2
end

function Status:poll_battery(now)
  self.battery_path = self.battery_path or battery_path() or false
  if self.battery_path then
    local capacity = tonumber((read_file(self.battery_path .. "/capacity") or ""):match("%d+"))
    local state = read_file(self.battery_path .. "/status") or ""
    self.battery = {
      present = capacity ~= nil,
      percent = capacity or 0,
      charging = state:match("Charging") ~= nil,
    }
  else
    self.battery.present = false
  end
  self.due.battery = now + 10
end

function Status:update()
  local now = os.time()
  if not self.due.clock or now >= self.due.clock then self:poll_clock(now) end
  if not self.due.cpu or now >= self.due.cpu then self:poll_cpu(now) end
  if not self.due.memory or now >= self.due.memory then self:poll_memory(now) end
  if not self.due.disk or now >= self.due.disk then self:poll_disk(now) end
  if not self.due.network or now >= self.due.network then self:poll_network(now) end
  if not self.due.audio or now >= self.due.audio then self:poll_audio(now) end
  if not self.due.battery or now >= self.due.battery then self:poll_battery(now) end
  return now
end

function Status.audio_visible(self, now)
  return self.audio_changed_at ~= nil and now - self.audio_changed_at < 2
end

function Status.format_rate(value)
  if value >= 1024 * 1024 then return string.format("%.1fM", value / (1024 * 1024)) end
  if value >= 1024 then return string.format("%.0fK", value / 1024) end
  return string.format("%.0fB", value)
end

return Status

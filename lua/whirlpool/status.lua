-- Pure formatting helpers for status snapshots supplied by the host.
-- Acquisition and polling belong to asynchronous host services; surface Lua
-- never opens files, reads pipes, starts processes, or waits on timers.

local Status = {}

-- Three significant digits, so a changing value keeps a stable width.
local function significant(value)
  if value >= 100 then return string.format("%.0f", value) end
  if value >= 10 then return string.format("%.1f", value) end
  return string.format("%.2f", value)
end

local UNITS = { "B", "K", "M", "G", "T", "P" }

local function scaled(value)
  value = math.max(0, tonumber(value) or 0)
  local unit = 1
  while value >= 1024 and unit < #UNITS do
    value = value / 1024
    unit = unit + 1
  end
  return value, UNITS[unit]
end

-- A rate as a fixed-shape readout: a number of at most three characters and a
-- unit, chosen so the pair never reads "1024K" or "0.0M". Callers place the
-- number right-aligned in a fixed slot and the unit in another, so the unit
-- letter stays put and only the digits change.
function Status.rate_parts(value)
  local amount, unit = scaled(value)
  -- "1000K" would need four characters; it is "1.0M".
  for index, name in ipairs(UNITS) do
    if name == unit and amount >= 999.5 and UNITS[index + 1] then
      amount, unit = amount / 1024, UNITS[index + 1]
    end
    if name == unit then break end
  end
  local number
  if unit == "B" then
    number = string.format("%.0f", amount)
  elseif amount < 9.95 then
    number = string.format("%.1f", amount)
  else
    number = string.format("%.0f", amount)
  end
  -- Byte rates read "KB/s", "MB/s": the capital B tells them apart from the
  -- lowercase-b bit rates used for network links.
  return number, (unit == "B" and "B" or unit .. "B") .. "/s"
end

-- The same figure without the "B/s", for tight spaces: "120", "M".
function Status.compact_rate_parts(value)
  local number, unit = Status.rate_parts(value)
  local compact = unit:gsub("B/s", "")
  return number, compact == "" and "B" or compact
end

-- "10.9/126G": a part of a whole, both in the whole's unit, so it is clear
-- what the first number is out of.
function Status.format_ratio(part, whole)
  part, whole = math.max(0, tonumber(part) or 0), math.max(0, tonumber(whole) or 0)
  local scaled_whole, unit = scaled(whole)
  local divisor = whole / math.max(scaled_whole, 1e-9)
  if scaled_whole == 0 then divisor = 1 end
  return significant(part / divisor) .. "/" .. significant(scaled_whole) .. (unit == "B" and "B" or unit)
end

function Status.format_rate(value)
  local number, unit = Status.rate_parts(value)
  return number .. unit
end

-- Sizes carry no per-second suffix: "412G", "3.41T", "812M".
function Status.format_bytes(value)
  local amount, unit = scaled(value)
  if unit == "B" then return string.format("%.0fB", amount) end
  return significant(amount) .. unit
end

-- Network throughput in bits per second, the unit link speeds and speed tests
-- use (SI: 1 Gb = 10^9 bits). Same fixed shape as `rate_parts`.
function Status.bit_rate_parts(bytes_per_second)
  local amount = math.max(0, tonumber(bytes_per_second) or 0) * 8
  local units = { "b", "kb", "Mb", "Gb", "Tb" }
  local unit = 1
  while amount >= 999.5 and unit < #units do
    amount = amount / 1000
    unit = unit + 1
  end
  local number
  if unit == 1 then
    number = string.format("%.0f", amount)
  elseif amount < 9.95 then
    number = string.format("%.1f", amount)
  else
    number = string.format("%.0f", amount)
  end
  return number, units[unit] .. "/s"
end

return Status

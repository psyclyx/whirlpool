-- Pure formatting helpers for status snapshots supplied by the host.
-- Acquisition and polling belong to asynchronous host services; surface Lua
-- never opens files, reads pipes, starts processes, or waits on timers.

local Status = {}

function Status.format_rate(value)
  value = tonumber(value) or 0
  if value >= 1024 * 1024 * 1024 then return string.format("%.2fG/s", value / (1024 * 1024 * 1024)) end
  if value >= 1024 * 1024 then return string.format("%.1fM/s", value / (1024 * 1024)) end
  if value >= 1024 then return string.format("%.0fK/s", value / 1024) end
  return string.format("%.0fB/s", value)
end

return Status

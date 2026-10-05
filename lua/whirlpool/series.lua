-- Working with the timestamped series measurement sources deliver.
--
-- A source arrives as columns: `t`, sample times in milliseconds on the same
-- clock as `frame` ticks, and one array per field, oldest first. Counters
-- (network and disk bytes) are cumulative, so a rate is a difference over a
-- span of time, and the span is the caller's choice.

local series = {}

-- The newest value of `values`, or `fallback` when there is none.
function series.last(values, fallback)
  if not values or #values == 0 then return fallback end
  return values[#values]
end

-- Index of the newest sample taken at or before time `at`, or nil if every
-- sample is later.
function series.index_at(t, at)
  local low, high, found = 1, #t, nil
  while low <= high do
    local middle = (low + high) // 2
    if t[middle] <= at then found, low = middle, middle + 1 else high = middle - 1 end
  end
  return found
end

-- Per second, how fast cumulative `values` grew over the `window` milliseconds
-- ending at sample `index` (default: the newest). A window reaching before the
-- first sample uses what there is.
function series.rate(t, values, window, index)
  index = index or #t
  if index < 2 then return 0 end
  local start = series.index_at(t, t[index] - window) or 1
  if start >= index then start = index - 1 end
  local elapsed = t[index] - t[start]
  if elapsed <= 0 then return 0 end
  return math.max(0, (values[index] - values[start]) / elapsed * 1000)
end

-- The rate at every sample whose trailing `window` the samples cover in
-- full, as `times, rates`. Earlier samples are left out rather than read as
-- a rate over less time (the first would read 0), so a chart of them never
-- shows a dip that is only missing history.
function series.rates(t, values, window)
  local times, rates = {}, {}
  for index = 2, #t do
    if t[index] - window >= t[1] then
      times[#times + 1] = t[index]
      rates[#rates + 1] = series.rate(t, values, window, index)
    end
  end
  return times, rates
end

-- The largest value among samples taken after time `since`.
function series.peak(t, values, since)
  local peak = 0
  for index = #t, 1, -1 do
    if t[index] < since then break end
    peak = math.max(peak, values[index])
  end
  return peak
end

-- The `p`th percentile (0..1) of the values taken after time `since`, from
-- one or more series sharing the times `t`: the level that fraction of recent
-- samples stay at or below. 0 when there are none.
function series.percentile(p, t, since, ...)
  local recent = {}
  for _, values in ipairs({ ... }) do
    for index = #t, 1, -1 do
      if t[index] < since then break end
      recent[#recent + 1] = values[index]
    end
  end
  if #recent == 0 then return 0 end
  table.sort(recent)
  return recent[math.max(1, math.ceil(p * #recent))]
end

return series

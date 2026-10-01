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

-- The rate at every sample (each over its own trailing `window`), aligned with
-- `t`; the first sample has nothing before it and reads 0.
function series.rates(t, values, window)
  local result = {}
  for index = 1, #t do result[index] = series.rate(t, values, window, index) end
  return result
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

return series

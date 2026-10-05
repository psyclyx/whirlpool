-- The measurement sources lib.bar draws from, registered in one call so a
-- configuration using the bar gets each new one without listing it:
--
--   require("lib.sources").register()
--   require("lib.sources").register({ gpu = false, disks = { every = 2000 } })
--
-- Overrides go by name: a spec replaces the default, false leaves the source
-- out. Plots show 12.5 s of history, and the traffic charts' scales follow
-- 30 s (lib.bar's `scale_history`), so those sources keep that much; a source
-- that keeps less than a chart shows leaves the chart's left end empty.
-- `keep = 0` keeps only the latest sample.

local whirlpool = require("whirlpool")

local Sources = {}

Sources.defaults = {
  { "cpu", { every = 500, keep = 16000 } },
  { "network", { every = 500, keep = 32000 } },
  { "disks", { every = 1000, keep = 32000 } },
  { "memory", { every = 2000, keep = 0 } },
  { "sensors", { every = 2000, keep = 0 } },
  -- NVIDIA only (nvidia-smi); without one, the GPU panel stays hidden.
  { "gpu", { every = 1000, keep = 16000 } },
  -- Audio listens for changes; `every` is only how soon it retries if pactl
  -- stops.
  { "audio", { keep = 0 } },
  { "battery", { every = 10000, keep = 0 } },
}

function Sources.register(overrides)
  overrides = overrides or {}
  for _, entry in ipairs(Sources.defaults) do
    local name, spec = entry[1], entry[2]
    local override = overrides[name]
    if override ~= false then whirlpool.source(name, override or spec) end
  end
end

return Sources

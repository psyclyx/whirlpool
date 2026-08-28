-- Public program vocabulary. Native bindings install the constructors and
-- host-owned callbacks; this module intentionally contains no River-shaped API.
local whirlpool = {}

function whirlpool.program(spec)
  assert(type(spec) == "table", "program specification must be a table")
  assert(spec.api_version == 1, "unsupported whirlpool API version")
  local allowed = { api_version = true, layout = true, bindings = true, surfaces = true }
  for key in pairs(spec) do
    assert(allowed[key], "unsupported whirlpool program field: " .. tostring(key))
  end
  return spec
end

return whirlpool

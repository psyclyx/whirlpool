-- Whirlpool's configuration vocabulary.
--
-- A configuration is ordinary Lua that registers what it wants, one keyed entry
-- at a time: key bindings, the layout policy, surfaces. Registering under a key
-- that already exists replaces that entry, and registering nil removes it, so a
-- configuration can build on another (require it, then override pieces) with no
-- all-in-one program table. Nothing here is River-shaped.
--
-- Layouts and surfaces run in their own Lua states, so they are named by module
-- (`lib.bar` is `lib/bar.lua` beside the configuration) and receive their
-- options as plain data: tables, strings, numbers and booleans.

local whirlpool = {}

local registry = {
  bindings = {}, binding_order = {}, binding_listed = {},
  surfaces = {}, surface_order = {}, surface_listed = {},
  sources = {}, source_order = {}, source_listed = {},
  layout = nil,
}

-- Actions ------------------------------------------------------------------

-- An action the host performs. `whirlpool.spawn` and friends cover the
-- built-in ones; layout actions are opaque names the layout module handles.
function whirlpool.action(name, ...)
  return { name = name, args = { ... } }
end

function whirlpool.spawn(...) return whirlpool.action("spawn", ...) end
function whirlpool.enter_mode(mode) return whirlpool.action("enter-mode", mode) end
function whirlpool.layout_action(name, ...) return whirlpool.action("layout", name, ...) end

-- Bindings -----------------------------------------------------------------

local function binding_key(mode, modifiers, key)
  local sorted = {}
  for index, modifier in ipairs(modifiers) do sorted[index] = string.lower(modifier) end
  table.sort(sorted)
  return mode .. "\0" .. table.concat(sorted, "+") .. "\0" .. key
end

-- Bind `key` (with `modifiers`, in `mode`) to `action`, replacing whatever that
-- chord did before. A nil action unbinds it.
--   whirlpool.bind({ "super" }, "Return", whirlpool.spawn("foot"))
--   whirlpool.bind({ "super" }, "Return", nil, { mode = "default" })
function whirlpool.bind(modifiers, key, action, options)
  assert(type(modifiers) == "table", "binding modifiers must be a list")
  assert(type(key) == "string" and key ~= "", "binding key must be a key name")
  assert(action == nil or (type(action) == "table" and type(action.name) == "string"),
    "binding action must come from whirlpool.action or a helper")
  local mode = options and options.mode or "default"
  local id = binding_key(mode, modifiers, key)
  if not registry.binding_listed[id] then
    registry.binding_listed[id] = true
    registry.binding_order[#registry.binding_order + 1] = id
  end
  registry.bindings[id] = action and { mode = mode, modifiers = modifiers, key = key, action = action } or nil
end

-- Surfaces -----------------------------------------------------------------

local surface_fields = {
  provider = "string", role = "string", placement = "string", content = "string",
  edge = "string", height = "number", exclusive_zone = "number", options = "table",
}

-- Register a surface under `name`, replacing any surface of that name. `spec`:
--   provider, role, placement   where and how it is shown (host-defined)
--   edge, height, exclusive_zone
--   content                     module name, e.g. "lib.bar"
--   options                     plain data handed to the content module
-- A nil spec removes the surface.
function whirlpool.surface(name, spec)
  assert(type(name) == "string" and name ~= "", "surface name must be a string")
  if spec ~= nil then
    assert(type(spec) == "table", "surface spec must be a table")
    for field, value in pairs(spec) do
      local wanted = surface_fields[field]
      assert(wanted, "unknown surface field: " .. tostring(field))
      assert(type(value) == wanted, "surface field " .. field .. " must be a " .. wanted)
    end
  end
  if not registry.surface_listed[name] then
    registry.surface_listed[name] = true
    registry.surface_order[#registry.surface_order + 1] = name
  end
  registry.surfaces[name] = spec
end

-- Sources ------------------------------------------------------------------

-- Services every surface already receives; a source cannot take their names.
local reserved_services = { desktop = true, frame = true, ["surface-role"] = true, decoration = true, pointer = true }
local source_kinds = { cpu = true, memory = true, network = true, disks = true, audio = true, battery = true, command = true }

-- Measure something periodically under `name`; surfaces receive it as the
-- service of that name (`whirlpool.surface.on(name, fn)`), as timestamped
-- series. `spec`:
--   kind     cpu, memory, network, disks, audio, battery, or command
--            (default: the name)
--   every    milliseconds between samples (default 1000)
--   keep     milliseconds of history to keep (default 30000)
--   command  for kind = "command": the program and its arguments; its trimmed
--            output arrives as `text`
-- A nil spec stops the source.
function whirlpool.source(name, spec)
  assert(type(name) == "string" and name ~= "", "source name must be a string")
  assert(not reserved_services[name], "source name " .. name .. " is a built-in service")
  if spec ~= nil then
    assert(type(spec) == "table", "source spec must be a table")
    local kind = spec.kind or name
    assert(source_kinds[kind], "unknown source kind: " .. tostring(kind))
    assert(kind ~= "command" or type(spec.command) == "table", "a command source needs a command list")
    spec = { kind = kind, every = spec.every or 1000, keep = spec.keep or 30000, command = spec.command or {} }
  end
  if not registry.source_listed[name] then
    registry.source_listed[name] = true
    registry.source_order[#registry.source_order + 1] = name
  end
  registry.sources[name] = spec
end

-- Layout -------------------------------------------------------------------

-- Use the layout module `module` (e.g. "lib.scrolling"). A module returning a
-- table with `new` is constructed with `options`.
function whirlpool.layout(module, options)
  assert(type(module) == "string" and module ~= "", "layout must be a module name")
  registry.layout = { module = module, options = options or {} }
end

-- Plain data across Lua states -----------------------------------------------

-- Lua source for a constructor of `value`, which must be plain data.
function whirlpool.serialize(value, path)
  path = path or "options"
  local kind = type(value)
  if kind == "string" then return string.format("%q", value) end
  if kind == "boolean" then return tostring(value) end
  if kind == "number" then
    assert(value == value and value ~= math.huge and value ~= -math.huge, path .. " is not a finite number")
    if math.type and math.type(value) == "integer" then return tostring(value) end
    return string.format("%.17g", value)
  end
  assert(kind == "table", path .. " is a " .. kind .. ", which cannot be passed on")
  local keys = {}
  for key in pairs(value) do
    assert(type(key) == "string" or type(key) == "number", path .. " has a " .. type(key) .. " key")
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) == "number"
  end)
  local parts = {}
  for _, key in ipairs(keys) do
    local child = whirlpool.serialize(value[key], path .. "." .. tostring(key))
    parts[#parts + 1] = "[" .. whirlpool.serialize(key, path) .. "]=" .. child
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- The registered configuration as the host reads it.
function whirlpool._build()
  local bindings = {}
  for _, id in ipairs(registry.binding_order) do
    if registry.bindings[id] then bindings[#bindings + 1] = registry.bindings[id] end
  end
  local surfaces = {}
  for _, name in ipairs(registry.surface_order) do
    local spec = registry.surfaces[name]
    if spec then
      local entry = { name = name }
      for field, value in pairs(spec) do entry[field] = value end
      entry.options = whirlpool.serialize(spec.options or {}, "surface " .. name .. " options")
      surfaces[#surfaces + 1] = entry
    end
  end
  local sources = {}
  for _, name in ipairs(registry.source_order) do
    local spec = registry.sources[name]
    if spec then
      sources[#sources + 1] = { name = name, kind = spec.kind, every = spec.every, keep = spec.keep, command = spec.command }
    end
  end
  local layout = registry.layout
  return {
    bindings = bindings,
    surfaces = surfaces,
    sources = sources,
    layout = layout and {
      module = layout.module,
      options = whirlpool.serialize(layout.options, "layout options"),
    } or nil,
  }
end

return whirlpool

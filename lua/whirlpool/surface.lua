-- Inside a surface: handlers for the host's named services, one per service.
-- Registering a handler for a service replaces the previous one; nil removes
-- it. Content modules register what they draw from and return nothing.
--
--   local surface = require("whirlpool.surface")
--   surface.on("desktop", function(values) ... end)

local surface = { handlers = {} }

function surface.on(service, handler)
  assert(type(service) == "string", "service name must be a string")
  assert(handler == nil or type(handler) == "function", "handler must be a function")
  surface.handlers[service] = handler
end

-- Each value of an update is delivered in order: most services send one (an
-- object of named fields), event services such as `pointer` one per event.
function surface.dispatch(service, values)
  local handler = surface.handlers[service]
  if not handler then return end
  for _, value in ipairs(values) do handler(value, service) end
end

-- Ask the host to do something, e.g. `surface.act("layout", "focus-window", id)`
-- or `surface.act("spawn", "foot")`. Arguments are strings (numbers convert).
-- A decoration, from the press of a button held on it, may ask for
-- `surface.act("pointer-operation", "drag-window", args...)`: River takes the
-- pointer until release, and the layout action is told the motion, then
-- `args` (the right button cancels).
-- The host decides what each name means; unknown ones are ignored.
function surface.act(name, ...)
  whirlpool_native_act(name, ...)
end

return surface

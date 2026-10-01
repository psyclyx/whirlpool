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

function surface.dispatch(service, values)
  local handler = surface.handlers[service]
  if handler then handler(values, service) end
end

return surface

-- Ordinary workspace provider convention over Whirlpool's generic named
-- service/action values. Hosts do not know this module or its semantics.

local Workspace = {}
Workspace.__index = Workspace

function Workspace.new(options)
  options = options or {}
  return setmetatable({
    count = options.count or 9,
    selected = options.selected or 1,
    listeners = {},
  }, Workspace)
end

function Workspace:subscribe(listener)
  assert(type(listener) == "function", "workspace listener must be a function")
  self.listeners[#self.listeners + 1] = listener
  listener(self)
  return listener
end

function Workspace:update(service, values)
  if service ~= "workspaces" then return false end
  local selected = tonumber(values[1])
  if not selected or selected < 1 or selected > self.count then return false end
  self.selected = math.floor(selected)
  for _, listener in ipairs(self.listeners) do listener(self) end
  return true
end

function Workspace:labels()
  local labels = {}
  for index = 1, self.count do
    labels[index] = index == self.selected and ("[" .. index .. "]") or tostring(index)
  end
  return labels
end

function Workspace.focus(index)
  return { name = "focus-tag", args = { index } }
end

function Workspace.send(index)
  return { name = "send-to-tag", args = { index } }
end

return Workspace

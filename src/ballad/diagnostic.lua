local diagnostic = {}

local Diagnostic = {}
Diagnostic.__index = Diagnostic

local ORDER = { "subject", "message", "expected", "actual", "hint" }

local function display(value)
  if type(value) == "table" then
    local parts = {}
    for _, item in ipairs(value) do parts[#parts + 1] = tostring(item) end
    if #parts > 0 then return table.concat(parts, ", ") end
  end
  return tostring(value)
end

function Diagnostic:render()
  local lines = { "[" .. self.code .. "] " .. (self.message or "Ballad control failed") }
  for _, key in ipairs(ORDER) do
    local value = self[key]
    if value ~= nil and not (key == "message") then
      lines[#lines + 1] = "  " .. key .. ": " .. display(value)
    end
  end
  if self.node then lines[#lines + 1] = "  node: " .. tostring(self.node) end
  return table.concat(lines, "\n")
end

Diagnostic.__tostring = Diagnostic.render

function diagnostic.new(spec)
  if type(spec) == "string" then spec = { message = spec } end
  if type(spec) ~= "table" then error("diagnostic requires a string or table") end
  local value = {}
  for key, item in pairs(spec) do value[key] = item end
  value.code = value.code or "ballad_failure"
  if type(value.code) ~= "string" or not value.code:match("^[a-z][a-z0-9_]*$") then
    error("diagnostic code must match ^[a-z][a-z0-9_]*$")
  end
  if type(value.message) ~= "string" or value.message == "" then
    error("diagnostic message must be a non-empty string")
  end
  return setmetatable(value, Diagnostic)
end

function diagnostic.is(value)
  return getmetatable(value) == Diagnostic
end

function diagnostic.raise(spec)
  error(diagnostic.is(spec) and spec or diagnostic.new(spec), 0)
end

function diagnostic.render(value)
  return diagnostic.is(value) and value:render() or tostring(value)
end

return diagnostic

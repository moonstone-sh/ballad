local control = {}

local Value = {}
Value.__index = Value
Value.__newindex = function() error("control values are immutable") end
Value.__metatable = "BalladControlValue"

local Predicate = {}
Predicate.__index = Predicate
Predicate.__newindex = function() error("control predicates are immutable") end
Predicate.__metatable = "BalladControlPredicate"

local VALUE_STATE = setmetatable({}, { __mode = "k" })
local PREDICATE_STATE = setmetatable({}, { __mode = "k" })

local function validate_serializable(value, subject, seen)
  local kind = type(value)
  if kind == "nil" or kind == "string" or kind == "boolean" then return end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      error(subject .. " contains a non-finite number")
    end
    return
  end
  if kind ~= "table" then error(subject .. " must be serializable, got " .. kind) end
  if getmetatable(value) ~= nil then error(subject .. " must not use table metatables") end
  seen = seen or {}
  if seen[value] then error(subject .. " must not contain cycles") end
  seen[value] = true
  local numeric_keys = 0
  local string_keys = 0
  local maximum = 0
  for key, item in pairs(value) do
    local key_kind = type(key)
    if key_kind ~= "string" and key_kind ~= "number" then
      error(subject .. " contains unsupported " .. key_kind .. " key")
    end
    if key_kind == "number" then
      if key < 1 or key ~= math.floor(key) then error(subject .. " contains an invalid array index") end
      numeric_keys = numeric_keys + 1
      if key > maximum then maximum = key end
    else
      string_keys = string_keys + 1
    end
    validate_serializable(item, subject, seen)
  end
  if numeric_keys > 0 and string_keys > 0 then error(subject .. " must not mix array and object keys") end
  if numeric_keys > 0 and maximum ~= numeric_keys then error(subject .. " must not contain missing array entries") end
  seen[value] = nil
end

local function same(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  for key, value in pairs(left) do
    if not same(value, right[key]) then return false end
  end
  for key in pairs(right) do
    if left[key] == nil then return false end
  end
  return true
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

local function describe(value)
  local kind = type(value)
  if kind == "string" then return string.format("%q", value) end
  if kind ~= "table" then return tostring(value) end
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(left, right)
    if type(left) ~= type(right) then return type(left) < type(right) end
    return left < right
  end)
  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = "[" .. describe(key) .. "]=" .. describe(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function Value:eq(expected, opts)
  local state = assert(VALUE_STATE[self], "invalid control value")
  validate_serializable(expected, "control comparison")
  return state.context:_control_predicate("eq", { self }, {
    expected = expected,
    result = same(state.value, expected),
  }, opts)
end

function Value:one_of(expected, opts)
  local state = assert(VALUE_STATE[self], "invalid control value")
  if type(expected) ~= "table" then error("control one_of expects an array") end
  validate_serializable(expected, "control one_of values")
  local matched = false
  for _, item in ipairs(expected) do
    if same(state.value, item) then matched = true; break end
  end
  return state.context:_control_predicate("one_of", { self }, {
    expected = expected,
    result = matched,
  }, opts)
end

function Value:present(opts)
  local state = assert(VALUE_STATE[self], "invalid control value")
  return state.context:_control_predicate("present", { self }, {
    result = state.value ~= nil and state.value ~= "",
  }, opts)
end

function Value:get()
  return copy(assert(VALUE_STATE[self], "invalid control value").value)
end

function Predicate:result()
  return assert(PREDICATE_STATE[self], "invalid control predicate").value
end

function control.new_value(context, spec)
  validate_serializable(spec.value, "control value " .. tostring(spec.name))
  local value = setmetatable({}, Value)
  VALUE_STATE[value] = {
    context = context,
    node_id = spec.node_id,
    name = spec.name,
    value = copy(spec.value),
    source = spec.source,
    identity = copy(spec.identity),
  }
  return value
end

function control.new_predicate(context, spec)
  local predicate = setmetatable({}, Predicate)
  PREDICATE_STATE[predicate] = {
    context = context,
    node_id = spec.node_id,
    name = spec.name,
    value = spec.value == true,
    expression = spec.expression,
    identity = copy(spec.identity),
  }
  return predicate
end

function control.is_value(value) return type(value) == "table" and VALUE_STATE[value] ~= nil end
function control.is_predicate(value) return type(value) == "table" and PREDICATE_STATE[value] ~= nil end
function control.context(value)
  local state = VALUE_STATE[value] or PREDICATE_STATE[value]
  return state and state.context or nil
end
function control.node_id(value)
  local state = VALUE_STATE[value] or PREDICATE_STATE[value]
  return state and state.node_id or nil
end
function control.name(value)
  local state = VALUE_STATE[value] or PREDICATE_STATE[value]
  return state and state.name or nil
end
function control.expression(value)
  local state = PREDICATE_STATE[value]
  return state and state.expression or nil
end
function control.identity(value)
  local state = VALUE_STATE[value] or PREDICATE_STATE[value]
  return state and copy(state.identity) or nil
end
function control.result(value)
  local state = PREDICATE_STATE[value]
  return state and state.value or false
end
function control.validate_serializable(value, subject) return validate_serializable(value, subject or "control value") end
function control.copy_serializable(value)
  validate_serializable(value, "control value")
  return copy(value)
end
function control.describe(value) return describe(value) end

return control

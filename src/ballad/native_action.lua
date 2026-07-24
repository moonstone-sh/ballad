---@meta

---Reusable, cacheable native work shared by finite pipelines and watcher reactions.
local native_action = {}

local cache = require("ballad.cache")
local fs = require("ballad.fs")
local native_runner = require("ballad.native_runner")
local path = require("ballad.path")
local process = require("ballad.process")
local dkjson = require("dkjson")

local Action = {}
Action.__index = Action

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end

local function validate(opts)
  if type(opts) ~= "table" then error("task.native expects an options table") end
  if type(opts.id) ~= "string" or opts.id == "" then
    error("task.native requires a stable non-empty id")
  end
  if type(opts.tool) ~= "string" and type(opts.cmd) ~= "string" then
    error("task.native requires tool or cmd")
  end
  if opts.inputs and type(opts.inputs) ~= "table" then error("task.native inputs must be an array") end
  if opts.outputs and type(opts.outputs) ~= "table" then error("task.native outputs must be an array") end
  if opts.toolchain and type(opts.toolchain) ~= "table" then
    error("task.native toolchain must be { command = 'tool --version' }")
  end
  if opts.toolchain and type(opts.toolchain.command) ~= "string" then
    error("task.native toolchain.command must be a command string")
  end
end

---@param opts NativeTaskOpts
---@return NativeAction
function native_action.new(opts)
  validate(opts)
  return setmetatable({ opts = copy(opts) }, Action)
end

---@param value any
---@return boolean
function native_action.is_action(value)
  return getmetatable(value) == Action
end

---@return table
function Action:to_table()
  return copy(self.opts)
end

local function toolchain_fingerprint(opts)
  if type(opts.toolchain_fingerprint) == "string" then return opts.toolchain_fingerprint end
  if opts.toolchain and opts.toolchain.command then
    return process.capture(opts.toolchain.command .. " 2>&1")
  end
  return nil
end

local function ensure_output_parents(outputs)
  for _, output in ipairs(outputs or {}) do
    local parent = path.dirname(output)
    if parent ~= "." and parent ~= "" then fs.mkdir(parent) end
  end
end

local function failure_message(opts, result)
  if result.missing_tool then
    return "Native action failed: tool not found: " .. result.tool .. "\n\n" ..
      "Action: " .. opts.id .. "\n" ..
      "Hint: Install the helper or configure this action to use a different tool."
  end
  if result.exit_code ~= 0 then
    return "Native action failed: " .. opts.id .. "\n\n" ..
      "Exit code: " .. tostring(result.exit_code) .. "\n" ..
      (result.stderr ~= "" and ("Stderr:\n" .. result.stderr) or "")
  end
  return "Native action completed but did not produce declared output:\n\n" ..
    "Action: " .. opts.id .. "\n\nMissing outputs:\n  " .. table.concat(result.missing_outputs or {}, "\n  ")
end

---@param action NativeAction
---@return table result
function native_action.run(action)
  if not native_action.is_action(action) then error("native_action.run expects a NativeAction") end
  local opts = action:to_table()
  opts.toolchain_fingerprint = toolchain_fingerprint(opts)
  local cacheable = opts.cacheable ~= false
  local key = cacheable and cache.compute_native_key(opts, "ballad.action", "native") or nil
  if key then
    local entry = cache.read(key)
    if entry and cache.outputs_valid(entry) then
      print("Cache hit: native action (" .. opts.id .. ")")
      return { ok = true, cache_hit = true, outputs = opts.outputs or {}, cache_key = key }
    end
  end

  ensure_output_parents(opts.outputs)
  local result = native_runner.run(opts)
  if not result.ok then error(failure_message(opts, result)) end
  if key then cache.store(key, nil, opts.outputs or {}) end
  result.cache_hit = false
  result.cache_key = key
  return result
end

---@param filepath string
function native_action.run_file(filepath)
  local content = fs.read_file(filepath)
  if not content then error("Cannot read native action spec: " .. filepath) end
  local spec, _, err = dkjson.decode(content)
  if not spec then error("Invalid native action spec " .. filepath .. ": " .. tostring(err)) end
  native_action.run(native_action.new(spec))
end

---@param action NativeAction
---@param filepath string
function native_action.write_file(action, filepath)
  local parent = path.dirname(filepath)
  if parent ~= "." and parent ~= "" then fs.mkdir(parent) end
  fs.write_file(filepath, dkjson.encode(action:to_table()) .. "\n")
end

native_action.Action = Action

return native_action

local pipeline = require("ballad.pipeline")
local plugin_host = require("ballad.plugin_host")

---@alias PartitureFn fun(ctx: PipelineContext): any

local partiture = {}

---@param fn PartitureFn
---@param jobs? integer
---@param invocation_args? string[] opaque arguments supplied after `ballad play <file> --`
---@return Pipeline
function partiture.build(fn, jobs, invocation_args)
  local host = plugin_host.new()
  local p = pipeline.new(host, jobs, invocation_args)
  local ok, err = pcall(fn, p:context())
  if not ok then
    error("partiture construction failed: " .. tostring(err))
  end
  return p
end

---@param filepath string
---@param jobs? integer
---@param invocation_args? string[] opaque arguments supplied after `ballad play <file> --`
---@return Pipeline
function partiture.load(filepath, jobs, invocation_args)
  local chunk, err = loadfile(filepath)
  if not chunk then
    error("Failed to load partiture file '" .. filepath .. "': " .. tostring(err))
  end
  local ok, result = pcall(chunk)
  if not ok then
    error("Partiture file '" .. filepath .. "' failed to evaluate: " .. tostring(result))
  end
  if type(result) ~= "function" then
    error("Partiture file '" .. filepath .. "' must return a function (ballad.partiture(...))")
  end
  return partiture.build(result, jobs, invocation_args)
end

---@param fn PartitureFn
---@return PartitureFn
function partiture.partiture(fn)
  return fn
end

return partiture

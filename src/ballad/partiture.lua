local pipeline = require("ballad.pipeline")
local plugin_host = require("ballad.plugin_host")

local partiture = {}

function partiture.build(fn, jobs)
  local host = plugin_host.new()
  local p = pipeline.new(host, jobs)
  local ok, err = pcall(fn, p:context())
  if not ok then
    error("partiture construction failed: " .. tostring(err))
  end
  return p
end

function partiture.load(filepath, jobs)
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
  return partiture.build(result, jobs)
end

function partiture.partiture(fn)
  return fn
end

return partiture

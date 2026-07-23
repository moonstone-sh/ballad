local process = require("ballad.process")

local path = {}

function path.join(...)
  local parts = { ... }
  return (table.concat(parts, "/"):gsub("//+", "/"))
end

function path.dirname(value)
  return value:match("^(.*)/[^/]+$") or "."
end

function path.basename(value)
  return value:match("([^/]+)$") or value
end

function path.is_absolute(value)
  return value:sub(1, 1) == "/"
end

function path.absolute(value)
  if path.is_absolute(value) then return value end
  local cwd = process.capture("pwd -P")
  return path.join(cwd, value)
end

function path.relative(value, root)
  if value == root then return "." end

  local prefix = root .. "/"
  if value:sub(1, #prefix) ~= prefix then
    process.fail(value .. " is outside " .. root)
  end

  return value:sub(#prefix + 1)
end

function path.module_name(relative_path)
  return relative_path:gsub("%.lua$", ""):gsub("/init$", ""):gsub("/", ".")
end

function path.abi_directory(abi)
  local major, minor = abi:match("^lua(%d)(%d)$")
  if major and minor then return major .. "." .. minor end
  major, minor = abi:match("^lua%-(%d)%.(%d)$")
  if major and minor then return major .. "." .. minor end
  return abi
end

return path

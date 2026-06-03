local toml = require("ballad.toml")

local lockfile = {}

function lockfile.parse(content)
  local packages = {}
  local current

  for raw_line in (content or ""):gmatch("[^\r\n]+") do
    local line = raw_line:match("^%s*(.-)%s*$")

    if line == "[[package]]" then
      current = {}
      packages[#packages + 1] = current
    elseif current then
      local key, value = line:match("^([%w_]+)%s*=%s*(.-)%s*$")

      if key then
        current[key] = value and (value:match('^%s*"(.-)"%s*$') or value:match("^%s*'(.-)'%s*$") or value:match("^%s*(.-)%s*$"))
      end
    end
  end

  return packages
end

function lockfile.package_for_source(packages, source)
  for _, package in ipairs(packages) do
    local hash = package.artifact_hash and package.artifact_hash:gsub("^b3:", "")

    if hash and source:find(hash, 1, true) then
      package.artifact_path = package.artifact_path or source:match("^(.-)/files/")
      return package
    end
  end

  return nil
end

return lockfile

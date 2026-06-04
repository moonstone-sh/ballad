local toml = require("ballad.toml")

local lockfile = {}

function lockfile.parse(content)
  local packages = {}
  local current
  local in_array = false
  local array_key = nil
  local array_lines = {}

  for raw_line in (content or ""):gmatch("[^\r\n]+") do
    local line = raw_line:match("^%s*(.-)%s*$")

    if line == "[[package]]" then
      if current then
        packages[#packages + 1] = current
      end
      current = {}
      in_array = false
      array_key = nil
      array_lines = {}
    elseif current then
      if in_array then
        table.insert(array_lines, line)
        if line:match("%]") then
          -- close array
          local arr_text = table.concat(array_lines, " ")
          local items = {}
          for item in arr_text:gmatch('"([^"]+)"') do
            items[#items + 1] = item
          end
          current[array_key] = items
          in_array = false
          array_key = nil
          array_lines = {}
        end
      else
        local key, value = line:match("^([%w_]+)%s*=%s*(.-)%s*$")
        if key then
          if value:match("^%[") then
            in_array = true
            array_key = key
            array_lines = { value }
            if value:match("%]") then
              -- single-line array
              local items = {}
              for item in value:gmatch('"([^"]+)"') do
                items[#items + 1] = item
              end
              current[key] = items
              in_array = false
              array_key = nil
              array_lines = {}
            end
          else
            current[key] = value and (value:match('^%s*"(.-)"%s*$') or value:match("^%s*'(.-)'%s*$") or value:match("^%s*(.-)%s*$"))
          end
        end
      end
    end
  end

  if current then
    packages[#packages + 1] = current
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

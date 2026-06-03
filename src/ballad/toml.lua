local toml = {}

local function strip_quotes(value)
  return value:match('^%s*"(.-)"%s*$')
    or value:match("^%s*'(.-)'%s*$")
    or value:match("^%s*(.-)%s*$")
end

function toml.parse(content)
  local result = {}
  local section = result

  for raw_line in content:gmatch("[^\r\n]+") do
    local line = raw_line:gsub("%s+#.*$", ""):match("^%s*(.-)%s*$")
    local section_name = line:match("^%[([^%]]+)%]$")

    if section_name then
      section = result

      for part in section_name:gmatch("[^.]+") do
        section[part] = section[part] or {}
        section = section[part]
      end
    else
      local key, value = line:match('^"?([^"=]+)"?%s*=%s*(.-)%s*$')

      if key and value then
        section[key:match("^%s*(.-)%s*$")] = strip_quotes(value)
      end
    end
  end

  return result
end

return toml

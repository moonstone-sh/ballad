local toml = {}

local function strip_quotes(value)
  return value:match('^%s*"(.-)"%s*$')
    or value:match("^%s*'(.-)'%s*$")
    or value:match("^%s*(.-)%s*$")
end

local function parse_value(value)
  local trimmed = value:match("^%s*(.-)%s*$")
  if trimmed:match("^%[.*%]$") then
    local items = {}
    for item in trimmed:sub(2, -2):gmatch('"(.-)"') do
      items[#items + 1] = item
    end
    if #items == 0 then
      for item in trimmed:sub(2, -2):gmatch("'(.-)'") do
        items[#items + 1] = item
      end
    end
    return items
  end
  return strip_quotes(value)
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
        section[key:match("^%s*(.-)%s*$")] = parse_value(value)
      end
    end
  end

  return result
end

return toml

local table_util = {}

function table_util.sorted_keys(map)
  local keys = {}

  for key in pairs(map) do
    keys[#keys + 1] = key
  end

  table.sort(keys)

  return keys
end

return table_util

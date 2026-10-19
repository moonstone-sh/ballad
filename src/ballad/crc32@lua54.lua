-- CRC-32 for Lua 5.4: native integer operators. See crc32.lua (fallback).
local lookup = {}
for i = 0, 255 do
  local crc = i
  for _ = 1, 8 do
    if crc & 1 == 1 then
      crc = 0xEDB88320 ~ (crc >> 1)
    else
      crc = crc >> 1
    end
  end
  lookup[i] = crc
end

---@param data string
---@return integer crc non-negative, below 2^32
return function(data)
  local crc = 0xFFFFFFFF
  for i = 1, #data do
    crc = lookup[(crc ~ string.byte(data, i)) & 0xFF] ~ (crc >> 8)
  end
  return crc ~ 0xFFFFFFFF
end

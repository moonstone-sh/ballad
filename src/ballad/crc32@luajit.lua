-- CRC-32 for LuaJIT: the built-in `bit` library. See crc32.lua (fallback).
local bit = require("bit")
local bxor, rshift, band = bit.bxor, bit.rshift, bit.band

local lookup = {}
for i = 0, 255 do
  local crc = i
  for _ = 1, 8 do
    if band(crc, 1) == 1 then
      crc = bxor(0xEDB88320, rshift(crc, 1))
    else
      crc = rshift(crc, 1)
    end
  end
  lookup[i] = crc
end

---@param data string
---@return integer crc non-negative, below 2^32
return function(data)
  local crc = 0xFFFFFFFF
  for i = 1, #data do
    crc = bxor(lookup[band(bxor(crc, string.byte(data, i)), 0xFF)], rshift(crc, 8))
  end
  -- `bit` results are signed 32-bit; report the unsigned value.
  return bxor(crc, 0xFFFFFFFF) % 0x100000000
end

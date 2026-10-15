-- CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320) for the zip writer.
--
-- This is the untagged fallback: it runs on every Lua and picks its bit
-- operations at load time. Moonstone environments that select flavor
-- variants load `crc32@luajit.lua` or `crc32@lua54.lua` instead, which use
-- their interpreter's operations directly. All three return the checksum as a
-- non-negative integer below 2^32.

local bxor, rshift

local ok_bit, bit = pcall(require, "bit")
if ok_bit and type(bit) == "table" and bit.bxor then
  -- LuaJIT (or PUC 5.1 with LuaBitOp). Results are signed 32-bit; the final
  -- value is normalized below.
  bxor, rshift = bit.bxor, bit.rshift
elseif type(bit32) == "table" then
  bxor, rshift = bit32.bxor, bit32.rshift
else
  -- Lua 5.3+ has native integer operators. They are compiled from a string
  -- because older parsers reject `~` and `>>` even in a branch never taken.
  local compile = loadstring or load
  local native = compile("return function(a, b) return a ~ b end, function(a, n) return a >> n end")
  if native then
    bxor, rshift = native()
  else
    -- PUC Lua 5.1 without LuaBitOp: arithmetic on non-negative 32-bit values.
    rshift = function(a, n) return math.floor(a / 2 ^ n) end
    bxor = function(a, b)
      local result, place = 0, 1
      while a > 0 or b > 0 do
        if a % 2 ~= b % 2 then result = result + place end
        a, b, place = math.floor(a / 2), math.floor(b / 2), place * 2
      end
      return result
    end
  end
end

local POLY, MASK = 0xEDB88320, 0xFFFFFFFF

local lookup = {}
for i = 0, 255 do
  local crc = i
  for _ = 1, 8 do
    if crc % 2 == 1 then
      crc = bxor(POLY, rshift(crc, 1))
    else
      crc = rshift(crc, 1)
    end
  end
  lookup[i] = crc
end

---@param data string
---@return integer crc non-negative, below 2^32
return function(data)
  local crc = MASK
  for i = 1, #data do
    crc = bxor(lookup[bxor(crc, string.byte(data, i)) % 256], rshift(crc, 8))
  end
  return bxor(crc, MASK) % 0x100000000
end

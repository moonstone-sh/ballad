local archive = {}
local bit = require("bit")

-- CRC32 lookup table
local crc_table = {}
for i = 0, 255 do
  local crc = i
  for _ = 1, 8 do
    if crc % 2 == 1 then
      crc = bit.bxor(0xEDB88320, bit.rshift(crc, 1))
    else
      crc = bit.rshift(crc, 1)
    end
  end
  crc_table[i] = crc
end

local function crc32(data)
  local crc = 0xFFFFFFFF
  for i = 1, #data do
    local byte = string.byte(data, i)
    crc = bit.bxor(crc_table[bit.band(bit.bxor(crc, byte), 0xFF)], bit.rshift(crc, 8))
  end
  return bit.bxor(crc, 0xFFFFFFFF)
end

local function write_u16(v)
  return string.char(bit.band(v, 0xFF), bit.band(bit.rshift(v, 8), 0xFF))
end

local function write_u32(v)
  local a = bit.band(v, 0xFF)
  local b = bit.band(bit.rshift(v, 8), 0xFF)
  local c = bit.band(bit.rshift(v, 16), 0xFF)
  local d = bit.band(bit.rshift(v, 24), 0xFF)
  return string.char(a, b, c, d)
end

-- Parse a Unix timestamp into DOS time/date.
-- DOS date format: bits 15-9 = year-1980, 8-5 = month, 4-0 = day
-- DOS time format: bits 15-11 = hour, 10-5 = minute, 4-0 = second/2
local function unix_to_dos(timestamp)
  if not timestamp or timestamp < 0 then
    return 0x0000, 0x0000
  end
  local t = os.date("*t", timestamp)
  local year = t.year
  if year < 1980 then
    return 0x0000, 0x0000
  end
  local dos_date = bit.bor(bit.lshift(year - 1980, 9), bit.lshift(t.month, 5), t.day)
  local dos_time = bit.bor(bit.lshift(t.hour, 11), bit.lshift(t.min, 5), math.floor(t.sec / 2))
  return dos_time, dos_date
end

local function get_fixed_dos_time()
  local epoch = os.getenv("SOURCE_DATE_EPOCH")
  if epoch then
    return unix_to_dos(tonumber(epoch))
  end
  return 0x0000, 0x0000  -- 1980-01-01 00:00:00
end

---Write a deterministic zip archive using STORE (no compression).
---@param entries table[] list of {path=string, data=string|nil, src=string|nil}
---@param out_path string destination file path
---@param opts table|nil {deterministic=boolean}
function archive.zip_store(entries, out_path, opts)
  opts = opts or {}
  local deterministic = opts.deterministic ~= false

  -- Sort entries by path for stable ordering
  table.sort(entries, function(a, b)
    return a.path < b.path
  end)

  local dos_time, dos_date = get_fixed_dos_time()
  local out = assert(io.open(out_path, "wb"))

  local cd_entries = {}
  local offset = 0

  for _, entry in ipairs(entries) do
    local data
    if entry.data then
      data = entry.data
    elseif entry.src then
      local f = assert(io.open(entry.src, "rb"))
      data = f:read("*a")
      f:close()
    else
      data = ""
    end

    local name = entry.path:gsub("\\", "/")
    local crc = crc32(data)
    local size = #data

    -- Local file header
    local lfh = {}
    table.insert(lfh, write_u32(0x04034b50))        -- signature
    table.insert(lfh, write_u16(0x0014))            -- version needed (2.0)
    table.insert(lfh, write_u16(0x0000))            -- general purpose bit flag
    table.insert(lfh, write_u16(0x0000))            -- compression method: STORE
    table.insert(lfh, write_u16(dos_time))          -- last mod file time
    table.insert(lfh, write_u16(dos_date))          -- last mod file date
    table.insert(lfh, write_u32(crc))               -- crc-32
    table.insert(lfh, write_u32(size))              -- compressed size
    table.insert(lfh, write_u32(size))              -- uncompressed size
    table.insert(lfh, write_u16(#name))             -- file name length
    table.insert(lfh, write_u16(0x0000))            -- extra field length
    table.insert(lfh, name)                         -- file name

    local lfh_bytes = table.concat(lfh)
    out:write(lfh_bytes)
    out:write(data)

    table.insert(cd_entries, {
      name = name,
      crc = crc,
      size = size,
      offset = offset,
    })

    offset = offset + #lfh_bytes + size
  end

  local cd_offset = offset
  local cd_size = 0

  -- Central directory
  for _, cd in ipairs(cd_entries) do
    local cdf = {}
    table.insert(cdf, write_u32(0x02014b50))        -- signature
    table.insert(cdf, write_u16(0x0314))            -- version made by (Unix, 2.0)
    table.insert(cdf, write_u16(0x0014))            -- version needed
    table.insert(cdf, write_u16(0x0000))            -- general purpose bit flag
    table.insert(cdf, write_u16(0x0000))            -- compression method: STORE
    table.insert(cdf, write_u16(dos_time))          -- last mod file time
    table.insert(cdf, write_u16(dos_date))          -- last mod file date
    table.insert(cdf, write_u32(cd.crc))            -- crc-32
    table.insert(cdf, write_u32(cd.size))           -- compressed size
    table.insert(cdf, write_u32(cd.size))           -- uncompressed size
    table.insert(cdf, write_u16(#cd.name))          -- file name length
    table.insert(cdf, write_u16(0x0000))            -- extra field length
    table.insert(cdf, write_u16(0x0000))            -- file comment length
    table.insert(cdf, write_u16(0x0000))            -- disk number start
    table.insert(cdf, write_u16(0x0000))            -- internal file attributes
    table.insert(cdf, write_u32(0x81a40000))       -- external file attributes (regular file, rw-r--r--)
    table.insert(cdf, write_u32(cd.offset))         -- relative offset of local header
    table.insert(cdf, cd.name)                      -- file name

    local cdf_bytes = table.concat(cdf)
    out:write(cdf_bytes)
    cd_size = cd_size + #cdf_bytes
  end

  -- End of central directory record
  local eocd = {}
  table.insert(eocd, write_u32(0x06054b50))       -- signature
  table.insert(eocd, write_u16(0x0000))           -- disk number
  table.insert(eocd, write_u16(0x0000))           -- disk with central directory
  table.insert(eocd, write_u16(#cd_entries))      -- entries on this disk
  table.insert(eocd, write_u16(#cd_entries))        -- total entries
  table.insert(eocd, write_u32(cd_size))            -- central directory size
  table.insert(eocd, write_u32(cd_offset))          -- central directory offset
  table.insert(eocd, write_u16(0x0000))            -- comment length

  out:write(table.concat(eocd))
  out:close()
end

return archive

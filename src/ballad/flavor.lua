-- Moonstone Lua flavors, as far as Ballad needs them.
--
-- A package may ship `foo@lua54.lua` and `foo@luajit.lua` beside `foo.lua`.
-- They are variants of one module, `foo`: Ballad exports all of them
-- unchanged, and the consumer's `moon sync` projects the one matching its
-- flavor as `foo.lua`. Ballad only has to avoid treating `foo@lua54` as a
-- module of its own when it derives module names.
--
-- The rule belongs to Moonstone (`moonstone.variants`). It is used when the
-- environment provides it; the copy below covers older Moonstone releases and
-- plain Lua, and recognizes exactly the same file names.

local flavor = {}

local DIMENSION = {
  lua51 = 1, lua52 = 1, lua53 = 1, lua54 = 1, lua55 = 1, luajit = 1, luau = 1,
  linux = 2, macos = 2, windows = 2, freebsd = 2,
  x86_64 = 3, aarch64 = 3, riscv64 = 3,
}

local function builtin_parse(file_name)
  local base, ext = file_name:match("^(.+)(%.[^.@/\\]+)$")
  if not base then return nil end
  local stem, tags = base:match("^([^@]+)(@.+)$")
  if not stem then return nil end
  local list = {}
  for tag in tags:gmatch("@([^@]*)") do
    if not DIMENSION[tag] then return nil end
    list[#list + 1] = tag
  end
  local previous = 0
  for _, tag in ipairs(list) do
    if DIMENSION[tag] <= previous then
      return false, file_name .. ": tags must be in language, os, arch order, at most one each"
    end
    previous = DIMENSION[tag]
  end
  return { stem = stem, ext = ext, tags = list }
end

local moonstone_variants
do
  local ok, variants = pcall(require, "moonstone.variants")
  if ok and type(variants) == "table" and type(variants.parse) == "function" then
    moonstone_variants = variants
  end
end

---Split a file name (no directory) into variant parts.
---@param file_name string e.g. "lexer@lua54.lua"
---@return {stem:string, ext:string, tags:string[]}|nil|false variant nil for an ordinary file, false if malformed
---@return string? message
function flavor.parse(file_name)
  if moonstone_variants then return moonstone_variants.parse(file_name) end
  return builtin_parse(file_name)
end

---The path a variant file stands for: `src/foo@lua54.lua` -> `src/foo.lua`.
---Ordinary and malformed names are returned unchanged.
---@param relative_path string
---@return string
function flavor.module_file(relative_path)
  local dir, file_name = relative_path:match("^(.-)([^/\\]*)$")
  local variant = flavor.parse(file_name)
  if not variant then return relative_path end
  return dir .. variant.stem .. variant.ext
end

---Parse a flavor id such as `lua54-aarch64-macos` or `luajit-x86_64-linux`.
---@param id string
---@return {id:string, family:string, level:integer, os:string, arch:string}|nil
function flavor.parse_id(id)
  if type(id) ~= "string" then return nil end
  local language, arch, os_name = id:match("^([%w]+)%-([%w_]+)%-([%w]+)$")
  if not language then return nil end
  local level = tonumber(language:match("^lua(5%d)$"))
  if level then return { id = id, family = "lua", level = level, os = os_name, arch = arch } end
  if language == "luajit" or language == "luau" then
    return { id = id, family = language, level = 51, os = os_name, arch = arch }
  end
  return nil
end

---The flavor a build is for: `MOONSTONE_TARGET` when set (Moonstone sets it
---for `moon run`/`moon exec` unless the caller already did), otherwise the
---environment's `moonstone.target`, otherwise nil (unknown; plain Lua or an
---older Moonstone).
---@return {id:string, family:string, level:integer, os:string, arch:string}|nil
function flavor.target()
  local from_env = os.getenv("MOONSTONE_TARGET")
  if from_env and from_env ~= "" then return flavor.parse_id(from_env) end
  local ok, target = pcall(require, "moonstone.target")
  if ok and type(target) == "table" and type(target.id) == "string" then
    return flavor.parse_id(target.id)
  end
  return nil
end

return flavor

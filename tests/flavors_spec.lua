-- Lua flavor support: the crc32 compat module and its variants, and variant
-- file names in module-name derivation. Runs on any Lua; see test_flavors.sh.
local root = assert(os.getenv("BALLAD_ROOT"), "BALLAD_ROOT is required")
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path

local failures = 0
local function check(cond, message)
  if not cond then
    failures = failures + 1
    io.stderr:write("FAIL: " .. message .. "\n")
  end
end
local function eq(actual, expected, message)
  check(actual == expected, message .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local runtime = type(jit) == "table" and "luajit" or _VERSION:gsub("^Lua ", "lua"):gsub("%.", "")

-- crc32: the untagged fallback and the variant for this interpreter agree.
local blob = {}
for i = 0, 255 do blob[#blob + 1] = string.char(i) end
blob = string.rep(table.concat(blob), 64)
local cases = {
  { "", 0 },
  { "123456789", 0xCBF43926 },
  { "The quick brown fox jumps over the lazy dog", 0x414FA339 },
  { blob, nil },
}

local implementations = { { "crc32.lua", require("ballad.crc32") } }
local variant = ({ luajit = "crc32@luajit.lua", lua54 = "crc32@lua54.lua" })[runtime]
if variant then
  implementations[#implementations + 1] = { variant, assert(loadfile(root .. "/src/ballad/" .. variant))() }
end

local blob_crc = implementations[1][2](blob)
for _, impl in ipairs(implementations) do
  local name, crc32 = impl[1], impl[2]
  for _, case in ipairs(cases) do
    local value = crc32(case[1])
    local expected = case[2] or blob_crc
    eq(value, expected, name .. " crc of " .. #case[1] .. " bytes")
    check(value >= 0 and value < 0x100000000 and value % 1 == 0, name .. " returns an unsigned 32-bit value")
    if math.type then eq(math.type(value), "integer", name .. " returns an integer") end
  end
end

-- Variant file names stand for their untagged module.
local flavor = require("ballad.flavor")
local path = require("ballad.path")
local deps = require("ballad.deps")

for _, case in ipairs({
  { "foo@lua54.lua", "foo.lua" },
  { "src/pkg/fs@lua51@windows.lua", "src/pkg/fs.lua" },
  { "src/pkg/init@luajit.lua", "src/pkg/init.lua" },
  { "parser_luajit.lua", "parser_luajit.lua" },    -- `_` is not a separator
  { "name@thing.lua", "name@thing.lua" },          -- unknown tag: ordinary module
  { "lexer@linux@lua54.lua", "lexer@linux@lua54.lua" }, -- malformed: left alone
}) do
  eq(flavor.module_file(case[1]), case[2], "module_file(" .. case[1] .. ")")
end
eq(flavor.parse("lexer@linux@lua54.lua"), false, "out-of-order tags are malformed")
eq(path.module_name("src/pkg/fs@lua54.lua"), "src.pkg.fs", "path.module_name strips tags")
eq(path.module_name("pkg/init@luajit.lua"), "pkg", "path.module_name strips tags before init")
eq(path.module_name("pkg/name@thing.lua"), "pkg.name@thing", "path.module_name keeps unknown tags")
local internal = deps.build_internal_modules({ "lua/my_plugin/fs@lua54.lua", "lua/my_plugin/fs@luajit.lua" })
check(internal["my_plugin.fs"], "deps.build_internal_modules maps variants to their module")
check(not internal["my_plugin.fs@lua54"], "deps.build_internal_modules does not invent tagged modules")

local id = flavor.parse_id("luajit-x86_64-linux")
check(id and id.family == "luajit" and id.level == 51 and id.os == "linux" and id.arch == "x86_64", "parse_id(luajit-x86_64-linux)")
id = flavor.parse_id("lua54-aarch64-macos")
check(id and id.family == "lua" and id.level == 54 and id.os == "macos" and id.arch == "aarch64", "parse_id(lua54-aarch64-macos)")
eq(flavor.parse_id("lua54"), nil, "parse_id rejects a bare language")

local expected_target = os.getenv("BALLAD_EXPECT_TARGET")
if expected_target then
  local target = flavor.target()
  eq(target and target.id, expected_target, "flavor.target() follows MOONSTONE_TARGET")
end

-- When Moonstone's own rule is on the path, Ballad must agree with it.
local ok, variants = pcall(require, "moonstone.variants")
if ok then
  local target = { id = "probe", os = "macos", arch = "aarch64" }
  if runtime == "luajit" then target.family, target.level = "luajit", 51
  else target.family, target.level = "lua", tonumber(runtime:sub(4)) end
  local chosen = variants.resolve("ballad.crc32", target, root .. "/src/?.lua")
  eq(chosen and chosen:match("[^/]+$"), variant, "moonstone.variants selects the expected crc32 file")
end

if failures > 0 then
  io.stderr:write(failures .. " flavor check(s) failed on " .. runtime .. "\n")
  os.exit(1)
end
print("flavors_spec: ok on " .. runtime .. (ok and " (checked against moonstone.variants)" or ""))

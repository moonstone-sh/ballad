local source = debug.getinfo(1, "S").source
local script = source:sub(1, 1) == "@" and source:sub(2) or source
script = script:gsub("\\", "/")
local src = script:match("^(.*)/[^/]+$") or "src"
local root = src:match("^(.*)/src$") or "."

local lua_version = _VERSION:match("%d+%.%d+") or "5.4"
package.path = src .. "/?.lua;" .. src .. "/?/init.lua;"
  .. root .. "/.moonstone/env/share/lua/" .. lua_version .. "/?.lua;"
  .. root .. "/.moonstone/env/share/lua/" .. lua_version .. "/?/init.lua;"
  .. package.path

local cli = require("ballad.cli")

cli.main(arg)


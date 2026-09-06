local source = debug.getinfo(1, "S").source
local script = source:sub(1, 1) == "@" and source:sub(2) or source
local src = script:match("^(.*)/[^/]+$") or "src"
local root = src:match("^(.*)/src$") or "."

package.path = src .. "/?.lua;" .. src .. "/?/init.lua;"
  .. root .. "/.moonstone/env/share/lua/5.1/?.lua;"
  .. root .. "/.moonstone/env/share/lua/5.1/?/init.lua;"
  .. package.path

local cli = require("ballad.cli")

cli.main(arg)


#!/usr/bin/env sh
set -eu

BALLAD_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-conventions.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/project/src/core" "$WORK_DIR/project/generated"
mkdir -p "$WORK_DIR/project/src/package"
printf '%s\n' 'return {}' > "$WORK_DIR/project/src/package.lua"
printf '%s\n' 'return {}' > "$WORK_DIR/project/src/package/internal.lua"
printf '%s\n' 'return {}' > "$WORK_DIR/project/src/core/init.lua"
printf '%s\n' 'ignored' > "$WORK_DIR/project/src/core/debug.tmp"

LUA_PATH="$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?.lua;$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$BALLAD_ROOT/src/?.lua;$BALLAD_ROOT/src/?/init.lua;;"
export LUA_PATH BALLAD_CONVENTIONS_FIXTURE="$WORK_DIR/project"

luajit - <<'LUA'
local conventions = require("ballad").conventions
local root = assert(os.getenv("BALLAD_CONVENTIONS_FIXTURE"))
local project = {
  root = root,
  name = "moonstone/package",
  registry_name = "moonstone/package",
  version = "1.2.3",
  kind = "lib",
  description = "fixture",
}

local caller_include = { "src/**" }
local options = conventions.source_package(project, {
  include = caller_include,
  include_add = { "README.md" },
  collect = {
    lua_modules = {
      conventions.tree("src", {
        prefix = "package",
        strip_prefix = "package/",
        root_module = "package.lua",
        exclude = { "**/*.tmp" },
      }),
    },
  },
  materialize = {
    external_paths = {
      conventions.external.include("sqlite"),
      conventions.external.library("sqlite"),
    },
  },
})

assert(options.name == "moonstone/package")
assert(options.version == "1.2.3")
assert(options.kind == "lib")
assert(#caller_include == 1, "source_package mutated caller include options")
assert(options.include[2] == "README.md")
local modules = options.materialize.collect.lua_modules
assert(#modules == 3)
assert(modules[1].name == "package.lua" and modules[1].path == "src/package.lua")
assert(modules[2].name == "package/core/init.lua" and modules[2].path == "src/core/init.lua")
assert(modules[3].name == "package/internal.lua" and modules[3].path == "src/package/internal.lua")
assert(options.materialize.external_paths[1].variable == "SQLITE_INCDIR")
assert(options.materialize.external_paths[2].variable == "SQLITE_LIBDIR")

local ok, diagnostic = pcall(function()
  conventions.source_package(project, {
    collect = { lua_modules = {
      conventions.file("same.lua", "src/package.lua"),
      conventions.file("same.lua", "src/core/init.lua"),
    } },
  })
end)
assert(not ok and tostring(diagnostic):match("duplicate provision same.lua"), tostring(diagnostic))

ok, diagnostic = pcall(function()
  conventions.source_package(project, {
    collect = { lua_modules = { conventions.tree("missing") } },
  })
end)
assert(not ok and tostring(diagnostic):match("resolved from project root"), tostring(diagnostic))

ok, diagnostic = pcall(function()
  conventions.source_package(project, {
    collect = { lua_modules = { conventions.tree("src", { include = { "absent/**" } }) } },
  })
end)
assert(not ok and tostring(diagnostic):match("include pattern selected no files: absent/%*%*"), tostring(diagnostic))

ok, diagnostic = pcall(function()
  conventions.source_package(project, {
    collect = { lua_modules = { conventions.tree("src", {
      overrides = { ["stale.lua"] = "package/stale.lua" },
    }) } },
  })
end)
assert(not ok and tostring(diagnostic):match("override source was not selected: stale.lua"), tostring(diagnostic))
LUA

echo "PASS: Ballad conventions expand deterministic source-package declarations"

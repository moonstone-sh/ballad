#!/usr/bin/env sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="/tmp/ballad-nvim-extern-test"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/lua/my_plugin" "$WORKDIR/plugin"
mkdir -p "$WORKDIR/.moonstone/env"

cat > "$WORKDIR/moonstone.toml" <<'TOML'
[package]
name = "my-plugin"
version = "0.1.0"
kind = "lib"
description = "nvim extern test"

[runtime]
name = "luajit"
version = "2.1"
abi = "5.1"
TOML

cat > "$WORKDIR/.moonstone/env/env.toml" <<'TOML'
[runtime]
name = "luajit"
version = "2.1.0"
abi = "5.1"
TOML

: > "$WORKDIR/.moonstone/env/dependencies.toml"

cat > "$WORKDIR/lua/my_plugin/init.lua" <<'LUA'
local Path = require("plenary.path")
local telescope = require("telescope")
local M = {}
function M.setup() return Path, telescope end
return M
LUA

cat > "$WORKDIR/plugin/my_plugin.lua" <<'LUA'
require("my_plugin").setup()
LUA

cat > "$WORKDIR/partiture.lua" <<'LUA'
local ballad = require("ballad")
return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local nvim = p:use(ballad.plugins.nvim)
  local project = moonstone.project({ root = "." })
  local plugin = nvim.layout(project, {
    module = "my_plugin",
    out = ".ballad/tmp/nvim-layout",
    runtime = "nvim@0.12.2",
    lua_api = "5.1",
    lua_abi = "5.1",
    dependencies = ballad.plugins.nvim.extern({
      "plenary",
      telescope = { package = "nvim-telescope/telescope.nvim", optional = true },
    }),
  })
  local artifact = moonstone.registry.package(plugin, {
    name = project.name,
    version = project.version,
    target = "any",
    runtime = "nvim@0.12.2",
    lua_api = "5.1",
    lua_abi = "5.1",
  })
  p.sink.directory(plugin, { out = "dist/nvim-plugin", file_graph = true })
  p.sink.artifact(artifact, { out = "dist/nvim-plugin/registry-artifact" })
end)
LUA

cd "$WORKDIR"
LUA_PATH="$ROOT/.moonstone/env/share/lua/5.1/?.lua;$ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$ROOT/src/?.lua;$ROOT/src/?/init.lua;;"
export LUA_PATH
luajit "$ROOT/src/main.lua" play partiture.lua > /tmp/ballad-nvim-extern-test.log 2>&1

test -f dist/nvim-plugin/registry-artifact/package.toml
PACKAGE="dist/nvim-plugin/registry-artifact/package.toml"
grep -q 'name = "plenary"' "$PACKAGE"
grep -q 'package = "nvim-lua/plenary.nvim"' "$PACKAGE"
grep -q 'role = "peer"' "$PACKAGE"
grep -q 'name = "telescope"' "$PACKAGE"
grep -q 'package = "nvim-telescope/telescope.nvim"' "$PACKAGE"
grep -q 'optional = true' "$PACKAGE"
grep -q 'runtime = "nvim@0.12.2"' "$PACKAGE"

cat > "$WORKDIR/partiture-suggest.lua" <<'LUA'
local ballad = require("ballad")
return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local nvim = p:use(ballad.plugins.nvim)
  local project = moonstone.project({ root = "." })
  local plugin = nvim.layout(project, {
    module = "my_plugin",
    out = ".ballad/tmp/nvim-layout-suggest",
    dependencies = {},
  })
  p.sink.directory(plugin, { out = "dist/nvim-plugin-suggest" })
end)
LUA

luajit "$ROOT/src/main.lua" play partiture-suggest.lua > /tmp/ballad-nvim-extern-suggest.log 2>&1
grep -q "suggested dependency: plenary" /tmp/ballad-nvim-extern-suggest.log
grep -q "nvim-lua/plenary.nvim" /tmp/ballad-nvim-extern-suggest.log
grep -q "suggested dependency: telescope" /tmp/ballad-nvim-extern-suggest.log

echo "PASS: nvim extern helper and suggestions work"

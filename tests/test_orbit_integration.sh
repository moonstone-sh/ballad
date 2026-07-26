#!/usr/bin/env sh
set -eu

BALLAD_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-orbit-integration.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/child/input" "$WORK_DIR/plugins"
cat > "$WORK_DIR/moonstone.toml" <<'TOML'
[package]
name = "orbit-root"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[[orbits.member]]
name = "child"
path = "child"
TOML

cat > "$WORK_DIR/child/moonstone.toml" <<TOML
[package]
name = "orbit-child"
version = "0.1.0"
kind = "script"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[[dependencies]]
name = "$BALLAD_ROOT"
constraint = "*"
resolver = "path"
role = "tool"
TOML

printf 'orbit export\n' > "$WORK_DIR/child/input/hello.txt"
cat > "$WORK_DIR/plugins/orbit_marker.lua" <<'LUA'
return { value = "loaded" }
LUA
cat > "$WORK_DIR/child/partiture.lua" <<'LUA'
local ballad = require("ballad")
assert(require("orbit_marker").value == "loaded")

return ballad.partiture(function(p)
  local input = p.source.directory("input", { include = { "**" } })
  p.sink.directory(input, { out = "dist", file_graph = true })
end)
LUA

cat > "$WORK_DIR/parent.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local child = moonstone.orbit({
    name = "child",
    partiture = "partiture.lua",
    sync = "update",
    cacheable = false,
    inputs = { "moonstone.toml", "partiture.lua", "input/**", "../plugins/**" },
    lua_paths = { "../plugins" },
  })
  p.sink.directory(child, { out = "parent-dist", file_graph = true })
end)
LUA

cd "$WORK_DIR"
MOONSTONE_HOME="$WORK_DIR/.moonstone-home"
export MOONSTONE_HOME
LUA_PATH="$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?.lua;$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$BALLAD_ROOT/src/?.lua;$BALLAD_ROOT/src/?/init.lua;;"
export LUA_PATH
"${LUA_BIN:-luajit}" "$BALLAD_ROOT/src/main.lua" play parent.lua > "$WORK_DIR/run.log" 2>&1 || {
  cat "$WORK_DIR/run.log"
  exit 1
}

test -f "$WORK_DIR/parent-dist/orbits/child/dist/hello.txt"
echo "PASS: moonstone.orbit executes and imports child sinks"

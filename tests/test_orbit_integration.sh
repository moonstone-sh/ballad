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
name = "moonstone/ballad"
constraint = "path:$BALLAD_ROOT"
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
  assert(p.invocation.args[1] == "--profile")
  assert(p.invocation.args[2] == "test")
  local input = p.source.directory("input", { include = { "**" } })
  p.sink.directory(input, { out = "dist", file_graph = true, product = "release" })
end)
LUA

cat > "$WORK_DIR/parent.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local layout = p:use(ballad.plugins.layout)
  local child = moonstone.orbit("child"):partiture("partiture.lua"):run({
    sync = "update",
    cacheable = false,
    inputs = { "moonstone.toml", "partiture.lua", "../plugins/**" },
    lua_paths = { "../plugins" },
    args = { "--profile", "test" },
  })
  local suite = layout.directory({
    { from = child.product("release"), to = "child" },
  })
  p.sink.directory(suite, { out = "parent-dist", file_graph = true })
end)
LUA

cat > "$WORK_DIR/parent-unselected.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local child = moonstone.orbit("child"):partiture("partiture.lua"):run({
    sync = "never",
    cacheable = false,
  })
  p.sink.directory(child, { out = "must-not-exist" })
end)
LUA

cat > "$WORK_DIR/parent-observed.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local child = moonstone.orbit("child"):partiture("partiture.lua"):run({
    sync = "never",
    inputs = { "moonstone.toml", "partiture.lua", "input/**", "../plugins/**" },
    lua_paths = { "../plugins" },
    args = { "--profile", "test" },
  })
  p.sink.directory(child.product("release"), { out = "parent-observed-dist" })
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
"${LUA_BIN:-luajit}" "$BALLAD_ROOT/src/main.lua" play parent.lua > "$WORK_DIR/run-again.log" 2>&1 || {
  cat "$WORK_DIR/run-again.log"
  exit 1
}
if grep -q 'Cache hit: .*ballad.plugins.moonstone.orbit' "$WORK_DIR/run-again.log"; then
  echo "FAIL: non-cacheable orbit export reused a cached node" >&2
  exit 1
fi

test -f "$WORK_DIR/parent-dist/child/orbits/child/dist/hello.txt"
report="$(find "$WORK_DIR/child/.ballad/exports" -type f -name '*.json' -print -quit)"
test -n "$report"
grep -q '"version":2' "$report"
grep -q '"graph_fingerprint":"b3:' "$report"
grep -q '"fingerprint":"[0-9a-f]' "$report"
grep -q '"--profile"' "$report"
"${LUA_BIN:-luajit}" "$BALLAD_ROOT/src/main.lua" play parent-observed.lua > "$WORK_DIR/observed.log" 2>&1 || {
  cat "$WORK_DIR/observed.log"
  exit 1
}
grep -R -q 'child/input/hello.txt' "$WORK_DIR/.ballad/runs"
if "${LUA_BIN:-luajit}" "$BALLAD_ROOT/src/main.lua" play parent-unselected.lua > "$WORK_DIR/unselected.log" 2>&1; then
  echo "FAIL: unselected orbit export was accepted" >&2
  exit 1
fi
grep -q 'cannot consume an unselected moonstone.orbit export' "$WORK_DIR/unselected.log"
echo "PASS: moonstone.orbit selects explicit child products"

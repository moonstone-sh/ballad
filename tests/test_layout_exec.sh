#!/usr/bin/env sh
set -eu

BALLAD_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-layout-exec.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/generated/app" "$WORK_DIR/unused" "$WORK_DIR/.moonstone/env/share/lua/5.1/helper" "$WORK_DIR/.moonstone/env/lib/lua/5.1"
cat > "$WORK_DIR/moonstone.toml" <<'TOML'
[package]
name = "user/meteorite"
version = "1.2.3"
kind = "bin"

[scripts]
build = "true"
TOML
cat > "$WORK_DIR/.moonstone/env/env.toml" <<'TOML'
[runtime]
name = "luajit"
version = "2.1.0"
abi = "5.1"
TOML
cat > "$WORK_DIR/generated/app/main.lua" <<'LUA'
local helper = require("helper.message")
print("meteorite:" .. helper.value)
LUA
printf 'do not export\n' > "$WORK_DIR/unused/notes.txt"
cat > "$WORK_DIR/.moonstone/env/share/lua/5.1/helper/message.lua" <<'LUA'
return { value = "ok" }
LUA
printf 'native-placeholder\n' > "$WORK_DIR/.moonstone/env/lib/lua/5.1/meteorite_native.so"
cat > "$WORK_DIR/partiture.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local layout = p:use(ballad.plugins.layout)
  local project = moonstone.project({ root = "." })
  local build = moonstone:run("build", {
    inputs = { "generated/app/main.lua" },
    outputs = { "generated/app/main.lua" },
  })
  local app = layout.exec(project, {
    name = "meteorite",
    entry = "generated/app/main.lua",
    bin = "meteorite",
    interpreter = "luajit",
    include = { "generated/**" },
    lua_paths = { "lua", "generated/app" },
    depends_on = build,
  })
  p.sink.none(build)
  p.sink.directory(app, { out = "dist/meteorite", file_graph = true })
end)
LUA

cd "$WORK_DIR"
LUA_PATH="$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?.lua;$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$BALLAD_ROOT/src/?.lua;$BALLAD_ROOT/src/?/init.lua;;"
export LUA_PATH
luajit "$BALLAD_ROOT/src/main.lua" play partiture.lua > "$WORK_DIR/run.log" 2>&1 || { cat "$WORK_DIR/run.log"; exit 1; }

test -x dist/meteorite/bin/meteorite || { echo "FAIL: launcher missing or not executable"; exit 1; }
test -f dist/meteorite/libexec/meteorite/generated/app/main.lua || { echo "FAIL: project entry missing"; exit 1; }
test ! -e dist/meteorite/libexec/meteorite/unused/notes.txt || { echo "FAIL: excluded project file exported"; exit 1; }
test -f dist/meteorite/libexec/meteorite/lua/helper/message.lua || { echo "FAIL: Lua dependency missing"; exit 1; }
test -f dist/meteorite/libexec/meteorite/lib/meteorite_native.so || { echo "FAIL: native module missing"; exit 1; }
grep -q '"layout":"exec"' dist/meteorite/file-graph.json || { echo "FAIL: file graph layout not exec"; cat dist/meteorite/file-graph.json; exit 1; }
OUTPUT=$(dist/meteorite/bin/meteorite)
test "$OUTPUT" = "meteorite:ok" || { echo "FAIL: launcher output wrong: $OUTPUT"; exit 1; }

echo "PASS: layout.exec emits ready-to-run libexec app"

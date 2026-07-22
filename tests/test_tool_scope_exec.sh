#!/usr/bin/env sh
set -eu

BALLAD_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-tool-scope.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p \
  "$WORK_DIR/.moonstone/env/bin-runtime/formatter" \
  "$WORK_DIR/.moonstone/env/bin" \
  "$WORK_DIR/store/tool/files/bin" \
  "$WORK_DIR/store/helper/files/share/lua/5.1/helper" \
  "$WORK_DIR/store/native/files/lib/lua/5.1"

cat > "$WORK_DIR/moonstone.toml" <<'TOML'
[package]
name = "user/tool-host"
version = "0.1.0"
kind = "script"
TOML

cat > "$WORK_DIR/.moonstone/env/env.toml" <<'TOML'
[runtime]
name = "luajit"
version = "2.1.0"
abi = "5.1"
TOML

cat > "$WORK_DIR/store/tool/files/bin/formatter" <<'LUA'
#!/usr/bin/env lua
local helper = require("helper.message")
print("formatted:" .. helper.value)
LUA
chmod +x "$WORK_DIR/store/tool/files/bin/formatter"
ln -s "$WORK_DIR/store/tool/files/bin/formatter" "$WORK_DIR/.moonstone/env/bin/formatter"

cat > "$WORK_DIR/store/helper/files/share/lua/5.1/helper/message.lua" <<'LUA'
return { value = "ok" }
LUA
printf 'native-placeholder\n' > "$WORK_DIR/store/native/files/lib/lua/5.1/formatter_native.so"

cat > "$WORK_DIR/.moonstone/env/bin-runtime/formatter/env.toml" <<TOML
[env]
path_prepend = ["$WORK_DIR/store/tool/files/bin"]
lua_path = ["$WORK_DIR/store/helper/files/share/lua/5.1/?.lua", "$WORK_DIR/store/helper/files/share/lua/5.1/?/init.lua"]
lua_cpath = ["$WORK_DIR/store/native/files/lib/lua/5.1/?.so", "$WORK_DIR/store/native/files/lib/lua/5.1/?.dylib"]
TOML

cat > "$WORK_DIR/partiture.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local layout = p:use(ballad.plugins.layout)
  local project = moonstone.project({ root = "." })
  local tool = moonstone.tool(project, { name = "formatter" })
  local app = layout.exec(tool, { name = "formatter" })
  p.sink.directory(app, { out = "dist/formatter", file_graph = true })
end)
LUA

cd "$WORK_DIR"
export LUA_PATH="$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?.lua;$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$BALLAD_ROOT/src/?.lua;$BALLAD_ROOT/src/?/init.lua;;"
luajit "$BALLAD_ROOT/src/main.lua" play partiture.lua > "$WORK_DIR/run.log" 2>&1 || { cat "$WORK_DIR/run.log"; exit 1; }

test -x dist/formatter/bin/formatter || { echo "FAIL: launcher missing or not executable"; exit 1; }
test -f dist/formatter/libexec/formatter/bin/formatter || { echo "FAIL: tool executable missing"; exit 1; }
test -f dist/formatter/libexec/formatter/lua/helper/message.lua || { echo "FAIL: tool Lua closure missing"; exit 1; }
test -f dist/formatter/libexec/formatter/lib/formatter_native.so || { echo "FAIL: tool C-module closure missing"; exit 1; }
OUTPUT=$(dist/formatter/bin/formatter)
test "$OUTPUT" = "formatted:ok" || { echo "FAIL: launcher output wrong: $OUTPUT"; exit 1; }

echo "PASS: tool scope exports a runnable executable closure"

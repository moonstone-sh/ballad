#!/usr/bin/env sh
set -eu
BALLAD_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-native-closure.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/src" "$WORK_DIR/.moonstone/env/lib/lua/5.1"
cat > "$WORK_DIR/moonstone.toml" <<'TOML'
[package]
name = "user/native-closure"
version = "0.1.0"
kind = "script"
TOML
cat > "$WORK_DIR/.moonstone/env/env.toml" <<'TOML'
[runtime]
name = "luajit"
version = "2.1.0"
abi = "lua-5.1"
TOML
cat > "$WORK_DIR/native_fixture.c" <<'C'
int luaopen_native_fixture(void *state) { (void)state; return 0; }
C
case "$(uname -s)" in
  Darwin) cc -bundle -undefined dynamic_lookup "$WORK_DIR/native_fixture.c" -o "$WORK_DIR/.moonstone/env/lib/lua/5.1/native_fixture.so" ;;
  *) cc -shared -fPIC "$WORK_DIR/native_fixture.c" -o "$WORK_DIR/.moonstone/env/lib/lua/5.1/native_fixture.so" ;;
esac
cat > "$WORK_DIR/src/main.lua" <<'LUA'
assert(require("native_fixture") == true)
print("native closure ok")
LUA
cat > "$WORK_DIR/partiture.lua" <<'LUA'
local ballad = require("ballad")
return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local layout = p:use(ballad.plugins.layout)
  local project = moonstone.project({ root = "." })
  local app = layout.libexec(project, { name = "native-closure", bin = "native-closure", entry = "src/main.lua", bundle_runtime = false, interpreter = "luajit" })
  p.sink.directory(app, { out = "dist", file_graph = true })
end)
LUA
cd "$WORK_DIR"
LUA_PATH="$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?.lua;$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$BALLAD_ROOT/src/?.lua;$BALLAD_ROOT/src/?/init.lua;;"
export LUA_PATH
luajit "$BALLAD_ROOT/src/main.lua" play partiture.lua > "$WORK_DIR/run.log" 2>&1 || { cat "$WORK_DIR/run.log"; exit 1; }
test -f dist/libexec/native-closure/lib/native_fixture.so
OUTPUT=$(BALLAD_LUA=luajit dist/bin/native-closure)
test "$OUTPUT" = "native closure ok"
echo "PASS: native C module ships in runnable closure"

#!/usr/bin/env sh
set -eu

BALLAD_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-init.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

cd "$WORK_DIR"
LUA_PATH="$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?.lua;$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$BALLAD_ROOT/src/?.lua;$BALLAD_ROOT/src/?/init.lua;;"
export LUA_PATH

echo "Testing ballad init love2d..."
luajit "$BALLAD_ROOT/src/main.lua" init love2d
test -f partiture.lua
grep -q "love.layout" partiture.lua
rm partiture.lua

echo "Testing ballad init executable..."
luajit "$BALLAD_ROOT/src/main.lua" init executable
test -f partiture.lua
grep -q "layout.exec" partiture.lua
rm partiture.lua

echo "Testing ballad init registry..."
luajit "$BALLAD_ROOT/src/main.lua" init registry
test -f partiture.lua
grep -q "registry.package" partiture.lua
rm partiture.lua

echo "Testing ballad init failure on existing file..."
touch partiture.lua
if luajit "$BALLAD_ROOT/src/main.lua" init love2d 2>/dev/null; then
  echo "FAIL: init should fail if partiture.lua exists"
  exit 1
fi

echo "Testing ballad init failure on unknown template..."
rm partiture.lua
if luajit "$BALLAD_ROOT/src/main.lua" init nonexistent 2>/dev/null; then
  echo "FAIL: init should fail for nonexistent template"
  exit 1
fi

echo "PASS: ballad init scaffolding works"

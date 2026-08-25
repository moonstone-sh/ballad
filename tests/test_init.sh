#!/usr/bin/env sh
set -eu

BALLAD_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-init.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

cd "$WORK_DIR"
LUA_PATH="$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?.lua;$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$BALLAD_ROOT/src/?.lua;$BALLAD_ROOT/src/?/init.lua;;"
export LUA_PATH
MOONSTONE_HOME="$WORK_DIR/moonstone-home"
MOONSTONE_CONFIG="$MOONSTONE_HOME/config"
MOONSTONE_DATA="$MOONSTONE_HOME/data"
MOONSTONE_CACHE="$MOONSTONE_HOME/cache"
XDG_CONFIG_HOME="$WORK_DIR/xdg/config"
XDG_DATA_HOME="$WORK_DIR/xdg/data"
XDG_CACHE_HOME="$WORK_DIR/xdg/cache"
export MOONSTONE_HOME MOONSTONE_CONFIG MOONSTONE_DATA MOONSTONE_CACHE
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
mkdir -p "$MOONSTONE_HOME" "$MOONSTONE_CONFIG" "$MOONSTONE_DATA" "$MOONSTONE_CACHE"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"

echo "Testing ballad init love2d..."
luajit "$BALLAD_ROOT/src/main.lua" -- init --template love2d --no-script
test -f partiture.lua
grep -q "love.layout" partiture.lua
rm partiture.lua

echo "Testing ballad init executable..."
luajit "$BALLAD_ROOT/src/main.lua" init --template executable --no-script
test -f partiture.lua
grep -q "layout.exec" partiture.lua
rm partiture.lua

echo "Testing ballad init registry..."
luajit "$BALLAD_ROOT/src/main.lua" init --template registry --no-script
test -f partiture.lua
grep -q "registry.source_package" partiture.lua
grep -q "convention.tree" partiture.lua
rm partiture.lua

echo "Testing ballad init failure on existing file..."
touch partiture.lua
if luajit "$BALLAD_ROOT/src/main.lua" init --template love2d --no-script 2>/dev/null; then
  echo "FAIL: init should fail if partiture.lua exists"
  exit 1
fi

echo "Testing ballad init failure on unknown template..."
rm partiture.lua
if luajit "$BALLAD_ROOT/src/main.lua" init --template nonexistent --no-script 2>unknown-template.log; then
  echo "FAIL: init should fail for nonexistent template"
  exit 1
fi
grep -q "available templates: executable, love2d, registry" unknown-template.log

echo "Testing Moonstone script registration..."
mkdir moonstone-project
moon init moonstone-project --name init-fixture --kind lib --no-sync --no-git
cd moonstone-project
mkdir -p src
printf '%s\n' 'return {}' > src/init-fixture.lua
luajit "$BALLAD_ROOT/src/main.lua" init --template registry
test -f partiture.lua
moon manifest script get package --json > script.json
grep -q 'moon exec ballad -- play partiture.lua' script.json

echo "Testing contextual script conflict diagnostics..."
rm partiture.lua
moon manifest script set package --command 'echo existing'
if luajit "$BALLAD_ROOT/src/main.lua" init --template registry 2>script-conflict.log; then
  echo "FAIL: init should fail for a conflicting Moonstone script"
  exit 1
fi
test ! -f partiture.lua
grep -q 'already exists with a different command' script-conflict.log
grep -q -- '--force-script' script-conflict.log

echo "PASS: ballad init scaffolding works"

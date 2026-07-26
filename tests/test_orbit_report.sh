#!/usr/bin/env sh
set -eu

BALLAD_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-orbit-report.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/input"
printf 'hello orbit\n' > "$WORK_DIR/input/hello.txt"

cat > "$WORK_DIR/partiture.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local input = p.source.directory("input", { include = { "**" } })
  p.sink.directory(input, { out = "dist" })
end)
LUA

cd "$WORK_DIR"
LUA_PATH="$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?.lua;$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$BALLAD_ROOT/src/?.lua;$BALLAD_ROOT/src/?/init.lua;;"
export LUA_PATH
luajit "$BALLAD_ROOT/src/main.lua" play partiture.lua --report .ballad/orbit-report.json > "$WORK_DIR/run.log" 2>&1 || {
  cat "$WORK_DIR/run.log"
  exit 1
}

test -f .ballad/orbit-report.json
grep -q '"version":1' .ballad/orbit-report.json
grep -q '"path":"dist"' .ballad/orbit-report.json

echo "PASS: ballad play writes explicit sink report"

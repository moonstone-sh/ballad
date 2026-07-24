#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/partiture.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  assert(#p.invocation.args == 4, "argument count")
  assert(p.invocation.args[1] == "--mode", "mode flag")
  assert(p.invocation.args[2] == "hybrid_dev", "mode value")
  assert(p.invocation.args[3] == "--backend", "backend flag")
  assert(p.invocation.args[4] == "fast_http", "backend value")
  p.sink.none()
end)
LUA

cd "$WORK_DIR"
"${LUA_BIN:-luajit}" "$ROOT/src/main.lua" play partiture.lua -- --mode hybrid_dev --backend fast_http >/tmp/ballad-invocation-test.log 2>&1 || {
  cat /tmp/ballad-invocation-test.log
  exit 1
}

GRAPH=$(find .ballad/runs -name graph.json -type f | head -n 1)
test -n "$GRAPH"
grep -q '"invocation":{"args":\["--mode","hybrid_dev","--backend","fast_http"\]}' "$GRAPH"

echo "PASS: partitures receive opaque invocation arguments"

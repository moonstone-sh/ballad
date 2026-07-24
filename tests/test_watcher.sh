#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-watcher.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/partiture.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local watcher = p:use(ballad.plugins.watcher)
  local sources = p.source.files({ "**/*.lua" }, { root = "src" })
  local session = watcher.watch({
    initial = {
      label = "bootstrap",
      outputs = { "watched.txt" },
      effect = "test \"$BALLAD_WATCH_REASON\" = initial && printf ready > watched.txt",
    },
    reactions = {
      {
        label = "lua sources",
        watch = { sources },
        outputs = { "watched.txt" },
        effect = "printf changed > watched.txt",
      },
    },
    options = { once = true },
  })
  p.sink.none(session)
end)
LUA

cd "$WORK_DIR"
mkdir src
printf 'return true\n' > src/main.lua
"${LUA_BIN:-luajit}" "$ROOT/src/main.lua" play partiture.lua >/tmp/ballad-watcher-test.log 2>&1 || {
  cat /tmp/ballad-watcher-test.log
  exit 1
}
test "$(cat watched.txt)" = "ready"
GRAPH=$(find .ballad/runs -name graph.json -type f | head -n 1)
test -n "$GRAPH"
grep -q '"watch":\["node_1"\]' "$GRAPH"
grep -q '"inputs":\["node_1"\]' "$GRAPH"

echo "PASS: watcher source handles become graph inputs"

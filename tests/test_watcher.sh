#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-watcher.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/partiture.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local watcher = p:use(ballad.plugins.watcher)
  local sources = p.source.directory("src")
  local session = watcher.watch({
    initial = {
      label = "bootstrap",
      inputs = { "src/**/*.lua" },
      depends_on = { sources },
      outputs = { "watched.txt" },
      effect = "test \"$BALLAD_WATCH_REASON\" = initial && printf ready > watched.txt",
    },
    reactions = {
      {
        label = "lua sources",
        inputs = { "src/**/*.lua" },
        depends_on = { sources },
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
echo "PASS: watcher reactions once mode"

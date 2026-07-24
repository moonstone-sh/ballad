#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/build_partiture.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local build = p.task.native({
    id = "fixture.shared-copy.v1",
    tool = "sh",
    args = { "-c", "mkdir -p build; cat src/main.lua > build/output.lua; printf run >> build/count; printf build >> build/order" },
    inputs = { "src/**/*.lua" },
    outputs = { "build/output.lua", "build/count", "build/order" },
    toolchain = { command = "sh --version" },
  })
  p.sink.none(p.task.run(build))
end)
LUA

cat > "$WORK_DIR/watch_partiture.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local watcher = p:use(ballad.plugins.watcher)
  local source = p.source.files({ "**/*.lua" }, { root = "src" })
  local build = p.task.native({
    id = "fixture.shared-copy.v1",
    tool = "sh",
    args = { "-c", "mkdir -p build; cat src/main.lua > build/output.lua; printf run >> build/count; printf build >> build/order" },
    inputs = { "src/**/*.lua" },
    outputs = { "build/output.lua", "build/count", "build/order" },
    toolchain = { command = "sh --version" },
  })
  local session = watcher.watch({
    initial = {
      label = "shared build",
      before = "mkdir -p build; printf before >> build/order",
      run = build,
      effect = "printf after >> build/order",
    },
    reactions = { { label = "source", watch = { source }, run = build } },
    options = { once = true },
  })
  p.sink.none(session)
end)
LUA

cd "$WORK_DIR"
mkdir src
printf 'return true\n' > src/main.lua

"${LUA_BIN:-luajit}" "$ROOT/src/main.lua" play build_partiture.lua >/tmp/ballad-native-action-build.log 2>&1 || {
  cat /tmp/ballad-native-action-build.log
  exit 1
}
test "$(cat build/count)" = "run"

"${LUA_BIN:-luajit}" "$ROOT/src/main.lua" play watch_partiture.lua >/tmp/ballad-native-action-watch.log 2>&1 || {
  cat /tmp/ballad-native-action-watch.log
  exit 1
}
test "$(cat build/count)" = "run"
test "$(cat build/order)" = "buildbeforeafter"
grep -q 'Cache hit: native action (fixture.shared-copy.v1)' /tmp/ballad-native-action-watch.log

echo "PASS: native actions share cache across finite and watcher partitures"

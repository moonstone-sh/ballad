#!/usr/bin/env sh
set -eu

BALLAD_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-readme.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/src" "$WORK_DIR/.moonstone/env"
cat > "$WORK_DIR/moonstone.toml" <<'TOML'
[package]
name = "user/readme-demo"
version = "0.4.2"
kind = "lib"
readme = "./README.md"
TOML
cat > "$WORK_DIR/README.md" <<'MD'
# readme-demo

A demo package with a README.
MD
cat > "$WORK_DIR/src/app.lua" <<'LUA'
return { ok = true }
LUA
cat > "$WORK_DIR/.moonstone/env/env.toml" <<'TOML'
[runtime]
name = "lua"
version = "5.4.0"
abi = "lua54"
TOML

cat > "$WORK_DIR/partiture.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local sources = p.source.directory(".")
  local source_artifact = moonstone.registry.source_package(sources, {
    name = "user/readme-demo",
    version = "0.4.2",
    kind = "lib",
    readme = "README.md",
    include = { "moonstone.toml", "src/**" },
    materialize = { type = "command", command = "echo build" },
  })
  p.sink.artifact(source_artifact, { out = "dist/registry/readme-demo" })
end)
LUA

cd "$WORK_DIR"
LUA_PATH="$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?.lua;$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$BALLAD_ROOT/src/?.lua;$BALLAD_ROOT/src/?/init.lua;;"
export LUA_PATH
luajit "$BALLAD_ROOT/src/main.lua" play partiture.lua > "$WORK_DIR/run.log" 2>&1 || { cat "$WORK_DIR/run.log"; exit 1; }

OUT="$WORK_DIR/dist/registry/readme-demo"
test -f "$OUT/package.toml" || { echo "FAIL: package.toml missing"; exit 1; }
test -f "$OUT/README.md" || { echo "FAIL: README.md not emitted"; exit 1; }
grep -q '^readme = ' "$OUT/package.toml" || { echo "FAIL: package.toml has no readme field"; exit 1; }
grep -q 'readme-demo' "$OUT/README.md" || { echo "FAIL: README.md content wrong"; exit 1; }
grep -q -- '-F readme=@' "$OUT/publish.sh" || { echo "FAIL: publish.sh missing readme upload"; exit 1; }

echo "PASS: registry.source_package inlines README, emits README.md, and threads it into publish.sh"

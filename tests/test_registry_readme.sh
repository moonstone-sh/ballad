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
TOML
cat > "$WORK_DIR/README.md" <<'MD'
# Repository README

Contributor-facing repository documentation.
MD
cat > "$WORK_DIR/REGISTRY_README.md" <<'MD'
# readme-demo

A hands-on package guide for Moonstone Registry visitors.
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
grep -q 'hands-on package guide' "$OUT/README.md" || { echo "FAIL: dedicated registry README was not selected"; exit 1; }
! grep -q 'Contributor-facing repository documentation' "$OUT/README.md" || { echo "FAIL: repository README was selected instead"; exit 1; }
grep -q -- '-F readme=@' "$OUT/publish.sh" || { echo "FAIL: publish.sh missing readme upload"; exit 1; }

cat > "$WORK_DIR/explicit-partiture.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local project = moonstone.project({ root = "." })
  local source_artifact = moonstone.registry.source_package(project, {
    name = "user/readme-demo",
    version = "0.4.2",
    kind = "lib",
    readme = "README.md",
    include = { "moonstone.toml", "src/**" },
    materialize = { type = "command", command = "echo build" },
  })
  p.sink.artifact(source_artifact, { out = "dist/registry/readme-explicit" })
end)
LUA

luajit "$BALLAD_ROOT/src/main.lua" play explicit-partiture.lua > "$WORK_DIR/explicit-run.log" 2>&1 || {
  cat "$WORK_DIR/explicit-run.log"
  exit 1
}

EXPLICIT_OUT="$WORK_DIR/dist/registry/readme-explicit"
grep -q 'Contributor-facing repository documentation' "$EXPLICIT_OUT/README.md" || {
  echo "FAIL: explicit README path did not override REGISTRY_README.md"
  exit 1
}

echo "PASS: registry.source_package prefers REGISTRY_README.md, honors explicit README paths, emits README.md, and threads it into publish.sh"

#!/usr/bin/env sh
set -eu

BALLAD_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-source-package.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/src" "$WORK_DIR/native" "$WORK_DIR/.moonstone/env" "$WORK_DIR/zig-out"
cat > "$WORK_DIR/moonstone.toml" <<'TOML'
[package]
name = "user/meteorite"
version = "1.2.3"
kind = "lib"
TOML
cat > "$WORK_DIR/build.zig" <<'ZIG'
pub fn build() void {}
ZIG
cat > "$WORK_DIR/src/app.lua" <<'LUA'
return { ok = true }
LUA
cat > "$WORK_DIR/native/module.zig" <<'ZIG'
pub export fn luaopen_meteorite_native() c_int { return 0; }
ZIG
printf 'secret\n' > "$WORK_DIR/.moonstone/secret"
cat > "$WORK_DIR/.moonstone/env/env.toml" <<'TOML'
[runtime]
name = "lua"
version = "5.4.0"
abi = "lua54"
TOML
printf 'build output\n' > "$WORK_DIR/zig-out/output"

cat > "$WORK_DIR/partiture.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local sources = p.source.directory(".")
  local source_artifact = moonstone.registry.source_package(sources, {
    name = "user/meteorite",
    version = "1.2.3",
    kind = "lib",
    include = {
      "moonstone.toml",
      "build.zig",
      "src/**",
      "native/**",
    },
    exclude = {
      ".moonstone/**",
      ".ballad/**",
      "zig-cache/**",
      "zig-out/**",
      ".git/**",
    },
    materialize = {
      type = "command",
      command = "zig build install-native",
      collect = {
        lua_modules = {
          { name = "meteorite.lua", path = "src/app.lua" },
        },
        lua_cmodules = {
          { name = "meteorite_native.so", path = ".moonstone/env/lib/lua/${lua_abi}/meteorite_native.so" },
        },
      },
    },
  })
  p.sink.artifact(source_artifact, { out = "dist/registry/meteorite" })
end)
LUA

cd "$WORK_DIR"
LUA_PATH="$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?.lua;$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$BALLAD_ROOT/src/?.lua;$BALLAD_ROOT/src/?/init.lua;;"
export LUA_PATH
luajit "$BALLAD_ROOT/src/main.lua" play partiture.lua > "$WORK_DIR/run.log" 2>&1 || { cat "$WORK_DIR/run.log"; exit 1; }

test -f dist/registry/meteorite/package.toml || { echo "FAIL: package.toml missing"; exit 1; }
test -f dist/registry/meteorite/meteorite-1.2.3-source.tar.zst || { echo "FAIL: source tarball missing"; exit 1; }
test -x dist/registry/meteorite/publish.sh || { echo "FAIL: publish.sh missing or not executable"; exit 1; }

grep -q 'kind = "source"' dist/registry/meteorite/package.toml || { echo "FAIL: source kind missing"; cat dist/registry/meteorite/package.toml; exit 1; }
grep -q 'target = "source"' dist/registry/meteorite/package.toml || { echo "FAIL: source target missing"; exit 1; }
grep -q 'format = "tar.zst"' dist/registry/meteorite/package.toml || { echo "FAIL: tar.zst format missing"; exit 1; }
grep -q '\[artifacts.materialize\]' dist/registry/meteorite/package.toml || { echo "FAIL: materialize table missing"; exit 1; }
grep -q 'type = "command"' dist/registry/meteorite/package.toml || { echo "FAIL: command materializer missing"; exit 1; }
grep -q 'lua_modules' dist/registry/meteorite/package.toml || { echo "FAIL: lua_modules collect missing"; exit 1; }
grep -q 'lua_cmodules' dist/registry/meteorite/package.toml || { echo "FAIL: lua_cmodules collect missing"; exit 1; }

zstd -dc dist/registry/meteorite/meteorite-1.2.3-source.tar.zst | tar -tf - > "$WORK_DIR/tar-list.txt"
grep -q '^./moonstone.toml$' "$WORK_DIR/tar-list.txt" || { echo "FAIL: moonstone.toml not archived"; cat "$WORK_DIR/tar-list.txt"; exit 1; }
grep -q '^./src/app.lua$' "$WORK_DIR/tar-list.txt" || { echo "FAIL: src/app.lua not archived"; exit 1; }
grep -q '^./native/module.zig$' "$WORK_DIR/tar-list.txt" || { echo "FAIL: native/module.zig not archived"; exit 1; }
if grep -q '^./\.moonstone/' "$WORK_DIR/tar-list.txt" || grep -q '^./zig-out/' "$WORK_DIR/tar-list.txt"; then
  echo "FAIL: excluded build/private paths archived"
  cat "$WORK_DIR/tar-list.txt"
  exit 1
fi

cat > "$WORK_DIR/partiture_project.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local project = moonstone.project({ root = "." })
  local source_artifact = moonstone.registry.source_package(project, {
    name = "user/meteorite",
    version = project.version,
    kind = "lib",
    include = { "moonstone.toml", "build.zig", "src/**", "native/**" },
    materialize = {
      type = "command",
      command = "zig build install-native",
      collect = {
        lua_modules = {
          { name = "meteorite.lua", path = "src/app.lua" },
        },
        lua_cmodules = {
          { name = "meteorite_native.so", path = ".moonstone/env/lib/lua/${lua_abi}/meteorite_native.so" },
        },
      },
    },
  })
  p.sink.artifact(source_artifact, { out = "dist/registry/meteorite-project" })
end)
LUA

luajit "$BALLAD_ROOT/src/main.lua" play partiture_project.lua > "$WORK_DIR/run-project.log" 2>&1 || { cat "$WORK_DIR/run-project.log"; exit 1; }
test -f dist/registry/meteorite-project/package.toml || { echo "FAIL: project input package.toml missing"; exit 1; }
grep -q 'version = "1.2.3"' dist/registry/meteorite-project/package.toml || { echo "FAIL: project version not used"; exit 1; }

echo "PASS: registry.source_package emits source package descriptor and archive"

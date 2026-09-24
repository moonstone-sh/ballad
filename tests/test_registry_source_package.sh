#!/usr/bin/env sh
set -eu

BALLAD_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-source-package.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/src" "$WORK_DIR/native" "$WORK_DIR/.moonstone/env" "$WORK_DIR/zig-out" "$WORK_DIR/fake-bin"
mkdir -p "$WORK_DIR/runtime"
cat > "$WORK_DIR/moonstone.toml" <<'TOML'
[package]
name = "user/meteorite"
version = "1.2.3"
kind = "lib"

[[dependencies]]
name = "user/runtime"
constraint = "path:runtime"
registry = "path"
role = "runtime"

[[dependencies]]
name = "user/build-tool"
constraint = "^9.9.9"
role = "tool"
TOML
cat > "$WORK_DIR/runtime/moonstone.toml" <<'TOML'
[package]
name = "user/runtime"
version = "4.5.6"
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
cat > "$WORK_DIR/bin/meteorite" <<'SH'
#!/usr/bin/env sh
exec lua src/app.lua "$@"
SH
# Deliberately leave the source file non-executable. The bins collection is
# authoritative and must make the archived entry executable.
chmod 0644 "$WORK_DIR/bin/meteorite"
printf 'secret\n' > "$WORK_DIR/.moonstone/secret"
cat > "$WORK_DIR/.moonstone/env/env.toml" <<'TOML'
[runtime]
name = "lua"
version = "5.4.0"
abi = "lua54"
TOML
printf 'build output\n' > "$WORK_DIR/zig-out/output"

cat > "$WORK_DIR/fake-bin/moon" <<'SH'
#!/usr/bin/env sh
set -eu
if [ "${1:-}" = "-C" ]; then
  root=$2
  shift 2
  case "${1:-}:${2:-}:${3:-}" in
    manifest:export:--json)
      if [ "$(basename "$root")" = runtime ]; then
        printf '%s\n' '{"contract":"moonstone:manifest:v1","manifest":{"project":{"name":"user/runtime","version":"4.5.6","kind":"lib"}}}'
      else
        printf '%s\n' '{"contract":"moonstone:manifest:v1","manifest":{"project":{"name":"user/meteorite","version":"1.2.3","kind":"lib"},"dependencies":[{"name":"user/runtime","constraint":"path:runtime","registry":"path","role":"runtime"},{"name":"user/build-tool","constraint":"^9.9.9","role":"tool"}]}}'
      fi
      exit 0
      ;;
    lock:export:--json)
      printf '%s\n' '{"contract":"moonstone:lock:v1","realizations":[]}'
      exit 0
      ;;
  esac
fi
[ "${1:-}" = artifact ] && [ "${2:-}" = create ] && [ "${3:-}" = --out ] && [ "${5:-}" = --json ] && [ "${6:-}" = -- ] || exit 64
out=$4
shift 6
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
while [ "$#" -gt 0 ]; do
  virtual=$1 source=$2 mode=$3
  if [ "$virtual" = recipe ] && grep -q SQLITE_HEADERS "$source"; then
    digest=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  fi
  mkdir -p "$stage/$(dirname "$virtual")"
  cp "$source" "$stage/$virtual"
  chmod "$mode" "$stage/$virtual"
  shift 3
done
digest=${digest:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}
  (cd "$stage" && tar -czf "$out" $(find . -type f -print))
printf '{"contract":"moonstone:artifact-create:v1","path":"%s","bytes":1,"b3":"b3:%s"}\n' "$out" "$digest"
SH
chmod +x "$WORK_DIR/fake-bin/moon"

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
      "bin/**",
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
      external_paths = {
        { dependency = "SQLITE", variable = "SQLITE_LIBDIR", kind = "library" },
        { dependency = "SQLITE", variable = "SQLITE_INCDIR", kind = "include" },
      },
      ldflags = { "-L$(SQLITE_LIBDIR)" },
      collect = {
        bins = {
          { name = "bin/meteorite", path = "bin/meteorite" },
        },
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
export MOONSTONE_CLI="$WORK_DIR/fake-bin/moon"
luajit "$BALLAD_ROOT/src/main.lua" play partiture.lua > "$WORK_DIR/run.log" 2>&1 || { cat "$WORK_DIR/run.log"; exit 1; }

test -f dist/registry/meteorite/package.toml || { echo "FAIL: package.toml missing"; exit 1; }
test -f dist/registry/meteorite/meteorite-1.2.3-source.tar.gz || { echo "FAIL: source tarball missing"; exit 1; }
test -x dist/registry/meteorite/publish.sh || { echo "FAIL: publish.sh missing or not executable"; exit 1; }

grep -q 'kind = "source"' dist/registry/meteorite/package.toml || { echo "FAIL: source kind missing"; cat dist/registry/meteorite/package.toml; exit 1; }
grep -q 'target = "source"' dist/registry/meteorite/package.toml || { echo "FAIL: source target missing"; exit 1; }
grep -q 'format = "tar.gz"' dist/registry/meteorite/package.toml || { echo "FAIL: tar.gz format missing"; exit 1; }
grep -q '\[artifacts.materialize\]' dist/registry/meteorite/package.toml || { echo "FAIL: materialize table missing"; exit 1; }
grep -q 'type = "command"' dist/registry/meteorite/package.toml || { echo "FAIL: command materializer missing"; exit 1; }
grep -q 'lua_modules' dist/registry/meteorite/package.toml || { echo "FAIL: lua_modules collect missing"; exit 1; }
grep -q 'lua_cmodules' dist/registry/meteorite/package.toml || { echo "FAIL: lua_cmodules collect missing"; exit 1; }
grep -q 'external_paths = ' dist/registry/meteorite/package.toml || { echo "FAIL: external path contract missing"; exit 1; }
grep -q 'variable = "SQLITE_INCDIR"' dist/registry/meteorite/package.toml || { echo "FAIL: include path requirement missing"; exit 1; }
grep -q 'variable = "SQLITE_LIBDIR"' dist/registry/meteorite/package.toml || { echo "FAIL: library path requirement missing"; exit 1; }
grep -Fq 'ldflags = [ "-L$(SQLITE_LIBDIR)" ]' dist/registry/meteorite/package.toml || { echo "FAIL: external linker flag missing"; exit 1; }

RECIPE_WITH_INCDIR=$(sed -n 's/^recipe_hash = "\([^"]*\)"$/\1/p' dist/registry/meteorite/package.toml)
sed 's/SQLITE_INCDIR/SQLITE_HEADERS/g; s#dist/registry/meteorite#dist/registry/meteorite-headers#g' partiture.lua > partiture_external_variant.lua
luajit "$BALLAD_ROOT/src/main.lua" play partiture_external_variant.lua > "$WORK_DIR/run-external-variant.log" 2>&1 || { cat "$WORK_DIR/run-external-variant.log"; exit 1; }
RECIPE_WITH_HEADERS=$(sed -n 's/^recipe_hash = "\([^"]*\)"$/\1/p' dist/registry/meteorite-headers/package.toml)
test "$RECIPE_WITH_INCDIR" != "$RECIPE_WITH_HEADERS" || { echo "FAIL: external path contract did not affect recipe identity"; exit 1; }

sed 's/kind = "include"/kind = "root"/' partiture.lua > partiture_invalid_external.lua
if luajit "$BALLAD_ROOT/src/main.lua" play partiture_invalid_external.lua > "$WORK_DIR/run-invalid-external.log" 2>&1; then
  echo "FAIL: invalid external path kind was accepted"
  exit 1
fi
grep -q 'kind must be include or library' "$WORK_DIR/run-invalid-external.log" || { cat "$WORK_DIR/run-invalid-external.log"; echo "FAIL: invalid external path diagnostic missing"; exit 1; }

tar -tzf dist/registry/meteorite/meteorite-1.2.3-source.tar.gz > "$WORK_DIR/tar-list.txt"
tar -tvzf dist/registry/meteorite/meteorite-1.2.3-source.tar.gz > "$WORK_DIR/tar-detail.txt"
grep -Eq '^\.?/?moonstone.toml$' "$WORK_DIR/tar-list.txt" || { echo "FAIL: moonstone.toml not archived"; cat "$WORK_DIR/tar-list.txt"; exit 1; }
grep -Eq '^-rwxr-xr-x.* (\./)?bin/meteorite$' "$WORK_DIR/tar-detail.txt" || { echo "FAIL: declared bin lost executable mode"; cat "$WORK_DIR/tar-detail.txt"; exit 1; }
grep -Eq '^\.?/?src/app.lua$' "$WORK_DIR/tar-list.txt" || { echo "FAIL: src/app.lua not archived"; exit 1; }
grep -Eq '^\.?/?native/module.zig$' "$WORK_DIR/tar-list.txt" || { echo "FAIL: native/module.zig not archived"; exit 1; }
if grep -q '^\.moonstone/' "$WORK_DIR/tar-list.txt" || grep -q '^zig-out/' "$WORK_DIR/tar-list.txt"; then
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
grep -A4 '^\[\[dependencies\]\]$' dist/registry/meteorite-project/package.toml | grep -q 'name = "user/runtime"' || { echo "FAIL: source descriptor omitted runtime dependency"; cat dist/registry/meteorite-project/package.toml; exit 1; }
grep -A4 '^\[\[dependencies\]\]$' dist/registry/meteorite-project/package.toml | grep -q 'constraint = "\^4.5.6"' || { echo "FAIL: local runtime dependency was not converted to a release constraint"; cat dist/registry/meteorite-project/package.toml; exit 1; }
grep -A4 '^\[\[dependencies\]\]$' dist/registry/meteorite-project/package.toml | grep -q 'resolver = "moonstone"' || { echo "FAIL: local runtime dependency retained its path resolver"; cat dist/registry/meteorite-project/package.toml; exit 1; }
if grep -q 'user/build-tool' dist/registry/meteorite-project/package.toml; then
  echo "FAIL: source descriptor published a tool dependency"
  cat dist/registry/meteorite-project/package.toml
  exit 1
fi

cat > "$WORK_DIR/partiture_conventional.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local convention = ballad.conventions
  local project = moonstone.project({ root = "." })
  local source_artifact = moonstone.registry.source_package(project, {
    collect = {
      lua_modules = {
        convention.tree("src", {
          prefix = "meteorite",
          overrides = { ["app.lua"] = "meteorite.lua" },
        }),
      },
    },
  })
  p.sink.artifact(source_artifact, { out = "dist/registry/meteorite-conventional" })
end)
LUA

luajit "$BALLAD_ROOT/src/main.lua" play partiture_conventional.lua > "$WORK_DIR/run-conventional.log" 2>&1 || { cat "$WORK_DIR/run-conventional.log"; exit 1; }
test -f dist/registry/meteorite-conventional/package.toml || { echo "FAIL: conventional package.toml missing"; exit 1; }
grep -q 'name = "user/meteorite"' dist/registry/meteorite-conventional/package.toml || { echo "FAIL: conventional package name was not inferred"; exit 1; }
grep -q 'version = "1.2.3"' dist/registry/meteorite-conventional/package.toml || { echo "FAIL: conventional package version was not inferred"; exit 1; }
grep -q 'name = "meteorite.lua"' dist/registry/meteorite-conventional/package.toml || { echo "FAIL: conventional tree was not collected"; exit 1; }

echo "PASS: registry.source_package emits source package descriptor and archive"

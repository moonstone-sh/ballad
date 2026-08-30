#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-registry-helper.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/native/ballad-watch" "$WORK_DIR/fake-bin"
cp "$ROOT/partiture.ballad-watch.lua" "$WORK_DIR/partiture.ballad-watch.lua"
printf 'fake build input\n' > "$WORK_DIR/native/ballad-watch/build.zig"
mkdir -p "$WORK_DIR/native/ballad-watch/src"
printf 'fake source\n' > "$WORK_DIR/native/ballad-watch/src/main.zig"

cat > "$WORK_DIR/fake-bin/zig" <<'SH'
#!/usr/bin/env sh
set -eu
[ "$1" = build ] && [ "$2" = '-Dtarget=x86_64-windows-gnu' ] && [ "$3" = '-Doptimize=ReleaseSafe' ] || exit 64
mkdir -p zig-out/bin
printf 'windows helper\n' > zig-out/bin/ballad-watch.exe
SH
chmod +x "$WORK_DIR/fake-bin/zig"

cat > "$WORK_DIR/fake-bin/moon" <<'SH'
#!/usr/bin/env sh
set -eu
[ "$1" = artifact ] && [ "$2" = create ] && [ "$3" = --out ] && [ "$5" = --json ] && [ "$6" = -- ] || exit 64
out=$4
shift 6
while [ "$#" -gt 0 ]; do
  if [ "$1" = recipe ]; then
    [ "$3" = 0644 ] || exit 65
  else
    [ "$1" = bin/ballad-watch.exe ] && [ "$3" = 0755 ] || exit 66
  fi
  shift 3
done
printf archive > "$out"
printf '{"contract":"moonstone:artifact-create:v1","path":"%s","bytes":7,"b3":"b3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' "$out"
SH
chmod +x "$WORK_DIR/fake-bin/moon"

cd "$WORK_DIR"
LUA_PATH="$ROOT/.moonstone/env/share/lua/5.1/?.lua;$ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$ROOT/src/?.lua;$ROOT/src/?/init.lua;;"
export LUA_PATH
PATH="$WORK_DIR/fake-bin:$PATH" MOONSTONE_CLI="$WORK_DIR/fake-bin/moon" \
  luajit "$ROOT/src/main.lua" play partiture.ballad-watch.lua > run.log 2>&1 || { cat run.log; exit 1; }

descriptor=dist/registry/ballad-watch/package.toml
test -f "$descriptor" || { echo "FAIL: helper descriptor missing"; exit 1; }
test -f dist/registry/ballad-watch/ballad-watch-0.3.5-x86_64-windows-gnu.tar.gz || { echo "FAIL: helper archive missing"; exit 1; }
grep -q 'name = "moonstone/ballad-watch"' "$descriptor"
grep -q 'target = "x86_64-windows-gnu"' "$descriptor"
grep -q 'name = "ballad-watch"' "$descriptor"
grep -q 'path = "bin/ballad-watch.exe"' "$descriptor"
grep -q 'strip_components = 0' "$descriptor"

echo "PASS: ballad-watch helper archive, descriptor, provision, and target"

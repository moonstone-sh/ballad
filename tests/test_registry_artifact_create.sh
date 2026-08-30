#!/usr/bin/env sh
set -eu

BALLAD_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-artifact-create.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/src" "$WORK_DIR/fake-bin"
printf 'return { answer = 42 }\n' > "$WORK_DIR/src/app.lua"
cat > "$WORK_DIR/partiture.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local sources = p.source.directory(".")
  local artifact = moonstone.registry.source_package(sources, {
    name = "user/artifact-create",
    version = "1.0.0",
    include = { "src/**" },
    materialize = { type = "command", command = "true" },
    out = "dist/registry/artifact-create",
  })
  p.sink.artifact(artifact, { out = "dist/registry/artifact-create" })
end)
LUA

cat > "$WORK_DIR/fake-bin/moon" <<'SH'
#!/usr/bin/env sh
set -eu
[ "$1" = artifact ] && [ "$2" = create ] && [ "$3" = --out ] && [ "$5" = --json ] && [ "$6" = -- ] || {
  echo "unexpected moon invocation: $*" >&2
  exit 64
}
out=$4
shift 6
printf '%s\n' "$@" >> "$ARTIFACT_LOG"
digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
while [ "$#" -gt 0 ]; do
  virtual=$1
  source=$2
  mode=$3
  [ "$mode" = 0644 ] || [ "$mode" = 0755 ]
  if [ "$virtual" = recipe ]; then
    digest=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  fi
  shift 3
done
printf x > "$out"
printf '{"contract":"moonstone:artifact-create:v1","path":"%s","bytes":1,"b3":"b3:%s"}\n' "$out" "$digest"
SH
chmod +x "$WORK_DIR/fake-bin/moon"

# The Moonstone-backed tar.gz route must not execute legacy archive/hash tools.
for tool in tar zstd b3sum; do
  cat > "$WORK_DIR/fake-bin/$tool" <<'SH'
#!/usr/bin/env sh
echo "unexpected legacy archive tool: $0" >&2
exit 99
SH
  chmod +x "$WORK_DIR/fake-bin/$tool"
done

cd "$WORK_DIR"
LUA_PATH="$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?.lua;$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$BALLAD_ROOT/src/?.lua;$BALLAD_ROOT/src/?/init.lua;;"
export LUA_PATH
PATH="$WORK_DIR/fake-bin:$PATH" MOONSTONE_CLI="$WORK_DIR/fake-bin/moon" ARTIFACT_LOG="$WORK_DIR/artifact-args.log" \
  luajit "$BALLAD_ROOT/src/main.lua" play partiture.lua > "$WORK_DIR/run.log" 2>&1 || { cat "$WORK_DIR/run.log"; exit 1; }

DESCRIPTOR=dist/registry/artifact-create/package.toml
grep -q '^format = "tar.gz"$' "$DESCRIPTOR" || { echo "FAIL: source package did not select tar.gz"; exit 1; }
grep -q '^hash = "b3:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"$' "$DESCRIPTOR" || { echo "FAIL: JSON artifact digest was not used"; exit 1; }
grep -q '^bytes = 1$' "$DESCRIPTOR" || { echo "FAIL: JSON artifact byte count was not used"; exit 1; }
grep -q '^src/app.lua$' "$WORK_DIR/artifact-args.log" || { echo "FAIL: Ballad did not declare the selected source entry"; cat "$WORK_DIR/artifact-args.log"; exit 1; }
grep -q '^0644$' "$WORK_DIR/artifact-args.log" || { echo "FAIL: Ballad did not declare a portable entry mode"; exit 1; }

cat > "$WORK_DIR/fake-bin/old-moon" <<'SH'
#!/usr/bin/env sh
echo "Error: unknown command 'artifact'" >&2
exit 1
SH
chmod +x "$WORK_DIR/fake-bin/old-moon"
if MOONSTONE_CLI="$WORK_DIR/fake-bin/old-moon" ARTIFACT_LOG="$WORK_DIR/unused.log" \
  luajit "$BALLAD_ROOT/src/main.lua" play partiture.lua > "$WORK_DIR/old-moon.log" 2>&1; then
  echo "FAIL: old Moonstone artifact capability was accepted"
  exit 1
fi
grep -q 'moonstone:artifact-create:v1' "$WORK_DIR/old-moon.log" || { cat "$WORK_DIR/old-moon.log"; echo "FAIL: versioned capability diagnostic missing"; exit 1; }
grep -q 'upgrade to the first artifact-create milestone' "$WORK_DIR/old-moon.log" || { cat "$WORK_DIR/old-moon.log"; echo "FAIL: capability upgrade diagnostic missing"; exit 1; }

echo "PASS: registry tar.gz uses Moonstone artifact-create JSON and diagnoses an old CLI"

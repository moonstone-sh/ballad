#!/usr/bin/env sh
set -eu

BALLAD_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-moonstone-contract.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/project/.moonstone/env"
printf 'storage discovery only\n' > "$WORK_DIR/project/moonstone.toml"
printf 'storage discovery only\n' > "$WORK_DIR/project/moonstone.lock"
cat > "$WORK_DIR/project/.moonstone/env/env.toml" <<'TOML'
[runtime]
name = "lua"
version = "5.4"
abi = "5.4"
TOML

cat > "$WORK_DIR/moon" <<'SH'
#!/usr/bin/env sh
set -eu
if [ "${1:-}" = "-C" ]; then
  [ "${2:-}" = "$EXPECTED_PROJECT_ROOT" ] || {
    echo "unexpected project root: ${2:-}" >&2
    exit 1
  }
  shift 2
fi
case "$1:$2:$3" in
  manifest:export:--json)
    cat <<'JSON'
{"contract":"moonstone:manifest:v1","storage_revision":"b3:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","manifest":{"manifest_version":2,"project":{"name":"semantic-service","version":"1.2.3","kind":"bin","description":"from protocol","readme":"REGISTRY_README.md"},"runtime":{"name":"lua","version":"5.4","abi":"5.4"},"origin":{"kind":"git","url":"https://example.test/semantic-service","revision":"main","hash":null},"tidy":{"scripts":"lexicographic","on_script_mutation":true},"dependencies":[{"name":"moonstone/meteorite","constraint":"0.1.41","registry":"moonstone","role":"tool","optional":false}],"scripts":[],"registries":[],"orbits":[{"name":"site","path":"apps/site"}]}}
JSON
    ;;
  lock:export:--json)
    cat <<'JSON'
{"contract":"moonstone:lock:v1","storage_revision":"b3:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210","lockfile_version":3,"realizations":[{"realization_hash":"b3:realization","name":"moonstone/meteorite","version":"0.1.41","kind":"tool","resolver":"moonstone","registry":"moonstone","artifact_hash":"b3:artifact","source_hash":"b3:source","recipe_hash":"b3:recipe","runtime":"lua@5.4","lua_abi":"5.4","target":"aarch64-macos","replay_mode":"portable_source","reproducible":true}],"profiles":[]}
JSON
    ;;
  *)
    echo "unexpected fake moon invocation: $*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$WORK_DIR/moon"

EXPECTED_PROJECT_ROOT="$WORK_DIR/project" LUA_PATH="$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?.lua;$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$BALLAD_ROOT/src/?.lua;$BALLAD_ROOT/src/?/init.lua;;" \
  "${LUA_BIN:-luajit}" - "$WORK_DIR/project" "$WORK_DIR/moon" <<'LUA'
local project = require("ballad.project")
local loaded = project.load(arg[1], { moon = arg[2] })

assert(loaded.manifest.package.name == "semantic-service")
assert(loaded.manifest.package.readme == "REGISTRY_README.md")
assert(loaded.manifest.origin.url == "https://example.test/semantic-service")
assert(loaded.manifest.dependencies[1].name == "moonstone/meteorite")
assert(loaded.manifest.orbits[1].path == "apps/site")
assert(loaded.packages[1].artifact_hash == "b3:artifact")
print("PASS: Ballad consumes Moonstone semantic manifest and lock contracts")
LUA

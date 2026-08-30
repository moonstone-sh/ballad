#!/usr/bin/env sh
set -eu

BALLAD_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-runtime-registry.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/artifacts"
printf 'linux runtime\n' > "$WORK_DIR/artifacts/lua-5.4.8-x86_64-linux-gnu.tar.zst"
printf 'windows runtime\n' > "$WORK_DIR/artifacts/lua-5.4.8-x86_64-windows-gnu.tar.zst"
printf '# Lua runtime\n' > "$WORK_DIR/README.md"

cat > "$WORK_DIR/partiture.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local runtime = moonstone.registry.runtime({
    name = "lua",
    package_name = "moonstone/lua",
    version = "5.4.8",
    artifacts_dir = "artifacts",
    out = "dist",
  })
  p.sink.artifact(runtime, { out = "dist/moonstone-lua-5.4.8-package.toml" })
end)
LUA

cd "$WORK_DIR"
LUA_PATH="$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?.lua;$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$BALLAD_ROOT/src/?.lua;$BALLAD_ROOT/src/?/init.lua;;"
export LUA_PATH
luajit "$BALLAD_ROOT/src/main.lua" play partiture.lua > "$WORK_DIR/run.log" 2>&1 || { cat "$WORK_DIR/run.log"; exit 1; }

DESCRIPTOR="$WORK_DIR/dist/moonstone-lua-5.4.8-package.toml"
test -f "$DESCRIPTOR" || { echo "FAIL: runtime descriptor missing"; exit 1; }
grep -q '^readme = "README.md"$' "$DESCRIPTOR" || { echo "FAIL: runtime README declaration missing"; exit 1; }
grep -q -- '-F readme=@' "$WORK_DIR/dist/publish-moonstone-lua-5.4.8.sh" || { echo "FAIL: runtime README upload missing"; exit 1; }

WINDOWS_BLOCK=$(awk '/^\[\[artifacts\]\]$/{if (capture) exit} /target = "x86_64-windows-gnu"/{capture=1} capture{print}' "$DESCRIPTOR")
printf '%s\n' "$WINDOWS_BLOCK" | grep -q 'path = "bin/lua.exe"' || { echo "FAIL: Windows lua.exe provision missing"; exit 1; }
printf '%s\n' "$WINDOWS_BLOCK" | grep -q 'path = "bin/luac.exe"' || { echo "FAIL: Windows luac.exe provision missing"; exit 1; }

LINUX_BLOCK=$(awk '/^\[\[artifacts\]\]$/{if (capture) exit} /target = "x86_64-linux-gnu"/{capture=1} capture{print}' "$DESCRIPTOR")
printf '%s\n' "$LINUX_BLOCK" | grep -q 'path = "bin/lua"' || { echo "FAIL: Unix lua provision changed"; exit 1; }
printf '%s\n' "$LINUX_BLOCK" | grep -q 'path = "bin/luac"' || { echo "FAIL: Unix luac provision changed"; exit 1; }

echo "PASS: runtime registry provisions target-specific executable paths"

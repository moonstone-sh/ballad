#!/bin/sh
set -eu
unset LUA_PATH_5_4 LUA_CPATH_5_4
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
export LUA_PATH="$ROOT/src/?.lua;$ROOT/src/?/init.lua;$ROOT/.moonstone/env/share/lua/5.4/?.lua;$ROOT/.moonstone/env/share/lua/5.4/?/init.lua;;"
cd "$WORK_DIR"
"${LUA_BIN:-lua}" "$ROOT/tests/incremental_spec.lua"

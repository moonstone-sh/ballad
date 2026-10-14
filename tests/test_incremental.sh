#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
export LUA_PATH="$ROOT/src/?.lua;$ROOT/src/?/init.lua;$ROOT/.moonstone/env/share/lua/5.1/?.lua;$ROOT/.moonstone/env/share/lua/5.1/?/init.lua;;"
cd "$WORK_DIR"
"${LUA_BIN:-luajit}" "$ROOT/tests/incremental_spec.lua"

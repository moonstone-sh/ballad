#!/usr/bin/env sh
# Runs tests/flavors_spec.lua under the tool runtime and every other
# Lua on PATH, since crc32 has per-flavor variants and a fallback for all.
set -eu

BALLAD_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export BALLAD_ROOT

ran=0
for lua in luajit lua5.1 lua5.2 lua5.3 lua5.4 lua5.5 lua; do
  command -v "$lua" >/dev/null 2>&1 || continue
  "$lua" "$BALLAD_ROOT/tests/flavors_spec.lua"
  ran=$((ran + 1))
done
test "$ran" -gt 0

MOONSTONE_TARGET=lua51-x86_64-linux BALLAD_EXPECT_TARGET=lua51-x86_64-linux "${LUA_BIN:-lua}" "$BALLAD_ROOT/tests/flavors_spec.lua" >/dev/null
echo "PASS: flavor variants on $ran interpreter(s)"

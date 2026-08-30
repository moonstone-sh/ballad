#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-windows-portability.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/check.lua" <<'LUA'
local fs = require("ballad.fs")
local launcher = require("ballad.launcher")
local path = require("ballad.path")
local process = require("ballad.process")

assert(path.normalize([[c:\work\..\Export]], "windows") == "C:/Export")
assert(path.normalize([[\\server\share\dir\..\app]], "windows") == "//server/share/app")
assert(path.relative("C:/Export/Lua/Main.lua", "c:/export", "windows") == "Lua/Main.lua")
assert(path.is_root("C:/", "windows"))
assert(path.relative("file.lua", ".") == "file.lua")
assert(path.contains(".", "nested/file.lua"))

local command = process.build_command({
  tool = [[C:\Tools\lua.exe]],
  args = { "-e", "print_ok", "space value" },
  cwd = [[C:\Work Dir]],
  env = { BALLAD_TEST = "value" },
  stdout_file = [[C:\Temp\out.txt]],
  stderr_file = [[C:\Temp\err.txt]],
}, "windows")
assert(command:match("^cmd /d /v:off /s /c "))
assert(command == [[cmd /d /v:off /s /c "setlocal DisableDelayedExpansion && pushd "C:\Work Dir" && set "BALLAD_TEST=value" && "C:\Tools\lua.exe" "-e" "print_ok" "space value"" > "C:\Temp\out.txt" 2> "C:\Temp\err.txt"]])

for _, metacharacter in ipairs({ "&", "|", "<", ">", "(", ")", "^", '"', "!", "%" }) do
  local ok, err = pcall(process.build_command, { tool = "tool.exe", args = { "value" .. metacharacter } }, "windows")
  assert(not ok and tostring(err):find("cmd metacharacter", 1, true))
end
for _, opts in ipairs({
  { tool = "tool.exe", cwd = "bad&cwd" },
  { tool = "tool.exe", env = { BALLAD_TEST = "bad|env" } },
  { tool = "tool.exe", stdout_file = "bad>out" },
  { tool = "tool.exe", args = { "line\nbreak" } },
  { tool = "tool.exe", args = { "trailing\\" } },
  { tool = "tool.exe", args = { 42 } },
}) do
  assert(not pcall(process.build_command, opts, "windows"))
end

local native_tool = launcher.windows_libexec({
  libexec_root = "libexec/tool",
  entry = "bin/tool.exe",
  direct = true,
  path_prepend = true,
})
assert(native_tool:find('"%LIBEXEC%\\bin\\tool.exe" %*', 1, true))
assert(not native_tool:find("LUA_BIN", 1, true))

fs.write_file("old.txt", "old")
fs.write_file("new.txt", "new")
fs.write_file("old.txt.ballad-backup", "preserve")
assert(fs.replace_file("new.txt", "old.txt"))
assert(fs.read_file("old.txt") == "new")
assert(fs.read_file("old.txt.ballad-backup") == "preserve")
fs.mkdir("report-directory")
fs.write_file("pending-report.txt", "pending")
local replaced, replace_err = fs.replace_file("pending-report.txt", "report-directory")
assert(not replaced and tostring(replace_err):find("destination is a directory", 1, true))
assert(fs.read_file("pending-report.txt") == "pending")
fs.copy_tree("tree-src", "tree-dest")
LUA

cd "$WORK_DIR"
mkdir -p tree-src/nested
printf 'tree payload\n' > tree-src/nested/file.txt
printf '#!/bin/sh\nexit 0\n' > tree-src/run
chmod +x tree-src/run
ln -s nested/file.txt tree-src/link
LUA_PATH="$ROOT/.moonstone/env/share/lua/5.1/?.lua;$ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$ROOT/src/?.lua;$ROOT/src/?/init.lua;;" \
  "${LUA_BIN:-luajit}" check.lua
test -L tree-dest/link
test "$(readlink tree-dest/link)" = "nested/file.txt"
test -x tree-dest/run
test "$(cat tree-dest/nested/file.txt)" = "tree payload"

echo "PASS: Windows command boundary, virtual paths, report replacement, and POSIX tree copies are portable"

#!/usr/bin/env sh
set -eu

BALLAD_ROOT=${BALLAD_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
BALLAD_LUA_PATH="$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?.lua;$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$BALLAD_ROOT/src/?.lua;$BALLAD_ROOT/src/?/init.lua;;"

cd "$BALLAD_ROOT"
LUA_PATH=$BALLAD_LUA_PATH
export LUA_PATH

echo "=== Test 1: project metadata extraction ==="
CI_PROBE_DIR=.ci/ballad-release-probe
mkdir -p "$CI_PROBE_DIR"
printf 'CI scaffolding must not ship.\n' > "$CI_PROBE_DIR/ignored.txt"
trap 'rm -rf "$CI_PROBE_DIR"' EXIT INT TERM
rm -rf dist/ballad
luajit src/main.lua play partiture.lua
PKG_VERSION=$(grep '^version' dist/ballad/registry-artifact/package.toml | head -1)
echo "package.toml version line: $PKG_VERSION"
echo "$PKG_VERSION" | grep -q '0.2.' || { echo "FAIL: version mismatch"; exit 1; }
PACKAGE_ARCHIVE=$(find dist/ballad/registry-artifact -maxdepth 1 -type f -name 'ballad-*-any.tar.gz' -print -quit)
if tar -tzf "$PACKAGE_ARCHIVE" | grep -Eq '^\./libexec/ballad/(\.ci|docs|fixtures|synthetic-playground|tests)/'; then
  echo "FAIL: registry artifact contains non-runtime project files"
  exit 1
fi
echo "PASS: version matches moonstone.toml"

echo ""
echo "=== Test 2: no hardcoded version ==="
if grep -q 'version = "0.2.0"' partiture.lua; then
  echo "FAIL: partiture.lua still hardcodes version"
  exit 1
fi
echo "PASS: partiture.lua does not hardcode version"

echo ""
echo "=== Test 3: compatibility file graph ==="
test -f dist/ballad/file-graph.json || { echo "FAIL: dist/ballad/file-graph.json missing"; exit 1; }
test -d .ballad/runs || { echo "FAIL: .ballad/runs missing"; exit 1; }
LATEST_RUN=$(ls -1t .ballad/runs | head -1)
test -f ".ballad/runs/$LATEST_RUN/graph.json" || { echo "FAIL: graph.json missing"; exit 1; }
cat dist/ballad/file-graph.json | jq -e '.files[] | select(.dest == "bin/ballad")' > /dev/null || { echo "FAIL: bin/ballad missing from file-graph.json"; exit 1; }
cat dist/ballad/file-graph.json | jq -e '.files[] | select(.dest == "libexec/ballad/src/main.lua")' > /dev/null || { echo "FAIL: libexec/ballad/src/main.lua missing from file-graph.json"; exit 1; }
echo "PASS: file-graph.json and graph.json both exist with expected entries"

echo ""
echo "=== Test 3b: flat layout ==="
cd "$BALLAD_ROOT"
cat > /tmp/test_flat.lua << 'LUAEOF'
local ballad = require("ballad")
return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local layout = p:use(ballad.plugins.layout)

  local project = moonstone.project({ root = "." })
  local app = layout.flat(project, {
    name = "ballad",
    entry = "src/main.lua",
  })
  local registry_artifact = moonstone.registry.package(app, {
    name = project.registry_name or "moonstone/ballad",
    version = project.version,
    target = "any",
    runtime = project.runtime_spec or "moonstone/luajit@2.1.0",
    lua_abi = project.lua_abi or "5.1",
    description = project.description,
  })
  p.sink.directory(app, {
    out = "dist/flat-root",
    file_graph = true,
  })
  p.sink.artifact(registry_artifact, {
    out = "dist/flat-root/registry-artifact",
  })
end)
LUAEOF
rm -rf dist/flat-root
luajit src/main.lua play /tmp/test_flat.lua > /tmp/flat_test.log 2>&1
test -f dist/flat-root/src/main.lua || { echo "FAIL: dist/flat-root/src/main.lua missing"; cat /tmp/flat_test.log; exit 1; }
test -d dist/flat-root/lua || { echo "FAIL: dist/flat-root/lua missing"; cat /tmp/flat_test.log; exit 1; }
! test -f dist/flat-root/bin/ballad || { echo "FAIL: flat layout should not create launcher"; exit 1; }
cat dist/flat-root/file-graph.json | jq -e '.layout == "flat"' > /dev/null || { echo "FAIL: file-graph layout is not flat"; exit 1; }
cat dist/flat-root/file-graph.json | jq -e '.files[] | select(.dest == "src/main.lua")' > /dev/null || { echo "FAIL: src/main.lua missing from file-graph"; exit 1; }
cat dist/flat-root/file-graph.json | jq -e '.files[] | select(.dest | startswith("lua/"))' > /dev/null || { echo "FAIL: lua modules missing from file-graph"; exit 1; }
echo "PASS: flat layout produces root-level files without launcher"

echo ""
echo "=== Test 4: native task success ==="
cat > /tmp/test_native_success.lua << 'LUAEOF'
local ballad = require("ballad")
return ballad.partiture(function(p)
  p:native_task({
    tool = "sh",
    args = { "-c", "echo hello > native-output.txt" },
    outputs = { "native-output.txt" },
    description = "Test native task success",
  })
  p.sink.file_graph(p.source.files({ "native-output.txt" }), {
    out = "/tmp/native-success-file-graph.json",
  })
end)
LUAEOF
rm -f native-output.txt
rm -rf .ballad/runs
luajit src/main.lua play /tmp/test_native_success.lua > /tmp/native_success.log 2>&1
test -f native-output.txt || { echo "FAIL: native-output.txt not created"; exit 1; }
grep -q "hello" native-output.txt || { echo "FAIL: native-output.txt content wrong"; exit 1; }
LATEST_RUN=$(ls -1t .ballad/runs | head -1)
test -f ".ballad/runs/$LATEST_RUN/events.ndjson" || { echo "FAIL: events.ndjson missing"; exit 1; }
grep -q "task_started" ".ballad/runs/$LATEST_RUN/events.ndjson" || { echo "FAIL: task_started event missing"; exit 1; }
grep -q "task_finished" ".ballad/runs/$LATEST_RUN/events.ndjson" || { echo "FAIL: task_finished event missing"; exit 1; }
rm -f native-output.txt
echo "PASS: native task success creates output and events"

echo ""
echo "=== Test 5: native task missing tool ==="
cat > /tmp/test_native_tool.lua << 'LUAEOF'
local ballad = require("ballad")
return ballad.partiture(function(p)
  p:native_task({
    tool = "definitely-not-a-real-tool-12345",
    args = {},
    outputs = { "x.txt" },
  })
end)
LUAEOF
if luajit src/main.lua play /tmp/test_native_tool.lua > /tmp/native_tool.log 2>&1; then
  echo "FAIL: should have failed for missing tool"
  exit 1
fi
grep -q "tool not found" /tmp/native_tool.log || { echo "FAIL: missing tool diagnostic not found"; exit 1; }
LATEST_RUN=$(ls -1t .ballad/runs | head -1)
test -f ".ballad/runs/$LATEST_RUN/graph.json" || { echo "FAIL: failed native task graph missing"; exit 1; }
test -f ".ballad/runs/$LATEST_RUN/events.ndjson" || { echo "FAIL: failed native task events missing"; exit 1; }
grep -q '"task_failed"' ".ballad/runs/$LATEST_RUN/events.ndjson" || { echo "FAIL: failed native task event missing"; exit 1; }
echo "PASS: native task fails clearly for missing tool"

echo ""
echo "=== Test 6: native task missing output ==="
cat > /tmp/test_native_output.lua << 'LUAEOF'
local ballad = require("ballad")
return ballad.partiture(function(p)
  p:native_task({
    tool = "sh",
    args = { "-c", "exit 0" },
    outputs = { "missing.txt" },
  })
end)
LUAEOF
if luajit src/main.lua play /tmp/test_native_output.lua > /tmp/native_output.log 2>&1; then
  echo "FAIL: should have failed for missing output"
  exit 1
fi
grep -q "Missing outputs" /tmp/native_output.log || { echo "FAIL: missing output diagnostic not found"; exit 1; }
LATEST_RUN=$(ls -1t .ballad/runs | head -1)
test -f ".ballad/runs/$LATEST_RUN/graph.json" || { echo "FAIL: incomplete native task graph missing"; exit 1; }
grep -q '"task_incomplete"' ".ballad/runs/$LATEST_RUN/events.ndjson" || { echo "FAIL: incomplete native task event missing"; exit 1; }
echo "PASS: native task fails clearly for missing output"

echo ""
echo "=== Test 7: love plugin layout and pack ==="
rm -rf /tmp/love-test-project
mkdir -p /tmp/love-test-project/src /tmp/love-test-project/.moonstone/env
cat > /tmp/love-test-project/.moonstone/env/env.toml << 'EOF'
[runtime]
name = "love"
version = "11.5"
abi = "lua51"
EOF
  cat > /tmp/love-test-project/moonstone.toml << 'EOF'
[package]
name = "love-game"
version = "0.1.0"
kind = "script"
description = "Test LÖVE game"

[interpreter]
name = "love"
version = "11.5"
abi = "5.1"
EOF
  echo "function love.draw() end" > /tmp/love-test-project/main.lua
  echo "function love.conf(t) t.identity = 'love-game' end" > /tmp/love-test-project/conf.lua
  echo "return {}" > /tmp/love-test-project/src/utils.lua
  cat > /tmp/love-test-project/partiture.lua << 'EOF'
local ballad = require("ballad")
return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local love = p:use(ballad.plugins.love)
  local project = moonstone.project({ root = "." })
  local app = love.layout(project, { main = "main.lua", conf = "conf.lua" })
  local archive = love.pack(app, { out = "dist/my-love-game.love" })
  local reg = moonstone.registry.package(app, { name = "my-love-game", version = "0.1.0", runtime = "love@11.5" })
  p.sink.directory(app, { out = "dist/love-root" })
  p.sink.artifact(archive, { out = "dist/my-love-game.love" })
  p.sink.artifact(reg, { out = "dist/love-root/registry-artifact" })
end)
EOF

cd /tmp/love-test-project
rm -rf dist
LUA_PATH=$BALLAD_LUA_PATH
export LUA_PATH
luajit "$BALLAD_ROOT/src/main.lua" play partiture.lua > /tmp/love_test.log 2>&1
test -f dist/my-love-game.love || { echo "FAIL: .love archive not created"; exit 1; }
unzip -l dist/my-love-game.love | grep -q "main.lua" || { echo "FAIL: main.lua not in .love archive"; exit 1; }
unzip -l dist/my-love-game.love | grep -q "conf.lua" || { echo "FAIL: conf.lua not in .love archive"; exit 1; }
unzip -l dist/my-love-game.love | grep -q "src/utils.lua" || { echo "FAIL: src/utils.lua not in .love archive"; exit 1; }
grep -q "runtime = \"love@11.5\"" dist/love-root/registry-artifact/package.toml || { echo "FAIL: love runtime not in package.toml"; exit 1; }
echo "PASS: love plugin layout and pack work correctly"
cd "$BALLAD_ROOT"

echo ""
echo "=== Test 7b: deterministic love archive ==="
rm -rf /tmp/love-determinism
mkdir -p /tmp/love-determinism
cp -r /tmp/love-test-project/dist/love-root /tmp/love-determinism/source
LUA_PATH=$BALLAD_LUA_PATH
export LUA_PATH
luajit -e 'local archive = require("ballad.archive"); local fs = require("ballad.fs"); local path = require("ballad.path"); local entries = {}; for _, f in ipairs(fs.list_files("/tmp/love-determinism/source")) do local rel = path.relative(f, "/tmp/love-determinism/source"); table.insert(entries, {path = rel, src = f}); end; archive.zip_store(entries, "/tmp/love-determinism/a.love", {deterministic = true}); archive.zip_store(entries, "/tmp/love-determinism/b.love", {deterministic = true});'
HASH_A=$(b3sum --no-names /tmp/love-determinism/a.love)
HASH_B=$(b3sum --no-names /tmp/love-determinism/b.love)
if [ "$HASH_A" != "$HASH_B" ]; then
  echo "FAIL: deterministic zip produced different hashes: $HASH_A vs $HASH_B"
  exit 1
fi
echo "PASS: deterministic love archive produces identical hashes"

echo ""
echo "=== Test 8: nvim plugin layout ==="
rm -rf /tmp/nvim-test-project
mkdir -p /tmp/nvim-test-project/lua/my_plugin /tmp/nvim-test-project/plugin /tmp/nvim-test-project/doc /tmp/nvim-test-project/.moonstone/env
cat > /tmp/nvim-test-project/.moonstone/env/env.toml << 'EOF'
[runtime]
name = "nvim"
version = "0.10"
abi = "lua51"
EOF
cat > /tmp/nvim-test-project/moonstone.toml << 'EOF'
[package]
name = "my_plugin"
version = "0.1.0"
kind = "script"

[interpreter]
name = "nvim"
version = "0.10"
abi = "5.1"
EOF
echo "return {}" > /tmp/nvim-test-project/lua/my_plugin/init.lua
echo "require('my_plugin.init')" > /tmp/nvim-test-project/plugin/my_plugin.lua
echo "*my_plugin.txt*" > /tmp/nvim-test-project/doc/my_plugin.txt
cat > /tmp/nvim-test-project/partiture.lua << 'EOF'
local ballad = require("ballad")
return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local nvim = p:use(ballad.plugins.nvim)
  local project = moonstone.project({ root = "." })
  local app = nvim.layout(project, { name = "my_plugin", entry = "plugin/my_plugin.lua" })
  p.sink.directory(app, { out = "dist/nvim-plugin" })
  local reg = moonstone.registry.package(app, { name = "my_plugin", version = "0.1.0", runtime = "nvim@0.10", lua_api = "5.1", entry = "plugin/my_plugin.lua" })
  p.sink.artifact(reg, { out = "dist/nvim-plugin/registry-artifact" })
end)
EOF

cd /tmp/nvim-test-project
rm -rf dist
LUA_PATH=$BALLAD_LUA_PATH
export LUA_PATH
luajit "$BALLAD_ROOT/src/main.lua" play partiture.lua > /tmp/nvim_test.log 2>&1
test -d dist/nvim-plugin/lua/my_plugin || { echo "FAIL: lua/my_plugin not in output"; exit 1; }
test -f dist/nvim-plugin/plugin/my_plugin.lua || { echo "FAIL: plugin/my_plugin.lua not in output"; exit 1; }
test -f dist/nvim-plugin/doc/my_plugin.txt || { echo "FAIL: doc/my_plugin.txt not in output"; exit 1; }
grep -q "runtime = \"nvim@0.10\"" dist/nvim-plugin/registry-artifact/package.toml || { echo "FAIL: nvim runtime not in package.toml"; exit 1; }
grep -q "lua_api = \"5.1\"" dist/nvim-plugin/registry-artifact/package.toml || { echo "FAIL: lua_api not correct in package.toml"; exit 1; }
echo "PASS: nvim plugin layout works correctly"
cd "$BALLAD_ROOT"

echo ""

echo ""
echo "=== Test 9: cache layer ==="
cd /tmp/love-test-project
rm -rf dist .ballad/cache
LUA_PATH=$BALLAD_LUA_PATH
export LUA_PATH
luajit "$BALLAD_ROOT/src/main.lua" play partiture.lua > /tmp/cache_run1.log 2>&1
if grep -q "Cache hit" /tmp/cache_run1.log; then
  echo "FAIL: first run should not have cache hits"
  exit 1
fi
test -d .ballad/cache/tasks || { echo "FAIL: cache directory not created"; exit 1; }
luajit "$BALLAD_ROOT/src/main.lua" play partiture.lua > /tmp/cache_run2.log 2>&1
if ! grep -q "Cache hit" /tmp/cache_run2.log; then
  echo "FAIL: second run should have cache hits"
  exit 1
fi
echo "PASS: cache skips tasks on second run"

# Test: deleting output invalidates cache
rm -f dist/my-love-game.love
luajit "$BALLAD_ROOT/src/main.lua" play partiture.lua > /tmp/cache_run3.log 2>&1
if grep -q "Cache hit: node_5" /tmp/cache_run3.log; then
  echo "FAIL: deleted output should invalidate cache"
  exit 1
fi
echo "PASS: deleting output invalidates cache"

cd "$BALLAD_ROOT"
echo "PASS: cache layer works correctly"


echo ""
echo "=== Test 10: parallel scheduler ==="
cat > /tmp/test_parallel.lua << 'LUAEOF'
local ballad = require("ballad")
return ballad.partiture(function(p)
  p:native_task({
    tool = "sh",
    args = { "-c", "sleep 0.3 && echo a > /tmp/parallel_a.txt" },
    outputs = { "/tmp/parallel_a.txt" },
    parallel_safe = true,
    description = "Parallel task A",
  })
  p:native_task({
    tool = "sh",
    args = { "-c", "sleep 0.3 && echo b > /tmp/parallel_b.txt" },
    outputs = { "/tmp/parallel_b.txt" },
    parallel_safe = true,
    description = "Parallel task B",
  })
  p.sink.file_graph(p.source.files({ "parallel_a.txt", "parallel_b.txt" }, { root = "/tmp" }), {
    out = "/tmp/parallel-file-graph.json",
  })
end)
LUAEOF
rm -f /tmp/parallel_a.txt /tmp/parallel_b.txt
luajit "$BALLAD_ROOT/src/main.lua" play /tmp/test_parallel.lua --jobs 2 > /tmp/parallel_test.log 2>&1
test -f /tmp/parallel_a.txt || { echo "FAIL: parallel task A did not produce output"; exit 1; }
test -f /tmp/parallel_b.txt || { echo "FAIL: parallel task B did not produce output"; exit 1; }
grep -q "a" /tmp/parallel_a.txt || { echo "FAIL: parallel task A content wrong"; exit 1; }
grep -q "b" /tmp/parallel_b.txt || { echo "FAIL: parallel task B content wrong"; exit 1; }
rm -f /tmp/parallel_a.txt /tmp/parallel_b.txt
echo "PASS: parallel scheduler runs tasks concurrently"


echo ""
echo "=== Test 11: dependency export policies ==="
rm -rf /tmp/nvim-deps-test-project
mkdir -p /tmp/nvim-deps-test-project/lua/my_plugin /tmp/nvim-deps-test-project/.moonstone/env
cat > /tmp/nvim-deps-test-project/.moonstone/env/env.toml << 'EOF'
[runtime]
name = "nvim"
version = "0.10"
abi = "lua51"
EOF
cat > /tmp/nvim-deps-test-project/moonstone.toml << 'EOF'
[package]
name = "my_plugin"
version = "0.1.0"
kind = "script"

[interpreter]
name = "nvim"
version = "0.10"
abi = "5.1"

[[dependencies]]
name = "nvim-lua/plenary.nvim"
constraint = "*"
role = "peer"

[[dependencies]]
name = "nvim-telescope/telescope.nvim"
constraint = "*"
role = "optional"
EOF
echo "require('plenary')" > /tmp/nvim-deps-test-project/lua/my_plugin/init.lua
echo "require('my_plugin.init')" > /tmp/nvim-deps-test-project/lua/my_plugin/utils.lua
echo "require('telescope')" >> /tmp/nvim-deps-test-project/lua/my_plugin/utils.lua
echo "require('unknown_lib')" >> /tmp/nvim-deps-test-project/lua/my_plugin/utils.lua
cat > /tmp/nvim-deps-test-project/partiture.lua << 'EOF'
local ballad = require("ballad")
return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local nvim = p:use(ballad.plugins.nvim)
  local project = moonstone.project({ root = "." })
  local app = nvim.layout(project, { name = "my_plugin", entry = "lua/my_plugin/init.lua" })
  p.sink.directory(app, { out = "dist/nvim-plugin" })
  local reg = moonstone.registry.package(app, { name = "my_plugin", version = "0.1.0", entry = "lua/my_plugin/init.lua", out = "dist/nvim-deps-artifact" })
  p.sink.artifact(reg, { out = "dist/nvim-deps-artifact" })
end)
EOF

cd /tmp/nvim-deps-test-project
rm -rf dist .ballad/cache
LUA_PATH=$BALLAD_LUA_PATH
export LUA_PATH
luajit "$BALLAD_ROOT/src/main.lua" play partiture.lua > /tmp/nvim_deps_test.log 2>&1

# Check that the plugin was emitted
if [ ! -d "dist/nvim-plugin/lua/my_plugin" ]; then
  echo "FAIL: plugin files not emitted"
  cat /tmp/nvim_deps_test.log
  exit 1
fi

# Check that internal modules are present
test -f "dist/nvim-plugin/lua/my_plugin/init.lua" || { echo "FAIL: init.lua missing"; exit 1; }
test -f "dist/nvim-plugin/lua/my_plugin/utils.lua" || { echo "FAIL: utils.lua missing"; exit 1; }

# Check that package.toml includes peer dependencies
if ! grep -q "name = \"plenary\"" dist/nvim-deps-artifact/package.toml; then
  echo "FAIL: plenary peer dependency not in package.toml"
  cat dist/nvim-deps-artifact/package.toml
  exit 1
fi
if ! grep -q "role = \"peer\"" dist/nvim-deps-artifact/package.toml; then
  echo "FAIL: peer role not in package.toml"
  cat dist/nvim-deps-artifact/package.toml
  exit 1
fi
if ! grep -q "package = \"nvim-lua/plenary.nvim\"" dist/nvim-deps-artifact/package.toml; then
  echo "FAIL: plenary package reference not in package.toml"
  cat dist/nvim-deps-artifact/package.toml
  exit 1
fi

# Check optional dependency
if ! grep -q "name = \"telescope\"" dist/nvim-deps-artifact/package.toml; then
  echo "FAIL: telescope optional dependency not in package.toml"
  cat dist/nvim-deps-artifact/package.toml
  exit 1
fi
if ! grep -q "role = \"optional\"" dist/nvim-deps-artifact/package.toml; then
  echo "FAIL: optional role not in package.toml"
  cat dist/nvim-deps-artifact/package.toml
  exit 1
fi
if ! grep -q "optional = true" dist/nvim-deps-artifact/package.toml; then
  echo "FAIL: optional=true not in package.toml"
  cat dist/nvim-deps-artifact/package.toml
  exit 1
fi

# Check that unknown require produced a warning
if ! grep -q "unresolved" /tmp/nvim_deps_test.log; then
  echo "FAIL: unresolved requires did not produce a warning"
  cat /tmp/nvim_deps_test.log
  exit 1
fi

echo "PASS: dependency export policies work correctly"
cd "$BALLAD_ROOT"

echo "=== All Stage 2 tests passed ==="

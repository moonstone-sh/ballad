#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-windows-watcher.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/check.lua" <<'LUA'
local dkjson = require("dkjson")
local graph = require("ballad.graph")
local native_action = require("ballad.native_action")
local process = require("ballad.process")
local watcher = require("ballad.plugins.watcher")

local original_is_windows = process.is_windows
local original_capture_run = process.capture_run
local original_cwd = process.cwd
local calls = {}
local resolver = "valid"
local helper = "valid"

process.is_windows = function() return true end
process.cwd = function() return "C:/fixture" end
process.capture_run = function(opts)
  calls[#calls + 1] = opts
  if opts.tool == "moon" then
    assert(table.concat(opts.args, " ") == "provision resolve ballad-watch --json")
    if resolver == "missing" then return { exit_code = 1, stdout = "", stderr = "tool provision unavailable offline" } end
    if resolver == "old" then return { exit_code = 0, stdout = '{"contract":"moonstone:tool-resolve:v0"}', stderr = "" } end
    return {
      exit_code = 0,
      stdout = '{"contract":"moonstone:tool-resolve:v1","path":"C:/helper/ballad-watch.exe","version":"1.0.0","digest":"b3:fixture","source":"project"}',
      stderr = "",
    }
  end
  assert(opts.tool == "C:/helper/ballad-watch.exe")
  assert(opts.args[1] == "--manifest")
  assert(opts.args[2] == "C:/fixture/node_3.windows.json")
  if helper == "old" then return { exit_code = 64, stdout = "", stderr = "unknown option --manifest" } end
  if helper == "ignores_manifest" then return { exit_code = 0, stdout = "legacy success", stderr = "" } end
  -- The test fixture reads the written manifest instead of guessing from argv.
  local content = assert(io.open("node_3.windows.json", "rb")):read("*a")
  local manifest = assert(dkjson.decode(content))
  return {
    exit_code = 0,
    stdout = string.format('{"contract":"ballad:watcher-result:v1","status":"%s","mode":"%s"}',
      manifest.mode == "once" and "completed" or "stopped", manifest.mode),
    stderr = "",
  }
end

local function action(id, tool, args, outputs)
  return native_action.new({
    id = id,
    tool = tool,
    args = args or {},
    cwd = "build",
    env = { ZED = "last", ALPHA = "first" },
    inputs = { "src/**/*.lua" },
    outputs = outputs or {},
    cacheable = false,
    toolchain_fingerprint = "fixture-toolchain",
  })
end

local function context()
  local g = graph.Graph.new()
  local source_files = g:add_node({
    plugin = "ballad.core.source", method = "files", role = "source",
    options = { root = "src", patterns = { "**/*.lua", "config.lua" } },
  })
  local source_dir = g:add_node({
    plugin = "ballad.core.source", method = "directory", role = "source",
    options = { path = "assets" },
  })
  local node = g:add_node({ plugin = "ballad.plugins.watcher", method = "watch", role = "transform" })
  return g, source_files, source_dir, {
    graph = g,
    node = node,
    fail = function(message) error(message, 0) end,
  }
end

local function full_spec(source_files, source_dir, once)
  return {
    initial = {
      label = "bootstrap",
      outputs = { "dist/bootstrap" },
      run = action("bootstrap", "bootstrap.exe", { "--first", "space value" }, { "dist/native-bootstrap" }),
    },
    reactions = {
      {
        label = "sources first",
        watch = { source_files, source_dir },
        outputs = { "dist/app" },
        run = action("build-app", "builder.exe", { "--out", "dist/app" }, { "dist/native-app" }),
      },
      {
        label = "assets second",
        watch = { source_dir },
        outputs = { "dist/assets" },
        run = action("build-assets", "assets.exe", {}, { "dist/native-assets" }),
      },
    },
    options = { state_dir = ".", cwd = "workspace", interval = 0.5, debounce = 0.1, once = once },
  }
end

local function run(once)
  local g, files, directory, ctx = context()
  local result = watcher.watch(ctx, {}, full_spec(files.id, directory.id, once))
  assert(result:count() == 1)
  return assert(io.open("node_3.windows.json", "rb")):read("*a")
end

local first = run(false)
local second = run(false)
assert(first == second, "watcher manifest must have stable bytes")
local manifest, _, err = dkjson.decode(first)
assert(manifest, err)
assert(manifest.contract == "ballad:watcher:v1")
assert(manifest.mode == "daemon")
assert(manifest.cwd == "workspace")
assert(manifest.interval == 0.5 and manifest.debounce == 0.1)
assert(manifest.initial.action.argv[1] == "bootstrap.exe")
assert(manifest.initial.action.argv[3] == "space value")
assert(manifest.initial.action.env.ALPHA == "first")
assert(manifest.initial.action.cacheable == false)
assert(manifest.reactions[1].label == "sources first")
assert(table.concat(manifest.reactions[1].source_nodes, ",") == "node_1,node_2")
assert(table.concat(manifest.reactions[1].inputs, ",") == "src/**/*.lua,src/*.lua,src/config.lua,assets/**")
assert(manifest.reactions[2].label == "assets second")
assert(table.concat(manifest.output_exclusions, ",")
  == "dist/bootstrap,dist/native-bootstrap,dist/app,dist/native-app,dist/assets,dist/native-assets")
assert(#calls == 4, "each bridge run must resolve then invoke exactly once")
assert(calls[1].tool == "moon" and calls[2].tool == "C:/helper/ballad-watch.exe")

calls = {}
local once_manifest = run(true)
local once_document = assert(dkjson.decode(once_manifest))
assert(once_document.mode == "once")
assert(#calls == 2 and calls[2].args[1] == "--manifest", "once still delegates exactly once to the helper")

local function expect_failure(expected, configure, mutate)
  calls = {}
  resolver, helper = "valid", "valid"
  configure()
  local g, files, directory, ctx = context()
  local spec = full_spec(files.id, directory.id, false)
  mutate(spec)
  local ok, message = pcall(function() watcher.watch(ctx, {}, spec) end)
  assert(not ok and tostring(message):find(expected, 1, true), tostring(message))
  return #calls
end

assert(expect_failure("legacy raw shell fields", function() end, function(spec)
  spec.initial.effect = "unsafe & shell"
  spec.options.cleanup = "also unsafe"
end) == 0, "legacy shell must fail before helper resolution")

assert(expect_failure("moon provision resolve ballad-watch --json", function() resolver = "missing" end, function() end) == 1)
assert(expect_failure("moonstone:tool-resolve:v1", function() resolver = "old" end, function() end) == 1)
assert(expect_failure("missing or too old", function() helper = "old" end, function() end) == 2)
assert(expect_failure("ballad:watcher-result:v1", function() helper = "ignores_manifest" end, function() end) == 2)
assert(expect_failure("task.native cmd", function() end, function(spec)
  spec.initial.run = native_action.new({ id = "raw", cmd = "raw & shell" })
end) == 0, "task.native cmd must never reach the helper")

process.is_windows = original_is_windows
process.capture_run = original_capture_run
process.cwd = original_cwd
print("PASS: Windows watcher bridge emits stable v1 manifests and safely resolves/invokes the helper")
LUA

cd "$WORK_DIR"
LUA_PATH="$ROOT/.moonstone/env/share/lua/5.1/?.lua;$ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$ROOT/src/?.lua;$ROOT/src/?/init.lua;;" \
  "${LUA_BIN:-luajit}" check.lua

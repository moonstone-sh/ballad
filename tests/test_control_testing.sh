#!/usr/bin/env sh
set -eu

BALLAD_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-control.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/release-input" "$WORK_DIR/dev-input"
printf '%s\n' release > "$WORK_DIR/release-input/value.txt"
printf '%s\n' development > "$WORK_DIR/dev-input/value.txt"

cat > "$WORK_DIR/partiture.lua" <<'LUA'
local ballad = require("ballad")

return ballad.partiture(function(p)
  local mode = p.control.value("mode", p.invocation.args[1], { source = "invocation" })
  local target = p.control.value("target", p.invocation.args[2] or "desktop", { source = "invocation" })
  local settings = p.control.value("settings", { channel = "stable" }, { source = "project" })
  local settings_copy = settings:get()
  settings_copy.channel = "mutated"
  assert(settings:eq({ channel = "stable" }, { name = "stable-settings" }):result(),
    "mutating a fact copy changed control identity")
  local writable = pcall(function() settings.value = { channel = "mutated" } end)
  assert(not writable, "control handles must be immutable")
  local present = mode:present({ name = "mode-present" })
  local release = mode:eq("release", { name = "release-selected" })
  local duplicate_ok, duplicate_error = pcall(function()
    mode:eq("development", { name = "release-selected" })
  end)
  assert(not duplicate_ok and tostring(duplicate_error):find("share one namespace", 1, true),
    "duplicate named predicates must fail contextually")
  local collision_ok, collision_error = pcall(function()
    mode:eq("release", { name = "mode" })
  end)
  assert(not collision_ok and tostring(collision_error):find("control.value", 1, true),
    "values and predicates must share one name namespace")
  local desktop = target:eq("desktop", { name = "desktop-selected" })
  local supported_target = target:one_of({ "desktop", "mobile" }, { name = "supported-target" })
  p.control.all(present, supported_target)
  p.control.any(release, p.control.not_(release, { name = "not-release" }))

  p.control.require("explicit-mode", present, {
    code = "missing_mode",
    subject = "mode",
    message = "A mode is required",
    expected = "release or development",
    actual = p.invocation.args[1],
    hint = "Pass the mode after --",
  })
  p.control.require("supported-target-required", supported_target, {
    code = "unsupported_target",
    subject = "target",
    message = "The selected target is unsupported",
    expected = { "desktop", "mobile" },
    actual = p.invocation.args[2],
  })

  p.control.when(release, function()
    p.control.when(desktop, function()
      local source = p.source.directory("release-input")
      p.sink.directory(source, { out = "dist/release", product = "release" })
    end)
    p.control.unless(desktop, function()
      local source = p.source.directory("release-input")
      p.sink.directory(source, { out = "dist/alternate", product = "alternate" })
    end)
  end)

  p.control.unless(release, function()
    local source = p.source.directory("dev-input")
    p.sink.directory(source, { out = "dist/development", product = "development" })
    local marker = p.task.native({
      id = "development-marker",
      tool = "sh",
      args = { "-c", "printf ran > should-not-run.txt" },
      outputs = { "should-not-run.txt" },
    })
    p.sink.none(p.task.run(marker), { product = "development-action" })
  end)
end)
LUA

cd "$WORK_DIR"
LUA_PATH="$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?.lua;$BALLAD_ROOT/.moonstone/env/share/lua/5.1/?/init.lua;$BALLAD_ROOT/src/?.lua;$BALLAD_ROOT/src/?/init.lua;;"
export LUA_PATH

luajit - <<'LUA'
local testing = require("ballad.testing")
local process = require("ballad.process")
local cache = require("ballad.cache")

local release = testing.load("partiture.lua", { args = { "release", "desktop" } })
local release_plan = release:plan()
release_plan:assert_control("mode", "release")
release_plan:assert_control("release-selected", true)
release_plan:assert_product("release", true)
release_plan:assert_product("alternate", false)
release_plan:assert_product("development", false)
release_plan:assert_product("development-action", false)
local release_fingerprint = process.b3sum_string(release.pipeline:graph():to_json())
local graph_json = release.pipeline:graph():to_json()
assert(graph_json:find('"enabled":false', 1, true), "disabled branch missing from graph")
assert(graph_json:find('"control_conditions"', 1, true), "control provenance missing from graph")

release:execute()
  :assert_success()
  :assert_product("release")
  :assert_path("dist/release/value.txt")
assert(not require("ballad.fs").is_dir("dist/development"), "disabled branch produced output")

local development = testing.load("partiture.lua", { args = { "development" } })
local development_plan = development:plan()
development_plan:assert_control("release-selected", false)
development_plan:assert_product("release", false)
development_plan:assert_product("development", true)
local development_fingerprint = process.b3sum_string(development.pipeline:graph():to_json())
assert(release_fingerprint ~= development_fingerprint, "control value did not affect graph identity")
development:execute()
  :assert_success()
  :assert_product("development")
  :assert_product("development-action")
  :assert_path("should-not-run.txt")
local release_cache = cache.compute_native_key({
  tool = "sh", args = { "-c", "true" }, outputs = {},
  control_conditions = { {
    expression = "supported target", result = true,
    operands = { { kind = "value", name = "target", value = "desktop", source = "invocation" } },
  } },
}, "fixture", "task")
local development_cache = cache.compute_native_key({
  tool = "sh", args = { "-c", "true" }, outputs = {},
  control_conditions = { {
    expression = "supported target", result = true,
    operands = { { kind = "value", name = "target", value = "mobile", source = "invocation" } },
  } },
}, "fixture", "task")
assert(release_cache ~= development_cache, "control fact did not affect native cache identity")

os.remove("should-not-run.txt")
require("ballad.fs").remove_tree("dist/development")

local missing = testing.load("partiture.lua", { args = {} })
missing:execute():assert_failure():assert_diagnostic("missing_mode")
assert(not require("ballad.fs").is_dir("dist/development"), "work ran before a failed requirement")
assert(not require("ballad.fs").is_file("should-not-run.txt"), "native work ran before a failed requirement")
LUA

rm -rf dist
luajit "$BALLAD_ROOT/src/main.lua" play partiture.lua --report report.json -- release desktop >/dev/null
grep -q '"controls"' report.json
grep -q '"name":"mode"' report.json
grep -q '"value":"release"' report.json

echo "PASS: deterministic controls and Ballad testing assertions work"

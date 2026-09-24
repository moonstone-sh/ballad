#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK_DIR=$(mktemp -d /tmp/ballad-pipeline-events.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/test.lua" <<'LUA'
local asset_set = require("ballad.graph").AssetSet
local pipeline = require("ballad.pipeline")
local plugin_host = require("ballad.plugin_host")
local dkjson = require("dkjson")

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error((message or "assertion failed") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function build_pipeline()
  local host = plugin_host.new()
  host:register("test.progress", {
    name = "test.progress",
    version = "1",
    methods = {
      produce = {
        inputs = {}, outputs = { "asset_set" }, role = "source",
        cacheable = true, parallel_safe = true,
      },
    },
    produce = function()
      return asset_set.new()
    end,
  })

  local p = pipeline.new(host)
  local source = p:context():use("test.progress").produce()
  p:context().sink.none(source)
  return p
end

local function run_in_coroutine(p)
  local yields = 0
  local co = coroutine.create(function() return p:execute() end)
  while true do
    local ok, value = coroutine.resume(co)
    assert_equal(ok, true, tostring(value))
    if coroutine.status(co) == "dead" then return yields, value end
    yields = yields + 1
  end
end

local function events_for(p)
  local file = assert(io.open(".ballad/runs/" .. p:context()._run_id .. "/events.ndjson", "r"))
  local events = {}
  for line in file:lines() do
    events[#events + 1] = assert(dkjson.decode(line))
  end
  file:close()
  return events
end

-- Ordinary nodes emit a start/finish pair and checkpoint once per planned
-- node, letting an embedding UI redraw between nodes.
local first = build_pipeline()
assert_equal(coroutine.isyieldable(), false, "test must begin on the main coroutine")
local planned = #first:plan().order
local first_yields = run_in_coroutine(first)
assert_equal(first_yields, planned, "one checkpoint per planned node")
local first_events = events_for(first)
assert_equal(#first_events, planned * 2, "ordinary nodes emit start and finish events")
for index = 1, #first_events, 2 do
  assert_equal(first_events[index].type, "task_started", "event start")
  assert_equal(first_events[index + 1].type, "task_finished", "event finish")
  assert_equal(first_events[index].kind, "node", "event kind")
  assert_equal(first_events[index + 1].id, first_events[index].id, "event node identity")
end

-- The cache-hit branch is also a node boundary: it must emit its explicit
-- skipped event and still checkpoint exactly once instead of starving callers.
local second = build_pipeline()
local second_yields = run_in_coroutine(second)
assert_equal(second_yields, #second:plan().order, "cache-hit nodes still checkpoint")
local second_events = events_for(second)
assert_equal(second_events[1].type, "task_skipped", "cached node emits skipped event")
assert_equal(second_events[1].reason, "cache_hit", "cached node reason")

-- Calling execute normally remains synchronous for Ballad's existing CLI.
local third = build_pipeline()
third:execute()

print("PASS: ordinary pipeline nodes emit events and checkpoint for coroutine consumers")
LUA

cd "$WORK_DIR"
LUA_PATH="$ROOT/src/?.lua;$ROOT/src/?/init.lua;${LUA_PATH:-}" "${LUA_BIN:-luajit}" test.lua

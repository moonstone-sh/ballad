local graph = require("ballad.graph")
local fs = require("ballad.fs")
local path = require("ballad.path")
local process = require("ballad.process")

---@class WatcherPluginContract
local watcher = {
  name = "ballad.plugins.watcher",
  version = "0.1.1",
  methods = {
    watch = {
      inputs = {},
      outputs = { "watch_session" },
      cacheable = false,
      parallel_safe = false,
    },
  },
}

local function shell_quote(value)
  return process.quote(value)
end

local function command_ok(command)
  local ok, _, code = os.execute(command)
  return ok == true or ok == 0 or code == 0
end

local function assert_glob(value, subject)
  if type(value) ~= "string" or value == "" or not value:match("^[%w%._%-%*/%?]+$") then
    error(subject .. " must be a non-empty portable glob")
  end
end

local function watch_root(glob)
  local prefix = glob:match("^([^%*%?]+)") or "."
  prefix = prefix:gsub("/+$", "")
  if prefix == "" then return "." end
  if prefix:find("/") and not prefix:match("/$") and not glob:find("[%*%?]") then return prefix end
  return prefix ~= "" and prefix or "."
end

local function append_unique(values, seen, value)
  if not seen[value] then
    values[#values + 1] = value
    seen[value] = true
  end
end

local function root_pattern(root, pattern)
  root = root or "."
  if root == "." or root == "" then return pattern end
  return root:gsub("/+$", "") .. "/" .. pattern
end

local function portable_patterns(pattern)
  local values = { pattern }
  local simplified = pattern:gsub("%*%*/", "")
  if simplified ~= pattern and simplified ~= "" then values[#values + 1] = simplified end
  return values
end

local function watch_inputs(ctx, watch, subject)
  local inputs, seen = {}, {}
  for _, node_id in ipairs(watch) do
    local node = ctx.graph.nodes[node_id]
    if not node or node.plugin ~= "ballad.core.source" then
      error(subject .. " watch entries must reference Ballad source nodes")
    end
    if node.method == "directory" then
      append_unique(inputs, seen, root_pattern(node.options.path or node.options.root or ".", "**"))
    elseif node.method == "files" then
      local root = node.options.root or "."
      local patterns = type(node.options.patterns) == "table" and node.options.patterns or { node.options.patterns }
      for _, pattern in ipairs(patterns) do
        for _, expanded in ipairs(portable_patterns(pattern)) do
          append_unique(inputs, seen, root_pattern(root, expanded))
        end
      end
    else
      error(subject .. " watch entries must reference directory or files source nodes")
    end
  end
  return inputs
end

local function normalize_reaction(ctx, reaction, index, subject)
  if type(reaction) ~= "table" then error(subject .. " " .. index .. " must be a table") end
  if type(reaction.watch) ~= "table" or #reaction.watch == 0 then
    error(subject .. " " .. index .. " requires a non-empty watch array")
  end
  for _, node_id in ipairs(reaction.watch) do
    if type(node_id) ~= "string" or node_id == "" then
      error(subject .. " " .. index .. " watch entries must be source node ids")
    end
  end
  local effect = reaction.effect or reaction.command
  if type(effect) ~= "string" or effect == "" then
    error(subject .. " " .. index .. " requires an effect command string")
  end
  local inputs = watch_inputs(ctx, reaction.watch, subject .. " " .. index)
  for _, input in ipairs(inputs) do assert_glob(input, subject .. " input") end
  return {
      label = reaction.label or (subject .. "-" .. index),
      inputs = inputs,
      effect = effect,
      watch = reaction.watch,
      outputs = reaction.outputs or {},
  }
end

local function normalize_reactions(ctx, spec)
  if type(spec) ~= "table" or type(spec.reactions) ~= "table" or #spec.reactions == 0 then
    error("watcher.watch requires a non-empty reactions array")
  end

  local reactions = {}
  for index, reaction in ipairs(spec.reactions) do
    reactions[#reactions + 1] = normalize_reaction(ctx, reaction, index, "watcher reaction")
  end
  return reactions
end

local function reaction_snapshot(reaction)
  local roots, seen = {}, {}
  for _, input in ipairs(reaction.inputs) do
    local root = watch_root(input)
    if not seen[root] then roots[#roots + 1], seen[root] = root, true end
  end

  local find_parts = { "find" }
  for _, root in ipairs(roots) do find_parts[#find_parts + 1] = shell_quote(root) end
  find_parts[#find_parts + 1] = "-type f -print 2>/dev/null"
  local cases = table.concat(reaction.inputs, "|")
  return table.concat({
    table.concat(find_parts, " "),
    "| while IFS= read -r file; do",
    "case \"$file\" in " .. cases .. ") ;; *) continue ;; esac;",
    "stat -f '%m %z %N' \"$file\" 2>/dev/null || stat -c '%Y %s %n' \"$file\";",
    "done | LC_ALL=C sort",
  }, " ")
end

local function write_script(node_id, initial, reactions, options)
  local interval = tonumber(options.interval) or 0.5
  local debounce = tonumber(options.debounce) or 0.1
  if interval <= 0 then error("watcher.watch interval must be greater than zero") end
  if debounce < 0 then error("watcher.watch debounce cannot be negative") end

  local state_dir = options.state_dir or ".ballad/watchers"
  fs.mkdir(state_dir)
  local script_path = path.join(state_dir, node_id .. ".sh")
  local cwd_prefix = options.cwd and ("cd " .. shell_quote(options.cwd) .. " && ") or ""
  local cleanup = options.cleanup or ""
  local body = {
    "#!/bin/sh",
    "set -eu",
    "cleaned=0",
    "cleanup() {",
    "  if [ \"$cleaned\" -eq 1 ]; then return; fi",
    "  cleaned=1",
    cleanup ~= "" and ("  " .. cwd_prefix .. "sh -c " .. shell_quote(cleanup) .. " || true") or "  :",
    "}",
    "trap 'cleanup; exit 0' INT TERM HUP",
    "trap cleanup EXIT",
  }

  if initial then
    body[#body + 1] = "run_initial() {"
    body[#body + 1] = "  printf '%s\\n' \"ballad watcher: " .. initial.label .. " (initial)\" >&2"
    body[#body + 1] = "  " .. cwd_prefix .. "BALLAD_WATCH_REASON=initial sh -c " .. shell_quote(initial.effect)
    body[#body + 1] = "}"
    body[#body + 1] = "run_initial"
  end

  for index, reaction in ipairs(reactions) do
    body[#body + 1] = "snapshot_" .. index .. "() { " .. reaction_snapshot(reaction) .. "; }"
    body[#body + 1] = "run_" .. index .. "() {"
    body[#body + 1] = "  reason=$1"
    body[#body + 1] = "  printf '%s\\n' \"ballad watcher: " .. reaction.label .. " ($reason)\" >&2"
    body[#body + 1] = "  " .. cwd_prefix .. "BALLAD_WATCH_REASON=\"$reason\" sh -c " .. shell_quote(reaction.effect)
    body[#body + 1] = "}"
    body[#body + 1] = "last_" .. index .. "=$(snapshot_" .. index .. ")"
  end

  body[#body + 1] = "while :; do"
  body[#body + 1] = "  sleep " .. tostring(interval)
  for index, _ in ipairs(reactions) do
    body[#body + 1] = "  current_" .. index .. "=$(snapshot_" .. index .. ")"
    body[#body + 1] = "  if [ \"$current_" .. index .. "\" != \"$last_" .. index .. "\" ]; then"
    body[#body + 1] = "    sleep " .. tostring(debounce)
    body[#body + 1] = "    last_" .. index .. "=$(snapshot_" .. index .. ")"
    body[#body + 1] = "    run_" .. index .. " change"
    body[#body + 1] = "  fi"
  end
  body[#body + 1] = "done"
  body[#body + 1] = ""

  fs.write_file(script_path, table.concat(body, "\n"))
  fs.chmod(script_path, "+x")
  return script_path
end

---Create and run a supervised watcher session.
---`initial` runs once; `reactions` run only after their own debounced input changes.
---@param ctx PluginCtx
---@param _ AssetSet[]
---@param spec WatcherSpec
---@return AssetSet
function watcher.watch(ctx, _, spec)
  spec = spec or {}
  local reactions = normalize_reactions(ctx, spec)
  local options = spec.options or {}
  local initial = nil
  if spec.initial then
    local effect = spec.initial.effect or spec.initial.command
    if type(effect) ~= "string" or effect == "" then
      ctx.fail("watcher initial requires an effect command string")
    end
    initial = {
      label = spec.initial.label or "watcher initial",
      effect = effect,
      outputs = spec.initial.outputs or {},
    }
  end

  if options.once then
    if initial then
      local cwd_prefix = options.cwd and ("cd " .. shell_quote(options.cwd) .. " && ") or ""
      if not command_ok(cwd_prefix .. "BALLAD_WATCH_REASON=initial sh -c " .. shell_quote(initial.effect)) then
        ctx.fail("watcher initial action failed: " .. initial.label)
      end
    end
    return graph.AssetSet.new({ ctx.graph:add_asset({
      kind = "watch_session",
      generated = true,
      virtual_path = "watcher/" .. ctx.node.id .. ".json",
      metadata = { mode = "once", initial = initial, reactions = reactions },
    }) })
  end

  local script_path = write_script(ctx.node.id, initial, reactions, options)
  if not command_ok("sh " .. shell_quote(script_path)) then
    ctx.fail("watcher exited with an error")
  end
  return graph.AssetSet.new({ ctx.graph:add_asset({
    kind = "watch_session",
    generated = true,
    output_path = script_path,
    virtual_path = "watcher/" .. ctx.node.id .. ".sh",
    metadata = { mode = "daemon", initial = initial, reactions = reactions },
  }) })
end

return watcher

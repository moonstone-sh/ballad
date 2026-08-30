local graph = require("ballad.graph")
local fs = require("ballad.fs")
local path = require("ballad.path")
local process = require("ballad.process")
local native_action = require("ballad.native_action")
local dkjson = require("dkjson")

---@class WatcherPluginContract
local watcher = {
  name = "ballad.plugins.watcher",
  version = "0.1.2",
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

local function normalize_action(spec, subject)
  local before = spec.before
  local effect = spec.effect or spec.command
  local action = spec.run
  if before ~= nil and (type(before) ~= "string" or before == "") then
    error(subject .. " before must be a non-empty command string")
  end
  if effect ~= nil and (type(effect) ~= "string" or effect == "") then
    error(subject .. " effect must be a non-empty command string")
  end
  if action ~= nil and not native_action.is_action(action) then
    error(subject .. " run must be a task.native action")
  end
  if effect == nil and action == nil then
    error(subject .. " requires effect/command or run")
  end
  return before, effect, action
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
  local before, effect, action = normalize_action(reaction, subject .. " " .. index)
  local inputs = watch_inputs(ctx, reaction.watch, subject .. " " .. index)
  for _, input in ipairs(inputs) do assert_glob(input, subject .. " input") end
  return {
      label = reaction.label or (subject .. "-" .. index),
      inputs = inputs,
      before = before,
      effect = effect,
      action = action,
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

local function reason_assignment(reason)
  if reason == "$reason" then return '"$reason"' end
  return shell_quote(reason)
end

local function action_command(action, reason)
  if not action then return nil end
  local runner = os.getenv("BALLAD_ACTION_RUNNER")
  if runner then
    return "BALLAD_WATCH_REASON=" .. reason_assignment(reason) .. " " .. runner .. " " .. shell_quote(action.spec_path)
  end
  return "BALLAD_WATCH_REASON=" .. reason_assignment(reason)
    .. " lua -e " .. shell_quote("require('ballad.native_action').run_file(arg[1])")
    .. " " .. shell_quote(action.spec_path)
end

local function run_command(step, reason, cwd_prefix)
  local commands = {}
  if step.before then
    commands[#commands + 1] = "BALLAD_WATCH_REASON=" .. reason_assignment(reason) .. " sh -c " .. shell_quote(step.before)
  end
  local action = action_command(step.action, reason)
  if action then commands[#commands + 1] = action end
  if step.effect then
    commands[#commands + 1] = "BALLAD_WATCH_REASON=" .. reason_assignment(reason) .. " sh -c " .. shell_quote(step.effect)
  end
  return cwd_prefix .. table.concat(commands, " && ")
end

local function write_action_specs(node_id, initial, reactions, options)
  local state_dir = options.state_dir or ".ballad/watchers"
  local actions_dir = path.join(state_dir, node_id .. "-actions")
  local written = {}
  local function prepare(step)
    if not step or not step.action then return end
    local id = step.action.opts.id
    local spec_path = path.join(actions_dir, id .. ".json")
    if not written[spec_path] then
      native_action.write_file(step.action, spec_path)
      written[spec_path] = true
    end
    step.action = { spec_path = spec_path }
  end
  prepare(initial)
  for _, reaction in ipairs(reactions) do prepare(reaction) end
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
  write_action_specs(node_id, initial, reactions, options)
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
    body[#body + 1] = "  " .. run_command(initial, "initial", cwd_prefix)
    body[#body + 1] = "}"
    body[#body + 1] = "run_initial"
  end

  for index, reaction in ipairs(reactions) do
    body[#body + 1] = "snapshot_" .. index .. "() { " .. reaction_snapshot(reaction) .. "; }"
    body[#body + 1] = "run_" .. index .. "() {"
    body[#body + 1] = "  reason=$1"
    body[#body + 1] = "  printf '%s\\n' \"ballad watcher: " .. reaction.label .. " ($reason)\" >&2"
    body[#body + 1] = "  " .. run_command(reaction, "$reason", cwd_prefix)
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

-- Windows has no safe shell-string boundary in Lua 5.1.  The native helper
-- receives this document as data and is solely responsible for direct argv
-- execution and its watcher lifecycle.  Keep this encoder local and sorted:
-- dkjson intentionally preserves table iteration order for objects, which is
-- not a manifest contract.
local json_array_marker = {}

local function json_array(values)
  return setmetatable(values or {}, json_array_marker)
end

local function json_string(value)
  local escapes = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
  }
  return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
    return escapes[char] or string.format("\\u%04x", string.byte(char))
  end) .. '"'
end

local function canonical_json(value)
  local kind = type(value)
  if kind == "nil" then return "null" end
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "string" then return json_string(value) end
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then error("watcher manifest cannot encode a non-finite number") end
    return dkjson.encode(value)
  end
  if kind ~= "table" then error("watcher manifest cannot encode " .. kind) end

  if getmetatable(value) == json_array_marker then
    local encoded = {}
    for index, child in ipairs(value) do encoded[#encoded + 1] = canonical_json(child) end
    return "[" .. table.concat(encoded, ",") .. "]"
  end

  local keys = {}
  for key, child in pairs(value) do
    if child ~= nil then
      if type(key) ~= "string" then error("watcher manifest object keys must be strings") end
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)
  local encoded = {}
  for _, key in ipairs(keys) do
    encoded[#encoded + 1] = json_string(key) .. ":" .. canonical_json(value[key])
  end
  return "{" .. table.concat(encoded, ",") .. "}"
end

local function string_array(values, subject)
  if values == nil then return json_array({}) end
  if type(values) ~= "table" then error(subject .. " must be an array") end
  local copied = {}
  for index, value in ipairs(values) do
    if type(value) ~= "string" or value == "" then error(subject .. " " .. index .. " must be a non-empty string") end
    copied[#copied + 1] = value
  end
  return json_array(copied)
end

local function windows_action_spec(action, subject)
  if not action then return nil end
  local opts = action:to_table()
  if opts.cmd ~= nil then
    error(subject .. " uses task.native cmd; Windows watchers require tool plus args and will not pass cmd through cmd.exe")
  end
  if opts.toolchain ~= nil then
    error(subject .. " uses task.native toolchain.command; Windows watchers require an explicit toolchain_fingerprint instead of a shell command")
  end
  if type(opts.tool) ~= "string" or opts.tool == "" then
    error(subject .. " requires task.native({ tool = ..., args = ... }) on Windows")
  end
  local argv = { opts.tool }
  for _, argument in ipairs(opts.args or {}) do
    if type(argument) ~= "string" then error(subject .. " task.native args must be strings") end
    argv[#argv + 1] = argument
  end
  if opts.cwd ~= nil and (type(opts.cwd) ~= "string" or opts.cwd == "") then
    error(subject .. " task.native cwd must be a non-empty string")
  end
  local env = {}
  if opts.env ~= nil and type(opts.env) ~= "table" then error(subject .. " task.native env must be a table") end
  for key, value in pairs(opts.env or {}) do
    if type(key) ~= "string" or type(value) ~= "string" then
      error(subject .. " task.native env must map strings to strings")
    end
    env[key] = value
  end
  local result = {
    id = opts.id,
    argv = json_array(argv),
    cwd = opts.cwd or ".",
    env = env,
    inputs = string_array(opts.inputs, subject .. " task.native inputs"),
    outputs = string_array(opts.outputs, subject .. " task.native outputs"),
    cacheable = opts.cacheable ~= false,
  }
  if opts.toolchain_fingerprint ~= nil then
    if type(opts.toolchain_fingerprint) ~= "string" then error(subject .. " task.native toolchain_fingerprint must be a string") end
    result.toolchain_fingerprint = opts.toolchain_fingerprint
  end
  return result, opts.outputs or {}
end

local function append_output_exclusions(exclusions, seen, outputs, subject)
  if outputs == nil then return end
  if type(outputs) ~= "table" then error(subject .. " outputs must be an array") end
  for index, output in ipairs(outputs) do
    if type(output) ~= "string" or output == "" then error(subject .. " output " .. index .. " must be a non-empty string") end
    output = path.normalize(output)
    if not seen[output] then
      exclusions[#exclusions + 1] = output
      seen[output] = true
    end
  end
end

local function windows_legacy_shell_diagnostic(initial, reactions, options)
  local fields = {}
  local function collect(step, subject)
    if not step then return end
    if step.before ~= nil then fields[#fields + 1] = subject .. ".before" end
    if step.effect ~= nil then fields[#fields + 1] = subject .. ".effect" end
  end
  collect(initial, "watcher initial")
  for index, reaction in ipairs(reactions) do collect(reaction, "watcher reaction " .. index) end
  if options.cleanup ~= nil then fields[#fields + 1] = "watcher options.cleanup" end
  if #fields == 0 then return nil end
  return "watcher.watch on Windows does not support legacy raw shell fields (" .. table.concat(fields, ", ")
    .. "); replace them with task.native({ id = ..., tool = ..., args = ... }). Ballad will not pass shell text through cmd.exe."
end

local function configured_moonstone_bin()
  for _, variable in ipairs({ "MOONSTONE_BIN", "MOONSTONE_CLI" }) do
    local value = os.getenv(variable)
    if value and value ~= "" then return value end
  end
  return "moon"
end

local function resolve_windows_helper(ctx)
  local result = process.capture_run({
    tool = configured_moonstone_bin(),
    args = { "provision", "resolve", "ballad-watch", "--json" },
  })
  if result.exit_code ~= 0 then
    ctx.fail("Windows watcher helper is unavailable: `moon provision resolve ballad-watch --json` failed"
      .. (result.stderr ~= "" and ("\n" .. result.stderr) or "")
      .. "\nProvision a Windows `ballad-watch` helper as a Moonstone helper dependency and run `moon sync`. "
      .. "Ballad requires helper protocol ballad:watcher:v1 and does not provision a substitute.")
  end
  local document, _, decode_error = dkjson.decode(result.stdout or "")
  if type(document) ~= "table" or document.contract ~= "moonstone:tool-resolve:v1"
    or type(document.path) ~= "string" or document.path == "" then
    ctx.fail("Windows watcher helper resolution requires Moonstone contract moonstone:tool-resolve:v1; "
      .. "the configured Moonstone is missing or too old"
      .. (decode_error and (": " .. tostring(decode_error)) or "")
      .. ". Upgrade Moonstone, provision `ballad-watch`, and run `moon sync`.")
  end
  return document
end

local function write_windows_manifest(node_id, initial, reactions, options)
  local interval = tonumber(options.interval) or 0.5
  local debounce = tonumber(options.debounce) or 0.1
  if interval <= 0 then error("watcher.watch interval must be greater than zero") end
  if debounce < 0 then error("watcher.watch debounce cannot be negative") end
  if options.cwd ~= nil and (type(options.cwd) ~= "string" or options.cwd == "") then
    error("watcher.watch cwd must be a non-empty string")
  end
  local state_dir = options.state_dir or ".ballad/watchers"
  if type(state_dir) ~= "string" or state_dir == "" then error("watcher.watch state_dir must be a non-empty string") end

  local exclusions, excluded = {}, {}
  local function manifest_step(step, subject, include_inputs)
    if not step then return nil end
    local action, action_outputs = windows_action_spec(step.action, subject)
    append_output_exclusions(exclusions, excluded, step.outputs, subject)
    append_output_exclusions(exclusions, excluded, action_outputs, subject .. " task.native")
    local document = {
      label = step.label,
      outputs = string_array(step.outputs, subject .. " outputs"),
      action = action,
    }
    if include_inputs then
      document.source_nodes = string_array(step.watch, subject .. " source nodes")
      document.inputs = string_array(step.inputs, subject .. " inputs")
    end
    return document
  end

  local manifest = {
    contract = "ballad:watcher:v1",
    node = node_id,
    mode = options.once and "once" or "daemon",
    cwd = options.cwd or ".",
    interval = interval,
    debounce = debounce,
    initial = manifest_step(initial, "watcher initial", false),
    reactions = json_array({}),
    output_exclusions = json_array(exclusions),
  }
  for index, reaction in ipairs(reactions) do
    manifest.reactions[#manifest.reactions + 1] = manifest_step(reaction, "watcher reaction " .. index, true)
  end

  fs.mkdir(state_dir)
  local manifest_path = path.join(state_dir, node_id .. ".windows.json")
  fs.write_file(manifest_path, canonical_json(manifest) .. "\n")
  return manifest_path, manifest
end

local function run_windows_helper(ctx, manifest_path, mode)
  local helper = resolve_windows_helper(ctx)
  local result = process.capture_run({
    tool = helper.path,
    args = { "--manifest", path.absolute(manifest_path) },
  })
  if result.exit_code ~= 0 then
    ctx.fail("Windows watcher helper failed (the resolved helper is missing or too old): " .. helper.path
      .. "\nBallad requires helper protocol ballad:watcher:v1 (`ballad-watch --manifest <absolute-manifest>`)."
      .. (result.stderr ~= "" and ("\n" .. result.stderr) or ""))
  end
  local response, _, decode_error = dkjson.decode(result.stdout or "")
  local expected_status = mode == "once" and "completed" or "stopped"
  if type(response) ~= "table" or response.contract ~= "ballad:watcher-result:v1"
    or response.status ~= expected_status or response.mode ~= mode then
    ctx.fail("Windows watcher helper is missing or too old: it did not return the required "
      .. "ballad:watcher-result:v1 response for " .. mode
      .. (decode_error and (" (" .. tostring(decode_error) .. ")") or "")
      .. ". Provision a compatible `ballad-watch` helper and run `moon sync`.")
  end
  return helper
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
    local before, effect, action = normalize_action(spec.initial, "watcher initial")
    initial = {
      label = spec.initial.label or "watcher initial",
      before = before,
      effect = effect,
      action = action,
      outputs = spec.initial.outputs or {},
    }
  end

  local control_conditions = ctx.node.control_conditions or {}
  local function bind_controls(step)
    if not step or not step.action or #control_conditions == 0 then return end
    local action_opts = step.action:to_table()
    action_opts.control_conditions = control_conditions
    step.action = native_action.new(action_opts)
  end
  bind_controls(initial)
  for _, reaction in ipairs(reactions) do bind_controls(reaction) end

  if process.is_windows() then
    local shell_diagnostic = windows_legacy_shell_diagnostic(initial, reactions, options)
    if shell_diagnostic then ctx.fail(shell_diagnostic) end
    local manifest_path = write_windows_manifest(ctx.node.id, initial, reactions, options)
    local mode = options.once and "once" or "daemon"
    local helper = run_windows_helper(ctx, manifest_path, mode)
    return graph.AssetSet.new({ ctx.graph:add_asset({
      kind = "watch_session",
      generated = true,
      output_path = manifest_path,
      virtual_path = "watcher/" .. ctx.node.id .. ".windows.json",
      metadata = {
        mode = mode,
        manifest = manifest_path,
        helper = {
          path = helper.path,
          version = helper.version,
          digest = helper.digest,
          source = helper.source,
        },
        initial = initial,
        reactions = reactions,
      },
    }) })
  end

  if options.once then
    if initial then
      local cwd_prefix = options.cwd and ("cd " .. shell_quote(options.cwd) .. " && ") or ""
      if initial.before and not command_ok(cwd_prefix .. "BALLAD_WATCH_REASON=initial sh -c " .. shell_quote(initial.before)) then
        ctx.fail("watcher initial pre-build action failed: " .. initial.label)
      end
      if initial.action then native_action.run(initial.action) end
      if initial.effect and not command_ok(cwd_prefix .. "BALLAD_WATCH_REASON=initial sh -c " .. shell_quote(initial.effect)) then
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

---@meta

local pipeline = {}
local graph_mod = require("ballad.graph")
local plugin_host = require("ballad.plugin_host")

---@class NodeHandle
---@field _id? string
---@field _graph? Graph
---@field [string] any eagerly-read metadata from _prepare hooks
local NodeHandle = {}
NodeHandle.__index = NodeHandle

function NodeHandle.new(id, graph, extra_meta)
  local self = setmetatable({ _id = id, _graph = graph }, NodeHandle)
  if extra_meta then
    for k, v in pairs(extra_meta) do
      self[k] = v
    end
  end
  return self
end

function NodeHandle:id()
  return self._id
end

function NodeHandle:metadata()
  local node = self._graph.nodes[self._id]
  return node and node.metadata or nil
end

---@class PluginProxy
---@field _name? string
---@field _graph? Graph
---@field _host? Host
---@field _ctx? PipelineContext
---@field [string] fun(...): NodeHandle
local PluginProxy = {}
PluginProxy.__index = PluginProxy

function PluginProxy.new(name, graph, host, pipeline_ctx, contract)
  local self = setmetatable({ _name = name, _graph = graph, _host = host, _ctx = pipeline_ctx }, PluginProxy)
  contract = contract or host:contract(name)
  if not contract then
    error("Plugin '" .. name .. "' has no contract")
  end
  for method_name, method_contract in pairs(contract.methods or {}) do
    self[method_name] = function(...)
      local args = {...}
      if args[1] == self then
        table.remove(args, 1)
      end
      local inputs = {}
      local options = {}
      if #args >= 2 then
        local first = table.remove(args, 1)
        if type(first) == "table" and getmetatable(first) == NodeHandle then
          table.insert(inputs, first._id)
          if type(args[1]) == "table" then
            options = args[1]
          end
        elseif type(first) == "string" then
          options[1] = first
          if type(args[1]) == "table" then
            for k, v in pairs(args[1]) do
              options[k] = v
            end
          end
        else
          table.insert(inputs, first)
          if type(args[1]) == "table" then
            options = args[1]
          end
        end
      elseif #args == 1 then
        local first = args[1]
        if type(first) == "table" and getmetatable(first) == NodeHandle then
          table.insert(inputs, first._id)
        elseif type(first) == "string" then
          options[1] = first
        elseif type(first) == "table" then
          options = first
        end
      end
      local node_options = {}
      for key, value in pairs(options) do
        if key ~= "depends_on" then node_options[key] = value end
      end
      if name == "ballad.plugins.watcher" and method_name == "watch" then
        node_options.reactions = {}
        for index, reaction in ipairs(options.reactions or {}) do
          local reaction_options = {}
          for key, value in pairs(reaction) do reaction_options[key] = value end
          reaction_options.depends_on = {}
          for _, target in ipairs(reaction.depends_on or {}) do
            if getmetatable(target) ~= NodeHandle then
              error("watcher reaction depends_on entries must be pipeline node handles")
            end
            table.insert(reaction_options.depends_on, target._id)
          end
          node_options.reactions[index] = reaction_options
        end
        if options.initial then
          local initial_options = {}
          for key, value in pairs(options.initial) do initial_options[key] = value end
          initial_options.depends_on = {}
          for _, target in ipairs(options.initial.depends_on or {}) do
            if getmetatable(target) ~= NodeHandle then
              error("watcher initial depends_on entries must be pipeline node handles")
            end
            table.insert(initial_options.depends_on, target._id)
          end
          node_options.initial = initial_options
        end
      end
      local node = graph:add_node({
        plugin = name,
        method = method_name,
        role = method_contract.role or "transform",
        label = method_contract.label,
        inputs = inputs,
        options = node_options,
        effects = method_contract.effects or {},
        progress_weight = method_contract.progress_weight,
        cacheable = method_contract.cacheable,
        parallel_safe = method_contract.parallel_safe,
        enabled = options.enabled,
      })
      local dependencies = options.depends_on
      if dependencies then
        local handles = getmetatable(dependencies) == NodeHandle and { dependencies } or dependencies
        if type(handles) ~= "table" then
          error("depends_on must be a pipeline node handle or an array of node handles")
        end
        for _, handle in ipairs(handles) do
          if getmetatable(handle) ~= NodeHandle then
            error("depends_on entries must be pipeline node handles")
          end
          table.insert(node.inputs, handle._id)
          graph.edges[handle._id] = graph.edges[handle._id] or {}
          table.insert(graph.edges[handle._id], node.id)
        end
      end
      if name == "ballad.plugins.watcher" and method_name == "watch" then
        local watcher_dependencies = {}
        if options.initial then table.insert(watcher_dependencies, options.initial) end
        for _, reaction in ipairs(options.reactions or {}) do table.insert(watcher_dependencies, reaction) end
        for _, reaction in ipairs(watcher_dependencies) do
          for _, handle in ipairs(reaction.depends_on or {}) do
            if getmetatable(handle) ~= NodeHandle then
              error("watcher reaction depends_on entries must be pipeline node handles")
            end
            local present = false
            for _, input_id in ipairs(node.inputs) do
              if input_id == handle._id then present = true; break end
            end
            if not present then
              table.insert(node.inputs, handle._id)
              graph.edges[handle._id] = graph.edges[handle._id] or {}
              table.insert(graph.edges[handle._id], node.id)
            end
          end
        end
      end
      local extra_meta = nil
      local prepare_fn = contract[method_name .. "_prepare"]
      if prepare_fn then
        local ok, meta = pcall(prepare_fn, options)
        if ok then
          extra_meta = meta
        else
          error("Plugin '" .. name .. "' " .. method_name .. "_prepare failed: " .. tostring(meta))
        end
      end
      return NodeHandle.new(node.id, graph, extra_meta)
    end
  end
  if name == "moonstone" or name == "ballad.plugins.moonstone" then
    self.registry = {
      package = function(...)
        return self:registry_package(...)
      end,
      source_package = function(...)
        return self:registry_source_package(...)
      end,
      runtime = function(...)
        return self:registry_runtime(...)
      end,
      external = function(...)
        return self:registry_external(...)
      end,
    }
  end
  return self
end

---@class PipelineContext
---@field _graph Graph
---@field _host Host
---@field _plugins table<string, PluginProxy>
---@field _metadata table<string, any>
---@field _warnings string[]
---@field _assets table<string, Asset>
local PipelineContext = {}
PipelineContext.__index = PipelineContext

local function native_assets_from_cache(graph, entry)
  local assets = graph_mod.AssetSet.new()
  for _, asset_info in ipairs(entry.assets or {}) do
    assets:add(graph:add_asset({
      kind = asset_info.kind,
      source_path = asset_info.source_path,
      virtual_path = asset_info.virtual_path,
      output_path = asset_info.output_path,
      content = asset_info.content,
      generated = asset_info.generated,
      metadata = asset_info.metadata,
    }))
  end
  return assets
end

local function path_lists_overlap(left, right)
  for _, a in ipairs(left or {}) do
    for _, b in ipairs(right or {}) do
      if a == b then return true end
    end
  end
  return false
end

function PipelineContext.new(graph, host, jobs)
  local self = setmetatable({
    _graph = graph,
    _host = host,
    _plugins = {},
    _metadata = {},
    _warnings = {},
    _assets = {},
    _run_id = os.date("%Y%m%d-%H%M%S"),
    _jobs = jobs or 1,
    _pending_tasks = {},
  }, PipelineContext)
  self.source = {}
  self.sink = {}
  self.source.directory = function(dir_path, opts)
    return self:_core_node("ballad.core.source", "directory", {}, opts or { path = dir_path }, function(o) o.path = o.path or dir_path end)
  end
  self.source.files = function(patterns, opts)
    opts = opts or {}
    opts.patterns = patterns
    return self:_core_node("ballad.core.source", "files", {}, opts)
  end
  self.source.stdin = function(opts)
    return self:_core_node("ballad.core.source", "stdin", {}, opts or {})
  end
  self.sink.directory = function(input, opts)
    return self:_core_node("ballad.core.sink", "directory", { input }, opts or {})
  end
  self.sink.stdout = function(input, opts)
    return self:_core_node("ballad.core.sink", "stdout", { input }, opts or {})
  end
  self.sink.file_graph = function(input, opts)
    return self:_core_node("ballad.core.sink", "file_graph", { input }, opts or {})
  end
  self.sink.artifact = function(input, opts)
    return self:_core_node("ballad.core.sink", "artifact", { input }, opts or {})
  end
  ---Terminal sink for tasks that do not produce output directories or artifacts.
  ---Accepts 0, 1, or 2 arguments: p.sink.none(), p.sink.none(input), p.sink.none(opts), or p.sink.none(input, opts).
  ---@param input? NodeHandle|table optional pipeline node handle or options table
  ---@param opts? table optional sink options
  ---@return NodeHandle
  self.sink.none = function(input, opts)
    if type(input) == "table" and getmetatable(input) ~= NodeHandle then
      opts = input
      input = nil
    end
    local inputs = input and { input } or {}
    return self:_core_node("ballad.core.sink", "none", inputs, opts or {})
  end
  return self
end

function PipelineContext:_core_node(plugin, method, inputs, opts, mutate_opts)
  opts = opts or {}
  if mutate_opts then mutate_opts(opts) end
  local input_ids = {}
  for _, inp in ipairs(inputs or {}) do
    if type(inp) == "table" and getmetatable(inp) == NodeHandle then
      table.insert(input_ids, inp._id)
    elseif inp ~= nil then
      error(method .. " expects pipeline node handles as inputs")
    end
  end
  local role = plugin == "ballad.core.source" and "source" or "sink"
  local node = self._graph:add_node({
    plugin = plugin,
    method = method,
    role = role,
    label = opts.label or method,
    inputs = input_ids,
    options = opts,
    effects = role == "sink" and { "write" } or { "read" },
    progress_weight = opts.progress_weight or 1,
    cacheable = false,
    parallel_safe = method ~= "stdout",
    enabled = opts.enabled,
  })
  return NodeHandle.new(node.id, self._graph)
end

---Import a plugin. Prefer `ballad.plugins.*`; string literal overloads are provided
---for existing partituras such as `p:use("moonstone")`.
---@overload fun(self: PipelineContext, plugin_ref: MoonstonePluginContract): MoonstonePlugin
---@overload fun(self: PipelineContext, plugin_ref: LayoutPluginContract): LayoutPlugin
---@overload fun(self: PipelineContext, plugin_ref: LovePluginContract): LovePlugin
---@overload fun(self: PipelineContext, plugin_ref: RegistryPluginContract): RegistryPlugin
---@overload fun(self: PipelineContext, plugin_ref: NvimPluginContract): NvimPlugin
---@overload fun(self: PipelineContext, plugin_ref: RuntimePluginContract): RuntimePlugin
---@overload fun(self: PipelineContext, plugin_ref: WatcherPluginContract): WatcherPlugin
---@overload fun(self: PipelineContext, plugin_ref: LuaPluginContract): LuaPlugin
---@overload fun(self: PipelineContext, plugin_ref: MoonstoneInputPluginContract): MoonstoneInputPlugin
---@overload fun(self: PipelineContext, plugin_ref: 'moonstone'|'ballad.plugins.moonstone'): MoonstonePlugin
---@overload fun(self: PipelineContext, plugin_ref: 'layout'|'ballad.plugins.layout'): LayoutPlugin
---@overload fun(self: PipelineContext, plugin_ref: 'love'|'ballad.plugins.love'): LovePlugin
---@overload fun(self: PipelineContext, plugin_ref: 'registry'|'ballad.plugins.registry'): RegistryPlugin
---@overload fun(self: PipelineContext, plugin_ref: 'nvim'|'ballad.plugins.nvim'): NvimPlugin
---@overload fun(self: PipelineContext, plugin_ref: 'runtime'|'ballad.plugins.runtime'): RuntimePlugin
---@overload fun(self: PipelineContext, plugin_ref: 'watcher'|'ballad.plugins.watcher'): WatcherPlugin
---@overload fun(self: PipelineContext, plugin_ref: 'lua'|'ballad.plugins.lua'): LuaPlugin
---@overload fun(self: PipelineContext, plugin_ref: 'input.moonstone'|'ballad.plugins.input.moonstone'): MoonstoneInputPlugin
---@param plugin_ref string|PluginContract
---@return PluginProxy
function PipelineContext:use(plugin_ref)
  if plugin_ref == "emit" or plugin_ref == "ballad.plugins.emit" then
    error("emit plugin removed; use p.sink.*")
  end
  if type(plugin_ref) == "table" and plugin_ref.name == "ballad.plugins.emit" then
    error("emit plugin removed; use p.sink.*")
  end
  local plugin_name, contract = self._host:resolve(plugin_ref)
  if not self._plugins[plugin_name] then
    self._plugins[plugin_name] = PluginProxy.new(plugin_name, self._graph, self._host, self, contract)
  end
  return self._plugins[plugin_name]
end

---@param pattern_or_patterns string|string[]
---@return AssetSet
function PipelineContext:files(pattern_or_patterns)
  local patterns = type(pattern_or_patterns) == "table" and pattern_or_patterns or { pattern_or_patterns }
  local fs = require("ballad.fs")
  local assets = graph_mod.AssetSet.new()
  for _, pat in ipairs(patterns) do
    for _, f in ipairs(fs.list_files(".")) do
      if f:match(pat) then
        local asset = self._graph:add_asset({
          kind = "file",
          source_path = f,
          virtual_path = f,
        })
        assets:add(asset)
      end
    end
  end
  return assets
end

---@param path string
---@param opts? table
---@return Asset
function PipelineContext:asset(path, opts)
  opts = opts or {}
  return self._graph:add_asset({
    kind = opts.kind or "file",
    source_path = path,
    virtual_path = opts.virtual_path or path,
    output_path = opts.output_path,
    metadata = opts.metadata,
  })
end

---@param path string
---@param content string
---@param opts? table
---@return Asset
function PipelineContext:generated(path, content, opts)
  opts = opts or {}
  return self._graph:add_asset({
    kind = opts.kind or "generated",
    virtual_path = path,
    output_path = opts.output_path or path,
    content = content,
    generated = true,
    metadata = opts.metadata,
  })
end

function PipelineContext:node(plugin, method, inputs, opts)
  opts = opts or {}
  local input_ids = {}
  for _, inp in ipairs(inputs or {}) do
    if type(inp) == "table" and getmetatable(inp) == NodeHandle then
      table.insert(input_ids, inp._id)
    end
  end
  local node = self._graph:add_node({
    plugin = plugin,
    method = method,
    inputs = input_ids,
    options = opts,
  })
  return NodeHandle.new(node.id, self._graph)
end

---@param key string
---@param value any
function PipelineContext:metadata(key, value)
  self._metadata[key] = value
  self._graph.metadata[key] = value
end

---@param message string
function PipelineContext:warn(message)
  table.insert(self._warnings, message)
  print("Warning: " .. message)
end

---@param message string
---@return never
function PipelineContext:fail(message)
  error("Pipeline failed: " .. message)
end

---Normalize a tool path: absolute paths pass through, relative names are resolved via PATH.
---@param tool string
---@return string|nil normalized path or nil if not found
local function resolve_tool(tool)
  if tool:sub(1, 1) == "/" or tool:sub(1, 2) == "./" then
    return tool
  end
  if tool:find(":") then
    error(
      "Moonstone-provisioned native helpers are not implemented yet.\n" ..
      "Tool: " .. tool .. "\n" ..
      "Use a system tool name or absolute path for now."
    )
  end
  -- Try which
  local pipe = io.popen("command -v " .. require("ballad.process").quote(tool) .. " 2>/dev/null")
  if pipe then
    local resolved = pipe:read("*l")
    pipe:close()
    if resolved and resolved ~= "" then
      return resolved
    end
  end
  return nil
end

---@class NativeTaskOpts
---@field tool? string executable tool name or path (e.g. "zip", "moonc", "gcc")
---@field cmd? string raw multi-segment command string (e.g. "moon run build" or "moonc -t dist src/")
---@field args? string[] arguments list (when cmd is not used)
---@field inputs? string[]|AssetSet[] input files, directory paths, glob patterns (e.g. "src/*.moon"), or asset sets to track for cache invalidation
---@field outputs? string[] output file or directory paths produced by the task
---@field cwd? string working directory for process execution (defaults to ".")
---@field env? table<string, string> environment variables for process execution
---@field cacheable? boolean whether task output can be cached (defaults to true)
---@field parallel_safe? boolean whether task can run in parallel with non-overlapping tasks (defaults to true)
---@field description? string human-readable description for progress reports and events

---Execute a native tool or command line subprocess.
---@param opts NativeTaskOpts options table defining tool/cmd, args, inputs, outputs, cwd, env, and caching
---@return AssetSet asset set representing produced outputs
function PipelineContext:native_task(opts)
  opts = opts or {}
  local tool = opts.tool or (opts.cmd and opts.cmd:match("^%S+")) or error("native_task: missing required field 'tool' or 'cmd'")
  local args = opts.args or {}
  local cmd_opt = opts.cmd
  local outputs = opts.outputs or {}
  local inputs = opts.inputs or {}
  local cwd = opts.cwd or "."
  local env = opts.env or {}
  local cacheable = opts.cacheable ~= false
  local parallel_safe = opts.parallel_safe ~= false
  local description = opts.description or cmd_opt or (tool .. " " .. table.concat(args, " "))

  local cache = require("ballad.cache")
  local cache_key = nil
  if cacheable then
    cache_key = cache.compute_native_key(opts, self._metadata._current_plugin, self._metadata._current_method)
    local entry = cache.read(cache_key)
    if entry and cache.outputs_valid(entry) then
      print("Cache hit: native task (" .. description .. ")")
      return native_assets_from_cache(self._graph, entry)
    end
  end

  -- Deferred parallel execution
  if self._jobs > 1 and parallel_safe then
    return self:_native_task_deferred(opts, cache_key)
  end

  -- Resolve tool
  local resolved_tool = resolve_tool(tool)
  if not resolved_tool then
    local task_id = self._graph:add_native_task({
      kind = "native",
      plugin = self._metadata._current_plugin or "unknown",
      method = self._metadata._current_method or "unknown",
      tool = tool,
      args = args,
      cwd = cwd,
      env = env,
      inputs = inputs,
      outputs = outputs,
      cacheable = cacheable,
      parallel_safe = parallel_safe,
      description = description,
      status = "failed",
      exit_code = nil,
      stderr = "tool not found: " .. tool,
      missing_outputs = {},
    })
    local run_id = self._run_id or os.date("%Y%m%d-%H%M%S")
    local events_file = ".ballad/runs/" .. run_id .. "/events.ndjson"
    local event_dir = require("ballad.path").dirname(events_file)
    local fs = require("ballad.fs")
    if not fs.is_dir(event_dir) then fs.mkdir(event_dir) end
    local file = io.open(events_file, "a")
    if file then
      file:write(require("dkjson").encode({
        type = "task_failed",
        kind = "native",
        id = task_id,
        stderr = "tool not found: " .. tool,
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      }) .. "\n")
      file:close()
    end
    error(
      "Native task failed: tool not found: " .. tool .. "\n\n" ..
      "Task: " .. (opts.id or description) .. "\n" ..
      "Hint: Install the helper or configure the plugin to use a different tool."
    )
  end

  -- Ensure cwd exists
  local fs = require("ballad.fs")
  local path = require("ballad.path")
  if not fs.is_dir(cwd) then
    error("Native task failed: cwd does not exist: " .. cwd)
  end

  -- Ensure output parent directories exist
  for _, out in ipairs(outputs) do
    local parent = path.dirname(out)
    if parent ~= "." and parent ~= "" then
      fs.mkdir(parent)
    end
  end

  -- Build command
  local cmd
  if cmd_opt then
    local first_token = cmd_opt:match("^%S+")
    if first_token and (first_token == tool or first_token == require("ballad.process").quote(tool) or first_token == resolved_tool or first_token == require("ballad.process").quote(resolved_tool)) then
      cmd = require("ballad.process").quote(resolved_tool) .. cmd_opt:sub(#first_token + 1)
    else
      cmd = require("ballad.process").quote(resolved_tool) .. " " .. cmd_opt
    end
  else
    local cmd_parts = { resolved_tool }
    for _, a in ipairs(args) do
      table.insert(cmd_parts, require("ballad.process").quote(a))
    end
    cmd = table.concat(cmd_parts, " ")
  end

  -- Build env prefix if needed
  local env_prefix = ""
  for k, v in pairs(env) do
    env_prefix = env_prefix .. k .. "=" .. require("ballad.process").quote(v) .. " "
  end
  if env_prefix ~= "" then
    cmd = env_prefix .. cmd
  end

  -- Capture stdout/stderr via temp files for reliability
  local tmp_stdout = os.tmpname()
  local tmp_stderr = os.tmpname()
  local full_cmd = string.format("cd %s && %s > %s 2> %s", require("ballad.process").quote(cwd), cmd, tmp_stdout, tmp_stderr)

  -- Run
  local status = os.execute(full_cmd)
  local exit_code = 0
  local ok = false
  if type(status) == "number" then
    exit_code = status
    ok = (status == 0)
  elseif status == true then
    ok = true
    exit_code = 0
  elseif status == nil then
    ok = false
    exit_code = 1
  end

  -- Read stdout/stderr
  local stdout_text = ""
  local stderr_text = ""
  local out_f = io.open(tmp_stdout, "r")
  if out_f then
    stdout_text = out_f:read("*a") or ""
    out_f:close()
  end
  local err_f = io.open(tmp_stderr, "r")
  if err_f then
    stderr_text = err_f:read("*a") or ""
    err_f:close()
  end
  os.remove(tmp_stdout)
  os.remove(tmp_stderr)

  -- Verify outputs
  local missing_outputs = {}
  if ok then
    for _, out in ipairs(outputs) do
      if not fs.read_file(out) and not fs.is_dir(out) then
        table.insert(missing_outputs, out)
      end
    end
  end

  -- Record task in graph
  local task = {
    kind = "native",
    plugin = self._metadata._current_plugin or "unknown",
    method = self._metadata._current_method or "unknown",
    tool = tool,
    resolved_tool = resolved_tool,
    args = args,
    cwd = cwd,
    env = env,
    inputs = inputs,
    outputs = outputs,
    cacheable = cacheable,
    parallel_safe = parallel_safe,
    description = description,
    status = ok and (#missing_outputs == 0 and "success" or "incomplete") or "failed",
    exit_code = exit_code,
    stdout = stdout_text,
    stderr = stderr_text,
    missing_outputs = missing_outputs,
  }
  local task_id = self._graph:add_native_task(task)

  -- Write event
  local run_id = self._run_id or os.date("%Y%m%d-%H%M%S")
  local events_file = ".ballad/runs/" .. run_id .. "/events.ndjson"
  local event_dir = path.dirname(events_file)
  if not fs.is_dir(event_dir) then
    fs.mkdir(event_dir)
  end
  local f = io.open(events_file, "a")
  if f then
    local dkjson = require("dkjson")
    f:write(dkjson.encode({
      type = "task_started",
      kind = "native",
      id = task_id,
      tool = tool,
      timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }) .. "\n")
    f:write(dkjson.encode({
      type = ok and (#missing_outputs == 0 and "task_finished" or "task_incomplete") or "task_failed",
      kind = "native",
      id = task_id,
      exit_code = exit_code,
      stderr = stderr_text ~= "" and stderr_text or nil,
      missing_outputs = #missing_outputs > 0 and missing_outputs or nil,
      timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }) .. "\n")
    f:close()
  end

  -- Fail if needed
  if not ok then
    error(
      "Native task failed: " .. (opts.id or description) .. "\n\n" ..
      "Tool:\n  " .. tool .. "\n\n" ..
      "Command:\n  " .. cmd .. "\n\n" ..
      "Cwd:\n  " .. cwd .. "\n\n" ..
      "Exit code:\n  " .. tostring(exit_code) .. "\n\n" ..
      (stderr_text ~= "" and ("Stderr:\n  " .. stderr_text .. "\n\n") or "") ..
      "Declared outputs:\n  " .. table.concat(outputs, "\n  ")
    )
  end

  if #missing_outputs > 0 then
    error(
      "Native task completed but did not produce declared output:\n\n" ..
      "Task:\n  " .. (opts.id or description) .. "\n\n" ..
      "Missing outputs:\n  " .. table.concat(missing_outputs, "\n  ")
    )
  end

  -- Return AssetSet with generated assets for outputs
  local assets = graph_mod.AssetSet.new()
  for _, out in ipairs(outputs) do
    local asset = self._graph:add_asset({
      kind = "generated",
      virtual_path = out,
      output_path = out,
      generated = true,
      metadata = {
        plugin = self._metadata._current_plugin,
        method = self._metadata._current_method,
        native_task_id = task_id,
      },
    })
    assets:add(asset)
  end

  if cacheable and cache_key then
    cache.store(cache_key, assets, outputs)
  end

  return assets
end

function PipelineContext:_native_task_deferred(opts, cache_key)
  local native_runner = require("ballad.native_runner")
  local path = require("ballad.path")
  local fs = require("ballad.fs")
  local dkjson = require("dkjson")

  local tool = opts.tool or (opts.cmd and opts.cmd:match("^%S+")) or error("native_task: missing tool or cmd")
  local outputs = opts.outputs or {}
  local inputs = opts.inputs or {}

  for _, pending in ipairs(self._pending_tasks) do
    local pending_outputs = pending.opts.outputs or {}
    if path_lists_overlap(outputs, pending_outputs) or path_lists_overlap(inputs, pending_outputs) or path_lists_overlap(pending.opts.inputs or {}, outputs) then
      self:_flush_pending_tasks()
      break
    end
  end

  -- Validate tool exists before deferring
  local resolved_tool = native_runner.find_tool(tool)
  if not resolved_tool then
    error(
      "Native task failed: tool not found: " .. tool .. "\n\n" ..
      "Task: " .. (opts.id or opts.description or "native task") .. "\n" ..
      "Hint: Install the helper or configure the plugin to use a different tool."
    )
  end

  local stdout_file = os.tmpname()
  local stderr_file = os.tmpname()
  local exit_file = os.tmpname()
  os.remove(exit_file)

  local cwd = opts.cwd or "."
  if not fs.is_dir(cwd) then
    error("Native task failed: cwd does not exist: " .. cwd)
  end
  for _, out in ipairs(outputs) do
    local parent = path.dirname(out)
    if parent ~= "." and parent ~= "" then
      fs.mkdir(parent)
    end
  end

  -- Record pending task in graph
  local task = {
    kind = "native",
    plugin = self._metadata._current_plugin or "unknown",
    method = self._metadata._current_method or "unknown",
    tool = tool,
    resolved_tool = resolved_tool,
    args = opts.args,
    cwd = cwd,
    env = opts.env or {},
    inputs = opts.inputs or {},
    outputs = outputs,
    cacheable = opts.cacheable ~= false,
    parallel_safe = true,
    description = opts.description or (tool .. " " .. table.concat(opts.args or {}, " ")),
    status = "pending",
  }
  local task_id = self._graph:add_native_task(task)

  -- Write task_started event
  local run_id = self._run_id or os.date("%Y%m%d-%H%M%S")
  local events_file = ".ballad/runs/" .. run_id .. "/events.ndjson"
  local event_dir = path.dirname(events_file)
  if not fs.is_dir(event_dir) then
    fs.mkdir(event_dir)
  end
  local f = io.open(events_file, "a")
  if f then
    f:write(dkjson.encode({
      type = "task_started",
      kind = "native",
      id = task_id,
      tool = tool,
      worker = 1,
      timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }) .. "\n")
    f:close()
  end

  local assets = graph_mod.AssetSet.new()
  for _, out in ipairs(outputs) do
    local asset = self._graph:add_asset({
      kind = "generated",
      virtual_path = out,
      output_path = out,
      generated = true,
      metadata = {
        plugin = self._metadata._current_plugin,
        method = self._metadata._current_method,
        native_task_id = task_id,
        pending = true,
      },
    })
    assets:add(asset)
  end

  local spawned, spawn_err = native_runner.spawn_background(opts, stdout_file, stderr_file, exit_file)
  if not spawned then
    error("Native task failed to start: " .. tostring(spawn_err))
  end

  table.insert(self._pending_tasks, {
    opts = opts,
    task_id = task_id,
    stdout_file = stdout_file,
    stderr_file = stderr_file,
    exit_file = exit_file,
    assets = assets,
    cache_key = cache_key,
  })

  return assets
end

function PipelineContext:_flush_pending_tasks()
  if #self._pending_tasks == 0 then return end

  local native_runner = require("ballad.native_runner")
  local path = require("ballad.path")
  local fs = require("ballad.fs")
  local dkjson = require("dkjson")
  local cache = require("ballad.cache")
  local run_id = self._run_id or os.date("%Y%m%d-%H%M%S")
  local events_file = ".ballad/runs/" .. run_id .. "/events.ndjson"

  local pending = {}
  for _, t in ipairs(self._pending_tasks) do
    table.insert(pending, t)
  end
  self._pending_tasks = {}

  -- Poll until all tasks complete
  while #pending > 0 do
    for i = #pending, 1, -1 do
      local task = pending[i]
      local result = native_runner.poll_background(task.stdout_file, task.stderr_file, task.exit_file)
      if result then
        -- Update graph task status
        for _, nt in ipairs(self._graph.native_tasks) do
          if nt.id == task.task_id then
            local missing_outputs = {}
            if result.exit_code == 0 then
              for _, out in ipairs(task.opts.outputs) do
                if not fs.read_file(out) and not fs.is_dir(out) then
                  table.insert(missing_outputs, out)
                end
              end
            end
            nt.status = (result.exit_code == 0 and #missing_outputs == 0) and "success" or "failed"
            nt.exit_code = result.exit_code
            nt.stdout = result.stdout
            nt.stderr = result.stderr
            nt.missing_outputs = missing_outputs
            break
          end
        end

        -- Write event
        local f = io.open(events_file, "a")
        if f then
          f:write(dkjson.encode({
            type = (result.exit_code == 0) and "task_finished" or "task_failed",
            kind = "native",
            id = task.task_id,
            exit_code = result.exit_code,
            stderr = result.stderr ~= "" and result.stderr or nil,
            worker = 1,
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
          }) .. "\n")
          f:close()
        end

        -- Fail if needed
        if result.exit_code ~= 0 then
          os.remove(task.stdout_file)
          os.remove(task.stderr_file)
          os.remove(task.exit_file)
          error(
            "Native task failed: " .. (task.opts.id or task.opts.description or "native task") .. "\n\n" ..
            "Tool:\n  " .. task.opts.tool .. "\n\n" ..
            "Exit code:\n  " .. tostring(result.exit_code) .. "\n\n" ..
            (result.stderr ~= "" and ("Stderr:\n  " .. result.stderr .. "\n\n") or "")
          )
        end

        local missing_outputs = {}
        for _, out in ipairs(task.opts.outputs or {}) do
          if not fs.read_file(out) and not fs.is_dir(out) then
            table.insert(missing_outputs, out)
          end
        end
        if #missing_outputs > 0 then
          os.remove(task.stdout_file)
          os.remove(task.stderr_file)
          os.remove(task.exit_file)
          error(
            "Native task completed but did not produce declared output:\n\n" ..
            "Task:\n  " .. (task.opts.id or task.opts.description or "native task") .. "\n\n" ..
            "Missing outputs:\n  " .. table.concat(missing_outputs, "\n  ")
          )
        end

        if task.cache_key and task.assets then
          cache.store(task.cache_key, task.assets, task.opts.outputs or {})
        end

        if task.assets then
          for _, asset in ipairs(task.assets.assets or {}) do
            if asset.metadata then asset.metadata.pending = nil end
          end
        end

        -- Clean up temp files
        os.remove(task.stdout_file)
        os.remove(task.stderr_file)
        os.remove(task.exit_file)

        table.remove(pending, i)
      end
    end
    if #pending > 0 then
      os.execute("sleep 0.1")
    end
  end
end

local function glob_to_pattern(glob)
  local pattern = tostring(glob):gsub("([%.%+%-%^%$%(%)%%])", "%%%1")
  pattern = pattern:gsub("%*%*/", ".-/")
  pattern = pattern:gsub("%*%*", ".-")
  pattern = pattern:gsub("%*", "[^/]*")
  return "^" .. pattern .. "$"
end

local function glob_match(value, glob)
  return tostring(value):match(glob_to_pattern(glob)) ~= nil
end

local function collect_input_assets(input_results)
  local assets = graph_mod.AssetSet.new()
  for _, set in ipairs(input_results or {}) do
    for _, asset in ipairs(set.assets or {}) do
      local is_project_metadata = asset.kind == "project" and asset.virtual_path == nil
      if asset.kind ~= "files" and not is_project_metadata then
        assets:add(asset)
      end
    end
  end
  return assets
end

local function write_asset_to_directory(fs, path, asset, out_dir)
  local rel = asset.virtual_path or asset.output_path or asset.source_path or asset.id
  rel = rel:gsub("^/", "")
  local dest = path.join(out_dir, rel)
  if asset.generated and asset.content then
    fs.mkdir(path.dirname(dest))
    fs.write_file(dest, asset.content)
  elseif asset.source_path then
    fs.copy_file(asset.source_path, dest)
  elseif asset.output_path and asset.output_path ~= dest then
    fs.copy_file(asset.output_path, dest)
  elseif asset.content then
    fs.mkdir(path.dirname(dest))
    fs.write_file(dest, asset.content)
  end
  if asset.metadata and asset.metadata.executable then
    fs.chmod(dest, "+x")
  end
  asset.output_path = dest
end

local function file_graph_for(input_results)
  local files = {}
  local layout = nil
  for _, set in ipairs(input_results or {}) do
    for _, asset in ipairs(set.assets or {}) do
      if asset.kind == "files" and asset.metadata then
        layout = asset.metadata.layout or layout
      end
      local is_project_metadata = asset.kind == "project" and asset.virtual_path == nil
      if asset.kind ~= "files" and not is_project_metadata then
        table.insert(files, {
          id = asset.id,
          kind = asset.kind,
          source = asset.source_path,
          dest = asset.virtual_path,
          virtual_path = asset.virtual_path,
          output_path = asset.output_path,
          generated = asset.generated,
          metadata = asset.metadata,
        })
      end
    end
  end
  table.sort(files, function(a, b) return (a.virtual_path or a.id) < (b.virtual_path or b.id) end)
  return { layout = layout, files = files }
end

local function core_handler(plugin, method)
  local fs = require("ballad.fs")
  local path = require("ballad.path")
  local process = require("ballad.process")
  local dkjson = require("dkjson")

  if plugin == "ballad.core.source" then
    if method == "directory" then
      return function(ctx, _, opts)
        local root = opts.path or opts.root or "."
        local assets = graph_mod.AssetSet.new()
        for _, source in ipairs(fs.list_files(root)) do
          assets:add(ctx.graph:add_asset({
            kind = "file",
            source_path = source,
            virtual_path = path.relative(source, root),
            metadata = opts.metadata,
          }))
        end
        return assets
      end
    elseif method == "files" then
      return function(ctx, _, opts)
        local patterns = type(opts.patterns) == "table" and opts.patterns or { opts.patterns }
        local root = opts.root or "."
        local assets = graph_mod.AssetSet.new()
        for _, source in ipairs(fs.list_files(root)) do
          local rel = path.relative(source, root)
          for _, pattern in ipairs(patterns) do
            if glob_match(rel, pattern) then
              assets:add(ctx.graph:add_asset({ kind = "file", source_path = source, virtual_path = rel, metadata = opts.metadata }))
              break
            end
          end
        end
        return assets
      end
    elseif method == "stdin" then
      return function(ctx, _, opts)
        local content = io.read("*a") or ""
        local assets = graph_mod.AssetSet.new()
        assets:add(ctx.graph:add_asset({ kind = opts.kind or "generated", virtual_path = opts.name or "stdin", content = content, generated = true, metadata = opts.metadata }))
        return assets
      end
    end
  elseif plugin == "ballad.core.sink" then
    if method == "directory" then
      return function(ctx, input_results, opts)
        local out_dir = opts.out or opts.path or "dist/ballad"
        fs.remove_tree(out_dir)
        fs.mkdir(out_dir)
        local input_assets = collect_input_assets(input_results)
        for _, asset in ipairs(input_assets.assets) do
          write_asset_to_directory(fs, path, asset, out_dir)
        end
        if opts.file_graph then
          fs.write_file(path.join(out_dir, "file-graph.json"), dkjson.encode(file_graph_for(input_results)) .. "\n")
        end
        local result = graph_mod.AssetSet.new()
        result:add(ctx.graph:add_asset({ kind = "sink", virtual_path = out_dir, output_path = out_dir, generated = true, metadata = { kind = "directory", count = input_assets:count() } }))
        return result
      end
    elseif method == "stdout" then
      return function(ctx, input_results, opts)
        local payload = opts.file_graph and file_graph_for(input_results) or file_graph_for(input_results).files
        print(dkjson.encode(payload))
        local result = graph_mod.AssetSet.new()
        result:add(ctx.graph:add_asset({ kind = "sink", virtual_path = "stdout", metadata = { kind = "stdout" } }))
        return result
      end
    elseif method == "file_graph" then
      return function(ctx, input_results, opts)
        local out = opts.out or opts.path or "file-graph.json"
        fs.mkdir(path.dirname(out))
        fs.write_file(out, dkjson.encode(file_graph_for(input_results)) .. "\n")
        local result = graph_mod.AssetSet.new()
        result:add(ctx.graph:add_asset({ kind = "sink", virtual_path = out, output_path = out, generated = true, metadata = { kind = "file_graph" } }))
        return result
      end
    elseif method == "artifact" then
      return function(ctx, input_results, opts)
        local input_assets = collect_input_assets(input_results)
        local chosen = nil
        for _, asset in ipairs(input_assets.assets) do
          if asset.output_path or asset.source_path then chosen = asset end
        end
        if not chosen then ctx.fail("sink.artifact requires an input asset with source_path or output_path") end
        local source = chosen.output_path or chosen.source_path
        local out = opts.out or source
        if out ~= source then
          if fs.is_dir(source) then
            fs.remove_tree(out)
            fs.mkdir(path.dirname(out))
            if not process.command_ok("cp -R " .. process.quote(source) .. " " .. process.quote(out)) then
              process.fail("cannot copy artifact " .. source .. " to " .. out)
            end
          else
            fs.copy_file(source, out)
          end
        end
        local result = graph_mod.AssetSet.new()
        result:add(ctx.graph:add_asset({ kind = "sink", virtual_path = out, output_path = out, generated = true, metadata = { kind = "artifact", source = source } }))
        return result
      end
    elseif method == "none" then
      return function(ctx, input_results, opts)
        local result = graph_mod.AssetSet.new()
        result:add(ctx.graph:add_asset({ kind = "sink", virtual_path = "none", metadata = { kind = "none" } }))
        return result
      end
    end
  end
  return nil
end

---@class Pipeline
---@field _graph Graph
---@field _host Host
---@field _context PipelineContext
local Pipeline = {}
Pipeline.__index = Pipeline

function Pipeline.new(host, jobs)
  local g = graph_mod.Graph.new()
  local ctx = PipelineContext.new(g, host, jobs)
  return setmetatable({
    _graph = g,
    _host = host,
    _context = ctx,
  }, Pipeline)
end

function Pipeline:context()
  return self._context
end

function Pipeline:graph()
  return self._graph
end

function Pipeline:plan(debug_dir)
  local fs = require("ballad.fs")
  local path = require("ballad.path")
  local dkjson = require("dkjson")

  local sinks = self._graph:terminal_sinks()
  if #sinks == 0 then
    error("Pipeline requires at least one explicit sink (use p.sink.*)")
  end

  local has_children = {}
  for parent_id, children in pairs(self._graph.edges) do
    for _, child_id in ipairs(children) do
      local child = self._graph.nodes[child_id]
      if child and child.enabled ~= false then
        has_children[parent_id] = true
      end
    end
  end
  local dangling = {}
  for id, node in pairs(self._graph.nodes) do
    if node.enabled ~= false and node.role == "transform" and not has_children[id] then
      table.insert(dangling, id .. " (" .. node.plugin .. "." .. node.method .. ")")
    end
  end
  table.sort(dangling)
  if #dangling > 0 then
    error("Pipeline has dangling transform leaf node(s); connect them to p.sink.* or remove them:\n  " .. table.concat(dangling, "\n  "))
  end

  local reachable = {}
  local function visit(id)
    if reachable[id] then return end
    local node = self._graph.nodes[id]
    if not node or node.enabled == false then return end
    reachable[id] = true
    for _, input_id in ipairs(node.inputs or {}) do
      visit(input_id)
    end
  end
  for _, sink in ipairs(sinks) do visit(sink.id) end

  local order = {}
  for _, id in ipairs(self._graph:topological_order()) do
    if reachable[id] then table.insert(order, id) end
  end

  local total_weight = 0
  for _, id in ipairs(order) do
    local node = self._graph.nodes[id]
    total_weight = total_weight + (node.progress_weight or 1)
  end
  local plan = { order = order, sinks = {}, total_progress_weight = total_weight, reachable = reachable }
  for _, sink in ipairs(sinks) do
    table.insert(plan.sinks, { id = sink.id, method = sink.method, label = sink.label, options = sink.options })
  end
  self._graph.metadata.plan = {
    order = order,
    sink_count = #sinks,
    total_progress_weight = total_weight,
  }
  if debug_dir then
    fs.write_file(path.join(debug_dir, "plan.json"), dkjson.encode(plan) .. "\n")
  end
  return plan
end

function Pipeline:execute()
  local fs = require("ballad.fs")
  local path = require("ballad.path")
  local dkjson = require("dkjson")
  local cache = require("ballad.cache")

  local run_id = self._context._run_id
  local debug_dir = ".ballad/runs/" .. run_id
  fs.mkdir(debug_dir)
  local function write_debug_graph()
    fs.write_file(path.join(debug_dir, "graph.json"), self._graph:to_json())
  end
  local function flush_pending_tasks()
    local ok, err = pcall(function()
      self._context:_flush_pending_tasks()
    end)
    if not ok then
      write_debug_graph()
      error(err, 0)
    end
  end
  local plan = self:plan(debug_dir)
  local order = plan.order

  for _, node_id in ipairs(order) do
    local node = self._graph.nodes[node_id]
        local input_results = {}
    for _, input_id in ipairs(node.inputs) do
      local result = self._graph:node_result(input_id)
      if result and getmetatable(result) == graph_mod.AssetSet then
        table.insert(input_results, result)
      else
        table.insert(input_results, graph_mod.AssetSet.new())
      end
    end

    -- Cache check for cacheable nodes
    local cached_result = nil
    if node.cacheable then
      -- Verify input files still exist before trusting cache
      local inputs_stale = false
      for _, asset_set in ipairs(input_results) do
        for _, asset in ipairs(asset_set.assets) do
          if asset.source_path and not fs.read_file(asset.source_path) and not fs.is_dir(asset.source_path) then
            inputs_stale = true
          end
          if asset.output_path and not fs.read_file(asset.output_path) and not fs.is_dir(asset.output_path) then
            inputs_stale = true
          end
        end
      end
      if not inputs_stale then
        local contract = self._host:contract(node.plugin)
        local plugin_version = contract and contract.version or "unknown"
        local key = cache.compute_key(node, input_results, plugin_version)
        local entry = cache.read(key)
        if entry and cache.outputs_valid(entry) then
        -- Restore cached AssetSet
        cached_result = graph_mod.AssetSet.new()
        for _, asset_info in ipairs(entry.assets or {}) do
          local asset = self._graph:add_asset({
            kind = asset_info.kind,
            source_path = asset_info.source_path,
            virtual_path = asset_info.virtual_path,
            output_path = asset_info.output_path,
            content = asset_info.content,
            generated = asset_info.generated,
            metadata = asset_info.metadata,
          })
          cached_result:add(asset)
        end

        -- Write skipped event
        local events_file = ".ballad/runs/" .. run_id .. "/events.ndjson"
        local f = io.open(events_file, "a")
        if f then
          f:write(dkjson.encode({
            type = "task_skipped",
            kind = "node",
            id = node_id,
            reason = "cache_hit",
            plugin = node.plugin,
            method = node.method,
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
          }) .. "\n")
          f:close()
        end

        print("Cache hit: " .. node_id .. " (" .. node.plugin .. "." .. node.method .. ")")
        self._graph:set_node_result(node_id, cached_result)
        goto continue
        end
      end
    end

    -- Flush pending parallel tasks before non-parallel-safe nodes
    if not node.parallel_safe then
      flush_pending_tasks()
    end

    local handler = core_handler(node.plugin, node.method) or self._host:handler(node.plugin, node.method)
    if not handler then
      write_debug_graph()
      error("No handler for " .. node.plugin .. "." .. node.method)
    end

    local ctx = {
      graph = self._graph,
      node = node,
      warn = function(msg) self._context:warn(msg) end,
      fail = function(msg) self._context:fail(msg) end,
      metadata = function(key, value) self._context:metadata(key, value) end,
      native_task = function(_, opts) return self._context:native_task(opts) end,
    }

    self._context._metadata._current_plugin = node.plugin
    self._context._metadata._current_method = node.method

    local ok, result = pcall(handler, ctx, input_results, node.options)
    if not ok then
      write_debug_graph()
      error("Pipeline node " .. node_id .. " (" .. node.plugin .. "." .. node.method .. ") failed: " .. tostring(result))
    end

    if result and getmetatable(result) ~= graph_mod.AssetSet then
      write_debug_graph()
      error("Node " .. node_id .. " did not return an AssetSet")
    end

    self._graph:set_node_result(node_id, result)

    if result and result.assets then
      for _, asset in ipairs(result.assets) do
        if asset.metadata and asset.metadata.pending then
          flush_pending_tasks()
          break
        end
      end
    end

	    -- Store cache entry on success
    if node.cacheable then
      local outputs = {}
      if result and result.assets then
        for _, asset in ipairs(result.assets) do
          if asset.output_path then
            table.insert(outputs, asset.output_path)
          end
        end
      end
      local contract = self._host:contract(node.plugin)
      local plugin_version = contract and contract.version or "unknown"
      local key = cache.compute_key(node, input_results, plugin_version)
      cache.store(key, result, outputs)
    end

    ::continue::
  end

  -- Final flush of any remaining pending tasks
  flush_pending_tasks()

  write_debug_graph()
  print("Graph debug written to " .. debug_dir .. "/graph.json")

  local sink_results = {}
  for _, sink in ipairs(self._graph:sink_nodes()) do
    table.insert(sink_results, {
      node = sink,
      result = sink.result,
    })
  end
  return sink_results
end

function pipeline.new(host, jobs)
  return Pipeline.new(host, jobs)
end

return pipeline

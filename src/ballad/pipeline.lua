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
      local inputs = {}
      local options = {}
      local first = args[1]
      if type(first) == "table" and getmetatable(first) == NodeHandle then
        table.insert(inputs, first._id)
        table.remove(args, 1)
      end
      if #args >= 1 and type(args[1]) == "table" then
        options = args[1]
      end
      local node = graph:add_node({
        plugin = name,
        method = method_name,
        inputs = inputs,
        options = options,
        cacheable = method_contract.cacheable,
        parallel_safe = method_contract.parallel_safe,
      })
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
  return setmetatable({
    _graph = graph,
    _host = host,
    _plugins = {},
    _metadata = {},
    _warnings = {},
    _assets = {},
    _run_id = nil,
    _jobs = jobs or 1,
    _pending_tasks = {},
  }, PipelineContext)
end

---@param plugin_ref string|PluginContract
---@return PluginProxy
function PipelineContext:use(plugin_ref)
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

---@param opts table
---@return AssetSet
---@param opts table
---@return AssetSet
function PipelineContext:native_task(opts)
  opts = opts or {}
  local tool = opts.tool or error("native_task: missing required field 'tool'")
  local args = opts.args or {}
  local outputs = opts.outputs or error("native_task: missing required field 'outputs'")
  local inputs = opts.inputs or {}
  local cwd = opts.cwd or "."
  local env = opts.env or {}
  local cacheable = opts.cacheable ~= false
  local parallel_safe = opts.parallel_safe ~= false
  local description = opts.description or (tool .. " " .. table.concat(args, " "))

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
  local cmd_parts = { resolved_tool }
  for _, a in ipairs(args) do
    table.insert(cmd_parts, require("ballad.process").quote(a))
  end
  local cmd = table.concat(cmd_parts, " ")

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

  local tool = opts.tool
  local outputs = opts.outputs
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

function Pipeline:execute()
  local order = self._graph:topological_order()
  local fs = require("ballad.fs")
  local path = require("ballad.path")
  local dkjson = require("dkjson")
  local cache = require("ballad.cache")

  local run_id = os.date("%Y%m%d-%H%M%S")
  self._context._run_id = run_id
  local debug_dir = ".ballad/runs/" .. run_id
  fs.mkdir(debug_dir)

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
      self._context:_flush_pending_tasks()
    end

    local handler = self._host:handler(node.plugin, node.method)
    if not handler then
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
      error("Pipeline node " .. node_id .. " (" .. node.plugin .. "." .. node.method .. ") failed: " .. tostring(result))
    end

    if result and getmetatable(result) ~= graph_mod.AssetSet then
      error("Node " .. node_id .. " did not return an AssetSet")
    end

    self._graph:set_node_result(node_id, result)

    if result and result.assets then
      for _, asset in ipairs(result.assets) do
        if asset.metadata and asset.metadata.pending then
          self._context:_flush_pending_tasks()
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
  self._context:_flush_pending_tasks()

  fs.write_file(path.join(debug_dir, "graph.json"), self._graph:to_json())
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

function pipeline.new(host)
  return Pipeline.new(host)
end

return pipeline

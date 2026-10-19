---@meta

---@class CacheTaskEntry
---@field version integer cache version
---@field key string cache key
---@field assets table[] stored asset metadata list
---@field outputs string[] stored output path list
---@field timestamp string ISO timestamp

local cache = {}
local process = require("ballad.process")
local dkjson = require("dkjson")
local fs = require("ballad.fs")

local CACHE_VERSION = 2
local CACHE_DIR = ".ballad/cache/tasks"
local output_snapshot
local serialize

-- Ensure cache directory exists
local function ensure_cache_dir()
  fs.mkdir(CACHE_DIR)
end

-- Compute a content hash for an asset
local function hash_asset(asset)
  -- A transformed asset's bytes are authoritative even when it retains its
  -- original source path for diagnostics.
  if asset.content ~= nil then
    return process.b3sum_string(asset.content)
  elseif asset.source_path and fs.read_file(asset.source_path) then
    return process.b3sum(asset.source_path)
  elseif asset.source_path and fs.is_dir(asset.source_path) then
    local manifest = asset.source_path .. "/moonstone.toml"
    if fs.read_file(manifest) then
      return process.b3sum(manifest)
    end
    return "dir:" .. asset.source_path
  elseif asset.output_path then
    return process.b3sum_string(serialize(output_snapshot(asset.output_path)))
  elseif asset.virtual_path then
    return "path:" .. asset.virtual_path
  else
    return "id:" .. asset.id
  end
end

-- Recursively sort table keys for deterministic JSON encoding
local function normalize(t)
  if type(t) ~= "table" then
    return t
  end
  local keys = {}
  for k in pairs(t) do
    table.insert(keys, k)
  end
  table.sort(keys)
  local result = {}
  for _, k in ipairs(keys) do
    result[k] = normalize(t[k])
  end
  return result
end

-- Deterministic string serializer for cache keys
serialize = function(value)
  local t = type(value)
  if t == "string" then
    return string.format("%q", value)
  elseif t == "number" then
    return tostring(value)
  elseif t == "boolean" then
    return tostring(value)
  elseif t == "table" then
    local keys = {}
    for k in pairs(value) do table.insert(keys, k) end
    table.sort(keys, function(a, b)
      local ta, tb = type(a), type(b)
      if ta ~= tb then return ta < tb end
      return a < b
    end)
    local parts = {}
    for _, k in ipairs(keys) do
      table.insert(parts, "[" .. serialize(k) .. "]=" .. serialize(value[k]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  else
    error("cannot serialize " .. t)
  end
end

-- Compute a stable cache key for a pipeline node
function cache.compute_key(node, input_results, plugin_version)
  local input_hashes = {}
  for i, asset_set in ipairs(input_results) do
    local hashes = {}
    for _, asset in ipairs(asset_set.assets) do
      table.insert(hashes, {
        hash = hash_asset(asset), kind = asset.kind, virtual_path = asset.virtual_path,
        source_path = asset.source_path, output_path = asset.output_path,
        generated = asset.generated, metadata = asset.metadata,
      })
    end
    table.insert(input_hashes, { index = i, hashes = hashes })
  end

  local key_data = {
    cache_version = CACHE_VERSION,
    kind = "node",
    plugin = node.plugin,
    method = node.method,
    plugin_version = plugin_version or "unknown",
    options = node.options,
    controls = node.control_conditions or {},
    input_hashes = input_hashes,
  }

  local json = serialize(key_data)
  return process.b3sum_string(json)
end

-- Compute a stable cache key for a native task
function cache.compute_native_key(opts, plugin_name, method_name)
  local input_hashes = {}
  local inputs_to_process = {}

  local function collect_inputs(inp)
    if type(inp) == "string" then
      if inp:find("%*") then
        -- Orbit inputs are absolute; enumerate their fixed directory prefix
        -- rather than comparing an absolute glob with relative project paths.
        local prefix = inp:match("^(.-)[*]") or ""
        local base = prefix:match("^(.*)/") or "."
        if base == "" then base = "/" end
        local files = fs.list_files(base)
        for _, f in ipairs(files) do
          local rel = f:gsub("^%./", "")
          if require("ballad.glob").matches(rel, inp) or require("ballad.glob").matches(f, inp) then
            table.insert(inputs_to_process, rel)
          end
        end
      elseif fs.is_dir(inp) then
        local files = fs.list_files(inp)
        for _, f in ipairs(files) do
          table.insert(inputs_to_process, f)
        end
      else
        table.insert(inputs_to_process, inp)
      end
    elseif type(inp) == "table" then
      if inp.assets then
        for _, asset in ipairs(inp.assets) do
          if asset.source_path then
            table.insert(inputs_to_process, asset.source_path)
          end
        end
      else
        for _, sub in ipairs(inp) do
          collect_inputs(sub)
        end
      end
    end
  end

  for _, input in ipairs(opts.inputs or {}) do
    collect_inputs(input)
  end

  for _, input in ipairs(inputs_to_process) do
    local content = fs.read_file(input)
    table.insert(input_hashes, {
      path = input,
      hash = content and process.b3sum_string(content) or "missing",
    })
  end
  table.sort(input_hashes, function(a, b) return a.path < b.path end)

  local key_data = {
    cache_version = CACHE_VERSION,
    kind = "native",
    plugin = plugin_name or "unknown",
    method = method_name or "unknown",
    tool = opts.tool or (opts.cmd and opts.cmd:match("^%S+")),
    cmd = opts.cmd,
    args = opts.args,
    cwd = opts.cwd,
    env = opts.env,
    action_id = opts.id,
    toolchain_fingerprint = opts.toolchain_fingerprint,
    controls = opts.control_conditions or {},
    input_hashes = input_hashes,
    outputs = opts.outputs,
  }

  local json = serialize(key_data)
  return process.b3sum_string(json)
end

local function cache_path(key)
  return CACHE_DIR .. "/" .. key .. ".json"
end

-- Read a cache entry if it exists
function cache.read(key)
  ensure_cache_dir()
  local path = cache_path(key)
  local content = fs.read_file(path)
  if not content then
    return nil
  end
  local ok, entry = pcall(dkjson.decode, content)
  if not ok or not entry then
    return nil
  end
  if entry.cache_version ~= CACHE_VERSION then
    return nil
  end
  return entry
end

-- Snapshot bytes and file membership, not merely output existence.
output_snapshot = function(out)
  if fs.is_dir(out) then
    local files = {}
    for _, file in ipairs(fs.list_files(out)) do
      local target = fs.readlink(file)
      files[#files + 1] = {
        path = require("ballad.path").relative(file, out),
        hash = fs.is_dir(file) and "directory-link" or process.b3sum(file),
        link = target ~= file and target or nil,
      }
    end
    return { kind = "directory", files = files }
  elseif fs.read_file(out) ~= nil then
    return { kind = "file", hash = process.b3sum(out) }
  end
  return nil
end

function cache.outputs_valid(entry)
  if not entry or not entry.outputs then
    return false
  end
  for _, out in ipairs(entry.outputs) do
    local snapshot = output_snapshot(out)
    if not snapshot or not entry.output_snapshots or
      serialize(snapshot) ~= serialize(entry.output_snapshots[out]) then
      return false
    end
  end
  return true
end

-- Write a cache entry
function cache.store(key, result_asset_set, outputs)
  ensure_cache_dir()
  local path = cache_path(key)

  local asset_info = {}
  if result_asset_set and result_asset_set.assets then
    for _, asset in ipairs(result_asset_set.assets) do
      table.insert(asset_info, {
        id = asset.id,
        kind = asset.kind,
        source_path = asset.source_path,
        virtual_path = asset.virtual_path,
        output_path = asset.output_path,
        content = asset.content,
        generated = asset.generated,
        metadata = asset.metadata,
      })
    end
  end

  local entry = {
    cache_version = CACHE_VERSION,
    key = key,
    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    outputs = outputs or {},
    assets = asset_info,
    output_snapshots = {},
  }

  for _, out in ipairs(entry.outputs) do
    entry.output_snapshots[out] = output_snapshot(out)
  end

  fs.write_file(path, dkjson.encode(entry) .. "\n")
end

-- Clear all cache entries
function cache.clear()
  fs.remove_tree(".ballad/cache")
end

return cache

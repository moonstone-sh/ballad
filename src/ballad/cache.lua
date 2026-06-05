local cache = {}
local process = require("ballad.process")
local dkjson = require("dkjson")
local fs = require("ballad.fs")

local CACHE_VERSION = 1
local CACHE_DIR = ".ballad/cache/tasks"

-- Ensure cache directory exists
local function ensure_cache_dir()
  fs.mkdir(CACHE_DIR)
end

-- Compute a content hash for an asset
local function hash_asset(asset)
  if asset.source_path and fs.read_file(asset.source_path) then
    return process.b3sum(asset.source_path)
  elseif asset.source_path and fs.is_dir(asset.source_path) then
    local manifest = asset.source_path .. "/moonstone.toml"
    if fs.read_file(manifest) then
      return process.b3sum(manifest)
    end
    return "dir:" .. asset.source_path
  elseif asset.content then
    return process.b3sum_string(asset.content)
  elseif asset.output_path then
    return "path:" .. asset.output_path
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
local function serialize(value)
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
      table.insert(hashes, hash_asset(asset))
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
    input_hashes = input_hashes,
  }

  local json = serialize(key_data)
  return process.b3sum_string(json)
end

-- Compute a stable cache key for a native task
function cache.compute_native_key(opts, plugin_name, method_name)
  local key_data = {
    cache_version = CACHE_VERSION,
    kind = "native",
    plugin = plugin_name or "unknown",
    method = method_name or "unknown",
    tool = opts.tool,
    args = opts.args,
    cwd = opts.cwd,
    env = opts.env,
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

-- Verify that all declared outputs still exist
function cache.outputs_valid(entry)
  if not entry or not entry.outputs then
    return false
  end
  for _, out in ipairs(entry.outputs) do
    if not fs.read_file(out) and not fs.is_dir(out) then
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
  }

  fs.write_file(path, dkjson.encode(entry) .. "\n")
end

-- Clear all cache entries
function cache.clear()
  fs.remove_tree(".ballad/cache")
end

return cache

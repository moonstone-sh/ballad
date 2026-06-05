---@meta

---@class Asset
---@field id string
---@field kind string one of: file, generated, project, package, files, registry, emit
---@field source_path string|nil actual input file path, if copied from disk
---@field virtual_path string|nil path inside the pipeline layout
---@field output_path string|nil final emitted path, usually assigned by emit plugin
---@field content string|nil only for generated assets
---@field generated boolean
---@field metadata table<string, any>
local Asset = {}
Asset.__index = Asset

---@param opts? table
---@return Asset
function Asset.new(opts)
  opts = opts or {}
  return setmetatable({
    id = opts.id or tostring(opts):gsub("table: ", ""),
    kind = opts.kind or "file",
    source_path = opts.source_path or nil,
    virtual_path = opts.virtual_path or nil,
    output_path = opts.output_path or nil,
    content = opts.content or nil,
    generated = opts.generated or false,
    metadata = opts.metadata or {},
  }, Asset)
end

---@class AssetSet
---@field assets Asset[]
local AssetSet = {}
AssetSet.__index = AssetSet

---@param assets? Asset[]
---@return AssetSet
function AssetSet.new(assets)
  local self = setmetatable({ assets = {} }, AssetSet)
  if assets then
    for _, a in ipairs(assets) do
      self:add(a)
    end
  end
  return self
end

---@param asset Asset
function AssetSet:add(asset)
  if getmetatable(asset) ~= Asset then
    error("AssetSet:add expected an Asset, got " .. type(asset))
  end
  table.insert(self.assets, asset)
end

---@param other AssetSet
---@return AssetSet
function AssetSet:merge(other)
  if getmetatable(other) ~= AssetSet then
    error("AssetSet:merge expected an AssetSet")
  end
  for _, a in ipairs(other.assets) do
    self:add(a)
  end
  return self
end

---@param predicate fun(asset: Asset): boolean
---@return AssetSet
function AssetSet:filter(predicate)
  local result = AssetSet.new()
  for _, a in ipairs(self.assets) do
    if predicate(a) then
      result:add(a)
    end
  end
  return result
end

---@return number
function AssetSet:count()
  return #self.assets
end

---@class Node
---@field id string
---@field plugin string
---@field method string
---@field inputs string[] node ids
---@field outputs string[] node ids
---@field options table<string, any>
---@field metadata table<string, any>
---@field effects string[]
---@field cacheable boolean
---@field parallel_safe boolean
---@field executed boolean
---@field result AssetSet|nil
local Node = {}
Node.__index = Node

---@param opts? table
---@return Node
function Node.new(opts)
  opts = opts or {}
  return setmetatable({
    id = opts.id or "node_0",
    plugin = opts.plugin or "unknown",
    method = opts.method or "unknown",
    inputs = opts.inputs or {},
    outputs = opts.outputs or {},
    options = opts.options or {},
    metadata = opts.metadata or {},
    effects = opts.effects or {},
    cacheable = opts.cacheable ~= false,
    parallel_safe = opts.parallel_safe ~= false,
    executed = false,
    result = nil,
  }, Node)
end

---@class Graph
---@field id string
---@field assets table<string, Asset>
---@field nodes table<string, Node>
---@field metadata table<string, any>
---@field outputs table<string, any>
---@field edges table<string, string[]>
local Graph = {}
Graph.__index = Graph

---@param opts? table
---@return Graph
function Graph.new(opts)
  opts = opts or {}
  return setmetatable({
    id = opts.id or "graph_0",
    assets = {},
    nodes = {},
    metadata = opts.metadata or {},
    outputs = {},
    edges = {},
    native_tasks = {},
    _node_counter = 1,
    _asset_counter = 1,
    _native_task_counter = 1,
  }, Graph)
end

---@return string
function Graph:_next_node_id()
  local id = "node_" .. self._node_counter
  self._node_counter = self._node_counter + 1
  return id
end

---@return string
function Graph:_next_asset_id()
  local id = "asset_" .. self._asset_counter
  self._asset_counter = self._asset_counter + 1
  return id
end

---@param opts table
---@return Node
function Graph:add_node(opts)
  local id = self:_next_node_id()
  local node = Node.new({
    id = id,
    plugin = opts.plugin,
    method = opts.method,
    inputs = opts.inputs or {},
    options = opts.options or {},
    metadata = opts.metadata or {},
    cacheable = opts.cacheable,
    parallel_safe = opts.parallel_safe,
  })
  self.nodes[id] = node
  for _, input_id in ipairs(node.inputs) do
    self.edges[input_id] = self.edges[input_id] or {}
    table.insert(self.edges[input_id], id)
  end
  return node
end

---@param opts table
---@return Asset
function Graph:add_asset(opts)
  local id = self:_next_asset_id()
  local asset = Asset.new({
    id = id,
    kind = opts.kind,
    source_path = opts.source_path,
    virtual_path = opts.virtual_path,
    output_path = opts.output_path,
    content = opts.content,
    generated = opts.generated,
    metadata = opts.metadata,
  })
  self.assets[id] = asset
  return asset
end

---@return string[]
function Graph:topological_order()
  local in_degree = {}
  for id, node in pairs(self.nodes) do
    in_degree[id] = 0
  end
  for id, node in pairs(self.nodes) do
    for _, input_id in ipairs(node.inputs) do
      in_degree[id] = in_degree[id] + 1
    end
  end
  local queue = {}
  for id, deg in pairs(in_degree) do
    if deg == 0 then
      table.insert(queue, id)
    end
  end
  local order = {}
  while #queue > 0 do
    table.sort(queue)
    local current = table.remove(queue, 1)
    table.insert(order, current)
    for _, child_id in ipairs(self.edges[current] or {}) do
      in_degree[child_id] = in_degree[child_id] - 1
      if in_degree[child_id] == 0 then
        table.insert(queue, child_id)
      end
    end
  end
  local count = 0
  for _ in pairs(self.nodes) do count = count + 1 end
  if #order ~= count then
    error("Graph contains a cycle")
  end
  return order
end

---@param id string
---@return AssetSet|nil
function Graph:node_result(id)
  local node = self.nodes[id]
  return node and node.result or nil
end

---@param id string
---@param result AssetSet|nil
function Graph:set_node_result(id, result)
  local node = self.nodes[id]
  if node then
    node.result = result
    node.executed = true
  end
end

---@return Node[]
function Graph:add_native_task(task)
  local id = "native_" .. self._native_task_counter
  self._native_task_counter = self._native_task_counter + 1
  task.id = id
  table.insert(self.native_tasks, task)
  return id
end

function Graph:sink_nodes()
  local has_children = {}
  for id, children in pairs(self.edges) do
    if #children > 0 then
      has_children[id] = true
    end
  end
  local sinks = {}
  for id, node in pairs(self.nodes) do
    if not has_children[id] then
      table.insert(sinks, node)
    end
  end
  return sinks
end

---@return string
function Graph:to_json()
  local dkjson = require("dkjson")
  local function serialize_node(node)
    return {
      id = node.id,
      plugin = node.plugin,
      method = node.method,
      inputs = node.inputs,
      options = node.options,
      metadata = node.metadata,
      effects = node.effects,
      cacheable = node.cacheable,
      parallel_safe = node.parallel_safe,
      executed = node.executed,
    }
  end
  local function serialize_asset(asset)
    return {
      id = asset.id,
      kind = asset.kind,
      source_path = asset.source_path,
      virtual_path = asset.virtual_path,
      output_path = asset.output_path,
      generated = asset.generated,
      metadata = asset.metadata,
    }
  end
  local nodes = {}
  for _, node in pairs(self.nodes) do
    table.insert(nodes, serialize_node(node))
  end
  local assets = {}
  for _, asset in pairs(self.assets) do
    table.insert(assets, serialize_asset(asset))
  end
  return dkjson.encode({
    id = self.id,
    metadata = self.metadata,
    nodes = nodes,
    assets = assets,
    outputs = self.outputs,
    native_tasks = self.native_tasks,
  })
end

local graph = {}
graph.Asset = Asset
graph.AssetSet = AssetSet
graph.Node = Node
graph.Graph = Graph

return graph

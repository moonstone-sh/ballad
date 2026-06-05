---@meta

local plugin_host = {}

local graph_mod = require("ballad.graph")
local fs = require("ballad.fs")
local path = require("ballad.path")
local process = require("ballad.process")
local project_mod = require("ballad.project")

---@class PluginMethod
---@field inputs string[]
---@field outputs string[]
---@field cacheable boolean
---@field parallel_safe boolean

---@class PluginContract
---@field name string
---@field version string
---@field methods table<string, PluginMethod>

---@param name string
---@return PluginContract
local function load_plugin(name)
  local mod_name = name:find("%.") and name or ("ballad.plugins." .. name)
  local ok, plugin = pcall(require, mod_name)
  if not ok then
    error("Failed to load plugin '" .. name .. "' from '" .. mod_name .. "': " .. tostring(plugin))
  end
  return plugin
end

---@class Host
---@field _registry table<string, PluginContract>
local Host = {}
Host.__index = Host

---@return Host
function Host.new()
  return setmetatable({
    _registry = {},
  }, Host)
end

---@param plugin_name string
---@return PluginContract
function Host:contract(plugin_name)
  return load_plugin(plugin_name)
end

---@param plugin_name string
---@param method_name string
---@return fun(ctx: PluginCtx, inputs: AssetSet[], opts: table): AssetSet|nil
function Host:handler(plugin_name, method_name)
  local plugin = load_plugin(plugin_name)
  if not plugin[method_name] then
    return nil
  end
  return function(ctx, inputs, opts)
    local result = plugin[method_name](ctx, inputs, opts)
    if result and getmetatable(result) ~= graph_mod.AssetSet then
      error("Plugin method '" .. method_name .. "' did not return an AssetSet")
    end
    return result
  end
end

---@param plugin_name string
---@param plugin_def PluginContract
function Host:register(plugin_name, plugin_def)
  self._registry[plugin_name] = plugin_def
end

---@return Host
function plugin_host.new()
  return Host.new()
end

return plugin_host

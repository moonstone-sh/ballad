local dkjson = require("dkjson")
local process = require("ballad.process")
local graph = require("ballad.graph")
local project_mod = require("ballad.project")

local input = {
  name = "ballad.plugins.input.moonstone",
  version = "0.1.0",
  methods = {
    packages = {
      inputs = {},
      outputs = { "asset_set" },
      cacheable = false,
      parallel_safe = true,
    },
  },
}

---@param package table
---@param roles BalladDependencyRole[]|nil
---@return boolean
local function role_allowed(package, roles)
  local allowed = {}
  for _, role in ipairs(roles or { "runtime" }) do
    allowed[role] = true
  end

  if type(package.roles) ~= "table" or #package.roles == 0 then
    return allowed.runtime == true
  end

  for _, role in ipairs(package.roles) do
    if allowed[role] then return true end
  end
  return false
end

---@param moon_bin string|nil
---@param artifact_hash string|nil
---@return table|nil result
---@return string|nil err
local query_artifact = require("ballad.moonstone_store").artifact

---@param package table
---@return table
local function copy_package(package)
  local out = {}
  for key, value in pairs(package) do out[key] = value end
  return out
end

---@param packages table[]|nil Lockfile package records from `moonstone.lock`.
---@param opts MoonstoneInputOptions|nil
---@return MoonstoneResolvedPackage[]
function input.enrich_packages(packages, opts)
  opts = opts or {}
  local roles = opts.roles or { "runtime" }
  local moon_bin = opts.moon or opts.moon_bin or os.getenv("MOONSTONE_CLI") or os.getenv("MOONSTONE_BIN") or "moon"
  local enriched = {}

  for _, package in ipairs(packages or {}) do
    if role_allowed(package, roles) then
      local out = copy_package(package)
      local query, err = query_artifact(moon_bin, package.artifact_hash)
      if query then
        out.artifact_path = query.artifact_path
        out.manifest_path = query.manifest_path
        out.source_payload_path = query.source_payload_path
        out.rockspec_payload_path = query.rockspec_payload_path
        out.source_payload = out.source_payload or query.source_payload
        out.rockspec_payload = out.rockspec_payload or query.rockspec_payload
        out.source_kind = out.source_kind or query.source_kind
        out.source_hash = out.source_hash or query.source_hash
        out.recipe_hash = out.recipe_hash or query.recipe_hash
        out.rockspec_hash = out.rockspec_hash or query.rockspec_hash
        out.store_query = query
        out.store_warnings = query.warnings or {}
      else
        out.store_warnings = {
          { code = "store_query_failed", message = err or "moon store list failed" },
        }
      end
      enriched[#enriched + 1] = out
    end
  end

  table.sort(enriched, function(left, right)
    if (left.name or "") ~= (right.name or "") then return (left.name or "") < (right.name or "") end
    if (left.version or "") ~= (right.version or "") then return (left.version or "") < (right.version or "") end
    return (left.artifact_hash or "") < (right.artifact_hash or "")
  end)

  return enriched
end

---@param opts MoonstoneInputOptions|nil
---@return table
function input.packages_prepare(opts)
  opts = opts or {}
  local loaded = project_mod.load(opts.root or ".", opts)
  return {
    root = loaded.root,
    packages = input.enrich_packages(loaded.packages, opts),
  }
end

---@param ctx PluginCtx
---@param inputs AssetSet[]
---@param opts MoonstoneInputOptions|nil
---@return AssetSet
function input.packages(ctx, inputs, opts)
  opts = opts or {}
  local loaded = project_mod.load(opts.root or ".", opts)
  local packages = input.enrich_packages(loaded.packages, opts)
  local assets = graph.AssetSet.new()
  local asset = ctx.graph:add_asset({
    kind = "moonstone_packages",
    source_path = loaded.root,
    metadata = {
      root = loaded.root,
      packages = packages,
    },
  })
  assets:add(asset)
  return assets
end

return input

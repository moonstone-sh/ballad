local graph = require("ballad.graph")
local project_mod = require("ballad.project")
local moonstone_input = require("ballad.plugins.input.moonstone")

return {
  name = "ballad.plugins.moonstone",
  version = "0.1.0",
  methods = {
    project = {
      inputs = {},
      outputs = { "asset_set" },
      cacheable = false,
      parallel_safe = true,
    },
  },

  ---Eagerly read project metadata during graph construction.
  ---@param opts table
  ---@return table
  project_prepare = function(opts)
    local root = opts.root or "."
    local loaded = project_mod.load(root)
    local pkg = loaded.manifest and loaded.manifest.package or {}
    local rt = loaded.manifest and loaded.manifest.runtime or {}
    local env_rt = loaded.env and loaded.env.runtime or {}
    local version = pkg.version
    if not version then
      error("moonstone.project: missing package.version in moonstone.toml")
    end
    local name = pkg.name or "app"
    local description = pkg.description or ""
    local runtime_name = rt.name or env_rt.name or "lua"
    local runtime_version = rt.version or env_rt.version or "5.1"
    local runtime = runtime_name .. "@" .. runtime_version
    local lua_abi = rt.abi or env_rt.abi or "5.1"
    local packages = moonstone_input.enrich_packages(loaded.packages, {
      roles = opts.roles or { "runtime" },
      moon = opts.moon or opts.moon_bin or "moon",
    })
    return {
      name = name,
      version = version,
      description = description,
      runtime = runtime,
      lua_abi = lua_abi,
      registry_name = pkg.registry_name or nil,
      packages = packages,
    }
  end,

  ---@param ctx PluginCtx
  ---@param inputs AssetSet[]
  ---@param opts table
  ---@return AssetSet
  project = function(ctx, inputs, opts)
    local root = opts.root or "."
    local loaded = project_mod.load(root)

    -- Build role-grouped dependency map from flat or role-table manifest.dependencies
    local dep_roles = { dev = {}, tool = {}, runtime = {}, helper = {}, peer = {}, optional = {} }
    if loaded.manifest and loaded.manifest.dependencies then
      if #loaded.manifest.dependencies > 0 then
        for _, dep in ipairs(loaded.manifest.dependencies) do
          local role = dep.role or "runtime"
          if dep_roles[role] then
            dep_roles[role][dep.name] = {
              constraint = dep.constraint or "*",
              resolver = dep.resolver or nil,
              optional = dep.optional or false,
            }
          end
        end
      else
        for role, deps in pairs(loaded.manifest.dependencies) do
          local normalized_role = role
          if role == "libs" then normalized_role = "runtime" end
          if role == "bins" then normalized_role = "helper" end
          if role == "dev_libs" then normalized_role = "dev" end
          if role == "dev_bins" then normalized_role = "tool" end
          if dep_roles[normalized_role] and type(deps) == "table" then
            for dep_name, spec in pairs(deps) do
              dep_roles[normalized_role][dep_name] = {
                constraint = tostring(spec),
                resolver = tostring(spec):match("^([^:]+):") or nil,
                optional = normalized_role == "optional",
              }
            end
          end
        end
      end
    end

    local assets = graph.AssetSet.new()
    local packages = moonstone_input.enrich_packages(loaded.packages, {
      roles = opts.roles or { "runtime" },
      moon = opts.moon or opts.moon_bin or "moon",
    })
    local asset = ctx.graph:add_asset({
      kind = "project",
      source_path = root,
      metadata = {
        root = loaded.root,
        manifest = loaded.manifest,
        packages = packages,
        env = loaded.env,
        abi = loaded.env and loaded.env.runtime and loaded.env.runtime.abi or "5.1",
        dependencies = dep_roles,
      },
    })
    assets:add(asset)
    return assets
  end,
}

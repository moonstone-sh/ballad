local graph = require("ballad.graph")
local fs = require("ballad.fs")
local path = require("ballad.path")

local function parse_dependencies_toml(content)
  local dependencies = {}
  local current = nil
  for raw_line in (content or ""):gmatch("[^\r\n]+") do
    local line = raw_line:match("^%s*(.-)%s*$")
    if line == "[[dependencies]]" then
      if current then table.insert(dependencies, current) end
      current = {}
    elseif current and line ~= "" and not line:match("^#") then
      local key, value = line:match('^"?([^"=]+)"?%s*=%s*(.-)%s*$')
      if key and value then
        key = key:match("^%s*(.-)%s*$")
        value = value:match('^%s*"(.-)"%s*$') or value:match("^%s*'(.-)'%s*$") or value:match("^%s*(.-)%s*$")
        current[key] = value
      end
    end
  end
  if current then table.insert(dependencies, current) end
  return dependencies
end

return {
  name = "ballad.plugins.runtime",
  version = "0.1.0",
  methods = {
    bundle = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      cacheable = false,
      parallel_safe = true,
    },
  },

  ---@param ctx PluginCtx
  ---@param inputs AssetSet[]
  ---@param opts table
  ---@return AssetSet
  bundle = function(ctx, inputs, opts)
    opts = opts or {}
    if opts.enabled == false or opts.include_runtime == false or opts.mode == "external" then
      local assets = graph.AssetSet.new()
      for _, asset in ipairs(inputs[1].assets) do
        assets:add(asset)
      end
      return assets
    end

    local project_asset = nil
    for _, asset in ipairs(inputs[1].assets) do
      if asset.kind == "project" and asset.metadata and asset.metadata.manifest then
        project_asset = asset
        break
      end
    end
    if not project_asset then
      ctx.fail("runtime.bundle requires a moonstone.project node as input")
    end

    local meta = project_asset.metadata
    local root = meta.root

    -- Find runtime dependency from .moonstone/env/dependencies.toml
    local deps_toml_path = path.join(root, ".moonstone/env/dependencies.toml")
    local deps_content = fs.read_file(deps_toml_path)
    if not deps_content then
      ctx.fail("runtime.bundle: missing .moonstone/env/dependencies.toml; run moon sync first")
    end

    local dependencies = parse_dependencies_toml(deps_content)
    local runtime_dep = nil
    for _, dep in ipairs(dependencies) do
      if dep.role == "runtime" and (dep.name == "lua" or dep.name == "luajit") then
        runtime_dep = dep
        break
      end
    end

    if not runtime_dep then
      ctx.fail("runtime.bundle: no runtime dependency found in .moonstone/env/dependencies.toml")
    end

    local artifact_path = runtime_dep.path
    if not artifact_path or artifact_path == "" then
      -- Compute from artifact_hash, name, version
      local hash = runtime_dep.artifact_hash
      local name = runtime_dep.name
      local version = runtime_dep.version
      local moonstone_home = os.getenv("MOONSTONE_HOME") or (os.getenv("HOME") .. "/.local/share/moonstone")
      local algo, hash_body = hash:match("^([^:]+):(.+)$")
      if not algo then algo = "b3"; hash_body = hash end
      local h0h1 = hash_body:sub(1, 2)
      local h2h3 = hash_body:sub(3, 4)
      artifact_path = path.join(moonstone_home, "store/v0", algo, h0h1, h2h3, hash_body .. "-" .. name .. "-" .. version)
    end

    local files_root = path.join(artifact_path, "files")
    if not fs.is_dir(files_root) then
      ctx.fail("runtime.bundle: runtime artifact not found at " .. files_root)
    end

    -- Copy forward all existing assets
    local assets = graph.AssetSet.new()
    for _, asset in ipairs(inputs[1].assets) do
      assets:add(asset)
    end

    -- Add runtime files
    for _, source in ipairs(fs.list_files(files_root)) do
      local relative = path.relative(source, files_root)
      local asset = ctx.graph:add_asset({
        kind = "runtime",
        source_path = source,
        virtual_path = relative,
        metadata = {
          runtime = runtime_dep.name,
          version = runtime_dep.version,
          artifact_hash = runtime_dep.artifact_hash,
        },
      })
      assets:add(asset)
    end

    return assets
  end,
}

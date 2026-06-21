local graph = require("ballad.graph")
local project_mod = require("ballad.project")
local moonstone_input = require("ballad.plugins.input.moonstone")
local dkjson = require("dkjson")
local fs = require("ballad.fs")
local path = require("ballad.path")
local process = require("ballad.process")

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

local function normalize_abi(abi)
  if not abi or abi == "" then return "lua-5.1" end
  local major, minor = abi:match("^lua(%d)(%d)$")
  if major and minor then return "lua-" .. major .. "." .. minor end
  major, minor = abi:match("^(%d)%.(%d)$")
  if major and minor then return "lua-" .. major .. "." .. minor end
  return abi
end

local function runtime_bin_map(files_root)
  local bin = {}
  for _, name in ipairs({ "lua", "luac", "luajit" }) do
    if process.command_ok("test -f " .. process.quote(path.join(files_root, "bin", name))) then
      bin[name] = path.join("files/bin", name)
    elseif process.command_ok("test -f " .. process.quote(path.join(files_root, "bin", name .. ".exe"))) then
      bin[name] = path.join("files/bin", name .. ".exe")
    end
  end
  return bin
end

local function runtime_from_dependencies(root, env_rt)
  local deps_content = fs.read_file(path.join(root, ".moonstone/env/dependencies.toml"))
  if not deps_content then return nil end
  for _, dep in ipairs(parse_dependencies_toml(deps_content)) do
    if dep.role == "runtime" and (dep.name == env_rt.name or dep.name == "moonstone/" .. tostring(env_rt.name)) then
      return dep
    end
  end
  return nil
end

local function query_current_runtime(root, moon_bin)
  local cmd = "cd " .. process.quote(root) .. " && " .. process.quote(moon_bin or "moon") .. " runtime path --current --json 2>/dev/null"
  local output = process.capture(cmd)
  if output == "" then return nil end
  local decoded = dkjson.decode(output)
  if type(decoded) ~= "table" then return nil end
  return decoded
end

local function query_runtime_artifact(moon_bin, artifact_hash)
  if not artifact_hash or artifact_hash == "" then return nil end
  local cmd = process.quote(moon_bin or "moon") .. " store query --by-artifact-hash " .. process.quote(artifact_hash) .. " --json"
  local output = process.capture(cmd)
  if output == "" then return nil end
  local decoded = dkjson.decode(output)
  if type(decoded) ~= "table" or type(decoded[1]) ~= "table" then return nil end
  return decoded[1]
end

local function hydrate_runtime(loaded, opts)
  opts = opts or {}
  local env_rt = loaded.env and loaded.env.runtime or {}
  local name = env_rt.name or "lua"
  local version = env_rt.version or "5.1"
  local dep = runtime_from_dependencies(loaded.root, env_rt) or {}
  local query = query_current_runtime(loaded.root, opts.moon or opts.moon_bin or "moon") or {}
  local artifact_hash = dep.artifact_hash or query.artifact_hash
  local store_query = query_runtime_artifact(opts.moon or opts.moon_bin or "moon", artifact_hash) or {}
  local artifact_path = dep.path or query.path
  local files_root = artifact_path and path.join(artifact_path, "files") or nil
  local bin = files_root and runtime_bin_map(files_root) or {}

  return {
    id = name .. "@" .. version,
    name = name,
    version = version,
    lua_abi = normalize_abi(env_rt.abi or dep.lua_abi or query.lua_abi),
    target = dep.target or query.target,
    artifact_hash = artifact_hash,
    artifact_path = artifact_path or store_query.artifact_path,
    manifest_path = store_query.manifest_path,
    source_payload = dep.source_payload or query.source_payload or store_query.source_payload,
    source_payload_path = dep.source_payload_path or query.source_payload_path or store_query.source_payload_path,
    source_kind = dep.source_kind or query.source_kind or store_query.source_kind,
    source_hash = dep.source_hash or query.source_hash or store_query.source_hash,
    store_query = store_query,
    store_warnings = store_query.warnings or {},
    bin = bin,
    lib = { lua = "files/lib" },
    include = "files/include",
    env = loaded.env,
  }
end

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
    local runtime_record = hydrate_runtime(loaded, opts)
    local packages = moonstone_input.enrich_packages(loaded.packages, {
      roles = opts.roles or { "runtime" },
      moon = opts.moon or opts.moon_bin or "moon",
    })
    return {
      name = name,
      version = version,
      description = description,
      root = loaded.root,
      runtime = runtime_record,
      runtime_spec = runtime,
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
    local runtime_record = hydrate_runtime(loaded, opts)
    local asset = ctx.graph:add_asset({
      kind = "project",
      source_path = root,
      metadata = {
        kind = "moonstone_project",
        root = loaded.root,
        project_root = loaded.root,
        manifest = loaded.manifest,
        packages = packages,
        runtime = runtime_record,
        env = loaded.env,
        abi = loaded.env and loaded.env.runtime and loaded.env.runtime.abi or "5.1",
        dependencies = dep_roles,
      },
    })
    assets:add(asset)
    return assets
  end,
}

---@meta

---@class MoonstoneProjectOpts
---@field root? string root directory of the Moonstone project (default ".")
---@field roles? string[] dependency roles to enrich (default {"runtime"})
---@field moon? string path or name of Moonstone binary (default "moon")

---@class MoonstoneToolOpts
---@field name string executable name from the synchronized Moonstone project

---@class MoonstoneRunOpts
---@field script? string named script from moonstone.toml to run
---@field inputs? string[]|AssetSet[] list of input file paths, globs (e.g. "src/*.moon"), or asset sets to track for cache invalidation
---@field outputs? string[] list of output file/directory paths expected to be produced
---@field cwd? string working directory (defaults to ".")
---@field env? table<string, string> environment variables to set during execution
---@field description? string human-readable description for diagnostics and graph visualization
---@field parallel_safe? boolean whether this task can run concurrently with non-overlapping tasks (default true)
---@field cacheable? boolean whether native task caching is enabled (default true)

---@class MoonstoneExecOpts
---@field cmd? string|string[] command string or array of arguments to execute inside moon exec
---@field inputs? string[]|AssetSet[] list of input file paths, globs (e.g. "src/*.moon"), or asset sets to track for cache invalidation
---@field outputs? string[] list of output file/directory paths expected to be produced
---@field cwd? string working directory (defaults to ".")
---@field env? table<string, string> environment variables to set during execution
---@field description? string human-readable description for diagnostics and graph visualization
---@field parallel_safe? boolean whether this task can run concurrently with non-overlapping tasks (default true)
---@field cacheable? boolean whether native task caching is enabled (default true)

---@class MoonstoneOrbitOpts
---@field name string root-declared Moonstone orbit name
---@field partiture string child-relative partiture path
---@field sync? 'locked'|'update'|'never' child environment policy (default 'locked')
---@field inputs? string[]|AssetSet[] additional child-relative cache inputs; Ballad also reuses observed source inputs from the prior matching export report
---@field args? string[] arguments forwarded to the child partiture after `--`
---@field moon? string path or name of Moonstone binary (default 'moon')
---@field cacheable? boolean whether the parent orbit task is cacheable (defaults false for sync='update')

local graph = require("ballad.graph")
local project_mod = require("ballad.project")
local moonstone_input = require("ballad.plugins.input.moonstone")
local dkjson = require("dkjson")
local fs = require("ballad.fs")
local path = require("ballad.path")
local process = require("ballad.process")
local toml = require("ballad.toml")

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
  local cmd = "cd " .. process.quote(root) .. " && " .. process.quote(moon_bin or "moon") .. " interpreter path --current --json 2>/dev/null"
  local output = process.capture(cmd)
  if output == "" then
    cmd = "cd " .. process.quote(root) .. " && " .. process.quote(moon_bin or "moon") .. " runtime path --current --json 2>/dev/null"
    output = process.capture(cmd)
  end
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

local function find_moon_cli(opts)
  opts = opts or {}
  if opts.moon or opts.moon_bin then
    return opts.moon or opts.moon_bin
  end
  if os.getenv("MOONSTONE_CLI") and os.getenv("MOONSTONE_CLI") ~= "" then
    return os.getenv("MOONSTONE_CLI")
  end
  if os.getenv("MOONSTONE_BIN") and os.getenv("MOONSTONE_BIN") ~= "" then
    return os.getenv("MOONSTONE_BIN")
  end

  local pipe = io.popen("which -a moon 2>/dev/null")
  if pipe then
    for line in pipe:lines() do
      local trimmed = line:match("^%s*(.-)%s*$")
      if trimmed ~= "" and not trimmed:find("%.moonstone/env/bin") and not trimmed:find("moonscript") then
        pipe:close()
        return trimmed
      end
    end
    pipe:close()
  end

  return "moon"
end

local function scope_root(pattern, suffix)
  if type(pattern) ~= "string" or pattern:sub(-#suffix) ~= suffix then return nil end
  return pattern:sub(1, #pattern - #suffix)
end

local function add_scope_files(ctx, assets, roots, suffix, kind, prefix, seen)
  for _, root in ipairs(roots or {}) do
    for _, file_path in ipairs(fs.list_files(root)) do
      local source = fs.readlink(file_path)
      if (kind == "lua" and fs.is_lua(file_path)) or (kind == "c_module" and fs.is_binary_module(file_path)) then
        local relative = path.relative(file_path, root)
        local virtual_path = prefix .. "/" .. relative
        if not seen[virtual_path] then
          seen[virtual_path] = true
          assets:add(ctx.graph:add_asset({
            kind = "tool_source",
            source_path = source,
            virtual_path = virtual_path,
            metadata = { scope_kind = kind },
          }))
        end
      end
    end
  end
end

local function tool_scope_assets(ctx, project_asset, opts)
  local meta = project_asset.metadata or {}
  local root = meta.root or meta.project_root
  local tool_name = opts.name or opts.tool or opts.bin
  if not tool_name or tool_name == "" then ctx.fail("moonstone.tool requires opts.name") end

  local scope_path = path.join(root, ".moonstone/env/bin-runtime", tool_name, "env.toml")
  local scope_content = fs.read_file(scope_path)
  if not scope_content then ctx.fail("moonstone.tool: missing synchronized scope for " .. tool_name .. "; run moon sync") end
  local scope = toml.parse(scope_content)
  local env = scope.env or {}
  local tool_link = path.join(root, ".moonstone/env/bin", tool_name)
  if not fs.is_file(tool_link) then ctx.fail("moonstone.tool: executable not found in project environment: " .. tool_name) end

  local assets = graph.AssetSet.new()
  local executable = fs.readlink(tool_link)
  assets:add(ctx.graph:add_asset({
    kind = "tool",
    source_path = executable,
    metadata = {
      kind = "moonstone_tool",
      name = tool_name,
      root = root,
      executable = executable,
      runtime = meta.runtime,
      scope_path = scope_path,
      scope = env,
    },
  }))

  local seen = {}
  local lua_roots, c_roots = {}, {}
  for _, pattern in ipairs(env.lua_path or {}) do
    local scope_path_root = scope_root(pattern, "/?.lua") or scope_root(pattern, "/?/init.lua")
    if scope_path_root then lua_roots[#lua_roots + 1] = scope_path_root end
  end
  for _, pattern in ipairs(env.lua_cpath or {}) do
    local scope_path_root = scope_root(pattern, "/?.so") or scope_root(pattern, "/?.dylib") or scope_root(pattern, "/?.dll")
    if scope_path_root then c_roots[#c_roots + 1] = scope_path_root end
  end
  add_scope_files(ctx, assets, lua_roots, ".lua", "lua", "lua", seen)
  add_scope_files(ctx, assets, c_roots, ".so", "c_module", "lib", seen)

  for _, bin_root in ipairs(env.path_prepend or {}) do
    for _, file_path in ipairs(fs.list_files(bin_root)) do
      if fs.is_file(file_path) then
        local virtual_path = "bin/" .. path.basename(file_path)
        if not seen[virtual_path] then
          seen[virtual_path] = true
          assets:add(ctx.graph:add_asset({
            kind = "tool_source",
            source_path = fs.readlink(file_path),
            virtual_path = virtual_path,
            metadata = { scope_kind = "bin", executable = true },
          }))
        end
      end
    end
  end

  return assets
end

local function canonical_dir(value)
  if not process.command_ok("test -d " .. process.quote(value)) then
    error("moonstone.orbit: directory does not exist: " .. value)
  end
  local resolved = process.capture("cd " .. process.quote(value) .. " && pwd -P")
  if resolved == "" then error("moonstone.orbit: cannot resolve directory: " .. value) end
  return resolved
end

local function resolve_orbit(root, name)
  local manifest = fs.read_file(path.join(root, "moonstone.toml"))
  if not manifest then error("moonstone.orbit: missing root moonstone.toml in " .. root) end

  local current = nil
  for raw_line in manifest:gmatch("[^\r\n]+") do
    local line = raw_line:match("^%s*(.-)%s*$")
    if line == "[[orbits.member]]" then
      if current and current.name == name and current.path then break end
      current = {}
    elseif current then
      local key, value = line:match('^([%w_]+)%s*=%s*"(.-)"%s*$')
      if key then current[key] = value end
    end
  end

  if not current or current.name ~= name or not current.path then
    error("moonstone.orbit: unknown root-declared orbit '" .. name .. "'")
  end

  local child = canonical_dir(path.join(root, current.path))
  if child ~= root and child:sub(1, #root + 1) ~= root .. "/" then
    error("moonstone.orbit: orbit path escapes the root project: " .. current.path)
  end
  if not fs.read_file(path.join(child, "moonstone.toml")) then
    error("moonstone.orbit: orbit '" .. name .. "' has no moonstone.toml")
  end
  return child
end

local function child_input_paths(child_root, inputs)
  local result = {}
  for _, value in ipairs(inputs or {}) do
    if type(value) ~= "string" then error("moonstone.orbit: inputs must be child-relative strings") end
    result[#result + 1] = path.join(child_root, value)
  end
  return result
end

local function child_relative_path(value)
  if type(value) ~= "string" or value == "" or value:sub(1, 1) == "/" or value:match("^%.%.?/") or value:find("/%.%.?/") then
    return nil
  end
  return value
end

local function invocation_fingerprint(orbit_name, child_root, partiture_file, args, lua_paths)
  local parts = { "orbit", orbit_name, child_root, partiture_file }
  for _, value in ipairs(args or {}) do
    parts[#parts + 1] = "arg:" .. #value .. ":" .. value
  end
  for _, value in ipairs(lua_paths or {}) do
    parts[#parts + 1] = "lua_path:" .. #value .. ":" .. value
  end
  return process.b3sum_string(table.concat(parts, "\0"))
end

local function observed_input_paths(child_root, report_path)
  local content = fs.read_file(report_path)
  if not content then return {} end
  local report = dkjson.decode(content)
  local result = {}
  for _, input in ipairs(report and report.invocation and report.invocation.inputs or {}) do
    local relative = child_relative_path(input.path)
    if relative then result[#result + 1] = path.join(child_root, relative) end
  end
  return result
end

local function orbit_input_paths(child_root, partiture_file, inputs, report_path)
  local paths = { path.join(child_root, "moonstone.toml"), path.join(child_root, partiture_file) }
  local lockfile = path.join(child_root, "moonstone.lock")
  if fs.read_file(lockfile) then paths[#paths + 1] = lockfile end
  for _, value in ipairs(child_input_paths(child_root, inputs)) do paths[#paths + 1] = value end
  for _, value in ipairs(observed_input_paths(child_root, report_path)) do paths[#paths + 1] = value end
  local seen, unique = {}, {}
  for _, value in ipairs(paths) do
    if not seen[value] then
      seen[value] = true
      unique[#unique + 1] = value
    end
  end
  return unique
end

local function child_lua_paths(root, child_root, lua_paths)
  local result = {}
  for _, value in ipairs(lua_paths or {}) do
    if type(value) ~= "string" or value == "" then error("moonstone.orbit: lua_paths must be child-relative directories") end
    local resolved = canonical_dir(path.join(child_root, value))
    if resolved ~= root and resolved:sub(1, #root + 1) ~= root .. "/" then
      error("moonstone.orbit: lua_path escapes the parent project: " .. value)
    end
    result[#result + 1] = value
  end
  return result
end

local function import_orbit_report(ctx, orbit_name, child_root, report_path, invocation)
  local content = fs.read_file(report_path)
  if not content then error("moonstone.orbit: child did not produce report " .. report_path) end
  local report, _, err = dkjson.decode(content)
  if not report or report.version ~= 2 or type(report.sinks) ~= "table" then
    error("moonstone.orbit: invalid child report: " .. tostring(err or "unsupported schema"))
  end
  if not report.invocation or report.invocation.fingerprint ~= invocation then
    error("moonstone.orbit: child report does not match the requested partiture invocation")
  end

  local assets = graph.AssetSet.new()
  local products = {}
  for _, sink in ipairs(report.sinks) do
    local product = sink.product
    if product ~= nil and (type(product) ~= "string" or not product:match("^[a-z][a-z0-9_-]*$")) then
      error("moonstone.orbit: child report has an invalid product name")
    end
    if product then
      if products[product] then
        error("moonstone.orbit: child report defines product '" .. product .. "' more than once")
      end
      products[product] = true
    end
    for _, recorded in ipairs(sink.assets or {}) do
      if not product then goto continue end
      if not recorded.path or recorded.path == "" then
        error("moonstone.orbit: sink '" .. tostring(sink.id) .. "' contains an unsupported non-materialized asset")
      end
      local source_path = path.absolute(path.join(child_root, recorded.path))
      if source_path ~= child_root and source_path:sub(1, #child_root + 1) ~= child_root .. "/" then
        error("moonstone.orbit: child report asset escapes orbit root: " .. tostring(recorded.path))
      end
      if not fs.read_file(source_path) and not fs.is_dir(source_path) then
        error("moonstone.orbit: reported sink asset is missing: " .. source_path)
      end
      local metadata = {
        orbit = orbit_name,
        orbit_product = product,
        orbit_sink = sink.id,
        orbit_sink_method = sink.method,
        orbit_root = child_root,
        child_metadata = recorded.metadata,
      }
      local virtual_root = path.join("orbits", orbit_name, recorded.virtual_path or recorded.path)
      if fs.is_dir(source_path) then
        for _, child_file in ipairs(fs.list_files(source_path)) do
          assets:add(ctx.graph:add_asset({
            kind = "file",
            source_path = child_file,
            virtual_path = path.join(virtual_root, path.relative(child_file, source_path)),
            metadata = metadata,
          }))
        end
      else
        assets:add(ctx.graph:add_asset({
          kind = recorded.kind or "file",
          source_path = source_path,
          virtual_path = virtual_root,
          metadata = metadata,
        }))
      end
      ::continue::
    end
  end
  if not next(products) then
    error("moonstone.orbit: child report exposes no named products; declare p.sink.*(..., { product = \"release\" })")
  end
  return assets
end

local moonstone_registry = require("ballad.moonstone_registry")

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
    tool = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      cacheable = false,
      parallel_safe = true,
    },
    run = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      cacheable = false,
      parallel_safe = true,
    },
    exec = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      cacheable = false,
      parallel_safe = true,
    },
    orbit = {
      inputs = {},
      outputs = { "asset_set" },
      cacheable = true,
      parallel_safe = false,
    },
    registry_package = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      cacheable = false,
      parallel_safe = true,
    },
    registry_source_package = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      cacheable = false,
      parallel_safe = true,
    },
    registry_runtime = {
      inputs = {},
      outputs = { "asset_set" },
      cacheable = false,
      parallel_safe = true,
    },
    registry_external = {
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
    local origin = loaded.manifest and loaded.manifest.origin or nil
    local runtime_name = rt.name or env_rt.name or "lua"
    local runtime_version = rt.version or env_rt.version or "5.1"
    local runtime = runtime_name .. "@" .. runtime_version
    local lua_abi = rt.abi or env_rt.abi or "5.1"
    local runtime_record = hydrate_runtime(loaded, opts)
    local packages = moonstone_input.enrich_packages(loaded.packages, {
      roles = opts.roles or { "runtime" },
      moon = opts.moon or opts.moon_bin or "moon",
    })
    -- An explicit package README wins. Otherwise prefer a registry-facing
    -- README, then use the repository README as a useful fallback.
    local readme_path = nil
    local readme_content = nil
    local declared_readme = pkg.readme
    if declared_readme and declared_readme ~= "" then
      local candidate = path.join(loaded.root, declared_readme)
      if fs.read_file(candidate) then
        readme_path = declared_readme
        readme_content = fs.read_file(candidate)
      end
    else
      for _, candidate_name in ipairs({ "REGISTRY_README.md", "README.md" }) do
        local candidate = path.join(loaded.root, candidate_name)
        local content = fs.read_file(candidate)
        if content then
          readme_path = candidate_name
          readme_content = content
          break
        end
      end
    end
    return {
      name = name,
      version = version,
      description = description,
      root = loaded.root,
      runtime = runtime_record,
      runtime_spec = runtime,
      lua_abi = lua_abi,
      registry_name = pkg.registry_name or nil,
      origin = origin,
      readme = readme_path,
      readme_content = readme_content,
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
    local pkg = loaded.manifest and loaded.manifest.package or {}

    -- Build role-grouped dependency map from flat, role-table, or [[dependencies]] array manifest.dependencies
    local dep_roles = { dev = {}, tool = {}, runtime = {}, helper = {}, peer = {}, optional = {} }
    local manifest_content = fs.read_file(path.join(loaded.root, "moonstone.toml")) or ""
    local parsed_deps = parse_dependencies_toml(manifest_content)
    if #parsed_deps > 0 then
      for _, dep in ipairs(parsed_deps) do
        local role = dep.role or "runtime"
        if dep_roles[role] then
          dep_roles[role][dep.name] = {
            constraint = dep.constraint or "*",
            resolver = dep.resolver or nil,
            optional = (role == "optional") or (dep.optional == "true"),
          }
        end
      end
    elseif loaded.manifest and loaded.manifest.dependencies then
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
        origin = loaded.manifest and loaded.manifest.origin or nil,
        readme = (pkg.readme and pkg.readme ~= "") and pkg.readme
          or (fs.read_file(path.join(loaded.root, "REGISTRY_README.md")) and "REGISTRY_README.md")
          or (fs.read_file(path.join(loaded.root, "README.md")) and "README.md" or nil),
      },
    })
    assets:add(asset)
    return assets
  end,

  tool = function(ctx, inputs, opts)
    opts = opts or {}
    local input = inputs[1]
    local project_asset = input and input.assets and input.assets[1]
    if not project_asset or project_asset.kind ~= "project" then
      ctx.fail("moonstone.tool requires a moonstone.project node as input")
    end
    return tool_scope_assets(ctx, project_asset, opts)
  end,

  ---Run a named script from moonstone.toml inside the Moonstone project environment.
  ---
  ---Example usage in `partiture.lua`:
  ---```lua
  ---  -- Run `moon run build` when any file in src/*.moon changes, emitting dist/src/main.lua
  ---  moonstone:run("build", {
  ---    inputs = { "src/*.moon" },
  ---    outputs = { "dist/src/main.lua" },
  ---  })
  ---```
  ---@param ctx PluginCtx
  ---@param inputs AssetSet[]
  ---@param opts MoonstoneRunOpts|string|table script name or options table (with optional inputs, outputs, cwd, env)
  ---@return AssetSet
  run = function(ctx, inputs, opts)
    opts = opts or {}
    local script = opts.script or opts[1] or error("moonstone.run: missing script name")
    local moon_bin = find_moon_cli(opts)
    local cmd = process.quote(moon_bin) .. " run " .. script
    local task_opts = {
      id = opts.id or ("moonstone.run:" .. script),
      cmd = cmd,
      tool = moon_bin,
      inputs = opts.inputs or {},
      outputs = opts.outputs or {},
      cwd = opts.cwd or opts.root or ".",
      env = opts.env,
      cacheable = opts.cacheable ~= false,
      parallel_safe = opts.parallel_safe ~= false,
      description = opts.description or ("moon run " .. script),
    }
    return ctx:native_task(task_opts)
  end,

  ---Execute an arbitrary command inside the project environment via `moon exec`.
  ---
  ---Example usage in `partiture.lua`:
  ---```lua
  ---  -- Run `moonc -t dist src/` when src/*.moon changes
  ---  moonstone:exec("moonc -t dist src/", {
  ---    inputs = { "src/*.moon" },
  ---    outputs = { "dist/src/main.lua" },
  ---  })
  ---```
  ---@param ctx PluginCtx
  ---@param inputs AssetSet[]
  ---@param opts MoonstoneExecOpts|string|table|string[] command string, array of args, or options table (with optional inputs, outputs, cwd, env)
  ---@return AssetSet
  exec = function(ctx, inputs, opts)
    opts = opts or {}
    local cmd_or_args = opts.cmd or opts.args or opts[1] or error("moonstone.exec: missing command")
    local moon_bin = find_moon_cli(opts)
    local command_str
    if type(cmd_or_args) == "table" then
      local parts = {}
      for _, p in ipairs(cmd_or_args) do
        table.insert(parts, process.quote(p))
      end
      command_str = table.concat(parts, " ")
    else
      command_str = tostring(cmd_or_args)
    end
    local cmd = process.quote(moon_bin) .. " exec " .. command_str
    local task_opts = {
      id = opts.id or "moonstone.exec",
      cmd = cmd,
      tool = moon_bin,
      inputs = opts.inputs or {},
      outputs = opts.outputs or {},
      cwd = opts.cwd or opts.root or ".",
      env = opts.env,
      cacheable = opts.cacheable ~= false,
      parallel_safe = opts.parallel_safe ~= false,
      description = opts.description or ("moon exec " .. command_str),
    }
    return ctx:native_task(task_opts)
  end,

  ---Run a child partiture in the selected orbit's isolated Moonstone scope.
  ---The child owns named products; select one with `orbit.product("name")` before consuming it.
  ---@param ctx PluginCtx
  ---@param inputs AssetSet[]
  ---@param opts MoonstoneOrbitOpts
  ---@return AssetSet
  orbit_prepare = function(opts)
    opts = opts or {}
    local orbit_name = opts.name or error("moonstone.orbit: missing orbit name")
    return { _orbit_export = { name = orbit_name } }
  end,

  orbit = function(ctx, inputs, opts)
    opts = opts or {}
    local orbit_name = opts.name or error("moonstone.orbit: missing orbit name")
    local partiture_file = opts.partiture or error("moonstone.orbit: missing child partiture")
    local sync_mode = opts.sync or "locked"
    if sync_mode ~= "locked" and sync_mode ~= "update" and sync_mode ~= "never" then
      error("moonstone.orbit: sync must be 'locked', 'update', or 'never'")
    end
    local root = canonical_dir(opts.root or ".")
    local child_root = resolve_orbit(root, orbit_name)
    local child_partiture = path.join(child_root, partiture_file)
    if not fs.read_file(child_partiture) then
      error("moonstone.orbit: partiture not found in orbit '" .. orbit_name .. "': " .. partiture_file)
    end

    local lua_paths = child_lua_paths(root, child_root, opts.lua_paths)
    local args = opts.args or {}
    local invocation = invocation_fingerprint(orbit_name, child_root, partiture_file, args, lua_paths)
    local report_path = path.join(child_root, ".ballad", "exports", invocation .. ".json")
    local moon_bin = find_moon_cli(opts)
    local command = "set -eu; "
    if sync_mode ~= "never" then
      command = command .. process.quote(moon_bin) .. " orbit sync " .. process.quote(orbit_name) .. " --" .. sync_mode .. "; "
    end
    command = command
      .. "BALLAD_ORBIT_NAME=" .. process.quote(orbit_name)
      .. " BALLAD_EXPORT_FINGERPRINT=" .. process.quote(invocation)
      .. " " .. process.quote(moon_bin) .. " orbit exec " .. process.quote(orbit_name)
      .. " -- ballad play " .. process.quote(partiture_file)
    for _, lua_path in ipairs(lua_paths) do
      command = command .. " --lua-path " .. process.quote(lua_path)
    end
    command = command
      .. " --report " .. process.quote(path.relative(report_path, child_root))
    if #args > 0 then
      command = command .. " --"
      for _, value in ipairs(args) do command = command .. " " .. process.quote(value) end
    end

    ctx:native_task({
      id = opts.id or ("moonstone.orbit:" .. orbit_name),
      tool = "sh",
      args = { "-c", command },
      inputs = orbit_input_paths(child_root, partiture_file, opts.inputs or {}, report_path),
      outputs = { report_path },
      cwd = root,
      cacheable = opts.cacheable ~= false and sync_mode ~= "update",
      parallel_safe = false,
      description = opts.description or ("export orbit " .. orbit_name .. " partiture " .. partiture_file),
    })

    return import_orbit_report(ctx, orbit_name, child_root, report_path, invocation)
  end,

  registry_package = function(ctx, inputs, opts)
    return moonstone_registry.package(ctx, inputs, opts)
  end,

  registry_source_package = function(ctx, inputs, opts)
    return moonstone_registry.source_package(ctx, inputs, opts)
  end,

  registry_runtime = function(ctx, inputs, opts)
    return moonstone_registry.runtime(ctx, inputs, opts)
  end,

  registry_external = function(ctx, inputs, opts)
    return moonstone_registry.external(ctx, inputs, opts)
  end,
}

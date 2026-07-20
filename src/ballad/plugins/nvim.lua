---@meta

---@class NvimOpts
---@field module string|nil top-level Lua module name (e.g. "my_plugin")
---@field include? string[] glob patterns for files to include
---@field exclude? string[] glob patterns for files to exclude
---@field out? string output directory (default "dist/nvim-plugin")
---@field runtime? string e.g. "nvim@0.12.2"
---@field lua_api? string e.g. "5.1"
---@field lua_abi? string e.g. "lua-5.1"
---@field dependencies? table<string, DependencySpec> declared dependency map
---@field unresolved? string behavior for unknown requires: "warn" or "fail" (default "warn")

---@class DependencySpec
---@field role string one of: "dev", "tool", "runtime", "peer", "optional"
---@field package? string package reference (e.g. "nvim-lua/plenary.nvim")
---@field constraint? string version constraint (e.g. "*", "^1.0")
---@field optional? boolean alias for role="optional"

---@class NvimHelptagsOpts
---@field doc string directory containing doc/*.txt files (default "doc")

local graph = require("ballad.graph")
local fs = require("ballad.fs")
local path = require("ballad.path")
local process = require("ballad.process")
local deps = require("ballad.deps")

local known_externs = {
  plenary = { role = "peer", package = "nvim-lua/plenary.nvim", constraint = "*" },
  telescope = { role = "optional", package = "nvim-telescope/telescope.nvim", constraint = "*", optional = true },
  ["nvim-treesitter"] = { role = "optional", package = "nvim-treesitter/nvim-treesitter", constraint = "*", optional = true },
  cmp = { role = "optional", package = "hrsh7th/nvim-cmp", constraint = "*", optional = true },
  luasnip = { role = "optional", package = "L3MON4D3/LuaSnip", constraint = "*", optional = true },
  lspconfig = { role = "optional", package = "neovim/nvim-lspconfig", constraint = "*", optional = true },
  treesitter = { role = "optional", package = "nvim-treesitter/nvim-treesitter", constraint = "*", optional = true },
}

local known_require_roots = {
  plenary = "plenary",
  telescope = "telescope",
  ["nvim-treesitter"] = "nvim-treesitter",
  cmp = "cmp",
  luasnip = "luasnip",
  lspconfig = "lspconfig",
  treesitter = "treesitter",
}

local function clone_spec(spec)
  local result = {}
  for key, value in pairs(spec or {}) do
    result[key] = value
  end
  return result
end

local function normalize_extern_spec(name, spec)
  if spec == true or spec == nil then
    local known = known_externs[name]
    if known then return clone_spec(known) end
    return { role = "peer", package = name, constraint = "*" }
  end
  if type(spec) == "string" then
    return { role = "peer", package = spec, constraint = "*" }
  end
  if type(spec) == "table" then
    local result = clone_spec(spec)
    if result.optional and not result.role then result.role = "optional" end
    result.role = result.role or "peer"
    result.constraint = result.constraint or "*"
    if not result.package then
      local known = known_externs[name]
      result.package = known and known.package or name
    end
    return result
  end
  return { role = "peer", package = tostring(spec), constraint = "*" }
end

local function suggest_extern(mod)
  for root, name in pairs(known_require_roots) do
    if mod == root or mod:sub(1, #root + 1) == root .. "." then
      local spec = known_externs[name]
      if spec then
        return name, spec
      end
    end
  end
  return nil, nil
end

---Convert a glob pattern to a Lua pattern.
---@param glob string
---@return string
local function glob_to_pattern(glob)
  if glob:match("/%*%*$") then
    local prefix = glob:gsub("/%*%*$", "")
    return "^" .. prefix:gsub("([%.%+%-%^%$%(%)%%])", "%%%1") .. "/.*$"
  end
  if glob:sub(1, 2) == "**" then
    local suffix = glob:sub(3)
    if suffix:sub(1, 1) == "/" then
      return ".*" .. suffix:gsub("([%.%+%-%^%$%(%)%%])", "%%%1") .. "$"
    end
    return ".*" .. glob:gsub("([%.%+%-%^%$%(%)%%])", "%%%1") .. ".*"
  end
  local pattern = glob:gsub("([%.%+%-%^%$%(%)%%])", "%%%1")
  pattern = pattern:gsub("%*%*/", ".-/")
  pattern = pattern:gsub("%*%*", ".-")
  pattern = pattern:gsub("%*", "[^/]+")
  return "^" .. pattern .. "$"
end

---@param file_path string
---@param glob string
---@return boolean
local function glob_match(file_path, glob)
  return file_path:match(glob_to_pattern(glob)) ~= nil
end

---Validate that a Neovim plugin directory has expected structure.
---@param root string
---@param module string|nil
---@param ctx PluginCtx
local function validate_nvim_structure(root, module, ctx)
  local has_lua = fs.is_dir(path.join(root, "lua"))
  local has_plugin = fs.is_dir(path.join(root, "plugin"))
  if not has_lua and not has_plugin then
    ctx.warn("nvim.layout: neither lua/ nor plugin/ found; may not be a valid Neovim plugin")
  end
  if module then
    local module_path = path.join(root, "lua", module:gsub("%.", "/") .. ".lua")
    if not fs.read_file(module_path) then
      local init_path = path.join(root, "lua", module:gsub("%.", "/"), "init.lua")
      if not fs.read_file(init_path) then
        ctx.warn("nvim.layout: module '" .. module .. "' not found at lua/" .. module:gsub("%.", "/") .. ".lua")
      end
    end
  end
end

local nvim_plugin = {
  name = "ballad.plugins.nvim",
  version = "0.1.0",

  methods = {
    layout = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      effects = { "metadata" },
      cacheable = true,
      parallel_safe = true,
    },
    helptags = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      effects = { "generated" },
      cacheable = true,
      parallel_safe = false,
    },
    discover = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      effects = { "read" },
      cacheable = true,
      parallel_safe = true,
    },
  },

  ---Arrange project files into a Neovim plugin directory layout.
  ---Preserves standard Neovim paths: lua/, plugin/, ftplugin/, after/, queries/, doc/, syntax/, health/, rplugin/
  ---@param ctx PluginCtx
  ---@param inputs AssetSet[]
  ---@param opts NvimOpts
  ---@return AssetSet
  layout = function(ctx, inputs, opts)
    local project_asset = inputs[1].assets[1]
    if not project_asset or project_asset.kind ~= "project" then
      ctx.fail("nvim.layout requires a moonstone.project node as input")
    end

    local meta = project_asset.metadata
    local root = meta.root
    local out_dir = opts.out or "dist/nvim-plugin"

    validate_nvim_structure(root, opts.module, ctx)

    fs.remove_tree(out_dir)
    fs.mkdir(out_dir)

    local include_patterns = opts.include or {
      "lua/**",
      "plugin/**",
      "ftplugin/**",
      "after/**",
      "queries/**",
      "doc/**",
      "syntax/**",
      "health/**",
      "autoload/**",
      "rplugin/**",
    }
    local exclude_patterns = opts.exclude or {
      ".moonstone/**",
      ".ballad/**",
      "dist/**",
      ".git/**",
      "tests/**",
    }

    local all_files = fs.list_files(root)
    local included = {}
    local lua_file_rels = {}

    for _, f in ipairs(all_files) do
      local rel = path.relative(f, root)
      local should_include = false

      for _, pattern in ipairs(include_patterns) do
        if glob_match(rel, pattern) then
          should_include = true
          break
        end
      end

      if should_include and exclude_patterns then
        for _, pattern in ipairs(exclude_patterns) do
          if glob_match(rel, pattern) then
            should_include = false
            break
          end
        end
      end

      if should_include then
        table.insert(included, { src = f, rel = rel })
        if rel:match("%.lua$") then
          table.insert(lua_file_rels, rel)
        end
      end
    end

    local assets = graph.AssetSet.new()
    for _, item in ipairs(included) do
      local dest = path.join(out_dir, item.rel)
      fs.copy_file(item.src, dest)
      local asset = ctx.graph:add_asset({
        kind = "file",
        source_path = item.src,
        virtual_path = item.rel,
        output_path = dest,
        metadata = { plugin = "nvim", method = "layout" },
      })
      assets:add(asset)
    end

    -- Build dependency classification
    local project_asset = nil
    if inputs[1] and inputs[1].assets then
      for _, a in ipairs(inputs[1].assets) do
        if a.kind == "project" or (a.metadata and a.metadata.kind == "moonstone_project") then
          project_asset = a
          break
        end
      end
    end
    local dependency_map = opts.dependencies or {}
    if not opts.dependencies and project_asset and project_asset.metadata and project_asset.metadata.dependencies then
      for role, deps_table in pairs(project_asset.metadata.dependencies) do
        for dep_name, dep_spec in pairs(deps_table) do
          local spec = {
            role = role,
            package = dep_spec.package or dep_name,
            constraint = dep_spec.constraint or "*",
            optional = (role == "optional") or dep_spec.optional or false,
          }
          dependency_map[dep_name] = spec
          if dep_name:find("/") then
            local short = dep_name:match("/([^/]+)$"):gsub("%.nvim$", "")
            dependency_map[short] = spec
          end
        end
      end
    end
    -- Normalize optional shorthand: { optional = true } -> { role = "optional" }
    for name, spec in pairs(dependency_map) do
      if spec.optional and not spec.role then
        spec.role = "optional"
      end
    end

    local internal_modules = deps.build_internal_modules(lua_file_rels)
    -- Also include the declared module as internal
    if opts.module then
      internal_modules[opts.module] = true
    end

    local require_map = deps.scan_requires(out_dir, out_dir)
    local classified = {}
    local unknown_requires = {}
    local peer_deps = {}
    local optional_deps = {}
    local runtime_deps = {}
    local dev_deps = {}
    local tool_deps = {}
    local helper_deps = {}
    local suggested_deps = {}

    for rel, required_mods in pairs(require_map) do
      for _, mod in ipairs(required_mods) do
        -- Skip vim/neovim built-ins (rough heuristic)
        if mod:match("^vim%.") or mod:match("^vim$") or mod:match("^nvim%.") or mod:match("^bit%.") or mod:match("^jit%.") or mod == "jit" or mod == "bit" or mod == "ffi" or mod == "package" or mod == "io" or mod == "os" or mod == "string" or mod == "table" or mod == "math" or mod == "debug" then
          goto skip_builtin
        end

        local role, pkg_ref, constraint = deps.classify(mod, internal_modules, dependency_map)
        classified[mod] = { role = role, package = pkg_ref, constraint = constraint }

        if role == "peer" then
          for dep_name, spec in pairs(dependency_map) do
            if mod == dep_name or mod:sub(1, #dep_name + 1) == dep_name .. "." then
              peer_deps[dep_name] = spec
            end
          end
        elseif role == "optional" then
          for dep_name, spec in pairs(dependency_map) do
            if mod == dep_name or mod:sub(1, #dep_name + 1) == dep_name .. "." then
              optional_deps[dep_name] = spec
            end
          end
        elseif role == "runtime" then
          for dep_name, spec in pairs(dependency_map) do
            if mod == dep_name or mod:sub(1, #dep_name + 1) == dep_name .. "." then
              runtime_deps[dep_name] = spec
            end
          end
        elseif role == "dev" then
          for dep_name, spec in pairs(dependency_map) do
            if mod == dep_name or mod:sub(1, #dep_name + 1) == dep_name .. "." then
              dev_deps[dep_name] = spec
            end
          end
        elseif role == "tool" then
          for dep_name, spec in pairs(dependency_map) do
            if mod == dep_name or mod:sub(1, #dep_name + 1) == dep_name .. "." then
              tool_deps[dep_name] = spec
            end
          end
        elseif role == "helper" then
          for dep_name, spec in pairs(dependency_map) do
            if mod == dep_name or mod:sub(1, #dep_name + 1) == dep_name .. "." then
              helper_deps[dep_name] = spec
            end
          end
        elseif role == "unknown" then
          local suggested_name, suggested_spec = suggest_extern(mod)
          if suggested_name and suggested_spec then
            suggested_deps[suggested_name] = suggested_spec
          end
          table.insert(unknown_requires, { file = rel, module = mod, suggested_name = suggested_name, suggested_spec = suggested_spec })
        end

        ::skip_builtin::
      end
    end

    -- Handle unresolved requires
    if #unknown_requires > 0 then
      local unresolved = opts.unresolved or "warn"
      local messages = {}
      for _, item in ipairs(unknown_requires) do
        local message = "  " .. item.file .. ": require('" .. item.module .. "')"
        if item.suggested_name and item.suggested_spec then
          message = message .. "\n    suggested dependency: " .. item.suggested_name .. " = { role = \"" .. (item.suggested_spec.role or "peer") .. "\", package = \"" .. item.suggested_spec.package .. "\" }"
        end
        table.insert(messages, message)
      end
      if unresolved == "fail" then
        ctx.fail("nvim.layout: unresolved require(s) found:\n" .. table.concat(messages, "\n") ..
          "\n\nDeclare them with nvim.extern({...}), pass opts.dependencies, or set opts.unresolved = 'warn'.")
      else
        ctx.warn("nvim.layout: unresolved require(s) found:\n" .. table.concat(messages, "\n"))
      end
    end

    -- Synthetic asset describing the layout output
    assets:add(ctx.graph:add_asset({
      kind = "files",
      virtual_path = out_dir,
      output_path = out_dir,
      metadata = {
        entry = opts.entry or (opts.module and ("lua/" .. opts.module:gsub("%.", "/") .. ".lua")) or (lua_file_rels[1] and lua_file_rels[1]) or "init.lua",
        libexec_root = "",
        bin_name = meta.manifest and meta.manifest.package and meta.manifest.package.name or "nvim-plugin",
        layout = "nvim",
        kind = "lib",
        artifact_kind = "lua_module",
        module = opts.module,
        runtime = opts.runtime or "nvim@0.12.2",
        lua_api = opts.lua_api or "5.1",
        lua_abi = opts.lua_abi or "5.1",
        dependencies = {
          peer = peer_deps,
          optional = optional_deps,
          runtime = runtime_deps,
          dev = dev_deps,
          tool = tool_deps,
          helper = helper_deps,
        },
        classified_requires = classified,
        suggested_dependencies = suggested_deps,
      },
    }))

    return assets
  end,

  ---Generate helptags for doc/*.txt files.
  ---Stage 2: emits a placeholder asset. In Stage 3+ this may invoke `nvim --headless`.
  ---@param ctx PluginCtx
  ---@param inputs AssetSet[]
  ---@param opts NvimHelptagsOpts
  ---@return AssetSet
  helptags = function(ctx, inputs, opts)
    local files_asset = nil
    for _, a in ipairs(inputs[1].assets) do
      if a.kind == "files" then
        files_asset = a
        break
      end
    end
    if not files_asset then
      ctx.fail("nvim.helptags requires a nvim.layout node as input")
    end

    local doc_dir = opts.doc or "doc"
    local out_dir = files_asset.output_path
    local full_doc = path.join(out_dir, doc_dir)

    if not fs.is_dir(full_doc) then
      ctx.warn("nvim.helptags: doc directory not found at " .. full_doc)
    else
      ctx.warn("nvim.helptags: native_task support is not implemented in Stage 2; skipping helptags generation")
    end

    -- Stage 2 no-op: return passthrough
    return inputs[1]
  end,

  ---Discover plugin structure and emit metadata.
  ---@param ctx PluginCtx
  ---@param inputs AssetSet[]
  ---@param opts table
  ---@return AssetSet
  discover = function(ctx, inputs, opts)
    local files_asset = nil
    for _, a in ipairs(inputs[1].assets) do
      if a.kind == "files" then
        files_asset = a
        break
      end
    end
    if not files_asset then
      ctx.fail("nvim.discover requires a nvim.layout node as input")
    end

    local out_dir = files_asset.output_path
    local discovery = {
      lua_modules = {},
      plugin_files = {},
      ftplugins = {},
      queries = {},
      docs = {},
      health_checks = {},
    }

    for _, f in ipairs(fs.list_files(out_dir)) do
      local rel = path.relative(f, out_dir)
      if rel:match("^lua/") then
        table.insert(discovery.lua_modules, rel)
      elseif rel:match("^plugin/") then
        table.insert(discovery.plugin_files, rel)
      elseif rel:match("^ftplugin/") then
        table.insert(discovery.ftplugins, rel)
      elseif rel:match("^queries/") then
        table.insert(discovery.queries, rel)
      elseif rel:match("^doc/") then
        table.insert(discovery.docs, rel)
      elseif rel:match("^health/") then
        table.insert(discovery.health_checks, rel)
      end
    end

    local assets = graph.AssetSet.new()
    assets:add(ctx.graph:add_asset({
      kind = "metadata",
      virtual_path = "nvim-discovery.json",
      output_path = path.join(out_dir, "nvim-discovery.json"),
      generated = true,
      content = require("dkjson").encode(discovery) .. "\n",
      metadata = { plugin = "nvim", method = "discover" },
    }))
    return assets
  end,
}

---Build a Neovim external dependency map for nvim.layout.
---Values may be package strings, dependency spec tables, or true to use built-in suggestions.
---@param specs table<string, string|DependencySpec|boolean>|string[]
---@return table<string, DependencySpec>
function nvim_plugin.extern(specs)
  local result = {}
  for key, value in pairs(specs or {}) do
    if type(key) == "number" then
      local name = tostring(value)
      result[name] = normalize_extern_spec(name, true)
    else
      result[key] = normalize_extern_spec(key, value)
    end
  end
  return result
end

return nvim_plugin

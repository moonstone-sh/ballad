---@class LoveOpts
---@field main string path to main.lua (default "main.lua")
---@field conf string|nil path to conf.lua
---@field include? string[] glob patterns for files to include
---@field exclude? string[] glob patterns for files to exclude
---@field out? string output directory (default "dist/love-root")
---@field runtime? string e.g. "love@11.5"
---@field lua_api? string e.g. "love-11"
---@field lua_abi? string e.g. "lua-5.1"

---@class LovePackOpts
---@field out string path to .love file (e.g. "dist/app.love")
---@field tool? string tool to use (default "zip")
---@field deterministic? boolean request deterministic output

local graph = require("ballad.graph")
local fs = require("ballad.fs")
local path = require("ballad.path")
local process = require("ballad.process")

local function local_package_name(name)
  local local_name = name:match("/([^/]+)$") or name
  return (local_name:gsub("%-", "_"))
end

local function export_filter(meta)
  local excluded = {}
  local dependencies = meta.dependencies or {}
  for _, role in ipairs({ "dev", "tool", "peer", "optional" }) do
    for dep_name, _ in pairs(dependencies[role] or {}) do
      excluded[local_package_name(dep_name)] = true
    end
  end

  return function(relative, source)
    local module_name = relative:gsub("%.lua$", ""):gsub("/init$", "")
    local top = module_name:match("^([^/]+)") or module_name
    if excluded[top] then return false end
    for name, _ in pairs(excluded) do
      if source and source:match("/" .. name .. "/src/") then return false end
    end
    return true
  end
end

---Convert a glob pattern to a Lua pattern for matching.
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

return {
  name = "ballad.plugins.love",
  version = "0.1.1",

  methods = {
    layout = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      effects = { "metadata" },
      cacheable = true,
      parallel_safe = true,
    },
    pack = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      effects = { "write" },
      cacheable = true,
      parallel_safe = false,
    },
  },

  ---Arrange project files into a LÖVE-friendly directory layout.
  ---@param ctx PluginCtx
  ---@param inputs AssetSet[]
  ---@param opts LoveOpts
  ---@return AssetSet
  layout = function(ctx, inputs, opts)
    local project_asset = inputs[1].assets[1]
    if not project_asset or project_asset.kind ~= "project" then
      ctx.fail("love.layout requires a moonstone.project node as input")
    end

    local meta = project_asset.metadata
    local root = meta.root
    local main_file = opts.main or "main.lua"
    local main_path = path.join(root, main_file)
    if not fs.read_file(main_path) then
      ctx.fail("love.layout: main.lua not found at " .. main_path)
    end

    if opts.conf then
      local conf_path = path.join(root, opts.conf)
      if not fs.read_file(conf_path) then
        ctx.fail("love.layout: conf.lua not found at " .. conf_path)
      end
    end

    local include_patterns = opts.include
    local exclude_patterns = opts.exclude or {
      ".moonstone/**",
      ".ballad/**",
      "dist/**",
      ".git/**",
    }

    local all_files = fs.list_files(root)
    local included = {}

    for _, f in ipairs(all_files) do
      local rel = path.relative(f, root)
      local should_include = false

      if include_patterns then
        for _, pattern in ipairs(include_patterns) do
          if glob_match(rel, pattern) then
            should_include = true
            break
          end
        end
      else
        should_include = true
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
      end
    end

    local assets = graph.AssetSet.new()
    local should_export = export_filter(meta)

    for _, item in ipairs(included) do
      local asset = ctx.graph:add_asset({
        kind = "file",
        source_path = item.src,
        virtual_path = item.rel,
        metadata = { plugin = "love", method = "layout" },
      })
      assets:add(asset)
    end

    -- Lua modules
    local module_root = path.join(meta.root, ".moonstone/env/share/lua", (meta.abi:gsub("^lua%-", ""):gsub("^lua", "")))
    if fs.is_dir(module_root) then
      for _, module_path in ipairs(fs.list_files(module_root)) do
        if fs.is_lua(module_path) then
          local relative = path.relative(module_path, module_root)
          local source = fs.readlink(module_path)
          if should_export(relative, source) then
            assets:add(ctx.graph:add_asset({
              kind = "package",
              source_path = source,
              virtual_path = relative,
              metadata = { plugin = "love", method = "layout", dependency = true },
            }))
          end
        end
      end
    end

    -- C modules
    local lib_module_root = path.join(meta.root, ".moonstone/env/lib/lua", (meta.abi:gsub("^lua%-", ""):gsub("^lua", "")))
    if fs.is_dir(lib_module_root) then
      for _, module_path in ipairs(fs.list_files(lib_module_root)) do
        if fs.is_binary_module(module_path) then
          local relative = path.relative(module_path, lib_module_root)
          local source = fs.readlink(module_path)
          if should_export(relative, source) then
            assets:add(ctx.graph:add_asset({
              kind = "package",
              source_path = source,
              virtual_path = relative,
              metadata = { plugin = "love", method = "layout", dependency = true },
            }))
          end
        end
      end
    end

    assets:add(ctx.graph:add_asset({
      kind = "files",
      virtual_path = "love-root",
      metadata = {
        name = meta.manifest and meta.manifest.package and meta.manifest.package.name or "app",
        entry = main_file,
        libexec_root = "",
        bin_name = meta.manifest and meta.manifest.package and meta.manifest.package.name or "app",
        layout = "love",
        kind = "app",
        artifact_kind = "lua_module",
        main = main_file,
        conf = opts.conf,
        runtime = opts.runtime or "love@11.5",
        lua_api = opts.lua_api or "love-11",
        lua_abi = opts.lua_abi or "5.1",
      },
    }))

    return assets
  end,

  ---Pack a LÖVE layout into a deterministic .love zip archive.
  ---@param ctx PluginCtx
  ---@param inputs AssetSet[]
  ---@param opts LovePackOpts
  ---@return AssetSet
  pack = function(ctx, inputs, opts)
    local files_asset = nil
    for _, a in ipairs(inputs[1].assets) do
      if a.kind == "files" then
        files_asset = a
        break
      end
    end
    if not files_asset then
      ctx.fail("love.pack requires a love.layout node as input")
    end

    local out_file = opts.out or ("dist/" .. (files_asset.metadata.name or "app") .. ".love")

    local use_deterministic = opts.deterministic ~= false

    if not use_deterministic then
      -- Fallback: system zip via native_task
      local abs_out = path.absolute(out_file)
      local staging = ".ballad/tmp/love-pack-" .. tostring(ctx.node.id)
      fs.remove_tree(staging)
      fs.mkdir(staging)
      for _, asset in ipairs(inputs[1].assets) do
        if asset.kind ~= "files" and asset.kind ~= "project" and asset.source_path then
          fs.copy_file(asset.source_path, path.join(staging, asset.virtual_path or path.basename(asset.source_path)))
        elseif asset.kind ~= "files" and asset.kind ~= "project" and asset.generated and asset.content then
          local dest = path.join(staging, asset.virtual_path or asset.id)
          fs.mkdir(path.dirname(dest))
          fs.write_file(dest, asset.content)
        end
      end
      return ctx:native_task({
        id = "love.pack",
        tool = opts.tool or "zip",
        args = { "-r", abs_out, "." },
        cwd = staging,
        outputs = { out_file },
        cacheable = true,
        parallel_safe = false,
        description = "Create .love archive (system zip)",
      })
    end

    -- Deterministic zip writer
    local archive = require("ballad.archive")
    local entries = {}
    for _, asset in ipairs(inputs[1].assets) do
      if asset.kind ~= "files" and asset.kind ~= "project" then
        table.insert(entries, {
          path = asset.virtual_path or asset.id,
          src = asset.source_path,
          data = asset.content,
        })
      end
    end

    fs.mkdir(path.dirname(out_file))
    archive.zip_store(entries, out_file, { deterministic = true })

    local assets = graph.AssetSet.new()
    assets:add(ctx.graph:add_asset({
      kind = "generated",
      virtual_path = out_file,
      output_path = out_file,
      generated = true,
      metadata = {
        plugin = "love",
        method = "pack",
        layout = "love",
        deterministic = true,
      },
    }))
    return assets
  end,
}

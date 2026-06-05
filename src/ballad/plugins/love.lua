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
  version = "0.1.0",

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
    local out_dir = opts.out or "dist/love-root"

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

    fs.remove_tree(out_dir)
    fs.mkdir(out_dir)

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
    for _, item in ipairs(included) do
      local dest = path.join(out_dir, item.rel)
      fs.copy_file(item.src, dest)
      local asset = ctx.graph:add_asset({
        kind = "file",
        source_path = item.src,
        virtual_path = item.rel,
        output_path = dest,
        metadata = { plugin = "love", method = "layout" },
      })
      assets:add(asset)
    end

    assets:add(ctx.graph:add_asset({
      kind = "files",
      virtual_path = out_dir,
      output_path = out_dir,
      metadata = {
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

    local out_dir = files_asset.output_path
    local out_file = opts.out or ("dist/" .. (files_asset.metadata.name or "app") .. ".love")

    local use_deterministic = opts.deterministic ~= false

    if not use_deterministic then
      -- Fallback: system zip via native_task
      local abs_out = path.absolute(out_file)
      return ctx:native_task({
        id = "love.pack",
        tool = opts.tool or "zip",
        args = { "-r", abs_out, "." },
        cwd = out_dir,
        outputs = { out_file },
        cacheable = true,
        parallel_safe = false,
        description = "Create .love archive (system zip)",
      })
    end

    -- Deterministic zip writer
    local archive = require("ballad.archive")
    local entries = {}
    for _, f in ipairs(fs.list_files(out_dir)) do
      local rel = path.relative(f, out_dir)
      table.insert(entries, {
        path = rel,
        src = f,
      })
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

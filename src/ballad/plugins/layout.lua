local graph = require("ballad.graph")
local fs = require("ballad.fs")
local path = require("ballad.path")

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

local function glob_to_pattern(glob)
  local pattern = glob:gsub("([%.%+%-%^%$%(%)%%])", "%%%1")
  pattern = pattern:gsub("%*%*/", ".-/")
  pattern = pattern:gsub("%*%*", ".-")
  pattern = pattern:gsub("%*", "[^/]+")
  return "^" .. pattern .. "$"
end

local function matches_any(file_path, patterns)
  if not patterns then return true end
  for _, glob in ipairs(patterns) do
    if file_path:match(glob_to_pattern(glob)) then return true end
  end
  return false
end

local function is_default_excluded(relative)
  return relative:match("^%.git/")
    or relative:match("^%.moonstone/")
    or relative:match("^%.ballad/")
    or relative:match("^dist/")
    or relative == "moonstone.lock"
end

local function lua_path_prefixes(roots)
  local prefixes = {}
  for _, root in ipairs(roots) do
    if root:sub(1, 1) == "/" or root:match("^%.%.?/") or root:match("/%.%.?/") then
      error("layout.libexec lua_paths entries must be relative paths")
    end
    table.insert(prefixes, "$LIBEXEC/" .. root .. "/?.lua")
    table.insert(prefixes, "$LIBEXEC/" .. root .. "/?/init.lua")
  end
  return table.concat(prefixes, ";")
end

local function selected_package_roots(meta, names)
  if not names then return nil end
  local selected = {}
  for _, name in ipairs(names) do selected[name] = true end
  local roots = {}
  for _, package in ipairs(meta.packages or {}) do
    if selected[package.name] and package.artifact_path then
      table.insert(roots, package.artifact_path)
    end
  end
  return roots
end

local function source_is_in_roots(source, roots)
  if not roots then return true end
  for _, root in ipairs(roots) do
    if source == root or source:sub(1, #root + 1) == root .. "/" then return true end
  end
  return false
end

local function build_libexec_layout(ctx, inputs, opts, method_name, layout_name)
  opts = opts or {}
  local project_asset = inputs[1].assets[1]
  if not project_asset or project_asset.kind ~= "project" then
    ctx.fail("layout." .. method_name .. " requires a moonstone.project node as input")
  end
  local meta = project_asset.metadata
  local should_export = export_filter(meta)
  local libexec_root = "libexec/" .. (opts.name or "app")
  local bin_name = opts.bin or opts.name or "app"
  local entry = opts.entry or "src/main.lua"
  local interpreter = opts.interpreter or "lua"
  local runnable = opts.runnable
  if runnable == nil then runnable = true end
  local lua_paths = opts.lua_paths or { "lua", "src" }
  local package_roots = selected_package_roots(meta, opts.packages)
  local files = {}
  local destinations = {}
  local function add_file(task)
    if destinations[task.dest] then
      error("destination collision: " .. task.dest)
    end
    destinations[task.dest] = task.src or "generated"
    table.insert(files, task)
  end
  for _, source in ipairs(fs.list_files(meta.root)) do
    local relative = path.relative(source, meta.root)
    if not is_default_excluded(relative) and matches_any(relative, opts.include) and not (opts.exclude and matches_any(relative, opts.exclude)) then
      add_file({ src = source, dest = libexec_root .. "/" .. relative, kind = "project" })
    end
  end
  local module_root = path.join(meta.root, ".moonstone/env/share/lua", path.abi_directory(meta.abi))
  if fs.is_dir(module_root) then
    for _, module_path in ipairs(fs.list_files(module_root)) do
      if fs.is_lua(module_path) then
        local relative = path.relative(module_path, module_root)
        local source = fs.readlink(module_path)
        if should_export(relative, source) and source_is_in_roots(source, package_roots) then
          add_file({ src = source, dest = libexec_root .. "/lua/" .. relative, kind = "package" })
        end
      end
    end
  end
  local lib_module_root = path.join(meta.root, ".moonstone/env/lib/lua", path.abi_directory(meta.abi))
  if fs.is_dir(lib_module_root) then
    for _, module_path in ipairs(fs.list_files(lib_module_root)) do
      if fs.is_binary_module(module_path) then
        local relative = path.relative(module_path, lib_module_root)
        local source = fs.readlink(module_path)
        if should_export(relative, source) and source_is_in_roots(source, package_roots) then
          add_file({ src = source, dest = libexec_root .. "/lib/" .. relative, kind = "package" })
        end
      end
    end
  end
  if opts.bundle_runtime or opts.bundle_interpreter then
    local rt = meta.runtime or {}
    local art_path = meta.runtime_path or rt.artifact_path
    if art_path and type(rt.bin) == "table" then
      for bin_key, rel_path in pairs(rt.bin) do
        local abs_src = path.join(art_path, rel_path)
        if fs.is_file(abs_src) then
          add_file({ src = abs_src, dest = "bin/" .. bin_key, kind = "package", executable = true })
        end
      end
    else
      local env_bin_dir = path.join(meta.root, ".moonstone/env/bin")
      for _, rt_name in ipairs({ "lua", "luajit", "lua.exe", "luajit.exe" }) do
        local bfile = path.join(env_bin_dir, rt_name)
        local target = fs.readlink(bfile)
        if target and target ~= bfile and fs.is_file(target) then
          add_file({ src = target, dest = "bin/" .. rt_name, kind = "package", executable = true })
        elseif fs.is_file(bfile) then
          add_file({ src = bfile, dest = "bin/" .. rt_name, kind = "package", executable = true })
        end
      end
    end
  end
  if runnable then
    local launcher_parts = {
      "#!/usr/bin/env sh",
      "set -eu",
      'ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"',
      'LIBEXEC="$ROOT/' .. libexec_root .. '"',
      'if [ -x "$ROOT/bin/lua" ]; then',
      '  LUA_BIN="$ROOT/bin/lua"',
      'elif [ -x "$ROOT/bin/luajit" ]; then',
      '  LUA_BIN="$ROOT/bin/luajit"',
      "else",
      '  LUA_BIN="${BALLAD_LUA:-' .. interpreter .. '}"',
      "fi",
      'export LUA_PATH="' .. lua_path_prefixes(lua_paths) .. ';${LUA_PATH:-};;"',
      'export LUA_CPATH="$LIBEXEC/lib/?.so;$LIBEXEC/lib/?.dylib;$LIBEXEC/lib/?.dll;${LUA_CPATH:-};;"',
      'exec "$LUA_BIN" "$LIBEXEC/' .. entry .. '" "$@"',
    }
    local launcher = table.concat(launcher_parts, "\n") .. "\n"
    add_file({ dest = "bin/" .. bin_name, content = launcher, kind = "generated", executable = true })
  end
  local assets = graph.AssetSet.new()
  for _, task in ipairs(files) do
    local asset = ctx.graph:add_asset({
      kind = task.kind,
      source_path = task.src,
      virtual_path = task.dest,
      content = task.content,
      generated = task.kind == "generated",
      metadata = {
        executable = task.executable == true,
      },
    })
    assets:add(asset)
  end
  assets:add(ctx.graph:add_asset({
    kind = "files",
    virtual_path = layout_name .. "-root",
    metadata = {
      layout = layout_name,
      libexec_root = libexec_root,
      bin_name = runnable and bin_name or nil,
      entry = entry,
      kind = "bin",
      dependencies = meta.dependencies,
    },
  }))
  assets:add(inputs[1].assets[1])
  return assets
end

local function build_tool_exec_layout(ctx, inputs, opts)
  opts = opts or {}
  local tool_asset = nil
  for _, asset in ipairs(inputs[1].assets or {}) do
    if asset.kind == "tool" and asset.metadata and asset.metadata.kind == "moonstone_tool" then
      tool_asset = asset
      break
    end
  end
  if not tool_asset then ctx.fail("layout.exec requires a moonstone.tool node") end

  local tool = tool_asset.metadata
  local name = opts.name or tool.name
  local bin_name = opts.bin or name
  local libexec_root = "libexec/" .. name
  local assets = graph.AssetSet.new()
  local destinations = {}
  for _, asset in ipairs(inputs[1].assets) do
    if asset.kind == "tool_source" and asset.source_path and asset.virtual_path then
      local destination = libexec_root .. "/" .. asset.virtual_path
      if not destinations[destination] then
        destinations[destination] = true
        assets:add(ctx.graph:add_asset({
          kind = "package",
          source_path = asset.source_path,
          virtual_path = destination,
          metadata = { executable = asset.metadata and asset.metadata.executable == true },
        }))
      end
    end
  end

  local runtime_name = tool.runtime and tool.runtime.name or "lua"
  local launcher = table.concat({
    "#!/usr/bin/env sh",
    "set -eu",
    'ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"',
    'LIBEXEC="$ROOT/' .. libexec_root .. '"',
    'if [ -x "$ROOT/bin/lua" ]; then',
    '  LUA_BIN="$ROOT/bin/lua"',
    'elif [ -x "$ROOT/bin/luajit" ]; then',
    '  LUA_BIN="$ROOT/bin/luajit"',
    "else",
    '  LUA_BIN="${BALLAD_LUA:-' .. runtime_name .. '}"',
    "fi",
    'export PATH="$LIBEXEC/bin:${PATH:-}"',
    'export LUA_PATH="$LIBEXEC/lua/?.lua;$LIBEXEC/lua/?/init.lua;${LUA_PATH:-};;"',
    'export LUA_CPATH="$LIBEXEC/lib/?.so;$LIBEXEC/lib/?.dylib;$LIBEXEC/lib/?.dll;${LUA_CPATH:-};;"',
    'exec "$LUA_BIN" "$LIBEXEC/bin/' .. tool.name .. '" "$@"',
  }, "\n") .. "\n"
  assets:add(ctx.graph:add_asset({
    kind = "generated",
    virtual_path = "bin/" .. bin_name,
    content = launcher,
    generated = true,
    metadata = { executable = true },
  }))
  assets:add(ctx.graph:add_asset({
    kind = "files",
    virtual_path = "tool-exec-root",
    metadata = { layout = "tool_exec", name = name, bin_name = bin_name, entry = "bin/" .. tool.name },
  }))
  assets:add(tool_asset)
  return assets
end

return {
  name = "ballad.plugins.layout",
  version = "0.1.0",
  methods = {
    libexec = {
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
    flat = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      cacheable = false,
      parallel_safe = true,
    },
    love = {
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
  libexec = function(ctx, inputs, opts)
    return build_libexec_layout(ctx, inputs, opts, "libexec", "libexec")
  end,

  ---@param ctx PluginCtx
  ---@param inputs AssetSet[]
  ---@param opts table
  ---@return AssetSet
  exec = function(ctx, inputs, opts)
    opts = opts or {}
    if opts.runnable == nil then opts.runnable = true end
    for _, asset in ipairs(inputs[1].assets or {}) do
      if asset.kind == "tool" and asset.metadata and asset.metadata.kind == "moonstone_tool" then
        return build_tool_exec_layout(ctx, inputs, opts)
      end
    end
    return build_libexec_layout(ctx, inputs, opts, "exec", "exec")
  end,

  ---@param ctx PluginCtx
  ---@param inputs AssetSet[]
  ---@param opts table
  ---@return AssetSet
  flat = function(ctx, inputs, opts)
    local project_asset = inputs[1].assets[1]
    if not project_asset or project_asset.kind ~= "project" then
      ctx.fail("layout.flat requires a moonstone.project node as input")
    end
    local meta = project_asset.metadata
    local should_export = export_filter(meta)

    local entry = opts.entry or "src/main.lua"
    local name = opts.name or meta.manifest and meta.manifest.package and meta.manifest.package.name or "app"
    local package_kind = opts.kind or (meta.manifest and meta.manifest.package and meta.manifest.package.kind) or "script"
    local bin_name = opts.bin or "run"
    local interpreter = opts.interpreter or "lua"
    local runnable = opts.runnable
    if runnable == nil then
      runnable = package_kind == "script" or package_kind == "bin" or opts.bin ~= nil
    end
    local assets = graph.AssetSet.new()

    -- Project files at root-relative virtual paths
    for _, source in ipairs(fs.list_files(meta.root)) do
      local relative = path.relative(source, meta.root)
      if not (relative:match("^%.git/") or relative:match("^%.moonstone/") or relative:match("^%.ballad/") or relative:match("^dist/") or relative == "moonstone.lock") then
        local asset = ctx.graph:add_asset({
          kind = "project",
          source_path = source,
          virtual_path = relative,
        })
        assets:add(asset)
      end
    end

    -- Lua modules mapped to lua/
    local module_root = path.join(meta.root, ".moonstone/env/share/lua", path.abi_directory(meta.abi))
    if fs.is_dir(module_root) then
      for _, module_path in ipairs(fs.list_files(module_root)) do
        if fs.is_lua(module_path) then
          local relative = path.relative(module_path, module_root)
          local source = fs.readlink(module_path)
          if should_export(relative, source) then
            local asset = ctx.graph:add_asset({
              kind = "package",
              source_path = source,
              virtual_path = "lua/" .. relative,
            })
            assets:add(asset)
          end
        end
      end
    end

    -- C modules mapped to lib/
    local lib_module_root = path.join(meta.root, ".moonstone/env/lib/lua", path.abi_directory(meta.abi))
    if fs.is_dir(lib_module_root) then
      for _, module_path in ipairs(fs.list_files(lib_module_root)) do
        if fs.is_binary_module(module_path) then
          local relative = path.relative(module_path, lib_module_root)
          local source = fs.readlink(module_path)
          if should_export(relative, source) then
            local asset = ctx.graph:add_asset({
              kind = "package",
              source_path = source,
              virtual_path = "lib/" .. relative,
            })
            assets:add(asset)
          end
        end
      end
    end

    if runnable then
      local launcher = table.concat({
        "#!/usr/bin/env sh",
        "set -eu",
        'ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"',
        'if [ -x "$ROOT/bin/lua" ]; then',
        '  LUA_BIN="$ROOT/bin/lua"',
        'elif [ -x "$ROOT/bin/luajit" ]; then',
        '  LUA_BIN="$ROOT/bin/luajit"',
        "else",
        '  LUA_BIN="${BALLAD_LUA:-' .. interpreter .. '}"',
        "fi",
        'export LUA_PATH="$ROOT/lua/?.lua;$ROOT/lua/?/init.lua;$ROOT/src/?.lua;$ROOT/src/?/init.lua;${LUA_PATH:-};;"',
        'export LUA_CPATH="$ROOT/lib/?.so;$ROOT/lib/?.dylib;$ROOT/lib/?.dll;$ROOT/lib/?/?.so;$ROOT/lib/?/?.dylib;$ROOT/lib/?/?.dll;${LUA_CPATH:-};;"',
        'exec "$LUA_BIN" "$ROOT/' .. entry .. '" "$@"',
      }, "\n") .. "\n"
      assets:add(ctx.graph:add_asset({
        kind = "generated",
        virtual_path = bin_name,
        content = launcher,
        generated = true,
      }))
    end

    assets:add(ctx.graph:add_asset({
      kind = "files",
      virtual_path = "flat-root",
      metadata = {
        layout = "flat",
        entry = entry,
        name = name,
        bin_name = runnable and bin_name or nil,
        kind = package_kind,
        dependencies = meta.dependencies,
      },
    }))
    -- Preserve the original project asset so downstream nodes can access project metadata
    assets:add(inputs[1].assets[1])
    return assets
  end,
}

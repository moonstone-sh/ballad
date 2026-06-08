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
    local project_asset = inputs[1].assets[1]
    if not project_asset or project_asset.kind ~= "project" then
      ctx.fail("layout.libexec requires a moonstone.project node as input")
    end
    local meta = project_asset.metadata
    local should_export = export_filter(meta)
    local out_dir = opts.out or "dist/ballad"
    fs.remove_tree(out_dir)
    fs.mkdir(out_dir)
    local libexec_root = "libexec/" .. (opts.name or "app")
    local bin_name = opts.bin or opts.name or "app"
    local entry = opts.entry or "src/main.lua"
    local interpreter = opts.interpreter or "lua"
    local files = {}
    local destinations = {}
    local function add_file(task)
      if destinations[task.dest] then
        error("destination collision: " .. task.dest)
      end
      destinations[task.dest] = task.src or "generated"
      if task.kind == "generated" then
        fs.mkdir(path.dirname(path.join(out_dir, task.dest)))
        fs.write_file(path.join(out_dir, task.dest), task.content)
      else
        fs.copy_file(task.src, path.join(out_dir, task.dest))
      end
      table.insert(files, task)
    end
    for _, source in ipairs(fs.list_files(meta.root)) do
      local relative = path.relative(source, meta.root)
      if not (relative:match("^%.git/") or relative:match("^%.moonstone/") or relative:match("^%.ballad/") or relative:match("^dist/") or relative == "moonstone.lock") then
        add_file({ src = source, dest = libexec_root .. "/" .. relative, kind = "project" })
      end
    end
    local module_root = path.join(meta.root, ".moonstone/env/share/lua", path.abi_directory(meta.abi))
    if fs.is_dir(module_root) then
      for _, module_path in ipairs(fs.list_files(module_root)) do
        if fs.is_lua(module_path) then
          local relative = path.relative(module_path, module_root)
          local source = fs.readlink(module_path)
          if should_export(relative, source) then
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
          if should_export(relative, source) then
            add_file({ src = source, dest = libexec_root .. "/lib/" .. relative, kind = "package" })
          end
        end
      end
    end
    local launcher_parts = {
      "#!/usr/bin/env sh",
      "set -eu",
      'ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"',
      'LIBEXEC="$ROOT/' .. libexec_root .. '"',
      'export LUA_PATH="$LIBEXEC/lua/?.lua;$LIBEXEC/lua/?/init.lua;$LIBEXEC/src/?.lua;$LIBEXEC/src/?/init.lua;${LUA_PATH:-};;"',
      'export LUA_CPATH="$LIBEXEC/lib/?.so;$LIBEXEC/lib/?.dylib;$LIBEXEC/lib/?.dll;${LUA_CPATH:-};;"',
      'exec ' .. interpreter .. ' "$LIBEXEC/' .. entry .. '" "$@"',
    }
    local launcher = table.concat(launcher_parts, "\n") .. "\n"
    add_file({ dest = "bin/" .. bin_name, content = launcher, kind = "generated" })
    fs.chmod(path.join(out_dir, "bin/" .. bin_name), "+x")
    local assets = graph.AssetSet.new()
    for _, task in ipairs(files) do
      local asset = ctx.graph:add_asset({
        kind = task.kind,
        source_path = task.src,
        virtual_path = task.dest,
        output_path = path.join(out_dir, task.dest),
        content = task.content,
        generated = task.kind == "generated",
      })
      assets:add(asset)
    end
    assets:add(ctx.graph:add_asset({
      kind = "files",
      virtual_path = out_dir,
      output_path = out_dir,
      metadata = {
        layout = "libexec",
        libexec_root = libexec_root,
        bin_name = bin_name,
        entry = entry,
      },
    }))
    return assets
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

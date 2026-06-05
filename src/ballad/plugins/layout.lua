local graph = require("ballad.graph")
local fs = require("ballad.fs")
local path = require("ballad.path")

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
      if not (relative:match("^%%.git/") or relative:match("^%%.moonstone/") or relative:match("^%%.ballad/") or relative:match("^dist/") or relative == "moonstone.lock") then
        add_file({ src = source, dest = libexec_root .. "/" .. relative, kind = "project" })
      end
    end
    local module_root = path.join(meta.root, ".moonstone/env/share/lua", path.abi_directory(meta.abi))
    if fs.is_dir(module_root) then
      for _, module_path in ipairs(fs.list_files(module_root)) do
        if fs.is_lua(module_path) then
          local relative = path.relative(module_path, module_root)
          local source = fs.readlink(module_path)
          add_file({ src = source, dest = libexec_root .. "/lua/" .. relative, kind = "package" })
        end
      end
    end
    local lib_module_root = path.join(meta.root, ".moonstone/env/lib/lua", path.abi_directory(meta.abi))
    if fs.is_dir(lib_module_root) then
      for _, module_path in ipairs(fs.list_files(lib_module_root)) do
        if fs.is_binary_module(module_path) then
          local relative = path.relative(module_path, lib_module_root)
          local source = fs.readlink(module_path)
          add_file({ src = source, dest = libexec_root .. "/lib/" .. relative, kind = "package" })
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
    error("layout.flat not yet implemented")
  end,
}

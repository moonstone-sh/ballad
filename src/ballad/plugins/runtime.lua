local graph = require("ballad.graph")
local fs = require("ballad.fs")
local path = require("ballad.path")
local dkjson = require("dkjson")

local runtime = {
  name = "ballad.plugins.runtime",
  version = "0.2.0",
  methods = {
    wrap = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      cacheable = false,
      parallel_safe = true,
    },
    bundle = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      cacheable = false,
      parallel_safe = true,
    },
  },
}

local function copy_input_assets(ctx, input)
  local assets = graph.AssetSet.new()
  for _, asset in ipairs(input.assets or {}) do
    assets:add(asset)
  end
  return assets
end

local function find_project_asset(input)
  for _, asset in ipairs(input.assets or {}) do
    if asset.kind == "project" and asset.metadata and (asset.virtual_path == nil or asset.metadata.kind == "moonstone_project" or asset.metadata.manifest) then
      return asset
    end
  end
  return nil
end

local function find_layout_metadata(input)
  for _, asset in ipairs(input.assets or {}) do
    if asset.kind == "files" and asset.metadata then
      return asset.metadata
    end
  end
  return {}
end

local function default_entry(layout_meta)
  if layout_meta.layout == "libexec" then
    return path.join(layout_meta.libexec_root or "libexec/app", layout_meta.entry or "src/main.lua")
  end
  return layout_meta.entry or "src/main.lua"
end

local function default_lua_roots(layout_meta)
  if layout_meta.layout == "libexec" then
    local root = layout_meta.libexec_root or "libexec/app"
    return { path.join(root, "lua"), path.join(root, "src") }
  end
  return { "lua", "src" }
end

local function default_cpath_roots(layout_meta)
  if layout_meta.layout == "libexec" then
    return { path.join(layout_meta.libexec_root or "libexec/app", "lib") }
  end
  return { "lib", "clib" }
end

local function lua_path_expr(roots)
  local parts = {}
  for _, root in ipairs(roots) do
    parts[#parts + 1] = "$SELF_DIR/" .. root .. "/?.lua"
    parts[#parts + 1] = "$SELF_DIR/" .. root .. "/?/init.lua"
  end
  parts[#parts + 1] = "${LUA_PATH:-}"
  parts[#parts + 1] = ";"
  return table.concat(parts, ";")
end

local function lua_cpath_expr(roots)
  local parts = {}
  for _, root in ipairs(roots) do
    parts[#parts + 1] = "$SELF_DIR/" .. root .. "/?.so"
    parts[#parts + 1] = "$SELF_DIR/" .. root .. "/?.dylib"
    parts[#parts + 1] = "$SELF_DIR/" .. root .. "/?.dll"
    parts[#parts + 1] = "$SELF_DIR/" .. root .. "/?/?.so"
    parts[#parts + 1] = "$SELF_DIR/" .. root .. "/?/?.dylib"
    parts[#parts + 1] = "$SELF_DIR/" .. root .. "/?/?.dll"
  end
  parts[#parts + 1] = "${LUA_CPATH:-}"
  parts[#parts + 1] = ";"
  return table.concat(parts, ";")
end

local function win_path(value)
  return (value:gsub("/", "\\"))
end

local function win_lua_path_expr(roots)
  local parts = {}
  for _, root in ipairs(roots) do
    local win_root = win_path(root)
    parts[#parts + 1] = "%SELF_DIR%" .. win_root .. "\\?.lua"
    parts[#parts + 1] = "%SELF_DIR%" .. win_root .. "\\?\\init.lua"
  end
  parts[#parts + 1] = "%LUA_PATH%"
  parts[#parts + 1] = ";"
  return table.concat(parts, ";")
end

local function win_lua_cpath_expr(roots)
  local parts = {}
  for _, root in ipairs(roots) do
    local win_root = win_path(root)
    parts[#parts + 1] = "%SELF_DIR%" .. win_root .. "\\?.dll"
    parts[#parts + 1] = "%SELF_DIR%" .. win_root .. "\\?\\?.dll"
  end
  parts[#parts + 1] = "%LUA_CPATH%"
  parts[#parts + 1] = ";"
  return table.concat(parts, ";")
end

local function preferred_runtime_bin(source, command)
  if command and command ~= "" then return command end
  local bin = source and source.bin or {}
  return bin.lua or bin.luajit or bin[source and source.name or ""] or "files/bin/lua"
end

local function shipped_runtime_path(source, command)
  local bin = preferred_runtime_bin(source, command)
  if bin:match("^files/") then bin = bin:sub(#"files/" + 1) end
  return "runtime/" .. bin
end

local function add_runtime_assets(ctx, assets, source)
  local artifact_path = source and source.artifact_path
  if not artifact_path or artifact_path == "" then
    ctx.fail("runtime.wrap mode=ship requires source.artifact_path")
  end

  local files_root = path.join(artifact_path, "files")
  if not fs.is_dir(files_root) then
    ctx.fail("runtime.wrap: runtime artifact not found at " .. files_root)
  end

  for _, source_file in ipairs(fs.list_files(files_root)) do
    local relative = path.relative(source_file, files_root)
    assets:add(ctx.graph:add_asset({
      kind = "runtime",
      source_path = source_file,
      virtual_path = path.join("runtime", relative),
      metadata = {
        runtime = source.name,
        version = source.version,
        artifact_hash = source.artifact_hash,
      },
    }))
  end
end

local function unix_launcher(opts)
  local mode = opts.mode
  local command = opts.command or "lua"
  local shipped = opts.shipped_runtime
  local lua_expr
  if mode == "ship" then
    lua_expr = 'LUA="$SELF_DIR/' .. shipped .. '"'
  elseif mode == "fallback" then
    lua_expr = table.concat({
      'if [ -x "$SELF_DIR/' .. shipped .. '" ]; then',
      '  LUA="$SELF_DIR/' .. shipped .. '"',
      "else",
      '  LUA="${BALLAD_LUA:-' .. command .. '}"',
      "fi",
    }, "\n")
  else
    lua_expr = 'LUA="${BALLAD_LUA:-' .. command .. '}"'
  end

  return table.concat({
    "#!/usr/bin/env sh",
    "set -eu",
    'SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"',
    lua_expr,
    'export LUA_PATH="' .. opts.lua_path .. '"',
    'export LUA_CPATH="' .. opts.lua_cpath .. '"',
    'exec "$LUA" "$SELF_DIR/' .. opts.entry .. '" "$@"',
  }, "\n") .. "\n"
end

local function windows_launcher(opts)
  local mode = opts.mode
  local command = opts.command or "lua"
  local shipped = win_path(opts.shipped_runtime or "runtime/bin/lua.exe")
  local entry = win_path(opts.entry)
  local lua_lines
  if mode == "ship" then
    lua_lines = 'set "LUA=%SELF_DIR%' .. shipped .. '"'
  elseif mode == "fallback" then
    lua_lines = table.concat({
      'if exist "%SELF_DIR%' .. shipped .. '" (',
      '  set "LUA=%SELF_DIR%' .. shipped .. '"',
      ") else (",
      '  if "%BALLAD_LUA%"=="" (set "LUA=' .. command .. '") else (set "LUA=%BALLAD_LUA%")',
      ")",
    }, "\r\n")
  else
    lua_lines = 'if "%BALLAD_LUA%"=="" (set "LUA=' .. command .. '") else (set "LUA=%BALLAD_LUA%")'
  end

  return table.concat({
    "@echo off",
    "setlocal",
    "set SELF_DIR=%~dp0",
    lua_lines,
    'set "LUA_PATH=' .. opts.win_lua_path .. '"',
    'set "LUA_CPATH=' .. opts.win_lua_cpath .. '"',
    '"%LUA%" "%SELF_DIR%' .. entry .. '" %*',
  }, "\r\n") .. "\r\n"
end

local function wrap_impl(ctx, inputs, opts)
  opts = opts or {}
  local input = inputs[1]
  local mode = opts.mode or (opts.enabled == false and "none") or "ship"
  if opts.include_runtime == false or opts.mode == "external" then mode = "global" end

  local assets = copy_input_assets(ctx, input)
  if mode == "none" then return assets end

  local project_asset = find_project_asset(input)
  if not project_asset then
    ctx.fail("runtime.wrap requires a moonstone.project node as input")
  end

  local layout_meta = find_layout_metadata(input)
  local project_runtime = project_asset.metadata and project_asset.metadata.runtime or nil
  local source = opts.source or project_runtime
  local command = opts.command or (source and source.name) or "lua"
  local shipped = source and shipped_runtime_path(source, opts.runtime_bin) or "runtime/bin/lua"

  if mode == "ship" or mode == "fallback" then
    if not source then ctx.fail("runtime.wrap mode=" .. mode .. " requires opts.source or project.runtime") end
    add_runtime_assets(ctx, assets, source)
  end

  local shim = opts.shim
  if shim == nil then shim = true end
  if not shim then return assets end

  local entry = opts.entry or default_entry(layout_meta)
  local launcher = opts.launcher or opts.bin or "run"
  local lua_roots = opts.lua_roots or default_lua_roots(layout_meta)
  local cpath_roots = opts.cpath_roots or default_cpath_roots(layout_meta)
  local launcher_meta = {
    name = launcher,
    kind = "shell",
    entry = entry,
    runtime = mode == "global" and command or shipped,
    mode = mode,
    env = {
      LUA_PATH = lua_path_expr(lua_roots),
      LUA_CPATH = lua_cpath_expr(cpath_roots),
    },
  }

  assets:add(ctx.graph:add_asset({
    kind = "generated",
    virtual_path = launcher,
    content = unix_launcher({
      mode = mode,
      command = command,
      shipped_runtime = shipped,
      entry = entry,
      lua_path = launcher_meta.env.LUA_PATH,
      lua_cpath = launcher_meta.env.LUA_CPATH,
    }),
    generated = true,
    metadata = { executable = true, launcher = launcher_meta },
  }))

  if opts.windows ~= false then
    assets:add(ctx.graph:add_asset({
      kind = "generated",
      virtual_path = launcher .. ".bat",
      content = windows_launcher({
        mode = mode,
        command = command,
        shipped_runtime = shipped,
        entry = entry,
        win_lua_path = win_lua_path_expr(lua_roots),
        win_lua_cpath = win_lua_cpath_expr(cpath_roots),
      }),
      generated = true,
      metadata = { launcher = launcher_meta },
    }))
  end

  assets:add(ctx.graph:add_asset({
    kind = "generated",
    virtual_path = "ballad-manifest.json",
    content = dkjson.encode({
      runtime = {
        mode = mode,
        id = source and source.id or nil,
        name = source and source.name or nil,
        version = source and source.version or nil,
        artifact_hash = source and source.artifact_hash or nil,
        shipped = mode == "ship" or mode == "fallback",
        path = mode == "global" and command or shipped,
      },
      launchers = { launcher_meta },
    }, { indent = true }) .. "\n",
    generated = true,
    metadata = { kind = "ballad_manifest" },
  }))

  assets:add(ctx.graph:add_asset({
    kind = "files",
    virtual_path = "runtime-wrapped-root",
    metadata = {
      layout = "runtime_wrapped",
      runtime = source,
      launchers = { launcher_meta },
    },
  }))

  return assets
end

function runtime.wrap(ctx, inputs, opts)
  return wrap_impl(ctx, inputs, opts)
end

function runtime.bundle(ctx, inputs, opts)
  return wrap_impl(ctx, inputs, opts)
end

return runtime

local fs = require("ballad.fs")
local path = require("ballad.path")
local flavor = require("ballad.flavor")
local selection = {}

-- Follow the module provisions used by Moonstone projection. Copied environments
-- carry the same module names, but cannot reveal ownership through readlink().
function selection.new(meta, names)
  if not names then return function() return true end end
  local wanted, roots, candidates, modules = {}, {}, {}, {lua_modules={},lua_cmodules={}}
  for _, name in ipairs(names) do wanted[name] = true end
  for _, package in ipairs(meta.packages or {}) do
    if wanted[package.name] and package.artifact_path then
      roots[#roots+1] = package.artifact_path:gsub("\\", "/")
      -- Older artifacts also expose modules through Moonstone's layout fallback.
      -- Verify copied files against their immutable payload, rather than guessing
      -- ownership from the package name or requiring symlink privileges.
      if require("ballad.process").is_windows() then
        for _, source in ipairs(fs.list_files(path.join(package.artifact_path,"files"))) do
          if fs.is_lua(source) or fs.is_binary_module(source) then
            local key = path.basename(flavor.module_file(source)):gsub("%.so$", ".dll"):gsub("%.dylib$", ".dll")
            candidates[key] = candidates[key] or {}
            table.insert(candidates[key], source)
          end
        end
      end
      local provisions = package.store_query and package.store_query.provisions
      if provisions then
        for kind, entries in pairs(modules) do
          for _, provision in ipairs(provisions[kind] or {}) do
            local source = (provision.path or ""):gsub("^%${build}/", "")
            local relative = source:match("share/lua/[^/]+/(.+)$")
              or (kind == "lua_cmodules" and source:match("lib/lua/[^/]+/(.+)$"))
            if not relative then
              local name = provision.name
              if kind == "lua_cmodules" then
                name = name:gsub("%.dll$", ""):gsub("%.so$", ""):gsub("%.dylib$", "")
                relative = name:gsub("%.", "/") .. ".dll"
              elseif name:find("/",1,true) then relative = name
              else relative = name:gsub("%.lua$", ""):gsub("%.", "/") end
            end
            local directory = fs.is_dir(path.join(package.artifact_path,"files",source))
            if kind == "lua_modules" and not directory and not relative:match("%.lua$") then relative = relative .. ".lua" end
            if kind == "lua_cmodules" then relative = relative:gsub("%.so$", ".dll"):gsub("%.dylib$", ".dll") end
            entries[#entries+1] = {relative=relative,directory=directory}
          end
        end
      end
    end
  end
  return function(source, relative, kind)
    source = source:gsub("\\", "/")
    for _, root in ipairs(roots) do
      if source == root or source:sub(1,#root+1) == root .. "/" then return true end
    end
    relative = flavor.module_file(relative)
    if kind == "lua_cmodules" then relative = relative:gsub("%.so$", ".dll"):gsub("%.dylib$", ".dll") end
    for _, entry in ipairs(modules[kind]) do
      if relative == entry.relative or (entry.directory and relative:sub(1,#entry.relative+1) == entry.relative .. "/") then return true end
    end
    local key = path.basename(relative)
    for _, candidate in ipairs(candidates[key] or {}) do
      local expected = fs.read_file(candidate)
      if expected and expected == fs.read_file(source) then return true end
    end
    return false
  end
end
return selection

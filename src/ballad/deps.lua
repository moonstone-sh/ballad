local deps = {}

---Extract require(...) calls from Lua source text.
---Handles: require("mod"), require 'mod', require([[mod]])
---@param source string Lua source text
---@return string[] list of required module names
function deps.extract_requires(source)
  local requires = {}
  -- require("mod")
  for mod in source:gmatch('require%s*%(%s*["\']([^"\']+)["\']%s*%)') do
    table.insert(requires, mod)
  end
  -- require 'mod'  (single quotes)
  for mod in source:gmatch('require%s+["\']([^"\']+)["\']') do
    table.insert(requires, mod)
  end
  -- require [[mod]]
  for mod in source:gmatch('require%s*%[%[(.-)%]%]') do
    table.insert(requires, mod)
  end
  -- require([=[mod]=])
  for mod in source:gmatch('require%s*%[%[(=+)%[(.-)%]%1%]%]') do
    table.insert(requires, mod)
  end
  return requires
end

---Classify a required module name given the plugin's dependency map and internal modules.
---@param mod string module name from require()
---@param internal_modules table<string, boolean> set of modules provided by the plugin itself
---@param dependency_map table<string, DependencySpec> user-declared dependencies
---@return string role one of: "internal", "peer", "optional", "runtime", "dev", "tool", "unknown"
---@return string|nil package_ref package reference if declared
---@return string|nil constraint version constraint if declared
function deps.classify(mod, internal_modules, dependency_map)
  -- Internal modules come first: exact match or prefix
  for internal_mod in pairs(internal_modules) do
    if mod == internal_mod or mod:sub(1, #internal_mod + 1) == internal_mod .. "." then
      return "internal", nil, nil
    end
  end

  -- Check declared dependency map (exact match or prefix)
  for dep_name, spec in pairs(dependency_map) do
    if mod == dep_name or mod:sub(1, #dep_name + 1) == dep_name .. "." then
      local role = spec.role or "runtime"
      return role, spec.package, spec.constraint
    end
  end

  return "unknown", nil, nil
end

---Build a set of internal modules from a list of exported Lua file paths.
---@param lua_files string[] list of relative paths like "lua/my_plugin/init.lua"
---@return table<string, boolean> module names
function deps.build_internal_modules(lua_files)
  local modules = {}
  for _, rel in ipairs(lua_files) do
    local mod = rel:gsub("^lua/", ""):gsub("/init%.lua$", ""):gsub("/", "."):gsub("%.lua$", "")
    modules[mod] = true
  end
  return modules
end

---Scan a directory for Lua files and extract all require() calls.
---@param dir string directory to scan
---@param root string project root for relative paths
---@return table<string, string[]> map of relative path -> list of required modules
function deps.scan_requires(dir, root)
  local fs = require("ballad.fs")
  local path = require("ballad.path")
  local results = {}
  for _, f in ipairs(fs.list_files(dir)) do
    if f:match("%.lua$") then
      local rel = path.relative(f, root)
      local content = fs.read_file(f)
      if content then
        results[rel] = deps.extract_requires(content)
      end
    end
  end
  return results
end

return deps

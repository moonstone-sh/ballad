local fs = require("ballad.fs")
local path = require("ballad.path")
local diagnostic = require("ballad.diagnostic")

local conventions = {}

local DEFAULT_SOURCE_INCLUDES = {
  "moonstone.toml",
  "moonstone.lock",
  "partiture.lua",
  "src/**",
  "lib/**",
  "bin/**",
  "scripts/**",
  "templates/**",
  "docs/**",
  "README.md",
  "REGISTRY_README.md",
  "build.zig",
  "build.zig.zon",
}

local DEFAULT_SOURCE_EXCLUDES = {
  ".meteorite/**",
  ".moonstone/**",
  ".ballad/**",
  ".zig-cache/**",
  "zig-cache/**",
  "zig-out/**",
  "dist/**",
  ".git/**",
  ".DS_Store",
  "**/.DS_Store",
}

local DEFAULT_TREE_EXCLUDES = {
  ".moonstone/**",
  ".ballad/**",
  ".zig-cache/**",
  "zig-cache/**",
  "zig-out/**",
  "dist/**",
  ".git/**",
  ".DS_Store",
  "**/.DS_Store",
}

local function fail(message)
  diagnostic.raise({
    code = "convention_error",
    subject = "source package convention",
    message = message,
  })
end

local function copy_table(value)
  local result = {}
  for key, item in pairs(value or {}) do result[key] = item end
  return result
end

local function copy_array(value)
  local result = {}
  for _, item in ipairs(value or {}) do result[#result + 1] = item end
  return result
end

local function glob_to_pattern(glob)
  local pattern = tostring(glob):gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1")
  pattern = pattern:gsub("%*%*", "\001")
  pattern = pattern:gsub("%*", "[^/]*")
  pattern = pattern:gsub("\001", ".*")
  return "^" .. pattern .. "$"
end

local function matches_any(value, patterns)
  if not patterns or #patterns == 0 then return false end
  for _, pattern in ipairs(patterns) do
    if value:match(glob_to_pattern(pattern)) then return true end
  end
  return false
end

local function require_non_empty(value, label)
  if type(value) ~= "string" or value == "" then fail(label .. " must be a non-empty string") end
  return value
end

local function require_relative(value, label)
  value = require_non_empty(value, label)
  if path.is_absolute(value) or value == ".." or value:match("^%.%./")
      or value:match("/%.%./") or value:match("/%.%.$") then
    fail(label .. " must stay relative to the source package root: " .. value)
  end
  return value
end

local function require_patterns(values, label)
  if values == nil then return {} end
  if type(values) ~= "table" then fail(label .. " must be an array of glob strings") end
  local count = 0
  local maximum = 0
  for key in pairs(values) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
      fail(label .. " must be an array of glob strings")
    end
    count = count + 1
    if key > maximum then maximum = key end
  end
  if maximum ~= count then fail(label .. " must not contain missing array entries") end
  local result = {}
  for index, value in ipairs(values) do
    result[#result + 1] = require_non_empty(value, label .. "[" .. tostring(index) .. "]")
  end
  return result
end

---Declare one explicit materialized file.
---@param name string installed provision name
---@param file_path string source-relative file path
---@return table
function conventions.file(name, file_path)
  return {
    name = require_relative(name, "file name"),
    path = require_relative(file_path, "file path"),
  }
end

---Declare a directory whose files expand into deterministic collection entries.
---@param root string source directory
---@param opts? table { prefix?, strip_prefix?, root_module?, include?, exclude?, overrides? }
---@return table
function conventions.tree(root, opts)
  opts = opts or {}
  if type(opts) ~= "table" then fail("tree options must be a table") end
  local excludes = copy_array(DEFAULT_TREE_EXCLUDES)
  for _, pattern in ipairs(require_patterns(opts.exclude, "tree exclude")) do excludes[#excludes + 1] = pattern end
  if opts.prefix ~= nil then require_relative(opts.prefix, "tree prefix") end
  if opts.strip_prefix ~= nil then require_relative(opts.strip_prefix, "tree strip_prefix") end
  if opts.root_module ~= nil then require_relative(opts.root_module, "tree root_module") end
  if opts.overrides ~= nil and type(opts.overrides) ~= "table" then fail("tree overrides must be a table") end
  for source, target in pairs(opts.overrides or {}) do
    require_relative(source, "tree override source")
    require_relative(target, "tree override target")
  end
  return {
    _ballad_convention = "tree",
    root = require_relative(root, "tree root"),
    prefix = opts.prefix,
    strip_prefix = opts.strip_prefix,
    root_module = opts.root_module,
    include = require_patterns(opts.include, "tree include"),
    exclude = excludes,
    overrides = copy_table(opts.overrides),
  }
end

local function expand_tree(spec, category, project_root)
  local filesystem_root = path.is_absolute(spec.root) and spec.root or path.join(project_root, spec.root)
  if not fs.is_dir(filesystem_root) then
    fail("collect." .. category .. " tree root does not exist: " .. spec.root
      .. " (resolved from project root " .. project_root .. "); create it or remove the tree declaration")
  end

  local entries = {}
  local matched_includes = {}
  local matched_overrides = {}
  for _, file_path in ipairs(fs.list_files(filesystem_root)) do
    local relative = path.relative(file_path, filesystem_root)
    local included = #spec.include == 0 or matches_any(relative, spec.include)
    if included and not matches_any(relative, spec.exclude) then
      local name = spec.overrides[relative]
      if name then matched_overrides[relative] = true end
      for _, pattern in ipairs(spec.include) do
        if relative:match(glob_to_pattern(pattern)) then matched_includes[pattern] = true end
      end
      if not name then
        local mapped_relative = relative
        if spec.strip_prefix and mapped_relative:sub(1, #spec.strip_prefix) == spec.strip_prefix then
          mapped_relative = mapped_relative:sub(#spec.strip_prefix + 1)
        end
        if spec.root_module and relative == spec.root_module then
          name = relative
        elseif spec.prefix and spec.prefix ~= "" then
          name = path.join(spec.prefix, mapped_relative)
        else
          name = mapped_relative
        end
      end
      local source_path = path.is_absolute(spec.root) and file_path or path.join(spec.root, relative)
      entries[#entries + 1] = conventions.file(name, source_path)
    end
  end

  for _, pattern in ipairs(spec.include) do
    if not matched_includes[pattern] then
      fail("collect." .. category .. " tree " .. spec.root .. " include pattern selected no files: " .. pattern)
    end
  end
  for source in pairs(spec.overrides) do
    if not matched_overrides[source] then
      fail("collect." .. category .. " tree " .. spec.root .. " override source was not selected: " .. source)
    end
  end

  if #entries == 0 then
    local include_text = #spec.include > 0 and table.concat(spec.include, ", ") or "all files"
    fail("collect." .. category .. " tree " .. spec.root .. " selected no files (include: " .. include_text .. ")")
  end
  return entries
end

local function expand_collect(collect, project_root)
  local result = {}
  for category, declarations in pairs(collect or {}) do
    if type(declarations) ~= "table" then fail("collect." .. tostring(category) .. " must be an array") end
    local entries = {}
    local names = {}
    for index, declaration in ipairs(declarations) do
      local expanded
      if type(declaration) == "table" and declaration._ballad_convention == "tree" then
        expanded = expand_tree(declaration, category, project_root)
      elseif type(declaration) == "table" then
        expanded = { conventions.file(declaration.name, declaration.path) }
      else
        fail("collect." .. tostring(category) .. "[" .. tostring(index) .. "] must use conventions.file or conventions.tree")
      end
      for _, entry in ipairs(expanded) do
        if names[entry.name] then
          fail("collect." .. tostring(category) .. " produces duplicate provision " .. entry.name
            .. " from " .. names[entry.name] .. " and " .. entry.path)
        end
        names[entry.name] = entry.path
        entries[#entries + 1] = entry
      end
    end
    table.sort(entries, function(left, right)
      if left.name == right.name then return left.path < right.path end
      return left.name < right.name
    end)
    result[category] = entries
  end
  return result
end

local function external_path(dependency, kind, opts)
  opts = opts or {}
  if type(opts) ~= "table" then fail("external path options must be a table") end
  dependency = require_non_empty(dependency, "external dependency")
  local suffix = kind == "include" and "INCDIR" or "LIBDIR"
  local variable = opts.variable or (dependency:gsub("[^%w]", "_"):upper() .. "_" .. suffix)
  return {
    dependency = dependency,
    variable = require_non_empty(variable, "external path variable"),
    kind = kind,
  }
end

conventions.external = {
  include = function(dependency, opts) return external_path(dependency, "include", opts) end,
  library = function(dependency, opts) return external_path(dependency, "library", opts) end,
}

---Construct a command materializer without repeating its discriminator.
---@param opts? table
---@return table
function conventions.command(opts)
  if opts ~= nil and type(opts) ~= "table" then fail("command options must be a table") end
  local result = copy_table(opts)
  result.type = result.type or "command"
  return result
end

---Build explicit registry.source_package options from project metadata and conventions.
---@param project table prepared moonstone.project node
---@param opts? table
---@return table
function conventions.source_package(project, opts)
  opts = opts or {}
  if type(project) ~= "table" then fail("source_package requires a moonstone.project node") end
  if type(opts) ~= "table" then fail("source_package options must be a table") end

  local result = copy_table(opts)
  result.name = result.name or project.registry_name or project.name
  result.version = result.version or project.version
  result.kind = result.kind or project.kind or "lib"
  result.description = result.description or project.description
  if not result.name or result.name == "" then fail("source_package could not infer package name; set opts.name") end
  if not result.version or result.version == "" then fail("source_package could not infer package version; set opts.version") end

  result.include = result.include == nil and copy_array(DEFAULT_SOURCE_INCLUDES)
    or require_patterns(result.include, "source_package include")
  for _, pattern in ipairs(require_patterns(opts.include_add, "source_package include_add")) do
    result.include[#result.include + 1] = pattern
  end
  result.include_add = nil

  local excludes = copy_array(DEFAULT_SOURCE_EXCLUDES)
  for _, pattern in ipairs(require_patterns(opts.exclude, "source_package exclude")) do
    excludes[#excludes + 1] = pattern
  end
  result.exclude = excludes

  local materialize = conventions.command(opts.materialize)
  if opts.collect and materialize.collect then
    fail("source_package accepts collect either at opts.collect or opts.materialize.collect, not both")
  end
  local collect = opts.collect or materialize.collect
  if collect then materialize.collect = expand_collect(collect, project.root or ".") end
  if not materialize.command and not materialize.steps then materialize.command = "true" end
  result.collect = nil
  result.materialize = materialize
  return result
end

return conventions

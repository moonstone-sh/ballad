---@meta

---@class RegistryPackageOpts
---@field name? string package name (e.g. "moonstone/ballad" or "user/app")
---@field version? string package version string (e.g. "0.1.0")
---@field kind? string package kind: "bin", "lib", "script", "runtime" (default from layout or "bin")
---@field target? string target platform or "any" (default "any")
---@field runtime? string runtime dependency constraint (e.g. "moonstone/luajit@2.1.0")
---@field lua_abi? string target Lua ABI (e.g. "5.1" or "lua-5.1")
---@field readme? string relative path to README file (defaults to REGISTRY_README.md, then README.md in project root)
---@field readme_content? string raw README markdown content string
---@field origin? table immutable source provenance override ({ kind = "git", url = "https://...", revision? = "..." })
---@field out? string output directory path for the registry artifact

---@class RegistryExternalPathRequirement
---@field dependency string external development package identifier (for example "SQLITE")
---@field variable string environment variable containing the host path
---@field kind "include"|"library" required path category

---@class RegistryMaterializeConfig
---@field type? string materializer type (defaults to "command")
---@field command? string command materializer executable or shell command
---@field args? string[] ordered command arguments
---@field steps? table[] ordered command steps
---@field env? table<string, string> fixed build environment entries
---@field external_paths? RegistryExternalPathRequirement[] host-provided paths resolved at materialization time
---@field ldflags? string[] ordered linker flags; `$(VARIABLE)` path references use declared external paths
---@field strategy? string materializer strategy
---@field input? table materializer input declaration
---@field output? table materializer output declaration
---@field collect? table materialized output collection rules
---@field cmake_args? string[] ordered CMake arguments

---@class RegistrySourcePackageOpts
---@field name? string package name (e.g. "user/meteorite")
---@field version? string package version string (e.g. "0.1.0")
---@field kind? string package kind: "lib", "bin", "script" (default "lib")
---@field description? string package description
---@field include? string[] list of glob patterns for files to include in the source archive
---@field exclude? string[] list of glob patterns for files to exclude from the source archive
---@field readme? string relative path to README file (defaults to REGISTRY_README.md, then README.md in project root)
---@field readme_content? string raw README markdown content string
---@field origin? table immutable source provenance override ({ kind = "git", url = "https://...", revision? = "..." })
---@field materialize? RegistryMaterializeConfig materialization recipe and external-input contract
---@field format? "tar.gz"|"tar.zst" source archive format; defaults to the portable Moonstone-backed "tar.gz" route
---@field moon? string path or name of the Moonstone CLI used for artifact creation
---@field out? string output directory path for the registry artifact

---@class RegistryHelperPackageOpts
---@field name string Moonstone package name (for example "moonstone/ballad-watch")
---@field version string helper package version
---@field target string native Windows target triple (for example "x86_64-windows-gnu")
---@field executable string logical Moonstone bin provision name (for example "ballad-watch")
---@field source_path? string explicit built executable path; otherwise exactly one input file is required
---@field description? string package description
---@field out? string output directory for package.toml and the canonical archive
---@field moon? string Moonstone CLI implementing moonstone:artifact-create:v1

---@class RegistryExternalPackageOpts
---@field name? string package name (e.g. "moonstone/lua")
---@field version? string package version string (e.g. "5.4.7")
---@field target? string target platform (e.g. "macos-aarch64")
---@field description? string package description
---@field readme? string path to README file (defaults to REGISTRY_README.md, then README.md in project root)
---@field readme_content? string raw README markdown content string
---@field out? string output directory path for the registry artifact

local registry = {}

local graph = require("ballad.graph")
local fs = require("ballad.fs")
local path = require("ballad.path")
local process = require("ballad.process")
local project_mod = require("ballad.project")
local dkjson = require("dkjson")

registry.name = "ballad.moonstone_registry"
registry.version = "0.1.0"

local README_SIDECAR = "README.md"

registry.methods = {
	package = {
		inputs = { "asset_set" },
		outputs = { "asset_set" },
		cacheable = false,
		parallel_safe = true,
	},
	helper = {
		inputs = { "asset_set" },
		outputs = { "asset_set" },
		cacheable = false,
		parallel_safe = true,
	},
	source_package = {
		inputs = { "asset_set" },
		outputs = { "asset_set" },
		cacheable = false,
		parallel_safe = true,
	},
	runtime = {
		inputs = {},
		outputs = { "asset_set" },
		cacheable = false,
		parallel_safe = true,
	},
}

local function normalize_runtime_spec(value)
	if type(value) == "string" then
		if value == "" or value:match("^table:%s*") then return nil end
		return value
	end
	if type(value) ~= "table" then return nil end
	if type(value.runtime_spec) == "string" and value.runtime_spec ~= "" then return value.runtime_spec end
	if type(value.spec) == "string" and value.spec ~= "" then return value.spec end
	if type(value.id) == "string" and value.id ~= "" then return value.id end
	if type(value.name) == "string" and value.name ~= "" and type(value.version) == "string" and value.version ~= "" then
		return value.name .. "@" .. value.version
	end
	return nil
end

local function toml_quote(value)
	return '"' .. tostring(value):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n') .. '"'
end

local function read_readme_file(project_root, readme_rel)
	if type(readme_rel) ~= "string" or readme_rel == "" then return nil end
	local candidate = path.is_absolute(readme_rel) and readme_rel or path.join(project_root, readme_rel)
	return fs.read_file(candidate)
end

local function resolve_readme_content(inputs, opts)
	if opts and type(opts.readme_content) == "string" and opts.readme_content ~= "" then
		return opts.readme_content
	end
	local project_asset = nil
	for _, input in ipairs(inputs or {}) do
		if type(input) == "table" and input.assets then
			for _, a in ipairs(input.assets) do
				if a.kind == "project" then
					project_asset = a
					break
				end
			end
		elseif type(input) == "table" and input.kind == "project" then
			project_asset = input
			break
		end
	end
	local project_root = (project_asset and project_asset.metadata and project_asset.metadata.root) or "."
	local explicit_readme = opts and opts.readme
	if type(explicit_readme) == "string" and explicit_readme ~= "" then
		return read_readme_file(project_root, explicit_readme)
	end

	local declared_readme = project_asset and project_asset.metadata and project_asset.metadata.readme
	local declared_content = read_readme_file(project_root, declared_readme)
	if declared_content then return declared_content end

	for _, fallback in ipairs({ "REGISTRY_README.md", "README.md" }) do
		if fallback ~= declared_readme then
			local content = read_readme_file(project_root, fallback)
			if content then return content end
		end
	end
	return nil
end

local function project_asset_from_inputs(inputs)
	for _, input in ipairs(inputs or {}) do
		for _, asset in ipairs(input.assets or {}) do
			if asset.kind == "project" then return asset end
		end
	end
	return nil
end

local function resolve_origin(inputs, opts)
	local project_asset = project_asset_from_inputs(inputs)
  local project_root = project_asset and project_asset.metadata and project_asset.metadata.root or (opts and opts.root) or "."
  local origin = (opts and opts.origin) or (project_asset and project_asset.metadata and project_asset.metadata.origin)
  if not origin and fs.read_file(path.join(project_root, "moonstone.toml")) then
    local ok, loaded = pcall(project_mod.load_manifest, project_root, opts or {})
    if ok and loaded and loaded.manifest then origin = loaded.manifest.origin end
  end
	if type(origin) ~= "table" or type(origin.kind) ~= "string" or type(origin.url) ~= "string" then return nil end

	local resolved = { kind = origin.kind, url = origin.url }
	if type(origin.revision) == "string" and origin.revision ~= "" then
		resolved.revision = origin.revision
	elseif origin.kind == "git" then
		local check = "git -C " .. process.quote(project_root) .. " rev-parse --is-inside-work-tree >/dev/null 2>&1"
		if process.command_ok(check) then
			local revision = process.capture("git -C " .. process.quote(project_root) .. " rev-parse HEAD")
			if revision ~= "" then resolved.revision = revision end
		end
	end
	if type(origin.hash) == "string" and origin.hash ~= "" then resolved.hash = origin.hash end
	return resolved
end

local function append_origin(lines, origin)
	if not origin then return end
	table.insert(lines, "")
	table.insert(lines, "[origin]")
	table.insert(lines, "kind = " .. toml_quote(origin.kind))
	table.insert(lines, "url = " .. toml_quote(origin.url))
	if origin.revision then table.insert(lines, "revision = " .. toml_quote(origin.revision)) end
	if origin.hash then table.insert(lines, "hash = " .. toml_quote(origin.hash)) end
end

local function is_array(value)
	if type(value) ~= "table" then return false end
	local max = 0
	local count = 0
	for k, _ in pairs(value) do
		if type(k) ~= "number" then return false end
		if k > max then max = k end
		count = count + 1
	end
	return count == max
end

local function toml_inline_value(value)
	local value_type = type(value)
	if value_type == "string" then return toml_quote(value) end
	if value_type == "number" or value_type == "boolean" then return tostring(value) end
	if value_type == "table" then
		if is_array(value) then
			local parts = {}
			for _, item in ipairs(value) do
				parts[#parts + 1] = toml_inline_value(item)
			end
			return "[ " .. table.concat(parts, ", ") .. " ]"
		end
		local parts = {}
		local keys = {}
		for k, _ in pairs(value) do keys[#keys + 1] = k end
		table.sort(keys)
		for _, key in ipairs(keys) do
			parts[#parts + 1] = tostring(key) .. " = " .. toml_inline_value(value[key])
		end
		return "{ " .. table.concat(parts, ", ") .. " }"
	end
	return toml_quote(value)
end

local function append_toml_table(lines, header, values)
	local scalar_keys = {}
	local table_keys = {}
	for k, v in pairs(values or {}) do
		if type(v) == "table" and not is_array(v) then
			table_keys[#table_keys + 1] = k
		else
			scalar_keys[#scalar_keys + 1] = k
		end
	end
	table.sort(scalar_keys)
	table.sort(table_keys)
	table.insert(lines, header)
	for _, key in ipairs(scalar_keys) do
		table.insert(lines, tostring(key) .. " = " .. toml_inline_value(values[key]))
	end
	for _, key in ipairs(table_keys) do
		table.insert(lines, "")
		local inner = header:match("^%[(.*)%]$")
		local child_header = inner and ("[" .. inner .. "." .. tostring(key) .. "]") or (header .. "." .. tostring(key))
		append_toml_table(lines, child_header, values[key])
	end
end

local function normalize_materialize(value, fail)
	local materialize = {}
	for key, item in pairs(value) do materialize[key] = item end
	materialize.type = materialize.type or "command"

	if materialize.external_paths ~= nil then
		if type(materialize.external_paths) ~= "table" or not is_array(materialize.external_paths) then
			fail("registry.source_package materialize.external_paths must be an array")
		end
		local paths = {}
		local variables = {}
		for index, requirement in ipairs(materialize.external_paths) do
			if type(requirement) ~= "table" or type(requirement.dependency) ~= "string" or requirement.dependency == "" or type(requirement.variable) ~= "string" or requirement.variable == "" then
				fail("registry.source_package materialize.external_paths[" .. tostring(index) .. "] requires dependency and variable strings")
			end
			if requirement.kind ~= "include" and requirement.kind ~= "library" then
				fail("registry.source_package materialize.external_paths[" .. tostring(index) .. "].kind must be include or library")
			end
			if variables[requirement.variable] then
				fail("registry.source_package materialize.external_paths contains duplicate variable " .. requirement.variable)
			end
			variables[requirement.variable] = true
			paths[#paths + 1] = {
				dependency = requirement.dependency,
				variable = requirement.variable,
				kind = requirement.kind,
			}
		end
		table.sort(paths, function(left, right)
			local left_key = left.variable .. "\0" .. left.dependency .. "\0" .. left.kind
			local right_key = right.variable .. "\0" .. right.dependency .. "\0" .. right.kind
			return left_key < right_key
		end)
		materialize.external_paths = paths
	end

	if materialize.ldflags ~= nil then
		if type(materialize.ldflags) ~= "table" or not is_array(materialize.ldflags) then
			fail("registry.source_package materialize.ldflags must be an array")
		end
		for index, flag in ipairs(materialize.ldflags) do
			if type(flag) ~= "string" then
				fail("registry.source_package materialize.ldflags[" .. tostring(index) .. "] must be a string")
			end
		end
	end

	return materialize
end

local function glob_to_pattern(glob)
	local pattern = tostring(glob):gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1")
	pattern = pattern:gsub("%*%*", "\001")
	pattern = pattern:gsub("%*", "[^/]*")
	pattern = pattern:gsub("\001", ".*")
	return "^" .. pattern .. "$"
end

local function glob_matches(value, glob)
	return value:match(glob_to_pattern(glob)) ~= nil
end

local function matches_any(value, patterns)
	for _, pattern in ipairs(patterns or {}) do
		if glob_matches(value, pattern) then return true end
	end
	return false
end

local function selected_source_files(ctx, input_set, opts)
	if type(opts.include) ~= "table" or #opts.include == 0 then
		ctx.fail("registry.source_package requires opts.include with explicit source patterns")
	end
	local default_exclude = {
		".moonstone/**",
		".ballad/**",
		"zig-cache/**",
		"zig-out/**",
		".git/**",
	}
	local excludes = {}
	for _, pattern in ipairs(default_exclude) do excludes[#excludes + 1] = pattern end
	for _, pattern in ipairs(opts.exclude or {}) do excludes[#excludes + 1] = pattern end

	local root = opts.root
	for _, asset in ipairs(input_set.assets or {}) do
		if asset.kind == "project" and asset.metadata then
			root = root or asset.metadata.root or asset.metadata.project_root or asset.source_path
		end
	end
	root = root or "."

	local files = {}
	local seen = {}
	local has_project = false
	for _, asset in ipairs(input_set.assets or {}) do
		if asset.kind == "project" then has_project = true end
	end

	if has_project or opts.root then
		for _, source in ipairs(fs.list_files(root)) do
			local rel = path.relative(source, root)
			if matches_any(rel, opts.include) and not matches_any(rel, excludes) then
				files[#files + 1] = { source_path = source, virtual_path = rel }
			end
		end
	else
		for _, asset in ipairs(input_set.assets or {}) do
			local rel = asset.virtual_path or asset.source_path or asset.output_path
			if rel and matches_any(rel, opts.include) and not matches_any(rel, excludes) and not seen[rel] then
				seen[rel] = true
				files[#files + 1] = asset
			end
		end
	end
	table.sort(files, function(a, b) return (a.virtual_path or a.source_path or a.id) < (b.virtual_path or b.source_path or b.id) end)
	if #files == 0 then ctx.fail("registry.source_package selected no files") end
	return files
end

local function copy_source_files(files, staging_dir)
	fs.remove_tree(staging_dir)
	fs.mkdir(staging_dir)
	for _, asset in ipairs(files) do
		local rel = asset.virtual_path or asset.source_path or asset.output_path or asset.id
		local dest = path.join(staging_dir, rel)
		if asset.generated and asset.content then
			fs.mkdir(path.dirname(dest))
			fs.write_file(dest, asset.content)
		elseif asset.source_path then
			fs.copy_file(asset.source_path, dest)
		elseif asset.output_path then
			fs.copy_file(asset.output_path, dest)
		end
		if asset.metadata and asset.metadata.executable then
			fs.chmod(dest, "+x")
		end
	end
end

local function write_tar_file_list(files, staging_dir, list_path)
	local lines = {}
	for _, asset in ipairs(files) do
		local rel = asset.virtual_path or asset.source_path or asset.output_path or asset.id
		lines[#lines + 1] = "./" .. rel
	end
	fs.write_file(list_path, table.concat(lines, "\n") .. "\n")
end

local ARTIFACT_CREATE_CONTRACT = "moonstone:artifact-create:v1"

local function configured_moon_cli(opts)
	if opts and (opts.moon or opts.moon_bin) then return opts.moon or opts.moon_bin end
	if os.getenv("MOONSTONE_CLI") and os.getenv("MOONSTONE_CLI") ~= "" then return os.getenv("MOONSTONE_CLI") end
	if os.getenv("MOONSTONE_BIN") and os.getenv("MOONSTONE_BIN") ~= "" then return os.getenv("MOONSTONE_BIN") end
	return "moon"
end

local function artifact_capability_failure(ctx, moon_bin, result, detail)
	local suffix = detail or (result and result.stderr)
	if suffix and suffix ~= "" then suffix = ": " .. suffix else suffix = "" end
	ctx.fail("registry archive creation requires Moonstone artifact-create contract " .. ARTIFACT_CREATE_CONTRACT
		.. " (`" .. tostring(moon_bin) .. " artifact create --json`). The configured Moonstone is unavailable or incompatible; upgrade to the first artifact-create milestone"
		.. suffix)
end

local function artifact_create_failure(ctx, moon_bin, result)
	local stderr = result.stderr or ""
	local stdout = result.stdout or ""
	local unavailable = result.exit_code == 127
		or stderr:match("[Uu]nknown command")
		or stderr:match("[Nn]ot found")
		or stderr:match("[Uu]nrecognized")
	if unavailable then artifact_capability_failure(ctx, moon_bin, result) end
	ctx.fail("Moonstone artifact-create invocation failed: " .. tostring(moon_bin) .. " artifact create --json"
		.. (stderr ~= "" and (": " .. stderr) or (stdout ~= "" and (": " .. stdout) or "")))
end

---Create a canonical tar.gz from the closure Ballad has already selected and staged.
---Moonstone owns byte-level archive construction only; Ballad owns every entry
---name, source, and portable mode supplied to this invocation.
local function create_tar_gz(ctx, opts, tarball_path, entries)
	if #entries == 0 then ctx.fail("registry archive selected no files") end
	local moon_bin = configured_moon_cli(opts)
	local args = { "artifact", "create", "--out", path.absolute(tarball_path), "--json", "--" }
	for _, entry in ipairs(entries) do
		args[#args + 1] = entry.virtual_path
		args[#args + 1] = path.absolute(entry.source_path)
		args[#args + 1] = entry.mode
	end
	local result = process.capture_run({ tool = moon_bin, args = args })
	if result.exit_code ~= 0 then artifact_create_failure(ctx, moon_bin, result) end

	local document, _, decode_error = dkjson.decode(result.stdout)
	if type(document) ~= "table" then
		artifact_capability_failure(ctx, moon_bin, result, "invalid JSON result: " .. tostring(decode_error))
	end
	local valid_b3 = type(document.b3) == "string" and #document.b3 == 67 and document.b3:match("^b3:[0-9a-f]+$")
	if document.contract ~= ARTIFACT_CREATE_CONTRACT
		or type(document.path) ~= "string"
		or type(document.bytes) ~= "number" or document.bytes < 0 or document.bytes % 1 ~= 0
		or not valid_b3 then
		artifact_capability_failure(ctx, moon_bin, result, "unsupported result document")
	end
	return document
end

local function sort_archive_entries(ctx, entries)
	local seen = {}
	for _, entry in ipairs(entries) do
		if not entry.virtual_path or entry.virtual_path == "" or seen[entry.virtual_path] then
			ctx.fail("registry archive has duplicate or missing virtual path " .. tostring(entry.virtual_path))
		end
		seen[entry.virtual_path] = true
		if not fs.is_file(entry.source_path) then
			ctx.fail("registry archive entry is not a regular staged file: " .. tostring(entry.source_path))
		end
	end
	table.sort(entries, function(left, right) return left.virtual_path < right.virtual_path end)
	return entries
end

-- The artifact-create milestone has no raw hashing endpoint. Hash the canonical
-- recipe representation through the same portable artifact contract instead of
-- falling back to host b3sum on Windows.
local function canonical_recipe_hash(ctx, opts, recipe_text, work_dir)
	local recipe_path = path.join(work_dir, ".ballad-recipe-" .. tostring(ctx.node.id) .. ".txt")
	local recipe_artifact = path.join(work_dir, ".ballad-recipe-" .. tostring(ctx.node.id) .. ".tar.gz")
	fs.write_file(recipe_path, recipe_text)
	local result = create_tar_gz(ctx, opts, recipe_artifact, {
		{ virtual_path = "recipe", source_path = recipe_path, mode = "0644" },
	})
	os.remove(recipe_path)
	os.remove(recipe_artifact)
	return result.b3
end

local function require_posix_registry(ctx, operation)
	if process.is_windows() then
		ctx.fail(operation .. " is unavailable on Windows: Ballad's registry publisher requires POSIX tar, zstd, and publish.sh tooling")
	end
end

---Package a layout AssetSet into a publishable prebuilt registry artifact.
---@param ctx PluginCtx
---@param inputs AssetSet[] layout asset set input
---@param opts RegistryPackageOpts|table options specifying name, version, target, runtime, readme, readme_content, etc.
---@return AssetSet
registry.package = function(ctx, inputs, opts)
	opts = opts or {}
	local files_asset = nil
	for _, a in ipairs(inputs[1].assets) do
		if a.kind == "files" then
			files_asset = a
			break
		end
	end
	if not files_asset or files_asset.kind ~= "files" then
		ctx.fail("registry.package requires a layout node as input")
	end
	local meta = files_asset.metadata or {}
	local out_dir = files_asset.output_path or path.join(".ballad/tmp/registry-package-" .. tostring(ctx.node.id), "payload")
	if not files_asset.output_path then
		fs.remove_tree(path.dirname(out_dir))
		fs.mkdir(out_dir)
		for _, asset in ipairs(inputs[1].assets) do
			local is_project_metadata = asset.kind == "project" and asset.virtual_path == nil
			if asset.kind ~= "files" and not is_project_metadata then
				local dest = path.join(out_dir, asset.virtual_path or asset.id)
				if asset.generated and asset.content then
					fs.mkdir(path.dirname(dest))
					fs.write_file(dest, asset.content)
				elseif asset.source_path then
					fs.copy_file(asset.source_path, dest)
				elseif asset.output_path then
					fs.copy_file(asset.output_path, dest)
				end
				if asset.executable or (asset.metadata and asset.metadata.executable) then
					fs.chmod(dest, "+x")
				end
			end
		end
	end
	local artifact_dir = path.join(out_dir, "registry-artifact")
	fs.mkdir(artifact_dir)
	local pkg_name = opts.name or "app"
	local version = opts.version or "0.0.0"
	local target = opts.target or "any"
	local runtime = normalize_runtime_spec(opts.runtime or opts.runtime_spec)
	local lua_abi = opts.lua_abi or "5.1"
	local local_name = pkg_name:match("/([^/]+)$") or pkg_name
	local tarball_name = local_name .. "-" .. version .. "-" .. target .. ".tar.gz"
	local tarball_path = path.join(artifact_dir, tarball_name)
	print("Creating registry artifact: " .. tarball_name)
	local entries = {}
	for _, asset in ipairs(inputs[1].assets or {}) do
		local is_project_metadata = asset.kind == "project" and asset.virtual_path == nil
		if asset.kind ~= "files" and not is_project_metadata and asset.virtual_path and asset.virtual_path ~= "" then
			entries[#entries + 1] = {
				virtual_path = asset.virtual_path,
				source_path = path.join(out_dir, asset.virtual_path),
				mode = (asset.executable or (asset.metadata and asset.metadata.executable)) and "0755" or "0644",
			}
		end
	end
	local artifact_result = create_tar_gz(ctx, opts, tarball_path, sort_archive_entries(ctx, entries))
	local blob_hash = artifact_result.b3
	local blob_bytes = artifact_result.bytes
	local bin_name = meta.bin_name or meta.name or "app"
	local libexec_root = meta.libexec_root or ""
	local readme_content = resolve_readme_content(inputs, opts)
	local origin = resolve_origin(inputs, opts)
	local entry_prefix = libexec_root ~= "" and libexec_root .. "/" or ""
	local provides_list = {}
	if target == "any" then
		table.insert(provides_list, "bin_lua:" .. bin_name .. ":" .. entry_prefix .. meta.entry)
	else
		table.insert(provides_list, "bin:" .. bin_name .. ":bin/" .. bin_name)
	end
	local recipe_text = table.concat({
		"schema=moonstone.recipe.v0",
		"kind=prebuilt-artifact",
		"name=" .. pkg_name,
		"version=" .. version,
		"materializer=archive",
		"target=" .. target,
		"provides=" .. table.concat(provides_list, ","),
		"",
	}, "\n")
	local recipe_hash = canonical_recipe_hash(ctx, opts, recipe_text, artifact_dir)
	local digest = blob_hash:sub(4)
	local url = string.format("blobs/b3/%s/%s/%s.tar.gz", digest:sub(1, 2), digest:sub(3, 4), digest)
	local runtime_field = ""
	if runtime then
		runtime_field = string.format('runtime = "%s"', runtime)
	end
	local provides_section = ""
	local entry_point_path = entry_prefix .. meta.entry
	if target == "any" then
		provides_section = table.concat({
			"",
			"[[artifacts.provides]]",
			'kind = "bin_lua"',
			'name = "' .. bin_name .. '"',
			'path = "bin/' .. bin_name .. '"',
			'entry_point = "' .. entry_point_path .. '"',
		}, "\n")
	else
		provides_section = table.concat({
			"",
			"[[artifacts.provides]]",
			'kind = "bin"',
			'name = "' .. bin_name .. '"',
			'path = "bin/' .. bin_name .. '"',
		}, "\n")
	end

	-- Build dependency metadata from layout or explicit opts.dependencies
	local dependency_entries = {}
	local raw_deps = opts.dependencies or (meta and meta.dependencies)
	if raw_deps then
		if raw_deps[1] and type(raw_deps[1]) == "table" then
			for _, dep in ipairs(raw_deps) do
				dependency_entries[#dependency_entries + 1] = {
					role = dep.role or "runtime",
					registry = dep.resolver or dep.registry or "moonstone",
					name = dep.name,
					constraint = dep.constraint or "*",
				}
			end
		else
			for role, dep_list in pairs(raw_deps) do
				if type(dep_list) == "table" then
					for dep_name, spec in pairs(dep_list) do
						local constraint = type(spec) == "table" and (spec.constraint or "*") or tostring(spec)
						local registry = type(spec) == "table" and (spec.registry or spec.resolver) or nil
						local prefix, remainder = constraint:match("^([^:]+):(.+)$")
						if prefix then
							registry = registry or prefix
							constraint = remainder:match("@(.+)$") or "*"
						end
						registry = registry or "moonstone"
						dependency_entries[#dependency_entries + 1] = {
							role = role,
							registry = registry,
							name = type(spec) == "table" and (spec.package or dep_name) or dep_name,
							constraint = constraint,
						}
					end
				end
			end
		end
	end
	table.sort(dependency_entries, function(left, right)
		return table.concat({ left.role, left.registry, left.name, left.constraint }, "\0")
			< table.concat({ right.role, right.registry, right.name, right.constraint }, "\0")
	end)
	local dependency_sections = {}
	for _, dependency in ipairs(dependency_entries) do
		dependency_sections[#dependency_sections + 1] = table.concat({
			"[[dependencies]]",
			"name = " .. toml_quote(dependency.name),
			"constraint = " .. toml_quote(dependency.constraint),
			"resolver = " .. toml_quote(dependency.registry),
			"role = " .. toml_quote(dependency.role),
		}, "\n")
	end
	local dependency_section = table.concat(dependency_sections, "\n\n")

	local package_lines = {
		"[package]",
		'name = "' .. pkg_name .. '"',
		'version = "' .. version .. '"',
		'kind = "' .. (opts.kind or meta.kind or "bin") .. '"',
		'description = "Exported ' .. pkg_name .. ' package"',
	}
	if readme_content then
		table.insert(package_lines, "readme = " .. toml_quote(README_SIDECAR))
	end
	append_origin(package_lines, origin)
	table.insert(package_lines, "")
	if dependency_section ~= "" then
		table.insert(package_lines, dependency_section)
		table.insert(package_lines, "")
	end
	for _, line in ipairs({
		"[[artifacts]]",
		'id = "' .. (opts.artifact_kind or meta.artifact_kind or "bin") .. "-" .. target .. '"',
		'kind = "' .. (opts.artifact_kind or meta.artifact_kind or "bin") .. '"',
		'target = "' .. target .. '"',
		'lua_api = "' .. (lua_abi:gsub("^lua%-", ""):gsub("^lua", "")) .. '"',
		'lua_abi = "' .. lua_abi .. '"',
		'format = "tar.gz"',
		'url = "' .. url .. '"',
		'hash = "' .. blob_hash .. '"',
		'recipe_hash = "' .. recipe_hash .. '"',
		"bytes = " .. tostring(blob_bytes),
	}) do
		table.insert(package_lines, line)
	end
	if runtime_field ~= "" then
		table.insert(package_lines, "")
		table.insert(package_lines, runtime_field)
	end
	for _, line in ipairs({
		"",
		"[artifacts.materialize]",
		'type = "archive"',
		"strip_components = 0",
		provides_section,
	}) do
		table.insert(package_lines, line)
	end
	local package_toml = table.concat(package_lines, "\n") .. "\n"
	fs.write_file(path.join(artifact_dir, "package.toml"), package_toml)
	local readme_field = ""
	if readme_content then
		fs.write_file(path.join(artifact_dir, README_SIDECAR), readme_content)
		readme_field = ' -F readme=@"$(dirname "$0")/' .. README_SIDECAR .. '"'
	end
	local publish_lines = {
		"#!/usr/bin/env sh",
		"set -eu",
		': "${MOONSTONE_TOKEN:?Set MOONSTONE_TOKEN to a write:registry API token}"',
		'descriptor="$(dirname "$0")/package.toml"',
		'if [ -n "${MOONSTONE_ARTIFACT_URL:-}" ]; then',
		'  external_descriptor=$(mktemp)',
		[=[  trap 'rm -f "$external_descriptor"' EXIT HUP INT TERM]=],
		[=[  awk -v artifact_url="$MOONSTONE_ARTIFACT_URL" ']=],
		[=[    BEGIN { replaced = 0; in_artifact = 0 }]=],
		[=[    /^\[\[artifacts\]\]$/ { in_artifact = 1 }]=],
		[=[    in_artifact && !replaced && /^url = "/ { print "url = \"" artifact_url "\""; replaced = 1; next }]=],
		[=[    { print }]=],
		[=[  ' "$descriptor" > "$external_descriptor"]=],
		'  descriptor="$external_descriptor"',
		'  curl --fail-with-body -H "Authorization: Bearer $MOONSTONE_TOKEN" -F descriptor=@"$descriptor"' .. readme_field .. ' "${MOONSTONE_PUBLISH_URL:-https://registry.moonstone.sh/api/registry/v0/publish}"',
		"else",
		'  curl --fail-with-body -H "Authorization: Bearer $MOONSTONE_TOKEN" -F descriptor=@"$descriptor"' .. readme_field .. ' -F blob=@"$(dirname "$0")/'
			.. tarball_name
			.. '" "${MOONSTONE_PUBLISH_URL:-https://registry.moonstone.sh/api/registry/v0/publish}"',
		"fi",
	}
	local publish_sh = table.concat(publish_lines, "\n") .. "\n"
	local publish_path = path.join(artifact_dir, "publish.sh")
	fs.write_file(publish_path, publish_sh)
	fs.chmod(publish_path, "+x")
	print("Registry artifact ready in " .. artifact_dir)
	local assets = graph.AssetSet.new()
	assets:add(ctx.graph:add_asset({
		kind = "registry",
		virtual_path = artifact_dir,
		output_path = artifact_dir,
		metadata = {
			tarball = tarball_path,
			package_toml = path.join(artifact_dir, "package.toml"),
			publish_sh = publish_path,
			readme = readme_content and path.join(artifact_dir, README_SIDECAR) or nil,
		},
	}))
	return assets
end

-- Package one native executable as a Moonstone bin provision. The dependency
-- role is intentionally not encoded in the artifact: the consumer chooses
-- role = "helper", which creates Moonstone's isolated bin-helper scope.
-- This creates release inputs only; it neither publishes nor contacts a registry.
---@param ctx PluginCtx
---@param inputs AssetSet[] exactly one generated or source executable asset
---@param opts RegistryHelperPackageOpts
---@return AssetSet
registry.helper = function(ctx, inputs, opts)
	opts = opts or {}
	if type(opts.name) ~= "string" or opts.name == "" then ctx.fail("registry.helper requires opts.name") end
	if type(opts.version) ~= "string" or opts.version == "" then ctx.fail("registry.helper requires opts.version") end
	if type(opts.executable) ~= "string" or opts.executable == "" or opts.executable:find("[/\\]", 1) then
		ctx.fail("registry.helper requires a logical opts.executable name, not a path")
	end
	if type(opts.target) ~= "string" or not opts.target:find("-windows-", 1, true) then
		ctx.fail("registry.helper requires an explicit Windows target triple")
	end

	local source_path = opts.source_path
	if source_path == nil then
		local candidates = {}
		for _, asset in ipairs((inputs[1] and inputs[1].assets) or {}) do
			local candidate = asset.output_path or asset.source_path
			if candidate and fs.is_file(candidate) then candidates[#candidates + 1] = candidate end
		end
		if #candidates ~= 1 then
			ctx.fail("registry.helper requires exactly one executable input asset or opts.source_path")
		end
		source_path = candidates[1]
	end
	if type(source_path) ~= "string" or not fs.is_file(source_path) then
		ctx.fail("registry.helper executable is not a regular file: " .. tostring(source_path))
	end
	if not source_path:lower():match("%.exe$") then
		ctx.fail("registry.helper Windows executable must end in .exe")
	end

	local out_dir = opts.out or path.join(".ballad/tmp/registry-helper-" .. tostring(ctx.node.id), "registry-artifact")
	local work_dir = path.join(path.dirname(out_dir), ".registry-helper-work-" .. tostring(ctx.node.id))
	local staged_path = path.join(work_dir, "payload", "bin", opts.executable .. ".exe")
	fs.remove_tree(out_dir)
	fs.remove_tree(work_dir)
	fs.mkdir(path.dirname(staged_path))
	fs.mkdir(out_dir)
	fs.copy_file(source_path, staged_path)
	fs.chmod(staged_path, "+x")

	local local_name = opts.name:match("/([^/]+)$") or opts.name
	local tarball_name = local_name .. "-" .. opts.version .. "-" .. opts.target .. ".tar.gz"
	local tarball_path = path.join(out_dir, tarball_name)
	local artifact_result = create_tar_gz(ctx, opts, tarball_path, {
		{ virtual_path = "bin/" .. opts.executable .. ".exe", source_path = staged_path, mode = "0755" },
	})
	local recipe_text = table.concat({
		"schema=moonstone.recipe.v0",
		"kind=helper-artifact",
		"name=" .. opts.name,
		"version=" .. opts.version,
		"materializer=archive",
		"target=" .. opts.target,
		"provides=bin:" .. opts.executable .. ":bin/" .. opts.executable .. ".exe",
		"",
	}, "\n")
	local recipe_hash = canonical_recipe_hash(ctx, opts, recipe_text, work_dir)
	local digest = artifact_result.b3:sub(4)
	local url = string.format("blobs/b3/%s/%s/%s.tar.gz", digest:sub(1, 2), digest:sub(3, 4), digest)
	local descriptor = table.concat({
		"[package]",
		"name = " .. toml_quote(opts.name),
		"version = " .. toml_quote(opts.version),
		"kind = \"bin\"",
		"description = " .. toml_quote(opts.description or ("Moonstone helper " .. opts.executable)),
		"",
		"[[artifacts]]",
		"id = " .. toml_quote("helper-" .. opts.target),
		"kind = \"bin\"",
		"target = " .. toml_quote(opts.target),
		"format = \"tar.gz\"",
		"url = " .. toml_quote(url),
		"hash = " .. toml_quote(artifact_result.b3),
		"recipe_hash = " .. toml_quote(recipe_hash),
		"bytes = " .. tostring(artifact_result.bytes),
		"",
		"[artifacts.materialize]",
		"type = \"archive\"",
		"strip_components = 0",
		"",
		"[[artifacts.provides]]",
		"kind = \"bin\"",
		"name = " .. toml_quote(opts.executable),
		"path = " .. toml_quote("bin/" .. opts.executable .. ".exe"),
		"",
	}, "\n")
	local descriptor_path = path.join(out_dir, "package.toml")
	fs.write_file(descriptor_path, descriptor)

	local assets = graph.AssetSet.new()
	assets:add(ctx.graph:add_asset({
		kind = "registry",
		virtual_path = out_dir,
		output_path = out_dir,
		generated = true,
		metadata = {
			kind = "helper", name = opts.name, version = opts.version, target = opts.target,
			executable = opts.executable, tarball = tarball_path, package_toml = descriptor_path,
		},
	}))
	return assets
end

---Package a Moonstone project into a publishable source archive artifact.
---@param ctx PluginCtx
---@param inputs AssetSet[] moonstone.project asset set input
---@param opts RegistrySourcePackageOpts|table options specifying name, version, include, exclude, readme, readme_content, materialize, etc.
---@return AssetSet
registry.source_package = function(ctx, inputs, opts)
	opts = opts or {}
	local input_set = inputs[1]
	if not input_set or not input_set.assets then
		ctx.fail("registry.source_package requires a moonstone.project or asset set input")
	end
	if not opts.name or opts.name == "" then ctx.fail("registry.source_package requires opts.name") end
	if not opts.version or opts.version == "" then ctx.fail("registry.source_package requires opts.version") end
	if type(opts.materialize) ~= "table" then ctx.fail("registry.source_package requires opts.materialize") end
	local materialize = normalize_materialize(opts.materialize, function(message) ctx.fail(message) end)

	local archive_format = opts.format or opts.archive_format or "tar.gz"
	if archive_format ~= "tar.gz" and archive_format ~= "tar.zst" then
		ctx.fail("registry.source_package format must be tar.gz or tar.zst")
	end
	if archive_format == "tar.zst" and process.is_windows() then
		ctx.fail("registry.source_package format=tar.zst is unsupported by Moonstone artifact-create contract " .. ARTIFACT_CREATE_CONTRACT
			.. " (it produces tar.gz only); the retained tar.zst path requires POSIX tar, zstd, and b3sum. Use format = \"tar.gz\" on Windows")
	end
	if archive_format == "tar.zst" and not process.command_ok("command -v zstd >/dev/null 2>&1") then
		ctx.fail("registry.source_package format=tar.zst requires zstd in PATH; use format = \"tar.gz\" for Moonstone artifact-create")
	end

	local package_name = opts.name
	local version = opts.version
	local package_kind = opts.kind or "lib"
	local local_name = package_name:match("/([^/]+)$") or package_name
	local explicit_out = opts.out ~= nil
	local out_dir = opts.out or path.join(".ballad/tmp/registry-source-package-" .. tostring(ctx.node.id), "registry-artifact")
	local work_dir = explicit_out
		and path.join(path.dirname(out_dir), ".registry-source-work-" .. tostring(ctx.node.id))
		or path.join(path.dirname(out_dir), "source-work")
	local staging_dir = path.join(work_dir, "payload")
	local list_path = path.join(work_dir, "sources.list")
	local uncompressed_tar_path = path.join(work_dir, "source.tar")
	local tarball_name = local_name .. "-" .. version .. "-source." .. archive_format
	local tarball_path = path.join(out_dir, tarball_name)

	local files = selected_source_files(ctx, input_set, opts)
	if explicit_out then
		fs.remove_tree(out_dir)
		fs.remove_tree(work_dir)
	else
		fs.remove_tree(path.dirname(out_dir))
	end
	fs.mkdir(out_dir)
	copy_source_files(files, staging_dir)

	print("Creating source registry artifact: " .. tarball_name)
	local entries = {}
	for _, asset in ipairs(files) do
		local rel = asset.virtual_path or asset.source_path or asset.output_path or asset.id
		entries[#entries + 1] = {
			virtual_path = rel,
			source_path = path.join(staging_dir, rel),
			mode = (asset.executable or (asset.metadata and asset.metadata.executable)) and "0755" or "0644",
		}
	end
	local blob_hash, blob_bytes
	if archive_format == "tar.gz" then
		local artifact_result = create_tar_gz(ctx, opts, tarball_path, sort_archive_entries(ctx, entries))
		blob_hash, blob_bytes = artifact_result.b3, artifact_result.bytes
	else
		write_tar_file_list(files, staging_dir, list_path)
		local tar_cmd = string.format(
			"tar -cf %s -C %s -T %s",
			process.quote(path.absolute(uncompressed_tar_path)),
			process.quote(path.absolute(staging_dir)),
			process.quote(path.absolute(list_path))
		)
		if not process.command_ok(tar_cmd) then ctx.fail("registry.source_package failed to create intermediate source tar") end
		local zstd_cmd = string.format("zstd -q -T0 -19 -f -o %s %s", process.quote(path.absolute(tarball_path)), process.quote(path.absolute(uncompressed_tar_path)))
		if not process.command_ok(zstd_cmd) then ctx.fail("registry.source_package failed to create " .. tarball_name) end
		blob_hash = "b3:" .. process.b3sum(tarball_path)
		local handle = io.open(tarball_path, "rb")
		blob_bytes = handle and handle:seek("end") or 0
		if handle then handle:close() end
	end
	local recipe_text = table.concat({
		"schema=moonstone.recipe.v0",
		"kind=source-artifact",
		"name=" .. package_name,
		"version=" .. version,
		"materializer=" .. tostring(materialize.type),
		"materialize=" .. toml_inline_value(materialize),
		"target=source",
		"hash=" .. blob_hash,
		"",
	}, "\n")
	local recipe_hash = archive_format == "tar.gz"
		and canonical_recipe_hash(ctx, opts, recipe_text, work_dir)
		or ("b3:" .. process.b3sum_string(recipe_text))
	local digest = blob_hash:sub(4)
	local url = string.format("blobs/b3/%s/%s/%s.%s", digest:sub(1, 2), digest:sub(3, 4), digest, archive_format)

	local readme_content = resolve_readme_content(inputs, opts)
	local origin = resolve_origin(inputs, opts)
	local package_lines = {
		"[package]",
		"name = " .. toml_quote(package_name),
		"version = " .. toml_quote(version),
		"kind = " .. toml_quote(package_kind),
		"description = " .. toml_quote(opts.description or ("Source package for " .. package_name)),
	}
	if readme_content then
		table.insert(package_lines, "readme = " .. toml_quote(README_SIDECAR))
	end
	append_origin(package_lines, origin)
	for _, line in ipairs({
		"",
		"[[artifacts]]",
		'id = "source"',
		'kind = "source"',
		'target = "source"',
		'format = "' .. archive_format .. '"',
		'url = "' .. url .. '"',
		'hash = "' .. blob_hash .. '"',
		'recipe_hash = "' .. recipe_hash .. '"',
		"bytes = " .. tostring(blob_bytes),
		"",
	}) do
		table.insert(package_lines, line)
	end
	append_toml_table(package_lines, "[artifacts.materialize]", materialize)
	fs.write_file(path.join(out_dir, "package.toml"), table.concat(package_lines, "\n") .. "\n")
	local readme_field = ""
	if readme_content then
		fs.write_file(path.join(out_dir, README_SIDECAR), readme_content)
		readme_field = ' -F readme=@"$(dirname "$0")/' .. README_SIDECAR .. '"'
	end

	local publish_lines = {
		"#!/usr/bin/env sh",
		"set -eu",
		': "${MOONSTONE_TOKEN:=${MOONSTONE_PUBLISH_TOKEN:-}}"',
		': "${MOONSTONE_TOKEN:?Set MOONSTONE_TOKEN or MOONSTONE_PUBLISH_TOKEN}"',
		'descriptor="$(dirname "$0")/package.toml"',
		'if [ -n "${MOONSTONE_ARTIFACT_URL:-}" ]; then',
		'  external_descriptor=$(mktemp)',
		[=[  trap 'rm -f "$external_descriptor"' EXIT HUP INT TERM]=],
		[=[  awk -v artifact_url="$MOONSTONE_ARTIFACT_URL" ']=],
		[=[    BEGIN { replaced = 0; in_artifact = 0 }]=],
		[=[    /^\[\[artifacts\]\]$/ { in_artifact = 1 }]=],
		[=[    in_artifact && !replaced && /^url = "/ { print "url = \"" artifact_url "\""; replaced = 1; next }]=],
		[=[    { print }]=],
		[=[  ' "$descriptor" > "$external_descriptor"]=],
		'  descriptor="$external_descriptor"',
		'  curl --fail-with-body -H "Authorization: Bearer $MOONSTONE_TOKEN" -F descriptor=@"$descriptor"' .. readme_field .. ' "${MOONSTONE_PUBLISH_URL:-https://registry.moonstone.sh/api/registry/v0/publish}"',
		"else",
		'  curl --fail-with-body -H "Authorization: Bearer $MOONSTONE_TOKEN" -F descriptor=@"$descriptor"' .. readme_field .. ' -F blob=@"$(dirname "$0")/'
			.. tarball_name
			.. '" "${MOONSTONE_PUBLISH_URL:-https://registry.moonstone.sh/api/registry/v0/publish}"',
		"fi",
	}
	local publish_path = path.join(out_dir, "publish.sh")
	fs.write_file(publish_path, table.concat(publish_lines, "\n") .. "\n")
	fs.chmod(publish_path, "+x")

	print("Source registry artifact ready in " .. out_dir)
	local assets = graph.AssetSet.new()
	assets:add(ctx.graph:add_asset({
		kind = "registry",
		virtual_path = out_dir,
		output_path = out_dir,
		metadata = {
			kind = "source",
			name = package_name,
			version = version,
			tarball = tarball_path,
			package_toml = path.join(out_dir, "package.toml"),
			publish_sh = publish_path,
		},
	}))
	return assets
end

local function infer_runtime_lua_abi(name, version, explicit)
	if explicit and explicit ~= "" then return explicit end
	if name == "luajit" or name == "love" then return "lua51" end
	local major, minor = tostring(version):match("^(%d+)%.(%d+)")
	if major and minor then return "lua" .. major .. minor end
	return "lua54"
end

local function runtime_bin_provides(name, opts, target)
	if opts.bins then return opts.bins end
	local suffix = tostring(target):find("windows", 1, true) and ".exe" or ""
	if name == "love" then return { love = "bin/love" .. suffix } end
	if name == "luajit" then
		return { lua = "bin/lua" .. suffix, luajit = "bin/luajit" .. suffix }
	end
	return { lua = "bin/lua" .. suffix, luac = "bin/luac" .. suffix }
end

local function artifact_target_from_path(artifact, name, version)
	local prefix = name .. "-" .. version .. "-"
	local base = artifact:match("([^/]+)$") or artifact
	if base:sub(1, #prefix) ~= prefix or not base:match("%.tar%.zst$") then return nil end
	return base:sub(#prefix + 1, #base - #".tar.zst")
end

local function file_size(file_path)
	local handle = io.open(file_path, "rb")
	if not handle then return 0 end
	local bytes = handle:seek("end") or 0
	handle:close()
	return bytes
end

local function existing_file(file_path)
	local handle = io.open(file_path, "rb")
	if not handle then return nil end
	handle:close()
	return file_path
end

local function default_runtime_source_archive(name, version, artifacts_dir)
	return existing_file(path.join(artifacts_dir, "src", name .. "-" .. version .. ".tar.gz"))
		or existing_file(path.join(path.dirname(artifacts_dir), "src", name .. "-" .. version .. ".tar.gz"))
end

registry.runtime = function(ctx, inputs, opts)
	require_posix_registry(ctx, "registry.runtime")
	opts = opts or {}
	local name = opts.name or os.getenv("RUNTIME_NAME") or "lua"
	local package_name = opts.package_name or os.getenv("RUNTIME_PACKAGE_NAME") or name
	local version = opts.version or os.getenv("RUNTIME_VERSION")
	if not version or version == "" then ctx.fail("registry.runtime requires opts.version or RUNTIME_VERSION") end
	local artifacts_dir = opts.artifacts_dir or os.getenv("RUNTIME_ARTIFACTS_DIR") or "scripts/runtime/artifacts"
	local out_dir = opts.out or os.getenv("RUNTIME_REGISTRY_OUT") or artifacts_dir
	local registry_url = opts.registry_url or os.getenv("MOONSTONE_PUBLISH_URL") or "https://registry.moonstone.sh/api/registry/v0/publish"
	local token = opts.token or os.getenv("MOONSTONE_PUBLISH_TOKEN") or os.getenv("MOONSTONE_TOKEN") or ""
	local publish_now = opts.publish == true or opts.publish == "true" or os.getenv("RUNTIME_PUBLISH") == "1"
	local lua_abi = infer_runtime_lua_abi(name, version, opts.lua_abi or os.getenv("RUNTIME_LUA_ABI"))
	local lua_api = opts.lua_api or os.getenv("RUNTIME_LUA_API") or lua_abi
	local source_archive = opts.source_archive or opts.source or os.getenv("RUNTIME_SOURCE_ARCHIVE") or default_runtime_source_archive(name, version, artifacts_dir)
	local source_kind = opts.source_kind or os.getenv("RUNTIME_SOURCE_KIND") or (name == "lua" and "puc_lua_source" or (name == "luajit" and "luajit_source" or "runtime_source"))
	local source_format = opts.source_format or os.getenv("RUNTIME_SOURCE_FORMAT") or "tar.gz"
	local source_hash = nil
	local source_url = nil
	if source_archive and source_archive ~= "" then
		if not existing_file(source_archive) then ctx.fail("registry.runtime source archive not found: " .. tostring(source_archive)) end
		source_hash = "b3:" .. process.b3sum(source_archive)
		source_url = "https://registry.moonstone.sh/registry/v0/blobs/placeholder/" .. source_hash
	end

	fs.mkdir(out_dir)
	local descriptor_stem = package_name:gsub("/", "-")
	local descriptor_path = path.join(out_dir, descriptor_stem .. "-" .. version .. "-package.toml")
	local publish_path = path.join(out_dir, "publish-" .. descriptor_stem .. "-" .. version .. ".sh")
	local artifact_paths = {}
	local readme_content = resolve_readme_content(inputs, opts)
	local package_lines = {
		"[package]",
		'name = "' .. package_name .. '"',
		'version = "' .. version .. '"',
		'kind = "runtime"',
		'description = "' .. (opts.description or (name .. " runtime packaged for Moonstone")) .. '"',
	}
	if readme_content then
		table.insert(package_lines, "readme = " .. toml_quote(README_SIDECAR))
	end
	table.insert(package_lines, "")

	local find_cmd = "find " .. process.quote(artifacts_dir) .. " -maxdepth 1 -type f -name " .. process.quote(name .. "-" .. version .. "-*.tar.zst") .. " | sort"
	local pipe = assert(io.popen(find_cmd, "r"))
	for artifact in pipe:lines() do
		local target = artifact_target_from_path(artifact, name, version)
		if target then
			local bins = runtime_bin_provides(name, opts, target)
			local blob_hash = fs.read_file(artifact .. ".blob.hash")
			if blob_hash then blob_hash = blob_hash:match("^%s*(.-)%s*$") end
			if not blob_hash or blob_hash == "" then blob_hash = "b3:" .. process.b3sum(artifact) end
			local recipe_hash = "b3:" .. process.b3sum_string("recipe-" .. name .. "-" .. version .. "-" .. target)
			local bytes = file_size(artifact)
			table.insert(artifact_paths, artifact)
			table.insert(package_lines, "[[artifacts]]")
			table.insert(package_lines, 'kind = "runtime"')
			table.insert(package_lines, 'target = "' .. target .. '"')
			table.insert(package_lines, 'lua_api = "' .. lua_api .. '"')
			table.insert(package_lines, 'lua_abi = "' .. lua_abi .. '"')
			table.insert(package_lines, 'format = "tar.zst"')
			table.insert(package_lines, 'url = "https://registry.moonstone.sh/registry/v0/blobs/placeholder/' .. blob_hash .. '"')
			table.insert(package_lines, 'hash = "' .. blob_hash .. '"')
			if source_hash and source_url then
				table.insert(package_lines, 'source_hash = "' .. source_hash .. '"')
				table.insert(package_lines, 'source_url = "' .. source_url .. '"')
				table.insert(package_lines, 'source_kind = "' .. source_kind .. '"')
				table.insert(package_lines, 'source_format = "' .. source_format .. '"')
			end
			table.insert(package_lines, 'bytes = ' .. tostring(bytes))
			table.insert(package_lines, 'recipe_hash = "' .. recipe_hash .. '"')
			table.insert(package_lines, "")
			table.insert(package_lines, "[artifacts.materialize]")
			table.insert(package_lines, 'type = "archive"')
			table.insert(package_lines, "")
			table.insert(package_lines, "[[artifacts.provides]]")
			table.insert(package_lines, 'kind = "runtime"')
			table.insert(package_lines, 'name = "' .. name .. '"')
			table.insert(package_lines, 'version = "' .. version .. '"')
			table.insert(package_lines, 'lua_abi = "' .. lua_abi .. '"')
			table.insert(package_lines, "")
			for bin_name, bin_path in pairs(bins) do
				table.insert(package_lines, "[[artifacts.provides]]")
				table.insert(package_lines, 'kind = "bin"')
				table.insert(package_lines, 'name = "' .. bin_name .. '"')
				table.insert(package_lines, 'path = "' .. bin_path .. '"')
				table.insert(package_lines, "")
			end
		end
	end
	pipe:close()

	if #artifact_paths == 0 then
		ctx.fail("registry.runtime found no artifacts in " .. artifacts_dir .. " for " .. name .. " " .. version)
	end

	fs.write_file(descriptor_path, table.concat(package_lines, "\n") .. "\n")
	local readme_field = ""
	if readme_content then
		fs.write_file(path.join(out_dir, README_SIDECAR), readme_content)
		readme_field = ' -F readme=@"' .. path.join(out_dir, README_SIDECAR) .. '"'
	end
	local publish_lines = {
		"#!/usr/bin/env sh",
		"set -eu",
		': "${MOONSTONE_TOKEN:=${MOONSTONE_PUBLISH_TOKEN:-}}"',
		': "${MOONSTONE_TOKEN:?Set MOONSTONE_TOKEN or MOONSTONE_PUBLISH_TOKEN}"',
		"curl --fail-with-body -H \"Authorization: Bearer $MOONSTONE_TOKEN\" -F descriptor=@\"" .. descriptor_path .. "\" \\",
	}
	for _, artifact in ipairs(artifact_paths) do
		table.insert(publish_lines, "  -F blob=@\"" .. artifact .. "\" \\")
	end
	if readme_field ~= "" then
		table.insert(publish_lines, "  " .. readme_field:sub(2) .. " \\")
	end
	if source_archive and source_archive ~= "" then
		table.insert(publish_lines, "  -F blob=@\"" .. source_archive .. "\" \\")
	end
	table.insert(publish_lines, '  "${MOONSTONE_PUBLISH_URL:-' .. registry_url .. '}"')
	fs.write_file(publish_path, table.concat(publish_lines, "\n") .. "\n")
	fs.chmod(publish_path, "+x")

	if publish_now then
		if token == "" then ctx.fail("registry.runtime publish requires MOONSTONE_PUBLISH_TOKEN or MOONSTONE_TOKEN") end
		print("Publishing runtime " .. package_name .. " " .. version .. " with " .. tostring(#artifact_paths) .. " artifact(s) to " .. registry_url)
		local curl_cmd = "curl --fail-with-body -H " .. process.quote("Authorization: Bearer " .. token) .. " -F descriptor=@" .. process.quote(descriptor_path)
		for _, artifact in ipairs(artifact_paths) do
			curl_cmd = curl_cmd .. " -F blob=@" .. process.quote(artifact)
		end
		if source_archive and source_archive ~= "" then
			curl_cmd = curl_cmd .. " -F blob=@" .. process.quote(source_archive)
		end
		if readme_content then
			curl_cmd = curl_cmd .. " -F readme=@" .. process.quote(path.join(out_dir, README_SIDECAR))
		end
		curl_cmd = curl_cmd .. " " .. process.quote(registry_url)
		if not process.command_ok(curl_cmd) then ctx.fail("registry.runtime publish failed") end
		print("Published runtime " .. package_name .. " " .. version)
	end

	print("Runtime registry descriptor ready: " .. descriptor_path)
	local assets = graph.AssetSet.new()
	assets:add(ctx.graph:add_asset({
		kind = "registry",
		virtual_path = descriptor_path,
		output_path = descriptor_path,
		metadata = {
			kind = "runtime",
			name = package_name,
			runtime_name = name,
			version = version,
			artifacts = artifact_paths,
			package_toml = descriptor_path,
			publish_sh = publish_path,
			readme = readme_content and path.join(out_dir, README_SIDECAR) or nil,
		},
	}))
	return assets
end

return registry

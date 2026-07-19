local registry = {}

local graph = require("ballad.graph")
local fs = require("ballad.fs")
local path = require("ballad.path")
local process = require("ballad.process")

registry.name = "ballad.plugins.registry"
registry.version = "0.1.0"

registry.methods = {
	package = {
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

registry.package = function(ctx, inputs, opts)
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
				if asset.metadata and asset.metadata.executable then
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
	local tar_cmd = string.format(
		"tar --exclude=%s -czf %s -C %s .",
		process.quote("./registry-artifact"),
		process.quote(path.absolute(tarball_path)),
		process.quote(path.absolute(out_dir))
	)
	if not process.command_ok(tar_cmd) then
		error("failed to create tarball")
	end
	local blob_hash = "b3:" .. process.b3sum(tarball_path)
	local blob_bytes = 0
	local f = io.open(tarball_path, "rb")
	if f then
		blob_bytes = f:seek("end")
		f:close()
	end
	local bin_name = meta.bin_name or meta.name or "app"
	local libexec_root = meta.libexec_root or ""
	-- Resolve README content: explicit opts.readme_content, else read opts.readme / project readme.
	local readme_content = opts.readme_content
	if not readme_content then
		local project_asset = nil
		for _, a in ipairs(inputs[1].assets or {}) do
			if a.kind == "project" then project_asset = a break end
		end
		local project_root = (project_asset and project_asset.metadata and project_asset.metadata.root) or "."
		local readme_rel = opts.readme or (project_asset and project_asset.metadata and project_asset.metadata.readme) or nil
		if readme_rel and readme_rel ~= "" then
			local candidate = path.join(project_root, readme_rel)
			local content = fs.read_file(candidate)
			if content then readme_content = content end
		end
	end
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
	local recipe_hash = "b3:" .. process.b3sum_string(recipe_text)
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

	-- Build dependency metadata from layout
	local dependency_sections = {}
	if meta.dependencies then
		for role, dep_list in pairs(meta.dependencies) do
			for dep_name, spec in pairs(dep_list) do
				if role == "peer" or role == "optional" then
					local lines = {
						"",
						"[[dependencies]]",
						'name = "' .. dep_name .. '"',
						'role = "' .. role .. '"',
					}
					if spec.package then
						table.insert(lines, 'package = "' .. spec.package .. '"')
					end
					if spec.constraint then
						table.insert(lines, 'constraint = "' .. spec.constraint .. '"')
					end
					if spec.optional or role == "optional" then
						table.insert(lines, "optional = true")
					end
					table.insert(dependency_sections, table.concat(lines, "\n"))
				end
			end
		end
	end
	local dependency_section = table.concat(dependency_sections, "\n")

	local package_lines = {
		"[package]",
		'name = "' .. pkg_name .. '"',
		'version = "' .. version .. '"',
		'kind = "' .. (opts.kind or meta.kind or "bin") .. '"',
		'description = "Exported ' .. pkg_name .. ' package"',
	}
	if readme_content then
		table.insert(package_lines, "readme = " .. toml_quote(readme_content))
	end
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
		fs.write_file(path.join(artifact_dir, "README.md"), readme_content)
		readme_field = ' -F readme=@"$(dirname "$0")/README.md"'
	end
	local publish_lines = {
		"#!/usr/bin/env sh",
		"set -eu",
		': "${MOONSTONE_TOKEN:?Set MOONSTONE_TOKEN to a write:registry API token}"',
		'curl --fail-with-body -H "Authorization: Bearer $MOONSTONE_TOKEN" -F descriptor=@"$(dirname "$0")/package.toml"' .. readme_field .. ' -F blob=@"$(dirname "$0")/'
			.. tarball_name
			.. '" "${MOONSTONE_PUBLISH_URL:-https://registry.moonstone.sh/api/registry/v0/publish}"',
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
			readme = readme_content and path.join(artifact_dir, "README.md") or nil,
		},
	}))
	return assets
end

registry.source_package = function(ctx, inputs, opts)
	opts = opts or {}
	local input_set = inputs[1]
	if not input_set or not input_set.assets then
		ctx.fail("registry.source_package requires a moonstone.project or asset set input")
	end
	if not opts.name or opts.name == "" then ctx.fail("registry.source_package requires opts.name") end
	if not opts.version or opts.version == "" then ctx.fail("registry.source_package requires opts.version") end
	if type(opts.materialize) ~= "table" then ctx.fail("registry.source_package requires opts.materialize") end

	if not process.command_ok("command -v zstd >/dev/null 2>&1") then
		ctx.fail("registry.source_package requires zstd in PATH to create .tar.zst source archives")
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
	local tarball_name = local_name .. "-" .. version .. "-source.tar.zst"
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
	write_tar_file_list(files, staging_dir, list_path)

	print("Creating source registry artifact: " .. tarball_name)
	local tar_cmd = string.format(
		"tar -cf %s -C %s -T %s",
		process.quote(path.absolute(uncompressed_tar_path)),
		process.quote(path.absolute(staging_dir)),
		process.quote(path.absolute(list_path))
	)
	if not process.command_ok(tar_cmd) then
		ctx.fail("registry.source_package failed to create intermediate source tar")
	end
	local zstd_cmd = string.format(
		"zstd -q -T0 -19 -f -o %s %s",
		process.quote(path.absolute(tarball_path)),
		process.quote(path.absolute(uncompressed_tar_path))
	)
	if not process.command_ok(zstd_cmd) then
		ctx.fail("registry.source_package failed to create " .. tarball_name)
	end

	local blob_hash = "b3:" .. process.b3sum(tarball_path)
	local blob_bytes = 0
	local handle = io.open(tarball_path, "rb")
	if handle then
		blob_bytes = handle:seek("end") or 0
		handle:close()
	end
	local recipe_text = table.concat({
		"schema=moonstone.recipe.v0",
		"kind=source-artifact",
		"name=" .. package_name,
		"version=" .. version,
		"materializer=" .. tostring(opts.materialize.type or "command"),
		"target=source",
		"hash=" .. blob_hash,
		"",
	}, "\n")
	local recipe_hash = "b3:" .. process.b3sum_string(recipe_text)
	local digest = blob_hash:sub(4)
	local url = string.format("blobs/b3/%s/%s/%s.tar.zst", digest:sub(1, 2), digest:sub(3, 4), digest)

	-- Optional README: opts.readme_content, else read opts.readme from the project root.
	local readme_content = opts.readme_content
	if not readme_content and opts.readme and opts.readme ~= "" then
		local project_asset = nil
		for _, a in ipairs((inputs[1] and inputs[1].assets) or {}) do
			if a.kind == "project" then project_asset = a break end
		end
		local project_root = (project_asset and project_asset.metadata and project_asset.metadata.root) or "."
		local content = fs.read_file(path.join(project_root, opts.readme))
		if content then readme_content = content end
	end
	local package_lines = {
		"[package]",
		"name = " .. toml_quote(package_name),
		"version = " .. toml_quote(version),
		"kind = " .. toml_quote(package_kind),
		"description = " .. toml_quote(opts.description or ("Source package for " .. package_name)),
	}
	if readme_content then
		table.insert(package_lines, "readme = " .. toml_quote(readme_content))
	end
	for _, line in ipairs({
		"",
		"[[artifacts]]",
		'id = "source"',
		'kind = "source"',
		'target = "source"',
		'format = "tar.zst"',
		'url = "' .. url .. '"',
		'hash = "' .. blob_hash .. '"',
		'recipe_hash = "' .. recipe_hash .. '"',
		"bytes = " .. tostring(blob_bytes),
		"",
	}) do
		table.insert(package_lines, line)
	end
	local materialize = {}
	for key, value in pairs(opts.materialize) do
		materialize[key] = value
	end
	materialize.type = materialize.type or "command"
	append_toml_table(package_lines, "[artifacts.materialize]", materialize)
	fs.write_file(path.join(out_dir, "package.toml"), table.concat(package_lines, "\n") .. "\n")
	local readme_field = ""
	if readme_content then
		fs.write_file(path.join(out_dir, "README.md"), readme_content)
		readme_field = ' -F readme=@"$(dirname "$0")/README.md"'
	end

	local publish_lines = {
		"#!/usr/bin/env sh",
		"set -eu",
		': "${MOONSTONE_TOKEN:=${MOONSTONE_PUBLISH_TOKEN:-}}"',
		': "${MOONSTONE_TOKEN:?Set MOONSTONE_TOKEN or MOONSTONE_PUBLISH_TOKEN}"',
		'curl --fail-with-body -H "Authorization: Bearer $MOONSTONE_TOKEN" -F descriptor=@"$(dirname "$0")/package.toml"' .. readme_field .. ' -F blob=@"$(dirname "$0")/'
			.. tarball_name
			.. '" "${MOONSTONE_PUBLISH_URL:-https://registry.moonstone.sh/api/registry/v0/publish}"',
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

local function runtime_bin_provides(name, opts)
	if opts.bins then return opts.bins end
	if name == "love" then return { love = "bin/love" } end
	if name == "luajit" then return { lua = "bin/luajit", luajit = "bin/luajit" } end
	return { lua = "bin/lua", luac = "bin/luac" }
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
	local bins = runtime_bin_provides(name, opts)
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
	local readme_content = opts.readme_content
	if not readme_content and opts.readme and opts.readme ~= "" then
		local content = fs.read_file(opts.readme)
		if content then readme_content = content end
	end
	local package_lines = {
		"[package]",
		'name = "' .. package_name .. '"',
		'version = "' .. version .. '"',
		'kind = "runtime"',
		'description = "' .. (opts.description or (name .. " runtime packaged for Moonstone")) .. '"',
	}
	if readme_content then
		table.insert(package_lines, "readme = " .. toml_quote(readme_content))
	end
	table.insert(package_lines, "")

	local find_cmd = "find " .. process.quote(artifacts_dir) .. " -maxdepth 1 -type f -name " .. process.quote(name .. "-" .. version .. "-*.tar.zst") .. " | sort"
	local pipe = assert(io.popen(find_cmd, "r"))
	for artifact in pipe:lines() do
		local target = artifact_target_from_path(artifact, name, version)
		if target then
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
		fs.write_file(path.join(out_dir, "README.md"), readme_content)
		readme_field = ' -F readme=@"' .. path.join(out_dir, "README.md") .. '"'
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
			readme = readme_content and path.join(out_dir, "README.md") or nil,
		},
	}))
	return assets
end

return registry

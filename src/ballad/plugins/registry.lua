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
		"",
	}
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
	local publish_lines = {
		"#!/usr/bin/env sh",
		"set -eu",
		': "${MOONSTONE_TOKEN:?Set MOONSTONE_TOKEN to a write:registry API token}"',
		'curl --fail-with-body -H "Authorization: Bearer $MOONSTONE_TOKEN" -F descriptor=@"$(dirname "$0")/package.toml" -F blob=@"$(dirname "$0")/'
			.. tarball_name
			.. '" "${MOONSTONE_PUBLISH_URL:-https://moonstone.sh/api/registry/v0/publish}"',
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

registry.runtime = function(ctx, inputs, opts)
	local name = opts.name or os.getenv("RUNTIME_NAME") or "lua"
	local package_name = opts.package_name or os.getenv("RUNTIME_PACKAGE_NAME") or name
	local version = opts.version or os.getenv("RUNTIME_VERSION")
	if not version or version == "" then ctx.fail("registry.runtime requires opts.version or RUNTIME_VERSION") end
	local artifacts_dir = opts.artifacts_dir or os.getenv("RUNTIME_ARTIFACTS_DIR") or "scripts/runtime/artifacts"
	local out_dir = opts.out or os.getenv("RUNTIME_REGISTRY_OUT") or artifacts_dir
	local registry_url = opts.registry_url or os.getenv("MOONSTONE_PUBLISH_URL") or "https://moonstone.sh/api/registry/v0/publish"
	local token = opts.token or os.getenv("MOONSTONE_PUBLISH_TOKEN") or os.getenv("MOONSTONE_TOKEN") or ""
	local publish_now = opts.publish == true or opts.publish == "true" or os.getenv("RUNTIME_PUBLISH") == "1"
	local lua_abi = infer_runtime_lua_abi(name, version, opts.lua_abi or os.getenv("RUNTIME_LUA_ABI"))
	local lua_api = opts.lua_api or os.getenv("RUNTIME_LUA_API") or lua_abi
	local bins = runtime_bin_provides(name, opts)

	fs.mkdir(out_dir)
	local descriptor_stem = package_name:gsub("/", "-")
	local descriptor_path = path.join(out_dir, descriptor_stem .. "-" .. version .. "-package.toml")
	local publish_path = path.join(out_dir, "publish-" .. descriptor_stem .. "-" .. version .. ".sh")
	local artifact_paths = {}
	local package_lines = {
		"[package]",
		'name = "' .. package_name .. '"',
		'version = "' .. version .. '"',
		'kind = "runtime"',
		'description = "' .. (opts.description or (name .. " runtime packaged for Moonstone")) .. '"',
		"",
	}

	local find_cmd = "find " .. process.quote(artifacts_dir) .. " -maxdepth 1 -type f -name " .. process.quote(name .. "-" .. version .. "-*.tar.zst") .. " | sort"
	local pipe = assert(io.popen(find_cmd, "r"))
	for artifact in pipe:lines() do
		local target = artifact_target_from_path(artifact, name, version)
		if target then
			local blob_hash = fs.read_file(artifact .. ".blob.hash")
			if blob_hash then blob_hash = blob_hash:match("^%s*(.-)%s*$") end
			if not blob_hash or blob_hash == "" then blob_hash = "b3:" .. process.b3sum(artifact) end
			local recipe_hash = "b3:" .. process.b3sum_string("recipe-" .. name .. "-" .. version .. "-" .. target)
			local handle = io.open(artifact, "rb")
			local bytes = 0
			if handle then bytes = handle:seek("end") or 0; handle:close() end
			table.insert(artifact_paths, artifact)
			table.insert(package_lines, "[[artifacts]]")
			table.insert(package_lines, 'kind = "runtime"')
			table.insert(package_lines, 'target = "' .. target .. '"')
			table.insert(package_lines, 'lua_api = "' .. lua_api .. '"')
			table.insert(package_lines, 'lua_abi = "' .. lua_abi .. '"')
			table.insert(package_lines, 'format = "tar.zst"')
			table.insert(package_lines, 'url = "https://moonstone.sh/registry/v0/blobs/placeholder/' .. blob_hash .. '"')
			table.insert(package_lines, 'hash = "' .. blob_hash .. '"')
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
		},
	}))
	return assets
end

return registry

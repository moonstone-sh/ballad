local registry = {}

function registry.on_finalize(ctx)
	local fs = require("ballad.fs")
	local path = require("ballad.path")
	local process = require("ballad.process")

	local pkg_name = ctx.manifest.package and ctx.manifest.package.name or "app"
	local version = ctx.manifest.package and ctx.manifest.package.version or "0.0.0"
	local local_name = pkg_name:match("/([^/]+)$") or pkg_name

	local target = ctx.export.target or "any"

	-- We create the artifact in a subdirectory to avoid including it in the tarball
	local artifact_dir = path.join(ctx.out_dir, "registry-artifact")
	fs.mkdir(artifact_dir)

	local tarball_name = local_name .. "-" .. version .. "-" .. target .. ".tar.gz"
	local tarball_path = path.join(artifact_dir, tarball_name)

	print("Creating registry artifact: " .. tarball_name)

	-- Tar up the parent directory (ctx.out_dir) but exclude the registry-artifact dir
	local tar_cmd = string.format(
		"cd %s && tar --exclude='./registry-artifact' -czf %s .",
		process.quote(ctx.out_dir),
		process.quote(tarball_path)
	)

	if not process.command_ok(tar_cmd) then
		ctx.fail("failed to create tarball")
	end

	local blob_hash = "b3:" .. process.b3sum(tarball_path)
	local blob_bytes = tonumber(process.capture("stat -f%z " .. process.quote(tarball_path))) or 0

	-- Generate Recipe
	local provides_list = {}
	if ctx.preparer then
		if target == "any" then
			table.insert(provides_list, "bin_lua:" .. ctx.preparer.bin_name .. ":" .. ctx.options.main)
		else
			table.insert(provides_list, "bin:" .. ctx.preparer.bin_name .. ":bin/" .. ctx.preparer.bin_name)
		end
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

	-- Generate package.toml
	local digest = blob_hash:sub(4)
	local url = string.format("blobs/b3/%s/%s/%s.tar.gz", digest:sub(1, 2), digest:sub(3, 4), digest)

	local description = ctx.manifest.package.description
	if not description or description == "" then
		description = "Exported " .. pkg_name .. " package"
	end

	local abi = ctx.project.lua_abi
	if abi == "lua51" then
		abi = "5.1"
	elseif abi == "lua52" then
		abi = "5.2"
	elseif abi == "lua53" then
		abi = "5.3"
	elseif abi == "lua54" then
		abi = "5.4"
	end

	-- Runtime dependency and provides section
	local runtime_field = ""
	local provides_section = ""

	if target == "any" then
		if ctx.export.runtime then
			runtime_field = string.format('runtime = "%s"', ctx.export.runtime)
		end
		provides_section = [=[
[[artifacts.provides]]
kind = "bin_lua"
name = "]=] .. (ctx.preparer and ctx.preparer.bin_name or local_name) .. [=["
path = "bin/]=] .. (ctx.preparer and ctx.preparer.bin_name or local_name) .. [=["
entry_point = "]=] .. ctx.preparer.libexec_root .. "/" .. ctx.options.main .. [=["
]=]
	else
		provides_section = [=[
[[artifacts.provides]]
kind = "bin"
name = "]=] .. (ctx.preparer and ctx.preparer.bin_name or local_name) .. [=["
path = "bin/]=] .. (ctx.preparer and ctx.preparer.bin_name or local_name) .. [=["
]=]
	end

	-- Standalone runtime metadata
	local runtime_bundled_section = ""
	if ctx.export.mode == "standalone" and ctx.export.bundled_runtime then
		local rb = ctx.export.bundled_runtime
		runtime_bundled_section = string.format(
			'\n[runtime_bundled]\nname = "%s"\nversion = "%s"\ntarget = "%s"\nartifact_hash = "%s"\n',
			rb.name,
			rb.version,
			target,
			rb.artifact_hash
		)
	end

	local package_toml = [=[
[package]
name = "]=] .. pkg_name .. [=["
version = "]=] .. version .. [=["
kind = "bin"
description = "]=] .. description .. [=["
]=] .. runtime_bundled_section .. [=[

[[artifacts]]
      'id = "' .. (opts.artifact_kind or meta.artifact_kind or "bin") .. '-' .. target .. '"',
kind = "bin"
target = "]=] .. target .. [=["
lua_api = "]=] .. (ctx.project.lua_abi:gsub("^lua", "")) .. [=["
lua_abi = "]=] .. abi .. [=["
format = "tar.gz"
url = "]=] .. url .. [=["
hash = "]=] .. blob_hash .. [=["
recipe_hash = "]=] .. recipe_hash .. [=["
bytes = ]=] .. tostring(blob_bytes) .. [[
]] .. runtime_field .. [=[

[artifacts.materialize]
type = "archive"
strip_components = 0

]=] .. provides_section

	fs.write_file(path.join(artifact_dir, "package.toml"), package_toml)

	-- Generate publish.sh
	local publish_sh = [[
#!/usr/bin/env sh
set -eu
: "${MOONSTONE_TOKEN:?Set MOONSTONE_TOKEN to a write:registry API token}"
curl --fail-with-body \
  -H "Authorization: Bearer $MOONSTONE_TOKEN" \
  -F descriptor=@"$(dirname "$0")/package.toml" \
  -F blob=@"$(dirname "$0")/]] .. tarball_name .. [[" \
  "${MOONSTONE_PUBLISH_URL:-https://moonstone.sh/api/registry/v0/publish}"
]]

	local publish_path = path.join(artifact_dir, "publish.sh")
	fs.write_file(publish_path, publish_sh)
	fs.chmod(publish_path, "+x")

	print("Registry artifact ready in " .. artifact_dir)
	print("To publish, run: MOONSTONE_TOKEN=... " .. publish_path)
end

-- New contract-based interface (Stage 2 pipeline)
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
	local out_dir = files_asset.output_path or "dist/ballad"
	local artifact_dir = path.join(out_dir, "registry-artifact")
	fs.mkdir(artifact_dir)
	local pkg_name = opts.name or "app"
	local version = opts.version or "0.0.0"
	local target = opts.target or "any"
	local runtime = opts.runtime or nil
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
	local descriptor_path = path.join(out_dir, name .. "-" .. version .. "-package.toml")
	local publish_path = path.join(out_dir, "publish-" .. name .. "-" .. version .. ".sh")
	local artifact_paths = {}
	local package_lines = {
		"[package]",
		'name = "' .. name .. '"',
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
		local curl_cmd = "curl --fail-with-body -H " .. process.quote("Authorization: Bearer " .. token) .. " -F descriptor=@" .. process.quote(descriptor_path)
		for _, artifact in ipairs(artifact_paths) do
			curl_cmd = curl_cmd .. " -F blob=@" .. process.quote(artifact)
		end
		curl_cmd = curl_cmd .. " " .. process.quote(registry_url)
		if not process.command_ok(curl_cmd) then ctx.fail("registry.runtime publish failed") end
	end

	print("Runtime registry descriptor ready: " .. descriptor_path)
	local assets = graph.AssetSet.new()
	assets:add(ctx.graph:add_asset({
		kind = "registry",
		virtual_path = descriptor_path,
		output_path = descriptor_path,
		metadata = {
			kind = "runtime",
			name = name,
			version = version,
			artifacts = artifact_paths,
			package_toml = descriptor_path,
			publish_sh = publish_path,
		},
	}))
	return assets
end

return registry

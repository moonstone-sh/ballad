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
		""
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
	if abi == "lua51" then abi = "5.1"
	elseif abi == "lua52" then abi = "5.2"
	elseif abi == "lua53" then abi = "5.3"
	elseif abi == "lua54" then abi = "5.4"
	end

	-- Runtime dependency and provides section
	local runtime_field = ""
	local provides_section = ""
	
	if target == "any" then
		if ctx.export.runtime then
			runtime_field = string.format('\nruntime = "%s"', ctx.export.runtime)
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
			rb.name, rb.version, target, rb.artifact_hash
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
id = "bin-]=] .. target .. [=["
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

return registry

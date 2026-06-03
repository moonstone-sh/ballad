local fs = require("ballad.fs")
local path = require("ballad.path")
local process = require("ballad.process")
local dkjson = require("dkjson")
local project_mod = require("ballad.project")
local lockfile = require("ballad.lockfile")

local exporter = {}

local function should_skip_project_file(relative_path, output_relative)
	if relative_path:match("^%.git/") or relative_path:match("^%.moonstone/") or relative_path:match("^dist/") then
		return true
	end
	if relative_path == "moonstone.lock" then
		return true
	end

	if
		output_relative
		and (relative_path == output_relative or relative_path:sub(1, #output_relative + 1) == output_relative .. "/")
	then
		return true
	end

	return not (fs.is_lua(relative_path) or fs.is_binary_module(relative_path))
end

local function add_file(graph, destinations, source, destination, kind, package)
	if destinations[destination] then
		process.fail(
			"destination collision for " .. destination .. " from " .. source .. " and " .. destinations[destination]
		)
	end

	destinations[destination] = source

	fs.copy_file(source, path.join(graph.output, destination))

	graph.files[#graph.files + 1] = {
		destination = destination,
		kind = kind,
		module = (fs.is_lua(destination) or fs.is_binary_module(destination))
				and path.module_name(destination:gsub("^lua/", ""):gsub("^lib/", ""):gsub("^project/src/", ""))
			or nil,
		package = package and package.name or nil,
		artifact_hash = package and package.artifact_hash or nil,
		source = source,
	}
end

local function write_lua_runner(output, main_script)
	local content = {
		"local source = debug.getinfo(1, 'S').source",
		"local root = source:match('^@(.+)/run%.lua$') or '.'",
		"package.path = root .. '/lua/?.lua;' .. root .. '/lua/?/init.lua;' .. root .. '/project/src/?.lua;' .. root .. '/project/src/?/init.lua;' .. root .. '/project/?.lua;' .. root .. '/project/?/init.lua;' .. package.path",
		"package.cpath = root .. '/lib/?.so;' .. root .. '/lib/?.dylib;' .. root .. '/lib/?.dll;' .. package.cpath",
	}

	if main_script then
		table.insert(content, "if arg and arg[0] and arg[0]:match('run%.lua$') then")
		table.insert(content, "\tlocal chunk, err = loadfile(root .. '/project/" .. main_script .. "')")
		table.insert(content, "\tif not chunk then error(err) end")
		table.insert(content, "\tchunk(...)")
		table.insert(content, "end")
	end

	table.insert(content, "return root")
	table.insert(content, "")

	fs.write_file(path.join(output, "run.lua"), table.concat(content, "\n"))
end

function exporter.export(options)
	local loaded = project_mod.load(options.project)

	local project_root = loaded.root
	local manifest = loaded.manifest
	local packages = loaded.packages
	local env = loaded.env
	local abi = env.runtime.abi

	local output = path.absolute(options.output or path.join(project_root, "dist/ballad"))
	local output_relative = output:sub(1, #project_root + 1) == project_root .. "/"
			and path.relative(output, project_root)
		or nil

	fs.remove_tree(output)
	fs.mkdir(output)

	local graph = {
		format = "ballad-file-graph-v1",
		layout = options.layout,
		output = output,
		project = {
			name = manifest.package and manifest.package.name or path.basename(project_root),
			root = project_root,
			version = manifest.package and manifest.package.version or "unknown",
		},
		runtime = {
			name = env.runtime and env.runtime.name or "unknown",
			version = env.runtime and env.runtime.version or "unknown",
			abi = abi,
		},
		dependencies = manifest.dependencies or {},
		selected_packages = packages,
		files = {},
	}

	local destinations = {}

	for _, source in ipairs(fs.list_files(project_root)) do
		local relative_path = path.relative(source, project_root)

		if not should_skip_project_file(relative_path, output_relative) then
			local destination = options.layout == "love" and relative_path or path.join("project", relative_path)
			add_file(graph, destinations, source, destination, "project", nil)
		end
	end

	local module_root = path.join(project_root, ".moonstone/env/share/lua", path.abi_directory(abi))

	if fs.is_dir(module_root) then
		for _, module_path in ipairs(fs.list_files(module_root)) do
			if fs.is_lua(module_path) then
				local relative_path = path.relative(module_path, module_root)
				local source = fs.readlink(module_path)
				local package = lockfile.package_for_source(packages, source)
				local destination = options.layout == "love" and relative_path or path.join("lua", relative_path)

				add_file(graph, destinations, source, destination, "package", package)
			end
		end
	end

	local lib_module_root = path.join(project_root, ".moonstone/env/lib/lua", path.abi_directory(abi))

	if fs.is_dir(lib_module_root) then
		for _, module_path in ipairs(fs.list_files(lib_module_root)) do
			if fs.is_binary_module(module_path) then
				local relative_path = path.relative(module_path, lib_module_root)
				local source = fs.readlink(module_path)
				local package = lockfile.package_for_source(packages, source)
				local destination = options.layout == "love" and relative_path or path.join("lib", relative_path)

				add_file(graph, destinations, source, destination, "package", package)
			end
		end
	end

	table.sort(graph.files, function(left, right)
		return left.destination < right.destination
	end)

	table.sort(graph.selected_packages, function(left, right)
		if left.name == right.name then
			return (left.version or "") < (right.version or "")
		end
		return (left.name or "") < (right.name or "")
	end)

	graph.output = nil

	if options.layout == "lua" then
		write_lua_runner(output, options.main)
	end

	fs.write_file(path.join(output, "file-graph.json"), dkjson.encode(graph) .. "\n")

	print("Exported " .. tostring(#graph.files) .. " Lua files to " .. output)
	print("Layout: " .. options.layout)
	print("Graph: " .. path.join(output, "file-graph.json"))
end

return exporter

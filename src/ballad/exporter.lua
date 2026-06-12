local fs = require("ballad.fs")
local path = require("ballad.path")
local process = require("ballad.process")
local dkjson = require("dkjson")
local project_mod = require("ballad.project")
local lockfile = require("ballad.lockfile")

local exporter = {}

local function run_hook(ctx, hook_name, ...)
	for _, plugin in ipairs(ctx.plugins) do
		if plugin[hook_name] then
			local res = plugin[hook_name](ctx, ...)
			if res ~= nil then
				return res
			end
		end
	end
end

local function run_transform_hook(ctx, hook_name, task)
	local current_task = task
	for _, plugin in ipairs(ctx.plugins) do
		if plugin[hook_name] then
			local res = plugin[hook_name](ctx, current_task)
			if res == false then
				return false
			elseif type(res) == "table" then
				current_task = res
				current_task.plugin = current_task.plugin or plugin.name
			end
		end
	end
	return current_task
end

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

local function add_file(graph, destinations, task)
	local destination = task.dest or task.destination
	local source = task.src or task.source
	local kind = task.kind
	local package = task.package

	if destinations[destination] then
		process.fail(
			"destination collision for " .. destination .. " from " .. (source or "generated") .. " and " .. destinations[destination]
		)
	end

	destinations[destination] = source or "generated"

	if kind == "generated" then
		fs.mkdir(path.dirname(path.join(graph.output, destination)))
		fs.write_file(path.join(graph.output, destination), task.content)
	else
		fs.copy_file(source, path.join(graph.output, destination))
	end

	local mod_dest = destination
	if mod_dest:match("^libexec/[^/]+/") then
		mod_dest = mod_dest:gsub("^libexec/[^/]+/", "")
	end

	graph.files[#graph.files + 1] = {
		src = source,
		dest = destination,
		kind = kind,
		module = (fs.is_lua(destination) or fs.is_binary_module(destination))
				and path.module_name(mod_dest:gsub("^lua/", ""):gsub("^lib/", ""):gsub("^project/src/", ""):gsub("^src/", ""))
			or nil,
		package = type(package) == "table" and package.name or package,
		artifact_hash = type(package) == "table" and package.artifact_hash or nil,
		plugin = task.plugin,
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

local function is_runtime_package(package)
	if not package then return true end
	if package.roles then
		if #package.roles == 0 then return true end
		for _, role in ipairs(package.roles) do
			if role == "runtime" then return true end
		end
		return false
	end
	if not package.groups then return true end
	if #package.groups == 0 then return true end
	for _, g in ipairs(package.groups) do
		if g == "libs" or g == "bins" then
			return true
		end
	end
	return false
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

	local plugins = {}
	for _, spec in ipairs(options.plugins or {}) do
		local name = spec.name
		local mod_name = name:find("%.") and name or ("ballad.plugins." .. name)
		local ok, plugin = pcall(require, mod_name)
		if not ok then
			process.fail("failed to load plugin " .. name .. ": " .. tostring(plugin))
		end
		plugin.name = name
		plugin.params = spec.params or {}
		table.insert(plugins, plugin)
	end

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

	local host_target = process.capture("uname -sm | tr '[:upper:]' '[:lower:]'"):gsub("%s+", "-"):gsub("x86_64", "x86_64"):gsub("arm64", "aarch64")

	local destinations = {}
	local ctx = {
		host = {
			target = host_target,
			runtime = env.runtime.name .. "@" .. env.runtime.version,
		},
		project = {
			root = project_root,
			name = manifest.package and manifest.package.name or path.basename(project_root),
			version = manifest.package and manifest.package.version or "0.0.0",
			runtime = env.runtime.name .. "@" .. env.runtime.version,
			lua_abi = abi,
		},
		export = {
			mode = "agnostic",
			target = "any",
			runtime = env.runtime.name .. "@" .. env.runtime.version,
		},
		project_root = project_root,
		out_dir = output,
		layout = options.layout,
		options = options,
		graph = graph,
		plugins = plugins,
		manifest = manifest,
		packages = packages,
		env = env,
		emit_file = function(task)
			add_file(graph, destinations, task)
		end,
		add_generated_file = function(dest, content, plugin_name)
			add_file(graph, destinations, {
				dest = dest,
				kind = "generated",
				content = content,
				plugin = plugin_name,
			})
		end,
		warn = function(msg)
			print("Warning: " .. msg)
		end,
		fail = function(msg)
			process.fail(msg)
		end,
		chmod = function(dest, mode)
			fs.chmod(path.join(output, dest), mode)
		end,
		moonstone = {
			get_project_runtime = function()
				local json_path = path.join(project_root, ".moonstone/env/runtime.json")
				local f = io.open(json_path, "r")
				if f then
					local content = f:read("*a")
					f:close()
					return dkjson.decode(content)
				end
				return nil
			end,
			get_runtime_artifact = function(_, query)
				local spec = query.name
				if query.version then spec = spec .. "@" .. query.version end
				local cmd = "moon runtime path " .. process.quote(spec) .. " --json"
				if query.target then
					cmd = cmd .. " --target " .. process.quote(query.target)
				end
				local res = process.capture(cmd)
				if res:sub(1, 1) == "{" then
					return dkjson.decode(res)
				end
				return nil
			end,
		},
	}

	run_hook(ctx, "on_init")

	for _, source in ipairs(fs.list_files(project_root)) do
		local relative_path = path.relative(source, project_root)

		if not should_skip_project_file(relative_path, output_relative) then
			local destination = options.layout == "love" and relative_path or path.join("project", relative_path)
			local task = run_transform_hook(ctx, "on_add_file", {
				src = source,
				dest = destination,
				kind = "project",
			})

			if task then
				if task[1] then
					for _, subtask in ipairs(task) do
						add_file(graph, destinations, subtask)
					end
				else
					add_file(graph, destinations, task)
				end
			end
		end
	end

	local module_root = path.join(project_root, ".moonstone/env/share/lua", path.abi_directory(abi))

	if fs.is_dir(module_root) then
		for _, module_path in ipairs(fs.list_files(module_root)) do
			if fs.is_lua(module_path) then
				local relative_path = path.relative(module_path, module_root)
				local source = fs.readlink(module_path)
				local package = lockfile.package_for_source(packages, source)
				if not is_runtime_package(package) then
					-- skip dev-only packages
				else
					local destination = options.layout == "love" and relative_path or path.join("lua", relative_path)
					local task = run_transform_hook(ctx, "on_add_file", {
						src = source,
						dest = destination,
						kind = "package",
						package = package,
					})

					if task then
						if task[1] then
							for _, subtask in ipairs(task) do
								add_file(graph, destinations, subtask)
							end
						else
							add_file(graph, destinations, task)
						end
					end
				end
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
				if not is_runtime_package(package) then
					-- skip dev-only packages
				else
					local destination = options.layout == "love" and relative_path or path.join("lib", relative_path)
					local task = run_transform_hook(ctx, "on_add_file", {
						src = source,
						dest = destination,
						kind = "package",
						package = package,
					})

					if task then
						if task[1] then
							for _, subtask in ipairs(task) do
								add_file(graph, destinations, subtask)
							end
						else
							add_file(graph, destinations, task)
						end
					end
				end
			end
		end
	end

	run_hook(ctx, "on_finalize")

	table.sort(graph.files, function(left, right)
		return left.dest < right.dest
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

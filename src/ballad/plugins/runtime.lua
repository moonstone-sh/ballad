local runtime = {}

function runtime.on_init(ctx)
	local fs = require("ballad.fs")
	local path = require("ballad.path")
	local process = require("ballad.process")
	local dkjson = require("dkjson")

	local plugin_self = {}
	for _, p in ipairs(ctx.plugins) do
		if p.name == "runtime" then plugin_self = p end
	end

	-- 1. Determine requested target
	local target = plugin_self.params.target or ctx.host.target
	ctx.export.target = target
	ctx.export.mode = "standalone"

	-- 2. Determine requested runtime spec
	local runtime_spec = plugin_self.params.runtime or ctx.project.runtime
	ctx.export.runtime = runtime_spec

	-- 3. Resolve runtime artifact
	local meta = nil
	if target == ctx.host.target and runtime_spec == ctx.host.runtime then
		meta = ctx.moonstone.get_project_runtime()
	else
		meta = ctx.moonstone:get_runtime_artifact({
			name = runtime_spec:match("([^@]+)"),
			version = runtime_spec:match("@(.+)"),
			target = target,
		})
	end

	if not meta or not meta.path then
		ctx.fail(string.format(
			"Cannot create standalone export for %s.\n\nRequired runtime:\n  %s\n\nNo compatible runtime artifact was found in the Moonstone store or registry.",
			target, runtime_spec
		))
		return
	end

	ctx.runtime_provision = {
		files_root = meta.path .. "/files",
		interpreter_rel = meta.bin:sub(#meta.path + 8), -- skip path + /files/
		dest_dir = "runtime",
	}

	-- Update export context with bundled details
	ctx.export.bundled_runtime = {
		name = meta.name,
		version = meta.version,
		path = "runtime",
		interpreter = "runtime/" .. ctx.runtime_provision.interpreter_rel,
		artifact_hash = meta.artifact_hash,
	}

	-- Inform other plugins that we are bundling the runtime
	ctx.interpreter = "$ROOT/" .. ctx.export.bundled_runtime.interpreter
end

function runtime.on_finalize(ctx)
	if not ctx.runtime_provision then return end

	local fs = require("ballad.fs")
	local path = require("ballad.path")

	print("Provisioning runtime from " .. ctx.runtime_provision.files_root)

	local files = fs.list_files(ctx.runtime_provision.files_root)
	for _, source in ipairs(files) do
		local relative = source:sub(#ctx.runtime_provision.files_root + 2)
		local dest = path.join(ctx.runtime_provision.dest_dir, relative)
		
		ctx.emit_file({
			src = source,
			dest = dest,
			kind = "runtime",
			plugin = "runtime",
		})
	end
end

return runtime

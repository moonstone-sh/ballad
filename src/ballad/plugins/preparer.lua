local preparer = {}

function preparer.on_init(ctx)
	local package_name = ctx.manifest.package and ctx.manifest.package.name or "app"
	ctx.preparer = {
		package_name = package_name,
		bin_name = package_name:match("/([^/]+)$") or package_name,
		libexec_root = "libexec/" .. (package_name:match("/([^/]+)$") or package_name),
	}
end

function preparer.on_add_file(ctx, task)
	if task.kind == "project" then
		local relative_src = task.src:sub(#ctx.project_root + 2)
		task.dest = ctx.preparer.libexec_root .. "/" .. relative_src
		return task
	elseif task.kind == "package" then
		task.dest = ctx.preparer.libexec_root .. "/" .. task.dest
		return task
	end
end
function preparer.on_finalize(ctx)
	local plugin_self = {}
	for _, p in ipairs(ctx.plugins) do if p.name == "preparer" then plugin_self = p end end

	local interpreter = plugin_self.params.interpreter or ctx.interpreter
	if not interpreter then
		if ctx.export.runtime then
			interpreter = ctx.export.runtime:match("([^@]+)")
		else
			interpreter = "lua"
		end
	end

	local launcher = [[
#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIBEXEC="$ROOT/]] .. ctx.preparer.libexec_root .. [["

# Setup paths for the portable export
export LUA_PATH="$LIBEXEC/lua/?.lua;$LIBEXEC/lua/?/init.lua;$LIBEXEC/src/?.lua;$LIBEXEC/src/?/init.lua;${LUA_PATH:-};;"
export LUA_CPATH="$LIBEXEC/lib/?.so;$LIBEXEC/lib/?.dylib;$LIBEXEC/lib/?.dll;${LUA_CPATH:-};;"

exec ]] .. interpreter .. [[ "$LIBEXEC/]] .. ctx.options.main .. [[" "$@"
]]
	ctx.add_generated_file("bin/" .. ctx.preparer.bin_name, launcher, "preparer")
	ctx.chmod("bin/" .. ctx.preparer.bin_name, "+x")
end

return preparer

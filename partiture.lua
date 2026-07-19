local ballad = require("ballad")

return ballad.partiture(function(p)
	local moonstone = p:use(ballad.plugins.moonstone)
	local layout = p:use(ballad.plugins.layout)
	local registry = p:use(ballad.plugins.registry)

	local project = moonstone.project({
		root = ".",
	})

	local app = layout.libexec(project, {
		name = "ballad",
		entry = "src/main.lua",
		bin = "ballad",
		interpreter = "luajit",
	})

	local registry_artifact = registry.package(app, {
		name = project.registry_name or "moonstone/ballad",
		version = project.version,
		target = "any",
		runtime = project.runtime_spec or "moonstone/luajit@2.1.0",
		lua_abi = project.lua_abi or "5.1",
		description = project.description,
		-- Package the project README (declared via `readme = "./README.md"` in
		-- moonstone.toml [package], or auto-detected as ./README.md) into the
		-- release artifact: inlined into package.toml AND emitted as README.md,
		-- then uploaded by publish.sh as the `readme` form field.
		readme = project.readme,
		readme_content = project.readme_content,
	})

	p.sink.directory(app, {
		out = "dist/ballad",
		file_graph = true,
	})
	p.sink.artifact(registry_artifact, {
		out = "dist/ballad/registry-artifact",
	})
end)

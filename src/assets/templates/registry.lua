local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local project = moonstone.project({ root = "." })
  local convention = ballad.conventions
  local package_name = project.name:match("([^/]+)$") or project.name
  local artifact = moonstone.registry.source_package(project, {
    collect = {
      lua_modules = {
        convention.tree("src", {
          prefix = package_name,
          strip_prefix = package_name .. "/",
          root_module = package_name .. ".lua",
        }),
      },
    },
  })

  p.sink.artifact(artifact, { out = "dist/registry", product = "package" })
end)

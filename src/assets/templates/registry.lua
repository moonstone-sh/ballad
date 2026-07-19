local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local registry = p:use(ballad.plugins.registry)
  local project = moonstone.project({ root = "." })
  local artifact = registry.package(project)

  p.sink.artifact(artifact, { out = "dist/registry" })
end)

local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local project = moonstone.project({ root = "." })
  local artifact = moonstone.registry.package(project)

  p.sink.artifact(artifact, { out = "dist/registry" })
end)

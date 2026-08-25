local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local layout = p:use(ballad.plugins.layout)
  local project = moonstone.project({ root = "." })
  local app = layout.exec(project, {
    name = project.name,
    entry = "src/main.lua",
    bin = project.name:match("([^/]+)$") or project.name,
    interpreter = "lua",
  })

  p.sink.directory(app, { out = "dist/app", file_graph = true })
end)

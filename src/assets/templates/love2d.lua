local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local love = p:use(ballad.plugins.love)
  local project = moonstone.project({ root = "." })
  local app = love.layout(project)

  p.sink.directory(app, { out = "dist/love", file_graph = true })
end)

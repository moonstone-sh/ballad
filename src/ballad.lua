local partiture = require("ballad.partiture")
require("ballad.types")

---Public Ballad API entrypoint.
---@type Ballad
return {
  partiture = partiture.partiture,
  plugins = {
    layout = require("ballad.plugins.layout"),
    love = require("ballad.plugins.love"),
    lua = require("ballad.plugins.lua"),
    moonstone = require("ballad.plugins.moonstone"),
    nvim = require("ballad.plugins.nvim"),
    runtime = require("ballad.plugins.runtime"),
    watcher = require("ballad.plugins.watcher"),
    input = {
      moonstone = require("ballad.plugins.input.moonstone"),
    },
  },
}

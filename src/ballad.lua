local partiture = require("ballad.partiture")
require("ballad.types")

---Public Ballad API entrypoint.
---@type Ballad
return {
  partiture = partiture.partiture,
  plugins = {
    emit = require("ballad.plugins.emit"),
    layout = require("ballad.plugins.layout"),
    love = require("ballad.plugins.love"),
    lua = require("ballad.plugins.lua"),
    moonstone = require("ballad.plugins.moonstone"),
    nvim = require("ballad.plugins.nvim"),
    registry = require("ballad.plugins.registry"),
    runtime = require("ballad.plugins.runtime"),
  },
}

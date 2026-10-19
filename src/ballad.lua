local variants_ok, variants = pcall(function() return require("moonstone.variants") end)
local target_ok, target = pcall(function() return require("moonstone.target") end)
if variants_ok and target_ok then variants.install(target) end

local partiture = require("ballad.partiture")
require("ballad.types")

---Public Ballad API entrypoint.
---@type Ballad
return {
  partiture = partiture.partiture,
  action = require("ballad.native_action"),
  conventions = require("ballad.conventions"),
  diagnostic = require("ballad.diagnostic"),
  testing = require("ballad.testing"),
  flavor = require("ballad.flavor"),
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

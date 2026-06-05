local graph = require("ballad.graph")

return {
  name = "ballad.plugins.lua",
  version = "0.1.0",
  methods = {
    compile = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      cacheable = true,
      parallel_safe = true,
    },
    check = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      cacheable = true,
      parallel_safe = true,
    },
  },
  compile = function(ctx, inputs, opts)
    error("ballad.plugins.lua.compile not yet implemented")
  end,
  check = function(ctx, inputs, opts)
    error("ballad.plugins.lua.check not yet implemented")
  end,
}

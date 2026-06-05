local graph = require("ballad.graph")
local fs = require("ballad.fs")
local path = require("ballad.path")

return {
  name = "ballad.plugins.emit",
  version = "0.1.0",
  methods = {
    directory = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      cacheable = false,
      parallel_safe = true,
    },
    stdout = {
      inputs = { "asset_set" },
      outputs = { "asset_set" },
      cacheable = false,
      parallel_safe = true,
    },
  },
  directory = function(ctx, inputs, opts)
    local files_result = nil
    for _, a in ipairs(inputs[1].assets) do
      if a.kind == "files" then
        files_result = a
        break
      end
    end
    if not files_result or files_result.kind ~= "files" then
      ctx.fail("emit.directory requires a layout node as input")
    end
    local dest = opts.out or opts.dir or "dist"
    print("Emitting to directory: " .. dest)

    -- Build file-graph.json if requested
    if opts.file_graph then
      local file_graph = {
        version = 1,
        generated_by = "ballad",
        files = {},
      }
      -- Collect assets from all executed nodes in the graph
      for _, node in pairs(ctx.graph.nodes) do
        if node.result and getmetatable(node.result) == graph.AssetSet then
          for _, asset in ipairs(node.result.assets) do
            if asset.virtual_path then
              local entry = {
                kind = asset.generated and "generated" or "copy",
                source = asset.source_path or nil,
                dest = asset.virtual_path,
              }
              if asset.metadata and asset.metadata.plugin then
                entry.plugin = asset.metadata.plugin
                entry.method = asset.metadata.method
              end
              table.insert(file_graph.files, entry)
            end
          end
        end
      end
      local fg_path = path.join(dest, "file-graph.json")
      fs.mkdir(path.dirname(fg_path))
      fs.write_file(fg_path, require("dkjson").encode(file_graph) .. "\n")
      print("file-graph.json written to " .. fg_path)
    end

    local assets = graph.AssetSet.new()
    assets:add(ctx.graph:add_asset({
      kind = "emit",
      virtual_path = dest,
      output_path = dest,
      metadata = { kind = "directory", root = files_result.output_path },
    }))
    return assets
  end,
  stdout = function(ctx, inputs, opts)
    local data = inputs[1].assets[1]
    if not data then
      ctx.fail("emit.stdout requires an input node")
    end
    print(require("dkjson").encode(data))
    local assets = graph.AssetSet.new()
    assets:add(ctx.graph:add_asset({
      kind = "emit",
      virtual_path = "stdout",
      metadata = { kind = "stdout" },
    }))
    return assets
  end,
}

local graph = require("ballad.graph")
local fs = require("ballad.fs")
local path = require("ballad.path")
local process = require("ballad.process")

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

    fs.mkdir(dest)
    if opts.clean ~= false then
      local preserve = path.join(dest, "registry-artifact")
      process.command_ok(
        "find " .. process.quote(dest) .. " -mindepth 1 -path " .. process.quote(preserve) .. " -prune -o -exec rm -rf {} +"
      )
      fs.mkdir(dest)
    end

    -- Collect and emit only the final input asset set. Earlier pipeline nodes may
    -- contain intermediate duplicates that should not leak into the export.
    local file_graph = {
      version = 1,
      generated_by = "ballad",
      layout = files_result.metadata and files_result.metadata.layout or "unknown",
      files = {},
    }
    for _, asset in ipairs(inputs[1].assets) do
      if asset.virtual_path and asset.kind ~= "files" then
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

        if asset.kind == "project" or asset.kind == "package" or asset.kind == "file" or asset.kind == "generated" or asset.kind == "runtime" then
          local out_path = path.join(dest, asset.virtual_path)
          fs.mkdir(path.dirname(out_path))
          if asset.generated and asset.content then
            fs.write_file(out_path, asset.content)
            if asset.content:match("^#!") then
              fs.chmod(out_path, "+x")
            end
          elseif asset.source_path then
            fs.copy_file(asset.source_path, out_path)
          end
        end
      end
    end

    -- Build file-graph.json if requested
    if opts.file_graph then
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
      metadata = { kind = "directory", root = files_result.output_path or dest },
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

local process = require("ballad.process")
local exporter = require("ballad.exporter")

local cli = {}

local function print_help()
  print("Usage: moon run export -- [project-root] [output-dir] [--layout lua|love] [--main entry-point]")
  print("Exports deterministic project Lua files, selected package Lua modules, and file-graph.json.")
  print("")
  print("Flags:")
  print("  --main <file>   Specify the entry point script (default: src/main.lua)")
  print("  --layout <l>    Choose output layout: lua (default) or love")
end

function cli.parse_args(args)
  local options = {
    project = ".",
    output = nil,
    layout = "lua",
    main = "src/main.lua",
  }

  local positionals = {}
  local index = 1

  while index <= #args do
    local arg_value = args[index]

    if arg_value == "--layout" then
      index = index + 1
      options.layout = args[index] or process.fail("--layout requires lua or love")
    elseif arg_value == "--love" then
      options.layout = "love"
    elseif arg_value == "--main" then
      index = index + 1
      options.main = args[index] or process.fail("--main requires an entry-point path")
    elseif arg_value == "--help" or arg_value == "help" then
      print_help()
      os.exit(0)
    else
      positionals[#positionals + 1] = arg_value
    end

    index = index + 1
  end

  options.project = positionals[1] or "."
  options.output = positionals[2]

  if options.layout ~= "lua" and options.layout ~= "love" then
    process.fail("unsupported layout " .. options.layout)
  end

  return options
end

function cli.main(args)
  exporter.export(cli.parse_args(args or {}))
end

return cli

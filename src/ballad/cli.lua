local process = require("ballad.process")
local exporter = require("ballad.exporter")
local partiture = require("ballad.partiture")

local cli = {}

local KNOWN_COMMANDS = {
  export = true,
  play = true,
  help = true,
}

local function print_help()
  print("Usage: ballad <command> [args...]")
  print("")
  print("Commands:")
  print("  export            Export project to dist/ (legacy)")
  print("  play <file>       Execute a partiture.lua pipeline script")
  print("")
  print("Export flags:")
  print("  --main <file>     Specify the entry point script (default: src/main.lua)")
  print("  --layout <l>       Choose output layout: lua (default) or love")
  print("  --plugin <name>   Load a plugin (can be specified multiple times)")
end

function cli.parse_args(args)
  local options = {
    command = nil,
    project = ".",
    output = nil,
    layout = "lua",
    main = "src/main.lua",
    plugins = {},
    partiture_file = nil,
    jobs = 1,
  }

  local positionals = {}
  local index = 1

  while index <= #args do
    local arg_value = args[index]

    if arg_value == "--jobs" or arg_value == "-j" then
      index = index + 1
      options.jobs = tonumber(args[index]) or 1
    elseif arg_value == "--layout" then
      index = index + 1
      options.layout = args[index] or process.fail("--layout requires lua or love")
    elseif arg_value == "--love" then
      options.layout = "love"
    elseif arg_value == "--main" then
      index = index + 1
      options.main = args[index] or process.fail("--main requires an entry-point path")
    elseif arg_value == "--plugin" then
      index = index + 1
      local plugin_spec = args[index] or process.fail("--plugin requires a plugin name")
      local name, params_str = plugin_spec:match("([^:]+):?(.*)")
      local params = {}
      if params_str and params_str ~= "" then
        for k, v in params_str:gmatch("([^=,]+)=?([^,]*)") do
          params[k] = v == "" and true or v
        end
      end
      table.insert(options.plugins, { name = name, params = params })
    elseif arg_value == "--help" or arg_value == "help" then
      print_help()
      os.exit(0)
    else
      positionals[#positionals + 1] = arg_value
    end

    index = index + 1
  end

  -- Backward compatibility: if first positional is not a known command,
  -- treat it as the project directory (old export syntax).
  if #positionals >= 1 and KNOWN_COMMANDS[positionals[1]] then
    options.command = positionals[1]
    if options.command == "play" then
      options.partiture_file = positionals[2]
    else
      options.project = positionals[2] or "."
      options.output = positionals[3]
    end
  elseif #positionals >= 1 then
    -- Old syntax: ballad [project] [output] [flags...]
    options.command = "export"
    options.project = positionals[1] or "."
    options.output = positionals[2]
  else
    options.command = "export"
  end

  if options.layout ~= "lua" and options.layout ~= "love" then
    process.fail("unsupported layout " .. options.layout)
  end

  return options
end

function cli.main(args)
  local options = cli.parse_args(args or {})

  if options.command == "export" then
    exporter.export(options)
  elseif options.command == "play" then
    if not options.partiture_file then
      process.fail("Usage: ballad play <partiture.lua>")
    end
    local p = partiture.load(options.partiture_file, options.jobs)
    print("Partiture loaded: " .. options.partiture_file)
    print("Executing pipeline graph...")
    local results = p:execute()
    print("Pipeline completed. " .. #results .. " explicit sink(s) produced output.")
    for i, sink in ipairs(results) do
      print("  Output " .. i .. ": " .. sink.node.method)
      if sink.result and sink.result.assets then
        local assets = sink.result.assets
        print("    assets=" .. #assets)
        for _, a in ipairs(assets) do
          print("      " .. a.kind .. " " .. (a.virtual_path or a.id))
        end
      end
    end
  elseif options.command == "help" then
    print_help()
  else
    process.fail("Unknown command: " .. options.command)
  end
end

return cli

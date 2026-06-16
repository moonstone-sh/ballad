local process = require("ballad.process")
local partiture = require("ballad.partiture")

local cli = {}

local KNOWN_COMMANDS = {
  play = true,
  help = true,
}

local function print_help()
  print("Usage: ballad [play] <partiture.lua>")
  print("")
  print("Commands:")
  print("  play <file>       Execute a partiture.lua pipeline script")
  print("")
  print("Flags:")
  print("  --jobs, -j <n>    Run native tasks with up to n jobs")
end

function cli.parse_args(args)
  local options = {
    command = nil,
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
    elseif arg_value == "--help" or arg_value == "help" then
      print_help()
      os.exit(0)
    elseif arg_value:sub(1, 1) == "-" then
      process.fail("unknown flag: " .. arg_value)
    else
      positionals[#positionals + 1] = arg_value
    end

    index = index + 1
  end

  if #positionals >= 1 and KNOWN_COMMANDS[positionals[1]] then
    options.command = positionals[1]
    options.partiture_file = positionals[2]
  elseif #positionals >= 1 then
    options.command = "play"
    options.partiture_file = positionals[1]
  else
    options.command = "play"
    options.partiture_file = "partiture.lua"
  end

  return options
end

function cli.main(args)
  local options = cli.parse_args(args or {})

  if options.command == "play" then
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

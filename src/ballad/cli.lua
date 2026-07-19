local process = require("ballad.process")
local partiture = require("ballad.partiture")

local cli = {}

local KNOWN_COMMANDS = {
  play = true,
  help = true,
  init = true,
}

local function print_help()
  print("Usage: ballad <command> [args]")
  print("")
  print("Commands:")
  print("  play <file>       Execute a partiture.lua pipeline script (default)")
  print("  init <template>   Scaffold a partiture.lua from a template")
  print("  help              Show this help message")
  print("")
  print("Templates for init:")
  print("  love2d            Basic LÖVE project layout")
  print("  executable        Ready-to-run app layout with bin/ launcher")
  print("  registry          Moonstone registry package artifact")
  print("")
  print("Flags:")
  print("  --jobs, -j <n>    Run native tasks with up to n jobs")
end

function cli.parse_args(args)
  local options = {
    command = nil,
    partiture_file = nil,
    template = nil,
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
    if options.command == "init" then
      options.template = positionals[2]
    else
      options.partiture_file = positionals[2]
    end
  elseif #positionals >= 1 then
    options.command = "play"
    options.partiture_file = positionals[1]
  else
    options.command = "play"
    options.partiture_file = "partiture.lua"
  end

  return options
end

local function get_cli_src_path()
  -- Use debug.getinfo to find where ballad/cli.lua is located
  local info = debug.getinfo(1, "S")
  if info and info.source and info.source:sub(1, 1) == "@" then
    local path = info.source:sub(2)
    -- path/to/ballad/cli.lua -> path/to
    return path:match("(.*)/ballad/cli.lua$") or path:match("(.*)cli.lua$") or "."
  end
  return "."
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
  elseif options.command == "init" then
    if not options.template then
      process.fail("Usage: ballad init <template>\nRun 'ballad help' for available templates.")
    end
    if io.open("partiture.lua", "r") then
      process.fail("partiture.lua already exists in the current directory.")
    end
    local src_path = get_cli_src_path()
    local template_path = src_path .. "/assets/templates/" .. options.template .. ".lua"
    local fin = io.open(template_path, "r")
    if not fin then
      process.fail("Template not found: " .. options.template .. " (searched in " .. template_path .. ")")
    end
    local content = fin:read("*a")
    fin:close()
    local fout = io.open("partiture.lua", "w")
    if not fout then
      process.fail("Failed to write partiture.lua")
    end
    fout:write(content)
    fout:close()
    print("Successfully initialized partiture.lua from template: " .. options.template)
  elseif options.command == "help" then
    print_help()
  else
    process.fail("Unknown command: " .. options.command)
  end
end

return cli

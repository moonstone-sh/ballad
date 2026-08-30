local process = require("ballad.process")
local partiture = require("ballad.partiture")
local moonstone_contract = require("ballad.moonstone_contract")
local fs = require("ballad.fs")
local path = require("ballad.path")
local dkjson = require("dkjson")

local TEMPLATE_NAMES = { "executable", "love2d", "registry" }
local TEMPLATE_SET = {}
for _, name in ipairs(TEMPLATE_NAMES) do TEMPLATE_SET[name] = true end

local cli = {}

local KNOWN_COMMANDS = {
  play = true,
  help = true,
  init = true,
  ["action-run"] = true,
}

local function print_help()
  print("Usage: ballad <command> [args]")
  print("")
  print("Commands:")
  print("  play <file> [--report <path>] [--lua-path <dir>] [-- args…]  Execute a partiture.lua pipeline script (default)")
  print("  init --template <name>  Scaffold a conventional partiture and Moonstone package script")
  print("  action-run <file> Execute a serialized native action (watcher internal)")
  print("  help              Show this help message")
  print("")
  print("Templates for init:")
  print("  love2d            Basic LÖVE project layout")
  print("  executable        Ready-to-run app layout with bin/ launcher")
  print("  registry          Moonstone registry package artifact")
  print("")
  print("Flags:")
  print("  --jobs, -j <n>    Run native tasks with up to n jobs")
  print("  --report <path>   Write explicit sink results as a machine-readable JSON report")
  print("  --lua-path <dir>  Prepend a pure-Lua module root before loading the partiture (repeatable)")
  print("  --script-name <name>    Moonstone script created by init (default: package)")
  print("  --script-command <cmd>  Override the conventional Ballad script command")
  print("  --no-script             Do not register a Moonstone script during init")
  print("  --force-script          Replace a conflicting Moonstone script during init")
end

local function observed_inputs(pipeline, root)
  local inputs = {}
  local seen = {}
  for _, node in pairs(pipeline._graph.nodes or {}) do
    if node.plugin == "ballad.core.source" and node.result then
      for _, asset in ipairs(node.result.assets or {}) do
        if asset.source_path then
          local absolute = path.absolute(asset.source_path)
          if absolute == root or absolute:sub(1, #root + 1) == root .. "/" then
            local relative = path.relative(absolute, root)
            if not seen[relative] and fs.is_file(absolute) then
              seen[relative] = true
              inputs[#inputs + 1] = {
                path = relative,
                fingerprint = "b3:" .. process.b3sum(absolute),
              }
            end
          end
        end
      end
    end
  end
  table.sort(inputs, function(a, b) return a.path < b.path end)
  return inputs
end

local function write_report(report_path, partiture_file, results, pipeline, invocation_args)
  local root = process.capture("pwd -P")
  local sinks = {}
  for index, sink in ipairs(results) do
    local assets = {}
    for _, asset in ipairs((sink.result and sink.result.assets) or {}) do
      local source_path = asset.source_path or asset.output_path
      local relative_path = nil
      if source_path then
        local absolute = path.absolute(source_path)
        if absolute == root or absolute:sub(1, #root + 1) == root .. "/" then
          relative_path = path.relative(absolute, root)
        else
          process.fail("refusing to report an asset outside the partiture project: " .. absolute)
        end
      end
      assets[#assets + 1] = {
        id = asset.id,
        kind = asset.kind,
        path = relative_path,
        virtual_path = asset.virtual_path,
        metadata = asset.metadata,
      }
    end
    sinks[#sinks + 1] = {
      id = sink.node.id,
      method = sink.node.method,
      product = sink.node.options and sink.node.options.product or nil,
      assets = assets,
    }
  end

  fs.mkdir(path.dirname(report_path))
  local temporary = report_path .. ".tmp"
  fs.write_file(temporary, dkjson.encode({
    version = 2,
    root = ".",
    partiture = partiture_file,
    invocation = {
      fingerprint = os.getenv("BALLAD_EXPORT_FINGERPRINT"),
      orbit = os.getenv("BALLAD_ORBIT_NAME"),
      args = invocation_args or {},
      graph_fingerprint = "b3:" .. process.b3sum_string(pipeline._graph:to_json()),
      inputs = observed_inputs(pipeline, root),
    },
    controls = pipeline._graph.metadata.controls or {},
    sinks = sinks,
  }) .. "\n")
  local replaced, replace_err = fs.replace_file(temporary, report_path)
  if not replaced then
    process.fail("cannot finalize Ballad report at " .. report_path .. ": " .. tostring(replace_err))
  end
end

function cli.parse_args(args)
  local options = {
    command = nil,
    partiture_file = nil,
    template = nil,
    jobs = 1,
    report_path = nil,
    lua_paths = {},
    invocation_args = {},
    register_script = true,
    force_script = false,
    script_name = "package",
    script_command = "moon exec ballad -- play partiture.lua",
  }

  local positionals = {}
  local index = 1

  while index <= #args do
    local arg_value = args[index]

    if arg_value == "--" and index == 1 then
      -- Accept the transport delimiter when a launcher forwards it instead of
      -- consuming it (for example: `moon exec ballad -- init ...`).
    elseif arg_value == "--" then
      index = index + 1
      while index <= #args do
        options.invocation_args[#options.invocation_args + 1] = args[index]
        index = index + 1
      end
      break
    elseif arg_value == "--jobs" or arg_value == "-j" then
      index = index + 1
      options.jobs = tonumber(args[index]) or 1
    elseif arg_value == "--report" then
      index = index + 1
      options.report_path = args[index] or process.fail("--report requires a path")
    elseif arg_value == "--lua-path" then
      index = index + 1
      local lua_path = args[index] or process.fail("--lua-path requires a directory")
      options.lua_paths[#options.lua_paths + 1] = lua_path
    elseif arg_value == "--template" then
      index = index + 1
      options.template = args[index] or process.fail("--template requires a name")
    elseif arg_value == "--script-name" then
      index = index + 1
      options.script_name = args[index] or process.fail("--script-name requires a name")
    elseif arg_value == "--script-command" then
      index = index + 1
      options.script_command = args[index] or process.fail("--script-command requires a command")
    elseif arg_value == "--no-script" then
      options.register_script = false
    elseif arg_value == "--force-script" then
      options.force_script = true
    elseif arg_value == "--moonstone-entrypoint" then
      -- Preserve the experimental init contract while the conventional
      -- `package` entrypoint becomes the default for new invocations.
      options.register_script = true
      options.script_name = "build"
      options.script_command = "ballad play partiture.lua"
    elseif arg_value == "--help" or arg_value == "help" then
      print_help()
      os.exit(0)
    elseif arg_value:sub(1, 1) == "-" then
      options.invocation_args[#options.invocation_args + 1] = arg_value
    else
      if #positionals == 0 then
        positionals[#positionals + 1] = arg_value
      elseif positionals[1] == "play" and #positionals == 1 then
        positionals[#positionals + 1] = arg_value
      elseif KNOWN_COMMANDS[positionals[1]] and #positionals == 1 then
        positionals[#positionals + 1] = arg_value
      else
        options.invocation_args[#options.invocation_args + 1] = arg_value
      end
    end

    index = index + 1
  end

  if #positionals >= 1 and KNOWN_COMMANDS[positionals[1]] then
    options.command = positionals[1]
    if options.command == "init" then
      options.template = options.template or positionals[2]
    elseif options.command == "action-run" then
      options.action_file = positionals[2]
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

local function available_templates()
  return table.concat(TEMPLATE_NAMES, ", ")
end

local function configured_moonstone_bin()
  for _, variable in ipairs({ "MOONSTONE_BIN", "MOONSTONE_CLI" }) do
    local value = os.getenv(variable)
    if value and value ~= "" then return value end
  end
  return "moon"
end

local function moonstone_project_root(start_path)
  local current = path.absolute(start_path or ".")
  while current and current ~= "." do
    if fs.is_file(path.join(current, "moonstone.toml")) then return current end
    local parent = path.dirname(current)
    if parent == current then break end
    current = parent
  end
  return nil
end

local function prepare_moonstone_script(options)
  if not options.register_script then return nil end
  local root = moonstone_project_root(".")
  if not root then
    process.fail("cannot register Moonstone script `" .. options.script_name .. "`: moonstone.toml was not found; "
      .. "run `moon init` first or pass --no-script")
  end
  if path.absolute(".") ~= root then
    process.fail("cannot register Moonstone script `" .. options.script_name .. "` from a subdirectory; "
      .. "run Ballad from the project root " .. root .. " or pass --no-script")
  end
  local moon_bin = configured_moonstone_bin()
  local ok, document = pcall(moonstone_contract.manifest_export, root, moon_bin)
  if not ok then
    process.fail("cannot inspect Moonstone scripts through `moon manifest export`: " .. tostring(document)
      .. "; verify that Moonstone 0.4.2 or newer is on PATH")
  end
  for _, script in ipairs((document.manifest or {}).scripts or {}) do
    if script.name == options.script_name then
      if script.command == options.script_command then return { unchanged = true, root = root } end
      if not options.force_script then
        process.fail("Moonstone script `" .. options.script_name .. "` already exists with a different command\n"
          .. "  existing: " .. tostring(script.command) .. "\n"
          .. "  requested: " .. options.script_command .. "\n"
          .. "Use --force-script to replace it, --script-name to choose another entrypoint, or --no-script.")
      end
    end
  end
  return { root = root, moon_bin = moon_bin }
end

local function register_moonstone_script(options, prepared)
  if not prepared then return end
  if prepared.unchanged then
    print("Moonstone script `" .. options.script_name .. "` already uses the conventional Ballad command.")
    return
  end
  local command = process.quote(prepared.moon_bin) .. " -C " .. process.quote(prepared.root)
    .. " manifest script set " .. process.quote(options.script_name)
    .. " --command " .. process.quote(options.script_command)
  if not process.command_ok(command) then
    os.remove("partiture.lua")
    process.fail("Moonstone could not set script `" .. options.script_name .. "`; partiture.lua was rolled back. "
      .. "Run this command to inspect the failure:\n  " .. command)
  end
  print("Added Moonstone script `" .. options.script_name .. "`: " .. options.script_command)
end

local function apply_lua_paths(lua_paths)
  for index = #lua_paths, 1, -1 do
    local root = lua_paths[index]:gsub("/+$", "")
    if root == "" then process.fail("--lua-path must not be empty") end
    package.path = table.concat({
      root .. "/?.lua",
      root .. "/?/init.lua",
      package.path,
    }, ";")
  end
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
    apply_lua_paths(options.lua_paths)
    local p = partiture.load(options.partiture_file, options.jobs, options.invocation_args)
    print("Partiture loaded: " .. options.partiture_file)
    print("Executing pipeline graph...")
    local results = p:execute()
    if options.report_path then
      write_report(options.report_path, options.partiture_file, results, p, options.invocation_args)
    end
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
      process.fail("Usage: ballad init --template <name>\nAvailable templates: " .. available_templates())
    end
    if #options.invocation_args > 0 then
      process.fail("unknown init option or argument: " .. table.concat(options.invocation_args, " ")
        .. "\nUsage: ballad init --template <name>")
    end
    if not TEMPLATE_SET[options.template] then
      process.fail("unknown template `" .. options.template .. "`; available templates: " .. available_templates())
    end
    if fs.is_file("partiture.lua") then
      process.fail("partiture.lua already exists; move it aside or choose a project without a Ballad definition")
    end
    local prepared_script = prepare_moonstone_script(options)
    local src_path = get_cli_src_path()
    local template_path = src_path .. "/assets/templates/" .. options.template .. ".lua"
    local fin = io.open(template_path, "r")
    if not fin then process.fail("installed Ballad template is missing: " .. template_path) end
    local content = fin:read("*a")
    fin:close()
    local fout = io.open("partiture.lua", "w")
    if not fout then
      process.fail("Failed to write partiture.lua")
    end
    fout:write(content)
    fout:close()
    register_moonstone_script(options, prepared_script)
    print("Successfully initialized partiture.lua from template: " .. options.template)
  elseif options.command == "action-run" then
    if not options.action_file then process.fail("Usage: ballad action-run <action.json>") end
    local ok, err = pcall(require("ballad.native_action").run_file, options.action_file)
    if not ok then process.fail(tostring(err)) end
  elseif options.command == "help" then
    print_help()
  else
    process.fail("Unknown command: " .. options.command)
  end
end

return cli

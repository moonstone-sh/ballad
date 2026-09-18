local c = require("clingy")
local v = require("valua")
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
  local info = debug.getinfo(1, "S")
  if info and info.source and info.source:sub(1, 1) == "@" then
    local p = info.source:sub(2)
    return p:match("(.*)/ballad/cli.lua$") or p:match("(.*)cli.lua$") or "."
  end
  return "."
end

local function build_app()
  local app
  app = c.create({
    name = "ballad",
    version = "0.3.10",
    description = "Deterministic Lua project exporter and bundler for Moonstone",

    root = c.node({
      c.inherit(
        c.flag({ key = "help", aliases = { "-h", "--help" } })
      ),

      c.run(function(ctx)
        io.stdout:write(app:help() .. "\n")
        return 0
      end),

      play = c.node({
        c.arg({ key = "file", schema = v.string(), occurs = { min = 0, max = 1 } }),
        c.option({ key = "jobs", aliases = { "-j", "--jobs" }, value = { schema = v.integer() } }),
        c.option({ key = "report", aliases = { "--report" }, value = { schema = v.string() } }),
        c.option({ key = "lua_path", aliases = { "--lua-path" }, value = { schema = v.string() }, occurs = { min = 0, max = "many" } }),
        c.passthrough("invocation_args"),

        c.run(function(ctx)
          if ctx.args.help then
            io.stdout:write(app:help("play") .. "\n")
            return 0
          end

          local partiture_file = ctx.args.file or "partiture.lua"
          local jobs = ctx.args.jobs or 1
          local lua_paths = ctx.args.lua_path or {}
          local invocation_args = ctx.passthrough or {}
          local report_path = ctx.args.report

          apply_lua_paths(lua_paths)
          local p = partiture.load(partiture_file, jobs, invocation_args)
          print("Partiture loaded: " .. partiture_file)
          print("Executing pipeline graph...")
          local results = p:execute()
          if report_path then
            write_report(report_path, partiture_file, results, p, invocation_args)
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
          return 0
        end),
      }, {
        description = "Execute a partiture.lua pipeline script (default)",
      }),

      init = c.node({
        c.arg({ key = "template_arg", schema = v.string(), occurs = { min = 0, max = 1 } }),
        c.option({ key = "template", aliases = { "--template" }, value = { schema = v.string() } }),
        c.option({ key = "script_name", aliases = { "--script-name" }, value = { schema = v.string() } }),
        c.option({ key = "script_command", aliases = { "--script-command" }, value = { schema = v.string() } }),
        c.flag({ key = "no_script", aliases = { "--no-script" } }),
        c.flag({ key = "force_script", aliases = { "--force-script" } }),
        c.flag({ key = "moonstone_entrypoint", aliases = { "--moonstone-entrypoint" } }),
        c.passthrough("extra_args"),

        c.run(function(ctx)
          if ctx.args.help then
            io.stdout:write(app:help("init") .. "\n")
            return 0
          end

          local template = ctx.args.template or ctx.args.template_arg
          if not template then
            process.fail("Usage: ballad init --template <name>\nAvailable templates: " .. available_templates())
          end

          local extra_args = ctx.passthrough or {}
          if #extra_args > 0 then
            process.fail("unknown init option or argument: " .. table.concat(extra_args, " ")
              .. "\nUsage: ballad init --template <name>")
          end

          if not TEMPLATE_SET[template] then
            process.fail("unknown template `" .. template .. "`; available templates: " .. available_templates())
          end

          if fs.is_file("partiture.lua") then
            process.fail("partiture.lua already exists; move it aside or choose a project without a Ballad definition")
          end

          local options = {
            template = template,
            register_script = not ctx.args.no_script,
            force_script = ctx.args.force_script,
            script_name = ctx.args.script_name or "package",
            script_command = ctx.args.script_command or "moon exec ballad -- play partiture.lua",
          }

          if ctx.args.moonstone_entrypoint then
            options.register_script = true
            options.script_name = "build"
            options.script_command = "ballad play partiture.lua"
          end

          local prepared_script = prepare_moonstone_script(options)
          local src_path = get_cli_src_path()
          local template_path = src_path .. "/assets/templates/" .. template .. ".lua"
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
          print("Successfully initialized partiture.lua from template: " .. template)
          return 0
        end),
      }, {
        description = "Scaffold a conventional partiture and Moonstone package script",
      }),

      ["action-run"] = c.node({
        -- `file` is declared optional so that `--help` can reach the handler
        -- below; clingy validates required-positional minima during parsing
        -- (parser.lua "Missing required argument"), before any c.run executes,
        -- and it has no built-in --help short-circuit. Requiredness is enforced
        -- in the handler instead.
        c.arg({ key = "file", schema = v.string(), occurs = { min = 0, max = 1 } }),

        c.run(function(ctx)
          if ctx.args.help then
            io.stdout:write(app:help("action-run") .. "\n")
            return 0
          end
          if not ctx.args.file then
            process.fail("action-run requires a FILE argument")
          end
          local ok, err = pcall(require("ballad.native_action").run_file, ctx.args.file)
          if not ok then process.fail(tostring(err)) end
          return 0
        end),
      }, {
        description = "Execute a serialized native action (watcher internal)",
      }),
    }),
  })

  return app
end

cli.app = build_app()

function cli.main(args)
  args = args or {}
  local copy = {}
  for i, a in ipairs(args) do copy[i] = a end

  if copy[1] == "--" then
    table.remove(copy, 1)
  end

  local KNOWN = {
    play = true,
    init = true,
    ["action-run"] = true,
    help = true,
    ["--help"] = true,
    ["-h"] = true,
  }

  if #copy == 0 then
    copy = { "play" }
  elseif not KNOWN[copy[1]] and copy[1]:sub(1, 1) ~= "-" then
    table.insert(copy, 1, "play")
  elseif not KNOWN[copy[1]] and (copy[1] == "-j" or copy[1] == "--jobs" or copy[1] == "--report" or copy[1] == "--lua-path") then
    table.insert(copy, 1, "play")
  end

  local app = build_app()
  local exit_code = app:run(copy)
  if exit_code and exit_code ~= 0 then
    os.exit(exit_code)
  end
end

return cli

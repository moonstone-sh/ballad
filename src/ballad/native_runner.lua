local native_runner = {}
local process = require("ballad.process")
local path = require("ballad.path")
local fs = require("ballad.fs")

function native_runner.find_tool(tool)
  if path.is_absolute(tool) then
    return tool
  end
  if tool:find(":") then
    error("Moonstone-provisioned native helpers are not implemented yet: " .. tool)
  end
  local found = process.capture("which " .. process.quote(tool) .. " 2>/dev/null")
  if found == "" then
    return nil
  end
  return found
end

function native_runner.run(opts)
  local tool = opts.tool
  local args = opts.args
  local outputs = opts.outputs
  if not tool then error("native_task: missing tool") end
  if not args then error("native_task: missing args") end
  if not outputs or #outputs == 0 then error("native_task: missing outputs") end

  local tool_path = native_runner.find_tool(tool)
  if not tool_path then
    return {
      ok = false,
      missing_tool = true,
      tool = tool,
      description = opts.description or "native task",
      exit_code = -1,
      stdout = "",
      stderr = "",
      missing_outputs = outputs,
    }
  end

  local cwd = opts.cwd or "."
  local description = opts.description or "native task"

  local cmd_parts = {process.quote(tool_path)}
  for _, arg in ipairs(args) do
    table.insert(cmd_parts, process.quote(arg))
  end
  local cmd = table.concat(cmd_parts, " ")

  if not fs.is_dir(cwd) then
    fs.mkdir(cwd)
  end

  local stdout_text = ""
  local stderr_text = ""
  local exit_code = 0

  local stdout_file = os.tmpname()
  local stderr_file = os.tmpname()
  local exit_file = os.tmpname()

  os.execute("(" .. cmd .. " > " .. process.quote(stdout_file) .. " 2> " .. process.quote(stderr_file) .. "; echo $? > " .. process.quote(exit_file) .. ")")

  local f = io.open(exit_file, "r")
  if f then
    exit_code = tonumber(f:read("*l")) or 0
    f:close()
  end

  f = io.open(stdout_file, "r")
  if f then
    stdout_text = f:read("*a") or ""
    f:close()
  end

  f = io.open(stderr_file, "r")
  if f then
    stderr_text = f:read("*a") or ""
    f:close()
  end

  os.remove(stdout_file)
  os.remove(stderr_file)
  os.remove(exit_file)

  local missing_outputs = {}
  for _, out in ipairs(outputs) do
    if not fs.read_file(out) and not fs.is_dir(out) then
      table.insert(missing_outputs, out)
    end
  end

  return {
    ok = (exit_code == 0) and (#missing_outputs == 0),
    missing_tool = false,
    tool = tool,
    cmd = cmd,
    cwd = cwd,
    description = description,
    exit_code = exit_code,
    stdout = stdout_text,
    stderr = stderr_text,
    missing_outputs = missing_outputs,
  }
end

function native_runner.spawn_background(opts, stdout_file, stderr_file, exit_file)
  local tool_path = native_runner.find_tool(opts.tool)
  if not tool_path then
    return nil, "tool not found: " .. opts.tool
  end

  local cmd_parts = {process.quote(tool_path)}
  for _, arg in ipairs(opts.args) do
    table.insert(cmd_parts, process.quote(arg))
  end
  local cmd = table.concat(cmd_parts, " ")

  local env_prefix = ""
  for k, v in pairs(opts.env or {}) do
    env_prefix = env_prefix .. k .. "=" .. process.quote(v) .. " "
  end
  if env_prefix ~= "" then
    cmd = env_prefix .. cmd
  end

  if opts.cwd then
    cmd = "cd " .. process.quote(opts.cwd) .. " && " .. cmd
  end

  os.execute("(" .. cmd .. " > " .. process.quote(stdout_file) .. " 2> " .. process.quote(stderr_file) .. "; echo $? > " .. process.quote(exit_file) .. ") &")
  return true
end

function native_runner.poll_background(stdout_file, stderr_file, exit_file)
  local f = io.open(exit_file, "r")
  if not f then
    return nil
  end
  local exit_code = tonumber(f:read("*l")) or 0
  f:close()

  local stdout_text = ""
  f = io.open(stdout_file, "r")
  if f then
    stdout_text = f:read("*a") or ""
    f:close()
  end

  local stderr_text = ""
  f = io.open(stderr_file, "r")
  if f then
    stderr_text = f:read("*a") or ""
    f:close()
  end

  return {
    exit_code = exit_code,
    stdout = stdout_text,
    stderr = stderr_text,
  }
end

return native_runner

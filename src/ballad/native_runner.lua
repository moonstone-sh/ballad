---@meta

---@class NativeRunResult
---@field ok boolean whether execution succeeded (exit code 0 and all outputs present)
---@field tool string executable tool name or path
---@field resolved_tool string resolved absolute path to executable tool
---@field description string description of the task
---@field exit_code integer process exit code
---@field stdout string captured stdout text
---@field stderr string captured stderr text
---@field missing_outputs string[] list of declared outputs missing after execution
---@field missing_tool? boolean set if tool was not found in PATH

local native_runner = {}
local process = require("ballad.process")
local path = require("ballad.path")
local fs = require("ballad.fs")

---Resolve a tool name to an executable path.
---@param tool string tool name or path
---@return string|nil resolved path or nil if not found
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
  local tool = opts.tool or (opts.cmd and opts.cmd:match("^%S+"))
  local args = opts.args or {}
  local cmd_opt = opts.cmd
  local outputs = opts.outputs or {}
  if not tool then error("native_task: missing tool or cmd") end

  local tool_path = native_runner.find_tool(tool)
  if not tool_path then
    return {
      ok = false,
      missing_tool = true,
      tool = tool,
      description = opts.description or cmd_opt or "native task",
      exit_code = -1,
      stdout = "",
      stderr = "",
      missing_outputs = outputs,
    }
  end

  local cwd = opts.cwd or "."
  local description = opts.description or cmd_opt or (tool .. " " .. table.concat(args, " "))

  local cmd
  if cmd_opt then
    local first_token = cmd_opt:match("^%S+")
    if first_token and (first_token == tool or first_token == process.quote(tool) or first_token == tool_path or first_token == process.quote(tool_path)) then
      cmd = process.quote(tool_path) .. cmd_opt:sub(#first_token + 1)
    else
      cmd = process.quote(tool_path) .. " " .. cmd_opt
    end
  else
    local cmd_parts = {process.quote(tool_path)}
    for _, arg in ipairs(args) do
      table.insert(cmd_parts, process.quote(arg))
    end
    cmd = table.concat(cmd_parts, " ")
  end

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
  local tool = opts.tool or (opts.cmd and opts.cmd:match("^%S+"))
  if not tool then
    return nil, "missing tool or cmd"
  end
  local tool_path = native_runner.find_tool(tool)
  if not tool_path then
    return nil, "tool not found: " .. tool
  end

  local cmd
  if opts.cmd then
    local first_token = opts.cmd:match("^%S+")
    if first_token and (first_token == tool or first_token == process.quote(tool) or first_token == tool_path or first_token == process.quote(tool_path)) then
      cmd = process.quote(tool_path) .. opts.cmd:sub(#first_token + 1)
    else
      cmd = process.quote(tool_path) .. " " .. opts.cmd
    end
  else
    local cmd_parts = {process.quote(tool_path)}
    for _, arg in ipairs(opts.args or {}) do
      table.insert(cmd_parts, process.quote(arg))
    end
    cmd = table.concat(cmd_parts, " ")
  end

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

local variants_ok, variants = pcall(function() return require("moonstone.variants") end)
local target_ok, target = pcall(function() return require("moonstone.target") end)
if variants_ok and target_ok then variants.install(target) end

local host = require("ballad.platform")
local windows = require("ballad.windows_command")
local process = {}

function process.is_windows()
  return host.windows
end

function process.platform()
  return process.is_windows() and "windows" or "posix"
end

local function status_code(status, why, code)
  if type(status) == "number" then return status end
  if status == true then return 0 end
  return code or 1
end

function process.quote(value, platform)
  value = tostring(value)
  if (platform or process.platform()) ~= "windows" then
    return "'" .. value:gsub("'", "'\\''") .. "'"
  end
  -- CommandLineToArgvW-compatible quoting for an argv element.  The command
  -- processor still performs percent expansion, so structured tasks reject
  -- legacy shell strings rather than pretending they are portable.
  local escaped = value:gsub('(\\*)"', function(slashes) return slashes .. slashes .. '\\"' end)
  escaped = escaped:gsub('(\\+)$', '%1%1')
  return '"' .. escaped .. '"'
end

function process.fail(message)
  io.stderr:write("ballad: " .. message .. "\n")
  os.exit(1)
end

function process.command_ok(command)
  local ok, why, code = os.execute(command)
  return status_code(ok, why, code) == 0
end

-- Legacy shell capture. New native work must use run({ tool, args, cwd, env })
-- so argument boundaries are preserved.
function process.capture(command)
  local pipe = io.popen(command, "r")
  if not pipe then return "" end
  local output = pipe:read("*a") or ""
  pipe:close()
  return (output:gsub("%s+$", ""))
end

local function trim_output(value)
  return (value or ""):gsub("%s+$", "")
end

function process.cwd()
  local command = process.is_windows() and "cd" or "pwd -P"
  return process.capture(command)
end

function process.find_tool(tool)
  if tool:find(":", 1, true) and not tool:match("^[A-Za-z]:[/\\]") then
    error("Moonstone-provisioned native helpers are not implemented yet: " .. tool)
  end
  if tool:match("^[A-Za-z]:[/\\]") or tool:sub(1, 1) == "/" or tool:sub(1, 2) == "./" or tool:sub(1, 2) == ".\\" then
    return tool
  end
  local command = process.is_windows()
    and ("where " .. process.quote(tool) .. " 2>NUL")
    or ("command -v " .. process.quote(tool) .. " 2>/dev/null")
  local found = process.capture(command):match("([^\r\n]+)")
  return found ~= "" and found or nil
end

---Build the host-shell command for a structured process invocation.
---`platform` is primarily useful for tests; production calls use the host.
function process.build_command(opts, platform)
  if not opts or type(opts.tool) ~= "string" or opts.tool == "" then error("process.run requires tool") end
  platform = platform or process.platform()
  local command
  if platform == process.platform() then
    command = host.command(opts)
  elseif platform == "windows" then
    command = windows.command(opts)
  else
    error("cannot serialize a non-host POSIX command on Windows")
  end
  if opts.stdout_file then
    local stdout_file = platform == "windows" and windows.value(opts.stdout_file, "stdout_file") or opts.stdout_file
    command = command .. " > " .. (platform == "windows" and windows.quote(stdout_file, "stdout_file") or process.quote(stdout_file, platform))
  end
  if opts.stderr_file then
    local stderr_file = platform == "windows" and windows.value(opts.stderr_file, "stderr_file") or opts.stderr_file
    command = command .. " 2> " .. (platform == "windows" and windows.quote(stderr_file, "stderr_file") or process.quote(stderr_file, platform))
  end
  return command
end

---Run a structured argv task and capture output in caller-owned temporary files.
---@param opts {tool:string,args?:string[],cwd?:string,env?:table<string,string>,stdout_file?:string,stderr_file?:string}
---@return {exit_code:integer, command:string}
function process.run(opts)
  local command = process.build_command(opts)
  local ok, why, code = os.execute(command)
  return { exit_code = status_code(ok, why, code), command = command }
end

---Run a structured process and return its captured output.  This is the
---portable replacement for composing `cd`, redirection, and a command string.
function process.capture_run(opts)
  local stdout_file = os.tmpname()
  local stderr_file = os.tmpname()
  local run_opts = {}
  for key, value in pairs(opts or {}) do run_opts[key] = value end
  run_opts.stdout_file = stdout_file
  run_opts.stderr_file = stderr_file
  local result = process.run(run_opts)
  local stdout = ""
  local stderr = ""
  local file = io.open(stdout_file, "rb")
  if file then stdout = file:read("*a") or ""; file:close() end
  file = io.open(stderr_file, "rb")
  if file then stderr = file:read("*a") or ""; file:close() end
  os.remove(stdout_file)
  os.remove(stderr_file)
  result.stdout = trim_output(stdout)
  result.stderr = trim_output(stderr)
  return result
end

function process.b3sum(path)
  local hash
  if process.is_windows() then
    local result = process.capture_run({tool=os.getenv("MOONSTONE_CLI") or os.getenv("MOONSTONE_BIN") or "moon", args={"artifact", "hash", "--", path}})
    if result.exit_code ~= 0 then error("Moonstone file hashing failed: " .. result.stderr) end
    hash = result.stdout
  else
    hash = process.capture("b3sum --no-names " .. process.quote(path))
  end
  if #hash ~= 64 or not hash:match("^[0-9a-f]+$") then error("BLAKE3 hashing failed for " .. path) end
  return hash
end

function process.b3sum_string(content)
  local tmp = os.tmpname()
  local f = io.open(tmp, "wb")
  if f then
    f:write(content)
    f:close()
    local ok, hash = pcall(process.b3sum, tmp)
    os.remove(tmp)
    if not ok then error(hash) end
    return hash
  end
  error("Cannot create temporary file for BLAKE3 hashing")
end

return process

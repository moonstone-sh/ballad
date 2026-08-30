local process = {}

function process.is_windows()
  return package.config:sub(1, 1) == "\\" or os.getenv("OS") == "Windows_NT"
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

local function posix_command(opts)
  local parts = { process.quote(opts.tool) }
  for _, arg in ipairs(opts.args or {}) do parts[#parts + 1] = process.quote(arg) end
  local command = table.concat(parts, " ")
  local env = {}
  for key, value in pairs(opts.env or {}) do env[#env + 1] = key .. "=" .. process.quote(value) end
  table.sort(env)
  if #env > 0 then command = table.concat(env, " ") .. " " .. command end
  return "cd " .. process.quote(opts.cwd or ".") .. " && " .. command
end

-- Lua 5.1/LuaJIT exposes only os.execute, which delegates to cmd.exe on
-- Windows. It cannot call CreateProcessW with a real argv vector. Quoting is
-- not a sufficient command-processor security boundary, so accept only values
-- that cannot alter cmd parsing. Callers needing the rejected characters must
-- put them in a file or use a purpose-built helper executable.
local function windows_value(value, subject)
  if type(value) ~= "string" then
    error("Windows process " .. subject .. " must be a string")
  end
  if value:find("\r", 1, true) or value:find("\n", 1, true) or value:find("\0", 1, true) then
    error("Windows process " .. subject .. " cannot contain a newline or NUL")
  end
  if value:find('[&|<>()^"!%%]') then
    error("Windows process " .. subject .. " contains a cmd metacharacter; use a helper or a file for this value")
  end
  if value:sub(-1) == "\\" then
    error("Windows process " .. subject .. " cannot end with \\: use a forward slash path spelling")
  end
  return value
end

-- `cmd` does not use CRT backslash-quote escaping. Values above exclude the
-- syntax that would make ordinary cmd quotes ambiguous, including a trailing
-- backslash that the child CRT could consume as the closing quote.
local function windows_quote(value, subject)
  return '"' .. windows_value(value, subject) .. '"'
end

local function windows_command(opts)
  local parts = { windows_quote(opts.tool, "tool") }
  for index, arg in ipairs(opts.args or {}) do
    parts[#parts + 1] = windows_quote(arg, "argument " .. index)
  end
  local command = table.concat(parts, " ")
  local env = {}
  for key, value in pairs(opts.env or {}) do
    if type(key) ~= "string" or not key:match("^[A-Za-z_][A-Za-z0-9_]*$") then
      error("Windows process environment names must match [A-Za-z_][A-Za-z0-9_]*: " .. tostring(key))
    end
    env[#env + 1] = key .. "=" .. windows_value(value, "environment " .. key)
  end
  table.sort(env)
  local prefix = {
    "setlocal DisableDelayedExpansion",
    "pushd " .. windows_quote(opts.cwd or ".", "cwd"),
  }
  for _, assignment in ipairs(env) do prefix[#prefix + 1] = "set \"" .. assignment .. "\"" end
  prefix[#prefix + 1] = command
  -- os.execute already enters cmd.exe. This nested cmd owns the whole
  -- compound payload; ordinary inner quotes remain ordinary cmd quotes.
  return 'cmd /d /v:off /s /c "' .. table.concat(prefix, " && ") .. '"'
end

---Build the host-shell command for a structured process invocation.
---`platform` is primarily useful for tests; production calls use the host.
function process.build_command(opts, platform)
  if not opts or type(opts.tool) ~= "string" or opts.tool == "" then error("process.run requires tool") end
  platform = platform or process.platform()
  local command = platform == "windows" and windows_command(opts) or posix_command(opts)
  if opts.stdout_file then
    local stdout_file = platform == "windows" and windows_value(opts.stdout_file, "stdout_file") or opts.stdout_file
    command = command .. " > " .. (platform == "windows" and windows_quote(stdout_file, "stdout_file") or process.quote(stdout_file, platform))
  end
  if opts.stderr_file then
    local stderr_file = platform == "windows" and windows_value(opts.stderr_file, "stderr_file") or opts.stderr_file
    command = command .. " 2> " .. (platform == "windows" and windows_quote(stderr_file, "stderr_file") or process.quote(stderr_file, platform))
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
  return process.capture("b3sum --no-names " .. process.quote(path))
end

function process.b3sum_string(content)
  local tmp = os.tmpname()
  local f = io.open(tmp, "wb")
  if f then
    f:write(content)
    f:close()
    local hash = process.b3sum(tmp)
    os.remove(tmp)
    return hash
  end
  return ""
end

return process

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


return { command = windows_command, value = windows_value, quote = windows_quote }

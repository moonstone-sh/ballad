-- Generated launcher content belongs at the platform boundary, not in layout
-- plugins. Layouts provide canonical slash-separated virtual paths.
local launcher = {}

local function win_path(value)
  return tostring(value):gsub("/", "\\")
end

local function windows_lua_path(libexec_root, roots)
  local parts = {}
  for _, root in ipairs(roots) do
    local win_root = win_path(root)
    parts[#parts + 1] = "%LIBEXEC%\\" .. win_root .. "\\?.lua"
    parts[#parts + 1] = "%LIBEXEC%\\" .. win_root .. "\\?\\init.lua"
  end
  parts[#parts + 1] = "%LUA_PATH%"
  parts[#parts + 1] = ";"
  return table.concat(parts, ";")
end

local function windows_lua_bin(interpreter)
  interpreter = win_path(interpreter or "lua")
  if not interpreter:lower():match("%.exe$") then interpreter = interpreter .. ".exe" end
  return {
    'if exist "%ROOT%\\bin\\lua.exe" (',
    '  set "LUA_BIN=%ROOT%\\bin\\lua.exe"',
    ') else if exist "%ROOT%\\bin\\luajit.exe" (',
    '  set "LUA_BIN=%ROOT%\\bin\\luajit.exe"',
    ') else if not "%BALLAD_LUA%"=="" (',
    '  set "LUA_BIN=%BALLAD_LUA%"',
    ") else (",
    '  set "LUA_BIN=' .. interpreter .. '"',
    ")",
  }
end

function launcher.windows_libexec(opts)
  local lines = {
    "@echo off",
    "setlocal DisableDelayedExpansion",
    "for %%I in (\"%~dp0..\") do set \"ROOT=%%~fI\"",
    'set "LIBEXEC=%ROOT%\\' .. win_path(opts.libexec_root) .. '"',
  }
  if not opts.direct then
    for _, line in ipairs(windows_lua_bin(opts.interpreter)) do lines[#lines + 1] = line end
    lines[#lines + 1] = 'set "LUA_PATH=' .. windows_lua_path(opts.libexec_root, opts.lua_paths or { "lua", "src" }) .. '"'
    lines[#lines + 1] = 'set "LUA_CPATH=%LIBEXEC%\\lib\\?.dll;%LIBEXEC%\\lib\\?\\?.dll;%LUA_CPATH%;;"'
  end
  if opts.path_prepend then lines[#lines + 1] = 'set "PATH=%LIBEXEC%\\bin;%PATH%"' end
  if opts.direct then
    lines[#lines + 1] = '"%LIBEXEC%\\' .. win_path(opts.entry) .. '" %*'
  else
    lines[#lines + 1] = '"%LUA_BIN%" "%LIBEXEC%\\' .. win_path(opts.entry) .. '" %*'
  end
  lines[#lines + 1] = "exit /b %ERRORLEVEL%"
  return table.concat(lines, "\r\n") .. "\r\n"
end

function launcher.windows_flat(opts)
  local lines = {
    "@echo off",
    "setlocal DisableDelayedExpansion",
    'set "ROOT=%~dp0"',
    'if "%ROOT:~-1%"=="\\" set "ROOT=%ROOT:~0,-1%"',
  }
  for _, line in ipairs(windows_lua_bin(opts.interpreter)) do lines[#lines + 1] = line end
  lines[#lines + 1] = 'set "LUA_PATH=%ROOT%\\lua\\?.lua;%ROOT%\\lua\\?\\init.lua;%ROOT%\\src\\?.lua;%ROOT%\\src\\?\\init.lua;%LUA_PATH%;;"'
  lines[#lines + 1] = 'set "LUA_CPATH=%ROOT%\\lib\\?.dll;%ROOT%\\lib\\?\\?.dll;%LUA_CPATH%;;"'
  lines[#lines + 1] = '"%LUA_BIN%" "%ROOT%\\' .. win_path(opts.entry) .. '" %*'
  lines[#lines + 1] = "exit /b %ERRORLEVEL%"
  return table.concat(lines, "\r\n") .. "\r\n"
end

return launcher

local function quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end
local function posix_command(opts)
  local parts = { quote(opts.tool) }
  for _, arg in ipairs(opts.args or {}) do parts[#parts + 1] = quote(arg) end
  local command = table.concat(parts, " ")
  local env = {}
  for key, value in pairs(opts.env or {}) do env[#env + 1] = key .. "=" .. quote(value) end
  table.sort(env)
  if #env > 0 then command = table.concat(env, " ") .. " " .. command end
  return "cd " .. quote(opts.cwd or ".") .. " && " .. command
end


return { windows = false, command = posix_command, cwd_command = "pwd -P" }

local process = {}

function process.quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function process.fail(message)
  io.stderr:write("ballad: " .. message .. "\n")
  os.exit(1)
end

function process.command_ok(command)
  local ok, _, code = os.execute(command)
  if type(ok) == "number" then return ok == 0 end
  return ok == true and (code == nil or code == 0)
end

function process.capture(command)
  local pipe = assert(io.popen(command, "r"))
  local output = pipe:read("*a")
  pipe:close()
  return (output:gsub("%s+$", ""))
end

return process

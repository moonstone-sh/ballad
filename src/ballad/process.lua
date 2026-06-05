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

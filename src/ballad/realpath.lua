local process = require("ballad.process")
return { resolve = function(directory)
  local resolved = process.capture("cd " .. process.quote(directory) .. " && pwd -P")
  assert(resolved ~= "", "cannot resolve directory: " .. directory)
  return resolved
end }

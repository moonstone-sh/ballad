-- Portable path globs. **/ matches zero or more complete directories.
local M = {}

function M.matches(value, glob)
  value = tostring(value):gsub("\\", "/")
  glob = tostring(glob):gsub("\\", "/")
  local memo = {}
  local function match(v, g)
    local key = v .. ":" .. g
    if memo[key] ~= nil then return memo[key] end
    local result = false
    if g > #glob then
      result = v > #value
    elseif glob:sub(g, g + 2) == "**/" then
      result = match(v, g + 3)
      local slash = value:find("/", v, true)
      while not result and slash do
        result = match(slash + 1, g + 3)
        slash = value:find("/", slash + 1, true)
      end
    elseif glob:sub(g, g) == "*" then
      local recursive = glob:sub(g + 1, g + 1) == "*"
      local next_g = g + (recursive and 2 or 1)
      result = match(v, next_g)
      local cursor = v
      while not result and cursor <= #value and (recursive or value:sub(cursor, cursor) ~= "/") do
        cursor = cursor + 1
        result = match(cursor, next_g)
      end
    elseif v <= #value and value:sub(v, v) == glob:sub(g, g) then
      result = match(v + 1, g + 1)
    end
    memo[key] = result
    return result
  end
  return match(1, 1)
end

return M

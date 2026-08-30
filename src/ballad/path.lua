local process = require("ballad.process")

-- Filesystem paths use a canonical forward-slash spelling on every host.  The
-- Win32 APIs used by Lua accept it, and keeping layout paths canonical avoids
-- making file graphs and cache keys host-dependent.
local path = {}

local function platform_name(platform)
  return platform or (process.is_windows() and "windows" or "posix")
end

local function is_windows(platform)
  return platform_name(platform) == "windows"
end

local function split(value)
  local result = {}
  for segment in value:gmatch("[^/]+") do result[#result + 1] = segment end
  return result
end

local function prefix_for(value, platform)
  value = tostring(value):gsub("\\", "/")
  if is_windows(platform) then
    local drive, rest = value:match("^([A-Za-z]):(/.*)$")
    if drive then return drive:upper() .. ":/", rest:sub(2), "drive" end
    drive, rest = value:match("^([A-Za-z]):(.*)$")
    if drive then return drive:upper() .. ":", rest, "drive-relative" end
    local server, share, tail = value:match("^//([^/]+)/([^/]+)(.*)$")
    if server and share then return "//" .. server .. "/" .. share, tail:gsub("^/", ""), "unc" end
  end
  if value:sub(1, 1) == "/" then return "/", value:sub(2), "root" end
  return "", value, "relative"
end

function path.is_windows()
  return process.is_windows()
end

function path.normalize(value, platform)
  if value == nil or value == "" then return "." end
  local prefix, remainder, kind = prefix_for(value, platform)
  local parts = {}
  for _, segment in ipairs(split(remainder)) do
    if segment ~= "." and segment ~= "" then
      if segment == ".." then
        if #parts > 0 and parts[#parts] ~= ".." then
          table.remove(parts)
        elseif kind == "relative" or kind == "drive-relative" then
          parts[#parts + 1] = segment
        end
      else
        parts[#parts + 1] = segment
      end
    end
  end
  local tail = table.concat(parts, "/")
  if prefix == "/" then return tail == "" and "/" or "/" .. tail end
  if kind == "drive" then return tail == "" and prefix or prefix .. tail end
  if kind == "unc" then return tail == "" and prefix or prefix .. "/" .. tail end
  if kind == "drive-relative" then return prefix .. tail end
  return tail == "" and "." or tail
end

function path.join(...)
  local parts = { ... }
  local platform = nil
  local combined = ""
  for _, value in ipairs(parts) do
    if value ~= nil and value ~= "" then
      local normalized_value = tostring(value):gsub("\\", "/")
      if combined == "" then
        combined = normalized_value
      elseif path.is_absolute(normalized_value, platform) then
        combined = normalized_value
      else
        combined = combined:gsub("/+$", "") .. "/" .. normalized_value
      end
    end
  end
  return path.normalize(combined, platform)
end

function path.dirname(value, platform)
  local normalized = path.normalize(value, platform)
  if path.is_root(normalized, platform) then return normalized end
  local parent = normalized:match("^(.*)/[^/]+$")
  if parent and parent ~= "" then return parent end
  if normalized:match("^[A-Za-z]:[^/]+$") then return normalized:sub(1, 2) end
  return "."
end

function path.basename(value, platform)
  local normalized = path.normalize(value, platform)
  if path.is_root(normalized, platform) then return normalized end
  return normalized:match("([^/]+)$") or normalized
end

function path.is_absolute(value, platform)
  local prefix, _, kind = prefix_for(value, platform)
  return prefix == "/" or kind == "drive" or kind == "unc"
end

function path.is_root(value, platform)
  local normalized = path.normalize(value, platform)
  if normalized == "/" then return true end
  if is_windows(platform) then
    return normalized:match("^[A-Za-z]:/$") ~= nil or normalized:match("^//[^/]+/[^/]+$") ~= nil
  end
  return false
end

function path.absolute(value)
  if path.is_absolute(value) then return path.normalize(value) end
  return path.join(process.cwd(), value)
end

function path.contains(root, value, platform)
  local normalized_root = path.normalize(root, platform)
  local normalized_value = path.normalize(value, platform)
  if normalized_root == "." and not path.is_absolute(normalized_value, platform) then
    return normalized_value == "." or (normalized_value ~= ".." and normalized_value:sub(1, 3) ~= "../")
  end
  if is_windows(platform) then
    normalized_root = normalized_root:lower()
    normalized_value = normalized_value:lower()
  end
  return normalized_value == normalized_root
    or normalized_value:sub(1, #normalized_root + 1) == normalized_root:gsub("/+$", "") .. "/"
end

function path.relative(value, root, platform)
  local normalized_root = path.normalize(root, platform)
  local normalized_value = path.normalize(value, platform)
  local compare_root, compare_value = normalized_root, normalized_value
  if is_windows(platform) then
    compare_root, compare_value = compare_root:lower(), compare_value:lower()
  end
  if compare_value == compare_root then return "." end
  if compare_root == "." and not path.is_absolute(normalized_value, platform)
    and compare_value ~= ".." and compare_value:sub(1, 3) ~= "../" then
    return normalized_value
  end
  local prefix = compare_root:gsub("/+$", "") .. "/"
  if compare_value:sub(1, #prefix) ~= prefix then
    error(normalized_value .. " is outside " .. normalized_root)
  end
  return normalized_value:sub(#prefix + 1)
end

function path.module_name(relative_path)
  return relative_path:gsub("\\", "/"):gsub("%.lua$", ""):gsub("/init$", ""):gsub("/", ".")
end

function path.abi_directory(abi)
  local major, minor = abi:match("^lua(%d)(%d)$")
  if major and minor then return major .. "." .. minor end
  major, minor = abi:match("^lua%-(%d)%.(%d)$")
  if major and minor then return major .. "." .. minor end
  return abi
end

return path

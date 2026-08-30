local process = require("ballad.process")
local path = require("ballad.path")

local fs = {}

function fs.read_file(file_path)
  local file, err = io.open(file_path, "rb")
  if not file then return nil, err end
  local content = file:read("*a")
  file:close()
  return content
end

function fs.write_file(file_path, content)
  local file, err = io.open(file_path, "wb")
  if not file then process.fail("cannot write " .. file_path .. ": " .. tostring(err)) end
  file:write(content)
  file:close()
end

function fs.is_file(file_path)
  local f = io.open(file_path, "rb")
  if f then f:close(); return true end
  return false
end

function fs.mkdir(dir_path)
  if dir_path == "" or dir_path == "." then return end
  local command
  if process.is_windows() then
    command = "if not exist " .. process.quote(dir_path) .. " mkdir " .. process.quote(dir_path)
  else
    command = "mkdir -p " .. process.quote(dir_path)
  end
  if not process.command_ok(command) then process.fail("cannot create directory " .. dir_path) end
end

local function unsafe_tree_path(tree_path)
  return tree_path == "" or tree_path == "." or path.is_root(tree_path)
end

function fs.remove_tree(tree_path)
  if unsafe_tree_path(tree_path) then process.fail("refusing to remove unsafe output path") end
  local command
  if process.is_windows() then
    command = "if exist " .. process.quote(tree_path) .. " rmdir /s /q " .. process.quote(tree_path)
  else
    command = "rm -rf " .. process.quote(tree_path)
  end
  if not process.command_ok(command) then process.fail("cannot reset output directory " .. tree_path) end
end

function fs.copy_file(source, destination)
  fs.mkdir(path.dirname(destination))
  local input, input_err = io.open(source, "rb")
  if not input then process.fail("cannot read " .. source .. ": " .. tostring(input_err)) end
  local output, output_err = io.open(destination, "wb")
  if not output then
    input:close()
    process.fail("cannot write " .. destination .. ": " .. tostring(output_err))
  end
  while true do
    local chunk = input:read(64 * 1024)
    if not chunk then break end
    local ok, err = output:write(chunk)
    if not ok then
      input:close()
      output:close()
      process.fail("cannot copy " .. source .. " to " .. destination .. ": " .. tostring(err))
    end
  end
  input:close()
  output:close()
end

---Replace a completed file without invoking a platform shell utility.
---POSIX rename is atomic. Windows' Lua rename cannot replace an existing file,
---so preserve the previous report until the replacement is known to succeed.
function fs.replace_file(source, destination)
  if fs.is_dir(destination) then return nil, "destination is a directory: " .. destination end
  local ok, err = os.rename(source, destination)
  if ok then return true end
  if not process.is_windows() then return nil, err end

  -- Never use a fixed backup name: a stale or user-owned sibling must not be
  -- removed while recovering an interrupted report replacement.
  local backup = nil
  for attempt = 1, 32 do
    local token = path.basename(os.tmpname()):gsub("[^%w%._%-]", "_")
    local candidate = destination .. ".ballad-backup-" .. token .. "-" .. attempt
    if not fs.is_file(candidate) and not fs.is_dir(candidate) then
      backup = candidate
      break
    end
  end
  if not backup then return nil, "cannot allocate a collision-free report backup" end

  local had_destination = fs.is_file(destination)
  if had_destination then
    local backed_up, backup_err = os.rename(destination, backup)
    if not backed_up then return nil, backup_err end
  end
  local replaced, replace_err = os.rename(source, destination)
  if replaced then
    if had_destination then
      local removed, remove_err = os.remove(backup)
      if not removed then
        return nil, "report replaced but cannot remove preserved backup " .. backup .. ": " .. tostring(remove_err)
      end
    end
    return true
  end
  if had_destination then
    local restored, restore_err = os.rename(backup, destination)
    if not restored then
      return nil, "report replacement failed: " .. tostring(replace_err)
        .. "; rollback failed (previous report remains at " .. backup .. "): " .. tostring(restore_err)
    end
  end
  return nil, replace_err
end

function fs.list_files(root)
  local files = {}
  if not fs.is_dir(root) then return files end
  local command
  if process.is_windows() then
    -- cmd's dir is present on supported Windows installations and, unlike a
    -- symlink walk, does not require developer mode or elevated privileges.
    command = "dir /b /s /a:-d " .. process.quote(root) .. " 2>NUL"
  else
    command = "find " .. process.quote(root) .. " \\( -type f -o -type l \\) -print"
  end
  local pipe = io.popen(command, "r")
  if not pipe then return files end
  for file_path in pipe:lines() do files[#files + 1] = path.normalize(file_path) end
  pipe:close()
  table.sort(files)
  return files
end

function fs.readlink(file_path)
  if process.is_windows() then
    -- A copied Moonstone environment is a valid environment on Windows.  Do
    -- not require symlink creation/query privileges: copy the visible file.
    return file_path
  end
  local target = process.capture("readlink " .. process.quote(file_path) .. " 2>/dev/null")
  return target ~= "" and target or file_path
end

function fs.is_dir(dir_path)
  local command = process.is_windows()
    and ("if exist " .. process.quote(path.join(dir_path, "NUL")) .. " exit /b 0 else exit /b 1")
    or ("test -d " .. process.quote(dir_path))
  return process.command_ok(command)
end

function fs.copy_tree(source, destination)
  if not fs.is_dir(source) then process.fail("cannot copy missing directory " .. source) end
  fs.remove_tree(destination)
  if not process.is_windows() then
    -- Preserve directory entries, relative symlinks, and executable modes.
    -- The fallback file-by-file implementation cannot represent that closure.
    fs.mkdir(path.dirname(destination))
    if not process.command_ok("cp -RP " .. process.quote(source) .. " " .. process.quote(destination)) then
      process.fail("cannot copy directory " .. source .. " to " .. destination)
    end
    return
  end
  fs.mkdir(destination)
  for _, source_file in ipairs(fs.list_files(source)) do
    fs.copy_file(source_file, path.join(destination, path.relative(source_file, source)))
  end
end

function fs.is_lua(file_path)
  return file_path:lower():sub(-4) == ".lua"
end

function fs.is_binary_module(file_path)
  local ext = file_path:match("%.([^%.]+)$")
  return ext == "so" or ext == "dylib" or ext == "dll"
end

function fs.chmod(file_path, mode)
  if process.is_windows() then return end -- executable bit is not a Windows capability
  if not process.command_ok("chmod " .. process.quote(mode) .. " " .. process.quote(file_path)) then
    process.fail("cannot chmod " .. file_path .. " to " .. mode)
  end
end

return fs

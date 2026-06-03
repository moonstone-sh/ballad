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
  if not file then
    process.fail("cannot write " .. file_path .. ": " .. tostring(err))
  end

  file:write(content)
  file:close()
end

function fs.mkdir(dir_path)
  if not process.command_ok("mkdir -p " .. process.quote(dir_path)) then
    process.fail("cannot create directory " .. dir_path)
  end
end

function fs.remove_tree(tree_path)
  if tree_path == "" or tree_path == "/" then
    process.fail("refusing to remove unsafe output path")
  end

  if not process.command_ok("rm -rf " .. process.quote(tree_path)) then
    process.fail("cannot reset output directory " .. tree_path)
  end
end

function fs.copy_file(source, destination)
  fs.mkdir(path.dirname(destination))

  if not process.command_ok("cp " .. process.quote(source) .. " " .. process.quote(destination)) then
    process.fail("cannot copy " .. source .. " to " .. destination)
  end
end

function fs.list_files(root)
  local files = {}
  local command = "find " .. process.quote(root) .. " \\( -type f -o -type l \\) -print"
  local pipe = assert(io.popen(command, "r"))

  for file_path in pipe:lines() do
    files[#files + 1] = file_path
  end

  pipe:close()
  table.sort(files)

  return files
end

function fs.readlink(file_path)
  local target = process.capture("readlink " .. process.quote(file_path) .. " 2>/dev/null")
  return target ~= "" and target or file_path
end

function fs.is_dir(dir_path)
  return process.command_ok("test -d " .. process.quote(dir_path))
end

function fs.is_lua(file_path)
  return file_path:sub(-4) == ".lua"
end

function fs.is_binary_module(file_path)
  local ext = file_path:match("%.([^%.]+)$")
  return ext == "so" or ext == "dylib" or ext == "dll"
end

return fs

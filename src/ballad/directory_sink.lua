-- Incremental materialization of a dedicated, Ballad-owned output directory.
local fs = require("ballad.fs")
local path = require("ballad.path")
local process = require("ballad.process")
local M = {}

function M.prepare(out, assets, file_graph)
  out = path.normalize(out)
  if out == "." or path.is_root(out) then error("refusing unsafe incremental output directory") end
  if fs.readlink(out) ~= out then error("incremental output directory cannot be a symlink") end
  local expected = {}
  for _, asset in ipairs(assets) do
    local rel = asset.virtual_path or asset.output_path or asset.source_path or asset.id
    rel = path.normalize(rel)
    if path.is_absolute(rel) or rel:match("^%.%./") or rel == ".." then
      error("incremental sink asset must stay within its output directory: " .. rel)
    end
    if rel == "." then error("incremental sink asset needs a filename") end
    local dest = path.join(out, rel)
    if expected[dest] then error("duplicate incremental sink destination: " .. rel) end
    expected[dest] = true
    -- Never write through a pre-existing symlink in an owned tree.
    local cursor = dest
    while cursor ~= out do
      if fs.readlink(cursor) ~= cursor then error("incremental sink cannot write through symlink: " .. cursor) end
      cursor = path.dirname(cursor)
    end
  end
  if file_graph then
    local dest = path.join(out, "file-graph.json")
    if expected[dest] then error("file-graph.json is reserved when file_graph is enabled") end
    expected[dest] = true
  end
  for dest in pairs(expected) do
    local cursor = path.dirname(dest)
    while cursor ~= out do
      if expected[cursor] then error("incremental sink has conflicting file/directory destinations") end
      cursor = path.dirname(cursor)
    end
  end
  fs.mkdir(out)
  for _, file in ipairs(fs.list_files(out)) do
    if not expected[file] then
      assert(os.remove(file))
    end
  end
  -- Remove empty stale directories, including file→directory transitions.
  local command = process.is_windows()
    and ("dir /b /s /ad " .. process.quote(out) .. " 2>NUL")
    or ("find " .. process.quote(out) .. " -depth -type d -print")
  local dirs = {}
  local pipe = io.popen(command, "r")
  if pipe then
    for dir in pipe:lines() do dirs[#dirs + 1] = path.normalize(dir) end
    pipe:close()
  end
  table.sort(dirs, function(a, b) return #a > #b end)
  for _, dir in ipairs(dirs) do
    if dir ~= out then
      if process.is_windows() then
        process.command_ok("rmdir " .. process.quote(dir) .. " 2>NUL")
      else
        os.remove(dir) -- succeeds only for an empty directory
      end
    end
  end
end

return M

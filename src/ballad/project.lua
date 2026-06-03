local fs = require("ballad.fs")
local path = require("ballad.path")
local process = require("ballad.process")
local toml = require("ballad.toml")
local lockfile = require("ballad.lockfile")

local project = {}

function project.find_root(start_path)
  local root = path.absolute(start_path or ".")

  while root ~= "/" do
    if fs.read_file(path.join(root, "moonstone.toml")) then
      return root
    end

    root = path.dirname(root)
  end

  process.fail("moonstone.toml not found from " .. tostring(start_path or "."))
end

function project.load(start_path)
  local root = project.find_root(start_path)

  local manifest_content = assert(fs.read_file(path.join(root, "moonstone.toml")))
  local manifest = toml.parse(manifest_content)

  local lock_content = fs.read_file(path.join(root, "moonstone.lock")) or ""
  local packages = lockfile.parse(lock_content)

  local env_content = fs.read_file(path.join(root, ".moonstone/env/env.toml"))
  if not env_content then
    process.fail("missing .moonstone/env/env.toml; run moon sync in " .. root)
  end

  local env = toml.parse(env_content)

  if not env.runtime or not env.runtime.abi then
    process.fail("runtime ABI missing from .moonstone/env/env.toml")
  end

  return {
    root = root,
    manifest = manifest,
    packages = packages,
    env = env,
  }
end

return project

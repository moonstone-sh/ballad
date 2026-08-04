local fs = require("ballad.fs")
local path = require("ballad.path")
local process = require("ballad.process")
local toml = require("ballad.toml")
local moonstone_contract = require("ballad.moonstone_contract")

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

function project.load_manifest(start_path, opts)
  opts = opts or {}
  local root = project.find_root(start_path)
  local moon_bin = opts.moon or opts.moon_bin
    or (os.getenv("MOONSTONE_CLI") ~= "" and os.getenv("MOONSTONE_CLI"))
    or (os.getenv("MOONSTONE_BIN") ~= "" and os.getenv("MOONSTONE_BIN"))
    or "moon"
  local manifest_document = moonstone_contract.manifest_export(root, moon_bin)
  local manifest = moonstone_contract.project_manifest(manifest_document)

  return {
    root = root,
    manifest = manifest,
    manifest_document = manifest_document,
    moon_bin = moon_bin,
  }
end

function project.load(start_path, opts)
  local loaded = project.load_manifest(start_path, opts)
  local root = loaded.root
  local lock_document = moonstone_contract.lock_export(root, loaded.moon_bin)

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
    manifest = loaded.manifest,
    manifest_document = loaded.manifest_document,
    packages = lock_document and lock_document.packages or {},
    lock_document = lock_document,
    env = env,
  }
end

return project

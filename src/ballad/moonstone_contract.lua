---@meta

local dkjson = require("dkjson")
local fs = require("ballad.fs")
local path = require("ballad.path")
local process = require("ballad.process")

local contract = {}

local function capture_json(root, moon_bin, command, required)
  local shell = process.quote(moon_bin or "moon") .. " -C " .. process.quote(root) .. " " .. command .. " 2>/dev/null"
  local output = process.capture(shell)
  if output == "" then
    if required then
      error("moonstone contract query failed: moon " .. command)
    end
    return nil
  end

  local decoded, _, err = dkjson.decode(output)
  if type(decoded) ~= "table" then
    error("moonstone contract query returned invalid JSON for 'moon " .. command .. "': " .. tostring(err))
  end
  return decoded
end

---@param root string
---@param moon_bin string|nil
---@return table
function contract.manifest_export(root, moon_bin)
  local document = capture_json(root, moon_bin, "manifest export --json", true)
  if document.contract ~= "moonstone:manifest:v1" or type(document.manifest) ~= "table" then
    error("moonstone contract query returned an unsupported manifest document")
  end
  return document
end

---@param root string
---@param moon_bin string|nil
---@param operations table[]
---@return boolean
function contract.apply_manifest(root, moon_bin, operations)
  if #operations == 0 then return false end
  local document = contract.manifest_export(root, moon_bin)
  local request_path = os.tmpname()
  local request = assert(io.open(request_path, "wb"))
  request:write(dkjson.encode({
    contract = "moonstone:manifest-edit:v1",
    expected_revision = document.storage_revision,
    operations = operations,
  }))
  request:close()

  local command = process.quote(moon_bin or "moon") .. " -C " .. process.quote(root)
    .. " manifest apply --json --force < " .. process.quote(request_path)
  local ok = process.command_ok(command)
  os.remove(request_path)
  if not ok then error("Moonstone rejected Ballad's manifest adoption transaction") end
  return true
end

---@param root string
---@param moon_bin string|nil
---@param name string
---@param command string
---@return boolean
function contract.add_script_if_missing(root, moon_bin, name, command)
  local document = contract.manifest_export(root, moon_bin)
  for _, script in ipairs((document.manifest or {}).scripts or {}) do
    if script.name == name then return false end
  end
  return contract.apply_manifest(root, moon_bin, {
    { kind = "set_script", name = name, command = command },
  })
end

---@param root string
---@param moon_bin string|nil
---@return table|nil
function contract.lock_export(root, moon_bin)
  local lock_path = path.join(root, "moonstone.lock")
  if not fs.read_file(lock_path) then return nil end

  local document = capture_json(root, moon_bin, "lock export --json", true)
  if document.contract ~= "moonstone:lock:v1" then
    error("moonstone contract query returned an unsupported lock document")
  end

  if type(document.packages) ~= "table" then
    if type(document.realizations) ~= "table" then
      error("moonstone contract query returned an unsupported lock document")
    end
    document.packages = document.realizations
  end

  return document
end

---@param document table
---@return table
function contract.project_manifest(document)
  local manifest = document.manifest
  local project = manifest.project or {}
  return {
    manifest_version = manifest.manifest_version,
    package = {
      name = project.name,
      version = project.version,
      kind = project.kind,
      description = project.description,
      readme = project.readme,
    },
    runtime = manifest.runtime or {},
    origin = manifest.origin,
    tidy = manifest.tidy or {},
    dependencies = manifest.dependencies or {},
    scripts = manifest.scripts or {},
    registries = manifest.registries or {},
    orbits = manifest.orbits or {},
  }
end

return contract

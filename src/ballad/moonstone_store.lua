local json = require("dkjson")
local process = require("ballad.process")
local store = {}

function store.decode_artifact(output, artifact_hash)
  local found, complete = nil, false
  for line in output:gmatch("[^\r\n]+") do
    local event = json.decode(line)
    if type(event) ~= "table" or event.contract ~= "moonstone:cli-events:v1" then
      return nil, "invalid Moonstone store event"
    end
    if event.kind == "ERROR" then return nil, "Moonstone store lookup failed: " .. tostring(event.value) end
    if event.kind == "STATUS" and event.value == "artifact" then
      if type(event.data) ~= "table" or event.data.artifact_hash ~= artifact_hash then
        return nil, "Moonstone store lookup returned another artifact"
      end
      if found then return nil, "Moonstone store lookup returned duplicate artifacts" end
      found = event.data
    end
    if event.terminator then
      if event.kind ~= "RESULT" or event.value ~= "ok" then return nil, "Moonstone store lookup failed" end
      complete = true
    end
  end
  if not complete then return nil, "incomplete Moonstone store lookup" end
  if not found then return nil, "artifact not found in local store" end
  return found
end

function store.artifact(moon_bin, artifact_hash)
  if not artifact_hash or artifact_hash == "" then return nil, "missing artifact_hash" end
  local result = process.capture_run({
    tool = moon_bin or "moon",
    args = { "store", "list", "--by-artifact-hash", artifact_hash, "--json" },
  })
  if result.exit_code ~= 0 then return nil, "Moonstone store lookup failed: " .. result.stderr end
  return store.decode_artifact(result.stdout, artifact_hash)
end
return store

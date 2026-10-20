package.path = "src/?.lua;src/?/init.lua;" .. package.path
local store = require("ballad.moonstone_store")
local json = require("dkjson")
local hash = "b3:fixture"
local function event(kind, value, data, terminator)
  return json.encode({contract="moonstone:cli-events:v1",kind=kind,value=value,data=data or {},terminator=terminator or false}) .. "\n"
end
local item = event("STATUS","artifact",{artifact_hash=hash,artifact_path="/store/fixture"})
local done = event("RESULT","ok",{count=1},true)
assert(store.decode_artifact(event("START","begin")..item..done,hash).artifact_path=="/store/fixture")
assert(not store.decode_artifact(item,hash))
assert(not store.decode_artifact(item..event("ERROR","failed",{},true),hash))
assert(not store.decode_artifact(item..item..done,hash))
assert(not store.decode_artifact(item..done,"b3:other"))
assert(not store.decode_artifact(done,hash))
print("PASS: Moonstone store events require a complete, successful, exact artifact lookup")

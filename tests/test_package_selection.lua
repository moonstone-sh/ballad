package.path = "src/?.lua;src/?/init.lua;" .. package.path
local select = require("ballad.package_selection").new
local matches = select({packages={
  {name="keep", artifact_path="C:/store/keep", store_query={provisions={
    lua_modules={{name="keep",path="${build}/src/keep.lua"},{name="keep/deep.lua",path="${build}/src/keep/deep.lua"}},
    lua_cmodules={{name="native.core",path="${build}/native/core.so"}}
  }}},
  {name="omit",artifact_path="C:/store/omit",store_query={provisions={lua_modules={{name="omit",path="${build}/omit.lua"}}}}}
}}, {"keep"})
assert(matches("C:/env/keep.lua","keep.lua","lua_modules"))
assert(matches("C:/env/keep@windows.lua","keep@windows.lua","lua_modules"))
assert(matches("C:/env/keep/deep.lua","keep/deep.lua","lua_modules"))
assert(matches("C:/env/native/core.dll","native/core.dll","lua_cmodules"))
assert(not matches("C:/env/omit.lua","omit.lua","lua_modules"))
assert(not matches("C:/env/keep_bad.lua","keep_bad.lua","lua_modules"))
assert(matches("C:/store/keep/files/other.lua","other.lua","lua_modules"))
assert(select({},nil)("any","any","lua_modules"))
print("PASS: selected package ownership survives copied environments and variants")

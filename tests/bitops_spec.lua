package.path="src/?.lua;src/?/init.lua;" .. package.path
local ok, variants=pcall(function() return require("moonstone.variants") end)
if ok then variants.install() end
local selected=require("ballad.bitops")
local fallback=assert(loadfile("src/ballad/bitops.lua"))()
local seed=17
for _=1,1000 do
  seed=(seed*1664525+1013904223)%4294967296
  local left=seed
  seed=(seed*1664525+1013904223)%4294967296
  local right=seed
  for _,operation in ipairs({"band","bor","bxor"}) do
    assert(selected[operation](left,right)%4294967296==fallback[operation](left,right),operation)
  end
  for _,operation in ipairs({"lshift","rshift"}) do
    assert(selected[operation](left,right%32)%4294967296==fallback[operation](left,right%32),operation)
  end
end
print("PASS: native and fallback checksum operators agree")

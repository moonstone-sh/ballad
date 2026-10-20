package.path = "src/?.lua;src/?/init.lua;" .. package.path
local plugin = require("ballad.plugins.moonstone")
local ctx = {native_task=function(_, task) return task end}
local run = plugin.run(ctx,{}, {script="build with spaces",moon="moon"})
assert(not run.cmd and run.tool and #run.args==2 and run.args[1]=="run" and run.args[2]=="build with spaces")
local exec = plugin.exec(ctx,{}, {args={"lua","script with spaces.lua","a&b"},moon="moon"})
assert(not exec.cmd and exec.args[1]=="exec" and exec.args[2]=="--" and exec.args[4]=="script with spaces.lua" and exec.args[5]=="a&b")
print("PASS: Moonstone run and argv exec preserve structured native tasks")

local partiture = require("ballad.partiture")
local diagnostic = require("ballad.diagnostic")
local fs = require("ballad.fs")

local testing = {}

local Subject = {}
Subject.__index = Subject

local PlanResult = {}
PlanResult.__index = PlanResult

local RunResult = {}
RunResult.__index = RunResult

local function fail(message)
  error("ballad.testing: " .. message, 0)
end

local function same(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  for key, value in pairs(left) do
    if not same(value, right[key]) then return false end
  end
  for key in pairs(right) do
    if left[key] == nil then return false end
  end
  return true
end

local function node_matches(node, query)
  for key, expected in pairs(query or {}) do
    local actual
    if key == "product" then actual = node.options and node.options.product
    else actual = node[key] end
    if not same(actual, expected) then return false end
  end
  return true
end

local function matching_nodes(graph, query)
  local result = {}
  for _, node in pairs(graph.nodes or {}) do
    if node_matches(node, query) then result[#result + 1] = node end
  end
  table.sort(result, function(left, right) return left.id < right.id end)
  return result
end

local function assert_control(graph, name, expected)
  local matches = {}
  for _, entry in ipairs(graph.metadata.controls or {}) do
    if entry.name == name then matches[#matches + 1] = entry end
  end
  if #matches == 0 then fail("named control not found: " .. tostring(name)) end
  if #matches > 1 then fail("named control is ambiguous: " .. tostring(name)) end
  local entry = matches[1]
  local actual = entry.kind == "value" and entry.value
    or (entry.kind == "requirement" and entry.passed or entry.result)
  if not same(actual, expected) then
    fail("control `" .. name .. "` expected " .. tostring(expected) .. " but was " .. tostring(actual))
  end
end

local function assert_node(graph, query)
  local matches = matching_nodes(graph, query)
  if #matches == 0 then fail("no graph node matched the requested fields") end
  return matches[1]
end

local function assert_provision(graph, category, name)
  for _, node in pairs(graph.nodes or {}) do
    local collect = node.options and node.options.materialize and node.options.materialize.collect
    for _, provision in ipairs((collect and collect[category]) or {}) do
      if provision.name == name then return provision end
    end
  end
  fail("provision not found in " .. tostring(category) .. ": " .. tostring(name))
end

function Subject:plan()
  local ok, result = pcall(function() return self.pipeline:plan() end)
  if not ok then fail("planning failed: " .. diagnostic.render(result)) end
  return setmetatable({ subject = self, graph = self.pipeline:graph(), value = result }, PlanResult)
end

function Subject:execute()
  local ok, result = pcall(function() return self.pipeline:execute() end)
  return setmetatable({
    subject = self,
    graph = self.pipeline:graph(),
    ok = ok,
    results = ok and result or nil,
    error = ok and nil or result,
  }, RunResult)
end

function PlanResult:assert_control(name, expected)
  assert_control(self.graph, name, expected)
  return self
end

function PlanResult:assert_node(query)
  assert_node(self.graph, query)
  return self
end

function PlanResult:assert_product(name, expected_enabled)
  local query = { role = "sink", product = name }
  if expected_enabled ~= nil then query.enabled = expected_enabled end
  assert_node(self.graph, query)
  return self
end

function PlanResult:assert_provision(category, name)
  assert_provision(self.graph, category, name)
  return self
end

function RunResult:assert_success()
  if not self.ok then fail("execution failed: " .. diagnostic.render(self.error)) end
  return self
end

function RunResult:assert_failure()
  if self.ok then fail("execution succeeded unexpectedly") end
  return self
end

function RunResult:assert_diagnostic(code)
  if self.ok then fail("expected diagnostic `" .. tostring(code) .. "`, but execution succeeded") end
  local actual = diagnostic.is(self.error) and self.error.code or nil
  if actual ~= code and not tostring(self.error):find("[" .. tostring(code) .. "]", 1, true) then
    fail("expected diagnostic `" .. tostring(code) .. "`, got: " .. diagnostic.render(self.error))
  end
  return self
end

function RunResult:assert_control(name, expected)
  assert_control(self.graph, name, expected)
  return self
end

function RunResult:assert_product(name)
  if not self.ok then fail("cannot assert product after failed execution: " .. diagnostic.render(self.error)) end
  local node = assert_node(self.graph, { role = "sink", product = name, enabled = true, executed = true })
  if not node.result then fail("product `" .. name .. "` has no execution result") end
  return self
end

function RunResult:assert_provision(category, name)
  assert_provision(self.graph, category, name)
  return self
end

function RunResult:assert_path(file_path)
  if not fs.is_file(file_path) and not fs.is_dir(file_path) then fail("expected path does not exist: " .. file_path) end
  return self
end

function testing.load(filepath, opts)
  opts = opts or {}
  if type(opts) ~= "table" then fail("load options must be a table") end
  if opts.args ~= nil and type(opts.args) ~= "table" then fail("load args must be an array") end
  local pipeline = partiture.load(filepath, opts.jobs, opts.args)
  return setmetatable({ pipeline = pipeline, filepath = filepath, opts = opts }, Subject)
end

testing.Subject = Subject
testing.PlanResult = PlanResult
testing.RunResult = RunResult

return testing

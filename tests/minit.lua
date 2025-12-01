#!/usr/bin/env -S nvim -l

-- Lightweight test runner without luassert dependency
-- Matches snacks.nvim structure but works around luassert installation issues

vim.env.LAZY_STDPATH = ".tests"
vim.opt.runtimepath:prepend(".") -- Add current directory to runtimepath

-- Setup minimal test environment
local test_files = {}
for i, arg in ipairs(_G.arg) do
  if arg:match("_spec%.lua$") then
    table.insert(test_files, arg)
  end
end

if #test_files == 0 then
  test_files = vim.fn.globpath("tests", "**/*_spec.lua", true, true)
end

-- Provide describe/it globals with basic assertion support
local current_suite = nil
local tests = {}
local stats = { pass = 0, fail = 0, total = 0 }

_G.describe = function(name, func)
  current_suite = name
  func()
  current_suite = nil
end

_G.it = function(name, func)
  local full_name = (current_suite and (current_suite .. " - ") or "") .. name
  stats.total = stats.total + 1

  local success, err = pcall(func)
  if success then
    stats.pass = stats.pass + 1
    print(string.format("✓ %s", full_name))
  else
    stats.fail = stats.fail + 1
    print(string.format("✗ %s", full_name))
    print(string.format("  Error: %s", tostring(err)))
  end
end

-- Provide luassert-compatible assertion API
local function create_assert()
  local base_assert = assert

  local assert_table = setmetatable({}, {
    __call = function(_, condition, message)
      return base_assert(condition, message)
    end
  })

  -- luassert.are.equal(expected, actual)
  assert_table.are = {
    equal = function(expected, actual, message)
      return base_assert(actual == expected,
        message or string.format("Expected %s, got %s", tostring(expected), tostring(actual)))
    end,
    same = function(expected, actual, message)
      return base_assert(vim.deep_equal(expected, actual), message or "Tables are not equal")
    end,
  }

  -- luassert.is_not.same(expected, actual)
  assert_table.is_not = {
    same = function(expected, actual, message)
      return base_assert(not vim.deep_equal(expected, actual), message or "Tables should not be equal")
    end,
  }

  -- luassert.is_not_nil(value)
  assert_table.is_not_nil = function(value, message)
    return base_assert(value ~= nil, message or "Expected value to not be nil")
  end

  -- luassert.is_nil(value)
  assert_table.is_nil = function(value, message)
    return base_assert(value == nil, message or "Expected value to be nil")
  end

  -- luassert.is_true(value)
  assert_table.is_true = function(value, message)
    return base_assert(value == true, message or "Expected true")
  end

  -- luassert.is_false(value)
  assert_table.is_false = function(value, message)
    return base_assert(value == false, message or "Expected false")
  end

  -- luassert.is.truthy(value)
  assert_table.is = {
    truthy = function(value, message)
      return base_assert(value, message or "Expected truthy value")
    end,
    falsy = function(value, message)
      return base_assert(not value, message or "Expected falsy value")
    end,
  }

  -- luassert.is_string(value)
  assert_table.is_string = function(value, message)
    return base_assert(type(value) == "string", message or string.format("Expected string, got %s", type(value)))
  end

  -- luassert.is_table(value)
  assert_table.is_table = function(value, message)
    return base_assert(type(value) == "table", message or string.format("Expected table, got %s", type(value)))
  end

  -- luassert.is_number(value)
  assert_table.is_number = function(value, message)
    return base_assert(type(value) == "number", message or string.format("Expected number, got %s", type(value)))
  end

  return assert_table
end

_G.assert = create_assert()

-- Run all test files
for _, file in ipairs(test_files) do
  print(string.format("\nRunning %s:", file))
  local success, err = pcall(dofile, file)
  if not success then
    print(string.format("Failed to load test file: %s", err))
  end
end

-- Print summary
print(string.format("\n\nTest Summary:"))
print(string.format("  Total: %d", stats.total))
print(string.format("  Passed: %d", stats.pass))
print(string.format("  Failed: %d", stats.fail))

-- Exit with appropriate code
if stats.fail > 0 then
  os.exit(1)
end

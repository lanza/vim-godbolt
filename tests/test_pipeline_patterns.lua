#!/usr/bin/env lua

-- Test pattern matching for pipeline viewer

local test_lines = {
  -- Module passes
  { line = "  1. [M] Annotation2MetadataPass on [module]", type = "module", selected = false },
  { line = "> 3. [M] InferFunctionAttrsPass on [module]", type = "module", selected = true },

  -- Group headers (folded)
  { line = "  5. ▸ [F] EntryExitInstrumenterPass (163 functions)", type = "group_folded", selected = false },
  { line = "> 7. ▸ [C] InlinerPass (163 functions)", type = "group_folded", selected = true },

  -- Group headers (unfolded)
  { line = "  9. ▾ [F] SimplifyCFGPass (1004 functions)", type = "group_unfolded", selected = false },
  { line = "> 11. ▾ [C] PostOrderFunctionAttrsPass (326 functions)", type = "group_unfolded", selected = true },

  -- Function entries
  { line = "         function1", type = "function", selected = false },
  { line = "     ●   function2", type = "function", selected = true },
  { line = "     ●   (foo, bar, baz)", type = "function", selected = true },
}

-- Patterns from pipeline_viewer.lua
-- Note: UTF-8 characters (▸▾●) can't use character classes, need explicit checking
local function is_group_line(line)
  -- Check basic structure first: "[> ] NN. "
  if not line:match("^[> ] %d+%. ") then
    return false
  end
  -- Check if it has a fold icon (▸ or ▾) after the number
  return line:match("^[> ] %d+%. ▸") or line:match("^[> ] %d+%. ▾")
end

local function is_function_line(line)
  -- Pattern: 5 spaces, then (● or space), then 3 spaces
  -- Can't use [● ] character class with UTF-8
  return line:match("^     ●   ") or line:match("^         ")
end

print("Testing pipeline viewer patterns:")
print(string.rep("=", 60))

local passed = 0
local failed = 0

for i, test in ipairs(test_lines) do
  local matched_type = nil

  if test.line:match("^[> ] %d+%. %[M%]") then
    matched_type = "module"
  elseif is_group_line(test.line) then
    matched_type = test.line:match("▸") and "group_folded" or "group_unfolded"
  elseif is_function_line(test.line) then
    matched_type = "function"
  end

  local success = (matched_type == test.type)
  if success then
    passed = passed + 1
    print(string.format("✓ Test %d: %s", i, test.type))
  else
    failed = failed + 1
    print(string.format("✗ Test %d: Expected %s, got %s", i, test.type, matched_type or "NONE"))
    print(string.format("  Line: %q", test.line))
  end

  -- Test selection marker
  local has_marker = test.line:match("^>") or test.line:match("^     ●")
  local expected_marker = test.selected
  if has_marker ~= expected_marker then
    print(string.format("  WARNING: Selection marker mismatch (expected %s, got %s)",
      tostring(expected_marker), tostring(has_marker)))
  end
end

print(string.rep("=", 60))
print(string.format("Results: %d passed, %d failed", passed, failed))

if failed > 0 then
  os.exit(1)
end

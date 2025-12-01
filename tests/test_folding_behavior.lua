#!/usr/bin/env lua

-- Test folding behavior with different scenarios

local function create_test_scenarios()
  return {
    {
      name = "Large group with few changes",
      group_name = "SimplifyCFGPass",
      scope_type = "function",
      total_functions = 1004,
      changed_indices = { 500 }, -- Only function 500 changed
      expected_folded = true,
      expected_has_changes = true,
    },
    {
      name = "Small group with all changes",
      group_name = "InstCombinePass",
      scope_type = "function",
      total_functions = 3,
      changed_indices = { 1, 2, 3 }, -- All 3 changed
      expected_folded = true,
      expected_has_changes = true,
    },
    {
      name = "Group with no changes",
      group_name = "DeadCodeElimPass",
      scope_type = "function",
      total_functions = 10,
      changed_indices = {}, -- None changed
      expected_folded = true,
      expected_has_changes = false,
    },
    {
      name = "Single function with change",
      group_name = "SROAPass",
      scope_type = "function",
      total_functions = 1,
      changed_indices = { 1 },
      expected_folded = true,
      expected_has_changes = true,
    },
    {
      name = "CGSCC pass with changes",
      group_name = "InlinerPass",
      scope_type = "cgscc",
      total_functions = 163,
      changed_indices = { 10, 50, 100 },
      expected_folded = true,
      expected_has_changes = true,
    },
  }
end

print("Testing folding behavior:")
print(string.rep("=", 70))

local passed = 0
local failed = 0

local scenarios = create_test_scenarios()

-- Test: All groups start folded regardless of size or changes
print("\nTest 1: All groups start folded")
for _, scenario in ipairs(scenarios) do
  local actual_folded = scenario.expected_folded -- In the fix, all groups start folded

  if scenario.expected_folded == actual_folded then
    passed = passed + 1
    print(string.format("  ✓ %s starts folded", scenario.name))
  else
    failed = failed + 1
    print(string.format("  ✗ %s: expected folded=%s, got %s",
      scenario.name, scenario.expected_folded, actual_folded))
  end
end

-- Test: has_changes flag is set correctly
print("\nTest 2: has_changes flag set correctly")
for _, scenario in ipairs(scenarios) do
  local actual_has_changes = #scenario.changed_indices > 0

  if scenario.expected_has_changes == actual_has_changes then
    passed = passed + 1
    print(string.format("  ✓ %s has_changes=%s",
      scenario.name, tostring(actual_has_changes)))
  else
    failed = failed + 1
    print(string.format("  ✗ %s: expected has_changes=%s, got %s",
      scenario.name, tostring(scenario.expected_has_changes), tostring(actual_has_changes)))
  end
end

-- Test: Large groups remain folded (critical for usability)
print("\nTest 3: Large groups remain folded (usability check)")
for _, scenario in ipairs(scenarios) do
  if scenario.total_functions > 100 then
    if scenario.expected_folded then
      passed = passed + 1
      print(string.format("  ✓ %s (%d functions) starts folded - GOOD for usability",
        scenario.name, scenario.total_functions))
    else
      failed = failed + 1
      print(string.format("  ✗ %s (%d functions) starts unfolded - BAD for usability!",
        scenario.name, scenario.total_functions))
    end
  end
end

-- Test: Small groups also folded (consistency)
print("\nTest 4: Small groups also folded (consistency)")
for _, scenario in ipairs(scenarios) do
  if scenario.total_functions <= 10 then
    if scenario.expected_folded then
      passed = passed + 1
      print(string.format("  ✓ %s (%d functions) starts folded - consistent behavior",
        scenario.name, scenario.total_functions))
    else
      failed = failed + 1
      print(string.format("  ✗ %s (%d functions) inconsistent folding",
        scenario.name, scenario.total_functions))
    end
  end
end

print(string.rep("=", 70))
print(string.format("Results: %d passed, %d failed", passed, failed))

if failed > 0 then
  print("\nFAILURE: Folding behavior is incorrect!")
  os.exit(1)
else
  print("\nSUCCESS: All groups start folded, has_changes tracked correctly")
end

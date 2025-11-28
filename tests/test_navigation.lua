#!/usr/bin/env lua

-- Test navigation behavior with folded/unfolded groups
-- These are specification tests - document expected behavior

print("Pipeline Viewer Navigation Specification Tests")
print(string.rep("=", 70))

-- Test scenarios that document how navigation SHOULD work
local navigation_specs = {
  {
    name = "j/k with all groups folded",
    description = "Should navigate only through visible lines (headers/modules)",
    layout = {
      {line = 1, type = "module", text = " 1. [M] ModulePass1"},
      {line = 2, type = "group_folded", text = " 2. ▸ [F] Pass1 (1004 functions)"},
      {line = 3, type = "group_folded", text = " 3. ▸ [F] Pass2 (50 functions)"},
      {line = 4, type = "module", text = " 4. [M] ModulePass2"},
    },
    action = "Press j from line 1, three times",
    expected = "Cursor moves: 1 → 2 → 3 → 4",
  },
  {
    name = "j/k with one group unfolded",
    description = "Should walk through all visible lines including function entries",
    layout = {
      {line = 1, type = "module", text = " 1. [M] ModulePass1"},
      {line = 2, type = "group_unfolded", text = " 2. ▾ [F] InstCombinePass (3 functions)"},
      {line = 3, type = "function", text = "         foo"},
      {line = 4, type = "function", text = "         bar"},
      {line = 5, type = "function", text = "         baz"},
      {line = 6, type = "module", text = " 3. [M] ModulePass2"},
    },
    action = "Press j from line 2, four times",
    expected = "Cursor moves: 2 → 3 → 4 → 5 → 6",
  },
  {
    name = "Tab with folded group containing changes",
    description = "Should UNFOLD the group and navigate to first changed function entry",
    layout_before = {
      {line = 1, type = "module", text = " 1. [M] ModulePass1", changed = true},
      {line = 2, type = "group_folded", text = " 2. ▸ [F] Pass1 (1004 functions)", has_changes = true},
      -- (functions are not visible - group is folded)
      {line = 3, type = "module", text = " 3. [M] ModulePass2", changed = false},
    },
    layout_after = {
      {line = 1, type = "module", text = " 1. [M] ModulePass1", changed = true},
      {line = 2, type = "group_unfolded", text = " 2. ▾ [F] Pass1 (1004 functions)", has_changes = true},
      {line = 3, type = "function", text = "         func1"},
      -- ... more functions ...
      {line = 502, type = "function", text = "     ●   func500"},  -- First changed function
      -- ... more functions ...
    },
    action = "Press Tab from line 1",
    expected = "Group AUTO-UNFOLDS (▸ → ▾), cursor lands on func500 (first changed function entry)",
    critical = "Group unfolds automatically - NO manual Enter required",
  },
  {
    name = "Tab with unfolded group",
    description = "Should jump only to changed function entries, skip unchanged",
    layout = {
      {line = 1, type = "group_unfolded", text = " 2. ▾ [F] Pass1 (5 functions)"},
      {line = 2, type = "function", text = "         func1", changed = false},
      {line = 3, type = "function", text = "         func2", changed = true},
      {line = 4, type = "function", text = "         func3", changed = false},
      {line = 5, type = "function", text = "         func4", changed = true},
      {line = 6, type = "function", text = "         func5", changed = false},
    },
    action = "Press Tab from line 1, three times",
    expected = "Cursor moves: 1 → 3 → 5 (skips 2, 4, 6)",
  },
  {
    name = "Tab skips groups with no changes",
    description = "Unchanged groups should be completely skipped",
    layout = {
      {line = 1, type = "module", text = " 1. [M] ModulePass1", changed = true},
      {line = 2, type = "group_folded", text = " 2. ▸ [F] UnchangedPass (100 functions)", has_changes = false},
      {line = 3, type = "module", text = " 3. [M] ModulePass2", changed = true},
    },
    action = "Press Tab from line 1",
    expected = "Cursor jumps directly to line 3 (skips line 2)",
  },
  {
    name = "Enter on folded group",
    description = "Should unfold the group to show individual functions",
    layout_before = {
      {line = 1, type = "group_folded", text = " 5. ▸ [F] SimplifyCFGPass (1004 functions)"},
      {line = 2, type = "module", text = " 6. [M] NextPass"},
    },
    layout_after = {
      {line = 1, type = "group_unfolded", text = " 5. ▾ [F] SimplifyCFGPass (1004 functions)"},
      {line = 2, type = "function", text = "         function1"},
      -- ... 1004 functions total ...
      {line = 1005, type = "function", text = "         function1004"},
      {line = 1006, type = "module", text = " 6. [M] NextPass"},
    },
    action = "Press Enter on line 1",
    expected = "Group unfolds, showing all 1004 functions, cursor stays on line 1",
  },
  {
    name = "o on folded group",
    description = "Same as Enter - toggles fold state",
    layout_before = {
      {line = 1, type = "group_folded", text = " 5. ▸ [F] SimplifyCFGPass (1004 functions)"},
    },
    layout_after = {
      {line = 1, type = "group_unfolded", text = " 5. ▾ [F] SimplifyCFGPass (1004 functions)"},
      -- ... functions visible ...
    },
    action = "Press o on line 1",
    expected = "Group unfolds, same as Enter",
  },
}

print("\nNavigation Behavior Specifications:\n")

local test_num = 1
for _, spec in ipairs(navigation_specs) do
  print(string.format("Test %d: %s", test_num, spec.name))
  print(string.format("  Description: %s", spec.description))
  print(string.format("  Action:      %s", spec.action))
  print(string.format("  Expected:    %s", spec.expected))
  if spec.critical then
    print(string.format("  CRITICAL:    %s", spec.critical))
  end
  print()
  test_num = test_num + 1
end

print(string.rep("=", 70))
print("\nThese tests document the EXPECTED behavior after the auto-unfold fix.")
print("They serve as a specification for manual verification.")
print("\nKey principles:")
print("  1. Groups start FOLDED (all sizes)")
print("  2. j/k navigates visible lines only (doesn't auto-unfold)")
print("  3. Tab AUTO-UNFOLDS groups with changes and jumps to first changed function")
print("  4. After Tab unfolds a group, j/k can navigate through the function entries")
print("  5. Enter/o still available for manual folding control")

-- Return success - these are specification tests, not automated checks
print("\nSpecification documented successfully.")

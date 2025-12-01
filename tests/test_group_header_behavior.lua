#!/usr/bin/env lua

-- Test group header buffer clearing behavior
-- These are specification tests - document expected behavior

print("Pipeline Viewer Group Header Behavior Specification Tests")
print(string.rep("=", 80))

-- Test scenarios for group header cursor behavior
local group_header_specs = {
  {
    name = "Cursor on folded group header",
    description = "When cursor is on a FOLDED group header, before/after buffers should be CLEARED",
    setup = {
      passes = {
        { line = 1, type = "module", text = " 1. [M] ModulePass1" },
        { line = 2, type = "group_header", text = " 2. ▸ [F] InstCombinePass (983 functions)", folded = true },
        { line = 3, type = "module", text = " 3. [M] ModulePass2" },
      },
      cursor_line = 2, -- On folded group header
      current_index = 2,
    },
    action = "Navigate to line 2 (folded group header)",
    expected = {
      "before_bufnr is cleared (empty buffer)",
      "after_bufnr is cleared (empty buffer)",
      "before buffer name set to 'Group: InstCombinePass (folded)'",
      "NO auto-selection of first function",
      "NO IR displayed - buffers remain empty",
    },
    rationale = "User can see the group name but no IR until they unfold with Enter/o",
  },
  {
    name = "Cursor on unfolded group header",
    description = "When cursor is on an UNFOLDED group header, before/after buffers should be CLEARED",
    setup = {
      passes = {
        { line = 1, type = "module", text = " 1. [M] ModulePass1" },
        { line = 2, type = "group_header", text = " 2. ▾ [F] InstCombinePass (983 functions)", folded = false },
        { line = 3, type = "function_entry", text = "         foo" },
        { line = 4, type = "function_entry", text = "         bar" },
        -- ... 981 more functions ...
      },
      cursor_line = 2, -- On unfolded group header
      current_index = 2,
    },
    action = "Navigate to line 2 (unfolded group header)",
    expected = {
      "before_bufnr is cleared (empty buffer)",
      "after_bufnr is cleared (empty buffer)",
      "before buffer name set to 'Group: InstCombinePass (unfolded)'",
      "NO auto-selection of first function (foo)",
      "User must press j to line 3 to see foo's IR",
    },
    rationale = "Group header is metadata, not a pass - should not show IR for any function",
    bug_before_fix = "User reported confusion - cursor on group header was auto-selecting first function",
  },
  {
    name = "Cursor on function entry after unfolding",
    description = "After unfolding, moving cursor to function entry SHOULD show IR",
    setup = {
      passes = {
        { line = 1, type = "group_header", text = " 2. ▾ [F] InstCombinePass (983 functions)", folded = false },
        { line = 2, type = "function_entry", text = "     ●   foo", original_index = 100 },
        { line = 3, type = "function_entry", text = "         bar", original_index = 101 },
      },
      cursor_line = 2, -- On function entry 'foo'
      current_index = 100,
    },
    action = "Navigate to line 2 (function entry 'foo')",
    expected = {
      "before_bufnr shows IR from pass 99 (before InstCombinePass on foo)",
      "after_bufnr shows IR from pass 100 (after InstCombinePass on foo)",
      "Circle marker (●) appears on line 2 if foo has changes",
      "Diff is displayed in before/after buffers",
    },
  },
  {
    name = "Toggle folding with Enter on group header",
    description = "Pressing Enter on group header should toggle fold state",
    setup = {
      passes = {
        { line = 1, type = "group_header", text = " 5. ▸ [F] SimplifyCFGPass (1004 functions)", folded = true },
      },
      cursor_line = 1,
    },
    action = "Press Enter on folded group header",
    expected = {
      "Group unfolds (▸ → ▾)",
      "1004 function entries become visible below header",
      "Cursor remains on line 1 (group header)",
      "Buffers remain cleared (still on header, not a function)",
      "User can now press j to navigate to first function entry",
    },
  },
  {
    name = "Group header identification logic",
    description = "Code should correctly identify group headers vs function entries",
    test_patterns = {
      { text = " 5. ▸ [F] InstCombinePass (983 functions)", is_group_header = true, folded = true },
      { text = " 5. ▾ [F] InstCombinePass (983 functions)", is_group_header = true, folded = false },
      { text = " 5. ▸ [C] CGSCCPass (50 functions)", is_group_header = true, folded = true },
      { text = "         foo", is_group_header = false },
      { text = "     ●   bar", is_group_header = false },
      { text = "     >   baz", is_group_header = false },
      { text = " 1. [M] ModulePass", is_group_header = false }, -- Module pass, not group
    },
    expected = {
      "Patterns with ▸ or ▾ followed by [F] or [C] are group headers",
      "Function entries (no number prefix) are NOT group headers",
      "Module passes [M] are NOT group headers",
    },
  },
}

print("\nGroup Header Behavior Specifications:\n")

local test_num = 1
for _, spec in ipairs(group_header_specs) do
  print(string.format("Test %d: %s", test_num, spec.name))
  print(string.format("  Description: %s", spec.description))
  if spec.action then
    print(string.format("  Action:      %s", spec.action))
  end
  print("  Expected:")
  if type(spec.expected) == "table" then
    for _, exp in ipairs(spec.expected) do
      print(string.format("    - %s", exp))
    end
  else
    print(string.format("    - %s", spec.expected))
  end
  if spec.rationale then
    print(string.format("  Rationale:   %s", spec.rationale))
  end
  if spec.bug_before_fix then
    print(string.format("  Bug Before Fix: %s", spec.bug_before_fix))
  end
  print()
  test_num = test_num + 1
end

print(string.rep("=", 80))
print("\nKey Fix: Remove folded check in select_pass_for_viewing")
print("\nImplementation Details:")
print("  OLD CODE: if is_group_header and group.folded then")
print("  NEW CODE: if is_group_header then")
print("\nBehavior:")
print("  - Group headers (folded OR unfolded) ALWAYS clear buffers")
print("  - Group headers show name in buffer title: 'Group: PassName (folded/unfolded)'")
print("  - Function entries show actual IR diff")
print("  - Enter/o toggles fold state")
print("  - j/k navigates through visible lines only")

print("\nSpecification documented successfully.")

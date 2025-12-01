#!/usr/bin/env lua

-- Test changed pass highlighting (blue vs other colors)
-- These are specification tests - document expected behavior for has_changes computation

print("Pipeline Viewer Changed Pass Highlighting Specification Tests")
print(string.rep("=", 80))

-- Test scenarios for highlighting correctness
local highlighting_specs = {
  {
    name = "Function group with all changed functions",
    description = "Group with ALL functions changed should highlight as CHANGED (not blue)",
    setup = {
      group = {
        type = "function_group",
        pass_name = "InstCombinePass",
        functions = {
          { name = "foo", original_index = 100, changed = true },
          { name = "bar", original_index = 101, changed = true },
          { name = "baz", original_index = 102, changed = true },
        },
      },
    },
    computation = "has_changes = any function has changed=true",
    expected = {
      "has_changes = true",
      "Group highlighted with CHANGED color (NOT blue)",
      "All 3 functions have changed=true",
      "changed_count = 3, total_count = 3",
    },
  },
  {
    name = "Function group with some changed functions",
    description = "Group with SOME functions changed should highlight as CHANGED",
    setup = {
      group = {
        type = "function_group",
        pass_name = "SROAPass",
        functions = {
          { name = "foo", original_index = 200, changed = true },
          { name = "bar", original_index = 201, changed = false },
          { name = "baz", original_index = 202, changed = true },
        },
      },
    },
    computation = "has_changes = any function has changed=true",
    expected = {
      "has_changes = true",
      "Group highlighted with CHANGED color",
      "changed_count = 2, total_count = 3",
    },
  },
  {
    name = "Function group with NO changed functions",
    description = "Group with NO functions changed should highlight as UNCHANGED (blue)",
    setup = {
      group = {
        type = "function_group",
        pass_name = "NoOpPass",
        functions = {
          { name = "foo", original_index = 300, changed = false },
          { name = "bar", original_index = 301, changed = false },
        },
      },
    },
    computation = "has_changes = any function has changed=true",
    expected = {
      "has_changes = false",
      "Group highlighted with UNCHANGED color (blue)",
      "changed_count = 0, total_count = 2",
    },
  },
  {
    name = "Pass.changed values from compute_pass_changes",
    description = "compute_pass_changes should set pass.changed correctly based on IR diff",
    test_cases = {
      {
        pass_name = "InstCombinePass on foo",
        before_ir = { "define i32 @foo() {", "  ret i32 0", "}" },
        after_ir = { "define i32 @foo() {", "  ret i32 1", "}" }, -- Changed: 0 → 1
        expected_changed = true,
        expected_lines_changed = 1,
      },
      {
        pass_name = "NoOpPass on bar",
        before_ir = { "define i32 @bar() {", "  ret i32 42", "}" },
        after_ir = { "define i32 @bar() {", "  ret i32 42", "}" }, -- Identical
        expected_changed = false,
        expected_lines_changed = 0,
      },
      {
        pass_name = "InlinePass on baz",
        before_ir = { "define i32 @baz() {", "  %x = call i32 @helper()", "  ret i32 %x", "}" },
        after_ir = { "define i32 @baz() {", "  ret i32 42", "}" }, -- Inlined: 3 → 2 lines
        expected_changed = true,
        expected_lines_changed = 2,                                -- Size differs + content differs
      },
    },
    computation_steps = {
      "1. Get before_ir and after_ir for pass",
      "2. If sizes differ: changed=true, count size diff + line-by-line diff",
      "3. If sizes same: compare line-by-line, changed=true if any differ",
      "4. Set pass.changed and pass.diff_stats",
    },
  },
  {
    name = "Cache invalidation after compute_pass_changes",
    description = "grouped_passes cache must be cleared so has_changes is recomputed",
    sequence = {
      "1. setup() calls populate_pass_list()",
      "2. populate_pass_list() calls group_passes() → computes has_changes with STALE pass.changed",
      "3. compute_pass_changes() updates all pass.changed values",
      "4. CRITICAL: M.state.grouped_passes = nil to clear cache",
      "5. populate_pass_list() called again → group_passes() recomputes has_changes with FRESH pass.changed",
    },
    bug_without_invalidation = "has_changes computed before pass.changed is set = incorrect blue highlighting",
    expected = {
      "grouped_passes cache cleared at line 140",
      "has_changes recomputed with updated pass.changed values",
      "Groups with changed functions show CHANGED color",
    },
  },
  {
    name = "Debug logging to identify highlighting issues",
    description = "Debug logs should help identify when has_changes is incorrect",
    debug_output_changed_group = {
      "[DEBUG] Group 'InstCombinePass' marked as CHANGED (5/983 functions changed)",
    },
    debug_output_unchanged_group = {
      "[DEBUG] Group 'NoOpPass' marked as UNCHANGED but has 100 functions: " ..
      "fn[1] idx=500 changed=false, fn[2] idx=501 changed=false, fn[3] idx=502 changed=false",
    },
    debug_output_summary = {
      "[DEBUG] compute_pass_changes COMPLETE: 150 changed, 5000 unchanged, 0 nil (total 5150)",
    },
    what_to_check = {
      "If group shows blue but user sees diffs: check debug log for that group",
      "If changed=false but diffs exist: issue in compute_pass_changes IR comparison",
      "If changed=true but has_changes=false: issue in grouping logic or cache",
      "If summary shows nil count > 0: passes missing changed computation",
    },
  },
  {
    name = "Nil vs false for pass.changed",
    description = "Pass.changed should be BOOLEAN (true/false), never nil after compute_pass_changes",
    potential_bug = "If pass.changed is nil, the check 'if pass.changed' will be false (Lua treats nil as falsy)",
    expected = {
      "After compute_pass_changes: ALL passes have changed=true or changed=false",
      "No passes should have changed=nil",
      "Debug summary should show nil_count=0",
    },
    fix_if_nil = {
      "Ensure every pass goes through compute_pass_changes logic",
      "Check for early exits that skip setting pass.changed",
      "Verify --print-changed optimization sets pass.changed=false (not nil)",
    },
  },
}

print("\nChanged Pass Highlighting Behavior Specifications:\n")

local test_num = 1
for _, spec in ipairs(highlighting_specs) do
  print(string.format("Test %d: %s", test_num, spec.name))
  print(string.format("  Description: %s", spec.description))

  if spec.computation then
    print(string.format("  Computation: %s", spec.computation))
  end

  if spec.expected then
    print("  Expected:")
    for _, exp in ipairs(spec.expected) do
      print(string.format("    - %s", exp))
    end
  end

  if spec.bug_without_invalidation then
    print(string.format("  Bug: %s", spec.bug_without_invalidation))
  end

  if spec.potential_bug then
    print(string.format("  Potential Bug: %s", spec.potential_bug))
  end

  print()
  test_num = test_num + 1
end

print(string.rep("=", 80))
print("\nKey Implementation Points:")
print("\n1. compute_pass_changes() (lines 1115-1231):")
print("   - Compares before_ir vs after_ir line-by-line")
print("   - Sets pass.changed = true/false (boolean, never nil)")
print("   - Optimization: passes pre-marked with --print-changed skip comparison")
print("\n2. group_passes() (lines 331-366):")
print("   - Iterates through group.functions")
print("   - Checks M.state.passes[fn.original_index].changed for each function")
print("   - Sets group.has_changes = true if ANY function has changed=true")
print("\n3. Cache invalidation (line 140):")
print("   - M.state.grouped_passes = nil AFTER compute_pass_changes completes")
print("   - Forces group_passes() to recompute with fresh pass.changed values")
print("\n4. Debug logging:")
print("   - Summary: changed/unchanged/nil counts after compute_pass_changes")
print("   - Sample: every 100th changed pass during computation")
print("   - Groups: changed_count/total_count for each group")
print("   - Groups: sample first 3 functions if marked unchanged")

print("\nCommon Issues to Check:")
print("  1. Pass.changed is nil instead of false → Lua treats as falsy")
print("  2. Cache not invalidated → has_changes uses stale pass.changed")
print("  3. Wrong original_index → checking wrong pass's changed value")
print("  4. IR comparison bug → changed=false when IR actually differs")

print("\nSpecification documented successfully.")

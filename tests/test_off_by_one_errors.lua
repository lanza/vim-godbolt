#!/usr/bin/env lua

-- Test off-by-one errors in pipeline viewer navigation and indexing
-- These are specification tests - document expected behavior and common pitfalls

print("Pipeline Viewer Off-by-One Error Specification Tests")
print(string.rep("=", 80))

-- Critical indexing relationships to verify
local index_specs = {
  {
    name = "Pass index vs cursor line (no virtual scroll)",
    description = "Without virtual scroll, cursor line != pass index due to headers/formatting",
    example = {
      passes = {
        { index = 1, name = "ModulePass1" },
        { index = 2, name = "FunctionPass on foo" },
        { index = 3, name = "FunctionPass on bar" },
      },
      buffer_lines = {
        [1] = "Optimization Pipeline (3 passes)",
        [2] = "----------------------------------------",
        [3] = "",
        [4] = " 1. [M] ModulePass1",         -- Pass index 1 → line 4
        [5] = " 2. [F] FunctionPass on foo", -- Pass index 2 → line 5
        [6] = " 3. [F] FunctionPass on bar", -- Pass index 3 → line 6
      },
    },
    relationships = {
      "Pass index 1 → buffer line 4 (NOT line 1)",
      "Pass index i → buffer line (i + 3) for simple case",
      "Cursor line → look up in line_map to get original_index",
    },
    critical = "NEVER assume cursor_line == pass_index",
  },
  {
    name = "Pass index vs cursor line (virtual scroll)",
    description = "Virtual scroll uses line_map to translate display line → original_index",
    example = {
      virtual_scroll = {
        enabled = true,
        all_lines = 90000,                                    -- Total logical lines
        visible_lines = 60,                                   -- Rendered in buffer
      },
      cursor_line = 30,                                       -- Line 30 in 60-line buffer
      line_map = {
        [30] = { type = "function", original_index = 45678 }, -- Maps to pass 45678
      },
    },
    relationships = {
      "cursor_line 30 → line_map[30].original_index → 45678",
      "Display buffer has 60 lines, but represents 90K logical lines",
      "line_map is ESSENTIAL - cursor_line has no direct relationship to pass index",
    },
    critical = "MUST use line_map[cursor_line].original_index, not cursor_line",
  },
  {
    name = "current_index range (1-based indexing)",
    description = "M.state.current_index is 1-based, ranges from 1 to #passes",
    lua_indexing = "Lua arrays are 1-based: passes[1] is first element",
    valid_range = {
      min = 1,
      max = "#M.state.passes",
    },
    invalid_values = {
      [0] = "Off-by-one: Lua index 0 is invalid",
      ["#passes + 1"] = "Off-by-one: exceeds array bounds",
    },
    examples = {
      correct = {
        "for i = 1, #passes do ... end",
        "current_index = 1  -- First pass",
        "current_index = #passes  -- Last pass",
      },
      incorrect = {
        "for i = 0, #passes do ... end  -- Starts at 0 (invalid)",
        "current_index = 0  -- Invalid",
        "current_index = #passes + 1  -- Out of bounds",
      },
    },
  },
  {
    name = "Group.functions original_index",
    description = "Each function entry stores original_index pointing to M.state.passes",
    example = {
      group = {
        pass_name = "InstCombinePass",
        functions = {
          { name = "foo", original_index = 500 }, -- Points to M.state.passes[500]
          { name = "bar", original_index = 501 }, -- Points to M.state.passes[501]
        },
      },
    },
    usage = {
      correct = "M.state.passes[fn.original_index].changed",
      incorrect = {
        "M.state.passes[i].changed  -- i is group index, not pass index",
        "M.state.passes[fn.original_index - 1].changed  -- Off-by-one",
      },
    },
    critical = "original_index is CORRECT - don't add/subtract 1",
  },
  {
    name = "Cursor movement boundaries",
    description = "Prevent cursor from moving outside valid line range",
    buffer_line_count = 100,
    valid_cursor_range = {
      min = 1,   -- First line
      max = 100, -- Last line (buffer_line_count)
    },
    boundary_checks = {
      goto_next = {
        current_line = 100,
        action = "Press j",
        expected = "No movement - already at last line",
        bug_if_wrong = "Cursor moves to line 101 (invalid) → error",
      },
      goto_prev = {
        current_line = 1,
        action = "Press k",
        expected = "No movement - already at first line",
        bug_if_wrong = "Cursor moves to line 0 (invalid) → error",
      },
    },
    implementation = {
      "for i = current_line + 1, #lines do  -- Correct: starts at next line",
      "for i = current_line - 1, 1, -1 do  -- Correct: ends at line 1",
    },
  },
  {
    name = "Virtual viewport rendering range",
    description = "Viewport should render from cursor-centered window without off-by-one",
    example = {
      cursor_line = 50,
      visible_lines = 60,
      total_lines = 90000,
    },
    calculation = {
      half_window = "math.floor(visible_lines / 2) = 30",
      start_line = "math.max(1, cursor_line - 30) = 20",
      end_line = "math.min(total_lines, start_line + visible_lines - 1) = 79",
    },
    critical_points = {
      "start_line ≥ 1 (not 0)",
      "end_line ≤ total_lines (not total_lines + 1)",
      "Number of rendered lines = end_line - start_line + 1 = 60 (INCLUSIVE range)",
    },
    off_by_one_bugs = {
      "end_line = start_line + visible_lines → renders 61 lines (bug)",
      "count = end_line - start_line → off by 1 (should be + 1)",
    },
  },
  {
    name = "Line map indexing",
    description = "line_map translates display line number → metadata",
    example = {
      line_map = {
        [1] = { type = "module", original_index = 1 },
        [2] = { type = "function", original_index = 2 },
        -- ...
        [60] = { type = "function", original_index = 5000 },
      },
    },
    usage = {
      correct = {
        "local metadata = line_map[cursor_line]",
        "local pass = M.state.passes[metadata.original_index]",
      },
      incorrect = {
        "local metadata = line_map[cursor_line - 1]  -- Off-by-one",
        "local pass = M.state.passes[cursor_line]  -- Wrong index",
      },
    },
    critical = "line_map keys are 1-based display line numbers",
  },
  {
    name = "Array iteration patterns",
    description = "Common Lua iteration patterns to avoid off-by-one",
    patterns = {
      forward_iteration = {
        correct = "for i = 1, #array do",
        incorrect = "for i = 0, #array do  -- Starts at invalid index 0",
      },
      backward_iteration = {
        correct = "for i = #array, 1, -1 do",
        incorrect = "for i = #array - 1, 0, -1 do  -- Misses last element, ends at 0",
      },
      range_iteration = {
        correct = "for i = start, math.min(start + count - 1, #array) do",
        incorrect = "for i = start, start + count do  -- Iterates count+1 times",
      },
    },
  },
  {
    name = "Marker position updates",
    description = "Markers (> and ●) must be placed on correct line after state update",
    example = {
      current_index = 50,
      line_map = {
        [29] = { original_index = 49 },
        [30] = { original_index = 50 }, -- current_index 50 → display line 30
        [31] = { original_index = 51 },
      },
    },
    marker_placement = {
      "Find line where line_map[line].original_index == current_index",
      "Place marker on that line (line 30 in example)",
      "NOT on current_index line directly (50 != 30)",
    },
    bug_if_wrong = "Marker appears on wrong line or not at all",
  },
}

print("\nOff-by-One Error Specifications:\n")

local test_num = 1
for _, spec in ipairs(index_specs) do
  print(string.format("Test %d: %s", test_num, spec.name))
  print(string.format("  Description: %s", spec.description))

  if spec.relationships then
    print("  Relationships:")
    for _, rel in ipairs(spec.relationships) do
      print(string.format("    - %s", rel))
    end
  end

  if spec.critical then
    print(string.format("  CRITICAL: %s", spec.critical))
  end

  print()
  test_num = test_num + 1
end

print(string.rep("=", 80))
print("\nKey Principles to Avoid Off-by-One Errors:")
print("\n1. Lua indexing is 1-based:")
print("   - Valid array indices: 1 to #array")
print("   - for i = 1, #array do ... end (CORRECT)")
print("   - for i = 0, #array do ... end (WRONG - starts at invalid 0)")
print("\n2. Cursor line != pass index:")
print("   - Without virtual scroll: cursor_line includes headers")
print("   - With virtual scroll: MUST use line_map[cursor_line].original_index")
print("   - Never assume cursor_line can index directly into passes array")
print("\n3. Inclusive ranges:")
print("   - Lua ranges are INCLUSIVE on both ends")
print("   - for i = 1, 10 do iterates 10 times (1, 2, ..., 10)")
print("   - Count = end - start + 1 (the +1 is critical)")
print("\n4. Boundary checks:")
print("   - Before incrementing: check i <= max")
print("   - Before decrementing: check i >= 1")
print("   - Use math.max(1, ...) and math.min(#array, ...) for safety")
print("\n5. Virtual scroll viewport:")
print("   - start_line = math.max(1, cursor - half_window)")
print("   - end_line = math.min(total, start + visible - 1)")
print("   - Count = end_line - start_line + 1")

print("\nCommon Off-by-One Bugs to Check:")
print("  ✗ Using cursor_line as pass index")
print("  ✗ for i = 0, #array (starts at invalid 0)")
print("  ✗ end_line = start + count (should be start + count - 1)")
print("  ✗ count = end - start (should be end - start + 1)")
print("  ✗ Forgetting line_map in virtual scroll mode")
print("  ✗ original_index ± 1 (it's already correct)")

print("\nSpecification documented successfully.")

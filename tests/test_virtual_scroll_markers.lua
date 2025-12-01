#!/usr/bin/env lua

-- Test virtual scrolling marker updates and navigation
-- These are specification tests - document expected behavior for the virtual scroll fixes

print("Pipeline Viewer Virtual Scroll Marker Specification Tests")
print(string.rep("=", 80))

-- Test scenarios that document how markers SHOULD work with virtual scrolling
local marker_specs = {
  {
    name = "Circle marker (●) stability during k navigation",
    description = "Marker should not flicker when navigating up with k key",
    setup = {
      total_passes = 100,
      current_index = 50,
      cursor_line = 50,
      virtual_scroll_enabled = true,
    },
    action = "Press k to move to previous pass (line 49)",
    expected = {
      "CursorMoved autocmd should NOT fire between cursor move and state update",
      "navigating flag prevents update_virtual_viewport during transition",
      "Circle marker (●) appears ONLY on line 49 after transition completes",
      "NO flickering - marker should never appear on both lines 49 and 50",
    },
    bug_before_fix = "CursorMoved fired before current_index update, causing double render with different markers",
  },
  {
    name = "Circle marker (●) stability during j navigation",
    description = "Marker should not flicker when navigating down with j key",
    setup = {
      total_passes = 100,
      current_index = 50,
      cursor_line = 50,
      virtual_scroll_enabled = true,
    },
    action = "Press j to move to next pass (line 51)",
    expected = {
      "navigating flag set before cursor movement",
      "CursorMoved autocmd returns early due to navigating flag",
      "select_pass_for_viewing updates current_index and renders once",
      "Circle marker (●) appears ONLY on line 51 after transition completes",
      "NO double rendering",
    },
    bug_before_fix = "User reported marker appearing/disappearing randomly with k key",
  },
  {
    name = "Arrow marker (>) stability on module passes",
    description = "Module pass marker should update correctly in virtual scroll",
    setup = {
      passes = {
        { index = 1, type = "module",   name = "ModulePass1",  changed = true },
        { index = 2, type = "function", name = "FunctionPass", changed = false },
        { index = 3, type = "module",   name = "ModulePass2",  changed = true },
      },
      current_index = 1,
      virtual_scroll_enabled = true,
    },
    action = "Press j twice to navigate from module pass 1 to module pass 2",
    expected = {
      "Arrow marker (>) moves from line 1 to line 3",
      "No flickering between states",
      "Virtual viewport re-renders with correct marker positions",
    },
  },
  {
    name = "Viewport re-render timing",
    description = "Virtual viewport should only re-render AFTER state updates complete",
    setup = {
      total_passes = 5000,
      current_index = 2500,
      cursor_line = 30, -- Middle of 60-line viewport
      virtual_scroll_enabled = true,
    },
    action = "Press k to navigate to line 29",
    expected = {
      "goto_prev_pass_line sets navigating=true",
      "Cursor moves to line 29",
      "CursorMoved autocmd fires but returns early (navigating=true)",
      "select_pass_for_viewing updates current_index to 2499",
      "render_virtual_viewport called with NEW current_index",
      "vim.schedule clears navigating=false",
      "Subsequent cursor movements work normally",
    },
  },
  {
    name = "Rapid navigation sequence",
    description = "Multiple rapid k/j presses should maintain marker consistency",
    setup = {
      total_passes = 100,
      current_index = 50,
      virtual_scroll_enabled = true,
    },
    action = "Rapidly press k k k j j (navigate up 3, down 2)",
    expected = {
      "Each navigation sets navigating=true before cursor move",
      "CursorMoved skipped during each transition",
      "Final marker position: line 48 (50 - 3 + 2)",
      "NO intermediate flickers or double markers",
      "State consistency maintained throughout sequence",
    },
  },
}

print("\nVirtual Scroll Marker Behavior Specifications:\n")

local test_num = 1
for _, spec in ipairs(marker_specs) do
  print(string.format("Test %d: %s", test_num, spec.name))
  print(string.format("  Description: %s", spec.description))
  print(string.format("  Action:      %s", spec.action))
  print("  Expected:")
  for _, exp in ipairs(spec.expected) do
    print(string.format("    - %s", exp))
  end
  if spec.bug_before_fix then
    print(string.format("  Bug Before Fix: %s", spec.bug_before_fix))
  end
  print()
  test_num = test_num + 1
end

print(string.rep("=", 80))
print("\nKey Fix: navigating flag prevents CursorMoved race condition")
print("\nImplementation Details:")
print("  1. M.state.virtual_scroll.navigating flag added")
print("  2. goto_next_pass_line() sets flag before cursor move, clears with vim.schedule")
print("  3. goto_prev_pass_line() sets flag before cursor move, clears with vim.schedule")
print("  4. update_virtual_viewport() checks flag and returns early if navigating")
print("\nRace Condition Before Fix:")
print("  goto_next_pass_line() moves cursor → CursorMoved fires → renders with OLD index")
print("  → select_pass_for_viewing() updates index → renders with NEW index")
print("  → User sees TWO renders with different marker positions = flicker")
print("\nAfter Fix:")
print("  goto_next_pass_line() sets flag → moves cursor → CursorMoved returns early")
print("  → select_pass_for_viewing() updates index + renders ONCE → clears flag")
print("  → User sees ONE render with correct marker position = no flicker")

print("\nSpecification documented successfully.")

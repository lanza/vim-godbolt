# Neovim Buffer Highlighting Best Practices

## Overview
This skill documents best practices for implementing buffer highlighting, theming, and visual effects in Neovim plugins, learned from developing the godbolt.nvim plugin's highlighting system.

## Core Principles

### 1. **Separate Namespaces by Update Frequency**

Always use separate namespaces for highlights that update at different rates:

```lua
-- CORRECT: Two namespaces for different purposes
M.ns_static = vim.api.nvim_create_namespace('myplug_static')
M.ns_cursor = vim.api.nvim_create_namespace('myplug_cursor')

-- ns_static: Set once when mapping is established (structural highlights)
-- ns_cursor: Updates every cursor movement (transient highlights)
```

**Why?** Clearing and re-applying highlights is expensive. Separating by update frequency means you only clear/reapply the transient highlights, not the structural ones.

### 2. **Always Validate Buffers Before Operations**

```lua
-- CORRECT: Validate before every highlight operation
if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
  return
end

-- Use pcall for additional safety when applying highlights
pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, group, line, col_start, col_end)
```

**Why?** Buffers can be deleted at any time. Invalid buffer operations crash the plugin.

### 3. **Clear Highlights in ALL Affected Buffers**

When updating cursor highlights that span multiple buffers (e.g., source ↔ output mapping):

```lua
-- CORRECT: Clear in both buffers
highlight.clear_namespace(state.source_bufnr, highlight.ns_cursor)
highlight.clear_namespace(state.output_bufnr, highlight.ns_cursor)

-- Then apply new highlights
highlight.highlight_lines_cursor(state.source_bufnr, {cursor_line})
highlight.highlight_lines_cursor(state.output_bufnr, mapped_lines)
```

**Why?** Forgetting to clear highlights in one buffer causes visual artifacts and duplicate highlights.

### 4. **Background-Aware Colors**

```lua
function M.setup()
  local bg = vim.o.background

  if bg == "dark" then
    vim.api.nvim_set_hl(0, "MyHighlight", {bg = "#404040"})
  else
    vim.api.nvim_set_hl(0, "MyHighlight", {bg = "#d0d0d0"})
  end
end
```

**Why?** Light backgrounds need darker colors, dark backgrounds need lighter colors for visibility.

## API Reference

### When to Use Each Highlighting Method

#### 1. `nvim_buf_add_highlight` - Full-line backgrounds
**Use for:** Full-line background highlights, structural highlighting

```lua
-- Highlights from column 0 to end of line (-1)
vim.api.nvim_buf_add_highlight(bufnr, ns, 'GodboltLevel1', line_num - 1, 0, -1)
```

**Note:** Line numbers are **0-indexed**, column end of `-1` means "to end of line"

#### 2. `vim.hl.range` - Precise token/column highlighting
**Use for:** Syntax highlighting, keyword coloring, precise token ranges

```lua
-- Highlight characters 5-10 on line 3
vim.hl.range(bufnr, ns, 'Keyword', {2, 4}, {2, 10}, {})
```

**Note:** Uses **0-indexed** positions with format `{line, col}`. The end position is **EXCLUSIVE**.

**Example:** To highlight "function" at line 3, columns 5-13:
```lua
vim.hl.range(bufnr, ns, 'Keyword', {2, 4}, {2, 12}, {})
-- {2, 4} = line 3 (0-indexed: 2), col 5 (0-indexed: 4)
-- {2, 12} = line 3, col 13 (exclusive, so stops at col 12)
```

#### 3. `vim.diagnostic.set` - LSP-style inline hints
**Use for:** Error/warning/info hints that should appear inline

```lua
vim.diagnostic.set(ns, bufnr, {
  {
    lnum = 0,  -- 0-indexed line
    col = 0,   -- 0-indexed column
    severity = vim.diagnostic.severity.INFO,
    message = "Optimization: 'foo' inlined into 'bar'",
  }
}, {})
```

**When NOT to use:** When you don't have precise line mappings. Diagnostics require accurate line/column info or they appear in wrong places.

**Known limitation in this project:** Cannot map LLVM optimization remarks to IR lines because pipeline uses `opt --strip-debug` which removes all `!dbg` metadata needed for source→IR mapping.

#### 4. Extmarks with `virt_text` - Virtual text annotations
**Use for:** Adding text that doesn't exist in the buffer

```lua
vim.api.nvim_buf_set_extmark(bufnr, ns, line_num - 1, 0, {
  virt_text = {{"  <- This is a note", "Comment"}},
  virt_text_pos = 'eol',  -- End of line
})
```

**Use cases:** Inline hints, end-of-line annotations, decorative markers

## Common Patterns

### Pattern 1: Two-Phase Highlighting
**Structural (once) + Transient (frequently)**

```lua
-- Phase 1: Apply static highlights ONCE when mapping is set up
local function apply_static_highlights()
  for src_line, out_lines in pairs(src_to_out) do
    highlight.highlight_lines_static(source_bufnr, {src_line})
    highlight.highlight_lines_static(output_bufnr, out_lines)
  end
end

-- Phase 2: Update cursor highlights on EVERY cursor movement
local function update_cursor_highlights()
  -- Clear previous transient highlights
  highlight.clear_namespace(source_bufnr, ns_cursor)
  highlight.clear_namespace(output_bufnr, ns_cursor)

  -- Apply new transient highlights
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  highlight.highlight_lines_cursor(source_bufnr, {cursor_line})
  highlight.highlight_lines_cursor(output_bufnr, mapped_lines)
end
```

### Pattern 2: Throttling Cursor Updates
**Prevent performance issues from high-frequency cursor movements**

```lua
local function throttle(fn, delay_ms)
  local timer = vim.loop.new_timer()
  local pending = false

  return function(...)
    if not pending then
      pending = true
      local args = {...}
      timer:start(delay_ms, 0, vim.schedule_wrap(function()
        fn(unpack(args))
        pending = false
      end))
    end
  end
end

-- Usage: Create throttled update function (50-150ms is good)
local throttled_update = throttle(update_cursor_highlights, 50)

vim.api.nvim_create_autocmd({'CursorMoved', 'CursorMovedI'}, {
  buffer = bufnr,
  callback = throttled_update,
})
```

### Pattern 3: Avoiding Duplicate Highlights
**Check what's already highlighted before adding more**

```lua
-- Get already highlighted lines
local highlighted_lines = vim.api.nvim_buf_get_extmarks(
  bufnr,
  ns_static,
  0,
  -1,
  {type = "highlight"}
)

-- Convert to lookup table
local highlighted_set = {}
for _, mark in ipairs(highlighted_lines) do
  highlighted_set[mark[2]] = true  -- mark[2] is the line number (0-indexed)
end

-- Only highlight if not already highlighted
if not highlighted_set[line_num - 1] then
  vim.api.nvim_buf_add_highlight(bufnr, ns_static, group, line_num - 1, 0, -1)
end
```

### Pattern 4: Line Number Translation (Filtered Buffers)
**When displayed lines ≠ original lines (e.g., filtered debug metadata)**

```lua
-- Store original→displayed mapping in buffer variable
vim.b[bufnr].godbolt_line_map = {
  [1] = 1,    -- Displayed line 1 = original line 1
  [2] = 3,    -- Displayed line 2 = original line 3 (line 2 was filtered)
  [3] = 4,    -- etc.
}

-- When highlighting, translate displayed→original
local function translate_to_original(displayed_line)
  local line_map = vim.b[bufnr].godbolt_line_map
  if line_map then
    return line_map[displayed_line] or displayed_line
  end
  return displayed_line
end

-- When getting cursor line (displayed), translate to original for lookups
local displayed_line = vim.api.nvim_win_get_cursor(0)[1]
local original_line = translate_to_original(displayed_line)

-- Use original_line for data structure lookups, displayed_line for highlights
local mapped_data = out_to_src[original_line]
vim.api.nvim_buf_add_highlight(bufnr, ns, group, displayed_line - 1, 0, -1)
```

### Pattern 5: Popup Window Highlighting
**Apply semantic highlighting to floating windows**

```lua
-- Create popup with content
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

-- Apply highlights using vim.hl.range for precise token highlighting
local ns = vim.api.nvim_create_namespace('popup_highlights')

for line_num, line in ipairs(lines) do
  -- Find patterns and highlight them
  local start_idx, end_idx = line:find("PASS")
  if start_idx then
    vim.hl.range(
      bufnr,
      ns,
      'DiagnosticOk',           -- Green for PASS
      {line_num - 1, start_idx - 1},  -- Start: {line, col} (0-indexed)
      {line_num - 1, end_idx},        -- End: {line, col} (exclusive)
      {}
    )
  end
end

-- Show popup
local win = vim.api.nvim_open_win(bufnr, false, {
  relative = 'cursor',
  width = 80,
  height = 20,
  row = 1,
  col = 0,
  style = 'minimal',
  border = 'rounded',
})
```

## Common Mistakes

### ❌ Mistake 1: Using vim.diagnostic without precise line mappings
```lua
-- WRONG: Remarks have source line info, but we're showing LLVM IR
-- The source lines don't correspond to IR lines without debug metadata
vim.diagnostic.set(ns, ir_bufnr, {
  {
    lnum = remark.location.line - 1,  -- This is a SOURCE line!
    message = remark.message,
  }
})
```

**Why wrong?** The IR buffer shows LLVM IR, but remarks have source file locations. Without debug metadata (`!dbg` annotations), you can't map source lines to IR lines. Diagnostics appear at wrong locations.

**✓ Fix:** Use popup windows with keymap triggers (`R`, `gR`) instead of inline diagnostics.

### ❌ Mistake 2: Forgetting to clear highlights in related buffers
```lua
-- WRONG: Only clearing in one buffer
highlight.clear_namespace(source_bufnr, ns_cursor)
-- Forgot to clear in output_bufnr!
highlight.highlight_lines_cursor(source_bufnr, {cursor_line})
```

**Why wrong?** Old highlights remain in output buffer, causing duplicate/stale highlights.

**✓ Fix:** Always clear in ALL affected buffers:
```lua
highlight.clear_namespace(source_bufnr, ns_cursor)
highlight.clear_namespace(output_bufnr, ns_cursor)
```

### ❌ Mistake 3: Mixing static and transient highlights in same namespace
```lua
-- WRONG: Using same namespace for both
local ns = vim.api.nvim_create_namespace('highlights')

-- Initial structural highlights
highlight_all_mapped_lines(bufnr, ns)

-- Cursor movement
vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)  -- Clears EVERYTHING!
highlight_cursor_line(bufnr, ns)  -- Static highlights are gone now
```

**Why wrong?** Clearing the namespace removes both structural and cursor highlights. You have to re-apply structural highlights on every cursor movement (expensive!).

**✓ Fix:** Use separate namespaces:
```lua
local ns_static = vim.api.nvim_create_namespace('highlights_static')
local ns_cursor = vim.api.nvim_create_namespace('highlights_cursor')

-- Initial highlights (once)
highlight_all_mapped_lines(bufnr, ns_static)

-- Cursor movement (only clear/update cursor namespace)
vim.api.nvim_buf_clear_namespace(bufnr, ns_cursor, 0, -1)
highlight_cursor_line(bufnr, ns_cursor)
```

### ❌ Mistake 4: Not validating buffers before operations
```lua
-- WRONG: Assuming buffer is valid
vim.api.nvim_buf_add_highlight(bufnr, ns, 'Highlight', line, 0, -1)
-- CRASHES if buffer was deleted!
```

**✓ Fix:** Always validate:
```lua
if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
  return
end
pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, 'Highlight', line, 0, -1)
```

### ❌ Mistake 5: Off-by-one errors with line numbers
```lua
-- WRONG: Mixing 1-indexed and 0-indexed
local cursor_line = vim.api.nvim_win_get_cursor(0)[1]  -- Returns 1-indexed
vim.api.nvim_buf_add_highlight(bufnr, ns, 'Hl', cursor_line, 0, -1)  -- Expects 0-indexed!
-- Highlights wrong line!
```

**✓ Fix:** Always subtract 1 when passing to API:
```lua
local cursor_line = vim.api.nvim_win_get_cursor(0)[1]  -- 1-indexed from user
vim.api.nvim_buf_add_highlight(bufnr, ns, 'Hl', cursor_line - 1, 0, -1)  -- 0-indexed for API
```

### ❌ Mistake 6: Using virtual text for visual feedback
```lua
-- WRONG: Adding "Inlined" virtual text to every inlined function
vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
  virt_text = {{"  Inlined", "Comment"}},
  virt_text_pos = 'eol',
})
```

**Why wrong?**
1. Without precise line mapping (source→IR), virtual text appears at random locations
2. Clutters the display with redundant info
3. User already requested removal: "Please remove the 'Inlined' virtual text"

**✓ Fix:** Use popup windows triggered by keymaps for detailed information.

## Known Limitations

### Debug Metadata Stripping
**Problem:** The godbolt.nvim pipeline uses `opt --strip-debug` to keep IR readable by removing debug metadata (`!dbg`, `!DILocation`, etc.).

**Impact:** Cannot map LLVM optimization remarks (which contain source file locations) to IR line numbers without this debug info.

**Workaround:** Use popup displays (`R` = current pass remarks, `gR` = all remarks) instead of inline diagnostics. Store original unfiltered IR in `vim.b[bufnr].godbolt_full_output` if needed for parsing.

### Performance Considerations
**Large files:** Highlighting thousands of lines is slow. Use:
- Throttling (50-150ms) for cursor updates
- Avoid re-highlighting static content
- Use `pcall` to prevent crashes from edge cases
- Consider lazy highlighting (only highlight visible range)

### Floating Window Lifecycles
**Problem:** Popup windows are ephemeral - they close when user moves cursor or presses keys.

**Best practice:** Don't try to update popup highlights after creation. Highlight once when creating the popup, then let it be closed naturally.

## Summary Checklist

When implementing highlighting:

- [ ] Use separate namespaces for static vs. transient highlights
- [ ] Validate buffers before every operation
- [ ] Clear highlights in ALL affected buffers
- [ ] Use background-aware colors
- [ ] Choose the right API (nvim_buf_add_highlight vs vim.hl.range vs vim.diagnostic)
- [ ] Throttle high-frequency updates (cursor movement)
- [ ] Handle line number translation for filtered buffers
- [ ] Avoid off-by-one errors (1-indexed user values → 0-indexed API)
- [ ] Check for already-highlighted lines to avoid duplicates
- [ ] Clean up autocmds and state when buffers are deleted
- [ ] Refresh highlights when colorscheme changes

## References

- `lua/godbolt/highlight.lua` - Central highlighting module
- `lua/godbolt/line_map.lua` - Two-phase highlighting with throttling
- `lua/godbolt/pipeline_viewer.lua` - Popup highlighting examples

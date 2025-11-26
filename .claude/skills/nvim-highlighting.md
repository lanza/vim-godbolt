# Neovim Buffer Highlighting Skill

This skill documents best practices for implementing buffer highlighting, theming, and visual effects in Neovim plugins using Lua.

## When to Use Different Highlighting APIs

### `vim.api.nvim_buf_add_highlight()` - Native Buffer Highlighting

**Use this when:**
- You need full-line background highlighting
- You want simple, performant highlighting without extra features
- You're highlighting code syntax or matched lines
- You want highlighting that automatically adjusts to line changes

**Syntax:**
```lua
vim.api.nvim_buf_add_highlight(
  buffer,      -- Buffer number (integer)
  ns_id,       -- Namespace ID (integer, use 0 for ephemeral)
  hl_group,    -- Highlight group name (string)
  line,        -- Line number (0-indexed)
  col_start,   -- Start column (0 for beginning of line)
  col_end      -- End column (-1 for end of line)
)
```

**Key Parameters:**
- `col_end = -1` highlights to the end of the line (full-line background)
- `col_start = 0, col_end = -1` highlights the entire line
- Line numbers are 0-indexed (subtract 1 from user-facing line numbers)

**Example:**
```lua
-- Highlight line 10 (1-indexed) with full background
vim.api.nvim_buf_add_highlight(bufnr, ns_id, "MyHighlight", 9, 0, -1)
```

### `vim.api.nvim_buf_set_extmark()` - Extended Marks

**Use this when:**
- You need virtual text, inline diagnostics, or decorations
- You want persistent marks that survive buffer changes
- You need line/column tracking with automatic adjustment
- You want additional features like conceal, signs, or virtual lines

**Syntax:**
```lua
vim.api.nvim_buf_set_extmark(bufnr, ns_id, line, col, {
  end_row = line + 1,
  end_col = 0,
  hl_group = "MyHighlight",
  hl_eol = true,  -- Highlight to end of line
  priority = 100,
  -- Additional options...
})
```

**When NOT to use extmarks for highlighting:**
- If you just need simple line highlighting, use `nvim_buf_add_highlight()` instead
- Extmarks are more complex and have more overhead

### `vim.fn.matchaddpos()` - Legacy Vim Highlighting

**Avoid using this in new plugins:**
- Limited to 8 highlights per call
- Less performant than native APIs
- Limited namespace support
- Use `nvim_buf_add_highlight()` instead

## Namespace Management

Namespaces isolate highlights and allow selective clearing without affecting other plugins.

### Creating Namespaces

```lua
local ns_id = vim.api.nvim_create_namespace('plugin_name_purpose')
```

**Best Practice:** Create separate namespaces for different purposes:
```lua
local M = {}
M.ns_static = vim.api.nvim_create_namespace('myplug_static')
M.ns_cursor = vim.api.nvim_create_namespace('myplug_cursor')
```

### Why Use Multiple Namespaces?

**Example: Static vs Dynamic Highlights**

1. **Static namespace** - Persistent highlights that stay visible
   - Applied once during initialization
   - Cleared only when needed (colorscheme change, cleanup)
   - Shows overall structure or mappings

2. **Cursor namespace** - Dynamic highlights that follow cursor
   - Cleared on every cursor movement
   - Redrawn based on new cursor position
   - Shows current selection or focus

### Clearing Namespaces

```lua
-- Clear all highlights in a namespace
vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

-- Clear specific line range
vim.api.nvim_buf_clear_namespace(bufnr, ns_id, start_line, end_line)
```

**Performance Tip:** Clear only the namespace you need, not all highlights:
```lua
-- Good - clears only cursor highlights
vim.api.nvim_buf_clear_namespace(bufnr, ns_cursor, 0, -1)

-- Bad - clears ALL highlights in buffer
vim.api.nvim_buf_clear_namespace(bufnr, -1, 0, -1)
```

## Highlight Groups and Colors

### Creating Highlight Groups with Hex Colors

```lua
vim.api.nvim_set_hl(0, "MyHighlight", {bg = "#404040"})
```

**Parameters:**
- First argument: `0` means global namespace
- Second argument: Highlight group name
- Third argument: Table with attributes (`fg`, `bg`, `bold`, `italic`, etc.)

### Linking to Existing Highlight Groups

```lua
vim.api.nvim_set_hl(0, "MyHighlight", {link = "Visual"})
```

This makes `MyHighlight` use whatever colors `Visual` has.

### Supporting Light and Dark Themes

```lua
function setup_highlights()
  local bg = vim.o.background

  if bg == "dark" then
    vim.api.nvim_set_hl(0, "MyHighlight", {bg = "#404040"})
  else
    vim.api.nvim_set_hl(0, "MyHighlight", {bg = "#d0d0d0"})
  end
end

-- Refresh on colorscheme change
vim.api.nvim_create_autocmd('ColorScheme', {
  callback = function()
    setup_highlights()
  end
})
```

### Color Progression for Multi-Level Highlights

```lua
-- Dark theme: lighter grays (more visible on dark background)
local colors_dark = {"#404040", "#383838", "#303030", "#282828", "#242424"}

-- Light theme: darker grays (more visible on light background)
local colors_light = {"#d0d0d0", "#d8d8d8", "#e0e0e0", "#e8e8e8", "#f0f0f0"}

-- Cyclic selection
local function get_color_for_line(line_num, colors)
  local index = ((line_num - 1) % #colors) + 1
  return colors[index]
end
```

## Querying Existing Highlights

To avoid duplicate highlighting, check what's already highlighted:

```lua
function get_highlighted_lines(bufnr, ns_id)
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {
    type = "highlight",
    details = false,
  })

  local lines = {}
  for _, mark in ipairs(extmarks) do
    local line = mark[2]  -- Second element is line number (0-indexed)
    table.insert(lines, line)
  end

  return lines
end
```

**Note:** Even with `nvim_buf_add_highlight()`, you query using `nvim_buf_get_extmarks()` with `type = "highlight"`.

## Common Patterns

### Pattern 1: Full-Line Highlighting

```lua
-- Highlight an entire line with background color
vim.api.nvim_buf_add_highlight(bufnr, ns_id, "MyHighlight", line - 1, 0, -1)
```

### Pattern 2: Highlight Multiple Lines

```lua
function highlight_lines(bufnr, ns_id, hl_group, lines)
  for _, line_num in ipairs(lines) do
    vim.api.nvim_buf_add_highlight(
      bufnr,
      ns_id,
      hl_group,
      line_num - 1,  -- Convert to 0-indexed
      0,             -- Start of line
      -1             -- End of line
    )
  end
end
```

### Pattern 3: Dynamic Cursor-Following Highlights

```lua
local function update_cursor_highlights()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  -- Clear previous highlights
  vim.api.nvim_buf_clear_namespace(bufnr, ns_cursor, 0, -1)

  -- Apply new highlights based on cursor position
  local related_lines = get_related_lines(cursor_line)
  for _, line in ipairs(related_lines) do
    vim.api.nvim_buf_add_highlight(bufnr, ns_cursor, "Cursor", line - 1, 0, -1)
  end
end

-- Set up autocmd
vim.api.nvim_create_autocmd({'CursorMoved', 'CursorMovedI'}, {
  buffer = bufnr,
  callback = update_cursor_highlights
})
```

### Pattern 4: Bidirectional Buffer Highlighting

```lua
-- Highlight both source and target buffers
local function sync_highlights(source_buf, target_buf, line_mapping)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  -- Clear both buffers
  vim.api.nvim_buf_clear_namespace(source_buf, ns_cursor, 0, -1)
  vim.api.nvim_buf_clear_namespace(target_buf, ns_cursor, 0, -1)

  -- Highlight source line
  vim.api.nvim_buf_add_highlight(source_buf, ns_cursor, "Cursor", cursor_line - 1, 0, -1)

  -- Highlight corresponding target lines
  local target_lines = line_mapping[cursor_line]
  for _, target_line in ipairs(target_lines) do
    vim.api.nvim_buf_add_highlight(target_buf, ns_cursor, "Cursor", target_line - 1, 0, -1)
  end
end
```

## Performance Considerations

### Use pcall for Safety

```lua
pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, hl_group, line, 0, -1)
```

This prevents errors if the buffer is no longer valid.

### Throttle Cursor Movement Updates

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

local throttled_update = throttle(update_cursor_highlights, 150)
```

### Check Buffer Validity

```lua
if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
  return
end
```

## Complete Example: Dual Namespace System

```lua
local M = {}

-- Create two namespaces
M.ns_static = vim.api.nvim_create_namespace('plugin_static')
M.ns_cursor = vim.api.nvim_create_namespace('plugin_cursor')

-- Setup highlight groups
function M.setup()
  vim.api.nvim_set_hl(0, "PluginLevel1", {bg = "#404040"})
  vim.api.nvim_set_hl(0, "PluginLevel2", {bg = "#383838"})
  vim.api.nvim_set_hl(0, "PluginCursor", {link = "Visual"})
end

-- Apply static highlights (once)
function M.apply_static(bufnr, lines)
  for i, line in ipairs(lines) do
    local hl_group = "PluginLevel" .. ((i % 2) + 1)
    vim.api.nvim_buf_add_highlight(bufnr, M.ns_static, hl_group, line - 1, 0, -1)
  end
end

-- Update cursor highlights (on every cursor move)
function M.update_cursor(bufnr, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_cursor, 0, -1)
  for _, line in ipairs(lines) do
    vim.api.nvim_buf_add_highlight(bufnr, M.ns_cursor, "PluginCursor", line - 1, 0, -1)
  end
end

return M
```

## Common Pitfalls

### ❌ Using extmarks when `nvim_buf_add_highlight` is sufficient

```lua
-- Bad - unnecessary complexity
vim.api.nvim_buf_set_extmark(bufnr, ns_id, line, 0, {
  end_row = line + 1,
  end_col = 0,
  hl_eol = true,
  hl_group = "MyHighlight",
})

-- Good - simple and performant
vim.api.nvim_buf_add_highlight(bufnr, ns_id, "MyHighlight", line, 0, -1)
```

### ❌ Forgetting to convert line numbers to 0-indexed

```lua
-- Bad - highlights wrong line
local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
vim.api.nvim_buf_add_highlight(bufnr, ns_id, "HL", cursor_line, 0, -1)

-- Good - subtracts 1 for 0-indexed API
vim.api.nvim_buf_add_highlight(bufnr, ns_id, "HL", cursor_line - 1, 0, -1)
```

### ❌ Not using -1 for end column

```lua
-- Bad - doesn't highlight full line
vim.api.nvim_buf_add_highlight(bufnr, ns_id, "HL", line, 0, 999)

-- Good - -1 means end of line
vim.api.nvim_buf_add_highlight(bufnr, ns_id, "HL", line, 0, -1)
```

### ❌ Clearing all namespaces instead of specific ones

```lua
-- Bad - clears highlights from other plugins
vim.api.nvim_buf_clear_namespace(bufnr, -1, 0, -1)

-- Good - clears only your namespace
vim.api.nvim_buf_clear_namespace(bufnr, M.ns_id, 0, -1)
```

### ❌ Hardcoding colors without theme detection

```lua
-- Bad - looks terrible on light themes
vim.api.nvim_set_hl(0, "MyHL", {bg = "#404040"})

-- Good - adapts to theme
local bg = vim.o.background == "dark" and "#404040" or "#d0d0d0"
vim.api.nvim_set_hl(0, "MyHL", {bg = bg})
```

## Quick Reference

| Task | API Call |
|------|----------|
| Create namespace | `vim.api.nvim_create_namespace(name)` |
| Highlight full line | `vim.api.nvim_buf_add_highlight(buf, ns, hl, line-1, 0, -1)` |
| Clear namespace | `vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)` |
| Set highlight group | `vim.api.nvim_set_hl(0, name, {bg = color})` |
| Link highlight | `vim.api.nvim_set_hl(0, name, {link = "Existing"})` |
| Query highlights | `vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {type="highlight"})` |

## References

- `:help nvim_buf_add_highlight()`
- `:help nvim_create_namespace()`
- `:help nvim_set_hl()`
- `:help nvim_buf_clear_namespace()`
- `:help nvim_buf_get_extmarks()`

## Real-World Example

This skill was created based on implementing line mapping highlights in vim-godbolt, which required:
- Static multi-colored highlights showing all source-to-IR mappings
- Dynamic cursor highlights following user's cursor in both buffers
- Proper namespace isolation to avoid conflicts
- Theme-aware color selection for light/dark backgrounds

See `lua/godbolt/highlight.lua` and `lua/godbolt/line_map.lua` for the complete implementation.

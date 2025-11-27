local M = {}

-- Two separate namespaces for different highlighting purposes
M.ns_static = vim.api.nvim_create_namespace('godbolt_static')
M.ns_cursor = vim.api.nvim_create_namespace('godbolt_cursor')

-- Setup highlight groups with hex color backgrounds
function M.setup()
  -- Detect background to use appropriate colors
  local bg = vim.o.background

  if bg == "dark" then
    -- Lighter grays for dark backgrounds (more visible)
    -- These are full-line background colors
    vim.api.nvim_set_hl(0, "GodboltLevel1", {bg = "#404040"})
    vim.api.nvim_set_hl(0, "GodboltLevel2", {bg = "#383838"})
    vim.api.nvim_set_hl(0, "GodboltLevel3", {bg = "#303030"})
    vim.api.nvim_set_hl(0, "GodboltLevel4", {bg = "#282828"})
    vim.api.nvim_set_hl(0, "GodboltLevel5", {bg = "#242424"})
  else
    -- Darker grays for light backgrounds
    vim.api.nvim_set_hl(0, "GodboltLevel1", {bg = "#d0d0d0"})
    vim.api.nvim_set_hl(0, "GodboltLevel2", {bg = "#d8d8d8"})
    vim.api.nvim_set_hl(0, "GodboltLevel3", {bg = "#e0e0e0"})
    vim.api.nvim_set_hl(0, "GodboltLevel4", {bg = "#e8e8e8"})
    vim.api.nvim_set_hl(0, "GodboltLevel5", {bg = "#f0f0f0"})
  end

  -- Cursor highlight - link to Visual for visibility
  vim.api.nvim_set_hl(0, "GodboltCursor", {link = "Visual"})
end

-- Get shade name based on index (cycles through levels)
local function get_shade_for_index(index)
  local level = ((index - 1) % 5) + 1
  return "GodboltLevel" .. level
end

-- Apply static multi-colored highlights to mapped lines
-- This is called ONCE when the mapping is set up
-- @param bufnr: buffer number
-- @param lines: table of line numbers (1-indexed)
function M.highlight_lines_static(bufnr, lines)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  for i, line_num in ipairs(lines) do
    if line_num > 0 then
      local shade = get_shade_for_index(line_num)

      -- Use nvim_buf_add_highlight for full-line background
      -- Parameters: buffer, namespace, group, line (0-indexed), col_start, col_end
      -- col_end = -1 means highlight to end of line
      pcall(vim.api.nvim_buf_add_highlight,
        bufnr,
        M.ns_static,
        shade,
        line_num - 1,  -- Convert to 0-indexed
        0,             -- Start of line
        -1             -- End of line
      )
    end
  end
end

-- Apply cursor-following highlights
-- This is called on EVERY cursor movement
-- @param bufnr: buffer number
-- @param lines: table of line numbers (1-indexed)
function M.highlight_lines_cursor(bufnr, lines)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  for _, line_num in ipairs(lines) do
    if line_num > 0 then
      -- Use Visual-style highlighting for cursor
      pcall(vim.api.nvim_buf_add_highlight,
        bufnr,
        M.ns_cursor,
        "GodboltCursor",
        line_num - 1,  -- Convert to 0-indexed
        0,             -- Start of line
        -1             -- End of line
      )
    end
  end
end

-- Apply column-specific cursor highlight
-- Highlights a specific column/token instead of the whole line
-- @param bufnr: buffer number
-- @param line_num: line number (1-indexed)
-- @param col_num: column number (1-indexed)
-- @param width: optional width of highlight (default: 10 characters)
function M.highlight_column_cursor(bufnr, line_num, col_num, width)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if not line_num or line_num < 1 or not col_num or col_num < 1 then
    -- Fall back to line highlighting if invalid
    M.highlight_lines_cursor(bufnr, {line_num})
    return
  end

  width = width or 1  -- Highlight just the starting character by default

  -- Highlight the column range
  -- NOTE: nvim_buf_add_highlight uses 0-indexed positions with EXCLUSIVE end
  -- To highlight N characters starting at 1-indexed column C:
  --   col_start = C - 1 (convert to 0-indexed)
  --   col_end = C - 1 + N (exclusive, so highlights N characters)
  pcall(vim.api.nvim_buf_add_highlight,
    bufnr,
    M.ns_cursor,
    "GodboltCursor",
    line_num - 1,       -- Convert to 0-indexed
    col_num - 1,        -- Convert to 0-indexed start position
    math.min(col_num - 1 + width, 9999) -- End position (exclusive), clamped
  )
end

-- Get list of already highlighted lines in a buffer/namespace
-- Used to avoid duplicate highlighting
-- @param bufnr: buffer number
-- @param namespace: namespace ID
-- @return: table of line numbers (0-indexed)
function M.get_highlighted_lines(bufnr, namespace)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, {
    type = "highlight",
    details = false,
  })

  local lines = {}
  for _, mark in ipairs(extmarks) do
    local line = mark[2]  -- Second element is line number
    table.insert(lines, line)
  end

  return lines
end

-- Clear all highlights in a buffer for a specific namespace
-- @param bufnr: buffer number
-- @param namespace: namespace ID to clear
function M.clear_namespace(bufnr, namespace)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
end

-- Clear all highlights in a buffer (both namespaces)
-- @param bufnr: buffer number
function M.clear_all_highlights(bufnr)
  M.clear_namespace(bufnr, M.ns_static)
  M.clear_namespace(bufnr, M.ns_cursor)
end

return M

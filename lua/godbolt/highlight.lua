local M = {}

-- Namespace for highlights
M.ns_id = vim.api.nvim_create_namespace('godbolt_line_map')

-- Setup highlight groups with shaded grays
function M.setup()
  -- Define multiple shades for better visualization
  vim.cmd([[
    highlight GodboltLevel1 guibg=#3a3a3a ctermbg=237
    highlight GodboltLevel2 guibg=#2f2f2f ctermbg=236
    highlight GodboltLevel3 guibg=#262626 ctermbg=235
    highlight GodboltLevel4 guibg=#1f1f1f ctermbg=234
    highlight GodboltLevel5 guibg=#1a1a1a ctermbg=233

    " Fallback for single-line highlighting
    highlight default link GodboltSourceHighlight CursorLine
    highlight default link GodboltOutputHighlight GodboltLevel1
  ]])
end

-- Get shade name based on index (cycles through levels)
local function get_shade_for_index(index, total)
  if total == 1 then
    return "GodboltLevel1"
  end

  -- Distribute shades across all lines
  local level = math.min(5, math.ceil((index / total) * 5))
  return "GodboltLevel" .. level
end

-- Highlight multiple lines in a buffer with shaded grays
-- @param bufnr: buffer number
-- @param lines: table of line numbers (1-indexed)
-- @param hl_group: highlight group name (optional, will use shades if nil)
function M.highlight_lines(bufnr, lines, hl_group)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    print(string.format("[Highlight] Invalid buffer: %s", tostring(bufnr)))
    return
  end

  print(string.format("[Highlight] Highlighting %d lines in buf %d", #lines, bufnr))

  for i, line_num in ipairs(lines) do
    if line_num > 0 then
      -- Use shaded highlighting if no specific hl_group provided
      local shade = hl_group or get_shade_for_index(i, #lines)

      -- Use extmarks for highlighting (0-indexed line numbers)
      local ok, err = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_id, line_num - 1, 0, {
        end_line = line_num,
        hl_group = shade,
        priority = 100,
      })

      if not ok then
        print(string.format("[Highlight] Failed to set extmark at line %d: %s", line_num, err))
        break
      else
        print(string.format("[Highlight] Set extmark at line %d with %s", line_num, shade))
      end
    end
  end
end

-- Clear all highlights in a buffer
-- @param bufnr: buffer number
function M.clear_highlights(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_id, 0, -1)
end

-- Clear highlights in a specific range
-- @param bufnr: buffer number
-- @param start_line: start line (0-indexed)
-- @param end_line: end line (0-indexed)
function M.clear_highlights_range(bufnr, start_line, end_line)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_id, start_line, end_line)
end

return M

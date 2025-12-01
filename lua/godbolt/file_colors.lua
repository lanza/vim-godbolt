local M = {}

-- Define highlight groups for different source files
-- We'll use a rotating set of colors for up to 8 different files
local FILE_COLORS = {
  "GodboltFile1",
  "GodboltFile2",
  "GodboltFile3",
  "GodboltFile4",
  "GodboltFile5",
  "GodboltFile6",
  "GodboltFile7",
  "GodboltFile8",
}

-- Initialize highlight groups
function M.setup_highlights()
  -- Define color palette for source files
  -- Using distinct but readable colors
  vim.api.nvim_set_hl(0, "GodboltFile1", { fg = "#61AFEF", bold = true }) -- Blue
  vim.api.nvim_set_hl(0, "GodboltFile2", { fg = "#98C379", bold = true }) -- Green
  vim.api.nvim_set_hl(0, "GodboltFile3", { fg = "#E5C07B", bold = true }) -- Yellow
  vim.api.nvim_set_hl(0, "GodboltFile4", { fg = "#C678DD", bold = true }) -- Purple
  vim.api.nvim_set_hl(0, "GodboltFile5", { fg = "#E06C75", bold = true }) -- Red
  vim.api.nvim_set_hl(0, "GodboltFile6", { fg = "#56B6C2", bold = true }) -- Cyan
  vim.api.nvim_set_hl(0, "GodboltFile7", { fg = "#D19A66", bold = true }) -- Orange
  vim.api.nvim_set_hl(0, "GodboltFile8", { fg = "#ABB2BF", bold = true }) -- Gray
end

-- Assign colors to source files
-- @param filenames: array of unique source filenames
-- @return: table mapping filename to highlight group name
function M.assign_file_colors(filenames)
  local color_map = {}

  for i, filename in ipairs(filenames) do
    local color_index = ((i - 1) % #FILE_COLORS) + 1
    color_map[filename] = FILE_COLORS[color_index]
  end

  return color_map
end

-- Apply file-based coloring to IR buffer
-- @param bufnr: buffer number
-- @param ir_lines: array of IR lines
-- @param func_sources: table mapping function names to {filename, directory}
function M.colorize_by_source_file(bufnr, ir_lines, func_sources)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Extract unique filenames
  local filenames = {}
  local filename_set = {}
  for _, info in pairs(func_sources) do
    if info.filename and not filename_set[info.filename] then
      table.insert(filenames, info.filename)
      filename_set[info.filename] = true
    end
  end

  -- Assign colors
  local color_map = M.assign_file_colors(filenames)

  -- Create namespace for file coloring
  local ns_id = vim.api.nvim_create_namespace('godbolt_file_colors')

  -- Clear existing highlights
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  -- Track current function for coloring
  local current_func = nil
  local current_color = nil

  for line_num, line in ipairs(ir_lines) do
    -- Detect function definition
    local func_name = line:match('^define%s+[^@]*@([^%(]+)%(')
    if func_name then
      current_func = func_name
      if func_sources[func_name] and func_sources[func_name].filename then
        current_color = color_map[func_sources[func_name].filename]
      else
        current_color = nil
      end
    end

    -- Apply coloring to function definition and body
    if current_color then
      -- Highlight the entire line
      pcall(vim.api.nvim_buf_add_highlight, bufnr, ns_id, current_color, line_num - 1, 0, -1)
    end

    -- Detect end of function (closing brace at start of line)
    if line:match('^}%s*$') then
      current_func = nil
      current_color = nil
    end
  end

  -- Return color legend for display
  return color_map
end

-- Create a legend string showing file-to-color mapping
-- @param color_map: table from assign_file_colors
-- @return: array of strings for legend display
function M.create_color_legend(color_map)
  local lines = {}

  table.insert(lines, "Source Files:")
  for filename, hl_group in pairs(color_map) do
    table.insert(lines, string.format("  %s", filename))
  end

  return lines
end

return M

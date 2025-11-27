local M = {}

local highlight = require('godbolt.highlight')
local assembly_parser = require('godbolt.parsers.assembly')
local llvm_ir_parser = require('godbolt.parsers.llvm_ir')

-- State for current mapping
local state = {
  source_bufnr = nil,
  output_bufnr = nil,
  src_to_out = nil,
  out_to_src = nil,
  output_type = nil,
  autocmd_ids = {},
}

-- Throttle function to prevent excessive updates
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

-- Apply static multi-colored highlights to all mapped lines
-- This is called ONCE when the mapping is set up
local function apply_static_highlights()
  if not state.source_bufnr or not state.output_bufnr then
    return
  end

  if not vim.api.nvim_buf_is_valid(state.source_bufnr) or
     not vim.api.nvim_buf_is_valid(state.output_bufnr) then
    return
  end

  -- Get already highlighted source lines to avoid duplicates
  local highlighted_source_lines = highlight.get_highlighted_lines(state.source_bufnr, highlight.ns_static)

  -- Iterate through all source → output mappings
  for src_line, out_lines in pairs(state.src_to_out) do
    -- Highlight source line if not already highlighted
    local is_highlighted = false
    for _, hl_line in ipairs(highlighted_source_lines) do
      if hl_line == (src_line - 1) then  -- Compare with 0-indexed line
        is_highlighted = true
        break
      end
    end

    if not is_highlighted then
      highlight.highlight_lines_static(state.source_bufnr, {src_line})
      table.insert(highlighted_source_lines, src_line - 1)
    end

    -- Highlight all corresponding output lines
    highlight.highlight_lines_static(state.output_bufnr, out_lines)
  end
end

-- Update cursor highlights when cursor moves in source buffer
local function update_source_highlights(config)
  if not state.source_bufnr or not state.output_bufnr then
    return
  end

  if not vim.api.nvim_buf_is_valid(state.source_bufnr) or
     not vim.api.nvim_buf_is_valid(state.output_bufnr) then
    return
  end

  -- Get current cursor line
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  -- Clear previous cursor highlights in BOTH buffers
  highlight.clear_namespace(state.source_bufnr, highlight.ns_cursor)
  highlight.clear_namespace(state.output_bufnr, highlight.ns_cursor)

  -- Get mapped output lines
  local mapped_lines = state.src_to_out and state.src_to_out[cursor_line] or {}

  if #mapped_lines > 0 then
    -- Highlight current source line with cursor style
    highlight.highlight_lines_cursor(state.source_bufnr, {cursor_line})

    -- Highlight mapped lines in output buffer with cursor style
    highlight.highlight_lines_cursor(state.output_bufnr, mapped_lines)

    -- Optional: Auto-scroll to first mapped line
    if config.auto_scroll then
      local first_line = mapped_lines[1]
      -- Find window showing output buffer
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == state.output_bufnr then
          vim.api.nvim_win_call(win, function()
            -- Check if line is visible in window
            local win_info = vim.fn.getwininfo(win)[1]
            if win_info then
              local top_line = win_info.topline
              local bot_line = win_info.botline

              -- Only scroll if line is off-screen
              if first_line < top_line or first_line > bot_line then
                vim.fn.cursor(first_line, 1)
                vim.cmd('normal! zz')  -- Center line
              end
            end
          end)
          break
        end
      end
    end
  end
end

-- Update cursor highlights when cursor moves in output buffer (reverse mapping)
local function update_output_highlights(config)
  if not state.source_bufnr or not state.output_bufnr then
    return
  end

  if not vim.api.nvim_buf_is_valid(state.source_bufnr) or
     not vim.api.nvim_buf_is_valid(state.output_bufnr) then
    return
  end

  -- Get current cursor line
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]

  -- Clear previous cursor highlights in BOTH buffers
  highlight.clear_namespace(state.source_bufnr, highlight.ns_cursor)
  highlight.clear_namespace(state.output_bufnr, highlight.ns_cursor)

  -- Get mapped source line and column
  local mapped_info = state.out_to_src and state.out_to_src[cursor_line]

  if mapped_info then
    -- Handle both old format (number) and new format (table with line/column)
    local mapped_src_line, mapped_src_col
    if type(mapped_info) == "table" then
      mapped_src_line = mapped_info.line
      mapped_src_col = mapped_info.column
    else
      mapped_src_line = mapped_info
      mapped_src_col = nil
    end

    -- Highlight current output line with cursor style
    highlight.highlight_lines_cursor(state.output_bufnr, {cursor_line})

    -- Highlight mapped source line with cursor style
    -- If we have column info, highlight that specific column/token
    if mapped_src_col then
      highlight.highlight_column_cursor(state.source_bufnr, mapped_src_line, mapped_src_col)
    else
      highlight.highlight_lines_cursor(state.source_bufnr, {mapped_src_line})
    end

    -- Optional: Auto-scroll to mapped source line
    if config.auto_scroll then
      -- Find window showing source buffer
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == state.source_bufnr then
          vim.api.nvim_win_call(win, function()
            -- Check if line is visible in window
            local win_info = vim.fn.getwininfo(win)[1]
            if win_info then
              local top_line = win_info.topline
              local bot_line = win_info.botline

              -- Only scroll if line is off-screen
              if mapped_src_line < top_line or mapped_src_line > bot_line then
                vim.fn.cursor(mapped_src_line, 1)
                vim.cmd('normal! zz')  -- Center line
              end
            end
          end)
          break
        end
      end
    end
  end
end

-- Clean up autocmds and state
function M.cleanup()
  -- Clear all highlights
  if state.source_bufnr and vim.api.nvim_buf_is_valid(state.source_bufnr) then
    highlight.clear_all_highlights(state.source_bufnr)
  end
  if state.output_bufnr and vim.api.nvim_buf_is_valid(state.output_bufnr) then
    highlight.clear_all_highlights(state.output_bufnr)
  end

  -- Remove autocmds
  for _, id in ipairs(state.autocmd_ids) do
    pcall(vim.api.nvim_del_autocmd, id)
  end

  -- Reset state
  state = {
    source_bufnr = nil,
    output_bufnr = nil,
    src_to_out = nil,
    out_to_src = nil,
    output_type = nil,
    autocmd_ids = {},
  }
end

-- Setup line mapping between source and output buffers
-- @param source_bufnr: source buffer number
-- @param output_bufnr: output buffer number (assembly/IR)
-- @param output_type: "asm" or "llvm"
-- @param config: configuration table
function M.setup(source_bufnr, output_bufnr, output_type, config)
  config = config or {}

  -- Default config
  local default_config = {
    enabled = true,
    auto_scroll = false,
    throttle_ms = 150,
  }
  config = vim.tbl_deep_extend("force", default_config, config)

  if not config.enabled then
    return
  end

  -- Setup highlight groups
  highlight.setup()

  -- Clean up previous mapping if exists
  M.cleanup()

  -- Store state
  state.source_bufnr = source_bufnr
  state.output_bufnr = output_bufnr
  state.output_type = output_type

  -- Get output buffer lines
  -- Use full unfiltered output if available (for debug metadata parsing),
  -- otherwise fallback to displayed lines
  local output_lines = vim.b[output_bufnr].godbolt_full_output or
                       vim.api.nvim_buf_get_lines(output_bufnr, 0, -1, false)

  -- Parse based on output type
  if output_type == "asm" then
    state.src_to_out, state.out_to_src = assembly_parser.parse(output_lines)
  elseif output_type == "llvm" then
    state.src_to_out, state.out_to_src = llvm_ir_parser.parse(output_lines)
  else
    -- Unknown output type, skip mapping
    return
  end

  -- Check if we found any mappings
  if not state.src_to_out or vim.tbl_count(state.src_to_out) == 0 then
    print("[Line Mapping] No line mappings found in output.")
    print("[Line Mapping] This is expected - the plugin handles debug info generation automatically.")
    print("[Line Mapping] If this persists, check :messages for diagnostic information.")
    return
  end

  -- Apply static multi-colored highlights to all mapped lines (ONCE)
  apply_static_highlights()

  -- Create throttled update functions for cursor movement
  local throttled_source_update = throttle(function()
    update_source_highlights(config)
  end, config.throttle_ms)

  local throttled_output_update = throttle(function()
    update_output_highlights(config)
  end, config.throttle_ms)

  -- Set up cursor tracking for source buffer
  local source_autocmd = vim.api.nvim_create_autocmd({'CursorMoved', 'CursorMovedI'}, {
    buffer = source_bufnr,
    callback = function()
      throttled_source_update()
    end,
    desc = 'Godbolt line mapping: source → output'
  })
  table.insert(state.autocmd_ids, source_autocmd)

  -- Set up cursor tracking for output buffer (bidirectional)
  local output_autocmd = vim.api.nvim_create_autocmd({'CursorMoved', 'CursorMovedI'}, {
    buffer = output_bufnr,
    callback = function()
      throttled_output_update()
    end,
    desc = 'Godbolt line mapping: output → source'
  })
  table.insert(state.autocmd_ids, output_autocmd)

  -- Clean up when buffers are deleted
  local cleanup_autocmd = vim.api.nvim_create_autocmd('BufDelete', {
    buffer = output_bufnr,
    callback = function()
      M.cleanup()
    end,
    desc = 'Godbolt line mapping: cleanup on buffer delete'
  })
  table.insert(state.autocmd_ids, cleanup_autocmd)

  -- Refresh highlights when colorscheme changes
  local colorscheme_autocmd = vim.api.nvim_create_autocmd('ColorScheme', {
    callback = function()
      highlight.setup()
      -- Reapply all highlights
      apply_static_highlights()
      update_source_highlights(config)
    end,
    desc = 'Godbolt line mapping: refresh highlights on colorscheme change'
  })
  table.insert(state.autocmd_ids, colorscheme_autocmd)

  -- Initial cursor highlight based on current cursor position
  update_source_highlights(config)
end

return M

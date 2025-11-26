local M = {}

local stats = require('godbolt.stats')

-- State for pipeline viewer
M.state = {
  passes = {},
  current_index = 1,
  source_bufnr = nil,
  pass_list_bufnr = nil,
  before_bufnr = nil,
  after_bufnr = nil,
  pass_list_winid = nil,
  before_winid = nil,
  after_winid = nil,
  config = nil,
  ns_id = vim.api.nvim_create_namespace('godbolt_pipeline'),
}

-- Setup pipeline viewer with 3-pane layout
-- @param source_bufnr: source buffer number
-- @param passes: array of {name, ir} from pipeline.parse_pipeline_output
-- @param config: configuration table
function M.setup(source_bufnr, passes, config)
  config = config or {}

  -- Default config
  local default_config = {
    show_stats = true,
    start_at_final = false,  -- Start at first pass to see initial changes
    filter_unchanged = false,
  }
  config = vim.tbl_deep_extend("force", default_config, config)

  -- Filter passes if requested
  if config.filter_unchanged then
    local pipeline = require('godbolt.pipeline')
    passes = pipeline.filter_changed_passes(passes)
    print(string.format("[Pipeline] Filtered to %d passes that changed IR", #passes))
  end

  -- Calculate statistics for each pass
  for i, pass in ipairs(passes) do
    pass.stats = stats.count(pass.ir)
  end

  -- Store state
  M.state.passes = passes
  M.state.source_bufnr = source_bufnr
  M.state.config = config

  -- Start at first pass
  M.state.current_index = config.start_at_final and #passes or 1

  -- Create 3-pane layout
  M.create_layout()

  -- Populate pass list
  M.populate_pass_list()

  -- Show initial diff
  M.show_diff(M.state.current_index)

  -- Set up key mappings
  M.setup_keymaps()
end

-- Create 3-pane layout: pass list | before | after
function M.create_layout()
  -- Create pass list buffer (left pane)
  M.state.pass_list_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'bufhidden', 'hide')
  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'swapfile', false)
  vim.api.nvim_buf_set_name(M.state.pass_list_bufnr, 'Pipeline Passes')

  -- Create before buffer (center pane)
  M.state.before_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.state.before_bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(M.state.before_bufnr, 'bufhidden', 'hide')
  vim.api.nvim_buf_set_option(M.state.before_bufnr, 'swapfile', false)
  vim.api.nvim_buf_set_option(M.state.before_bufnr, 'filetype', 'llvm')

  -- Create after buffer (right pane)
  M.state.after_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.state.after_bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(M.state.after_bufnr, 'bufhidden', 'hide')
  vim.api.nvim_buf_set_option(M.state.after_bufnr, 'swapfile', false)
  vim.api.nvim_buf_set_option(M.state.after_bufnr, 'filetype', 'llvm')

  -- Create window layout: vertical splits
  -- Start with full window, split into 3 parts

  -- Create pass list window (left, 30 columns wide)
  vim.cmd('topleft vertical 30 new')
  M.state.pass_list_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.state.pass_list_winid, M.state.pass_list_bufnr)
  vim.api.nvim_win_set_option(M.state.pass_list_winid, 'number', false)
  vim.api.nvim_win_set_option(M.state.pass_list_winid, 'relativenumber', false)
  vim.api.nvim_win_set_option(M.state.pass_list_winid, 'cursorline', true)

  -- Create before window (center pane)
  vim.cmd('vertical rightbelow new')
  M.state.before_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.state.before_winid, M.state.before_bufnr)
  vim.api.nvim_win_set_option(M.state.before_winid, 'number', false)

  -- Create after window (right pane)
  vim.cmd('vertical rightbelow new')
  M.state.after_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.state.after_winid, M.state.after_bufnr)
  vim.api.nvim_win_set_option(M.state.after_winid, 'number', false)

  -- Make window sizes equal for before/after
  vim.cmd('wincmd =')

  -- Go back to pass list window
  vim.api.nvim_set_current_win(M.state.pass_list_winid)
end

-- Populate pass list buffer with tree-style formatting
function M.populate_pass_list()
  local lines = {}
  local header = string.format("Optimization Pipeline (%d passes)", #M.state.passes)
  table.insert(lines, header)
  table.insert(lines, string.rep("─", #header))
  table.insert(lines, "")

  for i, pass in ipairs(M.state.passes) do
    local marker = (i == M.state.current_index) and "▶" or " "
    local name = pass.name

    -- Truncate long pass names
    if #name > 25 then
      name = string.sub(name, 1, 22) .. "..."
    end

    local line = string.format("%s %2d. %s", marker, i, name)
    table.insert(lines, line)

    -- Show stats as sub-item if configured
    if M.state.config.show_stats and i > 1 then
      local prev_stats = M.state.passes[i - 1].stats
      local delta = stats.delta(prev_stats, pass.stats)

      -- Only show if there were changes
      if delta.instructions ~= 0 or delta.basic_blocks ~= 0 then
        local stats_line = string.format("     Δ: Insts %+d, BBs %+d",
          delta.instructions, delta.basic_blocks)
        table.insert(lines, stats_line)
      end
    end
  end

  table.insert(lines, "")
  table.insert(lines, "Keys: j/k=nav, Enter=select, q=quit")

  vim.api.nvim_buf_set_lines(M.state.pass_list_bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'modifiable', false)
end

-- Show diff between pass N-1 and pass N
-- @param index: pass index (1-based)
function M.show_diff(index)
  if #M.state.passes == 0 then
    return
  end

  -- Clamp index
  index = math.max(1, math.min(index, #M.state.passes))
  M.state.current_index = index

  local pass = M.state.passes[index]

  -- Get before IR (previous pass, or empty if first)
  local before_ir = {}
  if index == 1 then
    -- First pass - show empty or could show original IR
    before_ir = {"", "[ Initial State - No Previous Pass ]", ""}
  else
    before_ir = M.state.passes[index - 1].ir
  end

  -- Get after IR (current pass)
  local after_ir = pass.ir

  -- Update buffers
  vim.api.nvim_buf_set_option(M.state.before_bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(M.state.before_bufnr, 0, -1, false, before_ir)
  vim.api.nvim_buf_set_option(M.state.before_bufnr, 'modifiable', false)

  vim.api.nvim_buf_set_option(M.state.after_bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(M.state.after_bufnr, 0, -1, false, after_ir)
  vim.api.nvim_buf_set_option(M.state.after_bufnr, 'modifiable', false)

  -- Update buffer names
  local before_name = index == 1 and "Initial" or M.state.passes[index - 1].name
  local after_name = pass.name

  pcall(vim.api.nvim_buf_set_name, M.state.before_bufnr,
    string.format("Before: %s", before_name))
  pcall(vim.api.nvim_buf_set_name, M.state.after_bufnr,
    string.format("After: %s", after_name))

  -- Enable diff mode
  vim.api.nvim_win_call(M.state.before_winid, function()
    vim.cmd('diffthis')
  end)
  vim.api.nvim_win_call(M.state.after_winid, function()
    vim.cmd('diffthis')
  end)

  -- Update pass list highlighting
  M.update_pass_list_cursor(index)

  -- Print stats
  if M.state.config.show_stats then
    M.show_stats(index)
  end
end

-- Update the cursor marker in pass list
function M.update_pass_list_cursor(index)
  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'modifiable', true)

  local lines = vim.api.nvim_buf_get_lines(M.state.pass_list_bufnr, 0, -1, false)

  for i, line in ipairs(lines) do
    -- Remove old markers
    if line:match("^▶") then
      lines[i] = " " .. line:sub(3)
    end

    -- Add new marker (line number = header(3) + pass index)
    local pass_line_num = 3 + (index - 1)
    if M.state.config.show_stats and index > 1 then
      -- Account for stats lines (each pass after first has an extra line)
      pass_line_num = pass_line_num + (index - 1)
    end

    if i == pass_line_num then
      lines[i] = "▶" .. line:sub(2)
    end
  end

  vim.api.nvim_buf_set_lines(M.state.pass_list_bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'modifiable', false)

  -- Move cursor to the marked line in pass list
  local cursor_line = 3 + (index - 1)
  if M.state.config.show_stats and index > 1 then
    cursor_line = cursor_line + (index - 1)
  end

  vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {cursor_line + 1, 0})
end

-- Show statistics for current pass
function M.show_stats(index)
  local pass = M.state.passes[index]

  if index == 1 then
    print(string.format("[Pass %d/%d] %s | %s",
      index, #M.state.passes, pass.name, stats.format_compact(pass.stats)))
  else
    local prev_stats = M.state.passes[index - 1].stats
    local delta = stats.delta(prev_stats, pass.stats)
    print(string.format("[Pass %d/%d] %s | %s",
      index, #M.state.passes, pass.name,
      stats.format_with_delta(pass.stats, delta)))
  end
end

-- Navigate to next pass
function M.next_pass()
  M.show_diff(M.state.current_index + 1)
end

-- Navigate to previous pass
function M.prev_pass()
  M.show_diff(M.state.current_index - 1)
end

-- Navigate to first pass
function M.first_pass()
  M.show_diff(1)
end

-- Navigate to last pass
function M.last_pass()
  M.show_diff(#M.state.passes)
end

-- Select pass under cursor in pass list
function M.select_pass_under_cursor()
  local cursor = vim.api.nvim_win_get_cursor(M.state.pass_list_winid)
  local line_num = cursor[1]

  -- Parse line to get pass index
  local line = vim.api.nvim_buf_get_lines(M.state.pass_list_bufnr, line_num - 1, line_num, false)[1]
  if not line then
    return
  end

  -- Match pattern like "▶  1. PassName" or "   1. PassName"
  local pass_index = line:match("^.%s*(%d+)%.")
  if pass_index then
    M.show_diff(tonumber(pass_index))
  end
end

-- Setup key mappings
function M.setup_keymaps()
  if not vim.api.nvim_buf_is_valid(M.state.pass_list_bufnr) then
    return
  end

  local bufnr = M.state.pass_list_bufnr

  -- Navigation in pass list
  vim.keymap.set('n', 'j', function()
    vim.cmd('normal! j')
    M.select_pass_under_cursor()
  end, {
    buffer = bufnr,
    desc = 'Next pass'
  })

  vim.keymap.set('n', 'k', function()
    vim.cmd('normal! k')
    M.select_pass_under_cursor()
  end, {
    buffer = bufnr,
    desc = 'Previous pass'
  })

  vim.keymap.set('n', '<Down>', function()
    vim.cmd('normal! j')
    M.select_pass_under_cursor()
  end, {
    buffer = bufnr,
    desc = 'Next pass'
  })

  vim.keymap.set('n', '<Up>', function()
    vim.cmd('normal! k')
    M.select_pass_under_cursor()
  end, {
    buffer = bufnr,
    desc = 'Previous pass'
  })

  vim.keymap.set('n', '<CR>', function()
    M.select_pass_under_cursor()
  end, {
    buffer = bufnr,
    desc = 'Select pass'
  })

  vim.keymap.set('n', 'q', function()
    M.cleanup()
    vim.cmd('quit')
  end, {
    buffer = bufnr,
    desc = 'Quit pipeline viewer'
  })

  vim.keymap.set('n', 'g[', function() M.first_pass() end, {
    buffer = bufnr,
    desc = 'First pass'
  })

  vim.keymap.set('n', 'g]', function() M.last_pass() end, {
    buffer = bufnr,
    desc = 'Last pass'
  })

  -- Also add commands that work from any window
  vim.keymap.set('n', ']p', function() M.next_pass() end, {
    buffer = M.state.before_bufnr,
    desc = 'Next pass'
  })

  vim.keymap.set('n', '[p', function() M.prev_pass() end, {
    buffer = M.state.before_bufnr,
    desc = 'Previous pass'
  })

  vim.keymap.set('n', ']p', function() M.next_pass() end, {
    buffer = M.state.after_bufnr,
    desc = 'Next pass'
  })

  vim.keymap.set('n', '[p', function() M.prev_pass() end, {
    buffer = M.state.after_bufnr,
    desc = 'Previous pass'
  })
end

-- Cleanup viewer state
function M.cleanup()
  -- Disable diff mode
  if M.state.before_winid and vim.api.nvim_win_is_valid(M.state.before_winid) then
    vim.api.nvim_win_call(M.state.before_winid, function()
      pcall(vim.cmd, 'diffoff')
    end)
  end

  if M.state.after_winid and vim.api.nvim_win_is_valid(M.state.after_winid) then
    vim.api.nvim_win_call(M.state.after_winid, function()
      pcall(vim.cmd, 'diffoff')
    end)
  end

  M.state = {
    passes = {},
    current_index = 1,
    source_bufnr = nil,
    pass_list_bufnr = nil,
    before_bufnr = nil,
    after_bufnr = nil,
    pass_list_winid = nil,
    before_winid = nil,
    after_winid = nil,
    config = nil,
    ns_id = M.state.ns_id,  -- Keep namespace
  }
end

return M

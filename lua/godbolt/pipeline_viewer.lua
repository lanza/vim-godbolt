local M = {}

local stats = require('godbolt.stats')
local ir_utils = require('godbolt.ir_utils')
local pipeline = require('godbolt.pipeline')

-- State for pipeline viewer
M.state = {
  passes = {},
  current_index = 1,
  source_bufnr = nil,
  input_file = nil,  -- Path to input .ll file
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
-- @param input_file: path to input .ll file
-- @param passes: array of {name, ir} from pipeline.parse_pipeline_output
-- @param config: configuration table
function M.setup(source_bufnr, input_file, passes, config)
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
  M.state.input_file = input_file
  M.state.config = config

  -- Pre-compute which passes actually changed IR
  -- This allows us to gray out no-op passes in the list
  M.compute_pass_changes()

  -- Start at first/last changed pass
  if config.start_at_final then
    -- Find last changed pass
    M.state.current_index = #passes
    for i = #passes, 1, -1 do
      if passes[i].changed then
        M.state.current_index = i
        break
      end
    end
  else
    -- Find first changed pass
    M.state.current_index = 1
    for i = 1, #passes do
      if passes[i].changed then
        M.state.current_index = i
        break
      end
    end
  end

  -- Create 3-pane layout
  M.create_layout()

  -- Populate pass list
  M.populate_pass_list()

  -- Show initial diff
  M.show_diff(M.state.current_index)

  -- Set up key mappings
  M.setup_keymaps()

  -- Position cursor on first pass entry (header + separator + blank + first pass = line 4)
  vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {4, 0})
end

-- Create 3-pane layout: pass list | before | after
function M.create_layout()
  -- Create new tab for pipeline viewer
  vim.cmd('tabnew')

  -- Create unique buffer names using timestamp
  local timestamp = os.time()

  -- Create pass list buffer (left pane)
  M.state.pass_list_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'swapfile', false)
  pcall(vim.api.nvim_buf_set_name, M.state.pass_list_bufnr,
    string.format('Pipeline Passes [%d]', timestamp))

  -- Create before buffer (center pane)
  M.state.before_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.state.before_bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(M.state.before_bufnr, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(M.state.before_bufnr, 'swapfile', false)
  vim.api.nvim_buf_set_option(M.state.before_bufnr, 'filetype', 'llvm')

  -- Create after buffer (right pane)
  M.state.after_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.state.after_bufnr, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(M.state.after_bufnr, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(M.state.after_bufnr, 'swapfile', false)
  vim.api.nvim_buf_set_option(M.state.after_bufnr, 'filetype', 'llvm')

  -- Set the current window to show pass list buffer
  M.state.pass_list_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.state.pass_list_winid, M.state.pass_list_bufnr)

  -- Calculate pass list width as 12% of total width (min 20, max 40 columns)
  local total_width = vim.o.columns
  local pass_list_width = math.floor(total_width * 0.12)
  pass_list_width = math.max(20, math.min(40, pass_list_width))

  vim.api.nvim_win_set_option(M.state.pass_list_winid, 'winfixwidth', true)
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

  vim.cmd(string.format('vertical resize %d', 38))
end

-- Populate pass list buffer with tree-style formatting
function M.populate_pass_list()
  local lines = {}
  local header = string.format("Optimization Pipeline (%d passes)", #M.state.passes)
  table.insert(lines, header)
  table.insert(lines, string.rep("-", #header))
  table.insert(lines, "")

  for i, pass in ipairs(M.state.passes) do
    local marker = (i == M.state.current_index) and ">" or " "
    local name = pass.name

    -- Add scope indicator
    local scope_icon = ""
    if pass.scope_type == "module" then
      scope_icon = "[M] "  -- Module pass
    elseif pass.scope_type == "cgscc" then
      scope_icon = "[C] "  -- CGSCC pass
    elseif pass.scope_type == "function" then
      scope_icon = "[F] "  -- Function pass
    else
      scope_icon = "[?] "  -- Unknown scope
    end

    local line = string.format("%s%2d. %s%s", marker, i, scope_icon, name)
    table.insert(lines, line)

    -- Show stats as sub-item if configured
    -- Stats delta should compare like-for-like scopes to match what the diff shows
    if M.state.config.show_stats and i > 1 then
      local prev_stats = nil

      if pass.scope_type == "module" then
        -- For module passes, find previous module pass (same logic as show_diff)
        for j = i - 1, 1, -1 do
          if M.state.passes[j].scope_type == "module" then
            prev_stats = M.state.passes[j].stats
            break
          end
        end
      else
        -- For function/CGSCC passes, only compare to previous pass if same target
        local prev_pass = M.state.passes[i - 1]
        if prev_pass.scope_type ~= "module" and prev_pass.scope_target == pass.scope_target then
          prev_stats = prev_pass.stats
        end
      end

      -- Only show stats if we have a valid comparison
      if prev_stats then
        local delta = stats.delta(prev_stats, pass.stats)

        -- Build stats line with inst/BB deltas and diff line count
        local stats_parts = {}

        -- Instruction delta
        if delta.instructions ~= 0 then
          table.insert(stats_parts, string.format("Insts %+d", delta.instructions))
        end

        -- Basic block delta
        if delta.basic_blocks ~= 0 then
          table.insert(stats_parts, string.format("BBs %+d", delta.basic_blocks))
        end

        -- Diff line count (always show if pass changed anything)
        if pass.changed and pass.diff_stats.lines_changed > 0 then
          table.insert(stats_parts, string.format("Δ%d lines", pass.diff_stats.lines_changed))
        end

        -- Only show stats line if there's something to show
        if #stats_parts > 0 then
          local stats_line = "     D: " .. table.concat(stats_parts, ", ")
          table.insert(lines, stats_line)
        end
      elseif pass.changed and pass.diff_stats.lines_changed > 0 then
        -- No prev_stats, but pass changed - show just diff count
        local stats_line = string.format("     D: Δ%d lines", pass.diff_stats.lines_changed)
        table.insert(lines, stats_line)
      end
    end
  end

  table.insert(lines, "")
  table.insert(lines, "Legend: [M]=Module [F]=Function [C]=CGSCC")
  table.insert(lines, "Keys: j/k/Tab/S-Tab=nav, Enter=select, q=quit")

  vim.api.nvim_buf_set_lines(M.state.pass_list_bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'modifiable', false)

  -- Apply syntax highlighting
  M.apply_pass_list_highlights()
end

-- Apply syntax highlighting to the pass list buffer
function M.apply_pass_list_highlights()
  local bufnr = M.state.pass_list_bufnr
  local ns_id = M.state.ns_id

  -- Clear previous highlights
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for line_idx, line in ipairs(lines) do
    local line_num = line_idx - 1  -- Convert to 0-indexed

    -- Line 1: Header - highlight as Title
    if line_idx == 1 then
      vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Title", line_num, 0, -1)

    -- Line 2: Separator - highlight as Comment
    elseif line_idx == 2 then
      vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Comment", line_num, 0, -1)

    -- Stats lines (start with spaces and "D:")
    elseif line:match("^%s+D:") then
      vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Comment", line_num, 0, -1)

    -- Legend and Keys lines at the end
    elseif line:match("^Legend:") or line:match("^Keys:") then
      vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Comment", line_num, 0, -1)

    -- Pass entry lines
    elseif line:match("^.%s*%d+%.") then
      -- Extract pass number to check if it changed
      local pass_num = tonumber(line:match("^.%s*(%d+)%."))
      local pass = pass_num and M.state.passes[pass_num]

      -- If pass didn't change, gray out entire line
      if pass and not pass.changed then
        vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Comment", line_num, 0, -1)
      else
        -- Normal highlighting for passes that changed
        local col = 0

        -- Highlight marker (> or space)
        local marker_end = 1
        if line:match("^>") then
          vim.api.nvim_buf_add_highlight(bufnr, ns_id, "WarningMsg", line_num, 0, marker_end)
        end
        col = marker_end

        -- Find and highlight pass number
        local num_start, num_end = line:find("%d+", col)
        if num_start then
          vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Number", line_num, num_start - 1, num_end)
          col = num_end
        end

        -- Find and highlight scope indicator [M], [F], [C]
        local scope_start, scope_end = line:find("%[%w%]", col)
        if scope_start then
          vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Type", line_num, scope_start - 1, scope_end)
          col = scope_end + 1  -- Skip space after scope
        end

        -- Highlight pass name (everything up to " on ")
        local on_start = line:find(" on ", col)
        if on_start then
          -- Pass name
          vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Identifier", line_num, col, on_start - 1)

          -- Highlight " on " as Special
          vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Special", line_num, on_start - 1, on_start + 3)

          -- Highlight target (everything after "on ")
          vim.api.nvim_buf_add_highlight(bufnr, ns_id, "String", line_num, on_start + 3, -1)
        else
          -- No " on " found, highlight rest as pass name
          vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Identifier", line_num, col, -1)
        end
      end
    end
  end
end

-- Extract function name from pass name
-- @param pass_name: e.g., "SROAPass on foo" or "InstCombinePass on bar"
-- @return: function name (e.g., "foo" or "bar") or nil
local function extract_function_name(pass_name)
  return pass_name:match(" on (.+)$")
end

-- Pre-compute which passes actually changed IR
-- Sets pass.changed (boolean) and pass.diff_stats (table) for each pass
function M.compute_pass_changes()
  local ir_utils = require('godbolt.ir_utils')
  local pipeline = require('godbolt.pipeline')

  for index, pass in ipairs(M.state.passes) do
    -- Get before IR using same logic as show_diff
    local before_ir = M.get_before_ir_for_pass(index)
    local after_ir = pass.ir

    -- Apply same filtering as display
    if M.state.config and M.state.config.display and M.state.config.display.strip_debug_metadata then
      before_ir = select(1, ir_utils.filter_debug_metadata(before_ir))
      after_ir = select(1, ir_utils.filter_debug_metadata(after_ir))
    end

    -- Compare IR and count differences
    local changed = false
    local lines_changed = 0
    local max_lines = math.max(#before_ir, #after_ir)

    if #before_ir ~= #after_ir then
      changed = true
      lines_changed = math.abs(#after_ir - #before_ir)
    end

    for i = 1, max_lines do
      local before_line = before_ir[i] or ""
      local after_line = after_ir[i] or ""
      if before_line ~= after_line then
        changed = true
        lines_changed = lines_changed + 1
      end
    end

    pass.changed = changed
    pass.diff_stats = {
      lines_changed = lines_changed,
      lines_before = #before_ir,
      lines_after = #after_ir,
    }
  end
end

-- Get before IR for a given pass index
-- Extracted from show_diff logic for reuse
-- @param index: pass index (1-based)
-- @return: IR lines array
function M.get_before_ir_for_pass(index)
  local ir_utils = require('godbolt.ir_utils')
  local pipeline = require('godbolt.pipeline')

  if index <= 1 then
    -- First pass: return empty or input
    if M.state.input_file then
      return pipeline.get_stripped_input(M.state.input_file) or {}
    else
      return {}
    end
  end

  local pass = M.state.passes[index]
  local scope_type = pass.scope_type
  local scope_target = pass.scope_target

  if scope_type == "module" then
    -- Module pass: get previous module pass
    for i = index - 1, 1, -1 do
      if M.state.passes[i].scope_type == "module" then
        return M.state.passes[i].ir
      end
    end

    -- No previous module pass, use input
    if M.state.input_file then
      return pipeline.get_stripped_input(M.state.input_file) or {}
    else
      return {}
    end

  else
    -- Function or CGSCC pass
    local func_name = scope_target
    local prev_pass = M.state.passes[index - 1]
    local prev_scope_type = prev_pass.scope_type
    local prev_func_name = prev_pass.scope_target

    if prev_scope_type ~= "module" and prev_func_name == func_name then
      -- Same function in previous pass
      return prev_pass.ir
    elseif prev_scope_type == "module" then
      -- Previous pass was module, extract function
      return ir_utils.extract_function(prev_pass.ir, func_name)
    else
      -- Different function, find last module pass
      for i = index - 1, 1, -1 do
        if M.state.passes[i].scope_type == "module" then
          return ir_utils.extract_function(M.state.passes[i].ir, func_name)
        end
      end

      -- No module pass found, try input
      if func_name and M.state.input_file then
        local input_ir = pipeline.get_stripped_input(M.state.input_file)
        return ir_utils.extract_function(input_ir, func_name)
      else
        return {}
      end
    end
  end
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
  local scope_type = pass.scope_type
  local scope_target = pass.scope_target

  -- Get before and after IR based on scope type
  local before_ir = {}
  local before_name = ""
  local after_ir = pass.ir

  if scope_type == "module" then
    -- Module pass: show full module before/after
    if index == 1 then
      -- First pass overall: get input module
      if M.state.input_file then
        before_ir = pipeline.get_stripped_input(M.state.input_file)
        before_name = "Input Module"
      else
        before_ir = {"", "[ No previous state ]", ""}
        before_name = "Initial"
      end
    else
      -- Find previous module pass
      local prev_module_idx = nil
      for i = index - 1, 1, -1 do
        if M.state.passes[i].scope_type == "module" then
          prev_module_idx = i
          break
        end
      end

      if prev_module_idx then
        -- Found previous module pass
        before_ir = M.state.passes[prev_module_idx].ir
        before_name = M.state.passes[prev_module_idx].name
      else
        -- No previous module pass, use input
        if M.state.input_file then
          before_ir = pipeline.get_stripped_input(M.state.input_file)
          before_name = "Input Module"
        else
          before_ir = {"", "[ No previous state ]", ""}
          before_name = "Initial"
        end
      end
    end

  else
    -- Function or CGSCC pass: show specific function
    local func_name = scope_target

    if index == 1 then
      -- First pass overall: get function from input
      if func_name and M.state.input_file then
        local input_ir = pipeline.get_stripped_input(M.state.input_file)
        before_ir = ir_utils.extract_function(input_ir, func_name)
        before_name = "Input: " .. func_name
      else
        before_ir = {"", "[ No previous state ]", ""}
        before_name = "Initial"
      end
    else
      -- Check previous pass scope
      local prev_pass = M.state.passes[index - 1]
      local prev_scope_type = prev_pass.scope_type
      local prev_func_name = prev_pass.scope_target

      if prev_scope_type ~= "module" and prev_func_name == func_name then
        -- Same function in previous pass, use it directly
        before_ir = prev_pass.ir
        before_name = prev_pass.name
      elseif prev_scope_type == "module" then
        -- Previous pass was module-scoped, extract our function from it
        before_ir = ir_utils.extract_function(prev_pass.ir, func_name)
        before_name = prev_pass.name .. " → " .. func_name
      else
        -- Previous pass was different function, look backwards for last module pass
        local last_module_pass = nil
        for i = index - 1, 1, -1 do
          if M.state.passes[i].scope_type == "module" then
            last_module_pass = M.state.passes[i]
            break
          end
        end

        if last_module_pass then
          -- Found a module pass, extract our function from it
          before_ir = ir_utils.extract_function(last_module_pass.ir, func_name)
          before_name = last_module_pass.name .. " → " .. func_name
        elseif func_name and M.state.input_file then
          -- No module pass found, try input file
          local input_ir = pipeline.get_stripped_input(M.state.input_file)
          before_ir = ir_utils.extract_function(input_ir, func_name)
          before_name = "Input: " .. func_name
        else
          -- No state available
          before_ir = {"", "[ No previous state ]", ""}
          before_name = "Initial"
        end
      end
    end
  end

  -- Filter debug metadata if configured
  if M.state.config and M.state.config.display and M.state.config.display.strip_debug_metadata then
    before_ir = select(1, ir_utils.filter_debug_metadata(before_ir))
    after_ir = select(1, ir_utils.filter_debug_metadata(after_ir))
  end

  -- Update buffers
  vim.api.nvim_buf_set_option(M.state.before_bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(M.state.before_bufnr, 0, -1, false, before_ir)
  vim.api.nvim_buf_set_option(M.state.before_bufnr, 'modifiable', false)

  vim.api.nvim_buf_set_option(M.state.after_bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(M.state.after_bufnr, 0, -1, false, after_ir)
  vim.api.nvim_buf_set_option(M.state.after_bufnr, 'modifiable', false)

  -- Update buffer names
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
  local target_line_num = nil

  for i, line in ipairs(lines) do
    -- Remove old markers
    if line:match("^>") then
      lines[i] = " " .. line:sub(2)
    end

    -- Find the line for this pass index by matching the pattern
    local pass_idx = line:match("^.%s*(%d+)%.")
    if pass_idx and tonumber(pass_idx) == index then
      lines[i] = ">" .. line:sub(2)
      target_line_num = i
    end
  end

  vim.api.nvim_buf_set_lines(M.state.pass_list_bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'modifiable', false)

  -- Reapply syntax highlighting after updating markers
  M.apply_pass_list_highlights()

  -- Move cursor to the marked line
  if target_line_num then
    vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {target_line_num, 0})
  end
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

-- Navigate to next pass (skips unchanged passes)
function M.next_pass()
  if not M.state.passes or #M.state.passes == 0 then
    return
  end

  -- Find next changed pass
  for i = M.state.current_index + 1, #M.state.passes do
    if M.state.passes[i].changed then
      M.show_diff(i)
      return
    end
  end

  -- No changed pass found ahead, wrap to first changed pass
  for i = 1, M.state.current_index do
    if M.state.passes[i].changed then
      M.show_diff(i)
      return
    end
  end

  -- No changed passes at all (unlikely), just go to next
  M.show_diff(M.state.current_index + 1)
end

-- Navigate to previous pass (skips unchanged passes)
function M.prev_pass()
  if not M.state.passes or #M.state.passes == 0 then
    return
  end

  -- Find previous changed pass
  for i = M.state.current_index - 1, 1, -1 do
    if M.state.passes[i].changed then
      M.show_diff(i)
      return
    end
  end

  -- No changed pass found before, wrap to last changed pass
  for i = #M.state.passes, M.state.current_index, -1 do
    if M.state.passes[i].changed then
      M.show_diff(i)
      return
    end
  end

  -- No changed passes at all (unlikely), just go to previous
  M.show_diff(M.state.current_index - 1)
end

-- Navigate to first changed pass
function M.first_pass()
  if not M.state.passes or #M.state.passes == 0 then
    return
  end

  -- Find first changed pass
  for i = 1, #M.state.passes do
    if M.state.passes[i].changed then
      M.show_diff(i)
      return
    end
  end

  -- No changed passes, just go to first
  M.show_diff(1)
end

-- Navigate to last changed pass
function M.last_pass()
  if not M.state.passes or #M.state.passes == 0 then
    return
  end

  -- Find last changed pass
  for i = #M.state.passes, 1, -1 do
    if M.state.passes[i].changed then
      M.show_diff(i)
      return
    end
  end

  -- No changed passes, just go to last
  M.show_diff(#M.state.passes)
end

-- Helper function to check if a line contains a pass entry
local function is_pass_line(line)
  return line and line:match("^.%s*%d+%.") ~= nil
end

-- Navigate to next pass line in the pass list
local function goto_next_pass_line()
  local cursor = vim.api.nvim_win_get_cursor(M.state.pass_list_winid)
  local current_line = cursor[1]
  local lines = vim.api.nvim_buf_get_lines(M.state.pass_list_bufnr, 0, -1, false)

  -- Find next pass line
  for i = current_line + 1, #lines do
    if is_pass_line(lines[i]) then
      vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {i, 0})
      M.select_pass_under_cursor()
      return
    end
  end
end

-- Navigate to previous pass line in the pass list
local function goto_prev_pass_line()
  local cursor = vim.api.nvim_win_get_cursor(M.state.pass_list_winid)
  local current_line = cursor[1]
  local lines = vim.api.nvim_buf_get_lines(M.state.pass_list_bufnr, 0, -1, false)

  -- Find previous pass line
  for i = current_line - 1, 1, -1 do
    if is_pass_line(lines[i]) then
      vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {i, 0})
      M.select_pass_under_cursor()
      return
    end
  end
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

  -- Match pattern like ">  1. PassName" or "   1. PassName"
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
  vim.keymap.set('n', 'j', goto_next_pass_line, {
    buffer = bufnr,
    desc = 'Next pass'
  })

  vim.keymap.set('n', 'k', goto_prev_pass_line, {
    buffer = bufnr,
    desc = 'Previous pass'
  })

  vim.keymap.set('n', '<Down>', goto_next_pass_line, {
    buffer = bufnr,
    desc = 'Next pass'
  })

  vim.keymap.set('n', '<Up>', goto_prev_pass_line, {
    buffer = bufnr,
    desc = 'Previous pass'
  })

  vim.keymap.set('n', '<Tab>', goto_next_pass_line, {
    buffer = bufnr,
    desc = 'Next pass'
  })

  vim.keymap.set('n', '<S-Tab>', goto_prev_pass_line, {
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

  vim.keymap.set('n', '<Tab>', function() M.next_pass() end, {
    buffer = M.state.before_bufnr,
    desc = 'Next pass'
  })

  vim.keymap.set('n', '<S-Tab>', function() M.prev_pass() end, {
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

  vim.keymap.set('n', '<Tab>', function() M.next_pass() end, {
    buffer = M.state.after_bufnr,
    desc = 'Next pass'
  })

  vim.keymap.set('n', '<S-Tab>', function() M.prev_pass() end, {
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

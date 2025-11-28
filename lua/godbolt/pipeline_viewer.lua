local M = {}

local stats = require('godbolt.stats')
local ir_utils = require('godbolt.ir_utils')
local pipeline = require('godbolt.pipeline')
local line_map = require('godbolt.line_map')

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
  grouped_passes = nil,  -- Grouped/folded pass structure
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

-- Group passes by name for function/cgscc passes
-- Module passes stay ungrouped
-- @return: grouped_passes array with fold state
function M.group_passes()
  local groups = {}
  local open_groups = {}  -- Function groups that can still accept new functions

  for i, pass in ipairs(M.state.passes) do
    if pass.scope_type == "module" then
      -- Module pass: finalize all open function groups
      for _, open_group in ipairs(open_groups) do
        table.insert(groups, open_group)
      end
      open_groups = {}

      -- Add module pass as standalone entry
      table.insert(groups, {
        type = "module",
        pass = pass,
        original_index = i,
      })
    else
      -- Function/CGSCC pass: try to add to an existing open group
      local pass_name = pass.name:match("^(.+) on ") or pass.name
      local added = false

      -- Check if any open group can accept this pass
      for _, open_group in ipairs(open_groups) do
        if open_group.pass_name == pass_name and
           open_group.scope_type == pass.scope_type then
          -- Check if this target already exists in the group
          local target_exists = false
          for _, fn in ipairs(open_group.functions) do
            if fn.target == pass.scope_target then
              target_exists = true
              break
            end
          end

          if not target_exists then
            -- Add to this open group (same pass, different function)
            table.insert(open_group.functions, {
              target = pass.scope_target,
              pass = pass,
              original_index = i,
            })
            added = true
            break
          end
        end
      end

      if not added then
        -- Create new open group (new pass or duplicate target = different invocation)
        local group_type = pass.scope_type == "cgscc" and "cgscc_group" or "function_group"
        local new_group = {
          type = group_type,
          pass_name = pass_name,
          scope_type = pass.scope_type,
          functions = {{
            target = pass.scope_target,
            pass = pass,
            original_index = i,
          }},
          folded = true,
        }
        table.insert(open_groups, new_group)
      end
    end
  end

  -- Finalize any remaining open groups at end of pipeline
  for _, open_group in ipairs(open_groups) do
    table.insert(groups, open_group)
  end

  -- Assign display_index sequentially
  for idx, group in ipairs(groups) do
    group.display_index = idx
  end

  -- Compute has_changes flag for each group (used for highlighting)
  -- All groups start folded - user unfolds with Enter/o to see individual functions
  -- This keeps the list compact even when groups have 1000s of functions
  for _, group in ipairs(groups) do
    if group.type == "function_group" or group.type == "cgscc_group" then
      local has_changes = false
      for _, fn in ipairs(group.functions) do
        if M.state.passes[fn.original_index].changed then
          has_changes = true
          break
        end
      end
      group.has_changes = has_changes  -- Store for highlighting
      group.folded = true  -- Always start folded
    end
  end

  return groups
end

-- Populate pass list buffer with tree-style formatting
function M.populate_pass_list()
  -- Group passes first (or use cached groups)
  if not M.state.grouped_passes then
    M.state.grouped_passes = M.group_passes()
  end

  local lines = {}
  local groups = M.state.grouped_passes
  local header = string.format("Optimization Pipeline (%d passes, %d groups)", #M.state.passes, #groups)
  table.insert(lines, header)
  table.insert(lines, string.rep("-", #header))
  table.insert(lines, "")

  for _, group in ipairs(groups) do
    if group.type == "module" then
      -- Single module pass
      local pass = group.pass
      local i = group.original_index
      local marker = (i == M.state.current_index) and ">" or " "

      local line = string.format("%s%2d. [M] %s", marker, group.display_index, pass.name)
      table.insert(lines, line)

      -- Add stats if configured
      if M.state.config.show_stats and i > 1 then
        local prev_stats = nil
        for j = i - 1, 1, -1 do
          if M.state.passes[j].scope_type == "module" then
            prev_stats = M.state.passes[j].stats
            break
          end
        end

        if prev_stats then
          local delta = stats.delta(prev_stats, pass.stats)
          local stats_parts = {}
          if delta.instructions ~= 0 then
            table.insert(stats_parts, string.format("Insts %+d", delta.instructions))
          end
          if delta.basic_blocks ~= 0 then
            table.insert(stats_parts, string.format("BBs %+d", delta.basic_blocks))
          end
          if pass.changed and pass.diff_stats and pass.diff_stats.lines_changed > 0 then
            table.insert(stats_parts, string.format("Δ%d lines", pass.diff_stats.lines_changed))
          end
          if #stats_parts > 0 then
            table.insert(lines, "     D: " .. table.concat(stats_parts, ", "))
          end
        elseif pass.changed and pass.diff_stats and pass.diff_stats.lines_changed > 0 then
          table.insert(lines, string.format("     D: Δ%d lines", pass.diff_stats.lines_changed))
        end
      end

    else
      -- Function/CGSCC group
      local fold_icon = group.folded and "▸" or "▾"
      local scope_icon = group.scope_type == "cgscc" and "C" or "F"
      local func_count = #group.functions

      -- Check if any function in this group is selected
      local any_selected = false
      for _, fn in ipairs(group.functions) do
        if fn.original_index == M.state.current_index then
          any_selected = true
          break
        end
      end
      local marker = any_selected and ">" or " "

      -- Format: " 5. ▸ [F] PassName (N functions)" - aligned with module passes
      local line = string.format("%s%2d. %s [%s] %s (%d %s)",
        marker, group.display_index, fold_icon, scope_icon, group.pass_name, func_count,
        func_count == 1 and "function" or "functions")
      table.insert(lines, line)

      -- If unfolded, show function list
      if not group.folded then
        for fn_idx, fn in ipairs(group.functions) do
          local fn_marker = (fn.original_index == M.state.current_index) and "●" or " "
          -- Indent: 5 spaces (for " NN. ") + marker + 3 spaces + name
          local fn_line = string.format("     %s   %s", fn_marker, fn.target)
          table.insert(lines, fn_line)

          -- Add stats for this function's pass
          if M.state.config.show_stats and fn.original_index > 1 then
            local pass = fn.pass
            local prev_pass = M.state.passes[fn.original_index - 1]
            local prev_stats = nil

            if prev_pass.scope_type ~= "module" and prev_pass.scope_target == pass.scope_target then
              prev_stats = prev_pass.stats
            end

            if prev_stats then
              local delta = stats.delta(prev_stats, pass.stats)
              local stats_parts = {}
              if delta.instructions ~= 0 then
                table.insert(stats_parts, string.format("Insts %+d", delta.instructions))
              end
              if delta.basic_blocks ~= 0 then
                table.insert(stats_parts, string.format("BBs %+d", delta.basic_blocks))
              end
              if pass.changed and pass.diff_stats and pass.diff_stats.lines_changed > 0 then
                table.insert(stats_parts, string.format("Δ%d lines", pass.diff_stats.lines_changed))
              end
              if #stats_parts > 0 then
                table.insert(lines, "       D: " .. table.concat(stats_parts, ", "))
              end
            elseif pass.changed and pass.diff_stats and pass.diff_stats.lines_changed > 0 then
              table.insert(lines, string.format("       D: Δ%d lines", pass.diff_stats.lines_changed))
            end
          end
        end
      end
    end
  end

  table.insert(lines, "")
  table.insert(lines, "Legend: [M]=Module [F]=Function [C]=CGSCC")
  table.insert(lines, "Keys: j/k=nav, Tab/S-Tab=changed-only, Enter/o=fold, q=quit")

  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(M.state.pass_list_bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'modifiable', false)

  -- Apply syntax highlighting
  M.apply_pass_list_highlights()
end

-- Setup custom highlight groups for pipeline viewer
local function setup_highlight_groups()
  local bg = vim.o.background

  -- Fold icons
  vim.api.nvim_set_hl(0, "GodboltPipelineFoldIcon", {link = "Special"})

  -- Group headers (function/CGSCC groups)
  if bg == "dark" then
    vim.api.nvim_set_hl(0, "GodboltPipelineGroupHeader", {fg = "#8fbcbb", bold = true})
    vim.api.nvim_set_hl(0, "GodboltPipelineGroupCount", {fg = "#88c0d0", italic = true})
  else
    vim.api.nvim_set_hl(0, "GodboltPipelineGroupHeader", {fg = "#5e81ac", bold = true})
    vim.api.nvim_set_hl(0, "GodboltPipelineGroupCount", {fg = "#81a1c1", italic = true})
  end

  -- Function entries (indented)
  vim.api.nvim_set_hl(0, "GodboltPipelineFunctionEntry", {link = "String"})

  -- Selected marker
  if bg == "dark" then
    vim.api.nvim_set_hl(0, "GodboltPipelineSelectedMarker", {fg = "#bf616a", bold = true})
  else
    vim.api.nvim_set_hl(0, "GodboltPipelineSelectedMarker", {fg = "#d08770", bold = true})
  end

  -- Pass numbers
  vim.api.nvim_set_hl(0, "GodboltPipelinePassNumber", {link = "Number"})

  -- Scope indicators [M], [F], [C]
  vim.api.nvim_set_hl(0, "GodboltPipelineScopeModule", {link = "Type"})
  vim.api.nvim_set_hl(0, "GodboltPipelineScopeFunction", {link = "Function"})
  vim.api.nvim_set_hl(0, "GodboltPipelineScopeCGSCC", {link = "Keyword"})

  -- Pass names
  vim.api.nvim_set_hl(0, "GodboltPipelinePassName", {link = "Identifier"})

  -- Unchanged passes (grayed out)
  vim.api.nvim_set_hl(0, "GodboltPipelineUnchanged", {link = "Comment"})
end

-- Apply syntax highlighting to the pass list buffer
function M.apply_pass_list_highlights()
  local bufnr = M.state.pass_list_bufnr
  local ns_id = M.state.ns_id

  -- Setup highlight groups (refresh on every call to support colorscheme changes)
  setup_highlight_groups()

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

    -- Indented function entry "     ●   function_name" or "         function_name"
    -- Note: Can't use [● ] character class with UTF-8
    elseif line:match("^     ●   ") or line:match("^         ") then
      -- Check if marker is ●
      if line:match("^     ●") then
        -- Highlight selection marker (● at position 5)
        local marker_pos = 5  -- 0-indexed, 5 spaces then marker
        vim.api.nvim_buf_add_highlight(bufnr, ns_id, "GodboltPipelineSelectedMarker", line_num, marker_pos, marker_pos + 3)  -- ● is 3 bytes in UTF-8
      end

      -- Determine if this function's pass has changes
      local func_name = line:match("^     ●   (.+)$") or line:match("^         (.+)$")
      local func_changed = false

      if func_name and M.state.grouped_passes then
        -- Look backwards to find the group header
        for back_i = line_idx - 1, 1, -1 do
          local prev_line = lines[back_i]
          if prev_line and prev_line:match("^[> ]%s*%d+%. ") and (prev_line:match("▸") or prev_line:match("▾")) then
            -- Found group header, get display index
            local display_idx = tonumber(prev_line:match("^[> ]%s*(%d+)%."))
            if display_idx then
              -- Find this group in grouped_passes
              for _, group in ipairs(M.state.grouped_passes) do
                if group.display_index == display_idx and (group.type == "function_group" or group.type == "cgscc_group") and group.functions then
                  -- Find this function in the group
                  for _, fn in ipairs(group.functions) do
                    if fn.target == func_name then
                      func_changed = M.state.passes[fn.original_index].changed
                      break
                    end
                  end
                end
              end
            end
            break
          end
        end
      end

      -- Highlight function name (starts at position 9: "     ●   ")
      local name_start = 9
      local highlight_group = func_changed and "GodboltPipelineFunctionEntry" or "GodboltPipelineUnchanged"
      vim.api.nvim_buf_add_highlight(bufnr, ns_id, highlight_group, line_num, name_start, -1)

    -- Group header lines "> 5. ▸ [F] PassName (N functions)" or " 10. ▾ [F] PassName..."
    -- Note: Can't use [▸▾] character class with UTF-8, must check explicitly
    elseif line:match("^[> ]%s*%d+%. ") and (line:match("▸") or line:match("▾")) then
      local col = 0

      -- Highlight selection marker (> or space at position 0)
      if line:match("^>") then
        vim.api.nvim_buf_add_highlight(bufnr, ns_id, "GodboltPipelineSelectedMarker", line_num, 0, 1)
      end
      col = 1  -- After marker

      -- Skip space(s), find and highlight number
      local num_start, num_end = line:find("%d+", col + 1)
      if num_start then
        vim.api.nvim_buf_add_highlight(bufnr, ns_id, "GodboltPipelinePassNumber", line_num, num_start - 1, num_end)
        col = num_end + 1  -- After number, skip ". "
      end

      -- Find fold icon (▸ or ▾) - it's 3 bytes in UTF-8
      local fold_start = col
      vim.api.nvim_buf_add_highlight(bufnr, ns_id, "GodboltPipelineFoldIcon", line_num, fold_start, fold_start + 3)
      col = fold_start + 4  -- After fold icon + space

      -- Find and highlight scope indicator [F] or [C]
      local scope_start, scope_end = line:find("%[%w%]", col)
      if scope_start then
        local scope_type = line:match("%[(%w)%]", col)
        local scope_hl = "GodboltPipelineScopeModule"
        if scope_type == "F" then
          scope_hl = "GodboltPipelineScopeFunction"
        elseif scope_type == "C" then
          scope_hl = "GodboltPipelineScopeCGSCC"
        end
        vim.api.nvim_buf_add_highlight(bufnr, ns_id, scope_hl, line_num, scope_start - 1, scope_end)
        col = scope_end + 1  -- Skip space after scope
      end

      -- Highlight pass name and function count
      local count_start = line:find(" %(", col)
      if count_start then
        -- Pass name (everything before count)
        vim.api.nvim_buf_add_highlight(bufnr, ns_id, "GodboltPipelineGroupHeader", line_num, col, count_start)
        -- Function count (e.g., "(3 functions)")
        vim.api.nvim_buf_add_highlight(bufnr, ns_id, "GodboltPipelineGroupCount", line_num, count_start, -1)
      else
        vim.api.nvim_buf_add_highlight(bufnr, ns_id, "GodboltPipelineGroupHeader", line_num, col, -1)
      end

      -- Check if this group has changes - gray out if not
      local display_idx = tonumber(line:match("^[> ]%s*(%d+)%."))
      if display_idx and M.state.grouped_passes then
        for _, group in ipairs(M.state.grouped_passes) do
          if group.display_index == display_idx and (group.type == "function_group" or group.type == "cgscc_group") then
            if not group.has_changes then
              -- Override with gray highlighting for unchanged groups
              -- Re-highlight from pass name to end of line
              vim.api.nvim_buf_add_highlight(bufnr, ns_id, "GodboltPipelineUnchanged", line_num, col, -1)
            end
            break
          end
        end
      end

    -- Module pass entry lines "> 1. [M] PassName" or " 10. [M] PassName"
    elseif line:match("^[> ]%s*%d+%. %[M%]") then
      local col = 0

      -- Highlight selection marker (> or space)
      if line:match("^>") then
        vim.api.nvim_buf_add_highlight(bufnr, ns_id, "GodboltPipelineSelectedMarker", line_num, 0, 1)
      end
      col = 1

      -- Skip space, then find and highlight pass number
      local num_start, num_end = line:find("%d+", col + 1)
      if num_start then
        vim.api.nvim_buf_add_highlight(bufnr, ns_id, "GodboltPipelinePassNumber", line_num, num_start - 1, num_end)
        col = num_end + 1  -- Skip ". "
      end

      -- Find and highlight scope indicator [M]
      local scope_start, scope_end = line:find("%[M%]", col)
      if scope_start then
        vim.api.nvim_buf_add_highlight(bufnr, ns_id, "GodboltPipelineScopeModule", line_num, scope_start - 1, scope_end)
        col = scope_end + 1  -- Skip space after scope
      end

      -- Check if module pass changed
      local pass_num = tonumber(line:match("^[> ]%s*(%d+)%."))
      if pass_num and M.state.grouped_passes then
        local pass_changed = false
        for _, group in ipairs(M.state.grouped_passes) do
          if group.display_index == pass_num and group.type == "module" then
            pass_changed = M.state.passes[group.original_index].changed
            break
          end
        end

        if not pass_changed then
          -- Gray out unchanged module passes
          vim.api.nvim_buf_add_highlight(bufnr, ns_id, "GodboltPipelineUnchanged", line_num, col, -1)
        else
          -- Highlight pass name (everything up to " on ")
          local on_start = line:find(" on ", col)
          if on_start then
            -- Pass name
            vim.api.nvim_buf_add_highlight(bufnr, ns_id, "GodboltPipelinePassName", line_num, col, on_start - 1)
            -- Highlight " on " as Special
            vim.api.nvim_buf_add_highlight(bufnr, ns_id, "Special", line_num, on_start - 1, on_start + 3)
            -- Highlight target (everything after "on ")
            vim.api.nvim_buf_add_highlight(bufnr, ns_id, "String", line_num, on_start + 3, -1)
          else
            -- No " on " found, highlight rest as pass name
            vim.api.nvim_buf_add_highlight(bufnr, ns_id, "GodboltPipelinePassName", line_num, col, -1)
          end
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
    -- Get before IR - use stored before_ir if available, otherwise reconstruct
    local before_ir
    if pass.before_ir then
      -- We have the actual before IR from -print-before-all
      before_ir = pass.before_ir
    else
      -- Fallback to reconstruction (for backwards compatibility)
      before_ir = M.get_before_ir_for_pass(index)
    end

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

  -- Prefer captured before_ir from -print-before-all
  if pass.before_ir and #pass.before_ir > 0 then
    return pass.before_ir
  end

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
    -- Prefer captured before_ir from -print-before-all
    if pass.before_ir and #pass.before_ir > 0 then
      before_ir = pass.before_ir
      before_name = "Before: " .. pass.name
    elseif index == 1 then
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

  -- Set up line mapping between source and after IR (if source buffer exists)
  if M.state.source_bufnr and vim.api.nvim_buf_is_valid(M.state.source_bufnr) then
    -- Clean up previous line mapping
    line_map.cleanup()

    -- Set up line mapping with auto-scroll enabled
    local line_map_config = M.state.config.line_mapping or {}
    line_map_config.auto_scroll = true  -- Force auto-scroll in pipeline viewer

    -- Store full IR for line mapping
    vim.b[M.state.after_bufnr].godbolt_full_output = after_ir

    line_map.setup(M.state.source_bufnr, M.state.after_bufnr, "llvm", line_map_config)
  end
end

-- Update the cursor marker in pass list
-- IMPORTANT: index is the ORIGINAL index in M.state.passes, NOT display_index!
function M.update_pass_list_cursor(index)
  -- Just rebuild the entire list - it's simpler and more reliable
  -- The populate function already handles marking the correct entry based on M.state.current_index
  M.populate_pass_list()

  -- Find the line to move cursor to
  -- Need to map original_index to actual line number in display
  local target_line_num = nil
  local lines = vim.api.nvim_buf_get_lines(M.state.pass_list_bufnr, 0, -1, false)

  -- PRIORITY 1: Look for function entry marker ● (most specific)
  -- This ensures we land on the actual selected function entry, not the group header
  for i, line in ipairs(lines) do
    if line:match("^     ●") then
      target_line_num = i
      break
    end
  end

  -- PRIORITY 2: If no ● found, look for group/module marker > (fallback)
  if not target_line_num then
    for i, line in ipairs(lines) do
      if line:match("^>") then
        target_line_num = i
        break
      end
    end
  end

  -- Move cursor to the marked line
  if target_line_num then
    pcall(vim.api.nvim_win_set_cursor, M.state.pass_list_winid, {target_line_num, 0})
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

  -- No changed pass found ahead, stop at the end (don't wrap)
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

  -- No changed pass found before, stop at the beginning (don't wrap)
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

-- Toggle fold state of group under cursor
function M.toggle_fold_under_cursor()
  local cursor = vim.api.nvim_win_get_cursor(M.state.pass_list_winid)
  local line_num = cursor[1]
  local line = vim.api.nvim_buf_get_lines(M.state.pass_list_bufnr, line_num - 1, line_num, false)[1]

  -- Check if this is a foldable group (pattern: "[> ]NN. [▸▾]" where NN is right-aligned 2 digits)
  -- Note: Can't use [▸▾] character class with UTF-8
  local has_fold_icon = line:match("^[> ]%s*%d+%. ") and (line:match("▸") or line:match("▾"))
  if not has_fold_icon then
    return false
  end

  -- Extract display index from the line
  local display_idx = tonumber(line:match("^[> ]%s*(%d+)%."))
  if not display_idx then
    return false
  end

  -- Find the group and toggle fold state
  for _, group in ipairs(M.state.grouped_passes) do
    if group.display_index == display_idx and (group.type == "function_group" or group.type == "cgscc_group") then
      group.folded = not group.folded
      M.populate_pass_list()  -- Rebuild display

      -- Find the group header line again after rebuild (line numbers may have shifted)
      local lines = vim.api.nvim_buf_get_lines(M.state.pass_list_bufnr, 0, -1, false)
      for i, new_line in ipairs(lines) do
        local new_idx = tonumber(new_line:match("^[> ]%s*(%d+)%."))
        if new_idx == display_idx then
          -- Found the group header, move cursor there
          pcall(vim.api.nvim_win_set_cursor, M.state.pass_list_winid, {i, 0})
          return true
        end
      end

      return true
    end
  end

  return false
end

-- Helper function to check if a line contains a pass entry
local function is_pass_line(line)
  -- Match module passes, groups, or function entries
  -- Note: Can't use [▸▾●] character classes with UTF-8
  -- Format is: "> 1. " or " 10. " (marker + right-aligned 2-digit number + dot + space)
  return line and (
    line:match("^[> ]%s*%d+%. %[M%]") or      -- Module: "> 1. [M]" or " 10. [M]"
    (line:match("^[> ]%s*%d+%. ") and (line:match("▸") or line:match("▾"))) or  -- Group with fold icon
    line:match("^     ●   ") or line:match("^         ")  -- Function: "     ●   name" or "         name"
  )
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
      M.select_pass_for_viewing()  -- Use for_viewing to avoid toggling folds!
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
      M.select_pass_for_viewing()  -- Use for_viewing to avoid toggling folds!
      return
    end
  end
end

-- Helper to check if a pass is changed (for smart navigation)
local function is_pass_changed(original_index)
  if not M.state.passes or not M.state.passes[original_index] then
    return false
  end
  return M.state.passes[original_index].changed
end

-- Navigate to next changed pass line (smart Tab navigation)
local function goto_next_changed_pass_line()
  if not M.state.grouped_passes or #M.state.grouped_passes == 0 then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(M.state.pass_list_winid)
  local current_line = cursor[1]
  local lines = vim.api.nvim_buf_get_lines(M.state.pass_list_bufnr, 0, -1, false)

  -- Find next pass line that corresponds to a changed pass
  for i = current_line + 1, #lines do
    local line = lines[i]
    if is_pass_line(line) then
      -- Check if this is a group header: "> 5. ▸ [F] PassName"
      -- Note: Can't use [▸▾] character class with UTF-8
      local is_group = line:match("^[> ]%s*%d+%. ") and (line:match("▸") or line:match("▾"))
      if is_group then
        local display_idx = tonumber(line:match("^[> ]%s*(%d+)%."))
        if display_idx then
          -- Check if any function in this group has changes
          for _, group in ipairs(M.state.grouped_passes) do
            if group.display_index == display_idx and (group.type == "function_group" or group.type == "cgscc_group") and group.functions then
              -- Find first changed function in this group
              local first_changed_fn = nil
              for _, fn in ipairs(group.functions) do
                if is_pass_changed(fn.original_index) then
                  first_changed_fn = fn
                  break
                end
              end

              if first_changed_fn then
                -- UNFOLD the group if it's folded
                if group.folded then
                  group.folded = false
                  M.populate_pass_list()  -- Rebuild to show function entries
                end

                -- Now find the actual function entry line in the unfolded group
                local lines_updated = vim.api.nvim_buf_get_lines(M.state.pass_list_bufnr, 0, -1, false)
                for line_idx, search_line in ipairs(lines_updated) do
                  local func_name = search_line:match("^     ●   (.+)$") or search_line:match("^         (.+)$")
                  if func_name == first_changed_fn.target then
                    -- Found it! Move cursor to the function entry
                    vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {line_idx, 0})
                    M.select_pass_for_viewing()
                    return
                  end
                end

                -- Fallback: if we can't find the function entry (shouldn't happen), just show the group
                vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {i, 0})
                M.select_pass_for_viewing()
                return
              end
            end
          end
        end
      else
        -- Module pass or function entry
        local pass_num = line:match("^[> ]%s*(%d+)%. %[M%]")
        if pass_num then
          local display_idx = tonumber(pass_num)
          -- Find corresponding group and check if changed
          for _, group in ipairs(M.state.grouped_passes) do
            if group.display_index == display_idx and group.type == "module" then
              if is_pass_changed(group.original_index) then
                vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {i, 0})
                M.select_pass_for_viewing()  -- Use for_viewing to avoid toggling folds!
                return
              end
            end
          end
        else
          -- Check if this is a function entry
          local is_function_entry = line:match("^     ●   ") or line:match("^         ")
          if is_function_entry then
            -- Extract function name
            local func_name = line:match("^     ●   (.+)$") or line:match("^         (.+)$")
            if func_name then
              -- Look backwards to find the group header
              for back_i = i - 1, 1, -1 do
                local prev_line = lines[back_i]
                if prev_line and prev_line:match("^[> ]%s*%d+%. ") and (prev_line:match("▸") or prev_line:match("▾")) then
                  -- Found group header
                  local display_idx = tonumber(prev_line:match("^[> ]%s*(%d+)%."))
                  if display_idx then
                    -- Find the function in the group
                    for _, group in ipairs(M.state.grouped_passes) do
                      if group.display_index == display_idx and (group.type == "function_group" or group.type == "cgscc_group") and group.functions then
                        for _, fn in ipairs(group.functions) do
                          if fn.target == func_name and is_pass_changed(fn.original_index) then
                            vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {i, 0})
                            M.select_pass_for_viewing()
                            return
                          end
                        end
                      end
                    end
                  end
                  break
                end
              end
            end
          end
        end
      end
    end
  end
end

-- Navigate to previous changed pass line (smart Shift-Tab navigation)
local function goto_prev_changed_pass_line()
  if not M.state.grouped_passes or #M.state.grouped_passes == 0 then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(M.state.pass_list_winid)
  local current_line = cursor[1]
  local lines = vim.api.nvim_buf_get_lines(M.state.pass_list_bufnr, 0, -1, false)

  -- Find previous pass line that corresponds to a changed pass
  for i = current_line - 1, 1, -1 do
    local line = lines[i]
    if is_pass_line(line) then
      -- Check if this is a group header: "> 5. ▸ [F] PassName"
      -- Note: Can't use [▸▾] character class with UTF-8
      local is_group = line:match("^[> ]%s*%d+%. ") and (line:match("▸") or line:match("▾"))
      if is_group then
        local display_idx = tonumber(line:match("^[> ]%s*(%d+)%."))
        if display_idx then
          -- Check if any function in this group has changes
          for _, group in ipairs(M.state.grouped_passes) do
            if group.display_index == display_idx and (group.type == "function_group" or group.type == "cgscc_group") and group.functions then
              -- Find first changed function in this group
              local first_changed_fn = nil
              for _, fn in ipairs(group.functions) do
                if is_pass_changed(fn.original_index) then
                  first_changed_fn = fn
                  break
                end
              end

              if first_changed_fn then
                -- UNFOLD the group if it's folded
                if group.folded then
                  group.folded = false
                  M.populate_pass_list()  -- Rebuild to show function entries
                end

                -- Now find the actual function entry line in the unfolded group
                local lines_updated = vim.api.nvim_buf_get_lines(M.state.pass_list_bufnr, 0, -1, false)
                for line_idx, search_line in ipairs(lines_updated) do
                  local func_name = search_line:match("^     ●   (.+)$") or search_line:match("^         (.+)$")
                  if func_name == first_changed_fn.target then
                    -- Found it! Move cursor to the function entry
                    vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {line_idx, 0})
                    M.select_pass_for_viewing()
                    return
                  end
                end

                -- Fallback: if we can't find the function entry (shouldn't happen), just show the group
                vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {i, 0})
                M.select_pass_for_viewing()
                return
              end
            end
          end
        end
      else
        -- Module pass or function entry
        local pass_num = line:match("^[> ]%s*(%d+)%. %[M%]")
        if pass_num then
          local display_idx = tonumber(pass_num)
          -- Find corresponding group and check if changed
          for _, group in ipairs(M.state.grouped_passes) do
            if group.display_index == display_idx and group.type == "module" then
              if is_pass_changed(group.original_index) then
                vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {i, 0})
                M.select_pass_for_viewing()  -- Use for_viewing to avoid toggling folds!
                return
              end
            end
          end
        else
          -- Check if this is a function entry
          local is_function_entry = line:match("^     ●   ") or line:match("^         ")
          if is_function_entry then
            -- Extract function name
            local func_name = line:match("^     ●   (.+)$") or line:match("^         (.+)$")
            if func_name then
              -- Look backwards to find the group header
              for back_i = i - 1, 1, -1 do
                local prev_line = lines[back_i]
                if prev_line and prev_line:match("^[> ]%s*%d+%. ") and (prev_line:match("▸") or prev_line:match("▾")) then
                  -- Found group header
                  local display_idx = tonumber(prev_line:match("^[> ]%s*(%d+)%."))
                  if display_idx then
                    -- Find the function in the group
                    for _, group in ipairs(M.state.grouped_passes) do
                      if group.display_index == display_idx and (group.type == "function_group" or group.type == "cgscc_group") and group.functions then
                        for _, fn in ipairs(group.functions) do
                          if fn.target == func_name and is_pass_changed(fn.original_index) then
                            vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {i, 0})
                            M.select_pass_for_viewing()
                            return
                          end
                        end
                      end
                    end
                  end
                  break
                end
              end
            end
          end
        end
      end
    end
  end
end

-- Select pass for viewing (used by j/k navigation)
-- This version NEVER toggles folds, only shows diffs
function M.select_pass_for_viewing()
  local cursor = vim.api.nvim_win_get_cursor(M.state.pass_list_winid)
  local line_num = cursor[1]

  -- Parse line to get pass index
  local line = vim.api.nvim_buf_get_lines(M.state.pass_list_bufnr, line_num - 1, line_num, false)[1]
  if not line then
    return
  end

  -- Check if this is a group header "> 5. ▸ [F] PassName (N functions)"
  -- Note: Can't use [▸▾] character class with UTF-8
  local is_group_header = line:match("^[> ]%s*%d+%. ") and (line:match("▸") or line:match("▾"))

  if is_group_header then
    -- For navigation: check if current_index is already in this group
    local display_idx = tonumber(line:match("^[> ]%s*(%d+)%."))
    if display_idx and M.state.grouped_passes then
      for _, group in ipairs(M.state.grouped_passes) do
        if group.display_index == display_idx and (group.type == "function_group" or group.type == "cgscc_group") and group.functions and #group.functions > 0 then
          -- Check if current_index is already in this group
          local already_in_group = false
          for _, fn in ipairs(group.functions) do
            if fn.original_index == M.state.current_index then
              already_in_group = true
              break
            end
          end

          -- Only select first function if we're not already viewing a function in this group
          if not already_in_group then
            M.show_diff(group.functions[1].original_index)
          end
          return
        end
      end
    end
    return
  end

  -- Check if this is an indented function entry "     ●   function_name"
  -- Note: Can't use [● ] character class with UTF-8
  local is_function_entry = line:match("^     ●   ") or line:match("^         ")
  if is_function_entry then
    -- Look backwards to find the group header and count function entry position
    local group_header_line = nil
    for i = line_num - 1, 1, -1 do
      local prev_line = vim.api.nvim_buf_get_lines(M.state.pass_list_bufnr, i - 1, i, false)[1]
      -- Check if this is a group header (with UTF-8 triangle)
      if prev_line and prev_line:match("^[> ]%s*%d+%. ") and (prev_line:match("▸") or prev_line:match("▾")) then
        group_header_line = i
        break
      end
    end

    if group_header_line then
      -- Count which function entry this is (1-based index)
      local function_entry_index = 0
      for i = group_header_line + 1, line_num do
        local check_line = vim.api.nvim_buf_get_lines(M.state.pass_list_bufnr, i - 1, i, false)[1]
        if check_line and (check_line:match("^     ●   ") or check_line:match("^         ")) then
          function_entry_index = function_entry_index + 1
          if i == line_num then
            break
          end
        end
      end

      if function_entry_index > 0 then
        -- Extract display index from group header
        local header = vim.api.nvim_buf_get_lines(M.state.pass_list_bufnr, group_header_line - 1, group_header_line, false)[1]
        local display_idx = tonumber(header:match("^[> ]%s*(%d+)%."))

        if display_idx then
          -- Find the group and select the Nth function
          for _, group in ipairs(M.state.grouped_passes) do
            if group.display_index == display_idx and (group.type == "function_group" or group.type == "cgscc_group") and group.functions then
              if function_entry_index <= #group.functions then
                M.show_diff(group.functions[function_entry_index].original_index)
                return
              end
            end
          end
        end
      end
    end
  end

  -- Regular module pass: "> 1. [M] PassName" or " 10. [M] PassName"
  local pass_num = line:match("^[> ]%s*(%d+)%. %[M%]")
  if pass_num then
    local display_idx = tonumber(pass_num)
    for _, group in ipairs(M.state.grouped_passes) do
      if group.display_index == display_idx and group.type == "module" then
        M.show_diff(group.original_index)
        return
      end
    end
  end
end

-- Activate line under cursor (used by Enter key)
-- This version toggles folds for group headers, shows diffs for everything else
function M.activate_line_under_cursor()
  local cursor = vim.api.nvim_win_get_cursor(M.state.pass_list_winid)
  local line_num = cursor[1]

  -- Parse line to get pass index
  local line = vim.api.nvim_buf_get_lines(M.state.pass_list_bufnr, line_num - 1, line_num, false)[1]
  if not line then
    return
  end

  -- Check if this is a group header "> 5. ▸ [F] PassName (N functions)"
  -- Note: Can't use [▸▾] character class with UTF-8
  local is_group_header = line:match("^[> ]%s*%d+%. ") and (line:match("▸") or line:match("▾"))

  if is_group_header then
    -- For Enter key: toggle fold
    M.toggle_fold_under_cursor()
    return
  end

  -- For everything else (function entries, module passes), show diff
  M.select_pass_for_viewing()
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

  -- Smart navigation: Tab/Shift-Tab only jump to changed passes
  vim.keymap.set('n', '<Tab>', goto_next_changed_pass_line, {
    buffer = bufnr,
    desc = 'Next changed pass'
  })

  vim.keymap.set('n', '<S-Tab>', goto_prev_changed_pass_line, {
    buffer = bufnr,
    desc = 'Previous changed pass'
  })

  -- Fold/unfold groups
  vim.keymap.set('n', 'o', function()
    M.toggle_fold_under_cursor()
  end, {
    buffer = bufnr,
    desc = 'Toggle fold'
  })

  -- Enter: fold/unfold or select pass
  vim.keymap.set('n', '<CR>', function()
    M.activate_line_under_cursor()
  end, {
    buffer = bufnr,
    desc = 'Toggle fold or select pass'
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
  -- Clean up line mapping
  line_map.cleanup()

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

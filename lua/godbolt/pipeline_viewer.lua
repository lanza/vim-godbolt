local M = {}

local stats = require('godbolt.stats')
local ir_utils = require('godbolt.ir_utils')
local pipeline = require('godbolt.pipeline')
local line_map = require('godbolt.line_map')


-- Helper to get timestamp string
local function get_timestamp()
  return os.date("%H:%M:%S")
end

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
  ns_selection = vim.api.nvim_create_namespace('godbolt_pipeline_selection'),  -- Separate namespace for selection highlighting
  grouped_passes = nil,  -- Grouped/folded pass structure
  module_pass_indices = nil,  -- OPTIMIZATION: Index of module pass positions {5, 23, 107, ...}
  on_group_header = false,  -- Track if we're on a group header (don't show function marker)
  num_width = nil,  -- Width of pass numbers (computed once from #groups)
}

-- Setup pipeline viewer with 3-pane layout
-- @param source_bufnr: source buffer number
-- @param input_file: path to input .ll file
-- @param passes: array of {name, ir} from pipeline.parse_pipeline_output
-- @param config: configuration table
function M.setup(source_bufnr, input_file, passes, config)
  local setup_start = vim.loop.hrtime()
  -- print(string.format("[" .. get_timestamp() .. "] [Pipeline] [%.3fs] setup() called with %d passes", 0, #passes))

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
    local t = (vim.loop.hrtime() - setup_start) / 1e9
    -- print(string.format("[" .. get_timestamp() .. "] [Pipeline] [%.3fs] Filtered to %d passes that changed IR", t, #passes))
  end

  local t = (vim.loop.hrtime() - setup_start) / 1e9
  -- print(string.format("[" .. get_timestamp() .. "] [Pipeline] [%.3fs] Storing state", t))

  -- Store state EARLY (before any heavy computation)
  M.state.passes = passes
  M.state.source_bufnr = source_bufnr
  M.state.input_file = input_file
  M.state.config = config

  -- OPTIMIZATION: Build module pass index for O(1) lookups instead of O(n) scans
  -- This dramatically speeds up get_before_ir_for_pass() for module passes
  M.state.module_pass_indices = {}
  for i, pass in ipairs(passes) do
    if pass.scope_type == "module" then
      table.insert(M.state.module_pass_indices, i)
    end
  end

  -- t = (vim.loop.hrtime() - setup_start) / 1e9
  -- print(string.format("[" .. get_timestamp() .. "] [Pipeline] [%.3fs] Creating layout", t))

  -- Create 3-pane layout FIRST (show UI immediately, before any stats computation!)
  M.create_layout()

  -- t = (vim.loop.hrtime() - setup_start) / 1e9
  -- print(string.format("[" .. get_timestamp() .. "] [Pipeline] [%.3fs] Layout created, showing placeholder", t))

  -- Show "Computing..." message in pass list
  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(M.state.pass_list_bufnr, 0, -1, false, {
    string.format("Optimization Pipeline (%d passes)", #passes),
    string.rep("-", 40),
    "",
    "⏳ Computing statistics...",
  })
  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'modifiable', false)

  -- t = (vim.loop.hrtime() - setup_start) / 1e9
  -- print(string.format("[" .. get_timestamp() .. "] [Pipeline] [%.3fs] Setting up keymaps", t))

  -- Set up key mappings early
  M.setup_keymaps()

  -- t = (vim.loop.hrtime() - setup_start) / 1e9
  -- print(string.format("[" .. get_timestamp() .. "] [Pipeline] [%.3fs] Scheduling async computation", t))

  -- Defer ALL heavy computation to async chunks to avoid UI freeze
  vim.schedule(function()
    -- local async_start = vim.loop.hrtime()
    -- print(string.format("[" .. get_timestamp() .. "] [Pipeline] [%.3fs] Starting compute_stats_async", (async_start - setup_start) / 1e9))

    -- OPTIMIZATION: Compute stats asynchronously in chunks to avoid UI freeze
    -- Previously this was a synchronous loop causing 3-8 second freeze
    M.compute_stats_async(function()
      -- local stats_done = vim.loop.hrtime()
      -- print(string.format("[" .. get_timestamp() .. "] [Pipeline] [%.3fs] Stats complete, starting compute_pass_changes", (stats_done - setup_start) / 1e9))

      -- Update message
      vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'modifiable', true)
      vim.api.nvim_buf_set_lines(M.state.pass_list_bufnr, 3, 4, false, {
        "⏳ Computing pass changes...",
      })
      vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'modifiable', false)

      -- Pre-compute which passes actually changed IR (async with callback)
      M.compute_pass_changes(function()
        local changes_done = vim.loop.hrtime()
        -- print(string.format("[" .. get_timestamp() .. "] [Pipeline] [%.3fs] Pass changes complete, finding first changed", (changes_done - setup_start) / 1e9))

        -- IMPORTANT: Clear grouped_passes cache so has_changes is recomputed with updated pass.changed values
        -- Without this, has_changes may be stale from earlier (pre-compute_pass_changes) grouping
        M.state.grouped_passes = nil

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

        -- local t = (vim.loop.hrtime() - setup_start) / 1e9
        -- print(string.format("[" .. get_timestamp() .. "] [Pipeline] [%.3fs] Building pass list...", t))

        -- Populate pass list
        M.populate_pass_list()

        -- t = (vim.loop.hrtime() - setup_start) / 1e9
        -- print(string.format("[" .. get_timestamp() .. "] [Pipeline] [%.3fs] Loading initial diff...", t))

        -- Show initial diff
        M.show_diff(M.state.current_index)

        -- Position cursor on first pass entry (header + separator + blank + first pass = line 4)
        pcall(vim.api.nvim_win_set_cursor, M.state.pass_list_winid, {4, 0})

        -- t = (vim.loop.hrtime() - setup_start) / 1e9
        -- print(string.format("[" .. get_timestamp() .. "] [Pipeline] [%.3fs] ✓ Ready", t))
      end)
    end)
  end)
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
      local changed_count = 0
      local total_count = #group.functions

      -- DEBUG: Detailed logging for each function in the group
      local all_fn_info = {}
      for _, fn in ipairs(group.functions) do
        local pass_changed = M.state.passes[fn.original_index].changed
        table.insert(all_fn_info, string.format("%s=%s", fn.target, tostring(pass_changed)))
        if pass_changed then
          has_changes = true
          changed_count = changed_count + 1
        end
      end

      group.has_changes = has_changes  -- Store for highlighting
      group.folded = true  -- Always start folded

      -- DEBUG: Print ALL functions in small groups (<=5), sample for larger groups
      if total_count <= 5 then
        -- print(string.format("[DEBUG] Group '%s' has_changes=%s (%d/%d changed): [%s]",
        --   group.pass_name, tostring(has_changes), changed_count, total_count,
        --   table.concat(all_fn_info, ", ")))
      elseif total_count > 0 and not has_changes then
        -- For large groups showing as unchanged, sample first 5 functions
        local sample = {}
        for i = 1, math.min(5, total_count) do
          table.insert(sample, all_fn_info[i])
        end
        -- print(string.format("[DEBUG] Group '%s' marked UNCHANGED but has %d functions: [%s...]",
          -- group.pass_name, total_count, table.concat(sample, ", ")))
      elseif has_changes then
        -- print(string.format("[DEBUG] Group '%s' marked CHANGED (%d/%d functions)",
          -- group.pass_name, changed_count, total_count))
      end

      -- Sort functions within group: changed first, then by original order
      table.sort(group.functions, function(a, b)
        local a_changed = M.state.passes[a.original_index].changed
        local b_changed = M.state.passes[b.original_index].changed

        -- If one has changes and the other doesn't, changed comes first
        if a_changed ~= b_changed then
          return a_changed
        end

        -- Otherwise, sort by original order (index in pipeline)
        return a.original_index < b.original_index
      end)
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

  local groups = M.state.grouped_passes
  local lines = {}
  local line_map = {}  -- Map line number -> {type, group_idx, fn_idx, original_index}
  local header = string.format("Optimization Pipeline (%d passes, %d groups)", #M.state.passes, #groups)
  table.insert(lines, header)
  line_map[#lines] = {type = "header"}

  table.insert(lines, string.rep("-", #header))
  line_map[#lines] = {type = "separator"}

  table.insert(lines, "")
  line_map[#lines] = {type = "blank"}

  -- Calculate number width based on total groups (store for reuse)
  M.state.num_width = #tostring(#groups)
  local num_width = M.state.num_width

  for group_idx, group in ipairs(groups) do
    if group.type == "module" then
      -- Single module pass
      local pass = group.pass
      local i = group.original_index
      local marker = (i == M.state.current_index) and ">" or " "

      local line = string.format("%s%"..num_width.."d. [M] %s", marker, group.display_index, pass.name)
      table.insert(lines, line)
      line_map[#lines] = {type = "module", group_idx = group_idx, original_index = i}

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
            line_map[#lines] = {type = "module_stats", group_idx = group_idx, original_index = i}
          end
        elseif pass.changed and pass.diff_stats and pass.diff_stats.lines_changed > 0 then
          table.insert(lines, string.format("     D: Δ%d lines", pass.diff_stats.lines_changed))
          line_map[#lines] = {type = "module_stats", group_idx = group_idx, original_index = i}
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
      local line = string.format("%s%"..num_width.."d. %s [%s] %s (%d %s)",
        marker, group.display_index, fold_icon, scope_icon, group.pass_name, func_count,
        func_count == 1 and "function" or "functions")
      table.insert(lines, line)
      line_map[#lines] = {type = "group_header", group_idx = group_idx}

      -- If unfolded, show function list
      if not group.folded then
        for fn_idx, fn in ipairs(group.functions) do
          local fn_marker = (fn.original_index == M.state.current_index and not M.state.on_group_header) and "●" or " "
          -- Indent based on num_width: marker(1) + num_width + ". "(2) = total indent
          local indent = string.rep(" ", 1 + num_width + 2)
          local fn_line = string.format("%s%s   %s", indent, fn_marker, fn.target)
          table.insert(lines, fn_line)
          line_map[#lines] = {type = "function_entry", group_idx = group_idx, fn_idx = fn_idx, original_index = fn.original_index}

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
                line_map[#lines] = {type = "function_stats", group_idx = group_idx, fn_idx = fn_idx, original_index = fn.original_index}
              end
            elseif pass.changed and pass.diff_stats and pass.diff_stats.lines_changed > 0 then
              table.insert(lines, string.format("       D: Δ%d lines", pass.diff_stats.lines_changed))
              line_map[#lines] = {type = "function_stats", group_idx = group_idx, fn_idx = fn_idx, original_index = fn.original_index}
            end
          end
        end
      end
    end
  end

  table.insert(lines, "")
  line_map[#lines] = {type = "footer"}
  table.insert(lines, "Legend: [M]=Module [F]=Function [C]=CGSCC")
  line_map[#lines] = {type = "footer"}
  table.insert(lines, "Keys: j/k=nav, Tab/S-Tab=changed-only, Enter/o=fold, q=quit")
  line_map[#lines] = {type = "footer"}

  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(M.state.pass_list_bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'modifiable', false)

  -- Store line_map in state for select_pass_for_viewing to use
  M.state.pass_list_line_map = line_map

  -- Apply syntax highlighting
  M.apply_pass_list_highlights()

  -- Update selection highlighting
  M.update_selection_highlighting()
end

-- Setup custom highlight groups for pipeline viewer
local function setup_highlight_groups()
  local bg = vim.o.background

  -- Fold icons
  vim.api.nvim_set_hl(0, "GodboltPipelineFoldIcon", {link = "Special"})

  -- Group headers (function/CGSCC groups) - use same color as module pass names
  vim.api.nvim_set_hl(0, "GodboltPipelineGroupHeader", {link = "Identifier"})
  if bg == "dark" then
    vim.api.nvim_set_hl(0, "GodboltPipelineGroupCount", {fg = "#88c0d0", italic = true})
  else
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
-- This applies STATIC highlighting only (pass numbers, scopes, names)
-- Selection highlighting is handled separately in update_pass_list_cursor()
function M.apply_pass_list_highlights()
  local bufnr = M.state.pass_list_bufnr
  local ns_id = M.state.ns_id
  local line_map = M.state.pass_list_line_map
  local groups = M.state.grouped_passes

  if not line_map or not groups then
    return
  end

  setup_highlight_groups()
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  local num_width = M.state.num_width  -- Use cached value
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  for line_idx = 1, line_count do
    local line_num = line_idx - 1  -- 0-indexed for API
    local info = line_map[line_idx]

    if not info then
      -- No line_map entry, skip
    elseif info.type == "header" then
      vim.hl.range(bufnr, ns_id, "Title", {line_num, 0}, {line_num, -1})

    elseif info.type == "separator" then
      vim.hl.range(bufnr, ns_id, "Comment", {line_num, 0}, {line_num, -1})

    elseif info.type == "blank" then
      -- No highlighting

    elseif info.type == "footer" then
      vim.hl.range(bufnr, ns_id, "Comment", {line_num, 0}, {line_num, -1})

    elseif info.type == "module_stats" or info.type == "function_stats" then
      vim.hl.range(bufnr, ns_id, "Comment", {line_num, 0}, {line_num, -1})

    elseif info.type == "module" then
      -- Module pass line: " 1. [M] PassName"
      local pass = M.state.passes[info.original_index]

      -- Pass number (skip marker at column 0)
      -- Format: ">NNN." where N is digit, marker is col 0, first digit starts at col 1
      local num_start = 1
      local num_end = num_start + num_width  -- exclusive
      vim.hl.range(bufnr, ns_id, "GodboltPipelinePassNumber", {line_num, num_start}, {line_num, num_end})

      -- Get line content for pattern matching
      local line = vim.api.nvim_buf_get_lines(bufnr, line_num, line_num + 1, false)[1]

      -- [M] scope indicator - search for it
      local scope_col = line:find("%[M%]")
      if scope_col then
        -- scope_col is 1-indexed position of '[', highlight '[M]' (3 chars), exclusive end
        vim.hl.range(bufnr, ns_id, "GodboltPipelineScopeModule", {line_num, scope_col - 1}, {line_num, scope_col + 2})
      end

      -- Pass name starts after "[M] "
      local name_start = scope_col and (scope_col + 3) or (1 + num_width + 3)  -- after ". [M] "
      if pass.changed then
        -- Look for " on " to split highlighting
        local on_pos = line:find(" on ", name_start, true)
        if on_pos then
          vim.hl.range(bufnr, ns_id, "GodboltPipelinePassName", {line_num, name_start}, {line_num, on_pos - 1})
          vim.hl.range(bufnr, ns_id, "Special", {line_num, on_pos - 1}, {line_num, on_pos + 3})
          vim.hl.range(bufnr, ns_id, "String", {line_num, on_pos + 3}, {line_num, -1})
        else
          vim.hl.range(bufnr, ns_id, "GodboltPipelinePassName", {line_num, name_start}, {line_num, -1})
        end
      else
        vim.hl.range(bufnr, ns_id, "GodboltPipelineUnchanged", {line_num, name_start}, {line_num, -1})
      end

    elseif info.type == "group_header" then
      -- Group header: " 109. ▸ [F] PassName (N functions)"
      local group = groups[info.group_idx]

      -- Pass number (skip marker at column 0)
      local num_start = 1
      local num_end = num_start + num_width  -- exclusive
      vim.hl.range(bufnr, ns_id, "GodboltPipelinePassNumber", {line_num, num_start}, {line_num, num_end})

      -- Fold icon ▸ or ▾ - UTF-8 char is 3 bytes
      -- Position: after ">NNN. " = 1 + num_width + 2
      local fold_start = 1 + num_width + 2
      local fold_end = fold_start + 3  -- 3 bytes, exclusive end
      vim.hl.range(bufnr, ns_id, "GodboltPipelineFoldIcon", {line_num, fold_start}, {line_num, fold_end})

      -- Scope indicator [F] or [C]
      -- Position: after ">NNN. ▸ " = 1 + num_width + 2 + 3 + 1 = num_width + 7
      local scope_start = 1 + num_width + 2 + 3 + 1
      local scope_end = scope_start + 3  -- "[F]" is 3 chars, exclusive end
      local scope_hl = group.scope_type == "cgscc" and "GodboltPipelineScopeCGSCC" or "GodboltPipelineScopeFunction"
      vim.hl.range(bufnr, ns_id, scope_hl, {line_num, scope_start}, {line_num, scope_end})

      -- Pass name starts after ">NNN. ▸ [F] "
      local name_start = scope_end + 1

      -- Get line content for pattern matching
      local line = vim.api.nvim_buf_get_lines(bufnr, line_num, line_num + 1, false)[1]

      local count_col = line:find(" %(", name_start, true)
      if count_col then
        -- Highlight pass name up to " ("
        vim.hl.range(bufnr, ns_id, "GodboltPipelineGroupHeader", {line_num, name_start}, {line_num, count_col - 1})
        -- Highlight count " (N functions)"
        vim.hl.range(bufnr, ns_id, "GodboltPipelineGroupCount", {line_num, count_col - 1}, {line_num, -1})
      else
        vim.hl.range(bufnr, ns_id, "GodboltPipelineGroupHeader", {line_num, name_start}, {line_num, -1})
      end

      -- Gray out if no changes
      if not group.has_changes then
        vim.hl.range(bufnr, ns_id, "GodboltPipelineUnchanged", {line_num, name_start}, {line_num, -1})
      end

    elseif info.type == "function_entry" then
      -- Function entry: "      ●   functionName" or "          functionName"
      -- Note: marker can be ● (3 UTF-8 bytes) or space (1 byte), affecting alignment
      local pass = M.state.passes[info.original_index]

      -- Get line to determine marker type
      local line = vim.api.nvim_buf_get_lines(bufnr, line_num, line_num + 1, false)[1]

      local fn_marker_col = 1 + num_width + 2
      -- Check if marker is ● (UTF-8 starts with 0xE2) or space
      local marker_byte = line:byte(fn_marker_col + 1)  -- +1 for 1-indexed Lua strings
      local marker_is_bullet = marker_byte == 0xE2

      -- Calculate name start: marker_col + marker_size + 3 spaces
      local name_start = marker_is_bullet and (fn_marker_col + 3 + 3) or (fn_marker_col + 1 + 3)

      local highlight_group = pass.changed and "GodboltPipelinePassName" or "GodboltPipelineUnchanged"
      vim.hl.range(bufnr, ns_id, highlight_group, {line_num, name_start}, {line_num, -1})
    end
  end
end

-- Update selection highlighting for the currently selected pass
-- This is called from update_pass_list_cursor() when the selection changes
-- Uses a separate namespace so we can clear/update it without touching static highlights
function M.update_selection_highlighting()
  local bufnr = M.state.pass_list_bufnr
  local ns_sel = M.state.ns_selection
  local line_map = M.state.pass_list_line_map
  local groups = M.state.grouped_passes

  if not line_map or not groups then
    return
  end

  -- Clear all previous selection highlighting
  vim.api.nvim_buf_clear_namespace(bufnr, ns_sel, 0, -1)

  local num_width = M.state.num_width  -- Use cached value

  -- Find the line(s) to highlight based on current_index
  for line_idx, info in pairs(line_map) do
    local line_num = line_idx - 1  -- 0-indexed

    if info.type == "module" and info.original_index == M.state.current_index then
      -- Highlight the > marker at column 0 (single char, exclusive end = 1)
      vim.hl.range(bufnr, ns_sel, "GodboltPipelineSelectedMarker", {line_num, 0}, {line_num, 1})
      break

    elseif info.type == "group_header" then
      -- Check if this group contains the selected function
      local group = groups[info.group_idx]
      if group and (group.type == "function_group" or group.type == "cgscc_group") then
        for _, fn in ipairs(group.functions or {}) do
          if fn.original_index == M.state.current_index then
            -- Highlight the > marker at column 0 (single char, exclusive end = 1)
            vim.hl.range(bufnr, ns_sel, "GodboltPipelineSelectedMarker", {line_num, 0}, {line_num, 1})
            goto done  -- Found it, stop searching
          end
        end
      end

    elseif info.type == "function_entry" and info.original_index == M.state.current_index and not M.state.on_group_header then
      -- Highlight the ● marker (3 UTF-8 bytes, exclusive end)
      local fn_marker_col = 1 + num_width + 2
      vim.hl.range(bufnr, ns_sel, "GodboltPipelineSelectedMarker", {line_num, fn_marker_col}, {line_num, fn_marker_col + 3})
      break
    end
  end

  ::done::
end

-- Pre-compute statistics for all passes asynchronously in chunks
-- OPTIMIZATION: Previously this was synchronous causing 3-8 second UI freeze
-- Sets pass.stats for each pass
function M.compute_stats_async(callback)
  local total_passes = #M.state.passes
  local chunk_size = 100  -- Larger chunks than compute_pass_changes since stats are simpler
  local start_time = vim.loop.hrtime()
  local last_print_time = start_time

  local function process_chunk(chunk_start)
    -- Check if we're done
    if chunk_start > total_passes then
      if callback then callback() end
      return
    end

    local chunk_end = math.min(chunk_start + chunk_size - 1, total_passes)

    -- Show progress every 2 seconds
    local current_time = vim.loop.hrtime()
    local elapsed_since_print = (current_time - last_print_time) / 1e9
    if chunk_start > 1 and elapsed_since_print >= 2.0 then
      local total_elapsed = (current_time - start_time) / 1e9
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] [%.3fs] Computing statistics... (%d/%d passes)",
        total_elapsed, chunk_end, total_passes))
      last_print_time = current_time
      vim.cmd('redraw')  -- Force UI update
    end

    -- Process this chunk synchronously
    for index = chunk_start, chunk_end do
      local pass = M.state.passes[index]
      pass.stats = stats.count(pass.ir)
    end

    -- Schedule next chunk (yields to event loop for UI responsiveness)
    vim.schedule(function()
      process_chunk(chunk_start + chunk_size)
    end)
  end

  -- Start processing first chunk
  process_chunk(1)
end

-- Compute a hash of IR lines for efficient change detection
-- This is more reliable than line count comparison
local function compute_ir_hash(ir_lines)
  if not ir_lines or #ir_lines == 0 then
    return 0
  end

  -- Concatenate all lines and compute hash
  local content = table.concat(ir_lines, "\n")

  -- Simple hash function using Lua's string hashing
  local hash = 0
  for i = 1, #content do
    hash = (hash * 31 + string.byte(content, i)) % 2147483647
  end

  return hash
end

-- Pre-compute which passes actually changed IR
-- Sets pass.changed (boolean) and pass.diff_stats (table) for each pass
-- Now fully async with callback to avoid UI freeze on large pass counts
function M.compute_pass_changes(callback)
  local ir_utils = require('godbolt.ir_utils')
  local pipeline = require('godbolt.pipeline')
  local total_passes = #M.state.passes
  local chunk_size = 50  -- Process in chunks
  local start_time = vim.loop.hrtime()
  local last_print_time = start_time

  local function process_chunk(chunk_start)
    -- Check if we're done
    if chunk_start > total_passes then
      -- DEBUG: Print summary of changed/unchanged passes
      local changed_count = 0
      local unchanged_count = 0
      local nil_count = 0
      for _, pass in ipairs(M.state.passes) do
        if pass.changed == true then
          changed_count = changed_count + 1
        elseif pass.changed == false then
          unchanged_count = unchanged_count + 1
        else
          nil_count = nil_count + 1
        end
      end
      print(string.format("[DEBUG] compute_pass_changes COMPLETE: %d changed, %d unchanged, %d nil (total %d)",
        changed_count, unchanged_count, nil_count, total_passes))

      if callback then callback() end
      return
    end

    local chunk_end = math.min(chunk_start + chunk_size - 1, total_passes)

    -- Show progress every 2 seconds
    local current_time = vim.loop.hrtime()
    local elapsed_since_print = (current_time - last_print_time) / 1e9
    if chunk_start > 1 and elapsed_since_print >= 2.0 then
      local total_elapsed = (current_time - start_time) / 1e9
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] [%.3fs] Computing pass changes... (%d/%d passes)",
        total_elapsed, chunk_end, total_passes))
      last_print_time = current_time
      vim.cmd('redraw')  -- Force UI update
    end

    -- Process this chunk synchronously
    for index = chunk_start, chunk_end do
      local pass = M.state.passes[index]

      -- OPTIMIZATION: Skip expensive IR comparison for passes pre-marked as unchanged (--print-changed)
      -- However, we still need to verify with hash comparison since LLVM may include metadata
      if pass.changed == false then
        -- Pass was omitted by LLVM (--print-changed), but verify with hash
        local before_ir = pass.before_ir or M.get_before_ir_for_pass(index)
        local after_ir = pass.ir

        -- Apply same filtering as display
        if M.state.config and M.state.config.display and M.state.config.display.strip_debug_metadata then
          before_ir = select(1, ir_utils.filter_debug_metadata(before_ir))
          after_ir = select(1, ir_utils.filter_debug_metadata(after_ir))
        end

        -- Use hash comparison for efficiency
        local before_hash = compute_ir_hash(before_ir)
        local after_hash = compute_ir_hash(after_ir)

        if before_hash == after_hash then
          -- Truly unchanged
          pass.changed = false
          pass.diff_stats = {
            lines_changed = 0,
            lines_before = #before_ir,
            lines_after = #after_ir,
          }
        else
          -- Hash mismatch - LLVM's --print-changed optimization was wrong
          -- Fall through to full comparison below
          pass.changed = nil  -- Reset so we do full comparison
        end

        if pass.changed == false then
          goto continue
        end
      end

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

      -- Use hash comparison first for efficiency
      local before_hash = compute_ir_hash(before_ir)
      local after_hash = compute_ir_hash(after_ir)

      local changed = false
      local lines_changed = 0

      if before_hash == after_hash then
        -- Hashes match - IR is identical
        changed = false
        lines_changed = 0
      else
        -- Hashes differ - need to count changed lines
        changed = true
        local max_lines = math.max(#before_ir, #after_ir)

        -- Count different lines
        for i = 1, max_lines do
          local before_line = before_ir[i] or ""
          local after_line = after_ir[i] or ""
          if before_line ~= after_line then
            lines_changed = lines_changed + 1
          end
        end
      end

      pass.changed = changed
      pass.diff_stats = {
        lines_changed = lines_changed,
        lines_before = #before_ir,
        lines_after = #after_ir,
      }

      -- DEBUG: Log a sample of changed passes to verify detection is working
      if changed and index % 100 == 0 then  -- Log every 100th changed pass to avoid spam
        print(string.format("[DEBUG] Pass %d '%s' marked as CHANGED (lines_changed=%d, before=%d, after=%d)",
          index, pass.name, lines_changed, #before_ir, #after_ir))
      end

      ::continue::
    end

    -- Schedule next chunk (yields to event loop for UI responsiveness)
    vim.schedule(function()
      process_chunk(chunk_start + chunk_size)
    end)
  end

  -- Start processing first chunk
  process_chunk(1)
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
    -- OPTIMIZATION: Use module_pass_indices for O(1) lookup instead of O(n) scan
    if M.state.module_pass_indices then
      -- Binary search or linear search through index to find last module pass before current
      local last_module_idx = nil
      for _, mod_idx in ipairs(M.state.module_pass_indices) do
        if mod_idx >= index then
          break
        end
        last_module_idx = mod_idx
      end

      if last_module_idx then
        return M.state.passes[last_module_idx].ir
      end
    else
      -- Fallback to old O(n) scan if index not built
      for i = index - 1, 1, -1 do
        if M.state.passes[i].scope_type == "module" then
          return M.state.passes[i].ir
        end
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
      -- OPTIMIZATION: Use module_pass_indices for O(1) lookup
      if M.state.module_pass_indices then
        local last_module_idx = nil
        for _, mod_idx in ipairs(M.state.module_pass_indices) do
          if mod_idx >= index then
            break
          end
          last_module_idx = mod_idx
        end

        if last_module_idx then
          return ir_utils.extract_function(M.state.passes[last_module_idx].ir, func_name)
        end
      else
        -- Fallback to old O(n) scan
        for i = index - 1, 1, -1 do
          if M.state.passes[i].scope_type == "module" then
            return ir_utils.extract_function(M.state.passes[i].ir, func_name)
          end
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
  local info = debug.getinfo(2, "Sl")
  local caller = string.format("%s:%d", info.short_src:match("([^/]+)$") or info.short_src, info.currentline)
  if #M.state.passes == 0 then
    return
  end

  -- Clamp index
  index = math.max(1, math.min(index, #M.state.passes))

  -- Save old index BEFORE updating (needed for marker removal)
  local old_index = M.state.current_index

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
  M.update_pass_list_cursor(old_index, index)

  -- Print stats
  if M.state.config.show_stats then
    M.show_stats(index)
  end

  -- Set up line mapping between source and after IR (if source buffer exists)
  if M.state.source_bufnr and vim.api.nvim_buf_is_valid(M.state.source_bufnr) then
    -- Clean up previous line mapping
    line_map.cleanup()

    -- Set up line mapping with auto-scroll enabled and quiet mode
    local line_map_config = M.state.config.line_mapping or {}
    line_map_config.auto_scroll = true  -- Force auto-scroll in pipeline viewer
    line_map_config.quiet = true  -- Suppress "no mappings" warnings (expected for many passes)

    -- Store full IR for line mapping
    vim.b[M.state.after_bufnr].godbolt_full_output = after_ir

    line_map.setup(M.state.source_bufnr, M.state.after_bufnr, "llvm", line_map_config)
  end
end

-- Update the cursor marker in pass list
-- IMPORTANT: indices are ORIGINAL indices in M.state.passes, NOT display_index!
-- @param old_index: previous current_index (to remove old markers)
-- @param new_index: new current_index (to add new markers)
function M.update_pass_list_cursor(old_index, new_index)
  -- Update selection highlighting (uses separate namespace, very fast)
  M.update_selection_highlighting()

  -- Move cursor to the selected line
  local line_map = M.state.pass_list_line_map
  if not line_map then return end

  -- Find the line corresponding to new_index
  for line_idx, info in pairs(line_map) do
    if info.type == "module" and info.original_index == new_index then
      pcall(vim.api.nvim_win_set_cursor, M.state.pass_list_winid, {line_idx, 0})
      return
    elseif info.type == "function_entry" and info.original_index == new_index then
      -- If on group header, move to group header; otherwise move to function entry
      if M.state.on_group_header then
        -- Find the group header for this function
        for header_line_idx, header_info in pairs(line_map) do
          if header_info.type == "group_header" and header_info.group_idx == info.group_idx then
            pcall(vim.api.nvim_win_set_cursor, M.state.pass_list_winid, {header_line_idx, 0})
            return
          end
        end
      else
        pcall(vim.api.nvim_win_set_cursor, M.state.pass_list_winid, {line_idx, 0})
        return
      end
    end
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
  local line_map = M.state.pass_list_line_map

  if not line_map then return false end

  -- Use line_map to check if this is a group header
  local line_info = line_map[line_num]
  if not line_info or line_info.type ~= "group_header" then
    return false
  end

  -- Get the group and toggle fold state
  local groups = M.state.grouped_passes
  local group = groups[line_info.group_idx]
  if not group or (group.type ~= "function_group" and group.type ~= "cgscc_group") then
    return false
  end

  group.folded = not group.folded
  M.populate_pass_list()  -- Rebuild display

  -- Find the group header line again after rebuild using line_map
  local line_map_updated = M.state.pass_list_line_map
  for i, updated_info in pairs(line_map_updated) do
    if updated_info.type == "group_header" and updated_info.group_idx == line_info.group_idx then
      -- Found the group header, move cursor there
      pcall(vim.api.nvim_win_set_cursor, M.state.pass_list_winid, {i, 0})
      return true
    end
  end

  return true
end

-- Fold the parent group when cursor is on a function entry
function M.fold_parent_group_under_cursor()
  local cursor = vim.api.nvim_win_get_cursor(M.state.pass_list_winid)
  local line_num = cursor[1]
  local line_map = M.state.pass_list_line_map

  if not line_map then return false end

  -- Get current line info
  local line_info = line_map[line_num]
  if not line_info or line_info.type ~= "function_entry" then
    return false
  end

  -- Look backwards in line_map to find the parent group header
  for i = line_num - 1, 1, -1 do
    local prev_info = line_map[i]
    if prev_info and prev_info.type == "group_header" then
      -- Found the parent group header
      local groups = M.state.grouped_passes
      local group = groups[prev_info.group_idx]
      if group and (group.type == "function_group" or group.type == "cgscc_group") then
        group.folded = true  -- Always fold (don't toggle)
        M.populate_pass_list()  -- Rebuild display

        -- Move cursor to the folded group header using updated line_map
        local line_map_updated = M.state.pass_list_line_map
        for new_i, updated_info in pairs(line_map_updated) do
          if updated_info.type == "group_header" and updated_info.group_idx == prev_info.group_idx then
            pcall(vim.api.nvim_win_set_cursor, M.state.pass_list_winid, {new_i, 0})
            -- Update view to show group header state (cleared buffers)
            M.select_pass_for_viewing()
            return true
          end
        end

        return true
      end
    end
  end

  return false
end

-- Navigate to next pass line in the pass list
local function goto_next_pass_line()
  local cursor = vim.api.nvim_win_get_cursor(M.state.pass_list_winid)
  local current_line = cursor[1]
  local line_map = M.state.pass_list_line_map

  if not line_map then return end

  -- Find next selectable line using line_map
  local total_lines = vim.api.nvim_buf_line_count(M.state.pass_list_bufnr)
  for i = current_line + 1, total_lines do
    local line_info = line_map[i]
    if line_info and (line_info.type == "module" or
                      line_info.type == "group_header" or
                      line_info.type == "function_entry") then
      -- Found selectable line - move there
      vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {i, 0})

      -- Update current_index and render
      M.select_pass_for_viewing()

      return
    end
  end
end

-- Navigate to previous pass line in the pass list
local function goto_prev_pass_line()
  local cursor = vim.api.nvim_win_get_cursor(M.state.pass_list_winid)
  local current_line = cursor[1]
  local line_map = M.state.pass_list_line_map

  if not line_map then
    return
  end

  -- Find previous selectable line using line_map
  for i = current_line - 1, 1, -1 do
    local line_info = line_map[i]
    if line_info and (line_info.type == "module" or
                      line_info.type == "group_header" or
                      line_info.type == "function_entry") then
      -- Found selectable line - move there
      vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {i, 0})

      -- Update current_index and render
      M.select_pass_for_viewing()

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
  local line_map = M.state.pass_list_line_map
  local groups = M.state.grouped_passes

  if not line_map then return end

  -- Find next pass line that corresponds to a changed pass
  local total_lines = vim.api.nvim_buf_line_count(M.state.pass_list_bufnr)
  for i = current_line + 1, total_lines do
    local line_info = line_map[i]
    if not line_info then goto continue end

    if line_info.type == "group_header" then
      -- Check if any function in this group has changes
      local group = groups[line_info.group_idx]
      if group and (group.type == "function_group" or group.type == "cgscc_group") and group.functions then
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
          local line_map_updated = M.state.pass_list_line_map
          for line_idx, updated_info in pairs(line_map_updated) do
            if updated_info.type == "function_entry" and
               updated_info.original_index == first_changed_fn.original_index then
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

    elseif line_info.type == "module" then
      -- Check if this module pass is changed
      if is_pass_changed(line_info.original_index) then
        vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {i, 0})
        M.select_pass_for_viewing()
        return
      end

    elseif line_info.type == "function_entry" then
      -- Check if this function pass is changed
      if is_pass_changed(line_info.original_index) then
        vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {i, 0})
        M.select_pass_for_viewing()
        return
      end
    end

    ::continue::
  end
end

-- Navigate to previous changed pass line (smart Shift-Tab navigation)
local function goto_prev_changed_pass_line()
  if not M.state.grouped_passes or #M.state.grouped_passes == 0 then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(M.state.pass_list_winid)
  local current_line = cursor[1]
  local line_map = M.state.pass_list_line_map
  local groups = M.state.grouped_passes

  if not line_map then return end

  -- Find previous pass line that corresponds to a changed pass
  for i = current_line - 1, 1, -1 do
    local line_info = line_map[i]
    if not line_info then goto continue end

    if line_info.type == "group_header" then
      -- Check if any function in this group has changes
      local group = groups[line_info.group_idx]
      if group and (group.type == "function_group" or group.type == "cgscc_group") and group.functions then
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
          local line_map_updated = M.state.pass_list_line_map
          for line_idx, updated_info in pairs(line_map_updated) do
            if updated_info.type == "function_entry" and
               updated_info.original_index == first_changed_fn.original_index then
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

    elseif line_info.type == "module" then
      -- Check if this module pass is changed
      if is_pass_changed(line_info.original_index) then
        vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {i, 0})
        M.select_pass_for_viewing()
        return
      end

    elseif line_info.type == "function_entry" then
      -- Check if this function pass is changed
      if is_pass_changed(line_info.original_index) then
        vim.api.nvim_win_set_cursor(M.state.pass_list_winid, {i, 0})
        M.select_pass_for_viewing()
        return
      end
    end

    ::continue::
  end
end

-- Select pass for viewing (used by j/k navigation)
-- This version NEVER toggles folds, only shows diffs
function M.select_pass_for_viewing()
  local cursor = vim.api.nvim_win_get_cursor(M.state.pass_list_winid)
  local line_num = cursor[1]

  -- Use line_map instead of parsing rendered text
  local line_info = M.state.pass_list_line_map and M.state.pass_list_line_map[line_num]

  if not line_info then
    return
  end

  local groups = M.state.grouped_passes

  if line_info.type == "group_header" then
    -- On a group header: set current_index to first function and clear buffers
    local group = groups[line_info.group_idx]
    if group and (group.type == "function_group" or group.type == "cgscc_group") and group.functions and #group.functions > 0 then
      local old_index = M.state.current_index
      M.state.current_index = group.functions[1].original_index
      M.state.on_group_header = true  -- Don't show function marker

      -- Clear both buffers
      vim.api.nvim_buf_set_option(M.state.before_bufnr, 'modifiable', true)
      vim.api.nvim_buf_set_lines(M.state.before_bufnr, 0, -1, false, {})
      vim.api.nvim_buf_set_option(M.state.before_bufnr, 'modifiable', false)

      vim.api.nvim_buf_set_option(M.state.after_bufnr, 'modifiable', true)
      vim.api.nvim_buf_set_lines(M.state.after_bufnr, 0, -1, false, {})
      vim.api.nvim_buf_set_option(M.state.after_bufnr, 'modifiable', false)

      -- Update buffer names
      local fold_state = group.folded and " (folded)" or " (unfolded)"
      pcall(vim.api.nvim_buf_set_name, M.state.before_bufnr,
        string.format("Group: %s%s", group.pass_name, fold_state))
      pcall(vim.api.nvim_buf_set_name, M.state.after_bufnr,
        string.format("%d functions", #group.functions))

      -- Update markers to remove function marker
      M.update_pass_list_cursor(old_index, M.state.current_index)
    end
    return

  elseif line_info.type == "function_entry" then
    -- On a function entry: show diff for that function
    M.state.on_group_header = false  -- Clear flag
    M.show_diff(line_info.original_index)
    return

  elseif line_info.type == "module" then
    -- On a module pass: show diff
    M.state.on_group_header = false  -- Clear flag
    M.show_diff(line_info.original_index)
    return
  end

  -- For header/separator/footer/blank lines, do nothing
end

-- Activate line under cursor (used by Enter key)
-- This version toggles folds for group headers, shows diffs for everything else
function M.activate_line_under_cursor()
  local cursor = vim.api.nvim_win_get_cursor(M.state.pass_list_winid)
  local line_num = cursor[1]
  local line_map = M.state.pass_list_line_map

  if not line_map then return end

  -- Use line_map to determine line type
  local line_info = line_map[line_num]
  if not line_info then
    return
  end

  if line_info.type == "group_header" then
    -- For Enter key on group header: toggle fold
    M.toggle_fold_under_cursor()
    return
  end

  if line_info.type == "function_entry" then
    -- For Enter key on function entry: fold the parent group
    M.fold_parent_group_under_cursor()
    return
  end

  -- For module passes, show diff
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

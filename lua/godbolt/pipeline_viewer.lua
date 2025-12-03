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
  input_file = nil, -- Path to input .ll file
  pass_list_bufnr = nil,
  before_bufnr = nil,
  after_bufnr = nil,
  pass_list_winid = nil,
  before_winid = nil,
  after_winid = nil,
  config = nil,
  ns_id = vim.api.nvim_create_namespace('godbolt_pipeline'),
  ns_selection = vim.api.nvim_create_namespace('godbolt_pipeline_selection'), -- Separate namespace for selection highlighting
  ns_hints = vim.api.nvim_create_namespace('godbolt_remarks_hints'),          -- Namespace for inline hints
  inline_hints_enabled = true,                                                -- Track if inline hints are currently shown
  grouped_passes = nil,                                                       -- Grouped/folded pass structure
  module_pass_indices = nil,                                                  -- OPTIMIZATION: Index of module pass positions {5, 23, 107, ...}
  on_group_header = false,                                                    -- Track if we're on a group header (don't show function marker)
  num_width = nil,                                                            -- Width of pass numbers (computed once from #groups)
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
    start_at_final = false, -- Start at first pass to see initial changes
    filter_unchanged = false,
  }
  config = vim.tbl_deep_extend("force", default_config, config)

  -- Check if loaded from session
  if config.loaded_from_session and config.session_metadata then
    vim.notify(string.format(
      "[Pipeline] Loaded session: %s (%d passes)",
      config.session_metadata.name or os.date("%Y-%m-%d %H:%M", config.session_metadata.timestamp),
      #passes
    ))
  end

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

  -- Store additional metadata for session saving
  M.state.source_file = input_file  -- The LLVM IR input file
  M.state.initial_ir = passes[1] and passes[1]._initial_ir or nil  -- Extract initial IR
  M.state.opt_level = config.opt_level  -- Optimization level if available
  M.state.compilation_command = config.compilation_command  -- Original compilation command
  M.state.compiler = config.compiler  -- Compiler used

  -- OPTIMIZATION: Build module pass index for O(1) lookups instead of O(n) scans
  -- This dramatically speeds up get_before_ir_for_pass() for module passes
  M.state.module_pass_indices = {}
  for i, pass in ipairs(passes) do
    if pass.scope_type == "module" then
      table.insert(M.state.module_pass_indices, i)
    end
  end

  M.create_layout()

  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(M.state.pass_list_bufnr, 0, -1, false, {
    string.format("Optimization Pipeline (%d passes)", #passes),
    string.rep("-", 40),
    "",
    "⏳ Computing statistics...",
  })
  vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'modifiable', false)

  M.setup_keymaps()

  vim.schedule(function()
    -- Compute stats asynchronously in chunks to avoid UI freeze
    -- Previously this was a synchronous loop causing 3-8 second freeze
    M.compute_stats_async(function()
      vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'modifiable', true)
      vim.api.nvim_buf_set_lines(M.state.pass_list_bufnr, 3, 4, false, {
        "⏳ Computing pass changes...",
      })
      vim.api.nvim_buf_set_option(M.state.pass_list_bufnr, 'modifiable', false)

      -- Pre-compute which passes actually changed IR (async with callback)
      M.compute_pass_changes(function()
        local changes_done = vim.loop.hrtime()

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

        M.populate_pass_list()

        M.show_diff(M.state.current_index)

        -- Position cursor on first pass entry (header + separator + blank + first pass = line 4)
        pcall(vim.api.nvim_win_set_cursor, M.state.pass_list_winid, { 4, 0 })
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
  local open_groups = {} -- Function groups that can still accept new functions

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
          functions = { {
            target = pass.scope_target,
            pass = pass,
            original_index = i,
          } },
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

      group.has_changes = has_changes -- Store for highlighting
      group.folded = true             -- Always start folded

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
  local line_map = {} -- Map line number -> {type, group_idx, fn_idx, original_index}
  local header = string.format("Optimization Pipeline (%d passes, %d groups)", #M.state.passes, #groups)
  table.insert(lines, header)
  line_map[#lines] = { type = "header" }

  table.insert(lines, string.rep("-", #header))
  line_map[#lines] = { type = "separator" }

  table.insert(lines, "")
  line_map[#lines] = { type = "blank" }

  -- Calculate number width based on total groups (store for reuse)
  M.state.num_width = #tostring(#groups)
  local num_width = M.state.num_width

  for group_idx, group in ipairs(groups) do
    if group.type == "module" then
      -- Single module pass
      local pass = group.pass
      local i = group.original_index
      local marker = (i == M.state.current_index) and ">" or " "

      local line = string.format("%s%" .. num_width .. "d. [M] %s", marker, group.display_index, pass.name)
      table.insert(lines, line)
      line_map[#lines] = { type = "module", group_idx = group_idx, original_index = i }

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
            line_map[#lines] = { type = "module_stats", group_idx = group_idx, original_index = i }
          end
        elseif pass.changed and pass.diff_stats and pass.diff_stats.lines_changed > 0 then
          table.insert(lines, string.format("     D: Δ%d lines", pass.diff_stats.lines_changed))
          line_map[#lines] = { type = "module_stats", group_idx = group_idx, original_index = i }
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
      local line = string.format("%s%" .. num_width .. "d. %s [%s] %s (%d %s)",
        marker, group.display_index, fold_icon, scope_icon, group.pass_name, func_count,
        func_count == 1 and "function" or "functions")
      table.insert(lines, line)
      line_map[#lines] = { type = "group_header", group_idx = group_idx }

      -- If unfolded, show function list
      if not group.folded then
        for fn_idx, fn in ipairs(group.functions) do
          local fn_marker = (fn.original_index == M.state.current_index and not M.state.on_group_header) and "●" or " "
          -- Indent based on num_width: marker(1) + num_width + ". "(2) = total indent
          local indent = string.rep(" ", 1 + num_width + 2)
          local fn_line = string.format("%s%s   %s", indent, fn_marker, fn.target)
          table.insert(lines, fn_line)
          line_map[#lines] = {
            type = "function_entry",
            group_idx = group_idx,
            fn_idx = fn_idx,
            original_index = fn
                .original_index
          }

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
                line_map[#lines] = {
                  type = "function_stats",
                  group_idx = group_idx,
                  fn_idx = fn_idx,
                  original_index = fn
                      .original_index
                }
              end
            elseif pass.changed and pass.diff_stats and pass.diff_stats.lines_changed > 0 then
              table.insert(lines, string.format("       D: Δ%d lines", pass.diff_stats.lines_changed))
              line_map[#lines] = {
                type = "function_stats",
                group_idx = group_idx,
                fn_idx = fn_idx,
                original_index = fn
                    .original_index
              }
            end
          end
        end
      end
    end
  end

  table.insert(lines, "")
  line_map[#lines] = { type = "footer" }
  table.insert(lines, "Legend: [M]=Module [F]=Function [C]=CGSCC")
  line_map[#lines] = { type = "footer" }
  table.insert(lines, "Keys: j/k=nav, R=remarks, gR=all, gh=hints, g?=help, q=quit")
  line_map[#lines] = { type = "footer" }

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
  vim.api.nvim_set_hl(0, "GodboltPipelineFoldIcon", { link = "Special" })

  -- Group headers (function/CGSCC groups) - use same color as module pass names
  vim.api.nvim_set_hl(0, "GodboltPipelineGroupHeader", { link = "Identifier" })
  if bg == "dark" then
    vim.api.nvim_set_hl(0, "GodboltPipelineGroupCount", { fg = "#88c0d0", italic = true })
  else
    vim.api.nvim_set_hl(0, "GodboltPipelineGroupCount", { fg = "#81a1c1", italic = true })
  end

  -- Function entries (indented)
  vim.api.nvim_set_hl(0, "GodboltPipelineFunctionEntry", { link = "String" })

  -- Selected marker
  if bg == "dark" then
    vim.api.nvim_set_hl(0, "GodboltPipelineSelectedMarker", { fg = "#bf616a", bold = true })
  else
    vim.api.nvim_set_hl(0, "GodboltPipelineSelectedMarker", { fg = "#d08770", bold = true })
  end

  -- Pass numbers
  vim.api.nvim_set_hl(0, "GodboltPipelinePassNumber", { link = "Number" })

  -- Scope indicators [M], [F], [C]
  vim.api.nvim_set_hl(0, "GodboltPipelineScopeModule", { link = "Type" })
  vim.api.nvim_set_hl(0, "GodboltPipelineScopeFunction", { link = "Function" })
  vim.api.nvim_set_hl(0, "GodboltPipelineScopeCGSCC", { link = "Keyword" })

  -- Pass names
  vim.api.nvim_set_hl(0, "GodboltPipelinePassName", { link = "Identifier" })

  -- Unchanged passes (grayed out)
  vim.api.nvim_set_hl(0, "GodboltPipelineUnchanged", { link = "Comment" })
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

  local num_width = M.state.num_width -- Use cached value
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  for line_idx = 1, line_count do
    local line_num = line_idx - 1 -- 0-indexed for API
    local info = line_map[line_idx]

    if not info then
      -- No line_map entry, skip
    elseif info.type == "header" then
      vim.hl.range(bufnr, ns_id, "Title", { line_num, 0 }, { line_num, -1 })
    elseif info.type == "separator" then
      vim.hl.range(bufnr, ns_id, "Comment", { line_num, 0 }, { line_num, -1 })
    elseif info.type == "blank" then
      -- No highlighting
    elseif info.type == "footer" then
      vim.hl.range(bufnr, ns_id, "Comment", { line_num, 0 }, { line_num, -1 })
    elseif info.type == "module_stats" or info.type == "function_stats" then
      vim.hl.range(bufnr, ns_id, "Comment", { line_num, 0 }, { line_num, -1 })
    elseif info.type == "module" then
      -- Module pass line: " 1. [M] PassName"
      local pass = M.state.passes[info.original_index]

      -- Pass number (skip marker at column 0)
      -- Format: ">NNN." where N is digit, marker is col 0, first digit starts at col 1
      local num_start = 1
      local num_end = num_start + num_width -- exclusive
      vim.hl.range(bufnr, ns_id, "GodboltPipelinePassNumber", { line_num, num_start }, { line_num, num_end })

      -- Get line content for pattern matching
      local line = vim.api.nvim_buf_get_lines(bufnr, line_num, line_num + 1, false)[1]

      -- [M] scope indicator - search for it
      local scope_col = line:find("%[M%]")
      if scope_col then
        -- scope_col is 1-indexed position of '[', highlight '[M]' (3 chars), exclusive end
        vim.hl.range(bufnr, ns_id, "GodboltPipelineScopeModule", { line_num, scope_col - 1 }, { line_num, scope_col + 2 })
      end

      -- Pass name starts after "[M] "
      local name_start = scope_col and (scope_col + 3) or (1 + num_width + 3) -- after ". [M] "
      if pass.changed then
        -- Look for " on " to split highlighting
        local on_pos = line:find(" on ", name_start, true)
        if on_pos then
          vim.hl.range(bufnr, ns_id, "GodboltPipelinePassName", { line_num, name_start }, { line_num, on_pos - 1 })
          vim.hl.range(bufnr, ns_id, "Special", { line_num, on_pos - 1 }, { line_num, on_pos + 3 })
          vim.hl.range(bufnr, ns_id, "String", { line_num, on_pos + 3 }, { line_num, -1 })
        else
          vim.hl.range(bufnr, ns_id, "GodboltPipelinePassName", { line_num, name_start }, { line_num, -1 })
        end
      else
        vim.hl.range(bufnr, ns_id, "GodboltPipelineUnchanged", { line_num, name_start }, { line_num, -1 })
      end
    elseif info.type == "group_header" then
      -- Group header: " 109. ▸ [F] PassName (N functions)"
      local group = groups[info.group_idx]

      -- Pass number (skip marker at column 0)
      local num_start = 1
      local num_end = num_start + num_width -- exclusive
      vim.hl.range(bufnr, ns_id, "GodboltPipelinePassNumber", { line_num, num_start }, { line_num, num_end })

      -- Fold icon ▸ or ▾ - UTF-8 char is 3 bytes
      -- Position: after ">NNN. " = 1 + num_width + 2
      local fold_start = 1 + num_width + 2
      local fold_end = fold_start + 3 -- 3 bytes, exclusive end
      vim.hl.range(bufnr, ns_id, "GodboltPipelineFoldIcon", { line_num, fold_start }, { line_num, fold_end })

      -- Scope indicator [F] or [C]
      -- Position: after ">NNN. ▸ " = 1 + num_width + 2 + 3 + 1 = num_width + 7
      local scope_start = 1 + num_width + 2 + 3 + 1
      local scope_end = scope_start + 3 -- "[F]" is 3 chars, exclusive end
      local scope_hl = group.scope_type == "cgscc" and "GodboltPipelineScopeCGSCC" or "GodboltPipelineScopeFunction"
      vim.hl.range(bufnr, ns_id, scope_hl, { line_num, scope_start }, { line_num, scope_end })

      -- Pass name starts after ">NNN. ▸ [F] "
      local name_start = scope_end + 1

      -- Get line content for pattern matching
      local line = vim.api.nvim_buf_get_lines(bufnr, line_num, line_num + 1, false)[1]

      local count_col = line:find(" %(", name_start, true)
      if count_col then
        -- Highlight pass name up to " ("
        vim.hl.range(bufnr, ns_id, "GodboltPipelineGroupHeader", { line_num, name_start }, { line_num, count_col - 1 })
        -- Highlight count " (N functions)"
        vim.hl.range(bufnr, ns_id, "GodboltPipelineGroupCount", { line_num, count_col - 1 }, { line_num, -1 })
      else
        vim.hl.range(bufnr, ns_id, "GodboltPipelineGroupHeader", { line_num, name_start }, { line_num, -1 })
      end

      -- Gray out if no changes
      if not group.has_changes then
        vim.hl.range(bufnr, ns_id, "GodboltPipelineUnchanged", { line_num, name_start }, { line_num, -1 })
      end
    elseif info.type == "function_entry" then
      -- Function entry: "      ●   functionName" or "          functionName"
      -- Note: marker can be ● (3 UTF-8 bytes) or space (1 byte), affecting alignment
      local pass = M.state.passes[info.original_index]

      -- Get line to determine marker type
      local line = vim.api.nvim_buf_get_lines(bufnr, line_num, line_num + 1, false)[1]

      local fn_marker_col = 1 + num_width + 2
      -- Check if marker is ● (UTF-8 starts with 0xE2) or space
      local marker_byte = line:byte(fn_marker_col + 1) -- +1 for 1-indexed Lua strings
      local marker_is_bullet = marker_byte == 0xE2

      -- Calculate name start: marker_col + marker_size + 3 spaces
      local name_start = marker_is_bullet and (fn_marker_col + 3 + 3) or (fn_marker_col + 1 + 3)

      local highlight_group = pass.changed and "GodboltPipelinePassName" or "GodboltPipelineUnchanged"
      vim.hl.range(bufnr, ns_id, highlight_group, { line_num, name_start }, { line_num, -1 })
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

  local num_width = M.state.num_width -- Use cached value

  -- Find the line(s) to highlight based on current_index
  for line_idx, info in pairs(line_map) do
    local line_num = line_idx - 1 -- 0-indexed

    if info.type == "module" and info.original_index == M.state.current_index then
      -- Highlight the > marker at column 0 (single char, exclusive end = 1)
      vim.hl.range(bufnr, ns_sel, "GodboltPipelineSelectedMarker", { line_num, 0 }, { line_num, 1 })
      break
    elseif info.type == "group_header" then
      -- Check if this group contains the selected function
      local group = groups[info.group_idx]
      if group and (group.type == "function_group" or group.type == "cgscc_group") then
        for _, fn in ipairs(group.functions or {}) do
          if fn.original_index == M.state.current_index then
            -- Highlight the > marker at column 0 (single char, exclusive end = 1)
            vim.hl.range(bufnr, ns_sel, "GodboltPipelineSelectedMarker", { line_num, 0 }, { line_num, 1 })
            goto done -- Found it, stop searching
          end
        end
      end
    elseif info.type == "function_entry" and info.original_index == M.state.current_index and not M.state.on_group_header then
      -- Highlight the ● marker (3 UTF-8 bytes, exclusive end)
      local fn_marker_col = 1 + num_width + 2
      vim.hl.range(bufnr, ns_sel, "GodboltPipelineSelectedMarker", { line_num, fn_marker_col },
        { line_num, fn_marker_col + 3 })
      break
    end
  end

  ::done::
end

-- Pre-compute statistics for all passes asynchronously in chunks
-- Previously this was synchronous causing 3-8 second UI freeze
-- Sets pass.stats for each pass
function M.compute_stats_async(callback)
  local total_passes = #M.state.passes
  local chunk_size = 100 -- Larger chunks than compute_pass_changes since stats are simpler
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
      vim.cmd('redraw') -- Force UI update
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

-- Pre-compute diff statistics for display purposes
-- The parser already sets pass.changed from --print-changed, so we trust that.
-- This function only computes line-level statistics for UI display.
-- @param callback: function to call when complete
function M.compute_pass_changes(callback)
  local total_passes = #M.state.passes

  for index, pass in ipairs(M.state.passes) do
    -- Parser MUST have set pass.changed from --print-changed
    assert(pass.changed ~= nil, string.format("Pass %d '%s' missing .changed field - parser bug!", index, pass.name))

    -- Get before/after IR (full module from resolver)
    local before_ir = M.get_before_ir_for_pass(index)
    local after_ir = M.get_after_ir_for_pass(index)

    -- Extract function for scoped passes to match display
    if (pass.scope_type == "function" or pass.scope_type == "cgscc" or pass.scope_type == "loop") and pass.scope_target then
      local pipeline = require('godbolt.pipeline')
      local ir_parser = pipeline.ir_parser
      before_ir = ir_parser.extract_function(before_ir, pass.scope_target) or before_ir
      after_ir = ir_parser.extract_function(after_ir, pass.scope_target) or after_ir
    end

    -- Compute simple diff stats for display (cheap - just line counts)
    if pass.changed then
      pass.diff_stats = {
        lines_before = #before_ir,
        lines_after = #after_ir,
        lines_changed = math.abs(#after_ir - #before_ir), -- Rough estimate for display
      }
    else
      -- Unchanged pass: all stats are zero
      pass.diff_stats = {
        lines_before = #before_ir,
        lines_after = #before_ir,
        lines_changed = 0,
      }
    end
  end

  -- Count changed/unchanged for logging
  local changed_count = 0
  local unchanged_count = 0
  for _, pass in ipairs(M.state.passes) do
    if pass.changed then
      changed_count = changed_count + 1
    else
      unchanged_count = unchanged_count + 1
    end
  end

  print(string.format("[Pipeline] Pass changes: %d changed, %d unchanged (from --print-changed)",
    changed_count, unchanged_count))

  if callback then
    callback()
  end
end

-- Get before IR for a given pass index
-- Extracted from show_diff logic for reuse
-- @param index: pass index (1-based)
-- @return: IR lines array
function M.get_before_ir_for_pass(index)
  local pipeline = require('godbolt.pipeline')
  local ir_resolver = pipeline.ir_resolver

  -- Get initial IR once - it's stored in the first pass by pipeline.lua
  local initial_ir = M.state.passes[1]._initial_ir or {}

  -- Use lazy resolver to get before-IR
  return ir_resolver.get_before_ir(M.state.passes, initial_ir, index)
end

-- Get after-IR for a pass (IR state after the pass ran)
-- @param index: pass index (1-based)
-- @return: IR lines array
function M.get_after_ir_for_pass(index)
  local pipeline = require('godbolt.pipeline')
  local ir_resolver = pipeline.ir_resolver

  -- Get initial IR once - it's stored in the first pass by pipeline.lua
  local initial_ir = M.state.passes[1]._initial_ir or {}

  -- Use lazy resolver to get after-IR
  return ir_resolver.get_after_ir(M.state.passes, initial_ir, index)
end

-- Show diff between pass N-1 and pass N
-- @param index: pass index (1-based)
-- @param auto_unfold: whether to auto-unfold groups (defaults to true for Tab/Shift-Tab)
function M.show_diff(index, auto_unfold)
  -- auto_unfold defaults to true for backward compatibility (Tab/Shift-Tab behavior)
  auto_unfold = auto_unfold ~= false

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

  -- Use helper functions to get before and after IR (full module from resolver)
  local before_ir = M.get_before_ir_for_pass(index)
  local after_ir = M.get_after_ir_for_pass(index)

  -- With --print-module-scope, resolver gives us full module
  -- For scoped passes (function/loop/CGSCC), extract just the relevant function for display
  if (scope_type == "function" or scope_type == "cgscc" or scope_type == "loop") and scope_target then
    local pipeline = require('godbolt.pipeline')
    local ir_parser = pipeline.ir_parser

    -- Extract the target function from full module for cleaner display
    before_ir = ir_parser.extract_function(before_ir, scope_target) or before_ir
    after_ir = ir_parser.extract_function(after_ir, scope_target) or after_ir
  end

  -- Determine before_name for display
  local before_name = ""
  if index == 1 then
    before_name = M.state.input_file and "Input Module" or "Initial"
  else
    before_name = M.state.passes[index - 1].name
  end

  -- Filter debug metadata if configured
  if M.state.config and M.state.config.display and M.state.config.display.strip_debug_metadata then
    local ir_utils = require('godbolt.ir_utils')
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

  -- Update pass list highlighting (pass through auto_unfold parameter)
  M.update_pass_list_cursor(old_index, index, auto_unfold)

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
    line_map_config.auto_scroll = true -- Force auto-scroll in pipeline viewer
    line_map_config.quiet = true       -- Suppress "no mappings" warnings (expected for many passes)

    -- Store full IR for line mapping
    vim.b[M.state.after_bufnr].godbolt_full_output = after_ir

    line_map.setup(M.state.source_bufnr, M.state.after_bufnr, "llvm", line_map_config)
  end

  -- Show inline hints if enabled
  local godbolt = require('godbolt')
  local hints_config = godbolt.config.pipeline and
      godbolt.config.pipeline.remarks and
      godbolt.config.pipeline.remarks.inline_hints
  if hints_config and hints_config.enabled and M.state.inline_hints_enabled then
    M.show_inline_hints()
  end
end

-- Update the cursor marker in pass list
-- IMPORTANT: indices are ORIGINAL indices in M.state.passes, NOT display_index!
-- @param old_index: previous current_index (to remove old markers)
-- @param new_index: new current_index (to add new markers)
-- Show help menu with keybindings
function M.show_help_menu()
  local config = M.state.config or {}
  local godbolt = require('godbolt')
  local keymaps = (godbolt.config.pipeline and godbolt.config.pipeline.keymaps) or {}

  -- Helper to format keymap (handles both string and table)
  local function format_keymap(km)
    if type(km) == "table" then
      return table.concat(km, ", ")
    else
      return km or "not set"
    end
  end

  -- Build help text
  local lines = {}
  table.insert(lines, "Pipeline Viewer Keybindings")
  table.insert(lines, string.rep("=", 50))
  table.insert(lines, "")
  table.insert(lines, "Navigation:")
  table.insert(lines, string.format("  %-20s  %s", format_keymap(keymaps.next_pass), "Move to next pass"))
  table.insert(lines, string.format("  %-20s  %s", format_keymap(keymaps.prev_pass), "Move to previous pass"))
  table.insert(lines, string.format("  %-20s  %s", format_keymap(keymaps.next_changed), "Jump to next changed pass"))
  table.insert(lines, string.format("  %-20s  %s", format_keymap(keymaps.prev_changed), "Jump to previous changed pass"))
  table.insert(lines, string.format("  %-20s  %s", format_keymap(keymaps.first_pass), "Jump to first pass"))
  table.insert(lines, string.format("  %-20s  %s", format_keymap(keymaps.last_pass), "Jump to last pass"))
  table.insert(lines, "")
  table.insert(lines, "Actions:")
  table.insert(lines, string.format("  %-20s  %s", format_keymap(keymaps.toggle_fold), "Toggle fold/unfold group"))
  table.insert(lines, string.format("  %-20s  %s", format_keymap(keymaps.activate_line), "Select pass or toggle fold"))
  table.insert(lines, string.format("  %-20s  %s", format_keymap(keymaps.show_remarks), "Show remarks for current pass"))
  table.insert(lines,
    string.format("  %-20s  %s", format_keymap(keymaps.show_all_remarks), "Show ALL remarks from all passes"))
  table.insert(lines,
    string.format("  %-20s  %s", format_keymap(keymaps.toggle_inline_hints), "Toggle inline hints on/off"))
  table.insert(lines, string.format("  %-20s  %s", format_keymap(keymaps.show_help), "Show this help menu"))
  table.insert(lines, string.format("  %-20s  %s", format_keymap(keymaps.quit), "Quit pipeline viewer"))
  table.insert(lines, "")
  table.insert(lines, "In before/after panes:")
  table.insert(lines, "  ]p, [p            Navigate passes")
  table.insert(lines, "  ]c, [c            Jump to next/prev diff")
  table.insert(lines, "")
  table.insert(lines, "Legend:")
  table.insert(lines, "  [M] = Module pass    [F] = Function pass    [C] = CGSCC pass")
  table.insert(lines, "  >   = Selected pass   ●   = Selected function")
  table.insert(lines, "")
  table.insert(lines, "Press q, <Esc>, or <CR> to close this help")

  -- Create floating window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(buf, 'filetype', 'help')

  local width = math.min(60, vim.o.columns - 4)
  local height = math.min(#lines + 2, vim.o.lines - 4)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " Pipeline Viewer Help ",
    title_pos = "center",
  })

  -- Keymaps to close
  local opts = { noremap = true, silent = true, buffer = buf }
  vim.keymap.set('n', 'q', '<cmd>close<CR>', opts)
  vim.keymap.set('n', '<Esc>', '<cmd>close<CR>', opts)
  vim.keymap.set('n', '<CR>', '<cmd>close<CR>', opts)
  vim.keymap.set('n', 'g?', '<cmd>close<CR>', opts)
end

-- Helper to apply semantic highlighting to remarks popup buffer
-- @param bufnr: buffer number to highlight
-- @param lines: array of line strings
-- @param highlight_metadata: array of {category, icon_pos, category_pos, labels} per line
local function apply_remarks_highlighting(bufnr, lines, highlight_metadata)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local ns = vim.api.nvim_create_namespace('godbolt_remarks_popup')

  for line_num, line in ipairs(lines) do
    local meta = highlight_metadata[line_num]

    -- Highlight category labels (PASS, MISSED, ANALYSIS)
    if meta and meta.category then
      local hl_group = meta.category == "pass" and "DiagnosticOk" or
          meta.category == "missed" and "DiagnosticWarn" or
          "DiagnosticInfo"

      if meta.icon_pos then
        -- Highlight icon (✓, ✗, ℹ)
        local icon_start, icon_end = meta.icon_pos[1], meta.icon_pos[2]
        pcall(vim.hl.range, bufnr, ns, hl_group,
          { line_num - 1, icon_start }, { line_num - 1, icon_end }, {})
      end

      if meta.category_pos then
        -- Highlight category label (PASS, MISSED, ANALYSIS)
        local cat_start, cat_end = meta.category_pos[1], meta.category_pos[2]
        pcall(vim.hl.range, bufnr, ns, hl_group,
          { line_num - 1, cat_start }, { line_num - 1, cat_end }, {})
      end
    end

    -- Highlight field labels (Message:, Pass:, In:, Details:, etc.)
    if meta and meta.labels then
      for _, label_pos in ipairs(meta.labels) do
        local start_col, end_col = label_pos[1], label_pos[2]
        pcall(vim.hl.range, bufnr, ns, "Identifier",
          { line_num - 1, start_col }, { line_num - 1, end_col }, {})
      end
    end

    -- Highlight separators (=== and ---)
    if line:match("^=+$") or line:match("^-+$") then
      pcall(vim.hl.range, bufnr, ns, "Comment",
        { line_num - 1, 0 }, { line_num - 1, #line }, {})
    end

    -- Highlight location strings (file:line:col)
    local loc_start, loc_end = line:find("%S+:%d+:%d+")
    if loc_start then
      pcall(vim.hl.range, bufnr, ns, "String",
        { line_num - 1, loc_start - 1 }, { line_num - 1, loc_end }, {})
    end

    -- Enhanced highlighting for Details lines
    if line:match("^%s+Details:") then
      local details_start = line:find("Details:") + 8
      local content = line:sub(details_start + 1)

      -- Try to highlight inlining-specific patterns
      -- Pattern 1: "foo not inlined into bar" - highlight both function names
      local caller, callee = content:match("(%w+)%s+not inlined into%s+(%w+)")
      if caller and callee then
        -- Highlight first function (caller)
        local start = line:find(caller, details_start, true)
        if start then
          pcall(vim.hl.range, bufnr, ns, "Function",
            { line_num - 1, start - 1 }, { line_num - 1, start + #caller - 1 }, {})
        end
        -- Highlight second function (callee)
        local start2 = line:find(callee, start and (start + #caller) or details_start, true)
        if start2 then
          pcall(vim.hl.range, bufnr, ns, "Function",
            { line_num - 1, start2 - 1 }, { line_num - 1, start2 + #callee - 1 }, {})
        end
      else
        -- Pattern 2: "foo inlined into bar" (positive case) - highlight both
        local caller2, callee2 = content:match("(%w+)%s+inlined into%s+(%w+)")
        if caller2 and callee2 then
          -- Highlight first function
          local start = line:find(caller2, details_start, true)
          if start then
            pcall(vim.hl.range, bufnr, ns, "Function",
              { line_num - 1, start - 1 }, { line_num - 1, start + #caller2 - 1 }, {})
          end
          -- Highlight second function
          local start2 = line:find(callee2, start and (start + #caller2) or details_start, true)
          if start2 then
            pcall(vim.hl.range, bufnr, ns, "Function",
              { line_num - 1, start2 - 1 }, { line_num - 1, start2 + #callee2 - 1 }, {})
          end
        end
      end

      -- Generic pattern: highlight any function name followed by ()
      -- This catches cases like "analyzing foo()"
      for fname in content:gmatch("(%w+)%(%)") do
        local start = line:find(fname .. "()", details_start, true)
        if start then
          pcall(vim.hl.range, bufnr, ns, "Function",
            { line_num - 1, start - 1 }, { line_num - 1, start + #fname - 1 }, {})
        end
      end

      -- Highlight metrics (cost=value, threshold=value) - handle both numbers and words
      -- Pattern matches key=value where value is anything up to delimiter (comma, paren, space, colon)
      for metric, value in content:gmatch("(%w+)=([^,%)%s:]+)") do
        local pattern = metric .. "=" .. value
        local start = line:find(pattern, details_start, true)
        if start then
          -- Highlight the key
          pcall(vim.hl.range, bufnr, ns, "Special",
            { line_num - 1, start - 1 }, { line_num - 1, start + #metric - 1 }, {})
          -- Highlight the value (use Number if numeric, String otherwise)
          local hl_group = value:match("^%-?%d+$") and "Number" or "String"
          pcall(vim.hl.range, bufnr, ns, hl_group,
            { line_num - 1, start + #metric }, { line_num - 1, start + #pattern - 1 }, {})
        end
      end

      -- Highlight callsite location (e.g., "baz:1:30")
      for loc in content:gmatch("(%w+:%d+:%d+)") do
        local start = line:find(loc, details_start, true)
        if start then
          pcall(vim.hl.range, bufnr, ns, "String",
            { line_num - 1, start - 1 }, { line_num - 1, start + #loc - 1 }, {})
        end
      end
    end
  end
end

-- Show ALL optimization remarks from all passes
function M.show_all_remarks_popup()
  if not M.state.passes then
    vim.notify("No passes available", vim.log.levels.INFO)
    return
  end

  -- Collect all remarks from all passes
  local all_remarks = {}
  local total_count = 0
  local by_category = { pass = 0, missed = 0, analysis = 0 }

  for _, pass in ipairs(M.state.passes) do
    if pass.remarks and #pass.remarks > 0 then
      for _, remark in ipairs(pass.remarks) do
        table.insert(all_remarks, {
          remark = remark,
          pass_name = pass.name,
          pass_index = _,
        })
        total_count = total_count + 1
        by_category[remark.category] = by_category[remark.category] + 1
      end
    end
  end

  if total_count == 0 then
    vim.notify("No remarks found in any pass", vim.log.levels.INFO)
    return
  end

  -- Helper to format Args into a readable string
  local function format_args_details(args)
    if not args or #args == 0 then
      return nil
    end

    local parts = {}
    local i = 1

    while i <= #args do
      local arg = args[i]

      if arg.key == "String" then
        local str = arg.value
        -- Skip standalone quote marks
        if str ~= "'" and str ~= "''" and str ~= "" then
          -- Remove quote marks from the string
          str = str:gsub("'", "")
          table.insert(parts, str)
        end
      elseif arg.key == "Callee" or arg.key == "Caller" then
        -- Just insert the function name without key
        table.insert(parts, arg.value)
      elseif arg.key == "Cost" or arg.key == "Threshold" then
        -- Check if previous String fragment already contains the key
        local prev_part = parts[#parts] or ""
        local key_lower = arg.key:lower()

        if prev_part:match(key_lower .. "=$") then
          -- Key already present in template, just insert value
          table.insert(parts, arg.value)
        else
          -- Format as lowercase key=value
          table.insert(parts, key_lower .. "=" .. arg.value)
        end
      elseif arg.key == "Line" then
        -- Check if next is Column for compact formatting
        if i < #args and args[i + 1].key == "Column" then
          table.insert(parts, arg.value .. ":" .. args[i + 1].value)
          i = i + 1 -- Skip the Column entry
        else
          table.insert(parts, arg.value)
        end
      elseif arg.key == "Column" then
        -- Handle standalone Column (if Line wasn't before it)
        table.insert(parts, arg.value)
      else
        -- Other keys: just insert value
        table.insert(parts, arg.value)
      end

      i = i + 1
    end

    local result = table.concat(parts, "")
    -- Remove trailing semicolons
    result = result:gsub(";$", "")
    -- Clean up any double spaces
    result = result:gsub("  +", " ")

    return result
  end

  -- Format remarks as lines with detailed information
  -- Also track metadata for highlighting
  local lines = {}
  local highlight_metadata = {}
  table.insert(lines, string.format("All Optimization Remarks (%d passes with remarks)", total_count))
  table.insert(highlight_metadata, {})
  table.insert(lines, string.rep("=", 80))
  table.insert(highlight_metadata, {})
  table.insert(lines, "")
  table.insert(highlight_metadata, {})

  local remark_num = 0
  for _, entry in ipairs(all_remarks) do
    local remark = entry.remark
    remark_num = remark_num + 1

    -- Icon and header based on category
    local icon = remark.category == "pass" and "✓" or
        remark.category == "missed" and "✗" or "ℹ"
    local category_label = remark.category == "pass" and "PASS" or
        remark.category == "missed" and "MISSED" or "ANALYSIS"

    -- Location string
    local loc = remark.location
    local loc_str = loc and string.format("%s:%d:%d", loc.file, loc.line, loc.column) or "unknown"

    -- Header line with icon, number, category, and location
    local header_line = string.format("[%d] %s %s  %s", remark_num, icon, category_label, loc_str)
    table.insert(lines, header_line)
    -- Track positions for highlighting
    local icon_start = header_line:find(icon, 1, true)
    local cat_start, cat_end = header_line:find(category_label, 1, true)
    table.insert(highlight_metadata, {
      category = remark.category,
      icon_pos = icon_start and { icon_start - 1, icon_start + #icon - 1 },
      category_pos = cat_start and { cat_start - 1, cat_end },
    })

    -- Which pass this came from
    table.insert(lines, string.format("    From:    Pass #%d - %s", entry.pass_index, entry.pass_name))
    table.insert(highlight_metadata, { labels = { { 4, 9 } } }) -- "From:"

    -- Message (what happened)
    table.insert(lines, string.format("    Message: %s", remark.message))
    table.insert(highlight_metadata, { labels = { { 4, 12 } } }) -- "Message:"

    -- Pass name (the actual LLVM pass that generated this remark)
    if remark.pass_name then
      table.insert(lines, string.format("    Pass:    %s", remark.pass_name))
      table.insert(highlight_metadata, { labels = { { 4, 9 } } }) -- "Pass:"
    end

    -- Function context (which function this remark is about)
    if remark.function_name then
      table.insert(lines, string.format("    In:      %s()", remark.function_name))
      table.insert(highlight_metadata, { labels = { { 4, 7 } } }) -- "In:"
    end

    -- Args (additional details specific to the optimization)
    local details = format_args_details(remark.args)
    if details then
      table.insert(lines, string.format("    Details: %s", details))
      table.insert(highlight_metadata, { labels = { { 4, 12 } } }) -- "Details:"
    end

    -- Extra fields (any other metadata we found)
    if remark.extra then
      table.insert(lines, "    Extra:")
      table.insert(highlight_metadata, { labels = { { 4, 10 } } }) -- "Extra:"
      for key, value in pairs(remark.extra) do
        table.insert(lines, string.format("      • %s: %s", key, value))
        table.insert(highlight_metadata, {})
      end
    end

    table.insert(lines, "")
    table.insert(highlight_metadata, {})
  end

  -- Summary footer
  table.insert(lines, string.rep("-", 80))
  table.insert(highlight_metadata, {})
  table.insert(lines, string.format("Total: %d remarks (%d pass, %d missed, %d analysis)",
    total_count,
    by_category.pass,
    by_category.missed,
    by_category.analysis
  ))
  table.insert(highlight_metadata, {})
  table.insert(lines, "")
  table.insert(highlight_metadata, {})
  table.insert(lines, "Navigation: Use j/k or arrows to scroll")
  table.insert(highlight_metadata, {})
  table.insert(lines, "Press q, <Esc>, or <CR> to close")
  table.insert(highlight_metadata, {})

  -- Create floating window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')

  -- Apply semantic highlighting
  apply_remarks_highlighting(buf, lines, highlight_metadata)

  local width = math.min(100, vim.o.columns - 4)
  local height = math.min(#lines + 2, vim.o.lines - 4)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " All Optimization Remarks ",
    title_pos = "center",
  })

  -- Set filetype for potential syntax highlighting
  vim.api.nvim_buf_set_option(buf, 'filetype', 'godbolt-remarks')

  -- Keymaps to close
  local opts = { noremap = true, silent = true, buffer = buf }
  vim.keymap.set('n', 'q', '<cmd>close<CR>', opts)
  vim.keymap.set('n', '<Esc>', '<cmd>close<CR>', opts)
  vim.keymap.set('n', '<CR>', '<cmd>close<CR>', opts)
end

-- Setup diagnostic namespace for remarks
local remarks_ns = vim.api.nvim_create_namespace('godbolt_remarks_diagnostics')

-- Format a remark as diagnostic virtual text
-- @param remark: remark table
-- @param format: "icon", "short", or "detailed"
-- @return: string to show as virtual text
local function format_inline_hint(remark, format)
  format = format or "short"

  local icon = remark.category == "pass" and "✓" or
      remark.category == "missed" and "✗" or "ℹ"

  if format == "icon" then
    return icon
  elseif format == "short" then
    -- Show icon + message (compact)
    return string.format("%s %s", icon, remark.message)
  else -- "detailed"
    -- Show more context
    local text = string.format("%s %s", icon, remark.message)
    if remark.args then
      -- Add first useful arg (like Callee, Cost, Reason, etc.)
      for _, arg in ipairs(remark.args) do
        if arg.key ~= "String" then -- Skip generic String fields
          text = text .. string.format(" (%s: %s)", arg.key, arg.value)
          break
        end
      end
    end
    return text
  end
end

-- Get diagnostic severity for a remark category
-- @param category: "pass", "missed", or "analysis"
-- @return: vim.diagnostic.severity
local function get_remark_severity(category)
  if category == "pass" then
    return vim.diagnostic.severity.HINT -- Success - hint level
  elseif category == "missed" then
    return vim.diagnostic.severity.WARN -- Missed optimization - warning
  else
    return vim.diagnostic.severity.INFO -- Analysis - info
  end
end

-- Setup highlight groups for remarks diagnostics
local function setup_remark_highlights()
  -- Link to diagnostic highlights with custom italic styling
  if vim.fn.hlexists("DiagnosticHintGodbolt") == 0 then
    vim.api.nvim_set_hl(0, "DiagnosticHintGodbolt", { link = "DiagnosticHint" })
    vim.api.nvim_set_hl(0, "DiagnosticVirtualTextHintGodbolt", { fg = "#98c379", italic = true })
  end
  if vim.fn.hlexists("DiagnosticWarnGodbolt") == 0 then
    vim.api.nvim_set_hl(0, "DiagnosticWarnGodbolt", { link = "DiagnosticWarn" })
    vim.api.nvim_set_hl(0, "DiagnosticVirtualTextWarnGodbolt", { fg = "#e06c75", italic = true })
  end
  if vim.fn.hlexists("DiagnosticInfoGodbolt") == 0 then
    vim.api.nvim_set_hl(0, "DiagnosticInfoGodbolt", { link = "DiagnosticInfo" })
    vim.api.nvim_set_hl(0, "DiagnosticVirtualTextInfoGodbolt", { fg = "#61afef", italic = true })
  end
end

-- Show inline hints for current pass using vim.diagnostic
function M.show_inline_hints()
  if not M.state.current_index or not M.state.passes then
    return
  end

  local pass = M.state.passes[M.state.current_index]
  if not pass.remarks or #pass.remarks == 0 then
    return
  end

  -- Setup highlights
  setup_remark_highlights()

  -- Get config
  local godbolt = require('godbolt')
  local hints_config = godbolt.config.pipeline and
      godbolt.config.pipeline.remarks and
      godbolt.config.pipeline.remarks.inline_hints or {}
  local format = hints_config.format or "short"

  -- Build diagnostics array
  local diagnostics = {}

  -- TODO: Map source line numbers to IR line numbers
  -- For now, we'll show all remarks at the top of the buffer as a fallback
  -- In the future, we should use debug info to map source locations to IR lines

  -- Add each remark as a diagnostic
  for _, remark in ipairs(pass.remarks) do
    local message = format_inline_hint(remark, format)
    local severity = get_remark_severity(remark.category)

    -- For now, place all at line 0 since we don't have source->IR mapping yet
    -- TODO: Use debug metadata to find the actual IR line
    table.insert(diagnostics, {
      lnum = 0, -- 0-indexed line number
      col = 0,
      severity = severity,
      message = message,
      source = "godbolt-remarks",
    })
  end

  -- Set diagnostics for the after buffer
  vim.diagnostic.set(remarks_ns, M.state.after_bufnr, diagnostics, {
    virtual_text = {
      prefix = "",
      spacing = 4,
      suffix = function(diagnostic)
        if diagnostic.severity == vim.diagnostic.severity.HINT then
          return " ", "DiagnosticVirtualTextHintGodbolt"
        elseif diagnostic.severity == vim.diagnostic.severity.WARN then
          return " ", "DiagnosticVirtualTextWarnGodbolt"
        else
          return " ", "DiagnosticVirtualTextInfoGodbolt"
        end
      end,
    },
    signs = false,     -- Don't show signs column for remarks
    underline = false, -- Don't underline
    update_in_insert = false,
  })

  M.state.inline_hints_enabled = true
end

-- Hide inline hints
function M.hide_inline_hints()
  if M.state.after_bufnr then
    vim.diagnostic.reset(remarks_ns, M.state.after_bufnr)
  end
  M.state.inline_hints_enabled = false
end

-- Toggle inline hints on/off
function M.toggle_inline_hints()
  if M.state.inline_hints_enabled then
    M.hide_inline_hints()
    vim.notify("Inline hints hidden (press gh to show)", vim.log.levels.INFO)
  else
    M.show_inline_hints()
    vim.notify("Inline hints shown (press gh to hide)", vim.log.levels.INFO)
  end
end

-- Show optimization remarks popup for current pass
function M.show_remarks_popup()
  if not M.state.current_index or not M.state.passes then
    vim.notify("No pass selected", vim.log.levels.INFO)
    return
  end

  local pass = M.state.passes[M.state.current_index]
  if not pass.remarks or #pass.remarks == 0 then
    vim.notify("No remarks for this pass", vim.log.levels.INFO)
    return
  end

  -- Helper to format Args into a readable string
  local function format_args_details(args)
    if not args or #args == 0 then
      return nil
    end

    local parts = {}
    local i = 1

    while i <= #args do
      local arg = args[i]

      if arg.key == "String" then
        local str = arg.value
        -- Skip standalone quote marks
        if str ~= "'" and str ~= "''" and str ~= "" then
          -- Remove quote marks from the string
          str = str:gsub("'", "")
          table.insert(parts, str)
        end
      elseif arg.key == "Callee" or arg.key == "Caller" then
        -- Just insert the function name without key
        table.insert(parts, arg.value)
      elseif arg.key == "Cost" or arg.key == "Threshold" then
        -- Check if previous String fragment already contains the key
        local prev_part = parts[#parts] or ""
        local key_lower = arg.key:lower()

        if prev_part:match(key_lower .. "=$") then
          -- Key already present in template, just insert value
          table.insert(parts, arg.value)
        else
          -- Format as lowercase key=value
          table.insert(parts, key_lower .. "=" .. arg.value)
        end
      elseif arg.key == "Line" then
        -- Check if next is Column for compact formatting
        if i < #args and args[i + 1].key == "Column" then
          table.insert(parts, arg.value .. ":" .. args[i + 1].value)
          i = i + 1 -- Skip the Column entry
        else
          table.insert(parts, arg.value)
        end
      elseif arg.key == "Column" then
        -- Handle standalone Column (if Line wasn't before it)
        table.insert(parts, arg.value)
      else
        -- Other keys: just insert value
        table.insert(parts, arg.value)
      end

      i = i + 1
    end

    local result = table.concat(parts, "")
    -- Remove trailing semicolons
    result = result:gsub(";$", "")
    -- Clean up any double spaces
    result = result:gsub("  +", " ")

    return result
  end

  -- Format remarks as lines with detailed information
  -- Also track metadata for highlighting
  local lines = {}
  local highlight_metadata = {}
  table.insert(lines, string.format("Optimization Remarks for %s", pass.name))
  table.insert(highlight_metadata, {})
  table.insert(lines, string.rep("=", 80))
  table.insert(highlight_metadata, {})
  table.insert(lines, "")
  table.insert(highlight_metadata, {})

  -- Group by category for summary
  local by_category = { pass = {}, missed = {}, analysis = {} }
  for _, remark in ipairs(pass.remarks) do
    table.insert(by_category[remark.category], remark)
  end

  local remark_num = 0
  for _, remark in ipairs(pass.remarks) do
    remark_num = remark_num + 1

    -- Icon and header based on category
    local icon = remark.category == "pass" and "✓" or
        remark.category == "missed" and "✗" or "ℹ"
    local category_label = remark.category == "pass" and "PASS" or
        remark.category == "missed" and "MISSED" or "ANALYSIS"

    -- Location string
    local loc = remark.location
    local loc_str = loc and string.format("%s:%d:%d", loc.file, loc.line, loc.column) or "unknown"

    -- Header line with icon, number, category, and location
    local header_line = string.format("[%d] %s %s  %s", remark_num, icon, category_label, loc_str)
    table.insert(lines, header_line)
    -- Track positions for highlighting
    local icon_start = header_line:find(icon, 1, true)
    local cat_start, cat_end = header_line:find(category_label, 1, true)
    table.insert(highlight_metadata, {
      category = remark.category,
      icon_pos = icon_start and { icon_start - 1, icon_start + #icon - 1 },
      category_pos = cat_start and { cat_start - 1, cat_end },
    })

    -- Message (what happened)
    table.insert(lines, string.format("    Message: %s", remark.message))
    table.insert(highlight_metadata, { labels = { { 4, 12 } } }) -- "Message:"

    -- Pass name (the actual LLVM pass that generated this remark)
    if remark.pass_name then
      table.insert(lines, string.format("    Pass:    %s", remark.pass_name))
      table.insert(highlight_metadata, { labels = { { 4, 9 } } }) -- "Pass:"
    end

    -- Function context (which function this remark is about)
    if remark.function_name then
      table.insert(lines, string.format("    In:      %s()", remark.function_name))
      table.insert(highlight_metadata, { labels = { { 4, 7 } } }) -- "In:"
    end

    -- Args (additional details specific to the optimization)
    local details = format_args_details(remark.args)
    if details then
      table.insert(lines, string.format("    Details: %s", details))
      table.insert(highlight_metadata, { labels = { { 4, 12 } } }) -- "Details:"
    end

    -- Extra fields (any other metadata we found)
    if remark.extra then
      table.insert(lines, "    Extra:")
      table.insert(highlight_metadata, { labels = { { 4, 10 } } }) -- "Extra:"
      for key, value in pairs(remark.extra) do
        table.insert(lines, string.format("      • %s: %s", key, value))
        table.insert(highlight_metadata, {})
      end
    end

    table.insert(lines, "")
    table.insert(highlight_metadata, {})
  end

  -- Summary footer
  table.insert(lines, string.rep("-", 80))
  table.insert(highlight_metadata, {})
  table.insert(lines, string.format("Total: %d remarks (%d pass, %d missed, %d analysis)",
    #pass.remarks,
    #by_category.pass,
    #by_category.missed,
    #by_category.analysis
  ))
  table.insert(highlight_metadata, {})
  table.insert(lines, "")
  table.insert(highlight_metadata, {})
  table.insert(lines, "Press q, <Esc>, or <CR> to close")
  table.insert(highlight_metadata, {})

  -- Create floating window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')

  -- Apply semantic highlighting
  apply_remarks_highlighting(buf, lines, highlight_metadata)

  local width = math.min(100, vim.o.columns - 4)
  local height = math.min(#lines + 2, vim.o.lines - 4)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " Optimization Remarks ",
    title_pos = "center",
  })

  -- Set filetype for potential syntax highlighting
  vim.api.nvim_buf_set_option(buf, 'filetype', 'godbolt-remarks')

  -- Keymaps to close
  local opts = { noremap = true, silent = true, buffer = buf }
  vim.keymap.set('n', 'q', '<cmd>close<CR>', opts)
  vim.keymap.set('n', '<Esc>', '<cmd>close<CR>', opts)
  vim.keymap.set('n', '<CR>', '<cmd>close<CR>', opts)
end

function M.update_pass_list_cursor(old_index, new_index, auto_unfold)
  -- auto_unfold defaults to true for backward compatibility (Tab/Shift-Tab behavior)
  auto_unfold = auto_unfold ~= false

  -- Move cursor to the selected line
  local line_map = M.state.pass_list_line_map
  if not line_map then return end

  -- Only auto-unfold groups when explicitly enabled (Tab/Shift-Tab navigation)
  if auto_unfold then
    -- For function/loop/cgscc passes, ensure their group is unfolded
    local target_pass = M.state.passes[new_index]
    if target_pass and (target_pass.scope_type == "function" or target_pass.scope_type == "cgscc" or target_pass.scope_type == "loop") then
      -- Find which group this pass belongs to
      local groups = M.state.grouped_passes
      if groups then
        for group_idx, group in ipairs(groups) do
          if group.type == "function_group" or group.type == "cgscc_group" then
            if group.functions then
              for _, fn in ipairs(group.functions) do
                if fn.original_index == new_index then
                  -- Found the group containing this pass
                  if group.folded then
                    -- Unfold it
                    group.folded = false
                    M.populate_pass_list() -- Rebuild to show function entries
                    line_map = M.state.pass_list_line_map -- Get updated line_map
                  end
                  break
                end
              end
            end
          end
        end
      end
    end

    -- Clear the on_group_header flag so we move to the function entry, not the group header
    M.state.on_group_header = false
  end

  -- Only move cursor when auto_unfold is enabled (Tab/Shift-Tab)
  -- For j/k navigation, we just update highlighting without moving cursor
  if auto_unfold then
    -- Find the line corresponding to new_index
    for line_idx, info in pairs(line_map) do
      if info.type == "module" and info.original_index == new_index then
        pcall(vim.api.nvim_win_set_cursor, M.state.pass_list_winid, { line_idx, 0 })
        -- Update selection highlighting AFTER unfolding and cursor positioning
        M.update_selection_highlighting()
        return
      elseif info.type == "function_entry" and info.original_index == new_index then
        -- Move to function entry (not group header)
        pcall(vim.api.nvim_win_set_cursor, M.state.pass_list_winid, { line_idx, 0 })
        -- Update selection highlighting AFTER unfolding and cursor positioning
        M.update_selection_highlighting()
        return
      end
    end
  end

  -- Always update highlighting
  M.update_selection_highlighting()
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
  M.populate_pass_list() -- Rebuild display

  -- Find the group header line again after rebuild using line_map
  local line_map_updated = M.state.pass_list_line_map
  for i, updated_info in pairs(line_map_updated) do
    if updated_info.type == "group_header" and updated_info.group_idx == line_info.group_idx then
      -- Found the group header, move cursor there
      pcall(vim.api.nvim_win_set_cursor, M.state.pass_list_winid, { i, 0 })
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
        group.folded = true    -- Always fold (don't toggle)
        M.populate_pass_list() -- Rebuild display

        -- Move cursor to the folded group header using updated line_map
        local line_map_updated = M.state.pass_list_line_map
        for new_i, updated_info in pairs(line_map_updated) do
          if updated_info.type == "group_header" and updated_info.group_idx == prev_info.group_idx then
            pcall(vim.api.nvim_win_set_cursor, M.state.pass_list_winid, { new_i, 0 })
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
      vim.api.nvim_win_set_cursor(M.state.pass_list_winid, { i, 0 })

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
      vim.api.nvim_win_set_cursor(M.state.pass_list_winid, { i, 0 })

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

  -- Determine which group we're currently in (if any)
  local current_group_idx = nil
  local current_info = line_map[current_line]
  if current_info then
    if current_info.type == "function_entry" or current_info.type == "group_header" then
      current_group_idx = current_info.group_idx
    end
  end

  -- Find next pass line that corresponds to a changed pass
  local total_lines = vim.api.nvim_buf_line_count(M.state.pass_list_bufnr)
  for i = current_line + 1, total_lines do
    local line_info = line_map[i]
    if not line_info then goto continue end

    if line_info.type == "group_header" then
      -- Skip the header for our current group - we want to go AFTER it
      if current_group_idx and line_info.group_idx == current_group_idx then
        goto continue
      end

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
            M.populate_pass_list() -- Rebuild to show function entries
          end

          -- Now find the actual function entry line in the unfolded group
          local line_map_updated = M.state.pass_list_line_map
          for line_idx, updated_info in pairs(line_map_updated) do
            if updated_info.type == "function_entry" and
                updated_info.original_index == first_changed_fn.original_index then
              -- Found it! Move cursor to the function entry
              vim.api.nvim_win_set_cursor(M.state.pass_list_winid, { line_idx, 0 })
              M.select_pass_for_viewing()
              return
            end
          end

          -- Fallback: if we can't find the function entry (shouldn't happen), just show the group
          vim.api.nvim_win_set_cursor(M.state.pass_list_winid, { i, 0 })
          M.select_pass_for_viewing()
          return
        end
      end
    elseif line_info.type == "module" then
      -- Check if this module pass is changed
      if is_pass_changed(line_info.original_index) then
        vim.api.nvim_win_set_cursor(M.state.pass_list_winid, { i, 0 })
        M.select_pass_for_viewing()
        return
      end
    elseif line_info.type == "function_entry" then
      -- Skip function entries from our current group
      if current_group_idx and line_info.group_idx == current_group_idx then
        goto continue
      end

      -- Check if this function pass is changed
      if is_pass_changed(line_info.original_index) then
        vim.api.nvim_win_set_cursor(M.state.pass_list_winid, { i, 0 })
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

  -- Determine which group we're currently in (if any)
  local current_group_idx = nil
  local current_info = line_map[current_line]
  if current_info then
    if current_info.type == "function_entry" or current_info.type == "group_header" then
      current_group_idx = current_info.group_idx
    end
  end

  -- Find previous pass line that corresponds to a changed pass
  for i = current_line - 1, 1, -1 do
    local line_info = line_map[i]
    if not line_info then goto continue end

    if line_info.type == "group_header" then
      -- Skip the header for our current group - we want to go BEFORE it
      if current_group_idx and line_info.group_idx == current_group_idx then
        goto continue
      end

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
            M.populate_pass_list() -- Rebuild to show function entries
          end

          -- Now find the actual function entry line in the unfolded group
          local line_map_updated = M.state.pass_list_line_map
          for line_idx, updated_info in pairs(line_map_updated) do
            if updated_info.type == "function_entry" and
                updated_info.original_index == first_changed_fn.original_index then
              -- Found it! Move cursor to the function entry
              vim.api.nvim_win_set_cursor(M.state.pass_list_winid, { line_idx, 0 })
              M.select_pass_for_viewing()
              return
            end
          end

          -- Fallback: if we can't find the function entry (shouldn't happen), just show the group
          vim.api.nvim_win_set_cursor(M.state.pass_list_winid, { i, 0 })
          M.select_pass_for_viewing()
          return
        end
      end
    elseif line_info.type == "module" then
      -- Check if this module pass is changed
      if is_pass_changed(line_info.original_index) then
        vim.api.nvim_win_set_cursor(M.state.pass_list_winid, { i, 0 })
        M.select_pass_for_viewing()
        return
      end
    elseif line_info.type == "function_entry" then
      -- Skip function entries from our current group
      if current_group_idx and line_info.group_idx == current_group_idx then
        goto continue
      end

      -- Check if this function pass is changed
      if is_pass_changed(line_info.original_index) then
        vim.api.nvim_win_set_cursor(M.state.pass_list_winid, { i, 0 })
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
      M.state.on_group_header = true -- Don't show function marker

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

      -- DON'T call M.update_pass_list_cursor for j/k navigation!
      -- This was causing the cursor to bounce back to the first function entry
      -- Just update highlighting without moving cursor
      M.update_selection_highlighting()
    end
    return
  elseif line_info.type == "function_entry" then
    -- On a function entry: show diff for that function
    M.state.on_group_header = false -- Clear flag
    -- Pass auto_unfold=false to prevent j/k from unfolding groups
    M.show_diff(line_info.original_index, false)
    return
  elseif line_info.type == "module" then
    -- On a module pass: show diff
    M.state.on_group_header = false -- Clear flag
    -- Pass auto_unfold=false to prevent j/k from unfolding groups
    M.show_diff(line_info.original_index, false)
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
  local godbolt = require('godbolt')
  local keymaps = (godbolt.config.pipeline and godbolt.config.pipeline.keymaps) or {}

  -- Helper to set keymap(s) from config (handles both string and table)
  local function set_keymap(key_config, handler, desc)
    if not key_config then return end

    if type(key_config) == "table" then
      for _, key in ipairs(key_config) do
        vim.keymap.set('n', key, handler, { buffer = bufnr, desc = desc })
      end
    else
      vim.keymap.set('n', key_config, handler, { buffer = bufnr, desc = desc })
    end
  end

  -- Pass list navigation
  set_keymap(keymaps.next_pass, goto_next_pass_line, 'Next pass')
  set_keymap(keymaps.prev_pass, goto_prev_pass_line, 'Previous pass')
  set_keymap(keymaps.next_changed, function() M.next_pass() end, 'Next changed pass (pipeline order)')
  set_keymap(keymaps.prev_changed, function() M.prev_pass() end, 'Previous changed pass (pipeline order)')

  -- Folding
  set_keymap(keymaps.toggle_fold, function() M.toggle_fold_under_cursor() end, 'Toggle fold')
  set_keymap(keymaps.activate_line, function() M.activate_line_under_cursor() end, 'Toggle fold or select pass')

  -- Jump to first/last
  set_keymap(keymaps.first_pass, function() M.first_pass() end, 'First pass')
  set_keymap(keymaps.last_pass, function() M.last_pass() end, 'Last pass')

  -- Show remarks popup
  set_keymap(keymaps.show_remarks, function() M.show_remarks_popup() end, 'Show remarks for current pass')
  set_keymap(keymaps.show_all_remarks, function() M.show_all_remarks_popup() end, 'Show ALL remarks from all passes')

  -- Toggle inline hints
  set_keymap(keymaps.toggle_inline_hints, function() M.toggle_inline_hints() end, 'Toggle inline hints on/off')

  -- Show help menu
  set_keymap(keymaps.show_help, function() M.show_help_menu() end, 'Show help menu')

  -- Quit
  set_keymap(keymaps.quit, function()
    M.cleanup()
    vim.cmd('quit')
  end, 'Quit pipeline viewer')

  -- Also add commands that work from any window (before/after panes)
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

  -- Set up CursorMoved autocmd for j/k navigation in pass list
  -- This ensures the diff updates when moving with j/k
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = M.state.pass_list_bufnr,
    callback = function()
      -- Use vim.schedule to avoid errors during cursor movement
      vim.schedule(function()
        M.select_pass_for_viewing()
      end)
    end,
    desc = "Update diff when cursor moves in pass list"
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
    ns_id = M.state.ns_id, -- Keep namespace
    -- Session-related fields
    source_file = nil,
    initial_ir = nil,
    opt_level = nil,
    compilation_command = nil,
    compiler = nil,
  }
end

return M

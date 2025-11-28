local M = {}

-- Show Before/After LTO comparison in side-by-side view
-- @param source_files: array of source file paths
-- @param opt_level: optimization level (default: "-O2")
-- @param extra_args: additional compiler arguments
function M.show_lto_comparison(source_files, opt_level, extra_args)
  opt_level = opt_level or "-O2"
  extra_args = extra_args or ""

  local lto = require('godbolt.lto')
  local lto_stats = require('godbolt.lto_stats')
  local file_colors = require('godbolt.file_colors')
  local ir_utils = require('godbolt.ir_utils')
  local pipeline = require('godbolt.pipeline')

  print(string.format("[LTO Comparison] Analyzing %d files with %s...", #source_files, opt_level))

  -- Run LTO pipeline to capture before/after states
  print("[LTO Comparison] Running LTO pipeline with -print-before-all and -print-after-all...")
  local success, pipeline_output = lto.run_lto_pipeline(source_files, opt_level, extra_args)

  if not success then
    print("[LTO Comparison] Failed to run LTO pipeline:")
    print(pipeline_output)
    return
  end

  -- Parse pipeline output to extract passes
  print("[LTO Comparison] Parsing pipeline output...")
  local passes, initial_ir = pipeline.parse_pipeline_output(pipeline_output, "clang")

  if not passes or #passes == 0 then
    print("[LTO Comparison] No passes captured from pipeline")
    return
  end

  -- Get the initial module state (before any LTO passes)
  local before_ir = initial_ir
  if not before_ir or #before_ir == 0 then
    -- Fallback: use the first pass's before_ir
    if passes[1] and passes[1].before_ir then
      before_ir = passes[1].before_ir
    else
      print("[LTO Comparison] Could not find initial IR state")
      return
    end
  end

  -- Get the final module state (after all LTO passes)
  local after_ir = passes[#passes].ir
  if not after_ir or #after_ir == 0 then
    print("[LTO Comparison] Could not find final IR state")
    return
  end

  print(string.format("[LTO Comparison] Found %d passes, before: %d lines, after: %d lines",
    #passes, #before_ir, #after_ir))

  -- Parse debug info to track source files
  -- IMPORTANT: Parse from before_ir, as after_ir may have debug metadata stripped
  print("[LTO Comparison] Analyzing source file information...")
  local file_map = lto_stats.parse_di_files(before_ir)
  local func_sources = lto_stats.parse_function_sources(before_ir, file_map)

  -- Debug output
  print(string.format("[LTO Comparison] Found %d DIFiles", vim.tbl_count(file_map)))
  for id, info in pairs(file_map) do
    print(string.format("  %s: %s", id, info.filename))
  end

  print(string.format("[LTO Comparison] Mapped %d functions to source files", vim.tbl_count(func_sources)))
  for func, info in pairs(func_sources) do
    print(string.format("  %s -> %s", func, info.filename or "unknown"))
  end

  -- Calculate statistics
  print("[LTO Comparison] Computing statistics...")
  local inlining_stats = lto_stats.detect_cross_module_inlining(before_ir, after_ir, func_sources)
  local dce_stats = lto_stats.track_dead_code_elimination(before_ir, after_ir, func_sources)

  -- Step 5: Create comparison view
  print("[LTO Comparison] Step 5: Creating comparison view...")

  -- Create main window layout (3 columns)
  vim.cmd('tabnew')
  local main_win = vim.api.nvim_get_current_win()
  local main_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(main_win, main_buf)

  -- Left pane: Before LTO
  local before_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(before_buf, 'filetype', 'llvm')
  vim.api.nvim_buf_set_option(before_buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_name(before_buf, 'Before LTO (Merged Modules)')

  -- Center pane: Statistics
  local stats_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(stats_buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_name(stats_buf, 'LTO Statistics')

  -- Right pane: After LTO
  local after_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(after_buf, 'filetype', 'llvm')
  vim.api.nvim_buf_set_option(after_buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_name(after_buf, string.format('After LTO %s', opt_level))

  -- Set up layout
  vim.api.nvim_win_set_buf(main_win, before_buf)

  vim.cmd('vertical rightbelow new')
  local stats_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(stats_win, stats_buf)

  vim.cmd('vertical rightbelow new')
  local after_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(after_win, after_buf)

  -- Make all windows equal width
  vim.cmd('wincmd =')

  -- Populate before buffer
  local before_filtered = ir_utils.filter_debug_metadata(before_ir)
  vim.api.nvim_buf_set_lines(before_buf, 0, -1, false, before_filtered)

  -- Populate after buffer with coloring
  local after_filtered = ir_utils.filter_debug_metadata(after_ir)
  vim.api.nvim_buf_set_lines(after_buf, 0, -1, false, after_filtered)

  -- Apply file-based coloring to after buffer
  file_colors.setup_highlights()
  local color_map = file_colors.colorize_by_source_file(after_buf, after_filtered, func_sources)

  -- Populate statistics buffer
  local stats_lines = {}

  -- Title
  table.insert(stats_lines, "╔══════════════════════════════════════╗")
  table.insert(stats_lines, "║       LTO TRANSFORMATION STATS       ║")
  table.insert(stats_lines, "╚══════════════════════════════════════╝")
  table.insert(stats_lines, "")

  -- Source files legend
  local legend = file_colors.create_color_legend(color_map)
  for _, line in ipairs(legend) do
    table.insert(stats_lines, line)
  end
  table.insert(stats_lines, "")

  -- Cross-module inlining
  table.insert(stats_lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  table.insert(stats_lines, "Cross-Module Inlining:")
  table.insert(stats_lines, string.format("  Function calls before LTO: %d", inlining_stats.total_calls_before))
  table.insert(stats_lines, string.format("  Function calls after LTO:  %d", inlining_stats.total_calls_after))
  table.insert(stats_lines, string.format("  Total inlined: %d", inlining_stats.inlined_count))
  table.insert(stats_lines, "")
  table.insert(stats_lines, string.format("  Cross-module calls before: %d", inlining_stats.cross_module_calls_before))
  table.insert(stats_lines, string.format("  Cross-module calls after:  %d", inlining_stats.cross_module_calls_after))
  local cross_inlined = inlining_stats.cross_module_calls_before - inlining_stats.cross_module_calls_after
  table.insert(stats_lines, string.format("  Cross-module inlined: %d", cross_inlined))

  if next(inlining_stats.inlines_by_file) then
    table.insert(stats_lines, "")
    table.insert(stats_lines, "  Inlined by source file:")
    for file, info in pairs(inlining_stats.inlines_by_file) do
      local targets = table.concat(info.targets, ", ")
      table.insert(stats_lines, string.format("    • %s:", file))
      table.insert(stats_lines, string.format("      %d inlines from: %s", info.count, targets))
    end
  end

  table.insert(stats_lines, "")

  -- Dead code elimination
  table.insert(stats_lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  table.insert(stats_lines, "Dead Code Elimination:")
  table.insert(stats_lines, string.format("  Functions removed: %d", dce_stats.functions_removed))

  if next(dce_stats.functions_by_file) then
    table.insert(stats_lines, "")
    table.insert(stats_lines, "  By source file:")
    for file, info in pairs(dce_stats.functions_by_file) do
      table.insert(stats_lines, string.format("    • %s:", file))

      if #info.removed > 0 then
        local removed = table.concat(info.removed, ", ")
        table.insert(stats_lines, string.format("      Removed: %s", removed))
      end

      if #info.kept > 0 then
        local kept = table.concat(info.kept, ", ")
        table.insert(stats_lines, string.format("      Kept: %s", kept))
      end
    end
  end

  table.insert(stats_lines, "")

  -- Size comparison
  table.insert(stats_lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  table.insert(stats_lines, "Size Comparison:")
  table.insert(stats_lines, string.format("  Before LTO: %d lines", #before_filtered))
  table.insert(stats_lines, string.format("  After LTO:  %d lines", #after_filtered))
  local reduction = #before_filtered - #after_filtered
  local percent = reduction > 0 and (reduction / #before_filtered * 100) or 0
  table.insert(stats_lines, string.format("  Reduction:  %d lines (%.1f%%)", reduction, percent))

  vim.api.nvim_buf_set_lines(stats_buf, 0, -1, false, stats_lines)
  vim.api.nvim_buf_set_option(stats_buf, 'modifiable', false)

  -- Set focus to statistics pane
  vim.api.nvim_set_current_win(stats_win)

  print("[LTO Comparison] Done!")
end

return M

-- Helper to get timestamp string
local function get_timestamp()
  return os.date("%H:%M:%S")
end

local M = {}

local ir_utils = require('godbolt.ir_utils')

-- Debug flag - set to true to see detailed logging
M.debug = false

-- Forward declarations of pipeline functions
local run_opt_pipeline
local run_clang_pipeline

-- Helper: Normalize O-level input to clang format
-- @param input: "O2", "2", "-O2", "default<O2>"
-- @return: "-O2" or nil if not an O-level
local function normalize_o_level(input)
  local level = input:match("^%-?O?(%d)$")
  if level then
    return "-O" .. level
  elseif input:match("^default%<O(%d)%>$") then
    level = input:match("^default%<O(%d)%>$")
    return "-O" .. level
  else
    return nil
  end
end

-- Helper: Check if IR lines contain LLVM IR (not MIR or other formats)
-- @param ir_lines: array of lines
-- @return: boolean
local function is_llvm_ir(ir_lines)
  for _, line in ipairs(ir_lines) do
    if line:match("^define ") or line:match("^declare ") then
      return true
    end
  end
  return false
end

-- Helper: Detect LTO flags
-- @param args: string of compiler arguments
-- @return: boolean
local function has_lto_flags(args)
  return args:match("-flto") or args:match("-flink%-time%-optimization")
end

-- Note: Remark parsing is now handled by lua/godbolt/remarks.lua
-- LLVM outputs remarks in YAML format using -fsave-optimization-record flag

-- Helper: Parse pass header to extract scope information
-- @param pass_line: line containing pass boundary marker
-- @return: pass_name, scope_type, scope_target, is_before, is_omitted
--   pass_name: base pass name (e.g., "SROAPass")
--   scope_type: "module" | "function" | "cgscc" | "unknown"
--   scope_target: "[module]" | "quicksort" | "quicksort" (CGSCC without parens)
--   is_before: true if this is a "Before" dump
--   is_omitted: true if this pass was omitted (--print-changed only)
local function parse_pass_header(pass_line)
  -- --print-changed format (no semicolon): "*** IR Dump After PassName on target ***"
  -- --print-after-all format (with semicolon): "; *** IR Dump After PassName on target ***"
  -- Handle both formats
  local pass_info, is_before, is_omitted

  -- Try "After" pattern with semicolon (--print-after-all)
  pass_info = pass_line:match("^; %*%*%* IR Dump After (.-)%s+%*%*%*$")
  is_before = false
  is_omitted = false

  if not pass_info then
    -- Try "After" pattern without semicolon (--print-changed)
    pass_info = pass_line:match("^%*%*%* IR Dump After (.-)%s+%*%*%*$")
  end

  if not pass_info then
    -- Try "Before" pattern with semicolon
    pass_info = pass_line:match("^; %*%*%* IR Dump Before (.-)%s+%*%*%*$")
    is_before = true
  end

  if not pass_info then
    -- Try "Before" pattern without semicolon
    pass_info = pass_line:match("^%*%*%* IR Dump Before (.-)%s+%*%*%*$")
    is_before = true
  end

  if not pass_info then
    return nil, nil, nil, nil, nil
  end

  -- Check if pass was omitted (--print-changed only)
  -- Format: "PassName on target omitted because no change"
  local pass_info_without_omit = pass_info:match("^(.+) omitted because no change$")
  if pass_info_without_omit then
    pass_info = pass_info_without_omit
    is_omitted = true
  end

  -- Check for module pass: "PassName on [module]"
  local pass_name, module_marker = pass_info:match("^(.+) on (%[module%])$")
  if module_marker then
    return pass_name, "module", module_marker, is_before, is_omitted
  end

  -- Check for CGSCC pass: "PassName on (func)"
  -- Extract the function name from inside parentheses
  local pass_name_cgscc, cgscc_content = pass_info:match("^(.+) on %((.+)%)$")
  if cgscc_content then
    return pass_name_cgscc, "cgscc", cgscc_content, is_before, is_omitted
  end

  -- Check for function pass: "PassName on func"
  local pass_name_func, func_name = pass_info:match("^(.+) on (.+)$")
  if func_name then
    return pass_name_func, "function", func_name, is_before, is_omitted
  end

  -- Pass without scope (shouldn't happen with -print-after-all, but handle gracefully)
  return pass_info, "unknown", nil, is_before, is_omitted
end

-- Run optimization pipeline and capture intermediate IR at each pass
-- Supports both .ll files (opt) and C/C++ files (clang)
-- @param input_file: path to .ll, .c, or .cpp file
-- @param passes_str: comma-separated pass names, "default<O2>", or "O2"
-- @param opts: optional table with:
--   - compiler: compiler path (optional, uses clang/clang++ by default)
--   - flags: additional compiler flags (optional)
--   - working_dir: working directory to run from (optional)
-- @param callback: function(passes) called when complete (nil if async not supported)
-- @return: array of {name, ir} tables if callback is nil (sync), otherwise nil (async)
function M.run_pipeline(input_file, passes_str, opts, callback)
  opts = opts or {}

  if input_file:match("%.ll$") then
    if callback then
      return run_opt_pipeline_async(input_file, passes_str, opts, callback)
    else
      return run_opt_pipeline(input_file, passes_str, opts)
    end
  elseif input_file:match("%.c$") or input_file:match("%.cpp$") then
    local godbolt = require('godbolt')
    local lang_args = opts.flags or (input_file:match("%.cpp$") and
      godbolt.config.cpp_args or godbolt.config.c_args)
    if callback then
      return run_clang_pipeline_async(input_file, passes_str, lang_args, opts, callback)
    else
      return run_clang_pipeline(input_file, passes_str, lang_args, opts)
    end
  else
    print("[" .. get_timestamp() .. "] [Pipeline] Unsupported file type: " .. input_file)
    print("[" .. get_timestamp() .. "] [Pipeline] Only .ll, .c, and .cpp files are supported")
    if callback then
      vim.schedule(function() callback(nil) end)
    end
    return nil
  end
end

-- Run opt pipeline (LLVM IR files) - ASYNC VERSION
run_opt_pipeline_async = function(input_file, passes_str, opts, callback)
  opts = opts or {}

  -- Generate remarks file path if remarks are enabled
  local remarks_file = nil
  if opts.remarks then
    local remarks_mod = require('godbolt.remarks')
    remarks_file = remarks_mod.get_remarks_file_path(input_file)
  end

  -- Build command parts
  local cmd_parts = {
    "opt",
    "--strip-debug",
    "-passes=" .. passes_str,
    "--print-changed",
  }

  -- Add optimization remarks flags if enabled
  -- Use -fsave-optimization-record to output YAML instead of -Rpass (stderr text)
  if opts.remarks and remarks_file then
    local remarks = opts.remarks
    local filters = {}

    -- Build filter list based on enabled categories
    if remarks.pass then
      table.insert(filters, "pass")
    end
    if remarks.missed then
      table.insert(filters, "missed")
    end
    if remarks.analysis then
      table.insert(filters, "analysis")
    end

    -- Add YAML output flag with filter
    if #filters > 0 then
      -- Correct format: specify 'yaml' as format, then file path separately
      table.insert(cmd_parts, "-fsave-optimization-record=yaml")
      table.insert(cmd_parts, "-foptimization-record-file=" .. remarks_file)
      -- Add filter for which passes to report (default: all via .*)
      if remarks.filter and remarks.filter ~= ".*" then
        table.insert(cmd_parts, "-foptimization-record-passes=" .. remarks.filter)
      end
    end
  end

  table.insert(cmd_parts, "-S")
  table.insert(cmd_parts, input_file)

  local cmd = table.concat(cmd_parts, " ") .. " 2>&1"

  -- Always print exact command for debugging
  vim.notify("[" .. get_timestamp() .. "] [Pipeline] Running command:")
  vim.notify("  " .. cmd)

  local start_time = vim.loop.hrtime()
  local timer = vim.loop.new_timer()
  local timer_cancelled = false

  print("[" .. get_timestamp() .. "] [Pipeline] ⏳ Compiling...")

  -- Show progress every 2 seconds
  timer:start(1000, 1000, vim.schedule_wrap(function()
    if not timer_cancelled then
      local elapsed = (vim.loop.hrtime() - start_time) / 1e9  -- Convert to seconds
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] ⏳ Still compiling... (%ds elapsed)", math.floor(elapsed)))
    end
  end))

  if M.debug then
    print("[Pipeline Debug] Command details logged above")
  end

  -- Execute command ASYNCHRONOUSLY
  local cmd_parts = vim.split(cmd, " ", {trimempty = true})
  vim.system(cmd_parts, {
    text = true,
  }, function(obj)
    vim.schedule(function()
      -- Stop progress timer
      timer_cancelled = true
      timer:stop()
      timer:close()

      local elapsed = (vim.loop.hrtime() - start_time) / 1e9

      if obj.code ~= 0 then
        print(string.format("[" .. get_timestamp() .. "] [Pipeline] ❌ Compilation failed after %.1fs (exit code %d)", elapsed, obj.code))
        print("[" .. get_timestamp() .. "] [Pipeline] stderr: " .. (obj.stderr or ""))
        callback(nil)
        return
      end

      local output = obj.stdout or ""

      if M.debug then
        print("[Pipeline Debug] Output length: " .. #output .. " bytes")
        print("[Pipeline Debug] First 500 chars of output:")
        print(string.sub(output, 1, 500))
      end

      -- Check for errors
      if output:match("^opt:") or output:match("\nopt:") then
        print(string.format("[" .. get_timestamp() .. "] [Pipeline] ❌ Compilation failed after %.1fs", elapsed))
        print(cmd)
        local lines = vim.split(output, "\n")
        for i = 1, math.min(5, #lines) do
          print(lines[i])
        end
        callback(nil)
        return
      end

      -- Parse the pipeline output
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] ✓ Compilation completed in %.1fs, parsing passes...", elapsed))
      local parse_start = vim.loop.hrtime()
      M.parse_pipeline_output_async(output, nil, function(passes)
        local parse_elapsed = (vim.loop.hrtime() - parse_start) / 1e9
        print(string.format("[" .. get_timestamp() .. "] [Pipeline] ✓ Parsing completed in %.1fs (%d passes)", parse_elapsed, #passes))

        -- Parse remarks YAML if enabled
        if opts.remarks and remarks_file then
          local remarks_mod = require('godbolt.remarks')
          local remarks_by_pass = remarks_mod.parse_remarks_yaml(remarks_file)
          passes = remarks_mod.attach_remarks_to_passes(passes, remarks_by_pass)
          remarks_mod.cleanup_remarks_file(remarks_file)

          -- Count total remarks
          local remark_count = 0
          for _, pass in ipairs(passes) do
            if pass.remarks then
              remark_count = remark_count + #pass.remarks
            end
          end
          if remark_count > 0 then
            print(string.format("[" .. get_timestamp() .. "] [Pipeline] ✓ Parsed %d optimization remarks", remark_count))
          end
        end

        callback(passes)
      end)
    end)
  end)
end

-- Run opt pipeline (LLVM IR files) - SYNC VERSION (kept for backwards compat)
run_opt_pipeline = function(input_file, passes_str, opts)
  local cmd = string.format(
    'opt --strip-debug -passes="%s" --print-after-all -S "%s" 2>&1',
    passes_str,
    input_file
  )

  vim.notify("[" .. get_timestamp() .. "] [Pipeline] Running command:")
  vim.notify("  " .. cmd)

  local output = vim.fn.system(cmd)

  if M.debug then
    print("[Pipeline Debug] Output length: " .. #output .. " bytes")
  end

  if output:match("^opt:") or output:match("\nopt:") then
    print("[" .. get_timestamp() .. "] [Pipeline] Error running opt:")
    print(cmd)
    local lines = vim.split(output, "\n")
    for i = 1, math.min(5, #lines) do
      print(lines[i])
    end
    return nil
  end

  local passes, _ = M.parse_pipeline_output(output)
  return passes
end

-- Run clang pipeline (C/C++ files) - ASYNC VERSION
run_clang_pipeline_async = function(input_file, passes_str, lang_args, opts, callback)
  opts = opts or {}

  -- Validate: only O-levels for C/C++
  local opt_level = normalize_o_level(passes_str)
  if not opt_level then
    print("[" .. get_timestamp() .. "] [Pipeline] C/C++ files only support O-levels (O0, O1, O2, O3)")
    print("[" .. get_timestamp() .. "] [Pipeline] For custom passes, compile to .ll first")
    vim.schedule(function() callback(nil) end)
    return
  end

  -- Check for LTO flags
  local args_str = type(lang_args) == "table" and table.concat(lang_args, " ") or (lang_args or "")
  if has_lto_flags(args_str) then
    print("[" .. get_timestamp() .. "] [Pipeline] Error: LTO flags detected in compiler arguments")
    print("[" .. get_timestamp() .. "] [Pipeline] LTO defers optimizations to link-time, incompatible with -print-after-all")
    print("[" .. get_timestamp() .. "] [Pipeline] Remove -flto or similar flags to view pipeline")
    vim.schedule(function() callback(nil) end)
    return
  end

  -- Generate remarks file path if remarks are enabled
  local remarks_file = nil
  if opts.remarks then
    local remarks_mod = require('godbolt.remarks')
    remarks_file = remarks_mod.get_remarks_file_path(input_file)
  end

  -- Determine compiler
  local compiler = opts.compiler or (input_file:match("%.cpp$") and "clang++" or "clang")

  -- Build command
  local cmd_parts = {
    compiler,
    "-mllvm", "-print-changed",
    "-mllvm", "-print-before-pass-number=1",
    opt_level,
    "-fno-discard-value-names",
    "-fstandalone-debug",
  }

  -- Add optimization remarks flags if enabled
  -- Use -fsave-optimization-record to output YAML instead of -Rpass (stderr text)
  if opts.remarks and remarks_file then
    local remarks = opts.remarks
    -- Correct format: specify 'yaml' as format, then file path separately
    table.insert(cmd_parts, "-fsave-optimization-record=yaml")
    table.insert(cmd_parts, "-foptimization-record-file=" .. remarks_file)

    -- Add filter for which passes to report (default: all via .*)
    if remarks.filter and remarks.filter ~= ".*" then
      table.insert(cmd_parts, "-foptimization-record-passes=" .. remarks.filter)
    end
  end

  -- Add language args
  if lang_args then
    if type(lang_args) == "string" then
      for arg in lang_args:gmatch("%S+") do
        table.insert(cmd_parts, arg)
      end
    else
      for _, arg in ipairs(lang_args) do
        table.insert(cmd_parts, arg)
      end
    end
  end

  table.insert(cmd_parts, "-S")
  table.insert(cmd_parts, "-emit-llvm")
  table.insert(cmd_parts, "-o")
  table.insert(cmd_parts, "/dev/null")
  table.insert(cmd_parts, input_file)

  -- Change to working directory if specified
  local cwd = opts.working_dir

  -- Print exact command
  local cmd_display = table.concat(cmd_parts, " ") .. " 2>&1"
  if cwd then
    cmd_display = string.format("cd %s && %s", cwd, cmd_display)
  end
  vim.notify("[" .. get_timestamp() .. "] [Pipeline] Running command:")
  vim.notify("  " .. cmd_display)

  local start_time = vim.loop.hrtime()
  local timer = vim.loop.new_timer()
  local timer_cancelled = false

  print("[" .. get_timestamp() .. "] [Pipeline] ⏳ Compiling...")

  -- Show progress every 2 seconds
  timer:start(1000, 1000, vim.schedule_wrap(function()
    if not timer_cancelled then
      local elapsed = (vim.loop.hrtime() - start_time) / 1e9  -- Convert to seconds
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] ⏳ Still compiling... (%ds elapsed)", math.floor(elapsed)))
    end
  end))

  -- Execute ASYNCHRONOUSLY
  vim.system(cmd_parts, {
    text = true,
    cwd = cwd,
    stderr = true,
    stdout = true,
  }, function(obj)
    vim.schedule(function()
      -- Stop progress timer
      timer_cancelled = true
      timer:stop()
      timer:close()

      local elapsed = (vim.loop.hrtime() - start_time) / 1e9

      if obj.code ~= 0 then
        print(string.format("[" .. get_timestamp() .. "] [Pipeline] ❌ Compilation failed after %.1fs (exit code %d)", elapsed, obj.code))
        local output = (obj.stdout or "") .. (obj.stderr or "")
        local lines = vim.split(output, "\n")
        for i = 1, math.min(10, #lines) do
          print(lines[i])
        end
        callback(nil)
        return
      end

      -- Combine stdout and stderr
      local output = (obj.stdout or "") .. (obj.stderr or "")

      if M.debug then
        print("[Pipeline Debug] Output length: " .. #output .. " bytes")
      end

      -- Check for errors
      if output:match("error:") or output:match("fatal error:") then
        print(string.format("[" .. get_timestamp() .. "] [Pipeline] ❌ Compilation failed after %.1fs", elapsed))
        local lines = vim.split(output, "\n")
        for i = 1, math.min(10, #lines) do
          print(lines[i])
        end
        callback(nil)
        return
      end

      -- Parse pipeline output
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] ✓ Compilation completed in %.1fs, parsing passes...", elapsed))
      local parse_start = vim.loop.hrtime()
      M.parse_pipeline_output_async(output, "clang", function(passes, initial_ir)
        local parse_elapsed = (vim.loop.hrtime() - parse_start) / 1e9
        print(string.format("[" .. get_timestamp() .. "] [Pipeline] ✓ Parsing completed in %.1fs (%d passes)", parse_elapsed, #passes))

        -- Cache initial IR
        if initial_ir then
          M._cached_initial_ir = {
            file = input_file,
            ir = initial_ir,
          }
        end

        -- Parse remarks YAML if enabled
        if opts.remarks and remarks_file then
          local remarks_mod = require('godbolt.remarks')
          local remarks_by_pass = remarks_mod.parse_remarks_yaml(remarks_file)
          passes = remarks_mod.attach_remarks_to_passes(passes, remarks_by_pass)
          remarks_mod.cleanup_remarks_file(remarks_file)

          -- Count total remarks
          local remark_count = 0
          for _, pass in ipairs(passes) do
            if pass.remarks then
              remark_count = remark_count + #pass.remarks
            end
          end
          if remark_count > 0 then
            print(string.format("[" .. get_timestamp() .. "] [Pipeline] ✓ Parsed %d optimization remarks", remark_count))
          end
        end

        callback(passes)
      end)
    end)
  end)
end

-- Run clang pipeline (C/C++ files) - SYNC VERSION (kept for backwards compat)
run_clang_pipeline = function(input_file, passes_str, lang_args, opts)
  opts = opts or {}

  -- Validate: only O-levels for C/C++
  local opt_level = normalize_o_level(passes_str)
  if not opt_level then
    print("[" .. get_timestamp() .. "] [Pipeline] C/C++ files only support O-levels (O0, O1, O2, O3)")
    print("[" .. get_timestamp() .. "] [Pipeline] For custom passes, compile to .ll first:")
    print("  :Godbolt -emit-llvm -O0 -Xclang -disable-O0-optnone")
    print("  Then in the .ll file: :GodboltPipeline mem2reg,instcombine")
    return nil
  end

  -- Check for LTO flags
  local args_str = type(lang_args) == "table" and table.concat(lang_args, " ") or (lang_args or "")
  if has_lto_flags(args_str) then
    print("[" .. get_timestamp() .. "] [Pipeline] Error: LTO flags detected in compiler arguments")
    print("[" .. get_timestamp() .. "] [Pipeline] LTO defers optimizations to link-time, incompatible with -print-after-all")
    print("[" .. get_timestamp() .. "] [Pipeline] Remove -flto or similar flags to view pipeline")
    return nil
  end

  -- Determine compiler (use from opts or default to clang/clang++)
  local compiler = opts.compiler or (input_file:match("%.cpp$") and "clang++" or "clang")

  -- Build command: clang -mllvm -print-changed -mllvm -print-before-pass-number=1 <opt-level> <args> -S -emit-llvm -o /dev/null file.c
  local cmd_parts = {
    compiler,
    "-mllvm", "-print-changed",
    "-mllvm", "-print-before-pass-number=1",
    opt_level,
  }

  -- Add introspection flags for better IR readability and debug info
  table.insert(cmd_parts, "-fno-discard-value-names")  -- Keep SSA value names (%foo vs %1)
  table.insert(cmd_parts, "-fstandalone-debug")        -- Complete debug info (not minimal)

  -- Add language args
  if lang_args then
    if type(lang_args) == "string" then
      -- Split string into individual args
      for arg in lang_args:gmatch("%S+") do
        table.insert(cmd_parts, arg)
      end
    else
      -- lang_args is a table
      for _, arg in ipairs(lang_args) do
        table.insert(cmd_parts, arg)
      end
    end
  end

  -- Add output options
  table.insert(cmd_parts, "-S")
  table.insert(cmd_parts, "-emit-llvm")
  table.insert(cmd_parts, "-o")
  table.insert(cmd_parts, "/dev/null")
  table.insert(cmd_parts, '"' .. input_file .. '"')

  -- Redirect stderr to stdout to capture -print-after-all output
  local cmd = table.concat(cmd_parts, " ") .. " 2>&1"

  -- If working_dir is specified, prepend cd command
  if opts.working_dir then
    cmd = string.format("cd %s && %s", vim.fn.shellescape(opts.working_dir), cmd)
  end

  -- Always print exact command for debugging
  print("[" .. get_timestamp() .. "] [Pipeline] Running command:")
  print("  " .. cmd)

  if M.debug then
    print("[Pipeline Debug] Command details logged above")
  end

  -- Execute command and capture output
  local output = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error

  if M.debug then
    print("[Pipeline Debug] Output length: " .. #output .. " bytes")
    print("[Pipeline Debug] Exit code: " .. exit_code)
    print("[Pipeline Debug] First 500 chars of output:")
    print(string.sub(output, 1, 500))
  end

  -- Check for compilation errors (non-zero exit code or explicit error messages)
  if exit_code ~= 0 or (output:match("error:") or output:match("fatal error:")) then
    print("[" .. get_timestamp() .. "] [Pipeline] Compilation error:")
    print(cmd)
    local lines = vim.split(output, "\n")
    for i = 1, math.min(10, #lines) do
      print(lines[i])
    end
    return nil
  end

  -- Parse the pipeline output to get passes and initial IR
  local passes, initial_ir = M.parse_pipeline_output(output, "clang")

  -- Cache initial IR if we got one (for get_stripped_input to use)
  if initial_ir then
    M._cached_initial_ir = {
      file = input_file,
      ir = initial_ir
    }
    if M.debug then
      print(string.format("[Pipeline Debug] Cached initial IR for %s (%d lines)", input_file, #initial_ir))
    end
  else
    -- Clear cache if no initial IR
    M._cached_initial_ir = nil
  end

  return passes
end

-- Parse pipeline output into pass stages - ASYNC VERSION
-- Processes output in chunks to avoid UI freeze with large pipelines (90K+ passes)
-- @param output: raw output from opt/clang command
-- @param source_type: "opt" or "clang" (default "opt")
-- @param callback: function(passes, initial_ir) called when complete
function M.parse_pipeline_output_async(output, source_type, callback)
  source_type = source_type or "opt"

  local passes = {}
  local initial_ir = nil
  local initial_scope_type = nil
  local current_pass = nil
  local current_scope_type = nil
  local current_scope_target = nil
  local current_ir = {}
  local current_is_before = false
  local current_before_ir = nil
  local pass_boundary_count = 0
  local seen_module_id = false

  -- Track last IR for each scope (for --print-changed optimization)
  local last_module_ir = nil
  local last_ir_by_function = {}
  local last_ir_by_cgscc = {}

  -- Split output into lines ONCE (not in chunks to avoid complexity)
  local lines = {}
  for line in output:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end

  local total_lines = #lines
  local chunk_size = 500  -- Smaller chunks = smoother UI (yield more frequently)
  local start_time = vim.loop.hrtime()
  local last_print_time = start_time

  print(string.format("[" .. get_timestamp() .. "] [Pipeline] [Parse] Processing %d lines in chunks of %d", total_lines, chunk_size))

  local function process_chunk(chunk_start)
    if chunk_start > total_lines then
      -- Finished all lines, now clean IR in final pass
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] [Parse] Line processing complete, cleaning IR for %d passes", #passes))

      -- Clean all IR at once (do heavy work in one batch at the end)
      local clean_start = vim.loop.hrtime()
      for _, pass in ipairs(passes) do
        if pass.ir and not pass.cleaned then
          pass.ir = ir_utils.clean_ir(pass.ir, pass.scope_type)
          pass.cleaned = true
        end
        if pass.before_ir and not pass.before_cleaned then
          pass.before_ir = ir_utils.clean_ir(pass.before_ir, pass.scope_type)
          pass.before_cleaned = true
        end
      end

      if initial_ir then
        initial_ir = ir_utils.clean_ir(initial_ir, initial_scope_type)
      end

      local clean_elapsed = (vim.loop.hrtime() - clean_start) / 1e9
      local total_elapsed = (vim.loop.hrtime() - start_time) / 1e9
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] [Parse] [%.3fs] IR cleaning took %.3fs", total_elapsed, clean_elapsed))
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] [Parse] [%.3fs] Completed (%d passes)", total_elapsed, #passes))
      callback(passes, initial_ir)
      return
    end

    local chunk_end = math.min(chunk_start + chunk_size - 1, total_lines)

    -- Show progress every 2 seconds
    local current_time = vim.loop.hrtime()
    local elapsed_since_print = (current_time - last_print_time) / 1e9
    if chunk_start > 1 and elapsed_since_print >= 2.0 then
      local total_elapsed = (current_time - start_time) / 1e9
      local percent = math.floor((chunk_end / total_lines) * 100)
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] [Parse] [%.3fs] Processing... (%d%%)", total_elapsed, percent))
      last_print_time = current_time
      vim.cmd('redraw')
    end

    -- Process this chunk synchronously
    for line_idx = chunk_start, chunk_end do
      local line = lines[line_idx]

      local pass_name, scope_type, scope_target, is_before, is_omitted = parse_pass_header(line)

      if pass_name then
        pass_boundary_count = pass_boundary_count + 1

        -- Save previous pass/before dump if exists
        if current_pass and #current_ir > 0 then
          if current_is_before then
            -- Store raw IR, clean later
            current_before_ir = current_ir
            if not initial_ir and current_scope_type == "module" then
              initial_ir = current_ir
              initial_scope_type = current_scope_type
            end
          else
            if is_llvm_ir(current_ir) or #current_ir == 0 then
              -- Store raw IR, clean later
              table.insert(passes, {
                name = current_pass,
                scope_type = current_scope_type,
                scope_target = current_scope_target,
                ir = current_ir,  -- Raw, not cleaned
                before_ir = current_before_ir,
                cleaned = false,
              })

              -- Update last IR tracking
              if current_scope_type == "module" then
                last_module_ir = current_ir
              elseif current_scope_type == "function" and current_scope_target then
                last_ir_by_function[current_scope_target] = current_ir
              elseif current_scope_type == "cgscc" and current_scope_target then
                last_ir_by_cgscc[current_scope_target] = current_ir
              end

              current_before_ir = nil
            else
              current_before_ir = nil
            end
          end
        end

        -- Handle omitted passes
        if is_omitted then
          if scope_target then
            current_pass = pass_name .. " on " .. (scope_type == "module" and scope_target or
                                                    scope_type == "cgscc" and "(" .. scope_target .. ")" or
                                                    scope_target)
          else
            current_pass = pass_name
          end

          local copied_ir = nil
          if scope_type == "module" then
            copied_ir = last_module_ir or initial_ir
          elseif scope_type == "function" and scope_target then
            copied_ir = last_ir_by_function[scope_target]
            if not copied_ir and last_module_ir then
              copied_ir = ir_utils.extract_function(last_module_ir, scope_target)
              if copied_ir and #copied_ir > 0 then
                last_ir_by_function[scope_target] = copied_ir
              end
            end
          elseif scope_type == "cgscc" and scope_target then
            copied_ir = last_ir_by_cgscc[scope_target]
            if not copied_ir and last_module_ir then
              copied_ir = ir_utils.extract_function(last_module_ir, scope_target)
              if copied_ir and #copied_ir > 0 then
                last_ir_by_cgscc[scope_target] = copied_ir
              end
            end
          end

          if copied_ir then
            table.insert(passes, {
              name = current_pass,
              scope_type = scope_type,
              scope_target = scope_target,
              ir = copied_ir,
              changed = false,
            })
          end

          current_pass = nil
          current_scope_type = nil
          current_scope_target = nil
          current_ir = {}
          current_is_before = false
          seen_module_id = false
        else
          -- Start new pass
          if scope_target then
            current_pass = pass_name .. " on " .. (scope_type == "module" and scope_target or
                                                    scope_type == "cgscc" and "(" .. scope_target .. ")" or
                                                    scope_target)
          else
            current_pass = pass_name
          end
          current_scope_type = scope_type
          current_scope_target = scope_target
          current_is_before = is_before
          current_ir = {}
          seen_module_id = false
        end

      elseif current_pass then
        if source_type == "opt" and line:match("^; ModuleID = ") and #current_ir > 20 then
          -- Final output marker for opt
          if current_pass and #current_ir > 0 then
            if is_llvm_ir(current_ir) or #current_ir == 0 then
              table.insert(passes, {
                name = current_pass,
                scope_type = current_scope_type,
                scope_target = current_scope_target,
                ir = current_ir,  -- Raw, will be cleaned in finalization
                cleaned = false,
              })
            end
          end
          -- Early exit - skip to cleaning phase
          chunk_start = total_lines + 1
          vim.schedule(function()
            process_chunk(chunk_start)
          end)
          return
        else
          table.insert(current_ir, line)
        end
      end
    end

    -- Schedule next chunk
    vim.schedule(function()
      process_chunk(chunk_start + chunk_size)
    end)
  end

  process_chunk(1)
end

-- Parse pipeline output into pass stages
-- @param output: raw output from opt/clang command
-- @param source_type: "opt" or "clang" (default "opt")
-- @return: passes array, initial_ir (or nil if not found)
function M.parse_pipeline_output(output, source_type)
  source_type = source_type or "opt"

  local passes = {}
  local initial_ir = nil
  local initial_scope_type = nil
  local current_pass = nil
  local current_scope_type = nil
  local current_scope_target = nil
  local current_ir = {}
  local current_is_before = false
  local current_before_ir = nil  -- Store before IR for the current pass
  local line_count = 0
  local pass_boundary_count = 0
  local seen_module_id = false

  -- Track last IR for each scope (for --print-changed optimization)
  -- When a pass is omitted, we copy IR from the appropriate last_* variable
  local last_module_ir = nil  -- Last module-scoped IR
  local last_ir_by_function = {}  -- last_ir_by_function["foo"] = {...}
  local last_ir_by_cgscc = {}  -- last_ir_by_cgscc["foo"] = {...}

  for line in output:gmatch("[^\r\n]+") do
    line_count = line_count + 1

    -- Try to parse pass header to extract scope information
    local pass_name, scope_type, scope_target, is_before, is_omitted = parse_pass_header(line)

    if pass_name then
      pass_boundary_count = pass_boundary_count + 1

      if M.debug then
        local omit_str = is_omitted and " (OMITTED)" or ""
        print(string.format("[Pipeline Debug] Found %s boundary at line %d: '%s' (scope: %s, target: %s)%s",
          is_before and "Before" or "After", line_count, pass_name, scope_type or "none", scope_target or "none", omit_str))
      end

      -- Save previous pass/before dump if exists
      if current_pass and #current_ir > 0 then
        if current_is_before then
          -- This is a "Before" dump - save it for pairing with the "After" dump
          current_before_ir = ir_utils.clean_ir(current_ir, current_scope_type)

          -- Also save as initial IR if it's the first module-scoped before dump
          if not initial_ir and current_scope_type == "module" then
            initial_ir = current_before_ir
            initial_scope_type = current_scope_type
            if M.debug then
              print(string.format("[Pipeline Debug] Saved initial IR (module-scoped) with %d lines", #current_ir))
            end
          end

          if M.debug then
            print(string.format("[Pipeline Debug] Saved Before IR for pairing with %d lines", #current_ir))
          end
        else
          -- This is an "After" dump - save as pass with before_ir if available
          -- Validate it's LLVM IR before saving (filter out MIR, assembly, etc.)
          if is_llvm_ir(current_ir) or #current_ir == 0 then
            local cleaned_ir = ir_utils.clean_ir(current_ir, current_scope_type)
            table.insert(passes, {
              name = current_pass,
              scope_type = current_scope_type,
              scope_target = current_scope_target,
              ir = cleaned_ir,
              before_ir = current_before_ir,  -- Attach the before IR
            })

            -- Update last IR tracking for --print-changed
            if current_scope_type == "module" then
              last_module_ir = cleaned_ir
            elseif current_scope_type == "function" and current_scope_target then
              last_ir_by_function[current_scope_target] = cleaned_ir
            elseif current_scope_type == "cgscc" and current_scope_target then
              last_ir_by_cgscc[current_scope_target] = cleaned_ir
            end

            if M.debug then
              local before_info = current_before_ir and string.format(" (with before: %d lines)", #current_before_ir) or ""
              print(string.format("[Pipeline Debug] Saved pass '%s' with %d IR lines%s", current_pass, #current_ir, before_info))
            end
            current_before_ir = nil  -- Clear for next pass
          else
            if M.debug then
              print(string.format("[Pipeline Debug] Skipped pass '%s' - not LLVM IR (likely MIR or assembly)", current_pass))
            end
            current_before_ir = nil  -- Clear even if skipped
          end
        end
      end

      -- Handle omitted passes (--print-changed only)
      if is_omitted then
        -- Reconstruct full pass name with scope for display
        if scope_target then
          current_pass = pass_name .. " on " .. (scope_type == "module" and scope_target or
                                                  scope_type == "cgscc" and "(" .. scope_target .. ")" or
                                                  scope_target)
        else
          current_pass = pass_name
        end

        -- Copy IR from appropriate last_* variable
        local copied_ir = nil
        if scope_type == "module" then
          copied_ir = last_module_ir or initial_ir
        elseif scope_type == "function" and scope_target then
          copied_ir = last_ir_by_function[scope_target]
          -- Fallback: If this function hasn't appeared yet, try to extract from last module
          if not copied_ir and last_module_ir then
            copied_ir = ir_utils.extract_function(last_module_ir, scope_target)
            if copied_ir and #copied_ir > 0 then
              last_ir_by_function[scope_target] = copied_ir
            end
          end
        elseif scope_type == "cgscc" and scope_target then
          copied_ir = last_ir_by_cgscc[scope_target]
          -- Fallback: Try extracting from module
          if not copied_ir and last_module_ir then
            copied_ir = ir_utils.extract_function(last_module_ir, scope_target)
            if copied_ir and #copied_ir > 0 then
              last_ir_by_cgscc[scope_target] = copied_ir
            end
          end
        end

        if copied_ir then
          table.insert(passes, {
            name = current_pass,
            scope_type = scope_type,
            scope_target = scope_target,
            ir = copied_ir,
            changed = false,  -- Mark as unchanged for optimization
          })
          if M.debug then
            print(string.format("[Pipeline Debug] Saved omitted pass '%s' with copied IR (%d lines)", current_pass, #copied_ir))
          end
        else
          if M.debug then
            print(string.format("[Pipeline Debug] WARNING: Could not copy IR for omitted pass '%s'", current_pass))
          end
        end

        -- Reset state for next pass (omitted passes have no IR content)
        current_pass = nil
        current_scope_type = nil
        current_scope_target = nil
        current_ir = {}
        current_is_before = false
        seen_module_id = false
      else
        -- Start new pass (not omitted)
        -- Reconstruct full pass name with scope for display
        if scope_target then
          current_pass = pass_name .. " on " .. (scope_type == "module" and scope_target or
                                                  scope_type == "cgscc" and "(" .. scope_target .. ")" or
                                                  scope_target)
        else
          current_pass = pass_name
        end
        current_scope_type = scope_type
        current_scope_target = scope_target
        current_is_before = is_before
        current_ir = {}
        seen_module_id = false
      end

    elseif current_pass then
      -- Detect final output (ModuleID in stdout means we're done with pass dumps)
      -- NOTE: With --print-after-all, ModuleID only appears in final stdout
      -- But with --print-changed, module passes include ModuleID in their dumps!
      -- So we can't use ModuleID as an early-exit signal anymore.
      -- Instead, just keep collecting IR and let the pass parsing handle it.
      -- The final stdout will be there but won't match any dump headers.
      --
      -- For clang, ModuleID appears at the start of each pass dump, so we never used this anyway.
      if source_type == "opt" and line:match("^; ModuleID = ") and #current_ir > 20 then
        -- ONLY treat as final output if we've collected substantial IR (>20 lines)
        -- If current_ir is nearly empty, we just started a module pass dump
        -- (--print-changed includes ModuleID in module pass dumps)
        if M.debug then
          print(string.format("[Pipeline Debug] Found final output at line %d, stopping collection", line_count))
        end
        -- Save the current pass and stop processing
        if current_pass and #current_ir > 0 then
          if is_llvm_ir(current_ir) or #current_ir == 0 then
            table.insert(passes, {
              name = current_pass,
              scope_type = current_scope_type,
              scope_target = current_scope_target,
              ir = ir_utils.clean_ir(current_ir, current_scope_type),
            })
            if M.debug then
              print(string.format("[Pipeline Debug] Saved final pass '%s' with %d IR lines", current_pass, #current_ir))
            end
          else
            if M.debug then
              print(string.format("[Pipeline Debug] Skipped final pass '%s' - not LLVM IR (likely MIR or assembly)", current_pass))
            end
          end
        end
        break
      else
        -- We're inside a pass dump - collect all lines
        -- Skip "ignored" and PassManager messages from LLVM output
        if not line:match("^%*%*%* IR Pass .* ignored %*%*%*$") and
           not line:match("^; %*%*%* IR Pass .* ignored %*%*%*$") and
           not line:match("^%*%*%* IR Pass PassManager") and
           not line:match("^; %*%*%* IR Pass PassManager") then
          table.insert(current_ir, line)
        end
      end
    end
  end

  -- Save last pass if we didn't hit the final output marker
  if current_pass and #current_ir > 0 and #passes == pass_boundary_count - 1 then
    if current_is_before then
      -- Last dump was a "Before" dump - save as initial IR
      if current_scope_type == "module" then
        initial_ir = ir_utils.clean_ir(current_ir, current_scope_type)
        initial_scope_type = current_scope_type
        if M.debug then
          print(string.format("[Pipeline Debug] Saved final Before dump as initial IR (module-scoped) with %d lines", #current_ir))
        end
      end
    else
      -- Last dump was an "After" dump - save as pass
      if is_llvm_ir(current_ir) or #current_ir == 0 then
        table.insert(passes, {
          name = current_pass,
          scope_type = current_scope_type,
          scope_target = current_scope_target,
          ir = ir_utils.clean_ir(current_ir, current_scope_type),
        })
        if M.debug then
          print(string.format("[Pipeline Debug] Saved final pass '%s' with %d IR lines", current_pass, #current_ir))
        end
      else
        if M.debug then
          print(string.format("[Pipeline Debug] Skipped final pass '%s' - not LLVM IR (likely MIR or assembly)", current_pass))
        end
      end
    end
  end

  if M.debug then
    print(string.format("[Pipeline Debug] Parsing summary:"))
    print(string.format("  Total lines processed: %d", line_count))
    print(string.format("  Pass boundaries found: %d", pass_boundary_count))
    print(string.format("  Passes captured: %d", #passes))
    print(string.format("  Initial IR captured: %s", initial_ir and "yes" or "no"))
    if #passes > 0 then
      print(string.format("  First pass: '%s'", passes[1].name))
      print(string.format("  Last pass: '%s'", passes[#passes].name))
    end
  end

  return passes, initial_ir
end

-- Get predefined O-level pipeline string
-- @param level: "O0", "O1", "O2", or "O3"
-- @return: pipeline string for opt -passes
function M.get_o_level_pipeline(level)
  local level_map = {
    O0 = "default<O0>",
    O1 = "default<O1>",
    O2 = "default<O2>",
    O3 = "default<O3>",
  }

  return level_map[level] or level_map.O2
end

-- Filter passes to only those that changed the IR
-- @param passes: array of {name, ir} tables
-- @return: filtered array with only passes that modified IR
function M.filter_changed_passes(passes)
  if #passes == 0 then
    return passes
  end

  local filtered = {passes[1]} -- Always include first pass

  for i = 2, #passes do
    -- Compare IR with previous pass
    if not M.ir_equal(passes[i-1].ir, passes[i].ir) then
      table.insert(filtered, passes[i])
    end
  end

  return filtered
end

-- Compare two IR arrays for equality
-- @param ir1: array of IR lines
-- @param ir2: array of IR lines
-- @return: true if identical
function M.ir_equal(ir1, ir2)
  if #ir1 ~= #ir2 then
    return false
  end

  for i = 1, #ir1 do
    if ir1[i] ~= ir2[i] then
      return false
    end
  end

  return true
end

-- Get stripped input IR
-- For .ll files: runs opt --strip-debug
-- For .c/.cpp files: uses cached initial IR if available, otherwise compiles to LLVM IR with -O0
-- @param input_file: path to .ll, .c, or .cpp file
-- @return: array of IR lines with debug info removed
function M.get_stripped_input(input_file)
  -- Handle C/C++ files by checking cache first, then compiling to LLVM IR
  if input_file:match("%.c$") or input_file:match("%.cpp$") then
    -- Check if we have cached initial IR from -print-before-pass-number=1
    if M._cached_initial_ir and M._cached_initial_ir.file == input_file then
      if M.debug then
        print(string.format("[Pipeline Debug] Using cached initial IR for %s (%d lines)",
          input_file, #M._cached_initial_ir.ir))
      end
      return M._cached_initial_ir.ir
    end

    -- No cache, compile with -O0 as fallback
    if M.debug then
      print("[Pipeline Debug] No cached initial IR, compiling with -O0")
    end

    local compiler = input_file:match("%.cpp$") and "clang++" or "clang"
    local godbolt = require('godbolt')
    local lang_args = input_file:match("%.cpp$") and
      godbolt.config.cpp_args or godbolt.config.c_args

    -- Build command to compile to LLVM IR with -O0 (unoptimized initial state)
    local cmd_parts = {
      compiler,
      "-O0",
      "-Xclang", "-disable-O0-optnone",  -- Allow optimization passes to run on O0 code
    }

    -- Add language args if they exist
    if lang_args then
      if type(lang_args) == "string" then
        for arg in lang_args:gmatch("%S+") do
          table.insert(cmd_parts, arg)
        end
      else
        for _, arg in ipairs(lang_args) do
          table.insert(cmd_parts, arg)
        end
      end
    end

    table.insert(cmd_parts, "-S")
    table.insert(cmd_parts, "-emit-llvm")
    table.insert(cmd_parts, "-o")
    table.insert(cmd_parts, "-")  -- Output to stdout
    table.insert(cmd_parts, '"' .. input_file .. '"')

    local cmd = table.concat(cmd_parts, " ") .. " 2>&1"

    if M.debug then
      print("[Pipeline Debug] Compiling C/C++ to initial IR with: " .. cmd)
    end

    local output = vim.fn.system(cmd)

    -- Check for compilation errors
    if vim.v.shell_error ~= 0 then
      if M.debug then
        print("[Pipeline Debug] Error compiling C/C++ file to IR")
      end
      return {}
    end

    -- Split into lines
    local lines = {}
    for line in output:gmatch("[^\r\n]+") do
      table.insert(lines, line)
    end

    if M.debug then
      print(string.format("[Pipeline Debug] Got %d lines of initial IR from C/C++", #lines))
    end

    return lines
  end

  -- Handle .ll files with opt --strip-debug
  local cmd = string.format('opt --strip-debug -S "%s" 2>&1', input_file)

  if M.debug then
    print("[Pipeline Debug] Getting stripped input with: " .. cmd)
  end

  local output = vim.fn.system(cmd)

  -- Check for errors
  if output:match("^opt:") or output:match("\nopt:") then
    if M.debug then
      print("[Pipeline Debug] Error stripping input, falling back to raw file")
    end
    return M.read_input_file(input_file)
  end

  -- Split into lines
  local lines = {}
  for line in output:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end

  if M.debug then
    print(string.format("[Pipeline Debug] Got %d lines of stripped input", #lines))
  end

  return lines
end

-- Read and parse the input LLVM IR file (raw, with debug info)
-- @param input_file: path to .ll file
-- @return: array of IR lines
function M.read_input_file(input_file)
  local file = io.open(input_file, "r")
  if not file then
    if M.debug then
      print("[Pipeline Debug] Failed to open input file: " .. input_file)
    end
    return {}
  end

  local content = file:read("*all")
  file:close()

  -- Split into lines
  local lines = {}
  for line in content:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end

  if M.debug then
    print(string.format("[Pipeline Debug] Read %d lines from input file", #lines))
  end

  return lines
end

return M

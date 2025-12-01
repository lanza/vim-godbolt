-- Helper to get timestamp string
local function get_timestamp()
  return os.date("%H:%M:%S")
end

local M = {}

local ir_utils = require('godbolt.ir_utils')

-- Debug flag - set to true to see detailed logging
M.debug = false

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
    return run_opt_pipeline_async(input_file, passes_str, opts, callback)
  elseif input_file:match("%.c$") or input_file:match("%.cpp$") then
    local godbolt = require('godbolt')
    local lang_args = opts.flags or (input_file:match("%.cpp$") and
      godbolt.config.cpp_args or godbolt.config.c_args)
    return run_clang_pipeline_async(input_file, passes_str, lang_args, opts, callback)
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
    "--print-module-scope",  -- Always print full module IR (not just function/loop fragments)
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

  -- Always print exact command for debugging
  local cmd_display = table.concat(cmd_parts, " ")
  vim.notify("[" .. get_timestamp() .. "] [Pipeline] Running command:")
  vim.notify("  " .. cmd_display)

  local start_time = vim.loop.hrtime()
  local timer = vim.loop.new_timer()
  local timer_cancelled = false

  print("[" .. get_timestamp() .. "] [Pipeline] ⏳ Compiling...")

  -- Show progress every 2 seconds
  timer:start(1000, 1000, vim.schedule_wrap(function()
    if not timer_cancelled then
      local elapsed = (vim.loop.hrtime() - start_time) / 1e9 -- Convert to seconds
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] ⏳ Still compiling... (%ds elapsed)",
        math.floor(elapsed)))
    end
  end))

  if M.debug then
    print("[Pipeline Debug] Command details logged above")
  end

  -- Execute command ASYNCHRONOUSLY
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
        print(string.format("[" .. get_timestamp() .. "] [Pipeline] ❌ Compilation failed after %.1fs (exit code %d)",
          elapsed, obj.code))
        print("[" .. get_timestamp() .. "] [Pipeline] stderr: " .. (obj.stderr or ""))
        callback(nil)
        return
      end

      -- Combine stdout and stderr (opt --print-changed outputs to stderr)
      -- Note: stderr contains the IR dumps, stdout contains final IR
      local output = (obj.stderr or "") .. (obj.stdout or "")

      if M.debug then
        print("[Pipeline Debug] Output length: " .. #output .. " bytes")
        print("[Pipeline Debug] First 500 chars of output:")
        print(string.sub(output, 1, 500))
      end

      -- Check for errors
      if output:match("^opt:") or output:match("\nopt:") then
        print(string.format("[" .. get_timestamp() .. "] [Pipeline] ❌ Compilation failed after %.1fs", elapsed))
        print(cmd_display)
        local lines = vim.split(output, "\n")
        for i = 1, math.min(5, #lines) do
          print(lines[i])
        end
        callback(nil)
        return
      end

      -- Parse the pipeline output using new lazy parser
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] ✓ Compilation completed in %.1fs, parsing passes...",
        elapsed))
      local parse_start = vim.loop.hrtime()

      local result = M.parse_pipeline_lazy(output, "opt")
      local parse_elapsed = (vim.loop.hrtime() - parse_start) / 1e9
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] ✓ Parsing completed in %.1fs (%d passes)",
        parse_elapsed, #result.passes))

      -- Clear resolution cache before resolving passes
      M.ir_resolver.clear_cache()

      -- Resolve ir_or_index to .ir for all passes
      local passes = result.passes
      for i, pass in ipairs(passes) do
        pass._initial_ir = result.initial_ir
        pass.ir = M.ir_resolver.get_after_ir(passes, result.initial_ir, i)
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
    "-mllvm", "-print-module-scope",  -- Always print full module IR (not just function/loop fragments)
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
      local elapsed = (vim.loop.hrtime() - start_time) / 1e9 -- Convert to seconds
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] ⏳ Still compiling... (%ds elapsed)",
        math.floor(elapsed)))
    end
  end))

  -- Execute ASYNCHRONOUSLY
  vim.system(cmd_parts, {
    text = true,
    cwd = cwd,
  }, function(obj)
    vim.schedule(function()
      -- Stop progress timer
      timer_cancelled = true
      timer:stop()
      timer:close()

      local elapsed = (vim.loop.hrtime() - start_time) / 1e9

      if obj.code ~= 0 then
        print(string.format("[" .. get_timestamp() .. "] [Pipeline] ❌ Compilation failed after %.1fs (exit code %d)",
          elapsed, obj.code))
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

      -- Parse pipeline output using new lazy parser
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] ✓ Compilation completed in %.1fs, parsing passes...",
        elapsed))
      local parse_start = vim.loop.hrtime()

      local result = M.parse_pipeline_lazy(output, "clang")
      local parse_elapsed = (vim.loop.hrtime() - parse_start) / 1e9
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] ✓ Parsing completed in %.1fs (%d passes)",
        parse_elapsed, #result.passes))

      -- Cache initial IR
      if result.initial_ir then
        M._cached_initial_ir = {
          file = input_file,
          ir = result.initial_ir,
        }
      end

      -- Clear resolution cache before resolving passes
      M.ir_resolver.clear_cache()

      -- Resolve ir_or_index to .ir for all passes
      local passes = result.passes
      for i, pass in ipairs(passes) do
        pass._initial_ir = result.initial_ir
        pass.ir = M.ir_resolver.get_after_ir(passes, result.initial_ir, i)
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
end

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

  local filtered = { passes[1] } -- Always include first pass

  for i = 2, #passes do
    -- Compare IR with previous pass
    if not M.ir_equal(passes[i - 1].ir, passes[i].ir) then
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
    -- Check if we have cached initial IR from "IR Dump At Start"
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
      "-Xclang", "-disable-O0-optnone", -- Allow optimization passes to run on O0 code
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
    table.insert(cmd_parts, "-") -- Output to stdout
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

-- New lazy IR infrastructure (experimental)
M.ir_parser = require('godbolt.ir_parser')
M.ir_resolver = require('godbolt.ir_resolver')
M.pipeline_parser = require('godbolt.pipeline_parser')

function M.parse_pipeline_lazy(output, source_type)
  return M.pipeline_parser.parse_pipeline_output_lazy(output, source_type)
end

return M

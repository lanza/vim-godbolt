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

-- Helper: Parse pass header to extract scope information
-- @param pass_line: line containing pass boundary marker
-- @return: pass_name, scope_type, scope_target
--   pass_name: base pass name (e.g., "SROAPass")
--   scope_type: "module" | "function" | "cgscc" | "unknown"
--   scope_target: "[module]" | "quicksort" | "quicksort" (CGSCC without parens)
local function parse_pass_header(pass_line)
  local pass_info = pass_line:match("^; %*%*%* IR Dump After (.-)%s+%*%*%*$")
  if not pass_info then
    return nil, nil, nil
  end

  -- Check for module pass: "PassName on [module]"
  local pass_name, module_marker = pass_info:match("^(.+) on (%[module%])$")
  if module_marker then
    return pass_name, "module", module_marker
  end

  -- Check for CGSCC pass: "PassName on (func)"
  -- Extract the function name from inside parentheses
  local pass_name_cgscc, cgscc_content = pass_info:match("^(.+) on %((.+)%)$")
  if cgscc_content then
    return pass_name_cgscc, "cgscc", cgscc_content
  end

  -- Check for function pass: "PassName on func"
  local pass_name_func, func_name = pass_info:match("^(.+) on (.+)$")
  if func_name then
    return pass_name_func, "function", func_name
  end

  -- Pass without scope (shouldn't happen with -print-after-all, but handle gracefully)
  return pass_info, "unknown", nil
end

-- Run optimization pipeline and capture intermediate IR at each pass
-- Supports both .ll files (opt) and C/C++ files (clang)
-- @param input_file: path to .ll, .c, or .cpp file
-- @param passes_str: comma-separated pass names, "default<O2>", or "O2"
-- @return: array of {name, ir} tables, one per pass
function M.run_pipeline(input_file, passes_str)
  if input_file:match("%.ll$") then
    return run_opt_pipeline(input_file, passes_str)
  elseif input_file:match("%.c$") or input_file:match("%.cpp$") then
    local godbolt = require('godbolt')
    local lang_args = input_file:match("%.cpp$") and
      godbolt.config.cpp_args or godbolt.config.c_args
    return run_clang_pipeline(input_file, passes_str, lang_args)
  else
    print("[Pipeline] Unsupported file type: " .. input_file)
    print("[Pipeline] Only .ll, .c, and .cpp files are supported")
    return nil
  end
end

-- Run opt pipeline (LLVM IR files)
-- @param input_file: path to .ll file
-- @param passes_str: comma-separated pass names or "default<O2>"
-- @return: array of {name, ir} tables, one per pass
run_opt_pipeline = function(input_file, passes_str)
  local cmd = string.format(
    'opt --strip-debug -passes="%s" --print-after-all -S "%s" 2>&1',
    passes_str,
    input_file
  )

  -- Always print exact command for debugging
  print("[Pipeline] Running command:")
  print("  " .. cmd)

  if M.debug then
    print("[Pipeline Debug] Command details logged above")
  end

  -- Execute command and capture output
  local output = vim.fn.system(cmd)

  if M.debug then
    print("[Pipeline Debug] Output length: " .. #output .. " bytes")
    print("[Pipeline Debug] First 500 chars of output:")
    print(string.sub(output, 1, 500))
  end

  -- Check for errors (look for "opt:" error prefix in output)
  if output:match("^opt:") or output:match("\nopt:") then
    print("[Pipeline] Error running opt:")
    print(cmd)
    -- Print first few lines of error
    local lines = vim.split(output, "\n")
    for i = 1, math.min(5, #lines) do
      print(lines[i])
    end
    return nil
  end

  -- Parse the pipeline output to get passes
  local passes = M.parse_pipeline_output(output)

  -- Don't prepend Input - let the viewer handle the initial state per-function
  return passes
end

-- Run clang pipeline (C/C++ files)
-- @param input_file: path to .c or .cpp file
-- @param passes_str: optimization level (e.g., "O2", "-O2", "2")
-- @param lang_args: language-specific compiler arguments
-- @return: array of {name, ir} tables, one per pass
run_clang_pipeline = function(input_file, passes_str, lang_args)
  -- Validate: only O-levels for C/C++
  local opt_level = normalize_o_level(passes_str)
  if not opt_level then
    print("[Pipeline] C/C++ files only support O-levels (O0, O1, O2, O3)")
    print("[Pipeline] For custom passes, compile to .ll first:")
    print("  :Godbolt -emit-llvm -O0 -Xclang -disable-O0-optnone")
    print("  Then in the .ll file: :GodboltPipeline mem2reg,instcombine")
    return nil
  end

  -- Check for LTO flags
  local args_str = type(lang_args) == "table" and table.concat(lang_args, " ") or (lang_args or "")
  if has_lto_flags(args_str) then
    print("[Pipeline] Error: LTO flags detected in compiler arguments")
    print("[Pipeline] LTO defers optimizations to link-time, incompatible with -print-after-all")
    print("[Pipeline] Remove -flto or similar flags to view pipeline")
    return nil
  end

  -- Determine compiler (clang or clang++)
  local compiler = input_file:match("%.cpp$") and "clang++" or "clang"

  -- Build command: clang -mllvm -print-after-all <opt-level> <args> -S -emit-llvm -o /dev/null file.c
  local cmd_parts = {
    compiler,
    "-mllvm", "-print-after-all",
    opt_level,
  }

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

  -- Always print exact command for debugging
  print("[Pipeline] Running command:")
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
    print("[Pipeline] Compilation error:")
    print(cmd)
    local lines = vim.split(output, "\n")
    for i = 1, math.min(10, #lines) do
      print(lines[i])
    end
    return nil
  end

  -- Parse the pipeline output to get passes
  local passes = M.parse_pipeline_output(output, "clang")

  return passes
end

-- Parse pipeline output into pass stages
-- @param output: raw output from opt/clang command
-- @param source_type: "opt" or "clang" (default "opt")
-- @return: array of {name, scope_type, scope_target, ir, stats} tables
function M.parse_pipeline_output(output, source_type)
  source_type = source_type or "opt"

  local passes = {}
  local current_pass = nil
  local current_scope_type = nil
  local current_scope_target = nil
  local current_ir = {}
  local line_count = 0
  local pass_boundary_count = 0
  local seen_module_id = false

  for line in output:gmatch("[^\r\n]+") do
    line_count = line_count + 1

    -- Try to parse pass header to extract scope information
    local pass_name, scope_type, scope_target = parse_pass_header(line)

    if pass_name then
      pass_boundary_count = pass_boundary_count + 1

      if M.debug then
        print(string.format("[Pipeline Debug] Found pass boundary at line %d: '%s' (scope: %s, target: %s)",
          line_count, pass_name, scope_type or "none", scope_target or "none"))
      end

      -- Save previous pass if exists
      if current_pass and #current_ir > 0 then
        -- Validate it's LLVM IR before saving (filter out MIR, assembly, etc.)
        if is_llvm_ir(current_ir) or #current_ir == 0 then
          table.insert(passes, {
            name = current_pass,
            scope_type = current_scope_type,
            scope_target = current_scope_target,
            ir = ir_utils.clean_ir(current_ir, current_scope_type),
          })
          if M.debug then
            print(string.format("[Pipeline Debug] Saved pass '%s' with %d IR lines", current_pass, #current_ir))
          end
        else
          if M.debug then
            print(string.format("[Pipeline Debug] Skipped pass '%s' - not LLVM IR (likely MIR or assembly)", current_pass))
          end
        end
      end

      -- Start new pass
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
      current_ir = {}
      seen_module_id = false

    elseif current_pass then
      -- Detect final output (ModuleID in stdout means we're done with pass dumps)
      -- NOTE: For opt, ModuleID only appears in final stdout output
      -- For clang, ModuleID appears at the start of each pass dump, so we ignore it
      if source_type == "opt" and line:match("^; ModuleID = ") then
        -- Any ModuleID means we've hit opt's stdout (final output)
        -- Function-scoped dumps don't have ModuleIDs
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
        table.insert(current_ir, line)
      end
    end
  end

  -- Save last pass if we didn't hit the final output marker
  if current_pass and #current_ir > 0 and #passes == pass_boundary_count - 1 then
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

  if M.debug then
    print(string.format("[Pipeline Debug] Parsing summary:"))
    print(string.format("  Total lines processed: %d", line_count))
    print(string.format("  Pass boundaries found: %d", pass_boundary_count))
    print(string.format("  Passes captured: %d", #passes))
    if #passes > 0 then
      print(string.format("  First pass: '%s'", passes[1].name))
      print(string.format("  Last pass: '%s'", passes[#passes].name))
    end
  end

  return passes
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
-- For .c/.cpp files: compiles to LLVM IR with -O0
-- @param input_file: path to .ll, .c, or .cpp file
-- @return: array of IR lines with debug info removed
function M.get_stripped_input(input_file)
  -- Handle C/C++ files by compiling to LLVM IR first
  if input_file:match("%.c$") or input_file:match("%.cpp$") then
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

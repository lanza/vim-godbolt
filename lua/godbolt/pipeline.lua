local M = {}

local ir_utils = require('godbolt.ir_utils')

-- Debug flag - set to true to see detailed logging
M.debug = false

-- Run opt with a pipeline and capture intermediate IR at each pass
-- @param input_file: path to .ll file
-- @param passes_str: comma-separated pass names or "default<O2>"
-- @return: array of {name, ir} tables, one per pass
function M.run_pipeline(input_file, passes_str)
  local cmd = string.format(
    'opt --strip-debug -passes="%s" --print-after-all -S "%s" 2>&1',
    passes_str,
    input_file
  )

  if M.debug then
    print("[Pipeline Debug] Running command:")
    print("  " .. cmd)
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

-- Parse opt --print-after-all output into pass stages
-- @param output: raw output from opt command
-- @return: array of {name, ir} tables
function M.parse_pipeline_output(output)
  local passes = {}
  local current_pass = nil
  local current_ir = {}
  local line_count = 0
  local pass_boundary_count = 0
  local seen_module_id = false

  for line in output:gmatch("[^\r\n]+") do
    line_count = line_count + 1

    -- Detect pass boundary: ; *** IR Dump After PassName ***
    -- Use non-greedy match (.-) to avoid consuming the trailing ***
    local pass_name = line:match("^; %*%*%* IR Dump After (.-)%s+%*%*%*")

    if pass_name then
      pass_boundary_count = pass_boundary_count + 1

      if M.debug then
        print(string.format("[Pipeline Debug] Found pass boundary at line %d: '%s'", line_count, pass_name))
      end

      -- Save previous pass if exists
      if current_pass and #current_ir > 0 then
        table.insert(passes, {
          name = current_pass,
          ir = ir_utils.clean_ir(current_ir),
        })
        if M.debug then
          print(string.format("[Pipeline Debug] Saved pass '%s' with %d IR lines", current_pass, #current_ir))
        end
      end

      -- Start new pass
      current_pass = pass_name
      current_ir = {}
      seen_module_id = false

    elseif current_pass then
      -- Detect final output (ModuleID in stdout means we're done with pass dumps)
      if line:match("^; ModuleID = ") then
        -- Any ModuleID means we've hit opt's stdout (final output)
        -- Function-scoped dumps don't have ModuleIDs
        if M.debug then
          print(string.format("[Pipeline Debug] Found final output at line %d, stopping collection", line_count))
        end
        -- Save the current pass and stop processing
        if current_pass and #current_ir > 0 then
          table.insert(passes, {
            name = current_pass,
            ir = ir_utils.clean_ir(current_ir),
          })
          if M.debug then
            print(string.format("[Pipeline Debug] Saved final pass '%s' with %d IR lines", current_pass, #current_ir))
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
    table.insert(passes, {
      name = current_pass,
      ir = ir_utils.clean_ir(current_ir),
    })
    if M.debug then
      print(string.format("[Pipeline Debug] Saved final pass '%s' with %d IR lines", current_pass, #current_ir))
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

-- Get stripped input IR by running opt --strip-debug
-- @param input_file: path to .ll file
-- @return: array of IR lines with debug info removed
function M.get_stripped_input(input_file)
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

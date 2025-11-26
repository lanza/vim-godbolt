local M = {}

-- Debug flag - set to true to see detailed logging
M.debug = false

-- Run opt with a pipeline and capture intermediate IR at each pass
-- @param input_file: path to .ll file
-- @param passes_str: comma-separated pass names or "default<O2>"
-- @return: array of {name, ir} tables, one per pass
function M.run_pipeline(input_file, passes_str)
  local cmd = string.format(
    'opt -passes="%s" --print-after-all -S "%s" 2>&1',
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

  return M.parse_pipeline_output(output)
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
          ir = current_ir,
        })
        if M.debug then
          print(string.format("[Pipeline Debug] Saved pass '%s' with %d IR lines", current_pass, #current_ir))
        end
      end

      -- Start new pass
      current_pass = pass_name
      current_ir = {}

    elseif current_pass then
      -- We're inside a pass dump - collect all lines
      table.insert(current_ir, line)
    end
  end

  -- Don't forget the last pass
  if current_pass and #current_ir > 0 then
    table.insert(passes, {
      name = current_pass,
      ir = current_ir,
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

return M

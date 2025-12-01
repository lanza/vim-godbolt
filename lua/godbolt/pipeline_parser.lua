-- Pipeline parser for --print-changed with --print-module-scope
-- With --print-module-scope, LLVM always prints full module IR (not fragments)
-- This makes parsing trivial: each pass either has full IR or points to a previous pass

local ir_utils = require('godbolt.ir_utils')

local M = {}

-- Parse --print-changed pipeline output (with --print-module-scope)
-- Returns:
-- {
--   initial_ir = string[],  -- From "*** IR Dump At Start ***"
--   passes = {
--     {
--       name = "PassName on target",
--       scope_type = "module" | "function" | "cgscc" | "loop",
--       scope_target = "[module]" | "foo",
--       changed = true | false,
--       ir_or_index = string[] | number
--     }
--   }
-- }
--
-- @param output: string of pipeline output
-- @param source_type: "opt" | "clang" (for compatibility)
-- @return: { initial_ir, passes } or { error }
function M.parse_pipeline_output_lazy(output, source_type)
  source_type = source_type or "opt"

  local initial_ir = nil
  local passes = {}

  -- Track state during parsing
  local current_pass_name = nil
  local current_scope_type = nil
  local current_scope_target = nil
  local current_is_omitted = false
  local current_ir_lines = {}

  -- Track index of last pass with actual IR
  -- For omitted passes, we need to point to the last pass with full module IR
  local last_pass_with_ir = nil

  local function save_current_pass()
    if not current_pass_name then
      return
    end

    -- Special handling for initial IR
    if current_pass_name == "__INITIAL__" then
      initial_ir = current_ir_lines
      return
    end

    local pass_index = #passes + 1

    -- Build full pass name (e.g., "SROAPass on simple")
    local full_name = current_pass_name
    if current_scope_target then
      if current_scope_type == "cgscc" then
        full_name = current_pass_name .. " on (" .. current_scope_target .. ")"
      else
        full_name = current_pass_name .. " on " .. current_scope_target
      end
    end

    if current_is_omitted then
      -- Omitted pass: point to last pass with IR (or 0 for initial_ir)
      table.insert(passes, {
        name = full_name,
        scope_type = current_scope_type,
        scope_target = current_scope_target,
        changed = false,
        ir_or_index = last_pass_with_ir or 0
      })
    else
      -- Changed pass: store full module IR
      -- With --print-module-scope, even function/loop passes get full module IR
      table.insert(passes, {
        name = full_name,
        scope_type = current_scope_type,
        scope_target = current_scope_target,
        changed = true,
        ir_or_index = current_ir_lines
      })
      -- Update last_pass_with_ir to point to this pass
      last_pass_with_ir = pass_index
    end

    -- Reset for next pass
    current_pass_name = nil
    current_scope_type = nil
    current_scope_target = nil
    current_is_omitted = false
    current_ir_lines = {}
  end

  -- Parse line by line
  for line in output:gmatch("[^\r\n]+") do
    -- Check for initial IR marker first
    if line:match("IR Dump At Start") then
      save_current_pass()
      current_pass_name = "__INITIAL__"
      current_ir_lines = {}
    else
      -- Check for pass header
      local pass_name, scope_type, scope_target, is_before, is_omitted = M.parse_pass_header(line, source_type)

      if pass_name then
        if not is_before then
          -- Save previous pass
          save_current_pass()

          -- Start new pass
          current_pass_name = pass_name
          current_scope_type = scope_type
          current_scope_target = scope_target
          current_is_omitted = is_omitted
          current_ir_lines = {}
        end
        -- Skip "before" passes - we don't need them with --print-changed
      else
        -- Regular line: add to current IR
        table.insert(current_ir_lines, line)
      end
    end
  end

  -- Save final pass
  save_current_pass()

  return {
    initial_ir = initial_ir or {},
    passes = passes,
  }
end

-- Parse a pass header line to extract pass information
-- Returns: pass_name, scope_type, scope_target, is_before, is_omitted
-- @param line: string to parse
-- @param source_type: "opt" | "clang"
-- @return: pass_name, scope_type, scope_target, is_before, is_omitted (all nil if not a header)
function M.parse_pass_header(line, source_type)
  -- Try opt format with semicolon: "; *** IR Dump After PassName on target ***"
  local pass_info = line:match("^; %*%*%* IR Dump (.-) %*%*%*$")

  -- Try --print-changed format (no semicolon): "*** IR Dump After PassName on target ***"
  if not pass_info then
    pass_info = line:match("^%*%*%* IR Dump (.-) %*%*%*$")
  end

  if not pass_info then
    return nil
  end

  -- Extract "After/Before PassName on target"
  local after_or_before, pass_info_rest = pass_info:match("^(After) (.+)$")
  if not after_or_before then
    after_or_before, pass_info_rest = pass_info:match("^(Before) (.+)$")
  end

  if not after_or_before then
    -- Might be "At Start"
    return nil
  end

  local is_before = after_or_before == "Before"
  local pass_info_without_omit = pass_info_rest

  -- Check if pass was omitted (--print-changed only)
  local is_omitted = false
  if pass_info_rest:match("omitted because no change$") then
    is_omitted = true
    pass_info_without_omit = pass_info_rest:gsub(" omitted because no change$", "")
  end

  pass_info = pass_info_without_omit

  -- Parse scope: "PassName on target" or "PassName on (target)" for CGSCC
  local pass_name, scope_type, scope_target

  -- Try module scope: "PassName on [module]"
  pass_name, scope_target = pass_info:match("^(.+) on (%[module%])$")
  if pass_name then
    return pass_name, "module", scope_target, is_before, is_omitted
  end

  -- Try CGSCC scope: "PassName on (target)"
  pass_name, scope_target = pass_info:match("^(.+) on %((.+)%)$")
  if pass_name then
    return pass_name, "cgscc", scope_target, is_before, is_omitted
  end

  -- Try loop scope: "PassName on loop ... in function func_name"
  -- Loop passes show partial IR, but with --print-module-scope they show full module
  local loop_info
  pass_name, loop_info = pass_info:match("^(.+) on (loop .+ in function .+)$")
  if pass_name and loop_info then
    -- Extract function name from "loop ... in function foo"
    local func_name = loop_info:match("in function (.+)$")
    if func_name then
      -- scope_type="loop", scope_target=function_name
      return pass_name, "loop", func_name, is_before, is_omitted
    end
  end

  -- Try function scope: "PassName on target"
  pass_name, scope_target = pass_info:match("^(.+) on (.+)$")
  if pass_name then
    return pass_name, "function", scope_target, is_before, is_omitted
  end

  -- No scope info, just pass name
  return pass_info, "unknown", nil, is_before, is_omitted
end

return M

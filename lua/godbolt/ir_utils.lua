local M = {}

-- Get full module IR without extracting individual functions
-- Used for module-scoped passes where we want to see all functions, globals, etc.
-- @param ir_lines: array of IR lines
-- @return: array with full module (still removes some comment noise)
function M.get_full_module(ir_lines)
  local module_ir = {}

  for _, line in ipairs(ir_lines) do
    -- Skip comment-only lines but keep everything else
    -- Keep: functions, globals, declares, attributes, metadata, etc.
    if not line:match("^%s*;%s*$") then  -- Skip empty comment lines
      table.insert(module_ir, line)
    end
  end

  return module_ir
end

-- Clean IR by removing metadata and keeping only function definitions
-- @param ir_lines: array of IR lines
-- @param scope_type: (optional) "module", "function", "cgscc", or nil
-- @return: cleaned array with only function definitions (or full module if scope is "module")
function M.clean_ir(ir_lines, scope_type)
  -- For module passes, return the full module
  if scope_type == "module" then
    return M.get_full_module(ir_lines)
  end

  -- For function/cgscc/unknown passes, extract only function definitions
  local cleaned = {}
  local in_function = false
  local brace_count = 0

  for _, line in ipairs(ir_lines) do
    -- Skip all comment lines (including "; Function Attrs:")
    if line:match("^%s*;") then
      -- Skip comments
    -- Skip metadata and header lines
    elseif line:match("^; ModuleID") or
       line:match("^source_filename") or
       line:match("^target datalayout") or
       line:match("^target triple") then
      -- Skip these lines
    -- Detect function start
    elseif line:match("^define ") then
      in_function = true
      brace_count = 0
      table.insert(cleaned, line)
    -- Detect function end
    elseif in_function then
      table.insert(cleaned, line)
      -- Count braces to detect end of function
      local open_braces = select(2, line:gsub("{", ""))
      local close_braces = select(2, line:gsub("}", ""))
      brace_count = brace_count + open_braces - close_braces

      if brace_count == 0 and line:match("}") then
        in_function = false
      end
    -- Skip declares, attributes, metadata, etc at the end
    elseif line:match("^declare ") or
           line:match("^attributes") or
           line:match("^!") or
           line:match("^@") then  -- Skip global variables/constants too
      -- Skip these
    end
  end

  return cleaned
end

-- Extract a specific function from IR and clean it
-- @param ir_lines: array of IR lines
-- @param func_name: function name to extract (e.g., "foo")
-- @return: array of lines containing only that function (cleaned)
function M.extract_function(ir_lines, func_name)
  local func_ir = {}
  local in_target_function = false
  local brace_count = 0

  for _, line in ipairs(ir_lines) do
    -- Check if this is the start of our target function
    if line:match("^define .* @" .. func_name .. "%(") or
       line:match("^define .* @" .. func_name .. "%(") then
      in_target_function = true
      brace_count = 0
      table.insert(func_ir, line)
      -- Count opening brace on define line if present
      local open_braces = select(2, line:gsub("{", ""))
      local close_braces = select(2, line:gsub("}", ""))
      brace_count = brace_count + open_braces - close_braces
      if brace_count == 0 and line:match("}") then
        break
      end
    elseif in_target_function then
      table.insert(func_ir, line)

      -- Count braces to detect end of function
      local open_braces = select(2, line:gsub("{", ""))
      local close_braces = select(2, line:gsub("}", ""))
      brace_count = brace_count + open_braces - close_braces

      if brace_count == 0 and line:match("}") then
        break
      end
    end
  end

  -- Clean the extracted function to remove any comments that slipped through
  return M.clean_ir(func_ir)
end

return M

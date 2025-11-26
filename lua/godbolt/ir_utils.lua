local M = {}

-- Clean IR by removing metadata and keeping only function definitions
-- @param ir_lines: array of IR lines
-- @return: cleaned array with only function definitions
function M.clean_ir(ir_lines)
  local cleaned = {}
  local in_function = false
  local brace_count = 0

  for _, line in ipairs(ir_lines) do
    -- Skip metadata and header lines
    if line:match("^; ModuleID") or
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
    -- Skip attributes, metadata, etc at the end
    elseif line:match("^attributes") or
           line:match("^!") or
           line:match("^declare ") then
      -- Skip these
    end
  end

  return cleaned
end

-- Extract a specific function from IR
-- @param ir_lines: array of IR lines
-- @param func_name: function name to extract (e.g., "foo")
-- @return: array of lines containing only that function
function M.extract_function(ir_lines, func_name)
  local func_ir = {}
  local in_target_function = false
  local brace_count = 0

  for _, line in ipairs(ir_lines) do
    -- Check if this is the start of our target function
    if line:match("^define .* @" .. func_name .. "%(") then
      in_target_function = true
      brace_count = 0
      table.insert(func_ir, line)
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

  return func_ir
end

return M

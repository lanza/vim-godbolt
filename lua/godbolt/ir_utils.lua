local M = {}

-- Extract a specific function from IR and clean it
-- @param ir_lines: array of IR lines
-- @param func_name: function name to extract (e.g., "foo")
-- @return: array of lines containing only that function (cleaned)
function M.extract_function(ir_lines, func_name)
  local func_ir = {}
  local in_target_function = false
  local brace_count = 0
  local comment_lines = {} -- Track comment lines before define

  -- OPTIMIZATION: Pre-compile regex pattern once instead of on every line
  -- Escaping special regex characters in function name
  local escaped_name = func_name:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
  local pattern = "^define .* @" .. escaped_name .. "%("

  for _, line in ipairs(ir_lines) do
    -- Check if this is the start of our target function
    if not in_target_function and line:match(pattern) then
      -- Found the function - add any preceding comment lines
      for _, comment in ipairs(comment_lines) do
        table.insert(func_ir, comment)
      end
      comment_lines = {}

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
    elseif line:match("^%s*;") then
      -- This is a comment line before the function - keep it
      table.insert(comment_lines, line)
    elseif not line:match("^%s*$") then
      -- Non-comment, non-empty line - clear comment buffer
      comment_lines = {}
    end
  end

  return func_ir
end

-- Filter debug metadata from LLVM IR for display
-- Removes debug intrinsic lines (#dbg_declare, #dbg_value) and debug metadata
-- Preserves PGO metadata (!prof, branch_weights, function_entry_count, etc.)
-- @param ir_lines: array of LLVM IR lines
-- @return: filtered_lines, line_map
--   - filtered_lines: array with debug metadata removed
--   - line_map: table mapping displayed_line_num -> original_line_num
function M.filter_debug_metadata(ir_lines)
  local filtered = {}
  local line_map = {} -- displayed_line -> original_line

  for original_line_num, line in ipairs(ir_lines) do
    -- Skip lines that are ONLY debug intrinsics (entire line)
    -- Matches:   #dbg_declare(ptr %a.addr, !14, !DIExpression(), !15)
    --            #dbg_value(i32 %10, !26, !DIExpression(), !47)
    if line:match("^%s*#dbg_") then
      goto continue
    end

    -- Filter out DEBUG-SPECIFIC metadata DEFINITIONS:
    -- Keep: !20 = !{!"function_entry_count", i64 100000}  (PGO)
    -- Keep: !21 = !{!"branch_weights", i32 90000, i32 10000}  (PGO)
    -- Remove: !10 = distinct !DISubprogram(...)  (debug)
    -- Remove: !11 = !DILocation(...)  (debug)
    -- Remove: !llvm.dbg.cu = !{!0}  (debug module metadata)
    local is_debug_metadata = line:match("^![0-9]+ = .*!DI") or  -- !10 = ...!DILocation/!DISubprogram/etc
        line:match("^!llvm%.dbg%.") or                          -- !llvm.dbg.cu, !llvm.dbg.sp, etc
        line:match("^![0-9]+ = !DI")                            -- !10 = !DILocation(...)

    if is_debug_metadata then
      goto continue
    end

    -- Remove inline DEBUG metadata REFERENCES from instruction lines
    -- Keep: !prof !20 (PGO profiling metadata)
    -- Remove: !dbg !11 (debug location metadata)
    local cleaned_line = line

    -- Remove debug metadata at end of instructions: ", !dbg !19"
    cleaned_line = cleaned_line:gsub(",%s*!dbg%s+![0-9]+", "")

    -- Remove space-separated debug metadata (like on define lines): " !dbg !17"
    -- This appears without a comma, e.g., "define ... ) #0 !dbg !17 {"
    cleaned_line = cleaned_line:gsub("%s+!dbg%s+![0-9]+", "")

    table.insert(filtered, cleaned_line)

    -- Map displayed line number to original line number
    local displayed_line_num = #filtered
    line_map[displayed_line_num] = original_line_num

    ::continue::
  end

  return filtered, line_map
end

return M

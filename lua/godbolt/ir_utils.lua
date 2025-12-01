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
-- Removes debug intrinsic lines (#dbg_declare, #dbg_value) and inline metadata references
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

    -- Filter out metadata DEFINITIONS:
    -- - !123 = !{...}  (numbered metadata)
    -- - !llvm.ident, !llvm.module.flags, etc.
    local is_metadata_def = line:match("^![0-9]+ = ") or -- !123 = !{...}
        line:match("^!llvm%.") or                        -- !llvm.ident = !{...}
        line:match("^!%.")                               -- !.something

    if is_metadata_def then
      goto continue
    end

    -- Remove inline metadata REFERENCES from instruction lines
    -- This handles: !dbg !XX, !tbaa !XX, !llvm.loop !XX, etc.
    local cleaned_line = line

    -- Remove metadata at end of instructions: ", !dbg !19", ", !tbaa !43", etc.
    -- Pattern: comma, optional spaces, !, word chars/dots, space, !, digits
    cleaned_line = cleaned_line:gsub(",%s*![%w%.]+%s+![0-9]+", "")

    -- Remove any remaining standalone metadata refs: ", !15"
    cleaned_line = cleaned_line:gsub(",%s*![0-9]+", "")

    -- Remove space-separated metadata (like on define lines): " !dbg !17"
    -- This appears without a comma, e.g., "define ... ) #0 !dbg !17 {"
    cleaned_line = cleaned_line:gsub("%s+![%w%.]+%s+![0-9]+", "")

    table.insert(filtered, cleaned_line)

    -- Map displayed line number to original line number
    local displayed_line_num = #filtered
    line_map[displayed_line_num] = original_line_num

    ::continue::
  end

  return filtered, line_map
end

return M

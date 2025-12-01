-- IR Parser: Treesitter-based LLVM IR parsing utilities
-- This module provides functions to parse and manipulate LLVM IR using tree-sitter

local M = {}

-- Path to the compiled LLVM tree-sitter parser
local LLVM_PARSER_PATH = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":p:h:h:h")
    .. "/tree-sitter-llvm/libtree-sitter-llvm.dylib"

-- Initialize the LLVM parser
-- Throws error if parser cannot be loaded
local function ensure_parser()
  local ok, err = pcall(function()
    vim.treesitter.language.add('llvm', { path = LLVM_PARSER_PATH })
  end)

  if not ok then
    error(
      "Failed to load LLVM tree-sitter parser.\n" ..
      "The godbolt.nvim pipeline feature requires tree-sitter-llvm to be compiled.\n" ..
      "Expected parser at: " .. LLVM_PARSER_PATH .. "\n" ..
      "Error: " .. tostring(err),
      0
    )
  end
end

-- Parse LLVM IR text into a syntax tree
-- @param ir_text: string of LLVM IR code
-- @return: TSTree object
function M.parse(ir_text)
  ensure_parser()

  local parser = vim.treesitter.get_string_parser(ir_text, 'llvm')
  local trees = parser:parse()
  return trees[1]
end

-- List all function names defined in LLVM IR
-- @param ir_lines: array of IR lines OR string of IR text
-- @return: array of function names (without @ prefix)
function M.list_functions(ir_lines)
  local ir_text = type(ir_lines) == "table" and table.concat(ir_lines, "\n") or ir_lines

  local tree = M.parse(ir_text)
  local root = tree:root()

  -- Query for function definitions
  local query = vim.treesitter.query.parse('llvm',
    '(fn_define (function_header (global_var) @func_name))')

  local functions = {}
  for id, node in query:iter_captures(root, ir_text) do
    local name = vim.treesitter.get_node_text(node, ir_text)
    -- Remove @ prefix if present
    name = name:gsub("^@", "")
    table.insert(functions, name)
  end

  return functions
end

-- Extract a specific function's IR from module IR
-- @param ir_lines: array of IR lines OR string of IR text
-- @param func_name: name of function to extract (with or without @ prefix)
-- @return: array of IR lines for just that function, or nil if not found
function M.extract_function(ir_lines, func_name)
  local ir_text = type(ir_lines) == "table" and table.concat(ir_lines, "\n") or ir_lines

  -- Normalize function name (add @ if missing)
  local search_name = func_name:match("^@") and func_name or ("@" .. func_name)

  local tree = M.parse(ir_text)
  local root = tree:root()

  -- Query for the specific function
  local query = vim.treesitter.query.parse('llvm',
    '(fn_define (function_header (global_var) @func_name) @func_def)')

  for id, node in query:iter_captures(root, ir_text) do
    local name = query.captures[id]

    if name == "func_name" then
      local func_text = vim.treesitter.get_node_text(node, ir_text)
      if func_text == search_name then
        -- Found the function, now get its parent fn_define node
        local fn_define = node:parent():parent() -- global_var -> function_header -> fn_define
        local start_row, _, end_row, end_col = fn_define:range()

        -- Split IR into lines to find comment lines before the function
        local all_lines = vim.split(ir_text, "\n", { plain = true })

        -- Walk backwards from start_row to find comment lines immediately before the function
        -- We want to include lines like "; Function Attrs: ..." that appear right before define
        local comment_lines = {}
        local row = start_row -- start_row is 0-indexed

        while row > 0 do
          row = row - 1
          local line = all_lines[row + 1] -- Convert 0-indexed row to 1-indexed Lua array

          if line:match("^%s*;") then
            -- This is a comment line - add to beginning of comment_lines
            table.insert(comment_lines, 1, line)
          elseif line:match("^%s*$") then
            -- Blank line - continue searching backwards (don't break the chain)
          else
            -- Non-comment, non-blank line - stop searching
            break
          end
        end

        -- Extract function lines (start_row is 0-indexed, Lua arrays are 1-indexed)
        local func_lines = {}
        for i = start_row + 1, end_row + 1 do
          table.insert(func_lines, all_lines[i])
        end

        -- Combine comment lines and function lines
        local result = {}
        for _, line in ipairs(comment_lines) do
          table.insert(result, line)
        end
        for _, line in ipairs(func_lines) do
          table.insert(result, line)
        end

        return result
      end
    end
  end

  return nil
end

-- Extract module-level globals (everything except function definitions)
-- @param ir_lines: array of IR lines OR string of IR text
-- @return: array of IR lines containing only globals/metadata/declarations
function M.extract_globals(ir_lines)
  local ir_text = type(ir_lines) == "table" and table.concat(ir_lines, "\n") or ir_lines

  local tree = M.parse(ir_text)
  local root = tree:root()

  local lines = vim.split(ir_text, "\n", { plain = true })

  -- Find all fn_define nodes
  local query = vim.treesitter.query.parse('llvm', '(fn_define) @func')

  local function_ranges = {}
  for id, node in query:iter_captures(root, ir_text) do
    local start_row, _, end_row, _ = node:range()
    table.insert(function_ranges, { start_row, end_row })
  end

  -- Filter out lines that are inside functions
  local globals = {}
  for i, line in ipairs(lines) do
    local line_num = i - 1 -- 0-indexed for tree-sitter
    local in_function = false

    for _, range in ipairs(function_ranges) do
      if line_num >= range[1] and line_num <= range[2] then
        in_function = true
        break
      end
    end

    if not in_function then
      table.insert(globals, line)
    end
  end

  return globals
end

-- Replace a function in module IR with new function IR
-- @param module_ir: array of IR lines OR string of module IR
-- @param func_name: name of function to replace (with or without @ prefix)
-- @param new_func_ir: array of IR lines OR string of new function IR
-- @return: array of IR lines with function replaced
function M.replace_function(module_ir, func_name, new_func_ir)
  local module_text = type(module_ir) == "table" and table.concat(module_ir, "\n") or module_ir
  local new_func_text = type(new_func_ir) == "table" and table.concat(new_func_ir, "\n") or new_func_ir

  -- Normalize function name
  local search_name = func_name:match("^@") and func_name or ("@" .. func_name)

  local tree = M.parse(module_text)
  local root = tree:root()

  -- Find the function to replace
  local query = vim.treesitter.query.parse('llvm',
    '(fn_define (function_header (global_var) @func_name))')

  local replace_start, replace_end = nil, nil
  for id, node in query:iter_captures(root, module_text) do
    local func_text = vim.treesitter.get_node_text(node, module_text)
    if func_text == search_name then
      local fn_define = node:parent():parent()
      replace_start, _, replace_end, _ = fn_define:range()
      break
    end
  end

  if not replace_start then
    -- Function not found, return original
    return type(module_ir) == "table" and module_ir or vim.split(module_ir, "\n")
  end

  -- Split module into lines
  local lines = vim.split(module_text, "\n", { plain = true })

  -- Build result: before + new_func + after
  local result = {}

  -- Lines before function (0-indexed to 1-indexed)
  for i = 1, replace_start do
    table.insert(result, lines[i])
  end

  -- New function
  local new_func_lines = vim.split(new_func_text, "\n", { plain = true })
  for _, line in ipairs(new_func_lines) do
    table.insert(result, line)
  end

  -- Lines after function (0-indexed to 1-indexed)
  for i = replace_end + 2, #lines do
    table.insert(result, lines[i])
  end

  return result
end

return M

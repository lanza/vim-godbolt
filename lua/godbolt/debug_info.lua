local M = {}

-- Parse DILocalVariable metadata from LLVM IR
-- @param ir_lines: array of LLVM IR lines
-- @return: table mapping metadata IDs to variable info {name, type_ref}
local function parse_di_local_variables(ir_lines)
  local var_map = {}  -- !10 -> {name="x", type="i32"}

  for _, line in ipairs(ir_lines) do
    -- Parse: !10 = !DILocalVariable(name: "x", scope: !11, file: !1, line: 5, type: !12)
    local id, name = line:match("^(![0-9]+)%s*=%s*!DILocalVariable%(.-name:%s*\"([^\"]+)\"")

    if id and name then
      var_map[id] = {name = name}
    end
  end

  return var_map
end

-- Find llvm.dbg.declare and llvm.dbg.value calls that map SSA registers to variables
-- @param ir_lines: array of LLVM IR lines
-- @param var_map: table from parse_di_local_variables
-- @return: table mapping SSA registers to variable names {"%5" -> "x"}
local function map_ssa_to_variables(ir_lines, var_map)
  local ssa_map = {}  -- %5 -> "x"

  for _, line in ipairs(ir_lines) do
    -- Match llvm.dbg.declare: call void @llvm.dbg.declare(metadata ptr %5, metadata !10, ...)
    local ssa_reg, var_id = line:match("llvm%.dbg%.declare%(metadata %w+ (%%[0-9]+), metadata (![0-9]+)")

    if not ssa_reg then
      -- Match llvm.dbg.value: call void @llvm.dbg.value(metadata i32 %5, metadata !10, ...)
      ssa_reg, var_id = line:match("llvm%.dbg%.value%(metadata %w+ (%%[0-9]+), metadata (![0-9]+)")
    end

    if ssa_reg and var_id and var_map[var_id] then
      ssa_map[ssa_reg] = var_map[var_id].name
    end
  end

  return ssa_map
end

-- Annotate LLVM IR buffer with variable names using virtual text
-- @param bufnr: buffer number
-- @param ir_lines: array of LLVM IR lines (displayed, might be filtered)
-- @param full_ir_lines: array of full LLVM IR lines (with all metadata, for parsing)
function M.annotate_variables(bufnr, ir_lines, full_ir_lines)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- Use full IR for parsing to get debug info
  local var_map = parse_di_local_variables(full_ir_lines)
  local ssa_map = map_ssa_to_variables(full_ir_lines, var_map)

  -- If no variables found, nothing to annotate
  if vim.tbl_count(ssa_map) == 0 then
    return
  end

  -- Create namespace for annotations
  local ns_id = vim.api.nvim_create_namespace('godbolt_var_annotations')

  -- Clear existing annotations
  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  -- Annotate each line that contains SSA registers
  for line_num, line in ipairs(ir_lines) do
    local annotations = {}

    -- Find all SSA registers in this line
    for ssa_reg in line:gmatch("(%%[0-9]+)") do
      if ssa_map[ssa_reg] and not vim.tbl_contains(annotations, ssa_reg) then
        table.insert(annotations, ssa_reg)
      end
    end

    -- Add virtual text if we found any variables
    if #annotations > 0 then
      local virt_text_parts = {}
      for _, ssa_reg in ipairs(annotations) do
        table.insert(virt_text_parts, {" ; " .. ssa_reg .. " = " .. ssa_map[ssa_reg], "Comment"})
      end

      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, line_num - 1, 0, {
        virt_text = virt_text_parts,
        virt_text_pos = "eol",
      })
    end
  end
end

return M

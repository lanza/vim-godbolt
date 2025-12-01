local M = {}

-- Parse LLVM IR using treesitter to extract line mappings
-- Returns: src_to_ir, ir_to_src tables
function M.parse(ir_lines)
  local src_to_ir = {} -- source_line → [ir_line_nums]
  local ir_to_src = {} -- ir_line_num → source_line
  local metadata = {}  -- metadata_id → {line, column}

  -- First pass: Build metadata table by parsing !DILocation entries
  for ir_line_num, line in ipairs(ir_lines) do
    -- Parse metadata definitions like:
    -- !21 = !DILocation(line: 2, column: 18, scope: !10)
    local meta_id, src_line, src_col = line:match("^!(%d+)%s*=%s*!DILocation%(.-line:%s*(%d+).-column:%s*(%d+)")

    if meta_id and src_line then
      metadata[tonumber(meta_id)] = {
        line = tonumber(src_line),
        column = src_col and tonumber(src_col) or nil,
        ir_line = ir_line_num,
      }
    end
  end

  -- Second pass: Map instructions to source lines via !dbg references
  for ir_line_num, line in ipairs(ir_lines) do
    -- Skip metadata lines and attributes
    if not line:match("^!") and not line:match("^attributes") and not line:match("^source_filename")
        and not line:match("^target") and not line:match("^; ") then
      -- Check if this is a #dbg_declare or #dbg_value intrinsic
      -- Examples:
      --   #dbg_declare(ptr %arr.addr, !23, !DIExpression(), !24)
      --   #dbg_value(i32 %10, !26, !DIExpression(), !47)
      -- The last !XX is the location reference
      if line:match("^%s*#dbg_") then
        -- Find all !number references and take the last one (the location)
        local refs = {}
        for ref in line:gmatch("!(%d+)") do
          table.insert(refs, ref)
        end

        if #refs > 0 then
          local dbg_intrinsic_ref = refs[#refs]
          -- This is a debug intrinsic - apply its location to the PREVIOUS instruction
          -- since these intrinsics typically annotate the preceding alloca/store
          local meta = metadata[tonumber(dbg_intrinsic_ref)]
          if meta and meta.line and ir_line_num > 1 then
            local prev_line = ir_line_num - 1
            local src_line = meta.line
            local src_col = meta.column

            -- Only set mapping if previous line doesn't already have one
            if not ir_to_src[prev_line] then
              -- Forward mapping
              if not src_to_ir[src_line] then
                src_to_ir[src_line] = {}
              end
              table.insert(src_to_ir[src_line], prev_line)

              -- Reverse mapping with column info
              ir_to_src[prev_line] = {
                line = src_line,
                column = src_col
              }
            end
          end
        end
      else
        -- Look for regular !dbg reference in instruction lines
        -- Examples: "!dbg !21" or ", !dbg !34"
        local dbg_ref = line:match("!dbg%s+!(%d+)")

        if dbg_ref then
          local meta = metadata[tonumber(dbg_ref)]
          if meta and meta.line then
            local src_line = meta.line
            local src_col = meta.column

            -- Forward mapping: add this IR line to source line's list
            if not src_to_ir[src_line] then
              src_to_ir[src_line] = {}
            end
            table.insert(src_to_ir[src_line], ir_line_num)

            -- Reverse mapping with column info
            ir_to_src[ir_line_num] = {
              line = src_line,
              column = src_col
            }
          end
        end
      end
    end
  end

  return src_to_ir, ir_to_src, metadata
end

return M

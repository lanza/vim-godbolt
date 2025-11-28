local M = {}

-- Parse DIFile metadata to build a map of file IDs to filenames
-- @param ir_lines: array of LLVM IR lines
-- @return: table mapping file metadata IDs to {filename, directory}
function M.parse_di_files(ir_lines)
  local file_map = {}  -- !1 -> {filename="main.c", directory="/path"}

  for _, line in ipairs(ir_lines) do
    -- Parse: !5 = !DIFile(filename: "utils.c", directory: "/path", checksumkind: CSK_MD5, checksum: "...")
    -- Note: checksumkind and checksum are optional, so just match filename and directory
    local id, filename, directory = line:match('^(![0-9]+)%s*=%s*!DIFile%(filename:%s*"([^"]+)",%s*directory:%s*"([^"]*)"')

    if id and filename then
      file_map[id] = {
        filename = filename,
        directory = directory or "",
      }
    end
  end

  return file_map
end

-- Parse function definitions and extract their source file information
-- @param ir_lines: array of LLVM IR lines
-- @param file_map: table from parse_di_files
-- @return: table mapping function names to source file info
function M.parse_function_sources(ir_lines, file_map)
  local func_sources = {}  -- "main" -> {filename="main.c", directory="/path"}
  local current_func = nil

  for _, line in ipairs(ir_lines) do
    -- Match function definition: define i32 @main(...) ... !dbg !10 {
    -- Note: There can be attributes like "local_unnamed_addr #0" between ) and !dbg
    local func_name = line:match('^define%s+[^@]*@([^%(]+)%(')
    local dbg_ref = line:match('!dbg%s+(![0-9]+)')

    if func_name and dbg_ref then
      current_func = func_name
      -- We'll need to look up this dbg_ref in DISubprogram metadata
      -- For now, store the reference
      func_sources[func_name] = {dbg_ref = dbg_ref}
    end
  end

  -- Second pass: resolve DISubprogram references to DIFile
  for _, line in ipairs(ir_lines) do
    -- Parse: !10 = distinct !DISubprogram(name: "main", ... file: !1, ...)
    -- Note: "distinct" is a keyword that comes before !DISubprogram
    local id, name, file_ref = line:match('^(![0-9]+)%s*=%s*distinct%s+!DISubprogram%(name:%s*"([^"]+)".*file:%s*(![0-9]+)')

    if id and name and file_ref and file_map[file_ref] then
      -- Find function with this dbg_ref
      for func_name, info in pairs(func_sources) do
        if info.dbg_ref == id then
          func_sources[func_name] = {
            filename = file_map[file_ref].filename,
            directory = file_map[file_ref].directory,
            file_id = file_ref,
          }
        end
      end
    end
  end

  return func_sources
end

-- Detect cross-module inlining by comparing before/after call sites
-- @param before_ir: IR lines before LTO
-- @param after_ir: IR lines after LTO
-- @param func_sources: table from parse_function_sources
-- @return: table with cross-module inlining statistics
function M.detect_cross_module_inlining(before_ir, after_ir, func_sources)
  local stats = {
    total_calls_before = 0,
    total_calls_after = 0,
    cross_module_calls_before = 0,
    cross_module_calls_after = 0,
    inlined_count = 0,
    inlines_by_file = {},  -- {main.c -> {count=5, targets=["utils.c", ...]}}
  }

  -- Helper to extract call sites from IR
  local function extract_calls(ir_lines)
    local calls = {}  -- {caller -> {callee, is_cross_module}}
    local current_func = nil
    local current_file = nil

    for _, line in ipairs(ir_lines) do
      -- Track current function
      local func_name = line:match('^define%s+[^@]*@([^%(]+)%(')
      if func_name then
        current_func = func_name
        current_file = func_sources[func_name] and func_sources[func_name].filename or "unknown"
      end

      -- Look for call instructions
      local called_func = line:match('%s+call%s+[^@]*@([^%(]+)%(')
      if called_func and current_func and current_file then
        -- Skip LLVM intrinsics
        if not called_func:match('^llvm%.') then
          local called_file = func_sources[called_func] and func_sources[called_func].filename or "unknown"
          local is_cross_module = (called_file ~= "unknown" and called_file ~= current_file)

          table.insert(calls, {
            caller = current_func,
            caller_file = current_file,
            callee = called_func,
            callee_file = called_file,
            is_cross_module = is_cross_module,
          })
        end
      end
    end

    return calls
  end

  -- Extract calls from before and after IR
  local calls_before = extract_calls(before_ir)
  local calls_after = extract_calls(after_ir)

  -- Count total and cross-module calls
  for _, call in ipairs(calls_before) do
    stats.total_calls_before = stats.total_calls_before + 1
    if call.is_cross_module then
      stats.cross_module_calls_before = stats.cross_module_calls_before + 1
    end
  end

  for _, call in ipairs(calls_after) do
    stats.total_calls_after = stats.total_calls_after + 1
    if call.is_cross_module then
      stats.cross_module_calls_after = stats.cross_module_calls_after + 1
    end
  end

  -- Calculate inlined calls (calls that disappeared)
  stats.inlined_count = stats.total_calls_before - stats.total_calls_after

  -- Build inlines_by_file map (cross-module calls that disappeared)
  local after_set = {}
  for _, call in ipairs(calls_after) do
    local key = call.caller .. "->" .. call.callee
    after_set[key] = true
  end

  for _, call in ipairs(calls_before) do
    if call.is_cross_module then
      local key = call.caller .. "->" .. call.callee
      if not after_set[key] then
        -- This cross-module call was inlined!
        if not stats.inlines_by_file[call.caller_file] then
          stats.inlines_by_file[call.caller_file] = {count = 0, targets = {}}
        end

        stats.inlines_by_file[call.caller_file].count = stats.inlines_by_file[call.caller_file].count + 1

        if not vim.tbl_contains(stats.inlines_by_file[call.caller_file].targets, call.callee_file) then
          table.insert(stats.inlines_by_file[call.caller_file].targets, call.callee_file)
        end
      end
    end
  end

  return stats
end

-- Track dead code elimination across files
-- @param before_ir: IR lines before LTO
-- @param after_ir: IR lines after LTO
-- @param func_sources: table from parse_function_sources
-- @return: table with dead code elimination statistics
function M.track_dead_code_elimination(before_ir, after_ir, func_sources)
  local stats = {
    functions_removed = 0,
    functions_by_file = {},  -- {main.c -> {removed=["foo", "bar"], kept=["main"]}}
  }

  -- Extract function names from IR
  local function extract_functions(ir_lines)
    local funcs = {}
    for _, line in ipairs(ir_lines) do
      local func_name = line:match('^define%s+[^@]*@([^%(]+)%(')
      if func_name then
        table.insert(funcs, func_name)
      end
    end
    return funcs
  end

  local before_funcs = extract_functions(before_ir)
  local after_funcs = extract_functions(after_ir)

  -- Convert to sets for easier lookup
  local after_set = {}
  for _, func in ipairs(after_funcs) do
    after_set[func] = true
  end

  -- Find removed functions
  for _, func in ipairs(before_funcs) do
    if not after_set[func] then
      stats.functions_removed = stats.functions_removed + 1

      local file = func_sources[func] and func_sources[func].filename or "unknown"
      if not stats.functions_by_file[file] then
        stats.functions_by_file[file] = {removed = {}, kept = {}}
      end

      table.insert(stats.functions_by_file[file].removed, func)
    else
      local file = func_sources[func] and func_sources[func].filename or "unknown"
      if not stats.functions_by_file[file] then
        stats.functions_by_file[file] = {removed = {}, kept = {}}
      end

      table.insert(stats.functions_by_file[file].kept, func)
    end
  end

  return stats
end

-- Format LTO statistics for display
-- @param inlining_stats: from detect_cross_module_inlining
-- @param dce_stats: from track_dead_code_elimination
-- @return: formatted string
function M.format_lto_stats(inlining_stats, dce_stats)
  local lines = {}

  table.insert(lines, "=== LTO Statistics ===")
  table.insert(lines, "")

  -- Cross-module inlining
  table.insert(lines, "Cross-Module Inlining:")
  table.insert(lines, string.format("  Calls before LTO: %d", inlining_stats.total_calls_before))
  table.insert(lines, string.format("  Calls after LTO: %d", inlining_stats.total_calls_after))
  table.insert(lines, string.format("  Total inlined: %d", inlining_stats.inlined_count))
  table.insert(lines, "")
  table.insert(lines, string.format("  Cross-module before: %d", inlining_stats.cross_module_calls_before))
  table.insert(lines, string.format("  Cross-module after: %d", inlining_stats.cross_module_calls_after))
  local cross_inlined = inlining_stats.cross_module_calls_before - inlining_stats.cross_module_calls_after
  table.insert(lines, string.format("  Cross-module inlined: %d", cross_inlined))

  if next(inlining_stats.inlines_by_file) then
    table.insert(lines, "")
    table.insert(lines, "  Inlined by file:")
    for file, info in pairs(inlining_stats.inlines_by_file) do
      local targets = table.concat(info.targets, ", ")
      table.insert(lines, string.format("    %s: %d inlines from [%s]", file, info.count, targets))
    end
  end

  table.insert(lines, "")

  -- Dead code elimination
  table.insert(lines, "Dead Code Elimination:")
  table.insert(lines, string.format("  Functions removed: %d", dce_stats.functions_removed))

  if next(dce_stats.functions_by_file) then
    table.insert(lines, "  By file:")
    for file, info in pairs(dce_stats.functions_by_file) do
      if #info.removed > 0 then
        local removed = table.concat(info.removed, ", ")
        table.insert(lines, string.format("    %s: removed [%s]", file, removed))
      end
      if #info.kept > 0 then
        local kept = table.concat(info.kept, ", ")
        table.insert(lines, string.format("    %s: kept [%s]", file, kept))
      end
    end
  end

  return table.concat(lines, "\n")
end

return M

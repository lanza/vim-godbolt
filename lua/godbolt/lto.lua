local M = {}

-- Compile a single source file to object file with LTO enabled
-- @param source_file: path to source file (.c, .cpp)
-- @param output_obj: path for output object file
-- @param compiler: compiler to use (clang, clang++)
-- @param extra_args: additional compiler arguments
-- @return: success (boolean), error_message (string or nil)
function M.compile_to_object(source_file, output_obj, compiler, extra_args)
  compiler = compiler or "clang"
  extra_args = extra_args or ""

  -- Build command: compile with LTO, debug info, and introspection flags
  local cmd = string.format(
    '%s -c -flto -g -fno-discard-value-names -fstandalone-debug %s "%s" -o "%s" 2>&1',
    compiler,
    extra_args,
    source_file,
    output_obj
  )

  local output = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error

  if exit_code ~= 0 then
    return false, string.format("Compilation failed for %s:\n%s", source_file, output)
  end

  return true, nil
end

-- Link multiple object files with lld and emit LTO IR
-- @param object_files: array of object file paths
-- @param output_ll: path for output LLVM IR file
-- @param linker: linker to use (default: "ld.lld")
-- @param extra_args: additional linker arguments
-- @return: success (boolean), ir_lines (array) or error_message (string)
function M.link_with_lld(object_files, output_ll, linker, extra_args)
  linker = linker or "ld.lld"
  extra_args = extra_args or ""

  if #object_files == 0 then
    return false, "No object files to link"
  end

  -- Build linker command with plugin options to emit LLVM IR
  local obj_list = table.concat(vim.tbl_map(function(f)
    return '"' .. f .. '"'
  end, object_files), " ")

  -- Note: ld.lld uses -plugin-opt=emit-llvm to output LLVM bitcode
  -- We then need to use llvm-dis to convert to readable IR
  local output_bc = output_ll:gsub("%.ll$", ".bc")

  local cmd = string.format(
    '%s -plugin-opt=emit-llvm %s %s -o "%s" 2>&1',
    linker,
    extra_args,
    obj_list,
    output_bc
  )

  local output = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error

  if exit_code ~= 0 then
    return false, string.format("Linking failed:\n%s", output)
  end

  -- Convert bitcode to readable IR using llvm-dis
  if vim.fn.filereadable(output_bc) ~= 1 then
    return false, string.format("Bitcode file not created: %s", output_bc)
  end

  local dis_cmd = string.format('llvm-dis "%s" -o "%s" 2>&1', output_bc, output_ll)
  local dis_output = vim.fn.system(dis_cmd)
  local dis_exit = vim.v.shell_error

  if dis_exit ~= 0 then
    return false, string.format("Failed to convert bitcode to IR:\n%s", dis_output)
  end

  -- Read the output IR file
  if vim.fn.filereadable(output_ll) ~= 1 then
    return false, string.format("Output file not created: %s", output_ll)
  end

  local ir_lines = vim.fn.readfile(output_ll)
  return true, ir_lines
end

-- Alternative: Use clang as linker driver
-- @param source_files: array of source file paths
-- @param output_ll: path for output LLVM IR file
-- @param compiler: compiler to use (clang or clang++)
-- @param extra_args: additional compiler/linker arguments
-- @return: success (boolean), ir_lines (array) or error_message (string)
function M.link_with_clang(source_files, output_ll, compiler, extra_args)
  compiler = compiler or "clang"
  extra_args = extra_args or ""

  if #source_files == 0 then
    return false, "No source files provided"
  end

  -- Build command: compile and link with LTO, emit IR, and introspection flags
  local src_list = table.concat(vim.tbl_map(function(f)
    return '"' .. f .. '"'
  end, source_files), " ")

  local cmd = string.format(
    '%s -flto -g -fno-discard-value-names -fstandalone-debug -Wl,-plugin-opt=emit-llvm %s %s -o "%s" 2>&1',
    compiler,
    extra_args,
    src_list,
    output_ll
  )

  local output = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error
  if exit_code ~= 0 then
    return false, string.format("LTO compilation failed:\n%s", output)
  end

  -- Read the output IR file
  if vim.fn.filereadable(output_ll) ~= 1 then
    return false, string.format("Output file not created: %s", output_ll)
  end

  local ir_lines = vim.fn.readfile(output_ll)
  return true, ir_lines
end

-- Compile multiple source files to object files with LTO
-- @param source_files: array of source file paths
-- @param temp_dir: directory for temporary object files
-- @param compiler: compiler to use (detected from first file if nil)
-- @param extra_args: additional compiler arguments
-- @return: success (boolean), object_files (array) or error_message (string)
function M.compile_all_sources(source_files, temp_dir, compiler, extra_args)
  local object_files = {}

  for i, source_file in ipairs(source_files) do
    -- Detect compiler from file extension if not provided
    local file_compiler = compiler
    if not file_compiler then
      if source_file:match("%.cpp$") or source_file:match("%.cc$") or source_file:match("%.cxx$") then
        file_compiler = "clang++"
      else
        file_compiler = "clang"
      end
    end

    -- Create object file path
    local basename = vim.fn.fnamemodify(source_file, ":t:r")
    local obj_file = string.format("%s/%s_%d.o", temp_dir, basename, i)

    -- Compile to object
    local success, err = M.compile_to_object(source_file, obj_file, file_compiler, extra_args)
    if not success then
      return false, err
    end

    table.insert(object_files, obj_file)
  end

  return true, object_files
end

-- Full LTO workflow: compile all sources and link with LTO
-- @param source_files: array of source file paths
-- @param config: configuration table {compiler, linker, extra_args, keep_temps}
-- @return: success (boolean), ir_lines (array), temp_dir (string) or error_message
function M.lto_compile_and_link(source_files, config)
  config = config or {}
  local compiler = config.compiler
  local linker = config.linker or "ld.lld"
  local extra_args = config.extra_args or ""
  local keep_temps = config.keep_temps or false

  -- Create temporary directory for object files
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, "p")

  -- Step 1: Compile all sources to object files
  local success, object_files = M.compile_all_sources(source_files, temp_dir, compiler, extra_args)
  if not success then
    if not keep_temps then
      vim.fn.delete(temp_dir, "rf")
    end
    return false, object_files -- object_files contains error message
  end

  -- Step 2: Link object files with LTO
  local output_ll = temp_dir .. "/lto_output.ll"
  success, ir_lines = M.link_with_lld(object_files, output_ll, linker, "")

  if not success then
    if not keep_temps then
      vim.fn.delete(temp_dir, "rf")
    end
    return false, ir_lines -- ir_lines contains error message
  end

  -- Return success with IR and temp dir (caller decides cleanup)
  return true, ir_lines, temp_dir
end

-- Cleanup temporary files
-- @param temp_dir: directory to remove
function M.cleanup(temp_dir)
  if temp_dir and vim.fn.isdirectory(temp_dir) == 1 then
    vim.fn.delete(temp_dir, "rf")
  end
end

-- Run LTO pipeline with pass visualization
-- Compiles and links with LTO while capturing all optimization passes
-- @param source_files: array of source file paths
-- @param opt_level: optimization level (e.g., "-O2", "-O3")
-- @param extra_args: additional compiler arguments
-- @return: success (boolean), pipeline_output (string) or error_message (string)
function M.run_lto_pipeline(source_files, opt_level, extra_args)
  opt_level = opt_level or "-O2"
  extra_args = extra_args or ""

  if #source_files == 0 then
    return false, "No source files provided"
  end

  -- Detect compiler from first file
  local compiler = "clang"
  for _, file in ipairs(source_files) do
    if file:match("%.cpp$") or file:match("%.cc$") or file:match("%.cxx$") then
      compiler = "clang++"
      break
    end
  end

  -- Build file list
  local src_list = table.concat(vim.tbl_map(function(f)
    return '"' .. vim.fn.expand(f) .. '"'
  end, source_files), " ")

  -- Create temp output file
  local temp_out = vim.fn.tempname()

  -- Build command: Actually link with LTO to capture link-time passes
  -- Key: We must actually perform linking for LTO passes to run
  -- -g: Generate debug info (required for DIFile and DISubprogram metadata)
  -- -fno-discard-value-names: Keep SSA value names for readability
  -- -fstandalone-debug: Complete debug info (not minimal)
  -- -Wl,-mllvm,-print-changed: Only print IR when passes change it
  -- -Wl,-mllvm,-print-module-scope: Always print full module IR (not just function fragments)
  local cmd = string.format(
    '%s -flto -g -fno-discard-value-names -fstandalone-debug %s %s -Wl,-mllvm,-print-changed -Wl,-mllvm,-print-module-scope %s -o "%s" 2>&1',
    compiler,
    opt_level,
    extra_args,
    src_list,
    temp_out
  )

  print(string.format("[LTO Pipeline] Running command:"))
  print("  " .. cmd)

  local output = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error

  -- Clean up temp file
  if vim.fn.filereadable(temp_out) == 1 then
    vim.fn.delete(temp_out)
  end

  if exit_code ~= 0 then
    return false, string.format("LTO pipeline failed:\n%s", output)
  end

  return true, output
end

return M

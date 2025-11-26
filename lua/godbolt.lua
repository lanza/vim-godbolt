local M = {}

-- Default configuration
M.config = {
  clang = "clang",
  c_args = "-std=c17",
  cpp_args = "-std=c++20",

  swift_args = "",
  swiftc = "swiftc",

  opt = "opt",
  ll_args = "",

  window_cmd = nil,

  -- Line mapping configuration
  line_mapping = {
    enabled = true,
    auto_scroll = false,
    throttle_ms = 150,
  },

  -- Pipeline configuration
  pipeline = {
    enabled = true,
    show_stats = true,
    start_at_final = true,
    filter_unchanged = false,
  },
}

-- Setup function to override defaults
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

-- Detect output type from compiler arguments
local function detect_output_type(all_args, file)
  -- For LLVM IR files, output is always LLVM IR
  if file:match("%.ll$") then
    return "llvm"
  end

  -- Check for various emit flags (using plain string find for simple cases)
  if all_args:find("-emit-llvm", 1, true) then
    return "llvm"
  elseif all_args:find("-emit-cir", 1, true) then
    return "cir"
  elseif all_args:find("-emit-ast", 1, true) then
    return "ast"
  elseif all_args:find("-emit-obj", 1, true) or all_args:match("-c%s") or all_args:match("-c$") then
    return "objdump"
  else
    return "asm"
  end
end

-- Set filetype based on output type
local function set_output_filetype(output_type)
  if output_type == "llvm" then
    vim.bo.filetype = "llvm"
  elseif output_type == "cir" then
    vim.bo.filetype = "mlir"  -- ClangIR uses MLIR syntax
  elseif output_type == "ast" then
    vim.bo.filetype = "text"
  elseif output_type == "objdump" then
    vim.bo.filetype = "asm"
  else
    vim.bo.filetype = "asm"
  end
end

-- Main godbolt function
function M.godbolt(args_str)
  args_str = args_str or ""
  local file = vim.fn.expand("%")
  local source_bufnr = vim.fn.bufnr("%")

  -- Parse first-line godbolt comment
  local first_line = vim.fn.getbufline(source_bufnr, 1, 1)[1] or ""
  local buffer_args = ""
  if first_line:match("^//[%s]*godbolt:") then
    buffer_args = first_line:gsub("^//[%s]*godbolt:", "")
  elseif first_line:match("^;[%s]*godbolt:") then
    buffer_args = first_line:gsub("^;[%s]*godbolt:", "")
  end

  -- Determine compiler and base args based on file type
  local compiler, lang_args, postprocess
  if file:match("%.cpp$") then
    compiler = M.config.clang .. "++"
    lang_args = M.config.cpp_args
  elseif file:match("%.c$") then
    compiler = M.config.clang
    lang_args = M.config.c_args
  elseif file:match("%.swift$") then
    compiler = M.config.swiftc
    lang_args = M.config.swift_args
    postprocess = "| xcrun swift-demangle"
  elseif file:match("%.ll$") then
    compiler = M.config.opt
    lang_args = M.config.ll_args
  else
    -- Default to C
    compiler = M.config.clang
    lang_args = M.config.c_args
  end

  -- Combine ALL arguments for output type detection
  local all_args = table.concat({args_str, buffer_args, lang_args}, " ")
  local output_type = detect_output_type(all_args, file)

  -- Build command arguments
  local cmd_args = {}
  table.insert(cmd_args, string.format('"%s"', file))
  if args_str ~= "" then table.insert(cmd_args, args_str) end
  table.insert(cmd_args, "-S")
  table.insert(cmd_args, "-g")

  -- Add compiler-specific flags
  if not file:match("%.ll$") and not file:match("%.swift$") then
    table.insert(cmd_args, "-fno-asynchronous-unwind-tables")
    table.insert(cmd_args, "-fno-discard-value-names")
  end

  if file:match("%.swift$") then
    table.insert(cmd_args, "-Xllvm --x86-asm-syntax=intel")
  elseif not file:match("%.ll$") then
    table.insert(cmd_args, "-masm=intel")
  end

  if lang_args ~= "" then table.insert(cmd_args, lang_args) end
  if buffer_args ~= "" then table.insert(cmd_args, buffer_args) end
  table.insert(cmd_args, "-o -")

  local cmd = ".!" .. compiler .. " " .. table.concat(cmd_args, " ")
  if postprocess then
    cmd = cmd .. " " .. postprocess
  end

  -- Create new window and set up buffer
  if M.config.window_cmd then
    vim.cmd(M.config.window_cmd)
  else
    vim.cmd("vertical botright new")
  end

  set_output_filetype(output_type)
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "hide"
  vim.bo.swapfile = false
  vim.wo.number = false

  -- Store and execute command
  vim.g.last_godbolt_cmd = cmd

  -- Remove the ".!" prefix for system execution
  local actual_cmd = cmd:gsub("^%.!", "")

  -- Create temporary file for stderr
  local stderr_file = vim.fn.tempname()
  local cmd_with_redirect = actual_cmd .. " 2>" .. stderr_file

  -- Execute command and capture stdout
  local output = vim.fn.system(cmd_with_redirect)

  -- Read stderr from temp file
  local stderr_lines = vim.fn.filereadable(stderr_file) == 1 and vim.fn.readfile(stderr_file) or {}
  vim.fn.delete(stderr_file)

  -- Show stderr (warnings/errors) in message log
  if #stderr_lines > 0 then
    -- Print the command first for context
    print(actual_cmd)
    for _, line in ipairs(stderr_lines) do
      print(line)
    end
  end

  -- Insert stdout into buffer
  local output_lines = vim.split(output, "\n")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, output_lines)

  -- Get output buffer number (current buffer after creating new window)
  local output_bufnr = vim.fn.bufnr("%")

  -- Setup line mapping
  if M.config.line_mapping and M.config.line_mapping.enabled then
    local ok, line_map = pcall(require, 'godbolt.line_map')
    if ok then
      -- Schedule to run after buffer is fully initialized
      vim.schedule(function()
        line_map.setup(source_bufnr, output_bufnr, output_type, M.config.line_mapping)
      end)
    end
  end

  -- Trigger autocommand event
  vim.cmd("doautocmd User VimGodbolt")

end

-- Run LLVM optimization pipeline and show passes
function M.godbolt_pipeline(args_str)
  args_str = args_str or ""
  local file = vim.fn.expand("%")
  local source_bufnr = vim.fn.bufnr("%")

  -- Only works with .ll files
  if not file:match("%.ll$") then
    print("[Pipeline] Only works with LLVM IR (.ll) files")
    return
  end

  -- Parse first-line godbolt comments for pipeline config
  local first_line = vim.fn.getbufline(source_bufnr, 1, 1)[1] or ""
  local pipeline_str = nil
  local o_level = nil

  -- Check for pipeline comment: ; godbolt-pipeline: mem2reg,instcombine
  if first_line:match("^;[%s]*godbolt%-pipeline:") then
    pipeline_str = first_line:gsub("^;[%s]*godbolt%-pipeline:[%s]*", "")
  end

  -- Check for O-level comment: ; godbolt-level: O2
  if first_line:match("^;[%s]*godbolt%-level:") then
    o_level = first_line:gsub("^;[%s]*godbolt%-level:[%s]*", "")
  end

  -- Priority: command line > buffer comment pipeline > buffer comment O-level > default O2
  local pipeline = require('godbolt.pipeline')
  local passes_to_run = nil

  if args_str ~= "" then
    -- Normalize O-level format: accept O2, 02, -O2, etc.
    local o_match = args_str:match("^%-?O?(%d)$")
    if o_match then
      -- It's an O-level: O2, 2, -O2, etc.
      passes_to_run = pipeline.get_o_level_pipeline("O" .. o_match)
    else
      -- Custom pass list
      passes_to_run = args_str
    end
  elseif pipeline_str then
    passes_to_run = pipeline_str
  elseif o_level then
    -- Normalize O-level from comment
    local o_match = o_level:match("^%-?O?(%d)$")
    if o_match then
      passes_to_run = pipeline.get_o_level_pipeline("O" .. o_match)
    else
      passes_to_run = o_level
    end
  else
    -- Default to O2
    passes_to_run = pipeline.get_o_level_pipeline("O2")
  end

  print(string.format("[Pipeline] Running: opt -passes=\"%s\"", passes_to_run))

  -- Run the pipeline
  local passes = pipeline.run_pipeline(file, passes_to_run)

  if not passes then
    print("[Pipeline] Failed to run pipeline (see error above)")
    return
  end

  if #passes == 0 then
    -- Check if the file has optnone attribute (prevents optimization)
    local file_content = vim.fn.readfile(file)
    local has_optnone = false
    for _, line in ipairs(file_content) do
      if line:match("optnone") then
        has_optnone = true
        break
      end
    end

    print("[Pipeline] No passes captured.")

    if has_optnone then
      print("")
      print("  *** FOUND PROBLEM: Your IR has 'optnone' attribute ***")
      print("  This prevents all optimization passes from running!")
      print("")
      print("  Solutions:")
      print("    1. Recompile without -O0:")
      print("       clang -S -emit-llvm yourfile.c -o yourfile.ll")
      print("")
      print("    2. Or strip optnone from existing file:")
      print("       opt -strip-optnone -S " .. file .. " -o " .. file)
      print("")
    else
      print("")
      print("  Possible reasons:")
      print("    1. The pass didn't produce any output")
      print("    2. Your LLVM version doesn't support --print-after-all")
      print("    3. The pass name is incorrect")
      print("")
      print("  To debug, enable debug mode:")
      print("    :GodboltDebug on")
      print("  Then run :VGodboltPipeline again")
      print("")
      print("  Or test manually:")
      print("    opt -passes=\"" .. passes_to_run .. "\" --print-after-all -S " .. file)
    end
    return
  end

  print(string.format("[Pipeline] Captured %d pass stages", #passes))

  -- Setup pipeline viewer (it will create its own 3-pane layout)
  local ok, pipeline_viewer = pcall(require, 'godbolt.pipeline_viewer')
  if ok then
    -- Merge pipeline config with line_mapping config
    local viewer_config = vim.tbl_deep_extend("force", M.config.pipeline, {
      line_mapping = M.config.line_mapping
    })

    pipeline_viewer.setup(source_bufnr, file, passes, viewer_config)
  else
    print("[Pipeline] Failed to load pipeline viewer")
  end

  -- Trigger autocommand event
  vim.cmd("doautocmd User VimGodboltPipeline")
end

return M

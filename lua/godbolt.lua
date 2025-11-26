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

  -- Check for various emit flags
  if all_args:match("-emit%-llvm") then
    return "llvm"
  elseif all_args:match("-emit%-cir") then
    return "cir"  -- ClangIR
  elseif all_args:match("-emit%-ast") then
    return "ast"
  elseif all_args:match("-emit%-obj") or all_args:match("-c%s") or all_args:match("-c$") then
    return "objdump"  -- Binary object file
  else
    return "asm"  -- Default to assembly
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
function M.godbolt(...)
  local args = table.concat({ ... }, " ")
  local file = vim.fn.expand("%")
  local emission = " -S "

  -- Get first line to check for godbolt comments
  local first_line = vim.fn.getbufline(vim.fn.bufnr("%"), 1, 1)[1] or ""
  local buffer_args = ""

  if first_line:match("^//[%s]*godbolt:") then
    buffer_args = first_line:gsub("^//[%s]*godbolt:", "")
  elseif first_line:match("^;[%s]*godbolt:") then
    buffer_args = first_line:gsub("^;[%s]*godbolt:", "")
  end

  -- Detect output type from all arguments
  local all_args = args .. " " .. buffer_args
  local output_type = detect_output_type(all_args, file)

  -- Create new window
  if M.config.window_cmd then
    vim.cmd(M.config.window_cmd)
  else
    vim.cmd("vertical botright new")
  end

  -- Set filetype and buffer options IMMEDIATELY after creating window
  -- This prevents Neovim's auto-detection from overriding our choice
  set_output_filetype(output_type)
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "hide"
  vim.bo.swapfile = false
  vim.wo.number = false

  local file_and_args = '"' .. file .. '" ' .. args
  local cmd

  -- Build command based on file extension
  if file:match("%.cpp$") then
    cmd = ".!" .. M.config.clang .. "++ " ..
        file_and_args .. " " ..
        emission .. " " ..
        " -fno-asynchronous-unwind-tables " ..
        " -fno-discard-value-names " ..
        " -masm=intel " ..
        M.config.cpp_args .. " " ..
        buffer_args .. " " ..
        " -o - "
  elseif file:match("%.swift$") then
    cmd = ".!" .. M.config.swiftc .. " " ..
        file_and_args .. " " ..
        emission .. " " ..
        " -Xllvm --x86-asm-syntax=intel " ..
        M.config.swift_args .. " " ..
        buffer_args .. " " ..
        " -o - | xcrun swift-demangle"
  elseif file:match("%.c$") then
    cmd = ".!" .. M.config.clang .. " " ..
        file_and_args .. " " ..
        emission .. " " ..
        " -fno-asynchronous-unwind-tables " ..
        " -masm=intel " ..
        M.config.c_args ..
        buffer_args .. " " ..
        " -o - "
  elseif file:match("%.ll$") then
    cmd = ".!" .. M.config.opt .. " " ..
        file_and_args .. " " ..
        emission .. " " ..
        M.config.ll_args .. " " ..
        buffer_args .. " " ..
        " -o - "
  else
    -- Default to C
    cmd = ".!" .. M.config.clang .. " " ..
        file_and_args .. " " ..
        emission .. " " ..
        " -fno-asynchronous-unwind-tables " ..
        " -masm=intel " ..
        M.config.c_args ..
        buffer_args .. " " ..
        " -o - "
  end

  -- Store last command for debugging
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

  -- Trigger autocommand event
  vim.cmd("doautocmd User VimGodbolt")

end

return M

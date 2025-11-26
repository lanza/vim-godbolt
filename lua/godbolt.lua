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

  -- Create new window
  if M.config.window_cmd then
    vim.cmd(M.config.window_cmd)
  else
    vim.cmd("vertical botright new")
  end

  -- Set filetype based on buffer args
  if buffer_args:match("-emit%-llvm") then
    vim.bo.filetype = "llvm"
  else
    vim.bo.filetype = "asm"
  end

  -- Set buffer options
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
    vim.bo.filetype = "llvm"
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
  print(cmd)

  -- Execute command
  vim.cmd(cmd)

  -- Trigger autocommand event
  vim.cmd("doautocmd User VimGodbolt")
end

return M

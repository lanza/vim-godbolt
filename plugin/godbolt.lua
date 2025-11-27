-- godbolt.nvim plugin initialization

-- Create the Godbolt command
vim.api.nvim_create_user_command('Godbolt', function(opts)
  local godbolt = require('godbolt')
  -- opts.args is a single string, pass it as is
  godbolt.godbolt(opts.args)
end, {
  nargs = '*',
  desc = 'Compile current file to assembly/IR using Godbolt-style compilation'
})

-- Create the GodboltPipeline command
vim.api.nvim_create_user_command('GodboltPipeline', function(opts)
  local godbolt = require('godbolt')
  godbolt.godbolt_pipeline(opts.args)
end, {
  nargs = '*',
  desc = 'Run LLVM optimization pipeline and navigate through passes'
})

-- Create the GodboltLTO command for Link-Time Optimization
vim.api.nvim_create_user_command('GodboltLTO', function(opts)
  local godbolt = require('godbolt')
  -- Split args into files and additional arguments
  local args_str = opts.args or ""
  local files = vim.split(args_str, "%s+")
  godbolt.godbolt_lto(files, "")
end, {
  nargs = '+',
  complete = 'file',
  desc = 'Compile and link multiple files with LTO (Link-Time Optimization)'
})

-- Create the GodboltLTOPipeline command for LTO pass visualization
vim.api.nvim_create_user_command('GodboltLTOPipeline', function(opts)
  local godbolt = require('godbolt')
  local args_str = opts.args or ""
  local files = vim.split(args_str, "%s+")
  godbolt.godbolt_lto_pipeline(files, "")
end, {
  nargs = '+',
  complete = 'file',
  desc = 'Visualize LTO optimization pipeline for multiple files'
})

-- Pipeline navigation commands
vim.api.nvim_create_user_command('NextPass', function()
  local ok, pipeline_viewer = pcall(require, 'godbolt.pipeline_viewer')
  if ok then
    pipeline_viewer.next_pass()
  else
    print("[Pipeline] No active pipeline viewer")
  end
end, {
  desc = 'Navigate to next optimization pass'
})

vim.api.nvim_create_user_command('PrevPass', function()
  local ok, pipeline_viewer = pcall(require, 'godbolt.pipeline_viewer')
  if ok then
    pipeline_viewer.prev_pass()
  else
    print("[Pipeline] No active pipeline viewer")
  end
end, {
  desc = 'Navigate to previous optimization pass'
})

vim.api.nvim_create_user_command('GotoPass', function(opts)
  local ok, pipeline_viewer = pcall(require, 'godbolt.pipeline_viewer')
  if ok then
    if opts.args ~= "" then
      local index = tonumber(opts.args)
      if index then
        pipeline_viewer.show_pass(index)
      else
        print("[Pipeline] Invalid pass number")
      end
    else
      pipeline_viewer.goto_pass()
    end
  else
    print("[Pipeline] No active pipeline viewer")
  end
end, {
  nargs = '?',
  desc = 'Go to specific optimization pass'
})

vim.api.nvim_create_user_command('FirstPass', function()
  local ok, pipeline_viewer = pcall(require, 'godbolt.pipeline_viewer')
  if ok then
    pipeline_viewer.first_pass()
  else
    print("[Pipeline] No active pipeline viewer")
  end
end, {
  desc = 'Go to first optimization pass'
})

vim.api.nvim_create_user_command('LastPass', function()
  local ok, pipeline_viewer = pcall(require, 'godbolt.pipeline_viewer')
  if ok then
    pipeline_viewer.last_pass()
  else
    print("[Pipeline] No active pipeline viewer")
  end
end, {
  desc = 'Go to last optimization pass'
})

-- Debug commands
vim.api.nvim_create_user_command('GodboltDebug', function(opts)
  local pipeline = require('godbolt.pipeline')
  if opts.args == "on" or opts.args == "true" or opts.args == "1" then
    pipeline.debug = true
    print("[Pipeline] Debug mode enabled")
  elseif opts.args == "off" or opts.args == "false" or opts.args == "0" then
    pipeline.debug = false
    print("[Pipeline] Debug mode disabled")
  else
    -- Toggle
    pipeline.debug = not pipeline.debug
    print(string.format("[Pipeline] Debug mode %s", pipeline.debug and "enabled" or "disabled"))
  end
end, {
  nargs = '?',
  desc = 'Toggle pipeline debug mode (on/off/toggle)'
})

-- Strip optnone attribute from current file
vim.api.nvim_create_user_command('GodboltStripOptnone', function()
  local file = vim.fn.expand("%")

  if not file:match("%.ll$") then
    print("[Godbolt] Only works with LLVM IR (.ll) files")
    return
  end

  local cmd = string.format('opt -strip-optnone -S "%s" -o "%s"', file, file)
  print("[Godbolt] Running: " .. cmd)

  local result = vim.fn.system(cmd)

  if vim.v.shell_error == 0 then
    print("[Godbolt] Successfully stripped 'optnone' attributes")
    print("[Godbolt] Reloading file...")
    vim.cmd('edit!')
  else
    print("[Godbolt] Error stripping optnone:")
    print(result)
  end
end, {
  desc = 'Strip optnone attributes from current LLVM IR file'
})

-- Show last compilation command
vim.api.nvim_create_user_command('GodboltShowCommand', function()
  local cmd = vim.g.last_godbolt_cmd
  if cmd then
    -- Remove the ".!" prefix if present
    cmd = cmd:gsub("^%.!", "")
    print("[Godbolt] Last compilation command:")
    print(cmd)
  else
    print("[Godbolt] No compilation command available. Run :Godbolt first.")
  end
end, {
  desc = 'Show the last Godbolt compilation command'
})

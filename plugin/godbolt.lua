-- vim-godbolt plugin initialization

-- Create the VGodbolt command
vim.api.nvim_create_user_command('VGodbolt', function(opts)
  local godbolt = require('godbolt')
  -- opts.args is a single string, pass it as is
  godbolt.godbolt(opts.args)
end, {
  nargs = '*',
  desc = 'Compile current file to assembly/IR using Godbolt-style compilation'
})

-- Create the VGodboltPipeline command
vim.api.nvim_create_user_command('VGodboltPipeline', function(opts)
  local godbolt = require('godbolt')
  godbolt.godbolt_pipeline(opts.args)
end, {
  nargs = '*',
  desc = 'Run LLVM optimization pipeline and navigate through passes'
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

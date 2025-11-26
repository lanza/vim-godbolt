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

-- Minimal init for testing
vim.cmd([[set runtimepath=$VIMRUNTIME]])
vim.cmd([[set packpath=/tmp/nvim/site]])

-- Add current plugin to runtimepath
local plugin_dir = vim.fn.fnamemodify(vim.fn.getcwd(), ':p')
vim.opt.rtp:append(plugin_dir)

-- Add plenary to runtimepath
local plenary_dir = vim.fn.expand('~/.local/share/nvim/lazy/plenary.nvim')
if vim.fn.isdirectory(plenary_dir) == 1 then
  vim.opt.rtp:append(plenary_dir)
end

vim.o.swapfile = false
vim.bo.swapfile = false

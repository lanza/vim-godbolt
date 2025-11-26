local M = {}

local stats = require('godbolt.stats')

-- State for pipeline viewer
M.state = {
  passes = {},
  current_index = 1,
  source_bufnr = nil,
  output_bufnr = nil,
  config = nil,
  ns_id = vim.api.nvim_create_namespace('godbolt_pipeline'),
}

-- Setup pipeline viewer
-- @param source_bufnr: source buffer number
-- @param output_bufnr: output buffer number (where to show IR)
-- @param passes: array of {name, ir} from pipeline.parse_pipeline_output
-- @param config: configuration table
function M.setup(source_bufnr, output_bufnr, passes, config)
  config = config or {}

  -- Default config
  local default_config = {
    show_stats = true,
    start_at_final = true,  -- Start at the final pass
    filter_unchanged = false,
  }
  config = vim.tbl_deep_extend("force", default_config, config)

  -- Filter passes if requested
  if config.filter_unchanged then
    local pipeline = require('godbolt.pipeline')
    passes = pipeline.filter_changed_passes(passes)
    print(string.format("[Pipeline] Filtered to %d passes that changed IR", #passes))
  end

  -- Calculate statistics for each pass
  for i, pass in ipairs(passes) do
    pass.stats = stats.count(pass.ir)
  end

  -- Store state
  M.state.passes = passes
  M.state.source_bufnr = source_bufnr
  M.state.output_bufnr = output_bufnr
  M.state.config = config

  -- Start at final pass or first pass
  if config.start_at_final then
    M.state.current_index = #passes
  else
    M.state.current_index = 1
  end

  -- Show initial pass
  M.show_pass(M.state.current_index)

  -- Set up key mappings in output buffer
  M.setup_keymaps()
end

-- Show a specific pass in the output buffer
-- @param index: pass index (1-based)
function M.show_pass(index)
  if #M.state.passes == 0 then
    print("[Pipeline] No passes to show")
    return
  end

  -- Clamp index to valid range
  if index < 1 then
    print("[Pipeline] Already at first pass")
    return
  end
  if index > #M.state.passes then
    print("[Pipeline] Already at last pass")
    return
  end

  M.state.current_index = index
  local pass = M.state.passes[index]

  if not vim.api.nvim_buf_is_valid(M.state.output_bufnr) then
    print("[Pipeline] Output buffer is no longer valid")
    return
  end

  -- Update buffer content
  vim.api.nvim_buf_set_lines(M.state.output_bufnr, 0, -1, false, pass.ir)

  -- Set buffer name to show current pass
  local buf_name = string.format("Pass %d/%d: %s", index, #M.state.passes, pass.name)
  pcall(vim.api.nvim_buf_set_name, M.state.output_bufnr, buf_name)

  -- Set filetype
  vim.api.nvim_buf_set_option(M.state.output_bufnr, 'filetype', 'llvm')

  -- Show statistics if enabled
  if M.state.config.show_stats then
    M.show_stats(index)
  end

  -- Update line mapping if enabled
  if M.state.config.line_mapping and M.state.config.line_mapping.enabled then
    vim.schedule(function()
      local ok, line_map = pcall(require, 'godbolt.line_map')
      if ok then
        line_map.cleanup()
        line_map.setup(
          M.state.source_bufnr,
          M.state.output_bufnr,
          "llvm",
          M.state.config.line_mapping
        )
      end
    end)
  end
end

-- Show statistics for current pass
-- @param index: pass index
function M.show_stats(index)
  local pass = M.state.passes[index]

  -- Calculate delta from previous pass
  local delta_str = ""
  if index > 1 then
    local prev_stats = M.state.passes[index - 1].stats
    local delta = stats.delta(prev_stats, pass.stats)
    delta_str = " | " .. stats.format_with_delta(pass.stats, delta)
  else
    delta_str = " | " .. stats.format_compact(pass.stats)
  end

  -- Print to command line
  print(string.format("[Pipeline] Pass %d/%d: %s%s",
    index, #M.state.passes, pass.name, delta_str))

  -- Also show as virtual text at top of buffer
  if vim.api.nvim_buf_is_valid(M.state.output_bufnr) then
    -- Clear previous virtual text
    vim.api.nvim_buf_clear_namespace(M.state.output_bufnr, M.state.ns_id, 0, -1)

    -- Add new virtual text
    local virt_text = string.format("Pass %d/%d: %s%s",
      index, #M.state.passes, pass.name, delta_str)

    pcall(vim.api.nvim_buf_set_extmark, M.state.output_bufnr, M.state.ns_id, 0, 0, {
      virt_text = {{virt_text, "Comment"}},
      virt_text_pos = "eol",
    })
  end
end

-- Navigate to next pass
function M.next_pass()
  M.show_pass(M.state.current_index + 1)
end

-- Navigate to previous pass
function M.prev_pass()
  M.show_pass(M.state.current_index - 1)
end

-- Navigate to first pass
function M.first_pass()
  M.show_pass(1)
end

-- Navigate to last pass
function M.last_pass()
  M.show_pass(#M.state.passes)
end

-- Navigate to specific pass (with prompt)
function M.goto_pass()
  local input = vim.fn.input(string.format("Go to pass (1-%d): ", #M.state.passes))
  local index = tonumber(input)

  if index then
    M.show_pass(index)
  else
    print("[Pipeline] Invalid pass number")
  end
end

-- Setup key mappings in output buffer
function M.setup_keymaps()
  if not vim.api.nvim_buf_is_valid(M.state.output_bufnr) then
    return
  end

  local bufnr = M.state.output_bufnr

  -- Navigation mappings
  vim.keymap.set('n', ']p', function() M.next_pass() end, {
    buffer = bufnr,
    desc = 'Next optimization pass'
  })

  vim.keymap.set('n', '[p', function() M.prev_pass() end, {
    buffer = bufnr,
    desc = 'Previous optimization pass'
  })

  vim.keymap.set('n', 'gp', function() M.goto_pass() end, {
    buffer = bufnr,
    desc = 'Go to specific pass'
  })

  vim.keymap.set('n', 'g[', function() M.first_pass() end, {
    buffer = bufnr,
    desc = 'Go to first pass'
  })

  vim.keymap.set('n', 'g]', function() M.last_pass() end, {
    buffer = bufnr,
    desc = 'Go to last pass'
  })
end

-- Cleanup viewer state
function M.cleanup()
  M.state = {
    passes = {},
    current_index = 1,
    source_bufnr = nil,
    output_bufnr = nil,
    config = nil,
    ns_id = M.state.ns_id,  -- Keep namespace
  }
end

return M

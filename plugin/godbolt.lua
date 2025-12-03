-- godbolt.nvim plugin initialization

-- Create the Godbolt command
vim.api.nvim_create_user_command('Godbolt', function(opts)
  local godbolt = require('godbolt')
  -- Default to LLVM IR when using compile_commands.json
  godbolt.godbolt(opts.args, { output = "llvm" })
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
  if args_str == "" then
    -- No args - auto-detect from compile_commands.json
    godbolt.godbolt_lto(nil, "", { output = "llvm" })
  else
    local files = vim.split(args_str, "%s+")
    godbolt.godbolt_lto(files, "", { output = "llvm" })
  end
end, {
  nargs = '*',  -- Changed from '+' to '*' to allow 0 arguments
  complete = 'file',
  desc = 'Compile and link multiple files with LTO (auto-detects from compile_commands.json if no args)'
})

-- Create the GodboltLTOPipeline command for LTO pass visualization
vim.api.nvim_create_user_command('GodboltLTOPipeline', function(opts)
  local godbolt = require('godbolt')
  local args_str = opts.args or ""
  if args_str == "" then
    -- No args - auto-detect from compile_commands.json
    godbolt.godbolt_lto_pipeline(nil, "", { output = "llvm" })
  else
    local files = vim.split(args_str, "%s+")
    godbolt.godbolt_lto_pipeline(files, "", { output = "llvm" })
  end
end, {
  nargs = '*',  -- Changed from '+' to '*' to allow 0 arguments
  complete = 'file',
  desc = 'Visualize LTO optimization pipeline (auto-detects from compile_commands.json if no args)'
})

-- Create the GodboltLTOCompare command for Before/After LTO comparison
vim.api.nvim_create_user_command('GodboltLTOCompare', function(opts)
  local godbolt = require('godbolt')
  local args_str = opts.args or ""
  godbolt.godbolt_lto_compare(args_str, "", { output = "llvm" })
end, {
  nargs = '*',  -- Changed from '+' to '*' to allow 0 arguments
  complete = 'file',
  desc = 'Show Before/After LTO comparison with statistics (auto-detects from compile_commands.json if no args)'
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

-- Pipeline session commands
vim.api.nvim_create_user_command('GodboltPipelineSave', function(opts)
  local pipeline_viewer = require('godbolt.pipeline_viewer')
  local pipeline_session = require('godbolt.pipeline_session')

  if not pipeline_viewer.state or not pipeline_viewer.state.passes then
    vim.notify("[Pipeline] No active pipeline to save", vim.log.levels.WARN)
    return
  end

  local name = opts.args ~= "" and opts.args or nil
  local set_latest = opts.bang

  -- Get compilation info from state
  local compilation_info = {
    opt_level = pipeline_viewer.state.opt_level,
    command = pipeline_viewer.state.compilation_command,
    compiler = pipeline_viewer.state.compiler,
  }

  local filepath, err = pipeline_session.save_session(
    pipeline_viewer.state.passes,
    pipeline_viewer.state.initial_ir,
    pipeline_viewer.state.source_file or vim.fn.expand("%:p"),
    compilation_info,
    name
  )

  if not filepath then
    vim.notify("[Pipeline] Failed to save session: " .. (err or "unknown error"), vim.log.levels.ERROR)
  elseif set_latest then
    vim.notify("[Pipeline] Session saved and set as latest", vim.log.levels.INFO)
  end
end, {
  nargs = '?',
  bang = true,
  desc = 'Save current pipeline state (use ! to set as latest)'
})

vim.api.nvim_create_user_command('GodboltPipelineLoad', function(opts)
  local pipeline_session = require('godbolt.pipeline_session')
  local pipeline_viewer = require('godbolt.pipeline_viewer')
  local pipeline = require('godbolt.pipeline')
  local serializer = require('godbolt.pipeline_serializer')

  -- Helper function to resolve IR references before passing to viewer
  local function resolve_ir_for_viewer(passes, initial_ir)
    -- Clear resolution cache before resolving passes
    pipeline.ir_resolver.clear_cache()

    -- Resolve ir_or_index to .ir for all passes (same as pipeline.lua does)
    for i, pass in ipairs(passes) do
      pass._initial_ir = initial_ir
      pass.ir = pipeline.ir_resolver.get_after_ir(passes, initial_ir, i)
    end

    return passes
  end

  -- Helper to load and display a session
  local function load_and_display(session)
    -- Load directly from session.file
    local result, err = serializer.load_from_file(session.file)
    if not result then
      vim.notify("[Pipeline] Failed to load session: " .. (err or "unknown error"), vim.log.levels.ERROR)
      return
    end

    -- Resolve IR references before passing to viewer
    local passes = resolve_ir_for_viewer(result.passes, result.initial_ir)

    -- Determine source file for viewer
    local source_file = result.metadata and result.metadata.source and result.metadata.source.file
      or session.file

    -- Setup viewer with loaded data
    pipeline_viewer.setup(
      vim.api.nvim_get_current_buf(),
      source_file,
      passes,
      vim.tbl_extend("force", require('godbolt').config, {
        loaded_from_session = true,
        session_metadata = {
          name = session.name,
          timestamp = session.timestamp,
          opt_level = session.opt_level,
          file = session.file,
        },
      })
    )
  end

  -- Show picker if no argument provided
  if opts.args == "" then
    pipeline_session.show_session_picker(nil, function(session)
      if session then
        load_and_display(session)
      end
    end)
    return
  end

  -- Direct load with argument - search all sessions for matching name
  local sessions = pipeline_session.list_all_sessions()
  local name_or_index = opts.args

  -- Try to parse as number first
  local num = tonumber(name_or_index)
  if num then
    if num >= 1 and num <= #sessions then
      load_and_display(sessions[num])
    else
      vim.notify("[Pipeline] Session index " .. num .. " not found", vim.log.levels.ERROR)
    end
    return
  end

  -- Search by name
  for _, session in ipairs(sessions) do
    if session.name == name_or_index then
      load_and_display(session)
      return
    end
  end

  vim.notify("[Pipeline] Session '" .. name_or_index .. "' not found", vim.log.levels.ERROR)
end, {
  nargs = '?',
  desc = 'Load saved pipeline session (name, index, or show picker)'
})

vim.api.nvim_create_user_command('GodboltPipelineList', function()
  local pipeline_session = require('godbolt.pipeline_session')

  local sessions = pipeline_session.list_all_sessions()

  if #sessions == 0 then
    vim.notify("[Pipeline] No saved sessions", vim.log.levels.INFO)
    return
  end

  print("Pipeline sessions:")
  print(string.format("%-5s %-12s %-20s %-5s %-7s %-8s %s",
    "Index", "Source", "Timestamp", "Opt", "Passes", "Size", "Name"))
  print(string.rep("-", 75))

  for i, session in ipairs(sessions) do
    local timestamp_str = os.date("%Y-%m-%d %H:%M:%S", session.timestamp)
    local opt_str = session.opt_level or "??"
    local pass_str = string.format("%d", session.passes or 0)
    local size_kb = session.size and string.format("%.0f KB", session.size / 1024) or "?"
    local name_str = session.name or ""
    local source_str = session.source_key or "?"

    print(string.format("[%-3d] %-12s %-20s %-5s %-7s %-8s %s",
      i, source_str, timestamp_str, opt_str, pass_str, size_kb, name_str))
  end
end, {
  desc = 'List all available pipeline sessions'
})

vim.api.nvim_create_user_command('GodboltPipelineDelete', function(opts)
  local pipeline_session = require('godbolt.pipeline_session')
  local source_file = vim.fn.expand("%:p")

  if opts.args == "" then
    vim.notify("[Pipeline] Usage: :GodboltPipelineDelete <index|name>", vim.log.levels.WARN)
    return
  end

  local name_or_index = tonumber(opts.args) or opts.args

  local success, err = pipeline_session.delete_session(source_file, name_or_index)
  if not success then
    vim.notify("[Pipeline] " .. (err or "Failed to delete session"), vim.log.levels.ERROR)
  end
end, {
  nargs = 1,
  desc = 'Delete a saved pipeline session'
})

vim.api.nvim_create_user_command('GodboltPipelineCleanup', function()
  local pipeline_session = require('godbolt.pipeline_session')
  local source_file = vim.fn.expand("%:p")

  local count = pipeline_session.cleanup_old_sessions(source_file)
  if count == 0 then
    vim.notify("[Pipeline] No old sessions to clean up", vim.log.levels.INFO)
  end
end, {
  desc = 'Clean up old pipeline sessions based on policy'
})

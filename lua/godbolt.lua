local M = {}

-- Helper to get timestamp string
local function get_timestamp()
  return os.date("%H:%M:%S")
end

---@class GodboltLineMapping
---@field enabled boolean Enable line mapping between source and IR
---@field auto_scroll boolean Auto-scroll to mapped lines when cursor moves
---@field throttle_ms number Throttle delay in milliseconds
---@field silent_on_failure boolean Show error messages if debug info missing
---@field show_compilation_cmd boolean Show compilation command when debug info fails

---@class GodboltDisplay
---@field strip_debug_metadata boolean Hide debug metadata (!123 = !{...}) in LLVM IR display

---@class GodboltRemarksInlineHints
---@field enabled boolean Show remarks as inline hints by default
---@field format "icon"|"short"|"detailed" How much detail to show inline
---@field position "eol"|"right_align" Position of inline hints

---@class GodboltRemarks
---@field pass boolean Enable optimization pass remarks
---@field missed boolean Enable missed optimization remarks
---@field analysis boolean Enable analysis remarks
---@field filter string Regex filter for which passes to report (default: ".*" for all)
---@field inline_hints GodboltRemarksInlineHints Inline hints configuration

---@class GodboltKeymaps
---@field next_pass string|string[] Move to next pass
---@field prev_pass string|string[] Move to previous pass
---@field next_changed string|string[] Jump to next changed pass
---@field prev_changed string|string[] Jump to previous changed pass
---@field toggle_fold string|string[] Toggle fold/unfold group
---@field activate_line string|string[] Select pass or toggle fold
---@field first_pass string|string[] Jump to first pass
---@field last_pass string|string[] Jump to last pass
---@field show_remarks string|string[] Show remarks for current pass
---@field show_all_remarks string|string[] Show ALL remarks from all passes
---@field toggle_inline_hints string|string[] Toggle inline hints on/off
---@field show_help string|string[] Show help menu
---@field quit string|string[] Quit pipeline viewer

---@class GodboltPipeline
---@field enabled boolean Enable pipeline viewer
---@field show_stats boolean Show statistics logging
---@field start_at_final boolean Start at final pass instead of first
---@field filter_unchanged boolean Filter out passes that didn't change IR
---@field remarks GodboltRemarks Optimization remarks configuration
---@field keymaps GodboltKeymaps Keymaps configuration for pipeline viewer

---@class GodboltLTO
---@field enabled boolean Enable LTO support
---@field linker string Linker to use (ld.lld, lld, etc.)
---@field keep_temps boolean Keep temporary object files
---@field save_temps boolean Use -save-temps to preserve intermediate files
---@field project_auto_detect boolean Auto-detect project files
---@field compile_commands_path string Path to compile_commands.json

---@class GodboltConfig
---@field clang string Path to clang compiler
---@field c_args string Default C compiler arguments
---@field cpp_args string Default C++ compiler arguments
---@field swift_args string Default Swift compiler arguments
---@field swiftc string Path to swiftc compiler
---@field opt string Path to opt tool
---@field ll_args string Default LLVM IR arguments
---@field window_cmd string|nil Custom window command
---@field line_mapping GodboltLineMapping Line mapping configuration
---@field display GodboltDisplay Display configuration
---@field pipeline GodboltPipeline Pipeline configuration
---@field lto GodboltLTO LTO configuration

-- Default configuration
---@type GodboltConfig
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
    auto_scroll = true,             -- Auto-scroll to mapped lines when cursor moves
    throttle_ms = 150,
    silent_on_failure = false,      -- Show error messages if debug info missing
    show_compilation_cmd = true,    -- Show compilation command when debug info fails
  },

  -- Display configuration
  display = {
    strip_debug_metadata = true,    -- Hide debug metadata (!123 = !{...}) in LLVM IR display
  },

  -- Pipeline configuration
  pipeline = {
    enabled = true,
    show_stats = false,            -- Disable stats logging by default (prints to messages, causes line wrapping)
    start_at_final = true,
    filter_unchanged = false,

    -- Optimization remarks configuration
    remarks = {
      pass = true,
      missed = true,
      analysis = true,
      filter = ".*",

      -- Inline hints (virtual text) configuration
      inline_hints = {
        enabled = true,           -- Show remarks as inline hints by default
        -- Format: "icon", "short", "detailed"
        format = "short",         -- How much detail to show inline
        position = "eol",         -- "eol" (end of line) or "right_align"
      },
    },

    -- Keymaps configuration for pipeline viewer
    keymaps = {
      -- Pass list navigation
      next_pass = { 'j', '<Down>' },
      prev_pass = { 'k', '<Up>' },
      next_changed = '<Tab>',
      prev_changed = '<S-Tab>',

      -- Folding
      toggle_fold = 'o',
      activate_line = '<CR>',

      -- Jump to first/last
      first_pass = 'g[',
      last_pass = 'g]',

      -- Show remarks popup
      show_remarks = { 'R', 'gr' },
      show_all_remarks = 'gR',  -- Show remarks from ALL passes
      toggle_inline_hints = 'gh',  -- Toggle inline hints on/off

      -- Show help menu
      show_help = 'g?',

      -- Quit
      quit = 'q',
    },
  },

  -- LTO (Link-Time Optimization) configuration
  lto = {
    enabled = true,
    linker = "ld.lld",              -- Linker to use (ld.lld, lld, etc.)
    keep_temps = false,             -- Keep temporary object files
    save_temps = true,              -- Use -save-temps to preserve intermediate files
    project_auto_detect = true,     -- Auto-detect project files
    compile_commands_path = "compile_commands.json",  -- Path to compile_commands.json
  },
}

-- Setup function to override defaults
---@param opts GodboltConfig|nil User configuration
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Normalize remarks config: true → {pass=true, missed=true, analysis=true, filter=".*"}
  if M.config.pipeline and M.config.pipeline.remarks then
    local remarks = M.config.pipeline.remarks
    if remarks == true then
      M.config.pipeline.remarks = {
        pass = true,
        missed = true,
        analysis = true,
        filter = ".*",
        inline_hints = {
          enabled = true,
          format = "short",
          position = "eol",
        },
      }
    elseif type(remarks) == "table" then
      -- Set defaults for missing fields
      if remarks.filter == nil then
        remarks.filter = ".*"
      end
      if remarks.inline_hints == nil then
        remarks.inline_hints = {
          enabled = true,
          format = "short",
          position = "eol",
        }
      end
    end
  end
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

-- Check if debug info exists in compilation output
-- @param output_lines: array of output lines
-- @param output_type: "asm" or "llvm"
-- @return: boolean, string (has_debug_info, diagnostic_message)
local function verify_debug_info(output_lines, output_type)
  if output_type == "llvm" then
    -- For LLVM IR, look for debug metadata
    for _, line in ipairs(output_lines) do
      if line:match("!DILocation") or line:match("!dbg") then
        return true, nil
      end
    end
    return false, "LLVM IR output contains no debug metadata (!DILocation or !dbg). This usually means debug info was stripped or not generated."
  elseif output_type == "asm" then
    -- For assembly, look for .loc or .file directives
    for _, line in ipairs(output_lines) do
      if line:match("^%s*%.loc%s") or line:match("^%s*%.file%s") then
        return true, nil
      end
    end
    return false, "Assembly output contains no debug directives (.loc or .file). Assembly line mapping is a work in progress."
  end

  return true, nil  -- For other types, assume OK
end

-- Check if args contain debug-disabling flags
-- @param args: string of compiler arguments
-- @return: boolean (true if debug-disabling flags found)
local function has_debug_disabling_flags(args)
  -- Check for flags that explicitly disable debug info
  return args:match("%-g0%s") or args:match("%-g0$") or
         args:match("%-ggdb0%s") or args:match("%-ggdb0$")
end

-- Main godbolt function
---@param args_str string|nil Compiler arguments (optional)
---@param opts table|nil Options table (optional)
---  - output: "llvm", "asm", or "auto" (default: "auto")
function M.godbolt(args_str, opts)
  args_str = args_str or ""
  opts = opts or {}
  local output_preference = opts.output or "auto"

  local file = vim.fn.expand("%:p")  -- Get absolute path
  local source_bufnr = vim.fn.bufnr("%")
  local compile_directory = nil  -- Working directory from compile_commands.json
  local cc_compiler = nil  -- Compiler from compile_commands.json

  -- Try to get compiler flags from compile_commands.json if no args provided
  if args_str == "" or args_str == "-g" then
    local project = require('godbolt.project')
    local compile_commands = require('godbolt.compile_commands')

    local cc_path = project.find_compile_commands()

    -- When using compile_commands.json, default to LLVM IR (unless explicitly set to "asm")
    -- This provides better UX since LLVM IR is more useful for analysis
    if cc_path and output_preference == "auto" then
      output_preference = "llvm"
    end

    if cc_path then
      local ok, cc_data = compile_commands.parse_compile_commands(cc_path)
      if ok then
        local entry = compile_commands.find_file_entry(cc_data, file)
        if entry then
          -- Store the directory to run compilation from
          compile_directory = entry.directory

          local parsed = compile_commands.parse_entry(entry)
          if parsed then
            -- Store compiler from compile_commands.json
            cc_compiler = parsed.compiler

            local relevant_flags = compile_commands.filter_relevant_flags(parsed.args)
            if #relevant_flags > 0 then
              -- Prepend compile_commands flags before user args
              local cc_flags = table.concat(relevant_flags, " ")

              -- Apply output preference when using compile_commands.json
              if output_preference ~= "auto" then
                -- Check if user has explicitly specified output format in args
                local has_explicit_output = args_str:match("-emit%-") or
                                           args_str:match("^%-S%s") or
                                           args_str:match("%s%-S%s") or
                                           args_str:match("%s%-S$")

                if not has_explicit_output then
                  if output_preference == "llvm" then
                    cc_flags = cc_flags .. " -emit-llvm"
                    print(string.format("[Godbolt] Auto-injecting -emit-llvm (output='%s')", output_preference))
                  elseif output_preference == "asm" then
                    -- Assembly is the default, no flag needed
                    print(string.format("[Godbolt] Using assembly output (output='%s')", output_preference))
                  end
                end
              end

              print(string.format("[Godbolt] Using compiler from compile_commands.json: %s", cc_compiler))
              print(string.format("[Godbolt] Using flags from compile_commands.json: %s", cc_flags))
              print(string.format("[Godbolt] Working directory: %s", compile_directory))
              args_str = args_str == "" and cc_flags or (cc_flags .. " " .. args_str)
            end
          end
        end
      end
    end
  end

  -- Parse first-line godbolt comment
  local first_line = vim.fn.getbufline(source_bufnr, 1, 1)[1] or ""
  local buffer_args = ""
  if first_line:match("^//[%s]*godbolt:") then
    buffer_args = first_line:gsub("^//[%s]*godbolt:", "")
  elseif first_line:match("^;[%s]*godbolt:") then
    buffer_args = first_line:gsub("^;[%s]*godbolt:", "")
  end

  -- Use relative path for display in commands
  file = vim.fn.expand("%")

  -- Determine compiler and base args based on file type
  local compiler, lang_args, postprocess
  if cc_compiler then
    -- Use compiler from compile_commands.json
    compiler = cc_compiler
    lang_args = ""  -- compile_commands.json already includes language args
  elseif file:match("%.cpp$") then
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

  -- Add compiler-specific flags for better introspection
  if not file:match("%.ll$") and not file:match("%.swift$") then
    table.insert(cmd_args, "-fno-asynchronous-unwind-tables")
    table.insert(cmd_args, "-fno-discard-value-names")  -- Keep SSA value names
    table.insert(cmd_args, "-fstandalone-debug")        -- Complete debug info
  end

  if file:match("%.swift$") then
    table.insert(cmd_args, "-Xllvm --x86-asm-syntax=intel")
  elseif not file:match("%.ll$") then
    table.insert(cmd_args, "-masm=intel")
  end

  if lang_args ~= "" then table.insert(cmd_args, lang_args) end
  if buffer_args ~= "" then table.insert(cmd_args, buffer_args) end

  -- Check if user has explicitly disabled debug info
  local all_user_args = table.concat({args_str, buffer_args, lang_args}, " ")
  if has_debug_disabling_flags(all_user_args) then
    print("[Godbolt] Warning: Debug-disabling flags detected (-g0). Line mapping may not work.")
  end

  -- Add -g LAST to ensure it's not overridden by user flags
  -- This is critical for line mapping to work
  -- NOTE: Only add -g for compilers (clang, swiftc), NOT for opt (LLVM IR optimizer)
  -- opt doesn't support -g flag and will error out
  if not file:match("%.ll$") then
    table.insert(cmd_args, "-g")
  end

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

  -- If we have a compile_directory from compile_commands.json, execute from there
  if compile_directory then
    -- Change to the directory, execute command, then return
    actual_cmd = string.format("cd %s && %s", vim.fn.shellescape(compile_directory), actual_cmd)
  end

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

  -- Filter debug metadata for display if configured
  local display_lines = output_lines
  local line_map = nil
  if output_type == "llvm" and M.config.display and M.config.display.strip_debug_metadata then
    local ir_utils = require('godbolt.ir_utils')
    display_lines, line_map = ir_utils.filter_debug_metadata(output_lines)
  end

  vim.api.nvim_buf_set_lines(0, 0, -1, false, display_lines)

  -- Get output buffer number (current buffer after creating new window)
  local output_bufnr = vim.fn.bufnr("%")

  -- Store original (unfiltered) lines for line mapping
  vim.b[output_bufnr].godbolt_full_output = output_lines

  -- Store line number mapping (displayed line -> original line)
  if line_map then
    vim.b[output_bufnr].godbolt_line_map = line_map
  end

  -- Verify debug info and setup line mapping
  if M.config.line_mapping and M.config.line_mapping.enabled then
    -- First check if debug info exists in the output
    local has_debug, debug_msg = verify_debug_info(output_lines, output_type)

    if not has_debug then
      -- Debug info verification failed
      if not M.config.line_mapping.silent_on_failure then
        print("[Line Mapping] " .. debug_msg)
        if M.config.line_mapping.show_compilation_cmd then
          print("[Line Mapping] Compilation command: " .. actual_cmd)
        end
        print("[Line Mapping] Troubleshooting: Run :GodboltDebug on for more details")
      end
    else
      -- Debug info exists, attempt to setup line mapping
      local ok, line_map = pcall(require, 'godbolt.line_map')
      if ok then
        -- Schedule to run after buffer is fully initialized
        vim.schedule(function()
          line_map.setup(source_bufnr, output_bufnr, output_type, M.config.line_mapping)

          -- Add variable name annotations for LLVM IR
          if output_type == "llvm" and M.config.display and M.config.display.annotate_variables ~= false then
            local ok_debug, debug_info = pcall(require, 'godbolt.debug_info')
            if ok_debug then
              -- Use displayed lines and full output for annotation
              local displayed_lines = vim.api.nvim_buf_get_lines(output_bufnr, 0, -1, false)
              local full_lines = vim.b[output_bufnr].godbolt_full_output or displayed_lines
              debug_info.annotate_variables(output_bufnr, displayed_lines, full_lines)
            end
          end
        end)
      end
    end
  end

  -- Trigger autocommand event
  vim.cmd("doautocmd User Godbolt")

end

-- Run LLVM optimization pipeline and show passes
function M.godbolt_pipeline(args_str)
  args_str = args_str or ""
  local file = vim.fn.expand("%:p")  -- Get absolute path
  local source_bufnr = vim.fn.bufnr("%")
  local compile_directory = nil
  local cc_compiler = nil
  local cc_flags = nil

  -- Support .ll, .c, and .cpp files
  if not (file:match("%.ll$") or file:match("%.c$") or file:match("%.cpp$")) then
    print("[" .. get_timestamp() .. "] [Pipeline] Only works with LLVM IR (.ll) or C/C++ (.c, .cpp) files")
    return
  end

  -- Try to get compiler flags from compile_commands.json for C/C++ files
  if (file:match("%.c$") or file:match("%.cpp$")) and args_str == "" then
    local project = require('godbolt.project')
    local compile_commands = require('godbolt.compile_commands')

    local cc_path = project.find_compile_commands()
    if cc_path then
      local ok, cc_data = compile_commands.parse_compile_commands(cc_path)
      if ok then
        local entry = compile_commands.find_file_entry(cc_data, file)
        if entry then
          compile_directory = entry.directory

          local parsed = compile_commands.parse_entry(entry)
          if parsed then
            cc_compiler = parsed.compiler

            local relevant_flags = compile_commands.filter_relevant_flags(parsed.args)
            if #relevant_flags > 0 then
              cc_flags = table.concat(relevant_flags, " ")
              print(string.format("[" .. get_timestamp() .. "] [Pipeline] Using compiler from compile_commands.json: %s", cc_compiler))
              print(string.format("[" .. get_timestamp() .. "] [Pipeline] Using flags from compile_commands.json: %s", cc_flags))
              print(string.format("[" .. get_timestamp() .. "] [Pipeline] Working directory: %s", compile_directory))
            end
          end
        end
      end
    end
  end

  -- For C/C++ files, check for LTO flags
  if file:match("%.c$") or file:match("%.cpp$") then
    -- Parse first-line comments
    local first_line = vim.fn.getbufline(source_bufnr, 1, 1)[1] or ""
    local buffer_args = ""
    if first_line:match("^//[%s]*godbolt:") then
      buffer_args = first_line:gsub("^//[%s]*godbolt:", "")
    end

    -- Check for LTO flags in compile_commands, command line, and buffer args
    local all_args = (cc_flags or "") .. " " .. args_str .. " " .. buffer_args
    if all_args:match("-flto") or all_args:match("-flink%-time%-optimization") then
      print("[" .. get_timestamp() .. "] [Pipeline] ERROR: LTO flags detected (-flto, -flto=thin)")
      print("[" .. get_timestamp() .. "] [Pipeline] LTO defers optimization to link-time, so compilation passes are minimal")
      print("[" .. get_timestamp() .. "] [Pipeline] Remove LTO flags to see optimization passes")
      print("[" .. get_timestamp() .. "] [Pipeline] Use optimization levels instead: :GodboltPipeline O2")
      return
    end
  end

  -- Parse first-line godbolt comments for pipeline config
  local first_line = vim.fn.getbufline(source_bufnr, 1, 1)[1] or ""
  local pipeline_str = nil
  local o_level = nil

  if file:match("%.ll$") then
    -- LLVM IR files use ; comments
    -- Check for pipeline comment: ; godbolt-pipeline: mem2reg,instcombine
    if first_line:match("^;[%s]*godbolt%-pipeline:") then
      pipeline_str = first_line:gsub("^;[%s]*godbolt%-pipeline:[%s]*", "")
    end

    -- Check for O-level comment: ; godbolt-level: O2
    if first_line:match("^;[%s]*godbolt%-level:") then
      o_level = first_line:gsub("^;[%s]*godbolt%-level:[%s]*", "")
    end
  elseif file:match("%.c$") or file:match("%.cpp$") then
    -- C/C++ files use // comments
    -- Only O-levels supported (not custom pipelines)
    if first_line:match("^//[%s]*godbolt%-level:") then
      o_level = first_line:gsub("^//[%s]*godbolt%-level:[%s]*", "")
    end
  end

  -- Priority: command line > buffer comment pipeline > buffer comment O-level > default O2
  local pipeline = require('godbolt.pipeline')
  local passes_to_run = nil

  if args_str ~= "" then
    -- Normalize O-level format: accept O2, 02, -O2, etc.
    local o_match = args_str:match("^%-?O?(%d)$")
    if o_match then
      -- It's an O-level: O2, 2, -O2, etc.
      -- For .ll files, convert to pipeline string
      if file:match("%.ll$") then
        passes_to_run = pipeline.get_o_level_pipeline("O" .. o_match)
      else
        -- For C/C++ files, keep as is (will be normalized in run_clang_pipeline)
        passes_to_run = args_str
      end
    else
      -- Custom pass list (only for .ll files)
      if file:match("%.ll$") then
        passes_to_run = args_str
      else
        print("[" .. get_timestamp() .. "] [Pipeline] C/C++ files only support O-levels (O0, O1, O2, O3)")
        print("[" .. get_timestamp() .. "] [Pipeline] For custom passes, compile to .ll first:")
        print("  :Godbolt -emit-llvm -O0 -Xclang -disable-O0-optnone")
        print("  Then in the .ll file: :GodboltPipeline mem2reg,instcombine")
        return
      end
    end
  elseif pipeline_str then
    -- Custom pipeline only for .ll files
    passes_to_run = pipeline_str
  elseif o_level then
    -- Normalize O-level from comment
    local o_match = o_level:match("^%-?O?(%d)$")
    if o_match then
      if file:match("%.ll$") then
        passes_to_run = pipeline.get_o_level_pipeline("O" .. o_match)
      else
        passes_to_run = o_level
      end
    else
      passes_to_run = o_level
    end
  else
    -- Default to O2
    if file:match("%.ll$") then
      passes_to_run = pipeline.get_o_level_pipeline("O2")
    else
      passes_to_run = "O2"
    end
  end

  -- Run the pipeline ASYNCHRONOUSLY
  local pipeline_opts = {
    compiler = cc_compiler,
    flags = cc_flags,
    working_dir = compile_directory,
    remarks = M.config.pipeline.remarks,  -- Pass remarks config
  }

  pipeline.run_pipeline(file, passes_to_run, pipeline_opts, function(passes)
    if not passes then
      print("[" .. get_timestamp() .. "] [Pipeline] Failed to run pipeline (see error above)")
      return
    end

    if #passes == 0 then
      -- Check if the file has optnone attribute
      local file_content = vim.fn.readfile(file)
      local has_optnone = false
      for _, line in ipairs(file_content) do
        if line:match("optnone") then
          has_optnone = true
          break
        end
      end

      print("[" .. get_timestamp() .. "] [Pipeline] No passes captured.")

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
        print("  Then run :GodboltPipeline again")
      end
      return
    end

    local callback_time = vim.loop.hrtime()
    print(string.format("[" .. get_timestamp() .. "] [Pipeline] [CALLBACK] Captured %d passes", #passes))

    -- Setup pipeline viewer
    local ok, pipeline_viewer = pcall(require, 'godbolt.pipeline_viewer')
    if ok then
      local viewer_config = vim.tbl_deep_extend("force", M.config.pipeline, {
        line_mapping = M.config.line_mapping,
        display = M.config.display
      })

      local setup_start = vim.loop.hrtime()
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] [CALLBACK +%.3fs] Calling pipeline_viewer.setup", (setup_start - callback_time) / 1e9))

      pipeline_viewer.setup(source_bufnr, file, passes, viewer_config)

      local setup_end = vim.loop.hrtime()
      print(string.format("[" .. get_timestamp() .. "] [Pipeline] [CALLBACK +%.3fs] setup() returned", (setup_end - callback_time) / 1e9))
    else
      print("[" .. get_timestamp() .. "] [Pipeline] Failed to load pipeline viewer")
    end

    vim.cmd("doautocmd User GodboltPipeline")
  end)
end

-- LTO (Link-Time Optimization) compilation for multiple files
-- Compiles multiple source files with LTO enabled and links them
-- @param file_list: array of source file paths, space-separated string, or nil (auto-detect from compile_commands.json)
-- @param args_str: optional additional compiler/linker arguments
-- @param opts: table of options (optional)
--   - output: "llvm", "asm", or "auto" (default: "auto")
function M.godbolt_lto(file_list, args_str, opts)
  args_str = args_str or ""
  opts = opts or {}
  local output_preference = opts.output or "auto"

  -- Auto-detect files from compile_commands.json if no files provided
  if not file_list or file_list == "" or (type(file_list) == "table" and #file_list == 0) then
    local project = require('godbolt.project')
    local compile_commands = require('godbolt.compile_commands')

    local cc_path = project.find_compile_commands()
    if not cc_path then
      print("[LTO] Error: No source files provided and no compile_commands.json found")
      print("[LTO] Usage: :GodboltLTO file1.c file2.c [args]")
      print("[LTO] Or create compile_commands.json in your project root")
      return
    end

    print(string.format("[LTO] Found compile_commands.json: %s", cc_path))
    local ok, cc_data = compile_commands.parse_compile_commands(cc_path)
    if not ok then
      print(string.format("[LTO] Error parsing compile_commands.json: %s", cc_data))
      return
    end

    file_list = compile_commands.get_all_source_files(cc_data)
    print(string.format("[LTO] Auto-detected %d files from compile_commands.json", #file_list))
  end

  -- Parse file list if it's a string
  if type(file_list) == "string" then
    file_list = vim.split(file_list, "%s+")
  end

  -- Validate input
  if not file_list or #file_list == 0 then
    print("[LTO] Error: No source files provided")
    print("[LTO] Usage: :GodboltLTO file1.c file2.c [args]")
    return
  end

  if #file_list < 2 then
    print("[LTO] Warning: LTO works best with multiple files")
    print("[LTO] For single-file compilation, use :Godbolt instead")
  end

  -- Expand file paths
  local expanded_files = {}
  for _, file in ipairs(file_list) do
    local expanded = vim.fn.expand(file)
    if vim.fn.filereadable(expanded) == 1 then
      table.insert(expanded_files, expanded)
    else
      print(string.format("[LTO] Error: File not found: %s", file))
      return
    end
  end

  if #expanded_files == 0 then
    print("[LTO] Error: No valid source files found")
    return
  end

  print(string.format("[LTO] Compiling %d files with LTO...", #expanded_files))
  for i, file in ipairs(expanded_files) do
    print(string.format("  [%d] %s", i, vim.fn.fnamemodify(file, ":t")))
  end

  -- Load LTO module
  local ok, lto = pcall(require, 'godbolt.lto')
  if not ok then
    print("[LTO] Error: Failed to load LTO module")
    print("[LTO] " .. tostring(lto))
    return
  end

  -- Prepare configuration
  local lto_config = {
    compiler = nil,  -- Auto-detect from file extension
    linker = M.config.lto.linker,
    extra_args = args_str,
    keep_temps = M.config.lto.keep_temps,
  }

  -- Compile and link with LTO
  local success, ir_lines, temp_dir = lto.lto_compile_and_link(expanded_files, lto_config)

  if not success then
    print("[LTO] Compilation/linking failed:")
    print(ir_lines)  -- ir_lines contains error message
    if temp_dir then
      lto.cleanup(temp_dir)
    end
    return
  end

  -- Create new window and set up buffer
  if M.config.window_cmd then
    vim.cmd(M.config.window_cmd)
  else
    vim.cmd("vertical botright new")
  end

  vim.bo.filetype = "llvm"
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "hide"
  vim.bo.swapfile = false
  vim.wo.number = false

  -- Filter debug metadata if configured
  local display_lines = ir_lines
  local line_map = nil
  if M.config.display and M.config.display.strip_debug_metadata then
    local ir_utils = require('godbolt.ir_utils')
    display_lines, line_map = ir_utils.filter_debug_metadata(ir_lines)
  end

  -- Set buffer content
  vim.api.nvim_buf_set_lines(0, 0, -1, false, display_lines)

  -- Get output buffer number
  local output_bufnr = vim.fn.bufnr("%")

  -- Store original (unfiltered) lines for line mapping
  vim.b[output_bufnr].godbolt_full_output = ir_lines

  -- Store line number mapping (displayed line -> original line)
  if line_map then
    vim.b[output_bufnr].godbolt_line_map = line_map
  end

  -- Store source file list for future reference
  vim.b[output_bufnr].godbolt_lto_sources = expanded_files

  -- Set buffer name
  local buffer_name = string.format("LTO: %d files", #expanded_files)
  pcall(vim.api.nvim_buf_set_name, output_bufnr, buffer_name)

  -- Cleanup temporary files if configured
  if not M.config.lto.keep_temps then
    lto.cleanup(temp_dir)
  else
    print(string.format("[LTO] Temporary files kept in: %s", temp_dir))
  end

  print(string.format("[LTO] Successfully linked %d files", #expanded_files))

  -- Trigger autocommand event
  vim.cmd("doautocmd User GodboltLTO")
end

-- LTO Pipeline Viewer - Visualize LTO optimization passes for multiple files
-- @param file_list: array of source file paths, space-separated string, or nil (auto-detect from compile_commands.json)
-- @param args_str: optional arguments (opt level, extra flags)
-- @param opts: table of options (optional)
--   - output: "llvm", "asm", or "auto" (default: "auto", LTO always uses LLVM IR)
function M.godbolt_lto_pipeline(file_list, args_str, opts)
  args_str = args_str or ""
  opts = opts or {}
  -- LTO always outputs LLVM IR, but accept opts for API consistency

  -- Auto-detect files from compile_commands.json if no files provided
  if not file_list or file_list == "" or (type(file_list) == "table" and #file_list == 0) then
    local project = require('godbolt.project')
    local compile_commands = require('godbolt.compile_commands')

    local cc_path = project.find_compile_commands()
    if not cc_path then
      print("[LTO Pipeline] Error: No source files provided and no compile_commands.json found")
      print("[LTO Pipeline] Usage: :GodboltLTOPipeline file1.c file2.c [-O2]")
      print("[LTO Pipeline] Or create compile_commands.json in your project root")
      return
    end

    print(string.format("[LTO Pipeline] Found compile_commands.json: %s", cc_path))
    local ok, cc_data = compile_commands.parse_compile_commands(cc_path)
    if not ok then
      print(string.format("[LTO Pipeline] Error parsing compile_commands.json: %s", cc_data))
      return
    end

    file_list = compile_commands.get_all_source_files(cc_data)
    print(string.format("[LTO Pipeline] Auto-detected %d files from compile_commands.json", #file_list))
  end

  -- Parse file list if it's a string
  if type(file_list) == "string" then
    file_list = vim.split(file_list, "%s+")
  end

  -- Validate input
  if not file_list or #file_list == 0 then
    print("[LTO Pipeline] Error: No source files provided")
    print("[LTO Pipeline] Usage: :GodboltLTOPipeline file1.c file2.c [-O2]")
    return
  end

  if #file_list < 2 then
    print("[LTO Pipeline] Warning: LTO works best with multiple files")
  end

  -- Expand file paths
  local expanded_files = {}
  for _, file in ipairs(file_list) do
    local expanded = vim.fn.expand(file)
    if vim.fn.filereadable(expanded) == 1 then
      table.insert(expanded_files, expanded)
    else
      print(string.format("[LTO Pipeline] Error: File not found: %s", file))
      return
    end
  end

  -- Parse optimization level from args
  local opt_level = args_str:match("%-O%d") or "-O2"
  local extra_args = args_str:gsub("%-O%d", ""):gsub("^%s+", ""):gsub("%s+$", "")

  print(string.format("[LTO Pipeline] Analyzing %d files with %s...", #expanded_files, opt_level))

  -- Load LTO module
  local ok, lto = pcall(require, 'godbolt.lto')
  if not ok then
    print("[LTO Pipeline] Error: Failed to load LTO module")
    return
  end

  -- Run LTO pipeline with pass capture
  local success, pipeline_output = lto.run_lto_pipeline(expanded_files, opt_level, extra_args)

  if not success then
    print("[LTO Pipeline] Failed:")
    print(pipeline_output)
    return
  end

  -- Parse pipeline output using existing parser
  local pipeline_ok, pipeline = pcall(require, 'godbolt.pipeline')
  if not pipeline_ok then
    print("[LTO Pipeline] Error: Failed to load pipeline module")
    return
  end

  -- Parse passes from LTO output (reuse existing parser!)
  -- Use "clang" source_type to avoid stopping at ModuleID (LTO has ModuleID in every dump)
  local passes, initial_ir = pipeline.parse_pipeline_output(pipeline_output, "clang")

  -- For LTO, we MUST prepend the initial IR as pass 0 because:
  -- 1. Multiple source files (can't cache by single filename like clang pipeline does)
  -- 2. Viewer needs the merged module state to extract functions for "before" diffs
  -- 3. The initial_ir comes from -print-before-pass-number=1 and contains the merged module
  if initial_ir and #initial_ir > 0 then
    table.insert(passes, 1, {
      name = "Input (before LTO)",
      scope_type = "module",
      scope_target = "[module]",
      ir = initial_ir,
    })
    if M.config.pipeline.debug then
      print(string.format("[LTO Pipeline Debug] Prepended initial IR as pass 0 (%d lines)", #initial_ir))
    end
  end

  if not passes or #passes == 0 then
    print("[LTO Pipeline] No optimization passes captured")
    print("[LTO Pipeline] This might happen if:")
    print("  - Compilation failed")
    print("  - No optimizations were performed")
    print("  - Output format was unexpected")
    return
  end

  print(string.format("[LTO Pipeline] Captured %d pass stages", #passes))

  -- Setup pipeline viewer
  local viewer_ok, pipeline_viewer = pcall(require, 'godbolt.pipeline_viewer')
  if viewer_ok then
    -- Create a virtual "source buffer" (use first file as reference)
    local source_bufnr = vim.fn.bufnr(expanded_files[1])
    if source_bufnr == -1 then
      -- File not loaded, open it
      vim.cmd("edit " .. expanded_files[1])
      source_bufnr = vim.fn.bufnr("%")
    end

    -- Merge config
    local viewer_config = vim.tbl_deep_extend("force", M.config.pipeline, {
      line_mapping = M.config.line_mapping,
      display = M.config.display
    })

    -- Note: For LTO, we don't have a single input file
    -- Use first file as reference, but viewer won't show "before" state from input
    pipeline_viewer.setup(source_bufnr, nil, passes, viewer_config)
  else
    print("[LTO Pipeline] Failed to load pipeline viewer")
  end

  -- Trigger autocommand event
  vim.cmd("doautocmd User GodboltLTOPipeline")
end

-- LTO Comparison View - Show Before/After LTO with statistics
-- @param file_list: array of source file paths, space-separated string, or nil (auto-detect from compile_commands.json)
-- @param args_str: optional arguments (opt level, extra flags)
-- @param opts: table of options (optional)
--   - output: "llvm", "asm", or "auto" (default: "auto", LTO always uses LLVM IR)
function M.godbolt_lto_compare(file_list, args_str, opts)
  args_str = args_str or ""
  opts = opts or {}
  -- LTO always outputs LLVM IR, but accept opts for API consistency

  -- Auto-detect files from compile_commands.json if no files provided
  if not file_list or file_list == "" or (type(file_list) == "table" and #file_list == 0) then
    local project = require('godbolt.project')
    local compile_commands = require('godbolt.compile_commands')

    local cc_path = project.find_compile_commands()
    if not cc_path then
      print("[LTO Compare] Error: No source files provided and no compile_commands.json found")
      print("[LTO Compare] Usage: :GodboltLTOCompare file1.c file2.c [-O2]")
      print("[LTO Compare] Or create compile_commands.json in your project root")
      return
    end

    print(string.format("[LTO Compare] Found compile_commands.json: %s", cc_path))
    local ok, cc_data = compile_commands.parse_compile_commands(cc_path)
    if not ok then
      print(string.format("[LTO Compare] Error parsing compile_commands.json: %s", cc_data))
      return
    end

    file_list = compile_commands.get_all_source_files(cc_data)
    print(string.format("[LTO Compare] Auto-detected %d files from compile_commands.json", #file_list))
  end

  -- Parse file list if it's a string
  if type(file_list) == "string" then
    file_list = vim.split(file_list, "%s+")
  end

  -- Validate input
  if not file_list or #file_list == 0 then
    print("[LTO Compare] Error: No source files provided")
    print("[LTO Compare] Usage: :GodboltLTOCompare file1.c file2.c [-O2]")
    return
  end

  if #file_list < 2 then
    print("[LTO Compare] Warning: LTO works best with multiple files")
  end

  -- Expand file paths
  local expanded_files = {}
  for _, file in ipairs(file_list) do
    local expanded = vim.fn.expand(file)
    if vim.fn.filereadable(expanded) == 1 then
      table.insert(expanded_files, expanded)
    else
      print(string.format("[LTO Compare] Error: File not found: %s", file))
      return
    end
  end

  -- Parse optimization level from args
  local opt_level = args_str:match("%-O%d") or "-O2"
  local extra_args = args_str:gsub("%-O%d", ""):gsub("^%s+", ""):gsub("%s+$", "")

  print(string.format("[LTO Compare] Comparing %d files: Before vs After %s...", #expanded_files, opt_level))

  -- Load comparison module
  local ok, lto_comparison = pcall(require, 'godbolt.lto_comparison')
  if not ok then
    print("[LTO Compare] Error: Failed to load LTO comparison module")
    return
  end

  -- Show comparison view
  lto_comparison.show_lto_comparison(expanded_files, opt_level, extra_args)

  -- Trigger autocommand event
  vim.cmd("doautocmd User GodboltLTOCompare")
end

return M

local M = {}

-- Parse a compile_commands.json file
-- @param filepath: path to compile_commands.json
-- @return: success (boolean), data (table) or error_message (string)
function M.parse_compile_commands(filepath)
  -- Check if file exists
  if vim.fn.filereadable(filepath) ~= 1 then
    return false, string.format("File not found: %s", filepath)
  end

  -- Read file
  local content = table.concat(vim.fn.readfile(filepath), "\n")

  -- Parse JSON
  local ok, data = pcall(vim.json.decode, content)
  if not ok then
    return false, string.format("Failed to parse JSON: %s", data)
  end

  -- Validate structure
  if type(data) ~= "table" then
    return false, "compile_commands.json must be a JSON array"
  end

  return true, data
end

-- Extract compilation info for a specific file
-- @param compile_commands: parsed compile_commands.json data
-- @param target_file: file to find (can be relative or absolute)
-- @return: compilation entry or nil
function M.find_file_entry(compile_commands, target_file)
  -- Normalize target file path
  local target_normalized = vim.fn.fnamemodify(target_file, ":p")

  for _, entry in ipairs(compile_commands) do
    if not entry.file then
      goto continue
    end

    -- Normalize entry file path (make absolute using entry.directory)
    local file_path = entry.file

    -- Check if path is relative (doesn't start with /)
    if not file_path:match("^/") then
      -- Relative path, resolve from entry.directory
      file_path = vim.fn.fnamemodify(entry.directory .. "/" .. file_path, ":p")
    else
      -- Already absolute
      file_path = vim.fn.fnamemodify(file_path, ":p")
    end

    if file_path == target_normalized then
      return entry
    end

    ::continue::
  end

  return nil
end

-- Extract compiler arguments from a compile command entry
-- @param entry: single entry from compile_commands.json
-- @return: table of {compiler, args, output_file}
function M.parse_entry(entry)
  local result = {
    compiler = nil,
    args = {},
    output_file = nil,
    directory = entry.directory,
  }

  -- Method 1: Use 'arguments' array (preferred)
  if entry.arguments then
    result.compiler = entry.arguments[1]
    for i = 2, #entry.arguments do
      local arg = entry.arguments[i]

      -- Extract output file if specified
      if arg == "-o" and i < #entry.arguments then
        result.output_file = entry.arguments[i + 1]
      end

      table.insert(result.args, arg)
    end
    return result
  end

  -- Method 2: Parse 'command' string
  if entry.command then
    -- Simple shell word splitting (handles basic cases)
    local words = {}
    local current = ""
    local in_quotes = false
    local quote_char = nil

    for i = 1, #entry.command do
      local c = entry.command:sub(i, i)

      if (c == '"' or c == "'") and not in_quotes then
        in_quotes = true
        quote_char = c
      elseif c == quote_char and in_quotes then
        in_quotes = false
        quote_char = nil
      elseif c == " " and not in_quotes then
        if #current > 0 then
          table.insert(words, current)
          current = ""
        end
      else
        current = current .. c
      end
    end

    if #current > 0 then
      table.insert(words, current)
    end

    if #words > 0 then
      result.compiler = words[1]
      for i = 2, #words do
        local arg = words[i]

        -- Extract output file
        if arg == "-o" and i < #words then
          result.output_file = words[i + 1]
        end

        table.insert(result.args, arg)
      end
    end

    return result
  end

  return nil
end

-- Find all C/C++ source files in compile_commands.json
-- @param compile_commands: parsed compile_commands.json data
-- @return: array of file paths
function M.get_all_source_files(compile_commands)
  local files = {}

  for _, entry in ipairs(compile_commands) do
    if entry.file then
      -- Normalize to absolute path
      local file_path = entry.file

      -- Check if path is relative (doesn't start with /)
      if not file_path:match("^/") then
        -- Relative path - resolve from entry.directory
        file_path = vim.fn.fnamemodify(entry.directory .. "/" .. file_path, ":p")
      else
        -- Already absolute
        file_path = vim.fn.fnamemodify(file_path, ":p")
      end

      table.insert(files, file_path)
    end
  end

  return files
end

-- Extract relevant compiler flags for godbolt compilation
-- Filters out flags that don't apply to single-file compilation
-- @param args: array of compiler arguments
-- @return: filtered array of arguments
function M.filter_relevant_flags(args)
  local relevant = {}
  local skip_next = false

  for i, arg in ipairs(args) do
    if skip_next then
      skip_next = false
      goto continue
    end

    -- Skip output file specification
    if arg == "-o" then
      skip_next = true
      goto continue
    end

    -- Skip linking flags
    if arg == "-c" or arg:match("^-l") or arg:match("^-L") then
      goto continue
    end

    -- Skip input files (source files)
    if arg:match("%.c$") or arg:match("%.cpp$") or arg:match("%.cc$") or
        arg:match("%.cxx$") or arg:match("%.C$") then
      goto continue
    end

    -- Keep optimization, include paths, defines, standards, etc.
    table.insert(relevant, arg)

    ::continue::
  end

  return relevant
end

return M

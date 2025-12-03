---@class godbolt.pipeline_session
---Manages pipeline session storage and retrieval
local M = {}

local serializer = require('godbolt.pipeline_serializer')

-- Get the session directory for a source file
---@param source_file string|nil Source file path
---@return string directory Session directory path
function M.get_session_dir(source_file)
  local cwd = vim.fn.getcwd()
  local base_dir = cwd .. "/.godbolt-pipeline/sessions"

  if source_file then
    -- Create subdirectory based on source filename
    local filename = vim.fn.fnamemodify(source_file, ":t:r")  -- basename without extension
    return base_dir .. "/" .. filename
  end

  return base_dir
end

-- Get metadata file path
---@return string filepath
local function get_metadata_path()
  local cwd = vim.fn.getcwd()
  return cwd .. "/.godbolt-pipeline/metadata.json"
end

-- Load metadata index
---@return table metadata
local function load_metadata()
  local path = get_metadata_path()

  if vim.fn.filereadable(path) ~= 1 then
    -- Initialize empty metadata
    return {
      version = 1,
      sessions = {},
      auto_load_latest = false,
      cleanup_policy = {
        max_age_days = 30,
        max_sessions_per_file = 10,
      }
    }
  end

  local file = io.open(path, "r")
  if not file then
    return {}
  end

  local content = file:read("*all")
  file:close()

  local ok, data = pcall(vim.json.decode, content)
  if not ok then
    vim.notify("Failed to parse session metadata: " .. tostring(data), vim.log.levels.WARN)
    return {}
  end

  return data
end

-- Save metadata index
---@param metadata table
local function save_metadata(metadata)
  local path = get_metadata_path()

  -- Create directory if needed
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")

  local file = io.open(path, "w")
  if not file then
    vim.notify("Failed to save session metadata", vim.log.levels.ERROR)
    return
  end

  file:write(vim.json.encode(metadata))
  file:close()
end

-- Generate session filename
---@param source_file string Source file path
---@param name string|nil Optional custom name
---@param opt_level string|nil Optimization level (e.g., "O2")
---@return string filename
local function generate_session_filename(source_file, name, opt_level)
  if name then
    -- Custom name provided
    if not name:match("%.json%.gz$") then
      name = name .. ".json.gz"
    end
    return name
  end

  -- Generate timestamp-based name
  local timestamp = os.date("%Y-%m-%d-%H%M%S")
  local opt_suffix = opt_level and ("-" .. opt_level:gsub("^-", "")) or ""

  return string.format("%s%s.json.gz", timestamp, opt_suffix)
end

-- List available sessions for a source file
---@param source_file string Source file path
---@return table[] sessions Array of session info
function M.list_sessions(source_file)
  local metadata = load_metadata()
  local filename = vim.fn.fnamemodify(source_file, ":t")

  local sessions = metadata.sessions[filename] or {}

  -- Sort by timestamp (newest first)
  table.sort(sessions, function(a, b)
    return (a.timestamp or 0) > (b.timestamp or 0)
  end)

  -- Add index numbers and source_key for each session
  for i, session in ipairs(sessions) do
    session.index = i
    session.source_key = filename
  end

  return sessions
end

-- List ALL available sessions across all source files
---@return table[] sessions Array of session info with source_key field
function M.list_all_sessions()
  local metadata = load_metadata()
  local all_sessions = {}

  for source_key, sessions in pairs(metadata.sessions) do
    for _, session in ipairs(sessions) do
      session.source_key = source_key
      table.insert(all_sessions, session)
    end
  end

  -- Sort by timestamp (newest first)
  table.sort(all_sessions, function(a, b)
    return (a.timestamp or 0) > (b.timestamp or 0)
  end)

  -- Add index numbers
  for i, session in ipairs(all_sessions) do
    session.index = i
  end

  return all_sessions
end

-- Save current pipeline session
---@param passes table[] Array of passes
---@param initial_ir string[]|nil Initial IR
---@param source_file string Source file path
---@param compilation_info table|nil Compilation metadata
---@param name string|nil Optional session name
---@return string|nil filepath Saved file path
---@return string|nil error Error message if save fails
function M.save_session(passes, initial_ir, source_file, compilation_info, name)
  if not passes or #passes == 0 then
    return nil, "No passes to save"
  end

  -- Read source file for checksum
  local source_checksum = nil
  local source_mtime = nil

  if source_file and vim.fn.filereadable(source_file) == 1 then
    local file = io.open(source_file, "r")
    if file then
      local content = file:read("*all")
      file:close()
      source_checksum = vim.fn.sha256(content)
      source_mtime = vim.fn.getftime(source_file)
    end
  end

  -- Prepare metadata
  local metadata = {
    source = {
      file = vim.fn.fnamemodify(source_file, ":p"),  -- Absolute path
      checksum = source_checksum,
      mtime = source_mtime,
    },
    compilation = compilation_info or {},
  }

  -- Generate filepath
  local session_dir = M.get_session_dir(source_file)
  local filename = generate_session_filename(
    source_file,
    name,
    compilation_info and compilation_info.opt_level
  )
  local filepath = session_dir .. "/" .. filename

  -- Save to file
  local success, err = serializer.save_to_file(filepath, passes, initial_ir, metadata)
  if not success then
    return nil, err
  end

  -- Update metadata index
  local meta = load_metadata()
  local source_filename = vim.fn.fnamemodify(source_file, ":t")

  if not meta.sessions[source_filename] then
    meta.sessions[source_filename] = {}
  end

  -- Add new session entry
  table.insert(meta.sessions[source_filename], 1, {
    timestamp = os.time(),
    name = name,
    opt_level = compilation_info and compilation_info.opt_level,
    checksum = source_checksum,
    file = filepath,
    size = vim.fn.getfsize(filepath),
    passes = #passes,
    changed_passes = vim.tbl_count(vim.tbl_filter(function(p) return p.changed end, passes)),
  })

  -- Apply cleanup policy
  local sessions = meta.sessions[source_filename]
  local max_sessions = meta.cleanup_policy.max_sessions_per_file or 10

  if #sessions > max_sessions then
    -- Remove oldest sessions
    for i = max_sessions + 1, #sessions do
      local old_session = sessions[i]
      if old_session.file then
        vim.fn.delete(old_session.file)
      end
    end

    -- Trim array
    for i = #sessions, max_sessions + 1, -1 do
      table.remove(sessions, i)
    end
  end

  save_metadata(meta)

  -- Update "latest" symlink
  local latest_link = session_dir .. "/latest"
  vim.fn.delete(latest_link)
  vim.fn.system({ "ln", "-s", filename, latest_link })

  return filepath
end

-- Load pipeline session
---@param source_file string Source file path
---@param name_or_index string|number|nil Session name, index, or nil for latest
---@return table|nil result Loaded session data
---@return string|nil error Error message if load fails
function M.load_session(source_file, name_or_index)
  local sessions = M.list_sessions(source_file)

  if #sessions == 0 then
    return nil, "No saved sessions for " .. source_file
  end

  local session = nil

  if not name_or_index then
    -- Load latest (first in sorted list)
    session = sessions[1]
  elseif type(name_or_index) == "number" then
    -- Load by index
    session = sessions[name_or_index]
    if not session then
      return nil, string.format("Session index %d not found", name_or_index)
    end
  else
    -- Load by name
    for _, s in ipairs(sessions) do
      if s.name == name_or_index or
         vim.fn.fnamemodify(s.file, ":t"):match("^" .. vim.pesc(name_or_index)) then
        session = s
        break
      end
    end

    if not session then
      return nil, string.format("Session '%s' not found", name_or_index)
    end
  end

  -- Load the session file
  local result, err = serializer.load_from_file(session.file)
  if not result then
    return nil, err
  end

  -- Validate source file
  local valid, warning = serializer.validate_source(result.metadata)
  if warning then
    vim.notify(warning, vim.log.levels.WARN)
  end
  if not valid then
    return nil, warning
  end

  -- Add session info to result
  result.session_info = {
    name = session.name,
    timestamp = session.timestamp,
    opt_level = session.opt_level,
    file = session.file,
    index = session.index,
  }

  return result
end

-- Delete a session
---@param source_file string Source file path
---@param name_or_index string|number Session name or index
---@return boolean success
---@return string|nil error
function M.delete_session(source_file, name_or_index)
  local sessions = M.list_sessions(source_file)

  local session = nil
  local session_idx = nil

  if type(name_or_index) == "number" then
    session = sessions[name_or_index]
    session_idx = name_or_index
  else
    for i, s in ipairs(sessions) do
      if s.name == name_or_index or
         vim.fn.fnamemodify(s.file, ":t"):match("^" .. vim.pesc(name_or_index)) then
        session = s
        session_idx = i
        break
      end
    end
  end

  if not session then
    return false, string.format("Session '%s' not found", tostring(name_or_index))
  end

  -- Delete file
  if session.file then
    vim.fn.delete(session.file)
  end

  -- Update metadata
  local meta = load_metadata()
  local source_filename = vim.fn.fnamemodify(source_file, ":t")

  if meta.sessions[source_filename] then
    table.remove(meta.sessions[source_filename], session_idx)
    save_metadata(meta)
  end

  vim.notify(string.format("Deleted session: %s", session.name or session.file))

  return true
end

-- Clean up old sessions based on policy
---@param source_file string|nil Source file path (nil for all files)
---@return number deleted_count Number of sessions deleted
function M.cleanup_old_sessions(source_file)
  local meta = load_metadata()
  local deleted_count = 0

  local max_age_days = meta.cleanup_policy.max_age_days or 30
  local max_age_seconds = max_age_days * 24 * 60 * 60
  local cutoff_time = os.time() - max_age_seconds

  local files_to_clean = {}

  if source_file then
    local filename = vim.fn.fnamemodify(source_file, ":t")
    files_to_clean[filename] = meta.sessions[filename]
  else
    files_to_clean = meta.sessions
  end

  for filename, sessions in pairs(files_to_clean) do
    if sessions then
      local kept_sessions = {}

      for _, session in ipairs(sessions) do
        if session.timestamp and session.timestamp < cutoff_time then
          -- Delete old session
          if session.file then
            vim.fn.delete(session.file)
            deleted_count = deleted_count + 1
          end
        else
          -- Keep recent session
          table.insert(kept_sessions, session)
        end
      end

      meta.sessions[filename] = kept_sessions
    end
  end

  save_metadata(meta)

  if deleted_count > 0 then
    vim.notify(string.format("Cleaned up %d old session(s)", deleted_count))
  end

  return deleted_count
end

-- Create a session picker UI using vim.ui.select
---@param source_file string|nil Source file path (nil to show all sessions)
---@param callback function Callback function(session_or_nil)
function M.show_session_picker(source_file, callback)
  local sessions
  if source_file then
    sessions = M.list_sessions(source_file)
  else
    sessions = M.list_all_sessions()
  end

  if #sessions == 0 then
    local msg = source_file
      and ("No saved sessions for " .. source_file)
      or "No saved sessions"
    vim.notify(msg, vim.log.levels.WARN)
    callback(nil)
    return
  end

  vim.ui.select(sessions, {
    prompt = "Select pipeline session:",
    format_item = function(session)
      local timestamp_str = os.date("%Y-%m-%d %H:%M:%S", session.timestamp)
      local opt_str = session.opt_level or "??"
      local size_kb = session.size and (session.size / 1024) or 0
      local pass_str = string.format("%dp", session.passes or 0)
      local name_str = session.name or ""
      local source_str = session.source_key or ""

      return string.format("[%s] %s %s %s %.0fKB %s",
        source_str, timestamp_str, opt_str, pass_str, size_kb, name_str)
    end,
  }, function(choice)
    callback(choice)
  end)
end

return M
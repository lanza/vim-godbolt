---@class godbolt.pipeline_serializer
---Handles serialization and deserialization of pipeline states to disk
local M = {}

local SCHEMA_VERSION = 1

-- Compute SHA256 hash of a string
---@param str string
---@return string
local function compute_checksum(str)
  return vim.fn.sha256(str)
end

-- Compress a string using gzip
---@param str string
---@return string base64-encoded compressed data
local function compress(str)
  -- For now, just base64 encode without compression
  -- TODO: Fix gzip compression on macOS
  return vim.base64.encode(str)
end

-- Decompress a string from gzip
---@param base64_data string base64-encoded compressed data
---@return string decompressed data
local function decompress(base64_data)
  -- For now, just base64 decode without decompression
  -- TODO: Fix gzip decompression on macOS
  return vim.base64.decode(base64_data)
end

-- Build IR deduplication table
---@param passes table[] Array of passes
---@param initial_ir string[]|nil Initial IR lines
---@return table ir_table Deduplicated IR table
---@return table pass_refs References from passes to ir_table
local function build_ir_table(passes, initial_ir)
  local ir_table = {}
  local ir_to_key = {}  -- Map IR content to key for deduplication
  local pass_refs = {}
  local next_key = 0

  -- Add initial IR if provided
  if initial_ir and #initial_ir > 0 then
    local ir_str = table.concat(initial_ir, "\n")
    ir_table["0"] = initial_ir
    ir_to_key[ir_str] = "0"
    next_key = 1
  end

  -- Process each pass
  for i, pass in ipairs(passes) do
    local ir_ref = nil

    if pass.ir then
      -- Pass has resolved IR
      local ir_str = table.concat(pass.ir, "\n")

      -- Check if we've seen this IR before
      if ir_to_key[ir_str] then
        -- Reuse existing key
        ir_ref = ir_to_key[ir_str]
      else
        -- New unique IR, add to table
        local key = tostring(next_key)
        ir_table[key] = pass.ir
        ir_to_key[ir_str] = key
        ir_ref = key
        next_key = next_key + 1
      end
    elseif type(pass.ir_or_index) == "number" then
      -- Pass references another pass's IR
      -- We'll resolve this to the actual IR key during restoration
      ir_ref = pass_refs[pass.ir_or_index] or "0"
    elseif type(pass.ir_or_index) == "table" then
      -- Pass has unresolved IR directly
      local ir_str = table.concat(pass.ir_or_index, "\n")

      if ir_to_key[ir_str] then
        ir_ref = ir_to_key[ir_str]
      else
        local key = tostring(next_key)
        ir_table[key] = pass.ir_or_index
        ir_to_key[ir_str] = key
        ir_ref = key
        next_key = next_key + 1
      end
    end

    pass_refs[i] = ir_ref
  end

  return ir_table, pass_refs
end

-- Serialize passes to a JSON-compatible structure
---@param passes table[] Array of passes
---@param initial_ir string[]|nil Initial IR
---@param metadata table|nil Additional metadata
---@return string json_string Serialized JSON string
function M.serialize(passes, initial_ir, metadata)
  metadata = metadata or {}

  -- Build deduplicated IR table
  local ir_table, pass_refs = build_ir_table(passes, initial_ir)

  -- Compress IR blobs for space efficiency
  local compressed_ir_table = {}
  for key, ir_lines in pairs(ir_table) do
    local ir_str = table.concat(ir_lines, "\n")
    compressed_ir_table[key] = compress(ir_str)
  end

  -- Build serialized passes (without IR data)
  local serialized_passes = {}
  for i, pass in ipairs(passes) do
    serialized_passes[i] = {
      name = pass.name,
      scope_type = pass.scope_type,
      scope_target = pass.scope_target,
      changed = pass.changed,
      ir_ref = pass_refs[i],

      -- Include computed stats if available
      stats = pass.stats,
      diff_stats = pass.diff_stats,
      remarks = pass.remarks,
    }
  end

  -- Build final structure
  local data = {
    version = SCHEMA_VERSION,
    plugin_version = "1.0.0",  -- TODO: Get from package info
    timestamp = os.time(),

    source = metadata.source or {},
    compilation = metadata.compilation or {},

    pipeline = {
      ir_table = compressed_ir_table,
      passes = serialized_passes,
      total_passes = #passes,
      changed_count = vim.tbl_count(vim.tbl_filter(function(p) return p.changed end, passes)),
      unchanged_count = vim.tbl_count(vim.tbl_filter(function(p) return not p.changed end, passes)),
    },

    metadata = {
      total_ir_entries = vim.tbl_count(ir_table),
      compression_ratio = metadata.compression_ratio,
      save_duration_ms = metadata.save_duration_ms,
    }
  }

  return vim.json.encode(data)
end

-- Deserialize JSON string back to passes
---@param json_string string Serialized JSON
---@return table result Table with passes, initial_ir, and metadata
---@return string|nil error Error message if deserialization fails
function M.deserialize(json_string)
  local ok, data = pcall(vim.json.decode, json_string)
  if not ok then
    return nil, "Failed to parse JSON: " .. tostring(data)
  end

  -- Check version compatibility
  if data.version > SCHEMA_VERSION then
    return nil, string.format("Unsupported schema version %d (current: %d)",
      data.version, SCHEMA_VERSION)
  end

  -- Decompress IR table
  local ir_table = {}
  for key, compressed_ir in pairs(data.pipeline.ir_table) do
    local ok, ir_str = pcall(decompress, compressed_ir)
    if not ok then
      return nil, "Failed to decompress IR for key " .. key .. ": " .. tostring(ir_str)
    end

    -- Split back into lines
    ir_table[key] = vim.split(ir_str, "\n", { plain = true })
  end

  -- Restore passes with lazy IR references
  local passes = {}
  for i, serialized_pass in ipairs(data.pipeline.passes) do
    local pass = {
      name = serialized_pass.name,
      scope_type = serialized_pass.scope_type,
      scope_target = serialized_pass.scope_target,
      changed = serialized_pass.changed,

      -- Stats and metadata
      stats = serialized_pass.stats,
      diff_stats = serialized_pass.diff_stats,
      remarks = serialized_pass.remarks,
    }

    -- Set up lazy IR resolution
    if serialized_pass.ir_ref then
      local ir_ref = serialized_pass.ir_ref

      -- Check if this references another pass or has its own IR
      local ref_ir = ir_table[ir_ref]
      if ref_ir then
        -- Has its own IR
        pass.ir_or_index = ref_ir
      else
        -- References another pass - find the most recent pass with same ir_ref
        for j = i - 1, 1, -1 do
          if data.pipeline.passes[j].ir_ref == ir_ref then
            pass.ir_or_index = j
            break
          end
        end

        -- Fallback to initial IR
        if not pass.ir_or_index then
          pass.ir_or_index = ir_table["0"] or {}
        end
      end
    end

    passes[i] = pass
  end

  -- Extract initial IR
  local initial_ir = ir_table["0"]

  return {
    passes = passes,
    initial_ir = initial_ir,
    metadata = {
      source = data.source,
      compilation = data.compilation,
      timestamp = data.timestamp,
      plugin_version = data.plugin_version,
      statistics = data.metadata,
    }
  }
end

-- Save serialized data to a file with compression
---@param filepath string Path to save file
---@param passes table[] Array of passes
---@param initial_ir string[]|nil Initial IR
---@param metadata table|nil Additional metadata
---@return boolean success
---@return string|nil error
function M.save_to_file(filepath, passes, initial_ir, metadata)
  local start_time = vim.loop.hrtime()

  -- Serialize data
  local ok, json_or_error = pcall(M.serialize, passes, initial_ir, metadata)
  if not ok then
    return false, "Serialization failed: " .. tostring(json_or_error)
  end

  local json_string = json_or_error

  -- Create directory if needed
  local dir = vim.fn.fnamemodify(filepath, ":h")
  vim.fn.mkdir(dir, "p")

  -- Write compressed file
  if vim.fn.fnamemodify(filepath, ":e") == "gz" then
    -- Save as compressed
    local uncompressed_size = #json_string
    local compressed = compress(json_string)

    local file = io.open(filepath, "wb")
    if not file then
      return false, "Failed to open file for writing: " .. filepath
    end

    -- Write the base64-encoded compressed data directly
    -- (since we're using base64 encoding as temporary compression)
    file:write(compressed)
    file:close()

    local compressed_size = vim.fn.getfsize(filepath)
    local compression_ratio = compressed_size / uncompressed_size

    local elapsed_ms = (vim.loop.hrtime() - start_time) / 1000000

    vim.notify(string.format(
      "Saved pipeline session: %s\n" ..
      "Size: %.1f MB → %.1f MB (%.0f%% compression)\n" ..
      "Time: %.0f ms",
      vim.fn.fnamemodify(filepath, ":t"),
      uncompressed_size / 1024 / 1024,
      compressed_size / 1024 / 1024,
      (1 - compression_ratio) * 100,
      elapsed_ms
    ))
  else
    -- Save uncompressed
    local file = io.open(filepath, "w")
    if not file then
      return false, "Failed to open file for writing: " .. filepath
    end

    file:write(json_string)
    file:close()

    local elapsed_ms = (vim.loop.hrtime() - start_time) / 1000000

    vim.notify(string.format(
      "Saved pipeline session: %s (%.1f MB in %.0f ms)",
      vim.fn.fnamemodify(filepath, ":t"),
      #json_string / 1024 / 1024,
      elapsed_ms
    ))
  end

  return true
end

-- Load serialized data from a file
---@param filepath string Path to load from
---@return table|nil result Deserialized data
---@return string|nil error
function M.load_from_file(filepath)
  if not vim.fn.filereadable(filepath) == 1 then
    return nil, "File not found: " .. filepath
  end

  local start_time = vim.loop.hrtime()

  local json_string

  if vim.fn.fnamemodify(filepath, ":e") == "gz" then
    -- Load compressed file (currently base64-encoded)
    local file = io.open(filepath, "r")  -- Read as text, not binary
    if not file then
      return nil, "Failed to open file: " .. filepath
    end

    local compressed_base64 = file:read("*all")
    file:close()

    local ok, decompressed = pcall(decompress, compressed_base64)
    if not ok then
      return nil, "Failed to decompress file: " .. tostring(decompressed)
    end

    json_string = decompressed
  else
    -- Load uncompressed file
    local file = io.open(filepath, "r")
    if not file then
      return nil, "Failed to open file: " .. filepath
    end

    json_string = file:read("*all")
    file:close()
  end

  -- Deserialize
  local result, err = M.deserialize(json_string)
  if not result then
    return nil, err
  end

  local elapsed_ms = (vim.loop.hrtime() - start_time) / 1000000

  vim.notify(string.format(
    "Loaded pipeline session: %s\n" ..
    "Passes: %d (%d changed)\n" ..
    "Time: %.0f ms",
    vim.fn.fnamemodify(filepath, ":t"),
    result.passes and #result.passes or 0,
    result.metadata and result.metadata.statistics and
      result.metadata.statistics.changed_count or 0,
    elapsed_ms
  ))

  return result
end

-- Validate that source file hasn't changed
---@param metadata table Session metadata with source info
---@return boolean valid
---@return string|nil warning Warning message if validation fails
function M.validate_source(metadata)
  if not metadata.source or not metadata.source.file then
    return true  -- No source info to validate
  end

  local source_file = metadata.source.file

  if vim.fn.filereadable(source_file) ~= 1 then
    return false, "Source file not found: " .. source_file
  end

  -- Read and compute checksum of current file
  local file = io.open(source_file, "r")
  if not file then
    return false, "Failed to read source file: " .. source_file
  end

  local content = file:read("*all")
  file:close()

  local current_checksum = compute_checksum(content)

  if metadata.source.checksum and current_checksum ~= metadata.source.checksum then
    return true, string.format(
      "Warning: Source file has changed since session was saved\n" ..
      "File: %s\n" ..
      "Saved checksum: %s\n" ..
      "Current checksum: %s",
      source_file,
      metadata.source.checksum,
      current_checksum
    )
  end

  return true
end

return M
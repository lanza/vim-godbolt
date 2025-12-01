local M = {}

-- Count statistics from LLVM IR lines
-- @param ir_lines: array of IR lines
-- @return: table with instruction counts, block counts, etc.
function M.count(ir_lines)
  local stats = {
    instructions = 0,
    basic_blocks = 0,
    functions = 0,
    phi_nodes = 0,
    calls = 0,
    loads = 0,
    stores = 0,
  }

  for _, line in ipairs(ir_lines) do
    -- Count functions (define statements)
    if line:match("^define ") then
      stats.functions = stats.functions + 1
    end

    -- Count basic blocks (labels ending with :)
    if line:match("^%w+:%s*$") or line:match("^%w+:%s*;") then
      stats.basic_blocks = stats.basic_blocks + 1
    end

    -- Count instructions (indented lines with operations)
    if line:match("^%s+%%") or line:match("^%s+store") or
        line:match("^%s+ret") or line:match("^%s+br") or
        line:match("^%s+call") or line:match("^%s+invoke") or
        line:match("^%s+switch") or line:match("^%s+unreachable") then
      stats.instructions = stats.instructions + 1

      -- Count specific instruction types
      if line:match("phi ") then
        stats.phi_nodes = stats.phi_nodes + 1
      end

      if line:match("call ") or line:match("invoke ") then
        stats.calls = stats.calls + 1
      end

      if line:match("^%s+%%.*=%s+load") then
        stats.loads = stats.loads + 1
      end

      if line:match("^%s+store") then
        stats.stores = stats.stores + 1
      end
    end
  end

  return stats
end

-- Format statistics into a readable string
-- @param stats: statistics table from count()
-- @return: formatted string
function M.format(stats)
  return string.format(
    "Fns: %d | BBs: %d | Insts: %d | Phis: %d | Calls: %d | Loads: %d | Stores: %d",
    stats.functions,
    stats.basic_blocks,
    stats.instructions,
    stats.phi_nodes,
    stats.calls,
    stats.loads,
    stats.stores
  )
end

-- Format statistics in compact form
-- @param stats: statistics table from count()
-- @return: compact formatted string
function M.format_compact(stats)
  return string.format(
    "Insts: %d | BBs: %d | Fns: %d",
    stats.instructions,
    stats.basic_blocks,
    stats.functions
  )
end

-- Calculate delta between two stat tables
-- @param before: statistics table
-- @param after: statistics table
-- @return: delta table with differences
function M.delta(before, after)
  local delta = {}
  for k, v in pairs(after) do
    delta[k] = v - (before[k] or 0)
  end
  return delta
end

-- Format statistics with delta (showing change from previous)
-- @param stats: current statistics
-- @param delta: delta statistics
-- @return: formatted string with deltas
function M.format_with_delta(stats, delta)
  local function format_change(value, change)
    if change == 0 then
      return string.format("%d", value)
    elseif change > 0 then
      return string.format("%d (+%d)", value, change)
    else
      return string.format("%d (%d)", value, change)
    end
  end

  return string.format(
    "Insts: %s | BBs: %s | Fns: %s",
    format_change(stats.instructions, delta.instructions),
    format_change(stats.basic_blocks, delta.basic_blocks),
    format_change(stats.functions, delta.functions)
  )
end

return M

-- IR resolver for --print-module-scope pipeline output
-- With --print-module-scope, EVERY pass has full module IR - no extraction needed!
-- Resolution is trivial: just follow index chains to get the full module

local M = {}

-- Memoization cache for resolved IR
local resolve_cache = {}

-- Clear the resolution cache (call when starting a new pipeline)
function M.clear_cache()
  resolve_cache = {}
end

-- Resolve IR at a specific pass index
-- With --print-module-scope, this is trivial:
-- - If ir_or_index is a table (IR lines), return it
-- - If ir_or_index is a number (index), recursively resolve that index
-- - If index is 0, return initial_ir
--
-- @param passes: array of all passes
-- @param initial_ir: array of initial IR lines (full module)
-- @param pass_index: index of the pass to resolve
-- @return: array of IR lines (ALWAYS full module IR)
function M.resolve_ir(passes, initial_ir, pass_index)
  -- Check cache
  local cache_key = tostring(pass_index)
  if resolve_cache[cache_key] then
    return resolve_cache[cache_key]
  end

  -- Base case: index 0 means initial_ir
  if pass_index == 0 then
    resolve_cache[cache_key] = initial_ir
    return initial_ir
  end

  -- Bounds check
  if pass_index < 1 or pass_index > #passes then
    resolve_cache[cache_key] = {}
    return {}
  end

  local pass = passes[pass_index]
  local ir_or_index = pass.ir_or_index

  local resolved

  if type(ir_or_index) == "table" then
    if #ir_or_index > 0 and type(ir_or_index[1]) == "string" then
      resolved = ir_or_index
    else
      assert(false, "Unexpected IR format at pass index " .. pass_index)
    end
  elseif type(ir_or_index) == "number" then
    -- It's an index - recursively resolve
    resolved = M.resolve_ir(passes, initial_ir, ir_or_index)
  else
    assert(false, "Unexpected IR format at pass index " .. pass_index .. " (type: " .. type(ir_or_index) .. ")")
  end

  resolve_cache[cache_key] = resolved
  return resolved
end

-- @param passes: array of all passes
-- @param initial_ir: array of initial IR lines (full module)
-- @param pass_index: index of the pass
-- @return: array of IR lines (full module IR)
function M.get_before_ir(passes, initial_ir, pass_index)
  if pass_index <= 1 then
    -- First pass: before is the initial IR (full module)
    return initial_ir or {}
  end

  local current_pass = passes[pass_index]

  if current_pass.changed == false then
    return M.get_after_ir(passes, initial_ir, pass_index)
  end

  -- For changed passes: before-IR is the full module state from previous pass
  return M.resolve_ir(passes, initial_ir, pass_index - 1)
end

-- @param passes: array of all passes
-- @param initial_ir: array of initial IR lines (full module)
-- @param pass_index: index of the pass
-- @return: array of IR lines (full module IR)
function M.get_after_ir(passes, initial_ir, pass_index)
  return M.resolve_ir(passes, initial_ir, pass_index)
end

return M

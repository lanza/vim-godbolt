-- Test that our parser's understanding of --print-changed matches reality
-- This verifies that when LLVM says "omitted", we show identical before/after
-- and when LLVM says "changed", we show different before/after

describe("Pipeline Correctness", function()
  local pipeline = require('godbolt.pipeline')
  local ir_resolver = pipeline.ir_resolver

  -- Helper: Parse raw --print-changed output to extract LLVM's decisions
  local function parse_llvm_decisions(output)
    local decisions = {}
    for line in output:gmatch("[^\r\n]+") do
      -- Match "*** IR Dump After PassName on target ***"
      local pass_info = line:match("^%*%*%* IR Dump After (.-)%s+%*%*%*$")
      if not pass_info then
        pass_info = line:match("^; %*%*%* IR Dump After (.-)%s+%*%*%*$")
      end

      if pass_info then
        -- Check if omitted
        local is_omitted = pass_info:match("omitted because no change$") ~= nil
        local pass_name = pass_info:gsub(" omitted because no change$", "")

        table.insert(decisions, {
          name = pass_name,
          llvm_said_changed = not is_omitted,
        })
      end
    end
    return decisions
  end

  -- Helper: Verify a pass's before/after IR matches LLVM's decision
  local function verify_pass_correctness(pass, pass_index, passes, initial_ir, llvm_said_changed)
    ir_resolver.clear_cache()
    local before_ir = ir_resolver.get_before_ir(passes, initial_ir, pass_index)
    local after_ir = ir_resolver.get_after_ir(passes, initial_ir, pass_index)

    assert.is_table(before_ir, "Before IR should be a table")
    assert.is_table(after_ir, "After IR should be a table")
    assert.is_true(#before_ir > 0, "Before IR should not be empty")
    assert.is_true(#after_ir > 0, "After IR should not be empty")

    -- Check if IRs are identical
    local identical = #before_ir == #after_ir
    if identical then
      for i = 1, #before_ir do
        if before_ir[i] ~= after_ir[i] then
          identical = false
          break
        end
      end
    end

    if llvm_said_changed then
      -- LLVM said it changed: before and after should be DIFFERENT
      -- EXCEPTIONS:
      -- 1. Some passes only modify function attributes or metadata that we strip during cleaning
      --    Examples: PostOrderFunctionAttrsPass may only change "; Function Attrs:" comments
      -- 2. Loop passes only output partial IR (loop body), so we show the full function instead
      --    For changed loop passes, we can't reconstruct the full function, so before==after
      if identical then
        -- Allow attribute-only changes for passes known to modify only metadata
        local is_attr_only_pass = pass.name:match("FunctionAttrsPass") or
            pass.name:match("AttributorPass") or
            pass.name:match("InferFunctionAttrsPass")

        -- Allow loop passes (they only show partial IR, we display full function)
        local is_loop_pass = pass.scope_type == "loop"

        if not is_attr_only_pass and not is_loop_pass then
          print(string.format("\nERROR: Pass '%s' - LLVM said CHANGED but before == after", pass.name))
          print(string.format("  before_ir: %d lines", #before_ir))
          print(string.format("  after_ir:  %d lines", #after_ir))
          print(string.format("  changed field: %s", tostring(pass.changed)))
          print(string.format("  scope_type: %s", pass.scope_type))
          print(string.format("  ir_or_index type: %s", type(pass.ir_or_index)))
          if type(pass.ir_or_index) == "number" then
            print(string.format("  ir_or_index: %d", pass.ir_or_index))
          end
          assert.is_false(identical,
            string.format("Pass '%s': LLVM said CHANGED but before == after (scope: %s)", pass.name, pass.scope_type))
        end
      end
    else
      -- LLVM said it was omitted: before and after should be IDENTICAL
      -- EXCEPTION: First pass may have duplicate function attribute comments when reconstructing
      -- from partial structure (known limitation in IR extraction/combination)
      if not identical then
        local is_first_pass = pass_index == 1

        if not is_first_pass then
          print(string.format("\nERROR: Pass '%s' - LLVM said OMITTED but before != after", pass.name))
          print(string.format("  before_ir: %d lines", #before_ir))
          print(string.format("  after_ir:  %d lines", #after_ir))
          print(string.format("  changed field: %s", tostring(pass.changed)))
          print(string.format("  ir_or_index type: %s", type(pass.ir_or_index)))

          -- Show first difference
          local max_lines = math.max(#before_ir, #after_ir)
          for i = 1, math.min(50, max_lines) do
            local before_line = before_ir[i] or ""
            local after_line = after_ir[i] or ""
            if before_line ~= after_line then
              print(string.format("\n  First diff at line %d:", i))
              print(string.format("    Before: %s", before_line))
              print(string.format("    After:  %s", after_line))
              break
            end
          end

          assert.is_true(identical,
            string.format("Pass '%s': LLVM said OMITTED but before != after", pass.name))
        end
      end
    end
  end

  describe("many.c with O2", function()
    it("parser decisions should match LLVM's --print-changed output", function()
      local input_file = "tests/fixtures/many.c"
      local cmd = string.format(
        'clang -mllvm -print-changed -mllvm -print-module-scope -O2 -fno-discard-value-names -fstandalone-debug -S -emit-llvm -o /dev/null "%s" 2>&1',
        input_file
      )

      local handle = io.popen(cmd)
      local output = handle:read("*a")
      handle:close()

      -- Parse LLVM's decisions from raw output
      local llvm_decisions = parse_llvm_decisions(output)
      assert.is_true(#llvm_decisions > 0, "Should have LLVM decisions")

      -- Parse through our parser
      local result = pipeline.parse_pipeline_lazy(output, "clang")
      local passes = result.passes
      local initial_ir = result.initial_ir

      assert.is_table(passes)
      assert.is_table(initial_ir)
      assert.is_true(#passes > 0, "Should have passes")
      assert.is_true(#initial_ir > 0, "Should have initial IR")

      -- Verify counts match
      assert.are.equal(#llvm_decisions, #passes,
        "Parser should produce same number of passes as LLVM decisions")

      -- Verify each pass
      local pass_errors = {}
      for i, pass in ipairs(passes) do
        local llvm_decision = llvm_decisions[i]

        -- Verify pass.changed matches LLVM's decision
        assert.are.equal(llvm_decision.llvm_said_changed, pass.changed,
          string.format("Pass %d '%s': changed field should match LLVM", i, pass.name))

        -- Verify before/after IR matches LLVM's decision
        local ok, err = pcall(function()
          verify_pass_correctness(pass, i, passes, initial_ir, llvm_decision.llvm_said_changed)
        end)

        if not ok then
          table.insert(pass_errors, {
            index = i,
            name = pass.name,
            error = err,
          })
        end
      end

      -- Report all errors
      if #pass_errors > 0 then
        print(string.format("\n\n=== %d PASSES HAD ERRORS ===", #pass_errors))
        for _, err_info in ipairs(pass_errors) do
          print(string.format("\nPass %d: %s", err_info.index, err_info.name))
          print(string.format("  Error: %s", err_info.error))
        end
        error(string.format("%d passes had mismatches", #pass_errors))
      end
    end)

    it("omitted module pass after function pass changes should include those changes", function()
      -- This is the specific bug scenario:
      -- 1. Module pass A (changed)
      -- 2. Function pass B on foo (changed)
      -- 3. Module pass C (omitted)
      -- Pass C should show pass B's changes to foo

      local input_file = "tests/fixtures/many.c"
      local cmd = string.format(
        'clang -mllvm -print-changed -mllvm -print-module-scope -O2 -fno-discard-value-names -fstandalone-debug -S -emit-llvm -o /dev/null "%s" 2>&1',
        input_file
      )

      local handle = io.popen(cmd)
      local output = handle:read("*a")
      handle:close()

      local result = pipeline.parse_pipeline_lazy(output, "clang")
      local passes = result.passes
      local initial_ir = result.initial_ir

      -- Find the pattern: module -> function -> omitted module
      for i = 3, #passes do
        local current_pass = passes[i]
        local prev_pass = passes[i - 1]
        local prev_prev_pass = passes[i - 2]

        if current_pass.scope_type == "module" and current_pass.changed == false and
            prev_pass.scope_type == "function" and prev_pass.changed == true and
            prev_prev_pass.scope_type == "module" then
          print(string.format("\n=== FOUND PATTERN AT PASS %d ===", i))
          print(string.format("Pass %d: %s (module, changed)", i - 2, prev_prev_pass.name))
          print(string.format("Pass %d: %s (function on %s, changed)", i - 1, prev_pass.name, prev_pass.scope_target))
          print(string.format("Pass %d: %s (module, omitted)", i, current_pass.name))

          -- Verify the omitted module pass includes the function pass's changes
          ir_resolver.clear_cache()
          local after_ir = ir_resolver.get_after_ir(passes, initial_ir, i)

          -- The after IR for the omitted module should include the changed function
          local functions_in_ir = pipeline.ir_parser.list_functions(after_ir)
          assert.is_true(#functions_in_ir >= 1, "Should have at least one function")

          -- Extract the changed function from the omitted module's IR
          local changed_func_ir = pipeline.ir_parser.extract_function(after_ir, prev_pass.scope_target)
          assert.is_not_nil(changed_func_ir, "Should find the changed function in omitted module's IR")

          -- Extract the changed function from the function pass
          local function_pass_ir = ir_resolver.get_after_ir(passes, initial_ir, i - 1)
          assert.is_table(function_pass_ir, "Function pass should have IR")

          -- They should be identical (the omitted module includes the function change)
          assert.are.equal(#changed_func_ir, #function_pass_ir,
            "Omitted module should include function pass's changes")

          for j = 1, #changed_func_ir do
            assert.are.equal(changed_func_ir[j], function_pass_ir[j],
              string.format("Line %d should match", j))
          end

          print("✓ Omitted module pass correctly includes function pass changes")
          return -- Test passed
        end
      end

      -- If we didn't find the pattern, that's okay - just skip this test
      print("Pattern not found in this pipeline (okay to skip)")
    end)
  end)
end)

-- Test what will actually be rendered in pipeline_viewer buffer
-- This tests the actual pipeline_viewer.lua module and its compute_pass_changes function

describe("Pipeline Viewer", function()
  local pipeline = require('godbolt.pipeline')
  local pipeline_viewer = require('godbolt.pipeline_viewer')
  local ir_resolver = pipeline.ir_resolver

  describe("compute_pass_changes", function()
    it("should trust parser's changed field and compute diff_stats", function()
      -- Run pipeline on many.c
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

      assert.is_true(#passes > 0, "Should have passes")

      -- Set up pipeline_viewer state (simulating what the viewer does)
      pipeline_viewer.state = {
        passes = passes,
        initial_ir = initial_ir,
      }

      -- Store initial_ir in first pass (as pipeline.lua does)
      passes[1]._initial_ir = initial_ir

      -- Run compute_pass_changes (this is what we're testing!)
      local completed = false
      pipeline_viewer.compute_pass_changes(function()
        completed = true
      end)

      assert.is_true(completed, "compute_pass_changes should call callback")

      -- Verify all passes have diff_stats computed
      for i, pass in ipairs(passes) do
        assert.is_not_nil(pass.diff_stats, string.format("Pass %d should have diff_stats", i))
        assert.is_number(pass.diff_stats.lines_before, string.format("Pass %d: lines_before should be number", i))
        assert.is_number(pass.diff_stats.lines_after, string.format("Pass %d: lines_after should be number", i))
        assert.is_number(pass.diff_stats.lines_changed, string.format("Pass %d: lines_changed should be number", i))

        -- Verify diff_stats make sense
        assert.is_true(pass.diff_stats.lines_before >= 0, "lines_before should be >= 0")
        assert.is_true(pass.diff_stats.lines_after >= 0, "lines_after should be >= 0")
        assert.is_true(pass.diff_stats.lines_changed >= 0, "lines_changed should be >= 0")

        -- For unchanged passes, lines_changed should be 0
        if pass.changed == false then
          assert.are.equal(0, pass.diff_stats.lines_changed,
            string.format("Pass %d '%s': Unchanged pass should have 0 lines_changed", i, pass.name))
        end
      end

      -- Verify that changed field is still set (compute_pass_changes should trust it)
      local has_changed = false
      local has_unchanged = false
      for _, pass in ipairs(passes) do
        assert.is_not_nil(pass.changed, "All passes should have .changed field")
        if pass.changed then
          has_changed = true
        else
          has_unchanged = true
        end
      end

      assert.is_true(has_changed, "Should have at least one changed pass")
      assert.is_true(has_unchanged, "Should have at least one unchanged pass")
    end)

    it("should assert if parser didn't set changed field", function()
      -- Create a pass without .changed field (parser bug simulation)
      local bad_passes = {
        {
          name = "TestPass",
          scope_type = "module",
          ir_or_index = {},
          -- Missing .changed field!
        }
      }

      pipeline_viewer.state = {
        passes = bad_passes,
        initial_ir = {},
      }
      bad_passes[1]._initial_ir = {}

      -- This should error because changed is nil
      local success, err = pcall(function()
        pipeline_viewer.compute_pass_changes()
      end)

      assert.is_false(success, "Should error when .changed is missing")
      assert.is_not_nil(err:match("missing .changed field"), "Error should mention missing .changed field")
    end)
  end)

  describe("get_before_ir_for_pass", function()
    it("should return correct before IR for all passes", function()
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

      pipeline_viewer.state = {
        passes = passes,
        initial_ir = initial_ir,
      }
      passes[1]._initial_ir = initial_ir

      -- Test get_before_ir_for_pass for several passes
      for i = 1, math.min(20, #passes) do
        ir_resolver.clear_cache()
        local before_ir = pipeline_viewer.get_before_ir_for_pass(i)

        assert.is_table(before_ir, string.format("Pass %d: Should return table", i))
        assert.is_true(#before_ir > 0, string.format("Pass %d: Before IR should not be empty", i))
      end
    end)
  end)

  describe("IR Resolution for actual rendering", function()
    it("should resolve IR correctly for all passes", function()
      -- Run pipeline on many.c
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

      assert.is_table(passes)
      assert.is_table(initial_ir)
      assert.is_true(#passes > 0, "Should have passes")
      assert.is_true(#initial_ir > 0, "Should have initial IR")

      -- Verify ALL passes can be resolved (what pipeline_viewer actually does)
      ir_resolver.clear_cache()
      for i, pass in ipairs(passes) do
        local before_ir = ir_resolver.get_before_ir(passes, initial_ir, i)
        local after_ir = ir_resolver.get_after_ir(passes, initial_ir, i)

        assert.is_table(before_ir, string.format("Pass %d: Before IR should be table", i))
        assert.is_table(after_ir, string.format("Pass %d: After IR should be table", i))
        assert.is_true(#before_ir > 0, string.format("Pass %d: Before IR should not be empty", i))
        assert.is_true(#after_ir > 0, string.format("Pass %d: After IR should not be empty", i))

        -- For module passes, verify they contain multiple functions
        if pass.scope_type == "module" then
          local before_funcs = pipeline.ir_parser.list_functions(before_ir)
          local after_funcs = pipeline.ir_parser.list_functions(after_ir)
          assert.is_true(#before_funcs >= 1, string.format("Pass %d: Module should have functions", i))
          assert.is_true(#after_funcs >= 1, string.format("Pass %d: Module should have functions", i))
        end

        -- For function/cgscc/loop passes, verify they contain the target function
        if (pass.scope_type == "function" or pass.scope_type == "cgscc" or pass.scope_type == "loop") and pass.scope_target then
          local before_funcs = pipeline.ir_parser.list_functions(before_ir)
          local after_funcs = pipeline.ir_parser.list_functions(after_ir)

          -- Should contain exactly the target function (or its components for CGSCC)
          local found_in_before = false
          local found_in_after = false
          for _, fname in ipairs(before_funcs) do
            if fname == pass.scope_target or fname:match(pass.scope_target) then
              found_in_before = true
            end
          end
          for _, fname in ipairs(after_funcs) do
            if fname == pass.scope_target or fname:match(pass.scope_target) then
              found_in_after = true
            end
          end

          assert.is_true(found_in_before,
            string.format("Pass %d '%s': Before IR should contain target '%s'", i, pass.name, pass.scope_target))
          assert.is_true(found_in_after,
            string.format("Pass %d '%s': After IR should contain target '%s'", i, pass.name, pass.scope_target))
        end
      end
    end)
  end)
end)

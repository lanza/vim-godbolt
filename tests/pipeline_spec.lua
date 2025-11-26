---@diagnostic disable: undefined-global
local pipeline = require('godbolt.pipeline')

describe("pipeline parser", function()
  describe("single function tests", function()
    it("parses single function with one pass", function()
      local test_file = vim.fn.fnamemodify("tests/fixtures/single_func.ll", ":p")
      local passes = pipeline.run_pipeline(test_file, "sroa")

      -- Should have: Input + sroa on simple
      assert.is_not_nil(passes)
      assert.are.equal(2, #passes, "Expected 2 stages: Input, sroa")

      assert.are.equal("Input", passes[1].name)
      assert.are.equal("SROAPass on simple", passes[2].name)

      -- Each pass should only contain the simple function
      for _, pass in ipairs(passes) do
        local ir_text = table.concat(pass.ir, "\n")
        assert.is_not_nil(ir_text:match("define i32 @simple"), "Pass should contain @simple function")
      end
    end)

    it("parses single function with multiple passes", function()
      local test_file = vim.fn.fnamemodify("tests/fixtures/single_func.ll", ":p")
      local passes = pipeline.run_pipeline(test_file, "sroa,instcombine")

      -- Should have: Input + sroa + instcombine
      assert.is_not_nil(passes)
      assert.are.equal(3, #passes, "Expected 3 stages")

      assert.are.equal("Input", passes[1].name)
      assert.are.equal("SROAPass on simple", passes[2].name)
      assert.are.equal("InstCombinePass on simple", passes[3].name)
    end)
  end)

  describe("two function tests", function()
    it("parses two functions with function passes - THE KEY TEST", function()
      local test_file = vim.fn.fnamemodify("tests/fixtures/two_funcs.ll", ":p")
      local passes = pipeline.run_pipeline(test_file, "sroa,instcombine")

      -- Should have: Input + (sroa-foo, instcombine-foo, sroa-bar, instcombine-bar)
      assert.is_not_nil(passes)
      assert.are.equal(5, #passes, "Expected 5 stages: Input + 2 funcs * 2 passes")

      assert.are.equal("Input", passes[1].name)
      assert.are.equal("SROAPass on foo", passes[2].name)
      assert.are.equal("InstCombinePass on foo", passes[3].name)
      assert.are.equal("SROAPass on bar", passes[4].name)
      assert.are.equal("InstCombinePass on bar", passes[5].name)

      -- Each function pass should ONLY show one function
      local sroa_foo_text = table.concat(passes[2].ir, "\n")
      assert.is_not_nil(sroa_foo_text:match("define i32 @foo"), "SROAPass on foo should contain @foo")
      assert.is_nil(sroa_foo_text:match("define i32 @bar"), "SROAPass on foo should NOT contain @bar")

      local instcombine_foo_text = table.concat(passes[3].ir, "\n")
      assert.is_not_nil(instcombine_foo_text:match("define i32 @foo"), "InstCombinePass on foo should contain @foo")
      assert.is_nil(instcombine_foo_text:match("define i32 @bar"), "InstCombinePass on foo should NOT contain @bar")

      local sroa_bar_text = table.concat(passes[4].ir, "\n")
      assert.is_not_nil(sroa_bar_text:match("define i32 @bar"), "SROAPass on bar should contain @bar")
      assert.is_nil(sroa_bar_text:match("define i32 @foo"), "SROAPass on bar should NOT contain @foo")

      local instcombine_bar_text = table.concat(passes[5].ir, "\n")
      assert.is_not_nil(instcombine_bar_text:match("define i32 @bar"), "InstCombinePass on bar should contain @bar")
      assert.is_nil(instcombine_bar_text:match("define i32 @foo"), "InstCombinePass on bar should NOT contain @foo")
    end)

    it("Input stage contains both functions", function()
      local test_file = vim.fn.fnamemodify("tests/fixtures/two_funcs.ll", ":p")
      local passes = pipeline.run_pipeline(test_file, "sroa")

      assert.is_not_nil(passes)
      local input_text = table.concat(passes[1].ir, "\n")

      -- Input should have both functions
      assert.is_not_nil(input_text:match("define i32 @foo"), "Input should contain @foo")
      assert.is_not_nil(input_text:match("define i32 @bar"), "Input should contain @bar")
    end)
  end)

  describe("parser edge cases", function()
    it("handles passes that don't modify IR", function()
      local test_file = vim.fn.fnamemodify("tests/fixtures/single_func.ll", ":p")
      -- Run a pass that won't change already-optimized code
      local passes = pipeline.run_pipeline(test_file, "sroa,sroa")

      assert.is_not_nil(passes)
      -- Should still have all stages even if IR doesn't change
      assert.is.truthy(#passes >= 2)
    end)
  end)
end)

---@diagnostic disable: undefined-global
local pipeline = require('godbolt.pipeline')

describe("pipeline parser", function()
  describe("single function tests", function()
    it("parses single function with one pass", function()
      local test_file = vim.fn.fnamemodify("tests/fixtures/single_func.ll", ":p")

      local passes
      pipeline.run_pipeline(test_file, "sroa", {}, function(result)
        passes = result
      end)
      vim.wait(5000, function() return passes ~= nil end)

      -- Should have: sroa on simple (NO Input pass)
      assert.is_not_nil(passes)
      assert.are.equal(1, #passes, "Expected 1 stage: sroa")

      assert.are.equal("SROAPass on simple", passes[1].name)

      -- Pass should only contain the simple function (metadata is preserved)
      local ir_text = table.concat(passes[1].ir, "\n")
      assert.is_not_nil(ir_text:match("define i32 @simple"), "Pass should contain @simple function")
    end)

    it("parses single function with multiple passes", function()
      local test_file = vim.fn.fnamemodify("tests/fixtures/single_func.ll", ":p")

      local passes
      pipeline.run_pipeline(test_file, "sroa,instcombine", {}, function(result)
        passes = result
      end)
      vim.wait(5000, function() return passes ~= nil end)

      -- Should have: sroa + instcombine (NO Input)
      assert.is_not_nil(passes)
      assert.are.equal(2, #passes, "Expected 2 stages")

      assert.are.equal("SROAPass on simple", passes[1].name)
      assert.are.equal("InstCombinePass on simple", passes[2].name)
    end)
  end)

  describe("two function tests", function()
    it("parses two functions with function passes - THE KEY TEST", function()
      local test_file = vim.fn.fnamemodify("tests/fixtures/two_funcs.ll", ":p")

      local passes
      pipeline.run_pipeline(test_file, "sroa,instcombine", {}, function(result)
        passes = result
      end)
      vim.wait(5000, function() return passes ~= nil end)

      -- Should have: sroa-foo, instcombine-foo, sroa-bar, instcombine-bar (NO Input)
      assert.is_not_nil(passes)
      assert.are.equal(4, #passes, "Expected 4 stages: 2 funcs * 2 passes")

      assert.are.equal("SROAPass on foo", passes[1].name)
      assert.are.equal("InstCombinePass on foo", passes[2].name)
      assert.are.equal("SROAPass on bar", passes[3].name)
      assert.are.equal("InstCombinePass on bar", passes[4].name)

      -- With --print-module-scope, each pass shows the FULL module
      -- (both functions are present), not just the individual function
      local sroa_foo_text = table.concat(passes[1].ir, "\n")
      assert.is_not_nil(sroa_foo_text:match("define i32 @foo"), "SROAPass on foo should contain @foo")
      assert.is_not_nil(sroa_foo_text:match("define i32 @bar"), "With --print-module-scope, should contain full module")

      local instcombine_foo_text = table.concat(passes[2].ir, "\n")
      assert.is_not_nil(instcombine_foo_text:match("define i32 @foo"), "InstCombinePass on foo should contain @foo")
      assert.is_not_nil(instcombine_foo_text:match("define i32 @bar"), "With --print-module-scope, should contain full module")

      local sroa_bar_text = table.concat(passes[3].ir, "\n")
      assert.is_not_nil(sroa_bar_text:match("define i32 @bar"), "SROAPass on bar should contain @bar")
      assert.is_not_nil(sroa_bar_text:match("define i32 @foo"), "With --print-module-scope, should contain full module")

      local instcombine_bar_text = table.concat(passes[4].ir, "\n")
      assert.is_not_nil(instcombine_bar_text:match("define i32 @bar"), "InstCombinePass on bar should contain @bar")
      assert.is_not_nil(instcombine_bar_text:match("define i32 @foo"), "With --print-module-scope, should contain full module")
    end)

    it("preserves module metadata in IR", function()
      local test_file = vim.fn.fnamemodify("tests/fixtures/two_funcs.ll", ":p")

      local passes
      pipeline.run_pipeline(test_file, "sroa", {}, function(result)
        passes = result
      end)
      vim.wait(5000, function() return passes ~= nil end)

      assert.is_not_nil(passes)
      for _, pass in ipairs(passes) do
        local ir_text = table.concat(pass.ir, "\n")
        -- Module metadata should be preserved
        assert.is_not_nil(ir_text:match("ModuleID"), "Should contain ModuleID")
      end
    end)
  end)

  describe("parser edge cases", function()
    it("handles passes that don't modify IR", function()
      local test_file = vim.fn.fnamemodify("tests/fixtures/single_func.ll", ":p")

      local passes
      pipeline.run_pipeline(test_file, "sroa,sroa", {}, function(result)
        passes = result
      end)
      vim.wait(5000, function() return passes ~= nil end)

      assert.is_not_nil(passes)
      -- Should still have all stages even if IR doesn't change
      assert.is.truthy(#passes >= 2)
    end)
  end)
end)

---@diagnostic disable: undefined-global
local pipeline = require('godbolt.pipeline')
local pipeline_viewer = require('godbolt.pipeline_viewer')
local ir_utils = require('godbolt.ir_utils')

describe("pipeline integration", function()
  it("full flow: pipeline + viewer with single function", function()
    local test_file = vim.fn.fnamemodify("tests/fixtures/single_func.ll", ":p")
    local passes = pipeline.run_pipeline(test_file, "sroa")

    assert.is_not_nil(passes)
    assert.are.equal(1, #passes)

    -- Test viewer can be set up
    local source_bufnr = vim.api.nvim_create_buf(false, true)
    local ok = pcall(pipeline_viewer.setup, source_bufnr, test_file, passes, {
      show_stats = false,
      filter_unchanged = false,
    })

    assert.is_true(ok, "Viewer setup should succeed")

    -- Clean up
    pcall(pipeline_viewer.cleanup)
    pcall(vim.api.nvim_buf_delete, source_bufnr, {force = true})
  end)

  it("full flow: pipeline + viewer with two functions", function()
    local test_file = vim.fn.fnamemodify("tests/fixtures/two_funcs.ll", ":p")
    local passes = pipeline.run_pipeline(test_file, "sroa,instcombine")

    assert.is_not_nil(passes)
    assert.are.equal(4, #passes)

    -- Test viewer can be set up
    local source_bufnr = vim.api.nvim_create_buf(false, true)
    local ok = pcall(pipeline_viewer.setup, source_bufnr, test_file, passes, {
      show_stats = false,
      filter_unchanged = false,
    })

    assert.is_true(ok, "Viewer setup should succeed")

    -- Test navigation
    assert.are.equal(1, pipeline_viewer.state.current_index)

    -- Clean up
    pcall(pipeline_viewer.cleanup)
    pcall(vim.api.nvim_buf_delete, source_bufnr, {force = true})
  end)

  it("handles nil input_file gracefully", function()
    local passes = {{name = "TestPass on foo", ir = {"define i32 @foo() { ret i32 0 }"}}}
    local source_bufnr = vim.api.nvim_create_buf(false, true)

    -- Should not crash even with nil input_file
    local ok = pcall(pipeline_viewer.setup, source_bufnr, nil, passes, {
      show_stats = false,
    })

    assert.is_true(ok, "Viewer should handle nil input_file gracefully")

    -- Clean up
    pcall(pipeline_viewer.cleanup)
    pcall(vim.api.nvim_buf_delete, source_bufnr, {force = true})
  end)

  it("strips all bottom matter from extracted functions", function()
    local test_file = vim.fn.fnamemodify("tests/fixtures/real_world.ll", ":p")

    -- Get stripped input
    local input_ir = pipeline.get_stripped_input(test_file)
    assert.is_not_nil(input_ir)

    -- Extract the quicksort function
    local quicksort_ir = ir_utils.extract_function(input_ir, "quicksort")
    assert.is_not_nil(quicksort_ir)
    assert.is.truthy(#quicksort_ir > 0, "Should extract quicksort function")

    local ir_text = table.concat(quicksort_ir, "\n")

    -- Should contain the function
    assert.is_not_nil(ir_text:match("define void @quicksort"), "Should contain quicksort function")

    -- Should NOT contain bottom matter
    assert.is_nil(ir_text:match("; Function Attrs:"), "Should NOT contain Function Attrs comments")
    assert.is_nil(ir_text:match("declare "), "Should NOT contain declare statements")
    assert.is_nil(ir_text:match("attributes #"), "Should NOT contain attributes")
    assert.is_nil(ir_text:match("!llvm%.module%.flags"), "Should NOT contain module flags")
    assert.is_nil(ir_text:match("!llvm%.ident"), "Should NOT contain llvm.ident")

    -- Should NOT contain comments at all
    assert.is_nil(ir_text:match("^;"), "Should NOT contain comment lines")
  end)
end)

---@diagnostic disable: undefined-global
local pipeline = require('godbolt.pipeline')
local pipeline_viewer = require('godbolt.pipeline_viewer')

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
end)

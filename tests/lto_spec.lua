---@diagnostic disable: undefined-global
local lto = require('godbolt.lto')
local godbolt = require('godbolt')

describe("LTO module", function()
  local temp_dir

  before_each(function()
    temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")
  end)

  after_each(function()
    if temp_dir and vim.fn.isdirectory(temp_dir) == 1 then
      vim.fn.delete(temp_dir, "rf")
    end
  end)

  describe("compile_to_object", function()
    it("compiles C file to object with LTO", function()
      local main_c = vim.fn.fnamemodify("tests/fixtures/lto_simple/main.c", ":p")
      local obj_file = temp_dir .. "/main.o"

      local success, err = lto.compile_to_object(main_c, obj_file, "clang", "")

      assert.is_true(success, "Compilation should succeed: " .. (err or ""))
      assert.are.equal(1, vim.fn.filereadable(obj_file), "Object file should exist")
    end)

    it("compiles C++ file with clang++", function()
      -- Create a temp C++ file
      local cpp_file = temp_dir .. "/test.cpp"
      vim.fn.writefile({
        "int add(int a, int b) { return a + b; }",
        "int main() { return add(1, 2); }"
      }, cpp_file)

      local obj_file = temp_dir .. "/test.o"
      local success, err = lto.compile_to_object(cpp_file, obj_file, "clang++", "")

      assert.is_true(success, "C++ compilation should succeed: " .. (err or ""))
      assert.are.equal(1, vim.fn.filereadable(obj_file), "Object file should exist")
    end)

    it("returns error on invalid file", function()
      local invalid_file = temp_dir .. "/nonexistent.c"
      local obj_file = temp_dir .. "/out.o"

      local success, err = lto.compile_to_object(invalid_file, obj_file, "clang", "")

      assert.is_false(success, "Should fail for nonexistent file")
      assert.is_not_nil(err, "Should return error message")
      assert.is.truthy(err:match("error"), "Error message should contain 'error'")
    end)
  end)

  describe("link_with_lld", function()
    it("links object files and produces LLVM IR", function()
      local main_c = vim.fn.fnamemodify("tests/fixtures/lto_simple/main.c", ":p")
      local utils_c = vim.fn.fnamemodify("tests/fixtures/lto_simple/utils.c", ":p")

      -- Compile to object files
      local main_o = temp_dir .. "/main.o"
      local utils_o = temp_dir .. "/utils.o"
      local success1, _ = lto.compile_to_object(main_c, main_o, "clang", "")
      local success2, _ = lto.compile_to_object(utils_c, utils_o, "clang", "")

      assert.is_true(success1 and success2, "Both compilations should succeed")

      -- Link with lld
      local output_ll = temp_dir .. "/output.ll"
      local success, ir_lines = lto.link_with_lld({ main_o, utils_o }, output_ll, "ld.lld", "")

      assert.is_true(success, "Linking should succeed: " .. (ir_lines or ""))
      assert.is_not_nil(ir_lines, "Should return IR lines")
      assert.is.truthy(#ir_lines > 0, "IR should not be empty")

      -- Check IR contains expected functions
      local ir_text = table.concat(ir_lines, "\n")
      assert.is.truthy(ir_text:match("define.*@main"), "IR should contain main function")
      assert.is.truthy(ir_text:match("define.*@add") or ir_text:match("@add"), "IR should reference add")
    end)

    it("returns error with no object files", function()
      local output_ll = temp_dir .. "/output.ll"
      local success, err = lto.link_with_lld({}, output_ll, "ld.lld", "")

      assert.is_false(success, "Should fail with no input files")
      assert.is_not_nil(err, "Should return error message")
    end)
  end)

  describe("lto_compile_and_link", function()
    it("performs full LTO workflow", function()
      local main_c = vim.fn.fnamemodify("tests/fixtures/lto_simple/main.c", ":p")
      local utils_c = vim.fn.fnamemodify("tests/fixtures/lto_simple/utils.c", ":p")

      local success, ir_lines, temp = lto.lto_compile_and_link({ main_c, utils_c }, {
        keep_temps = false
      })

      assert.is_true(success, "LTO workflow should succeed: " .. (ir_lines or ""))
      assert.is_not_nil(ir_lines, "Should return IR")
      assert.is.truthy(#ir_lines > 0, "IR should not be empty")
      assert.is_not_nil(temp, "Should return temp directory")

      -- Cleanup
      lto.cleanup(temp)
    end)

    it("handles C++ files correctly", function()
      -- Create temp C++ files
      local main_cpp = temp_dir .. "/main.cpp"
      local utils_cpp = temp_dir .. "/utils.cpp"

      vim.fn.writefile({
        "int add(int a, int b);",
        "int main() { return add(5, 3); }"
      }, main_cpp)

      vim.fn.writefile({
        "int add(int a, int b) { return a + b; }"
      }, utils_cpp)

      local success, ir_lines, temp = lto.lto_compile_and_link({ main_cpp, utils_cpp }, {
        compiler = "clang++",
        keep_temps = false
      })

      assert.is_true(success, "C++ LTO should succeed: " .. (ir_lines or ""))
      assert.is_not_nil(ir_lines, "Should return IR")

      -- Cleanup
      lto.cleanup(temp)
    end)
  end)

  describe("run_lto_pipeline", function()
    it("captures LTO optimization passes", function()
      local main_c = vim.fn.fnamemodify("tests/fixtures/lto_simple/main.c", ":p")
      local utils_c = vim.fn.fnamemodify("tests/fixtures/lto_simple/utils.c", ":p")

      local success, output = lto.run_lto_pipeline({ main_c, utils_c }, "-O2", "")

      assert.is_true(success, "Pipeline should succeed: " .. (output or ""))
      assert.is_not_nil(output, "Should return output")
      assert.is.truthy(#output > 0, "Output should not be empty")

      -- Check for pass markers
      assert.is.truthy(output:match("IR Dump"), "Output should contain IR dumps")
    end)

    it("works with different optimization levels", function()
      local main_c = vim.fn.fnamemodify("tests/fixtures/lto_simple/main.c", ":p")
      local utils_c = vim.fn.fnamemodify("tests/fixtures/lto_simple/utils.c", ":p")

      for _, opt_level in ipairs({ "-O0", "-O1", "-O2", "-O3", "-Os", "-Oz" }) do
        local success, output = lto.run_lto_pipeline({ main_c, utils_c }, opt_level, "")
        assert.is_true(success, opt_level .. " should work")
        assert.is.truthy(#output > 0, opt_level .. " should produce output")
      end
    end)

    it("returns error for invalid files", function()
      local success, err = lto.run_lto_pipeline({ "nonexistent.c" }, "-O2", "")

      assert.is_false(success, "Should fail for invalid files")
      assert.is_not_nil(err, "Should return error message")
    end)
  end)
end)

describe("LTO integration", function()
  it("godbolt_lto creates buffer with IR", function()
    local main_c = vim.fn.fnamemodify("tests/fixtures/lto_simple/main.c", ":p")
    local utils_c = vim.fn.fnamemodify("tests/fixtures/lto_simple/utils.c", ":p")

    -- Run LTO compilation
    godbolt.godbolt_lto({ main_c, utils_c }, "")

    -- Wait a moment for async operations
    vim.wait(1000, function() return false end)

    -- Check that a buffer was created with LLVM IR
    local found_ir = false
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 100, false)
        local text = table.concat(lines, "\n")
        if text:match("ModuleID") or text:match("define.*@") then
          found_ir = true
          break
        end
      end
    end

    assert.is_true(found_ir, "Should create buffer with LLVM IR")
  end)

  it("godbolt_lto_pipeline captures passes", function()
    local main_c = vim.fn.fnamemodify("tests/fixtures/lto_simple/main.c", ":p")
    local utils_c = vim.fn.fnamemodify("tests/fixtures/lto_simple/utils.c", ":p")

    -- Run LTO pipeline
    godbolt.godbolt_lto_pipeline({ main_c, utils_c }, "-O2")

    -- Wait for completion
    vim.wait(2000, function() return false end)

    -- Check that pipeline viewer was set up
    local pipeline_viewer = require('godbolt.pipeline_viewer')
    local has_state = pipeline_viewer.state and pipeline_viewer.state.passes

    assert.is_true(has_state, "Should set up pipeline viewer state")

    if has_state then
      assert.is.truthy(#pipeline_viewer.state.passes > 0, "Should capture passes")
    end

    -- Cleanup
    pcall(pipeline_viewer.cleanup)
  end)
end)

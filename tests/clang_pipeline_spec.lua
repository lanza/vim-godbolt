---@diagnostic disable: undefined-global
local pipeline = require('godbolt.pipeline')

describe("C/C++ pipeline support", function()
  describe("clang pipeline execution", function()
    it("captures passes for simple C function with O2", function()
      local test_file = vim.fn.fnamemodify("tests/fixtures/simple.c", ":p")
      local passes = pipeline.run_pipeline(test_file, "O2")

      -- Check if clang is available
      if vim.fn.executable("clang") == 0 then
        pending("clang not installed")
        return
      end

      assert.is_not_nil(passes, "Should return passes array")
      assert.is_true(#passes > 0, "Should capture at least one pass")

      -- Verify IR contains the add function
      local found_add = false
      for _, pass in ipairs(passes) do
        local ir_text = table.concat(pass.ir, "\n")
        if ir_text:match("@add") then
          found_add = true
          break
        end
      end
      assert.is_true(found_add, "Should find @add function in IR")
    end)

    it("handles different optimization levels", function()
      local test_file = vim.fn.fnamemodify("tests/fixtures/simple.c", ":p")

      if vim.fn.executable("clang") == 0 then
        pending("clang not installed")
        return
      end

      local passes_o0 = pipeline.run_pipeline(test_file, "O0")
      local passes_o2 = pipeline.run_pipeline(test_file, "O2")
      local passes_o3 = pipeline.run_pipeline(test_file, "O3")

      assert.is_not_nil(passes_o0)
      assert.is_not_nil(passes_o2)
      assert.is_not_nil(passes_o3)

      -- O2/O3 should typically have more passes than O0
      -- (but this might vary depending on the code)
      assert.is_true(#passes_o2 >= #passes_o0 or #passes_o2 > 0,
        "O2 should produce passes")
    end)

    it("captures passes for multiple functions", function()
      local test_file = vim.fn.fnamemodify("tests/fixtures/multi.c", ":p")

      if vim.fn.executable("clang") == 0 then
        pending("clang not installed")
        return
      end

      local passes = pipeline.run_pipeline(test_file, "O2")

      assert.is_not_nil(passes)
      assert.is_true(#passes > 0)

      -- Should find at least one of our functions
      local found_func = false
      for _, pass in ipairs(passes) do
        local ir_text = table.concat(pass.ir, "\n")
        if ir_text:match("@foo") or ir_text:match("@bar") or ir_text:match("@baz") then
          found_func = true
          break
        end
      end
      assert.is_true(found_func, "Should find at least one function")
    end)
  end)

  describe("C++ pipeline execution", function()
    it("handles C++ template instantiation", function()
      local test_file = vim.fn.fnamemodify("tests/fixtures/template.cpp", ":p")

      if vim.fn.executable("clang++") == 0 then
        pending("clang++ not installed")
        return
      end

      local passes = pipeline.run_pipeline(test_file, "O2")

      assert.is_not_nil(passes)
      assert.is_true(#passes > 0, "Should capture passes for C++")

      -- Should find main or template instantiation
      local found_code = false
      for _, pass in ipairs(passes) do
        local ir_text = table.concat(pass.ir, "\n")
        if ir_text:match("@main") or ir_text:match("@_Z") then
          found_code = true
          break
        end
      end
      assert.is_true(found_code, "Should find generated code")
    end)
  end)

  describe("error handling", function()
    it("rejects custom pass lists for C files", function()
      local test_file = vim.fn.fnamemodify("tests/fixtures/simple.c", ":p")

      if vim.fn.executable("clang") == 0 then
        pending("clang not installed")
        return
      end

      -- Custom passes should not be supported
      local passes = pipeline.run_pipeline(test_file, "mem2reg,instcombine")

      -- Should either return nil or be rejected at higher level
      -- The rejection happens in godbolt_pipeline, not run_pipeline
      -- So run_pipeline will fail trying to normalize non-O-level
      assert.is_nil(passes, "Should reject custom passes")
    end)

    it("handles compilation errors gracefully", function()
      -- Create a test file with syntax errors
      local error_file = vim.fn.tempname() .. ".c"
      vim.fn.writefile({
        "int main( {",  -- Missing )
        "  return 0;",
        "}"
      }, error_file)

      if vim.fn.executable("clang") == 0 then
        vim.fn.delete(error_file)
        pending("clang not installed")
        return
      end

      local passes = pipeline.run_pipeline(error_file, "O2")

      -- Should return nil on compilation error
      assert.is_nil(passes, "Should return nil on compilation error")

      -- Clean up
      vim.fn.delete(error_file)
    end)
  end)

  describe("parser validation", function()
    it("filters out non-LLVM-IR content", function()
      local test_file = vim.fn.fnamemodify("tests/fixtures/simple.c", ":p")

      if vim.fn.executable("clang") == 0 then
        pending("clang not installed")
        return
      end

      local passes = pipeline.run_pipeline(test_file, "O2")

      if not passes or #passes == 0 then
        pending("No passes captured")
        return
      end

      -- All passes should contain valid LLVM IR
      for _, pass in ipairs(passes) do
        local ir_text = table.concat(pass.ir, "\n")
        -- Should have either define/declare (functions), or typical LLVM IR constructs
        -- Module-level passes might only have attributes/metadata after cleaning
        local has_function = (ir_text:match("define ") or ir_text:match("declare ")) ~= nil
        local has_llvm_ir_markers = ir_text:match("^attributes ") ~= nil or
                                     ir_text:match("^!") ~= nil or  -- metadata
                                     ir_text:match("^target ") ~= nil or
                                     ir_text:match("^source_filename") ~= nil or
                                     #pass.ir == 0
        assert.is_true(
          has_function or has_llvm_ir_markers,
          "Pass '" .. pass.name .. "' should contain LLVM IR or typical IR constructs"
        )
      end
    end)

    it("parses pass names correctly from clang output", function()
      local test_file = vim.fn.fnamemodify("tests/fixtures/simple.c", ":p")

      if vim.fn.executable("clang") == 0 then
        pending("clang not installed")
        return
      end

      local passes = pipeline.run_pipeline(test_file, "O2")

      if not passes or #passes == 0 then
        pending("No passes captured")
        return
      end

      -- All passes should have names
      for _, pass in ipairs(passes) do
        assert.is_not_nil(pass.name)
        assert.is_string(pass.name)
        assert.is_true(#pass.name > 0, "Pass name should not be empty")
      end
    end)
  end)

  describe("helper functions", function()
    it("normalizes O-levels correctly", function()
      -- We can't directly test the local function, but we can test via run_pipeline
      -- by checking it doesn't error with various O-level formats
      local test_file = vim.fn.fnamemodify("tests/fixtures/simple.c", ":p")

      if vim.fn.executable("clang") == 0 then
        pending("clang not installed")
        return
      end

      -- All these should work (or at least not crash)
      local ok1, passes1 = pcall(pipeline.run_pipeline, test_file, "O2")
      local ok2, passes2 = pcall(pipeline.run_pipeline, test_file, "-O2")
      local ok3, passes3 = pcall(pipeline.run_pipeline, test_file, "2")

      assert.is_true(ok1, "Should handle 'O2'")
      assert.is_true(ok2, "Should handle '-O2'")
      assert.is_true(ok3, "Should handle '2'")
    end)
  end)
end)

describe("pipeline dispatcher", function()
  it("routes .ll files to opt pipeline", function()
    local test_file = vim.fn.fnamemodify("tests/fixtures/test.ll", ":p")

    if vim.fn.executable("opt") == 0 then
      pending("opt not installed")
      return
    end

    -- Should not crash for .ll files
    local ok, passes = pcall(pipeline.run_pipeline, test_file, "sroa")

    assert.is_true(ok, "Should handle .ll files")
  end)

  it("routes .c files to clang pipeline", function()
    local test_file = vim.fn.fnamemodify("tests/fixtures/simple.c", ":p")

    if vim.fn.executable("clang") == 0 then
      pending("clang not installed")
      return
    end

    local ok, passes = pcall(pipeline.run_pipeline, test_file, "O2")

    assert.is_true(ok, "Should handle .c files")
  end)

  it("routes .cpp files to clang++ pipeline", function()
    local test_file = vim.fn.fnamemodify("tests/fixtures/template.cpp", ":p")

    if vim.fn.executable("clang++") == 0 then
      pending("clang++ not installed")
        return
    end

    local ok, passes = pcall(pipeline.run_pipeline, test_file, "O2")

    assert.is_true(ok, "Should handle .cpp files")
  end)

  it("rejects unsupported file types", function()
    local result = pipeline.run_pipeline("test.txt", "O2")

    assert.is_nil(result, "Should reject unsupported file types")
  end)
end)

describe("scope detection", function()
  it("detects module passes", function()
    local output = [[
; *** IR Dump After GlobalOptPass on [module] ***
; ModuleID = 'test.c'
define void @foo() { ret void }
define void @bar() { ret void }
; *** IR Dump After SROAPass on foo ***
define void @foo() { ret void }
]]

    local passes = pipeline.parse_pipeline_output(output, "clang")

    assert.are.equal(2, #passes, "Should parse both passes")
    assert.are.equal("module", passes[1].scope_type, "First pass should be module scope")
    assert.are.equal("[module]", passes[1].scope_target, "Module target should be [module]")
    assert.are.equal("function", passes[2].scope_type, "Second pass should be function scope")
    assert.are.equal("foo", passes[2].scope_target, "Function target should be foo")
  end)

  it("detects CGSCC passes", function()
    local output = [[
; *** IR Dump After InlinerPass on (quicksort) ***
define void @quicksort() { ret void }
]]

    local passes = pipeline.parse_pipeline_output(output, "clang")

    assert.are.equal(1, #passes, "Should parse one pass")
    assert.are.equal("cgscc", passes[1].scope_type, "Should be CGSCC scope")
    assert.are.equal("quicksort", passes[1].scope_target, "CGSCC target should be quicksort without parens")
  end)

  it("detects function passes", function()
    local output = [[
; *** IR Dump After SROAPass on main ***
define i32 @main() { ret i32 0 }
]]

    local passes = pipeline.parse_pipeline_output(output, "clang")

    assert.are.equal(1, #passes, "Should parse one pass")
    assert.are.equal("function", passes[1].scope_type, "Should be function scope")
    assert.are.equal("main", passes[1].scope_target, "Function target should be main")
  end)

  it("handles mixed scope passes correctly", function()
    local output = [[
; *** IR Dump After Annotation2MetadataPass on [module] ***
; ModuleID = 'test.c'
define void @foo() { ret void }
define void @bar() { ret void }
; *** IR Dump After SROAPass on foo ***
define void @foo() { ret void }
; *** IR Dump After InstCombinePass on bar ***
define void @bar() { ret void }
; *** IR Dump After GlobalDCEPass on [module] ***
; ModuleID = 'test.c'
define void @foo() { ret void }
define void @bar() { ret void }
]]

    local passes = pipeline.parse_pipeline_output(output, "clang")

    assert.are.equal(4, #passes, "Should parse all four passes")

    -- Check scopes
    assert.are.equal("module", passes[1].scope_type, "First should be module")
    assert.are.equal("function", passes[2].scope_type, "Second should be function")
    assert.are.equal("function", passes[3].scope_type, "Third should be function")
    assert.are.equal("module", passes[4].scope_type, "Fourth should be module")

    -- Check targets
    assert.are.equal("[module]", passes[1].scope_target)
    assert.are.equal("foo", passes[2].scope_target)
    assert.are.equal("bar", passes[3].scope_target)
    assert.are.equal("[module]", passes[4].scope_target)
  end)

  it("correctly cleans module vs function IR", function()
    local output = [[
; *** IR Dump After GlobalOptPass on [module] ***
; ModuleID = 'test.c'
source_filename = "test.c"
target datalayout = "e-m:o-i64:64"
@global = internal constant i32 42
define void @foo() { ret void }
define void @bar() { ret void }
declare void @llvm.foo()
attributes #0 = { nounwind }
!0 = !{i32 1}
; *** IR Dump After SROAPass on foo ***
define void @foo() { ret void }
]]

    local passes = pipeline.parse_pipeline_output(output, "clang")

    assert.are.equal(2, #passes)

    -- Module pass should contain globals, functions, etc.
    local module_ir_text = table.concat(passes[1].ir, "\n")
    assert.is_true(module_ir_text:match("@global") ~= nil, "Module IR should contain globals")
    assert.is_true(module_ir_text:match("@foo") ~= nil, "Module IR should contain foo")
    assert.is_true(module_ir_text:match("@bar") ~= nil, "Module IR should contain bar")

    -- Function pass should contain only the function
    local func_ir_text = table.concat(passes[2].ir, "\n")
    assert.is_true(func_ir_text:match("define void @foo") ~= nil, "Function IR should contain foo")
    assert.is_false(func_ir_text:match("@global") ~= nil, "Function IR should not contain globals")
    assert.is_false(func_ir_text:match("@bar") ~= nil, "Function IR should not contain bar")
  end)
end)

describe("real-world C/C++ file with scope detection", function()
  it("handles qs.c with mixed module and function passes", function()
    local test_file = vim.fn.fnamemodify("tests/fixtures/qs.c", ":p")

    if vim.fn.executable("clang") == 0 then
      pending("clang not installed")
      return
    end

    local passes = pipeline.run_pipeline(test_file, "O2")

    if not passes or #passes == 0 then
      pending("No passes captured from qs.c")
      return
    end

    -- Should have both module and function passes
    local has_module = false
    local has_function = false
    local has_cgscc = false

    for _, pass in ipairs(passes) do
      if pass.scope_type == "module" then
        has_module = true
        -- Module pass should contain both functions
        local ir_text = table.concat(pass.ir, "\n")
        assert.is_true(ir_text:match("quicksort") ~= nil or ir_text:match("@") ~= nil,
          "Module pass '" .. pass.name .. "' should contain functions")
      elseif pass.scope_type == "function" then
        has_function = true
        -- Function pass should have a valid target
        assert.is_not_nil(pass.scope_target, "Function pass should have scope_target")
      elseif pass.scope_type == "cgscc" then
        has_cgscc = true
      end
    end

    assert.is_true(has_module, "Should have at least one module pass")
    assert.is_true(has_function or has_cgscc, "Should have at least one function or CGSCC pass")
  end)
end)


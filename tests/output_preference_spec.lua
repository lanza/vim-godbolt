describe("output preference with compile_commands.json", function()
  local godbolt = require('godbolt')
  local project = require('godbolt.project')

  local test_dir
  local test_file
  local cc_file

  before_each(function()
    -- Create temp directory with .git marker
    test_dir = vim.fn.tempname()
    vim.fn.mkdir(test_dir, "p")
    vim.fn.mkdir(test_dir .. "/.git", "p")

    -- Create test C file
    test_file = test_dir .. "/test.c"
    vim.fn.writefile({
      "int add(int a, int b) {",
      "    return a + b;",
      "}"
    }, test_file)

    -- Create compile_commands.json
    cc_file = test_dir .. "/compile_commands.json"
    vim.fn.writefile({
      '[',
      '  {',
      '    "directory": "' .. test_dir .. '",',
      '    "command": "/usr/bin/clang -O2 -c ' .. test_file .. '",',
      '    "file": "' .. test_file .. '"',
      '  }',
      ']'
    }, cc_file)
  end)

  after_each(function()
    -- Cleanup
    if test_dir then
      vim.fn.delete(test_dir, "rf")
    end
  end)

  it("should inject -emit-llvm when output=llvm", function()
    -- Open the test file
    vim.cmd("edit " .. test_file)

    -- Call godbolt with output=llvm
    godbolt.godbolt("", { output = "llvm" })

    -- Check the command that was generated
    local cmd = vim.g.last_godbolt_cmd
    assert.is_not_nil(cmd)
    assert.truthy(cmd:match("-emit%-llvm"), "Should have -emit-llvm")

    -- Should have -O2 from compile_commands.json
    assert.truthy(cmd:match("-O2"), "Should have -O2")

    -- Should have both -emit-llvm and -S (both are needed for LLVM IR text output)
    assert.truthy(cmd:match("-emit%-llvm"), "Should have -emit-llvm")
    assert.truthy(cmd:match("-S"), "Should have -S")
  end)

  it("should output LLVM IR with output=llvm", function()
    -- Open the test file
    vim.cmd("edit " .. test_file)

    -- Call godbolt with output=llvm
    godbolt.godbolt("", { output = "llvm" })

    -- Get the output buffer content
    local bufnr = vim.fn.bufnr("%")
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 20, false)
    local output = table.concat(lines, "\n")

    -- Should be LLVM IR, not assembly
    assert.truthy(output:match("ModuleID") or output:match("target datalayout"),
      "Expected LLVM IR output with ModuleID or target datalayout")
    assert.falsy(output:match("%.section"), "Should not contain assembly directives")
    assert.falsy(output:match("%.globl"), "Should not contain assembly directives")
  end)

  it("should NOT inject -emit-llvm when output=auto", function()
    -- Open the test file
    vim.cmd("edit " .. test_file)

    -- Call godbolt with output=auto
    godbolt.godbolt("", { output = "auto" })

    -- Check the command that was generated
    local cmd = vim.g.last_godbolt_cmd
    assert.is_not_nil(cmd)

    -- Should NOT have -emit-llvm
    assert.falsy(cmd:match("-emit%-llvm"))

    -- Should have -O2 from compile_commands.json
    assert.truthy(cmd:match("-O2"))
  end)

  it("should work with C++ files and complex compile_commands.json", function()
    -- Create a C++ file
    local cpp_file = test_dir .. "/test.cpp"
    vim.fn.writefile({
      "class Foo {",
      "public:",
      "  int add(int a, int b) { return a + b; }",
      "};",
    }, cpp_file)

    -- Create complex compile_commands.json like LLVM's
    vim.fn.writefile({
      '[',
      '  {',
      '    "directory": "' .. test_dir .. '",',
      '    "command": "/usr/bin/clang++ -DSOME_DEFINE -I/some/include -O3 -std=c++17 -c ' .. cpp_file .. '",',
      '    "file": "' .. cpp_file .. '"',
      '  }',
      ']'
    }, cc_file)

    -- Open the C++ file
    vim.cmd("edit " .. cpp_file)

    -- Call godbolt with output=llvm
    godbolt.godbolt("", { output = "llvm" })

    -- Check the command
    local cmd = vim.g.last_godbolt_cmd
    assert.is_not_nil(cmd)
    assert.truthy(cmd:match("-emit%-llvm"), "Should have -emit-llvm")
    assert.truthy(cmd:match("-S"), "Should have -S (needed with -emit-llvm)")
    assert.truthy(cmd:match("-O3"), "Should have -O3 from compile_commands")
    assert.truthy(cmd:match("-std=c%+%+17"), "Should have -std=c++17")
    assert.truthy(cmd:match("/usr/bin/clang%+%+"), "Should use correct compiler")

    -- Check output is LLVM IR
    local bufnr = vim.fn.bufnr("%")
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 20, false)
    local output = table.concat(lines, "\n")
    assert.truthy(output:match("ModuleID") or output:match("target datalayout"),
      "Should output LLVM IR")
  end)
end)

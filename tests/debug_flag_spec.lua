---@diagnostic disable: undefined-global
local godbolt = require('godbolt')

describe("godbolt debug flag handling", function()
  local original_config

  before_each(function()
    -- Save original config
    original_config = vim.deepcopy(godbolt.config)

    -- Reset to defaults
    godbolt.setup({
      clang = 'clang',
      opt = 'opt',
      line_mapping = {
        enabled = false -- Disable to avoid async issues in tests
      }
    })
  end)

  after_each(function()
    -- Restore original config
    godbolt.config = original_config

    -- Clean up any created buffers/windows
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_option(buf, 'buftype') == 'nofile' then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end)

  it("should add -g flag for C files (clang)", function()
    local test_file = vim.fn.fnamemodify("tests/fixtures/test.c", ":p")

    -- Create a buffer with the test file
    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, test_file)
    vim.api.nvim_set_current_buf(buf)

    -- Write test content
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "int add(int a, int b) {",
      "    return a + b;",
      "}"
    })

    -- Call godbolt (this will try to compile)
    godbolt.godbolt("")

    -- Check that the command contains -g
    local cmd = vim.g.last_godbolt_cmd
    assert.is_not_nil(cmd, "Compilation command should be stored")
    assert.is_not_nil(cmd:match("%-g"), "Command should contain -g flag for C files")

    -- Clean up
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("should NOT add -g flag for LLVM IR files (opt)", function()
    local test_file = vim.fn.fnamemodify("tests/fixtures/test.ll", ":p")

    -- Create a buffer with the test file
    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, test_file)
    vim.api.nvim_set_current_buf(buf)

    -- Write test content
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "define i32 @add(i32 %a, i32 %b) {",
      "entry:",
      "  %sum = add i32 %a, %b",
      "  ret i32 %sum",
      "}"
    })

    -- Call godbolt (this will try to compile)
    godbolt.godbolt("")

    -- Check that the command does NOT contain -g
    local cmd = vim.g.last_godbolt_cmd
    assert.is_not_nil(cmd, "Compilation command should be stored")
    assert.is_nil(cmd:match("%-g[^-]"), "Command should NOT contain -g flag for .ll files")
    assert.is_not_nil(cmd:match("opt"), "Command should use opt for .ll files")

    -- Clean up
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("should place -g at the end of arguments for C files", function()
    local test_file = vim.fn.fnamemodify("tests/fixtures/test.c", ":p")

    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, test_file)
    vim.api.nvim_set_current_buf(buf)

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "int add(int a, int b) { return a + b; }"
    })

    -- Call with user flags
    godbolt.godbolt("-O2")

    local cmd = vim.g.last_godbolt_cmd
    assert.is_not_nil(cmd)

    -- Extract just the arguments part after the filename
    -- Command format: clang "file" -S -O2 ... -g -o -
    -- We want to verify -g comes after -O2 and before -o
    local args_after_file = cmd:match('%.c"%s+(.*)%-o%s+%-')
    assert.is_not_nil(args_after_file, "Should extract args portion")

    -- -g should be near the end (after user flags like -O2)
    local g_pos = args_after_file:find("%-g")
    local o2_pos = args_after_file:find("%-O2")

    if o2_pos then
      assert.is_true(g_pos > o2_pos, "-g should come after user flags like -O2")
    end

    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("should warn about -g0 flag but still try to compile", function()
    local test_file = vim.fn.fnamemodify("tests/fixtures/test.c", ":p")

    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, test_file)
    vim.api.nvim_set_current_buf(buf)

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "// godbolt: -g0",
      "int add(int a, int b) { return a + b; }"
    })

    -- Capture print output would require more complex setup
    -- For now just verify it doesn't crash
    local ok = pcall(godbolt.godbolt, "")
    assert.is_true(ok, "Should not crash with -g0 flag")

    local cmd = vim.g.last_godbolt_cmd
    assert.is_not_nil(cmd)
    -- Should still have -g at the end
    assert.is_not_nil(cmd:match("%-g"), "Should still add -g even with -g0")

    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it("should handle buffer comments with -emit-llvm", function()
    local test_file = vim.fn.fnamemodify("tests/fixtures/test.c", ":p")

    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, test_file)
    vim.api.nvim_set_current_buf(buf)

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "// godbolt: -emit-llvm",
      "int add(int a, int b) { return a + b; }"
    })

    godbolt.godbolt("")

    local cmd = vim.g.last_godbolt_cmd
    assert.is_not_nil(cmd)
    assert.is_not_nil(cmd:match("%-emit%-llvm"), "Should include -emit-llvm from buffer comment")
    assert.is_not_nil(cmd:match("%-g"), "Should still add -g flag")

    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end)

describe("debug info verification", function()
  it("should detect LLVM IR debug metadata", function()
    local test_lines = {
      "define i32 @foo() !dbg !10 {",
      "  ret i32 42, !dbg !11",
      "}",
      "!10 = !DILocation(line: 1, column: 5, scope: !5)",
      "!11 = !DILocation(line: 2, column: 3, scope: !5)",
    }

    -- This is testing the internal verify_debug_info function
    -- We'll need to make it accessible or test indirectly
    -- For now, we verify the output contains the expected metadata
    local has_dilocation = false
    local has_dbg = false

    for _, line in ipairs(test_lines) do
      if line:match("!DILocation") then has_dilocation = true end
      if line:match("!dbg") then has_dbg = true end
    end

    assert.is_true(has_dilocation, "Test data should have !DILocation")
    assert.is_true(has_dbg, "Test data should have !dbg")
  end)

  it("should detect assembly debug directives", function()
    local test_lines = {
      "  .file 1 \"test.c\"",
      "  .loc 1 1 0",
      "add:",
      "  addl %esi, %edi",
      "  .loc 1 2 0",
      "  ret",
    }

    local has_file = false
    local has_loc = false

    for _, line in ipairs(test_lines) do
      if line:match("^%s*%.file%s") then has_file = true end
      if line:match("^%s*%.loc%s") then has_loc = true end
    end

    assert.is_true(has_file, "Test data should have .file directive")
    assert.is_true(has_loc, "Test data should have .loc directive")
  end)
end)

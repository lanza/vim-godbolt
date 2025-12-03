---@diagnostic disable: undefined-global
local serializer = require('godbolt.pipeline_serializer')
local session = require('godbolt.pipeline_session')
local pipeline_parser = require('godbolt.pipeline_parser')

describe("Pipeline Session Persistence", function()
  local test_dir = vim.fn.tempname() .. "_godbolt_test"
  local test_source = test_dir .. "/test.c"
  local test_ll = test_dir .. "/test.ll"

  -- Create a test directory and files
  before_each(function()
    vim.fn.mkdir(test_dir, "p")

    -- Create a simple C file
    local c_code = [[
int add(int a, int b) { return a + b; }
int main() { return add(5, 3); }
]]
    vim.fn.writefile(vim.split(c_code, "\n"), test_source)

    -- Compile to LLVM IR with -O1 (to get optimizable code)
    local compile_cmd = string.format(
      "clang -O1 -S -emit-llvm -o %s %s 2>/dev/null",
      test_ll, test_source
    )
    vim.fn.system(compile_cmd)

    if vim.v.shell_error ~= 0 then
      error("Failed to compile test file")
    end
  end)

  after_each(function()
    -- Clean up test files and session data
    vim.fn.delete(test_dir, "rf")
    vim.fn.delete(".godbolt-pipeline", "rf")
  end)

  it("persists sessions across Neovim instances", function()
    -- Step 1: Generate pipeline data
    local opt_cmd = string.format(
      "opt -O2 -print-changed -disable-output %s 2>&1",
      test_ll
    )
    local output = vim.fn.system(opt_cmd)

    assert.is_false(vim.v.shell_error ~= 0 and not output:match("IR Dump"),
      "Failed to run optimization pipeline")

    local result = pipeline_parser.parse_pipeline_output_lazy(output)
    local passes = result.passes
    local initial_ir = result.initial_ir

    assert.is_not_nil(passes, "Failed to parse pipeline output")
    assert.is_true(#passes > 0, "No passes generated")

    local num_passes = #passes
    local first_pass_name = passes[1].name
    local last_pass_name = passes[#passes].name

    -- Step 2: Save the session
    local session_name = "persistence-test-" .. os.time()
    local filepath, err = session.save_session(
      passes,
      initial_ir,
      test_source,
      {
        opt_level = "O2",
        command = opt_cmd,
        compiler = "opt"
      },
      session_name
    )

    assert.is_not_nil(filepath, "Failed to save session: " .. tostring(err))
    assert.is_true(vim.fn.filereadable(filepath) == 1,
      "Session file not created on disk")

    -- Step 3: Clear all in-memory data to simulate new Neovim instance
    passes = nil
    initial_ir = nil
    result = nil

    -- Force garbage collection to ensure data is cleared
    collectgarbage("collect")

    -- Step 4: List sessions (should find our saved session)
    local sessions = session.list_sessions(test_source)
    assert.is_true(#sessions > 0, "No sessions found after saving")

    local found_session = false
    for _, s in ipairs(sessions) do
      if s.name == session_name then
        found_session = true
        assert.equals(num_passes, s.passes,
          "Session metadata shows wrong number of passes")
        break
      end
    end
    assert.is_true(found_session, "Saved session not found in list")

    -- Step 5: Load the session back (simulating new Neovim instance)
    local loaded, load_err = session.load_session(test_source, session_name)

    assert.is_not_nil(loaded, "Failed to load session: " .. tostring(load_err))
    assert.is_table(loaded.passes, "Loaded session missing passes")
    assert.equals(num_passes, #loaded.passes,
      "Loaded session has wrong number of passes")

    -- Step 6: Verify data integrity
    assert.equals(first_pass_name, loaded.passes[1].name,
      "First pass name doesn't match")
    assert.equals(last_pass_name, loaded.passes[#loaded.passes].name,
      "Last pass name doesn't match")

    -- Verify IR content is preserved
    if loaded.passes[1].ir_or_index then
      assert.is_not_nil(loaded.passes[1].ir_or_index,
        "IR content not preserved")
    end

    -- Verify metadata
    assert.is_table(loaded.metadata, "Metadata not preserved")
    assert.equals("O2", loaded.metadata.compilation.opt_level,
      "Optimization level not preserved")
    assert.equals("opt", loaded.metadata.compilation.compiler,
      "Compiler not preserved")

    -- Step 7: Clean up the test session
    local delete_ok = session.delete_session(test_source, session_name)
    assert.is_true(delete_ok, "Failed to delete test session")

    -- Verify deletion
    sessions = session.list_sessions(test_source)
    found_session = false
    for _, s in ipairs(sessions) do
      if s.name == session_name then
        found_session = true
        break
      end
    end
    assert.is_false(found_session, "Session not deleted properly")
  end)

  it("handles multiple sessions correctly", function()
    -- Generate test data
    local opt_cmd = string.format(
      "opt -O2 -print-changed -disable-output %s 2>&1",
      test_ll
    )
    local output = vim.fn.system(opt_cmd)
    local result = pipeline_parser.parse_pipeline_output_lazy(output)

    -- Save multiple sessions
    local session_names = {}
    for i = 1, 3 do
      local name = "multi-test-" .. i
      table.insert(session_names, name)

      local filepath, err = session.save_session(
        result.passes,
        result.initial_ir,
        test_source,
        { opt_level = "O" .. i },
        name
      )

      assert.is_not_nil(filepath,
        "Failed to save session " .. i .. ": " .. tostring(err))

      -- Small delay to ensure different timestamps
      vim.wait(10)
    end

    -- List all sessions
    local sessions = session.list_sessions(test_source)
    assert.equals(3, #sessions, "Wrong number of sessions listed")

    -- Load each session and verify
    for _, name in ipairs(session_names) do
      local loaded, err = session.load_session(test_source, name)
      assert.is_not_nil(loaded,
        "Failed to load session " .. name .. ": " .. tostring(err))
      assert.equals(#result.passes, #loaded.passes,
        "Pass count mismatch for " .. name)
    end

    -- Clean up
    for _, name in ipairs(session_names) do
      session.delete_session(test_source, name)
    end
  end)

  it("validates source file changes", function()
    -- Generate and save a session
    local opt_cmd = string.format(
      "opt -O2 -print-changed -disable-output %s 2>&1",
      test_ll
    )
    local output = vim.fn.system(opt_cmd)
    local result = pipeline_parser.parse_pipeline_output_lazy(output)

    local session_name = "validation-test"
    session.save_session(
      result.passes,
      result.initial_ir,
      test_source,
      {},
      session_name
    )

    -- Modify the source file
    vim.fn.writefile({"// Modified"}, test_source, "a")

    -- Load the session (should succeed but with warning)
    local loaded, err = session.load_session(test_source, session_name)
    assert.is_not_nil(loaded, "Should load even with modified source")

    -- The serializer.validate_source function should detect the change
    local valid, warning = serializer.validate_source(loaded.metadata)
    assert.is_true(valid, "Validation should pass with warning")
    assert.is_not_nil(warning, "Should have warning about source change")
    assert.is_not_nil(warning:match("has changed"),
      "Warning should mention file change")

    -- Clean up
    session.delete_session(test_source, session_name)
  end)

  it("preserves session data integrity", function()
    -- Create passes with various data types
    local test_passes = {
      {
        name = "TestPass1",
        scope_type = "module",
        changed = true,
        ir_or_index = {"line1", "line2", "line3"},
        stats = { instructions = 10, functions = 2 },
        remarks = { { category = "test", message = "test remark" } }
      },
      {
        name = "TestPass2",
        scope_type = "function",
        scope_target = "main",
        changed = false,
        ir_or_index = 1,  -- Reference to previous pass
        stats = { instructions = 8 }
      }
    }

    local initial_ir = {"initial", "ir", "lines"}

    -- Save session
    local session_name = "integrity-test"
    local filepath, err = session.save_session(
      test_passes,
      initial_ir,
      test_source,
      { opt_level = "O2", custom_field = "test_value" },
      session_name
    )

    assert.is_not_nil(filepath, "Save failed: " .. tostring(err))

    -- Load session
    local loaded, load_err = session.load_session(test_source, session_name)
    assert.is_not_nil(loaded, "Load failed: " .. tostring(load_err))

    -- Verify passes
    assert.equals(2, #loaded.passes, "Wrong number of passes")
    assert.equals("TestPass1", loaded.passes[1].name)
    assert.equals("module", loaded.passes[1].scope_type)
    assert.is_true(loaded.passes[1].changed)
    assert.equals(10, loaded.passes[1].stats.instructions)

    assert.equals("TestPass2", loaded.passes[2].name)
    assert.equals("function", loaded.passes[2].scope_type)
    assert.equals("main", loaded.passes[2].scope_target)
    assert.is_false(loaded.passes[2].changed)

    -- Verify IR content
    assert.is_table(loaded.passes[1].ir_or_index)
    assert.equals("line1", loaded.passes[1].ir_or_index[1])

    -- Verify lazy reference
    assert.equals(1, loaded.passes[2].ir_or_index)

    -- Verify metadata
    assert.equals("O2", loaded.metadata.compilation.opt_level)
    assert.equals("test_value", loaded.metadata.compilation.custom_field)

    -- Clean up
    session.delete_session(test_source, session_name)
  end)
end)
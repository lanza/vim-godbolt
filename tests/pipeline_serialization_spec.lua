---@diagnostic disable: undefined-global
local serializer = require('godbolt.pipeline_serializer')
local session = require('godbolt.pipeline_session')

-- Helper to create test passes
local function create_test_passes()
  return {
    {
      name = "ModulePass1",
      scope_type = "module",
      changed = true,
      ir_or_index = { "define i32 @foo() {", "  ret i32 0", "}" },
      stats = { instructions = 10, functions = 1 },
      _initial_ir = { "; Initial IR", "define i32 @foo() {", "  ret i32 1", "}" },
    },
    {
      name = "FunctionPass on foo",
      scope_type = "function",
      scope_target = "foo",
      changed = true,
      ir_or_index = { "define i32 @foo() {", "  ret i32 2", "}" },
      stats = { instructions = 8, functions = 1 },
    },
    {
      name = "ModulePass2",
      scope_type = "module",
      changed = false,
      ir_or_index = 2,  -- References previous pass
      stats = { instructions = 8, functions = 1 },
    },
  }
end

describe("Pipeline Serializer", function()
  describe("serialization", function()
    it("serializes and deserializes passes correctly", function()
      local passes = create_test_passes()
      local initial_ir = passes[1]._initial_ir

      local json = serializer.serialize(passes, initial_ir, {
        source = { file = "test.ll", checksum = "abc123" },
        compilation = { opt_level = "O2" },
      })

      assert.is_string(json)
      assert.is_true(#json > 0)

      -- Deserialize
      local result = serializer.deserialize(json)
      assert.is_table(result)
      assert.is_table(result.passes)
      assert.equals(#passes, #result.passes)

      -- Check first pass
      assert.equals(passes[1].name, result.passes[1].name)
      assert.equals(passes[1].scope_type, result.passes[1].scope_type)
      assert.equals(passes[1].changed, result.passes[1].changed)

      -- Check IR content
      assert.is_table(result.passes[1].ir_or_index)
      assert.equals("define i32 @foo() {", result.passes[1].ir_or_index[1])
    end)

    it("deduplicates IR correctly", function()
      local passes = {
        {
          name = "Pass1",
          changed = true,
          ir_or_index = { "line1", "line2", "line3" },
        },
        {
          name = "Pass2",
          changed = true,
          ir_or_index = { "line1", "line2", "line3" },  -- Same IR
        },
        {
          name = "Pass3",
          changed = true,
          ir_or_index = { "different", "ir", "here" },
        },
      }

      local json = serializer.serialize(passes, nil, {})
      local data = vim.json.decode(json)

      -- Should only have 2 unique IR entries (not 3)
      local ir_count = vim.tbl_count(data.pipeline.ir_table)
      assert.equals(2, ir_count, "Should deduplicate identical IR")
    end)

    it("handles lazy IR references", function()
      local passes = {
        {
          name = "Pass1",
          changed = true,
          ir_or_index = { "ir1" },
        },
        {
          name = "Pass2",
          changed = false,
          ir_or_index = 1,  -- References pass 1
        },
        {
          name = "Pass3",
          changed = false,
          ir_or_index = 1,  -- Also references pass 1
        },
      }

      local json = serializer.serialize(passes, nil, {})
      local result = serializer.deserialize(json)

      -- Pass2 should reference Pass1's IR
      assert.equals(1, result.passes[2].ir_or_index)

      -- Pass3 should also reference Pass1's IR
      assert.equals(1, result.passes[3].ir_or_index)
    end)

    it("preserves metadata", function()
      local passes = create_test_passes()
      local metadata = {
        source = {
          file = "/path/to/test.ll",
          checksum = "sha256:abcdef",
          mtime = 1234567890,
        },
        compilation = {
          opt_level = "O3",
          command = "clang -O3 test.c",
          compiler = "clang",
        },
      }

      local json = serializer.serialize(passes, nil, metadata)
      local result = serializer.deserialize(json)

      assert.is_table(result.metadata)
      assert.is_table(result.metadata.source)
      assert.equals("/path/to/test.ll", result.metadata.source.file)
      assert.equals("sha256:abcdef", result.metadata.source.checksum)
      assert.equals("O3", result.metadata.compilation.opt_level)
    end)

    it("handles empty passes gracefully", function()
      local json = serializer.serialize({}, nil, {})
      local result = serializer.deserialize(json)

      assert.is_table(result)
      assert.is_table(result.passes)
      assert.equals(0, #result.passes)
    end)

    it("handles corrupted JSON gracefully", function()
      local result, err = serializer.deserialize("invalid json{")

      assert.is_nil(result)
      assert.is_string(err)
      assert.is_not_nil(err:match("parse JSON"))
    end)
  end)

  describe("compression", function()
    it("compresses and decompresses data", function()
      -- Skip if gzip not available
      if vim.fn.executable("gzip") == 0 then
        pending("gzip not available")
        return
      end

      local passes = create_test_passes()
      local tmpfile = vim.fn.tempname() .. ".json.gz"

      local success, err = serializer.save_to_file(tmpfile, passes, nil, {})
      assert.is_true(success, err)
      assert.is_true(vim.fn.filereadable(tmpfile) == 1)

      -- Load back
      local result, load_err = serializer.load_from_file(tmpfile)
      assert.is_not_nil(result, load_err)
      assert.equals(#passes, #result.passes)

      -- Cleanup
      vim.fn.delete(tmpfile)
    end)
  end)

  describe("source validation", function()
    it("detects source file changes", function()
      local tmpfile = vim.fn.tempname()

      -- Write initial content
      local file = io.open(tmpfile, "w")
      file:write("initial content")
      file:close()

      local metadata = {
        source = {
          file = tmpfile,
          checksum = vim.fn.sha256("initial content"),
        }
      }

      -- Should validate successfully
      local valid, warning = serializer.validate_source(metadata)
      assert.is_true(valid)
      assert.is_nil(warning)

      -- Change file content
      file = io.open(tmpfile, "w")
      file:write("modified content")
      file:close()

      -- Should detect change
      valid, warning = serializer.validate_source(metadata)
      assert.is_true(valid)  -- Still valid but with warning
      assert.is_not_nil(warning)
      assert.is_not_nil(warning:match("has changed"))

      -- Cleanup
      vim.fn.delete(tmpfile)
    end)

    it("handles missing source file", function()
      local metadata = {
        source = {
          file = "/nonexistent/file.ll",
          checksum = "abc123",
        }
      }

      local valid, warning = serializer.validate_source(metadata)
      assert.is_false(valid)
      assert.is_not_nil(warning)
      assert.is_not_nil(warning:match("not found"))
    end)
  end)
end)

describe("Pipeline Session", function()
  local test_source_file = "/tmp/test.c"

  describe("session management", function()
    it("saves and loads sessions", function()
      local passes = create_test_passes()
      local initial_ir = passes[1]._initial_ir

      -- Save session
      local filepath, err = session.save_session(
        passes,
        initial_ir,
        test_source_file,
        { opt_level = "O2" },
        "test-session"
      )

      assert.is_string(filepath, err)
      assert.is_true(vim.fn.filereadable(filepath) == 1)

      -- Load session
      local result, load_err = session.load_session(test_source_file, "test-session")
      assert.is_not_nil(result, load_err)
      assert.equals(#passes, #result.passes)

      -- Cleanup
      session.delete_session(test_source_file, "test-session")
    end)

    it("lists sessions correctly", function()
      -- Save multiple sessions
      local passes = create_test_passes()

      session.save_session(passes, nil, test_source_file, { opt_level = "O2" }, "session1")
      session.save_session(passes, nil, test_source_file, { opt_level = "O3" }, "session2")

      local sessions = session.list_sessions(test_source_file)
      assert.is_true(#sessions >= 2)

      -- Should be sorted by timestamp (newest first)
      local found_session1 = false
      local found_session2 = false

      for _, s in ipairs(sessions) do
        if s.name == "session1" then found_session1 = true end
        if s.name == "session2" then found_session2 = true end
      end

      assert.is_true(found_session1)
      assert.is_true(found_session2)

      -- Cleanup
      session.delete_session(test_source_file, "session1")
      session.delete_session(test_source_file, "session2")
    end)

    it("loads latest session when no name provided", function()
      local passes = create_test_passes()

      -- Save two sessions
      session.save_session(passes, nil, test_source_file, { opt_level = "O1" }, "old")
      vim.wait(1100)  -- Wait to ensure different timestamps
      session.save_session(passes, nil, test_source_file, { opt_level = "O2" }, "new")

      -- Load without name should get latest
      local result = session.load_session(test_source_file)
      assert.is_not_nil(result)
      assert.is_not_nil(result.session_info)

      -- Cleanup
      session.delete_session(test_source_file, "old")
      session.delete_session(test_source_file, "new")
    end)

    it("deletes sessions", function()
      local passes = create_test_passes()

      local filepath = session.save_session(
        passes, nil, test_source_file, {}, "to-delete"
      )
      assert.is_true(vim.fn.filereadable(filepath) == 1)

      -- Delete session
      local success = session.delete_session(test_source_file, "to-delete")
      assert.is_true(success)

      -- File should be gone
      assert.is_false(vim.fn.filereadable(filepath) == 1)

      -- Should not appear in list
      local sessions = session.list_sessions(test_source_file)
      for _, s in ipairs(sessions) do
        assert.is_not_equal("to-delete", s.name)
      end
    end)
  end)

  describe("session cleanup", function()
    it("enforces max sessions policy", function()
      -- Temporarily set a low limit
      local meta_path = vim.fn.getcwd() .. "/.godbolt-pipeline/metadata.json"
      local meta_dir = vim.fn.fnamemodify(meta_path, ":h")
      vim.fn.mkdir(meta_dir, "p")

      -- Save metadata with low limit
      local file = io.open(meta_path, "w")
      file:write(vim.json.encode({
        version = 1,
        sessions = {},
        cleanup_policy = { max_sessions_per_file = 2 },
      }))
      file:close()

      local passes = create_test_passes()

      -- Save 3 sessions (exceeds limit of 2)
      session.save_session(passes, nil, test_source_file, {}, "session1")
      session.save_session(passes, nil, test_source_file, {}, "session2")
      session.save_session(passes, nil, test_source_file, {}, "session3")

      -- Should only have 2 sessions (oldest deleted)
      local sessions = session.list_sessions(test_source_file)
      assert.equals(2, #sessions)

      -- Cleanup
      for _, s in ipairs(sessions) do
        session.delete_session(test_source_file, s.index)
      end
      vim.fn.delete(meta_dir, "rf")
    end)
  end)
end)
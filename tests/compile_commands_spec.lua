local compile_commands = require('godbolt.compile_commands')

describe("compile_commands", function()
  describe("parse_compile_commands", function()
    it("should parse valid compile_commands.json", function()
      -- Create temporary compile_commands.json
      local temp_file = vim.fn.tempname() .. ".json"
      local content = vim.json.encode({
        {
          directory = "/path/to/project",
          command = "clang -c -o main.o main.c -O2 -std=c17",
          file = "main.c"
        },
        {
          directory = "/path/to/project",
          arguments = { "clang", "-c", "-o", "utils.o", "utils.c", "-O2" },
          file = "utils.c"
        }
      })
      vim.fn.writefile({ content }, temp_file)

      local success, data = compile_commands.parse_compile_commands(temp_file)

      assert.is_true(success)
      assert.is_table(data)
      assert.are.equal(2, #data)
      assert.are.equal("main.c", data[1].file)
      assert.are.equal("utils.c", data[2].file)

      vim.fn.delete(temp_file)
    end)

    it("should fail on missing file", function()
      local success, err = compile_commands.parse_compile_commands("/nonexistent/file.json")

      assert.is_false(success)
      assert.is_string(err)
    end)

    it("should fail on invalid JSON", function()
      local temp_file = vim.fn.tempname() .. ".json"
      vim.fn.writefile({ "not valid json {" }, temp_file)

      local success, err = compile_commands.parse_compile_commands(temp_file)

      assert.is_false(success)
      assert.is_string(err)

      vim.fn.delete(temp_file)
    end)
  end)

  describe("find_file_entry", function()
    it("should find file by absolute path", function()
      local data = {
        {
          directory = "/project",
          file = "/project/main.c",
          command = "clang -c main.c"
        },
        {
          directory = "/project",
          file = "/project/utils.c",
          command = "clang -c utils.c"
        }
      }

      local entry = compile_commands.find_file_entry(data, "/project/main.c")

      assert.is_not_nil(entry)
      assert.are.equal("/project/main.c", entry.file)
    end)

    it("should return nil for non-existent file", function()
      local data = {
        { directory = "/project", file = "main.c", command = "clang -c main.c" }
      }

      local entry = compile_commands.find_file_entry(data, "/nonexistent.c")

      assert.is_nil(entry)
    end)
  end)

  describe("parse_entry", function()
    it("should parse command string", function()
      local entry = {
        directory = "/project",
        file = "main.c",
        command = "clang -c -O2 -std=c17 main.c -o main.o"
      }

      local result = compile_commands.parse_entry(entry)

      assert.is_not_nil(result)
      assert.are.equal("clang", result.compiler)
      assert.are.equal("main.o", result.output_file)
      assert.is_true(vim.tbl_contains(result.args, "-O2"))
      assert.is_true(vim.tbl_contains(result.args, "-std=c17"))
    end)

    it("should parse arguments array", function()
      local entry = {
        directory = "/project",
        file = "main.c",
        arguments = { "clang++", "-c", "-O3", "-std=c++20", "main.cpp", "-o", "main.o" }
      }

      local result = compile_commands.parse_entry(entry)

      assert.is_not_nil(result)
      assert.are.equal("clang++", result.compiler)
      assert.are.equal("main.o", result.output_file)
      assert.is_true(vim.tbl_contains(result.args, "-O3"))
      assert.is_true(vim.tbl_contains(result.args, "-std=c++20"))
    end)

    it("should handle quoted arguments in command string", function()
      local entry = {
        directory = "/project",
        file = "main.c",
        command = 'clang -DFOO="bar baz" -c main.c'
      }

      local result = compile_commands.parse_entry(entry)

      assert.is_not_nil(result)
      assert.are.equal("clang", result.compiler)
    end)
  end)

  describe("get_all_source_files", function()
    it("should extract all source files", function()
      local data = {
        { directory = "/project", file = "main.c",    command = "clang -c main.c" },
        { directory = "/project", file = "utils.c",   command = "clang -c utils.c" },
        { directory = "/project", file = "helpers.c", command = "clang -c helpers.c" }
      }

      local files = compile_commands.get_all_source_files(data)

      assert.are.equal(3, #files)
    end)

    it("should handle empty compile_commands", function()
      local files = compile_commands.get_all_source_files({})

      assert.are.equal(0, #files)
    end)
  end)

  describe("filter_relevant_flags", function()
    it("should keep optimization and standard flags", function()
      local args = { "-c", "-O2", "-std=c++20", "-o", "main.o", "main.cpp" }

      local filtered = compile_commands.filter_relevant_flags(args)

      assert.is_true(vim.tbl_contains(filtered, "-O2"))
      assert.is_true(vim.tbl_contains(filtered, "-std=c++20"))
      assert.is_false(vim.tbl_contains(filtered, "-c"))
      assert.is_false(vim.tbl_contains(filtered, "-o"))
      assert.is_false(vim.tbl_contains(filtered, "main.o"))
      assert.is_false(vim.tbl_contains(filtered, "main.cpp"))
    end)

    it("should keep include paths and defines", function()
      local args = { "-I/usr/include", "-DFOO=bar", "-L/usr/lib", "-lpthread" }

      local filtered = compile_commands.filter_relevant_flags(args)

      assert.is_true(vim.tbl_contains(filtered, "-I/usr/include"))
      assert.is_true(vim.tbl_contains(filtered, "-DFOO=bar"))
      assert.is_false(vim.tbl_contains(filtered, "-L/usr/lib"))
      assert.is_false(vim.tbl_contains(filtered, "-lpthread"))
    end)

    it("should remove linking flags", function()
      local args = { "-O2", "-lm", "-lpthread", "-L/usr/local/lib", "-std=c17" }

      local filtered = compile_commands.filter_relevant_flags(args)

      assert.is_true(vim.tbl_contains(filtered, "-O2"))
      assert.is_true(vim.tbl_contains(filtered, "-std=c17"))
      assert.is_false(vim.tbl_contains(filtered, "-lm"))
      assert.is_false(vim.tbl_contains(filtered, "-lpthread"))
      assert.is_false(vim.tbl_contains(filtered, "-L/usr/local/lib"))
    end)
  end)
end)

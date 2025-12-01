-- Test suite for optimization remarks functionality
---@diagnostic disable: undefined-global
local remarks = require('godbolt.remarks')

describe("Remarks Module", function()

  describe("parse_remarks_yaml", function()
    it("returns empty table for non-existent file", function()
      local result = remarks.parse_remarks_yaml("nonexistent.yaml")
      assert(vim.tbl_isempty(result), "Should return empty table for non-existent file")
    end)

    it("parses comprehensive remarks file correctly", function()
      local result = remarks.parse_remarks_yaml("tests/fixtures/comprehensive_remarks.yaml")
      assert(result ~= nil, "Should return remarks table")
      assert(type(result) == "table", "Should return a table")
    end)

    it("maps inline pass to InlinerPass", function()
      local result = remarks.parse_remarks_yaml("tests/fixtures/comprehensive_remarks.yaml")
      assert(result["InlinerPass"] ~= nil, "Should have InlinerPass")
      assert(#result["InlinerPass"] == 3, "Should have 3 inline remarks")
    end)

    it("maps sroa pass to SROAPass", function()
      local result = remarks.parse_remarks_yaml("tests/fixtures/comprehensive_remarks.yaml")
      assert(result["SROAPass"] ~= nil, "Should have SROAPass")
      assert(#result["SROAPass"] == 1, "Should have 1 SROA remark")
    end)

    it("parses Passed remarks with correct category", function()
      local result = remarks.parse_remarks_yaml("tests/fixtures/comprehensive_remarks.yaml")
      local inline_remarks = result["InlinerPass"]

      assert(inline_remarks[1].category == "pass", "First remark should be 'pass'")
      assert(inline_remarks[1].message == "Inlined", "Message should be 'Inlined'")
    end)

    it("parses Missed remarks with correct category", function()
      local result = remarks.parse_remarks_yaml("tests/fixtures/comprehensive_remarks.yaml")
      local inline_remarks = result["InlinerPass"]

      assert(inline_remarks[3].category == "missed", "Third remark should be 'missed'")
      assert(inline_remarks[3].message == "NotInlined", "Message should be 'NotInlined'")
    end)

    it("parses Analysis remarks with correct category", function()
      local result = remarks.parse_remarks_yaml("tests/fixtures/comprehensive_remarks.yaml")
      local vectorize_remarks = result["LoopVectorizePass"]

      assert(vectorize_remarks ~= nil, "Should have LoopVectorizePass")
      assert(vectorize_remarks[1].category == "analysis", "Should be 'analysis' category")
    end)

    it("parses location information correctly", function()
      local result = remarks.parse_remarks_yaml("tests/fixtures/comprehensive_remarks.yaml")
      local inline_remark = result["InlinerPass"][1]

      assert(inline_remark.location ~= nil, "Should have location")
      assert(inline_remark.location.file == "/tmp/test.cpp", "Should parse file path")
      assert(inline_remark.location.line == 10, "Should parse line number")
      assert(inline_remark.location.column == 5, "Should parse column number")
    end)

    it("parses function name correctly", function()
      local result = remarks.parse_remarks_yaml("tests/fixtures/comprehensive_remarks.yaml")
      local inline_remark = result["InlinerPass"][1]

      assert(inline_remark.function_name == "compute", "Should parse function name")
    end)

    it("parses pass name correctly", function()
      local result = remarks.parse_remarks_yaml("tests/fixtures/comprehensive_remarks.yaml")
      local inline_remark = result["InlinerPass"][1]

      assert(inline_remark.pass_name == "inline", "Should parse pass name")
    end)

    it("parses Args array correctly", function()
      local result = remarks.parse_remarks_yaml("tests/fixtures/comprehensive_remarks.yaml")
      local inline_remark = result["InlinerPass"][1]

      assert(inline_remark.args ~= nil, "Should have args")
      assert(type(inline_remark.args) == "table", "Args should be a table")
      assert(#inline_remark.args > 0, "Should have at least one arg")
    end)

    it("parses specific Args correctly", function()
      local result = remarks.parse_remarks_yaml("tests/fixtures/comprehensive_remarks.yaml")
      local inline_remark = result["InlinerPass"][1]

      -- Find Callee arg
      local callee_arg = nil
      for _, arg in ipairs(inline_remark.args) do
        if arg.key == "Callee" then
          callee_arg = arg
          break
        end
      end

      assert(callee_arg ~= nil, "Should have Callee arg")
      assert(callee_arg.value == "add", "Callee should be 'add'")
    end)

    it("handles missing fields gracefully", function()
      -- Test with minimal YAML that only has required fields
      local result = remarks.parse_remarks_yaml("tests/fixtures/sample_remarks.yaml")
      assert(result ~= nil, "Should handle minimal YAML")
      assert(type(result) == "table", "Should return a table")
    end)
  end)

  describe("attach_remarks_to_passes", function()
    it("returns passes unchanged if remarks_by_pass is nil", function()
      local passes = {{name = "TestPass"}}
      local result = remarks.attach_remarks_to_passes(passes, nil)
      assert(result == passes, "Should return same passes")
    end)

    it("returns passes unchanged if passes is nil", function()
      local result = remarks.attach_remarks_to_passes(nil, {})
      assert(result == nil, "Should return nil")
    end)

    it("attaches remarks to matching pass names", function()
      local passes = {
        {name = "InlinerPass on foo"},
        {name = "SROAPass on bar"},
      }
      local remarks_by_pass = {
        InlinerPass = {{category = "pass", message = "Inlined"}},
        SROAPass = {{category = "pass", message = "ScalarReplaced"}},
      }

      local result = remarks.attach_remarks_to_passes(passes, remarks_by_pass)

      assert(result[1].remarks ~= nil, "First pass should have remarks")
      assert(#result[1].remarks == 1, "First pass should have 1 remark")
      assert(result[2].remarks ~= nil, "Second pass should have remarks")
      assert(#result[2].remarks == 1, "Second pass should have 1 remark")
    end)

    it("handles passes without matching remarks", function()
      local passes = {
        {name = "UnknownPass on foo"},
      }
      local remarks_by_pass = {
        InlinerPass = {{category = "pass", message = "Inlined"}},
      }

      local result = remarks.attach_remarks_to_passes(passes, remarks_by_pass)

      assert(result[1].remarks ~= nil, "Should have remarks field")
      assert(#result[1].remarks == 0, "Should have empty remarks array")
    end)

    it("extracts base pass name correctly", function()
      local passes = {
        {name = "InlinerPass on (foo)"},  -- CGSCC format
        {name = "SROAPass on bar"},       -- Function format
        {name = "ModulePass on [module]"}, -- Module format
      }
      local remarks_by_pass = {
        InlinerPass = {{category = "pass", message = "Inlined"}},
        SROAPass = {{category = "pass", message = "ScalarReplaced"}},
        ModulePass = {{category = "pass", message = "Optimized"}},
      }

      local result = remarks.attach_remarks_to_passes(passes, remarks_by_pass)

      assert(#result[1].remarks == 1, "CGSCC pass should have remarks")
      assert(#result[2].remarks == 1, "Function pass should have remarks")
      assert(#result[3].remarks == 1, "Module pass should have remarks")
    end)
  end)

  describe("get_remarks_file_path", function()
    it("returns a valid file path", function()
      local path = remarks.get_remarks_file_path("/tmp/test.cpp")
      assert(type(path) == "string", "Should return a string")
      assert(path:match("%.yaml$"), "Path should end with .yaml")
    end)

    it("includes source filename in path", function()
      local path = remarks.get_remarks_file_path("/tmp/test.cpp")
      assert(path:match("test%-remarks"), "Path should include source filename")
    end)

    it("includes PID in path for uniqueness", function()
      local path = remarks.get_remarks_file_path("/tmp/test.cpp")
      local pid = tostring(vim.fn.getpid())
      assert(path:match(pid), "Path should include PID")
    end)

    it("creates parent directory", function()
      local path = remarks.get_remarks_file_path("/tmp/test.cpp")
      local parent = vim.fn.fnamemodify(path, ":h")
      assert(vim.fn.isdirectory(parent) == 1, "Parent directory should exist")
    end)
  end)

  describe("cleanup_remarks_file", function()
    it("deletes existing remarks file", function()
      -- Create a temp file
      local temp_file = vim.fn.tempname() .. ".yaml"
      vim.fn.writefile({"test"}, temp_file)
      assert(vim.fn.filereadable(temp_file) == 1, "Temp file should exist")

      -- Cleanup
      remarks.cleanup_remarks_file(temp_file)

      assert(vim.fn.filereadable(temp_file) == 0, "File should be deleted")
    end)

    it("handles non-existent file gracefully", function()
      -- Should not error
      local ok = pcall(remarks.cleanup_remarks_file, "/nonexistent/path.yaml")
      assert(ok, "Should not error on non-existent file")
    end)

    it("handles nil argument gracefully", function()
      local ok = pcall(remarks.cleanup_remarks_file, nil)
      assert(ok, "Should not error on nil argument")
    end)
  end)
end)

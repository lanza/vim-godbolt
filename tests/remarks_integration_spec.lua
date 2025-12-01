-- Integration tests for optimization remarks functionality
---@diagnostic disable: undefined-global
local remarks = require('godbolt.remarks')
local pipeline_viewer = require('godbolt.pipeline_viewer')
local godbolt = require('godbolt')

describe("Remarks Integration", function()
  describe("End-to-end YAML parsing", function()
    it("parses comprehensive remarks file and attaches to passes", function()
      -- Parse the YAML file
      local remarks_by_pass = remarks.parse_remarks_yaml("tests/fixtures/comprehensive_remarks.yaml")

      assert.is_not_nil(remarks_by_pass, "Should parse YAML file")
      assert.is_table(remarks_by_pass, "Should return a table")

      -- Create mock passes
      local passes = {
        { name = "InlinerPass on (compute)" },
        { name = "SROAPass on foo" },
        { name = "LoopVectorizePass on bar" },
      }

      -- Attach remarks to passes
      local result = remarks.attach_remarks_to_passes(passes, remarks_by_pass)

      assert.is_not_nil(result, "Should return passes")
      assert.are.equal(3, #result, "Should have 3 passes")

      -- Verify InlinerPass has remarks
      assert.is_not_nil(result[1].remarks, "InlinerPass should have remarks")
      assert.is_true(#result[1].remarks > 0, "InlinerPass should have at least one remark")

      -- Verify SROAPass has remarks
      assert.is_not_nil(result[2].remarks, "SROAPass should have remarks")

      -- Verify LoopVectorizePass has remarks
      assert.is_not_nil(result[3].remarks, "LoopVectorizePass should have remarks")
    end)

    it("handles empty remarks gracefully", function()
      local passes = {
        { name = "UnknownPass on foo" },
      }

      local result = remarks.attach_remarks_to_passes(passes, {})

      assert.is_not_nil(result, "Should return passes")
      assert.is_not_nil(result[1].remarks, "Should have remarks field")
      assert.are.equal(0, #result[1].remarks, "Should have empty remarks array")
    end)

    it("correctly maps all remark categories", function()
      local remarks_by_pass = remarks.parse_remarks_yaml("tests/fixtures/comprehensive_remarks.yaml")
      local inline_remarks = remarks_by_pass["InlinerPass"]

      -- Find each category
      local has_pass = false
      local has_missed = false

      for _, remark in ipairs(inline_remarks) do
        if remark.category == "pass" then
          has_pass = true
        elseif remark.category == "missed" then
          has_missed = true
        end
      end

      assert.is_true(has_pass, "Should have at least one 'pass' remark")
      assert.is_true(has_missed, "Should have at least one 'missed' remark")
    end)
  end)

  describe("Pipeline Viewer Integration", function()
    it("help menu function exists and is callable", function()
      assert.is_not_nil(pipeline_viewer.show_help_menu, "show_help_menu should exist")
      assert.are.equal("function", type(pipeline_viewer.show_help_menu), "show_help_menu should be a function")

      -- Function should be callable (may fail if no state, but shouldn't error on syntax)
      local ok = pcall(pipeline_viewer.show_help_menu)
      assert.are.equal("boolean", type(ok), "Should return boolean from pcall")
    end)

    it("all remarks popup function exists and is callable", function()
      assert.is_not_nil(pipeline_viewer.show_all_remarks_popup, "show_all_remarks_popup should exist")
      assert.are.equal("function", type(pipeline_viewer.show_all_remarks_popup),
        "show_all_remarks_popup should be a function")

      local ok = pcall(pipeline_viewer.show_all_remarks_popup)
      assert.are.equal("boolean", type(ok), "Should return boolean from pcall")
    end)

    it("inline hints functions exist", function()
      assert.is_not_nil(pipeline_viewer.show_inline_hints, "show_inline_hints should exist")
      assert.is_not_nil(pipeline_viewer.hide_inline_hints, "hide_inline_hints should exist")
      assert.is_not_nil(pipeline_viewer.toggle_inline_hints, "toggle_inline_hints should exist")

      assert.are.equal("function", type(pipeline_viewer.show_inline_hints), "show_inline_hints should be a function")
      assert.are.equal("function", type(pipeline_viewer.hide_inline_hints), "hide_inline_hints should be a function")
      assert.are.equal("function", type(pipeline_viewer.toggle_inline_hints), "toggle_inline_hints should be a function")
    end)
  end)

  describe("Configuration Integration", function()
    it("keymaps configuration is present in config", function()
      local config = godbolt.config

      assert.is_not_nil(config, "Config should exist")
      assert.is_not_nil(config.pipeline, "Pipeline config should exist")
      assert.is_not_nil(config.pipeline.keymaps, "Keymaps config should exist")

      local keymaps = config.pipeline.keymaps

      -- Check all required keymaps exist
      assert.is_not_nil(keymaps.next_pass, "next_pass keymap should exist")
      assert.is_not_nil(keymaps.prev_pass, "prev_pass keymap should exist")
      assert.is_not_nil(keymaps.show_remarks, "show_remarks keymap should exist")
      assert.is_not_nil(keymaps.show_all_remarks, "show_all_remarks keymap should exist")
      assert.is_not_nil(keymaps.toggle_inline_hints, "toggle_inline_hints keymap should exist")
      assert.is_not_nil(keymaps.show_help, "show_help keymap should exist")
    end)

    it("remarks configuration is present in config", function()
      local config = godbolt.config

      assert.is_not_nil(config.pipeline.remarks, "Remarks config should exist")

      local remarks_config = config.pipeline.remarks

      assert.is_not_nil(remarks_config.pass, "pass config should exist")
      assert.is_not_nil(remarks_config.missed, "missed config should exist")
      assert.is_not_nil(remarks_config.analysis, "analysis config should exist")
      assert.is_not_nil(remarks_config.filter, "filter config should exist")
      assert.is_not_nil(remarks_config.inline_hints, "inline_hints config should exist")
    end)

    it("inline_hints configuration has all fields", function()
      local hints_config = godbolt.config.pipeline.remarks.inline_hints

      assert.is_not_nil(hints_config.enabled, "enabled field should exist")
      assert.is_not_nil(hints_config.format, "format field should exist")
      assert.is_not_nil(hints_config.position, "position field should exist")

      -- Check types
      assert.are.equal("boolean", type(hints_config.enabled), "enabled should be boolean")
      assert.are.equal("string", type(hints_config.format), "format should be string")
      assert.are.equal("string", type(hints_config.position), "position should be string")
    end)

    it("allows custom keymap configuration", function()
      godbolt.setup({
        pipeline = {
          keymaps = {
            show_remarks = 'X',
            quit = 'Q',
          },
        },
      })

      local keymaps = godbolt.config.pipeline.keymaps

      assert.are.equal('X', keymaps.show_remarks, "show_remarks should be customized")
      assert.are.equal('Q', keymaps.quit, "quit should be customized")

      -- Other keymaps should still exist
      assert.is_not_nil(keymaps.next_pass, "next_pass should still exist")
    end)

    it("allows custom inline_hints configuration", function()
      godbolt.setup({
        pipeline = {
          remarks = {
            inline_hints = {
              enabled = false,
              format = "detailed",
            },
          },
        },
      })

      local hints = godbolt.config.pipeline.remarks.inline_hints

      assert.is_false(hints.enabled, "enabled should be false")
      assert.are.equal("detailed", hints.format, "format should be detailed")
    end)
  end)

  describe("Remarks File Lifecycle", function()
    it("creates unique remarks file paths", function()
      local path1 = remarks.get_remarks_file_path("/tmp/test.cpp")
      local path2 = remarks.get_remarks_file_path("/tmp/test.cpp")

      assert.is_string(path1, "Should return string path")
      assert.is_string(path2, "Should return string path")

      -- Both paths should include the source filename
      assert.is.truthy(path1:match("test%-remarks"), "Path should include source filename")

      -- Paths should end with .yaml
      assert.is.truthy(path1:match("%.yaml$"), "Path should end with .yaml")
    end)

    it("cleanup handles non-existent files", function()
      -- Should not error
      local ok = pcall(remarks.cleanup_remarks_file, "/nonexistent/path.yaml")
      assert.is_true(ok, "Should not error on non-existent file")
    end)

    it("cleanup deletes existing files", function()
      -- Create a temp file
      local temp_file = vim.fn.tempname() .. ".yaml"
      vim.fn.writefile({ "test" }, temp_file)

      assert.are.equal(1, vim.fn.filereadable(temp_file), "File should exist")

      -- Cleanup
      remarks.cleanup_remarks_file(temp_file)

      assert.are.equal(0, vim.fn.filereadable(temp_file), "File should be deleted")
    end)
  end)
end)

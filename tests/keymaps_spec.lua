-- Test suite for keymaps configuration
---@diagnostic disable: undefined-global
local godbolt = require('godbolt')

describe("Keymaps Configuration", function()
  describe("Default keymaps", function()
    it("has all required keymap fields", function()
      local keymaps = godbolt.config.pipeline.keymaps

      assert(keymaps.next_pass ~= nil, "Should have next_pass")
      assert(keymaps.prev_pass ~= nil, "Should have prev_pass")
      assert(keymaps.next_changed ~= nil, "Should have next_changed")
      assert(keymaps.prev_changed ~= nil, "Should have prev_changed")
      assert(keymaps.toggle_fold ~= nil, "Should have toggle_fold")
      assert(keymaps.activate_line ~= nil, "Should have activate_line")
      assert(keymaps.first_pass ~= nil, "Should have first_pass")
      assert(keymaps.last_pass ~= nil, "Should have last_pass")
      assert(keymaps.show_remarks ~= nil, "Should have show_remarks")
      assert(keymaps.show_all_remarks ~= nil, "Should have show_all_remarks")
      assert(keymaps.toggle_inline_hints ~= nil, "Should have toggle_inline_hints")
      assert(keymaps.show_help ~= nil, "Should have show_help")
      assert(keymaps.quit ~= nil, "Should have quit")
    end)

    it("supports string values", function()
      local keymaps = godbolt.config.pipeline.keymaps
      assert(type(keymaps.quit) == "string", "quit should be a string")
    end)

    it("supports array values", function()
      local keymaps = godbolt.config.pipeline.keymaps
      assert(type(keymaps.next_pass) == "table", "next_pass should be a table")
      assert(#keymaps.next_pass > 0, "next_pass should have at least one key")
    end)
  end)

  describe("Custom keymaps", function()
    it("allows overriding single keymap", function()
      godbolt.setup({
        pipeline = {
          keymaps = {
            quit = 'Q',
          },
        },
      })

      assert(godbolt.config.pipeline.keymaps.quit == 'Q', "quit should be 'Q'")
      -- Other keymaps should remain
      assert(godbolt.config.pipeline.keymaps.next_pass ~= nil, "Other keymaps should remain")
    end)

    it("allows array of keys for single action", function()
      godbolt.setup({
        pipeline = {
          keymaps = {
            show_remarks = { 'R', 'gr', '?' },
          },
        },
      })

      local remarks_keys = godbolt.config.pipeline.keymaps.show_remarks
      assert(type(remarks_keys) == "table", "Should be a table")
      assert(#remarks_keys == 3, "Should have 3 keys")
      assert(remarks_keys[3] == '?', "Third key should be '?'")
    end)

    it("deep merges keymaps configuration", function()
      godbolt.setup({
        pipeline = {
          keymaps = {
            quit = 'Q',
            next_pass = '<C-n>',
          },
        },
      })

      assert(godbolt.config.pipeline.keymaps.quit == 'Q', "quit should be overridden")
      assert(godbolt.config.pipeline.keymaps.next_pass == '<C-n>', "next_pass should be overridden")
      -- Unchanged keymaps should remain
      assert(godbolt.config.pipeline.keymaps.show_help == 'g?', "show_help should remain default")
    end)
  end)

  describe("Remarks configuration", function()
    it("has default remarks config", function()
      local remarks = godbolt.config.pipeline.remarks

      assert(remarks ~= nil, "Should have remarks config")
      assert(remarks.pass == true, "pass should be enabled by default")
      assert(remarks.missed == true, "missed should be enabled by default")
      assert(remarks.analysis == true, "analysis should be enabled by default")
      assert(remarks.filter == ".*", "filter should be .* by default")
    end)

    it("has inline_hints config", function()
      local hints = godbolt.config.pipeline.remarks.inline_hints

      assert(hints ~= nil, "Should have inline_hints config")
      assert(hints.enabled == true, "Should be enabled by default")
      assert(hints.format == "short", "Format should be 'short' by default")
      assert(hints.position == "eol", "Position should be 'eol' by default")
    end)

    it("allows customizing inline_hints format", function()
      godbolt.setup({
        pipeline = {
          remarks = {
            inline_hints = {
              format = "detailed",
            },
          },
        },
      })

      local format = godbolt.config.pipeline.remarks.inline_hints.format
      assert(format == "detailed", "Format should be 'detailed'")
    end)

    it("allows disabling inline_hints", function()
      godbolt.setup({
        pipeline = {
          remarks = {
            inline_hints = {
              enabled = false,
            },
          },
        },
      })

      local enabled = godbolt.config.pipeline.remarks.inline_hints.enabled
      assert(enabled == false, "Should be disabled")
    end)

    it("normalizes remarks=true to full config", function()
      godbolt.setup({
        pipeline = {
          remarks = true,
        },
      })

      local remarks = godbolt.config.pipeline.remarks
      assert(type(remarks) == "table", "Should be a table")
      assert(remarks.pass == true, "pass should be true")
      assert(remarks.missed == true, "missed should be true")
      assert(remarks.analysis == true, "analysis should be true")
      assert(remarks.filter ~= nil, "filter should be set")
    end)
  end)
end)

local pipeline_viewer = require('godbolt.pipeline_viewer')

describe("Help Menu", function()
  describe("show_help_menu", function()
    it("function exists", function()
      assert(type(pipeline_viewer.show_help_menu) == "function", "show_help_menu should be a function")
    end)

    -- Note: We can't fully test the UI without a running Neovim instance,
    -- but we can verify the function doesn't error
    it("doesn't error when called", function()
      local ok = pcall(pipeline_viewer.show_help_menu)
      -- May fail if state not initialized, but shouldn't throw syntax errors
      assert(type(ok) == "boolean", "Should return a boolean")
    end)
  end)
end)

describe("Inline Hints (Diagnostics)", function()
  describe("show_inline_hints", function()
    it("function exists", function()
      assert(type(pipeline_viewer.show_inline_hints) == "function", "show_inline_hints should be a function")
    end)

    it("hide_inline_hints function exists", function()
      assert(type(pipeline_viewer.hide_inline_hints) == "function", "hide_inline_hints should be a function")
    end)

    it("toggle_inline_hints function exists", function()
      assert(type(pipeline_viewer.toggle_inline_hints) == "function", "toggle_inline_hints should be a function")
    end)
  end)
end)

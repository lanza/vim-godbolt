---@diagnostic disable: undefined-global
local pipeline_viewer = require('godbolt.pipeline_viewer')
local pipeline = require('godbolt.pipeline')
local godbolt = require('godbolt')

describe("Pipeline Viewer selective metadata filtering", function()
  it("removes debug metadata but preserves PGO metadata (default config)", function()
    -- Verify default config
    assert.is_true(godbolt.config.display.strip_debug_metadata,
      "Default config should filter debug metadata")

    -- Create mock state with both debug and PGO metadata
    local test_ir = {
      "; ModuleID = 'test.ll'",
      "define i32 @test(i32 %x) !dbg !10 !prof !20 {",
      "  %cmp = icmp sgt i32 %x, 0, !dbg !11",
      "  br i1 %cmp, label %if.then, label %if.else, !dbg !12, !prof !21",
      "}",
      "!llvm.dbg.cu = !{!0}",
      "!llvm.module.flags = !{!2, !3}",
      "!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1)",
      "!1 = !DIFile(filename: \"test.c\", directory: \"/tmp\")",
      "!10 = distinct !DISubprogram(name: \"test\", scope: !1, file: !1, line: 1)",
      "!11 = !DILocation(line: 2, column: 7, scope: !10)",
      "!12 = !DILocation(line: 2, column: 3, scope: !10)",
      "!20 = !{!\"function_entry_count\", i64 100000}",
      "!21 = !{!\"branch_weights\", i32 90000, i32 10000}",
    }

    pipeline_viewer.state = {
      config = godbolt.config,
      passes = {
        {
          name = "TestPass",
          ir = test_ir,
          changed = true,
        }
      },
      initial_ir = test_ir,
      current_index = 1,
    }

    -- Get the IR that would be displayed
    local after_ir = pipeline_viewer.state.passes[1].ir

    -- Apply the same filtering that display_pass does
    if pipeline_viewer.state.config and
       pipeline_viewer.state.config.display and
       pipeline_viewer.state.config.display.strip_debug_metadata then
      local ir_utils = require('godbolt.ir_utils')
      after_ir = select(1, ir_utils.filter_debug_metadata(after_ir))
    end

    -- Convert to text for checking
    local after_text = table.concat(after_ir, "\n")

    -- Verify debug metadata is REMOVED
    assert.is_nil(after_text:match("!dbg"),
      "Should filter !dbg debug metadata references")
    assert.is_nil(after_text:match("!DILocation"),
      "Should filter !DILocation debug metadata definitions")
    assert.is_nil(after_text:match("!DISubprogram"),
      "Should filter !DISubprogram debug metadata definitions")
    assert.is_nil(after_text:match("!llvm%.dbg%.cu"),
      "Should filter !llvm.dbg.cu debug module metadata")

    -- Verify PGO metadata is PRESERVED
    assert.is_not_nil(after_text:match("!prof"),
      "Should preserve !prof PGO metadata references")
    assert.is_not_nil(after_text:match("function_entry_count"),
      "Should preserve PGO function_entry_count metadata")
    assert.is_not_nil(after_text:match("branch_weights"),
      "Should preserve PGO branch_weights metadata")

    -- Verify other important metadata is preserved
    assert.is_not_nil(after_text:match("!llvm%.module%.flags"),
      "Should preserve !llvm.module.flags metadata")
  end)

  it("shows all metadata when strip_debug_metadata = false", function()
    -- Create custom config with filtering disabled
    local custom_config = vim.deepcopy(godbolt.config)
    custom_config.display.strip_debug_metadata = false

    local test_ir = {
      "; ModuleID = 'test.ll'",
      "define i32 @test(i32 %x) !dbg !10 !prof !20 {",
      "  %cmp = icmp sgt i32 %x, 0, !dbg !11",
      "}",
      "!10 = distinct !DISubprogram(name: \"test\")",
      "!11 = !DILocation(line: 2, column: 7)",
      "!20 = !{!\"function_entry_count\", i64 100000}",
    }

    pipeline_viewer.state = {
      config = custom_config,
      passes = {
        {
          name = "TestPass",
          ir = test_ir,
          changed = true,
        }
      },
      initial_ir = test_ir,
      current_index = 1,
    }

    local after_ir = pipeline_viewer.state.passes[1].ir

    -- Apply filtering (should be a no-op since disabled)
    if pipeline_viewer.state.config and
       pipeline_viewer.state.config.display and
       pipeline_viewer.state.config.display.strip_debug_metadata then
      local ir_utils = require('godbolt.ir_utils')
      after_ir = select(1, ir_utils.filter_debug_metadata(after_ir))
    end

    local after_text = table.concat(after_ir, "\n")

    -- Verify ALL metadata is present when filtering is disabled
    assert.is_not_nil(after_text:match("!dbg"),
      "Should show !dbg when filtering is disabled")
    assert.is_not_nil(after_text:match("!DILocation"),
      "Should show !DILocation when filtering is disabled")
    assert.is_not_nil(after_text:match("!prof"),
      "Should show !prof when filtering is disabled")
  end)
end)

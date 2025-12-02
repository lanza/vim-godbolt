---@diagnostic disable: undefined-global
local ir_utils = require('godbolt.ir_utils')

describe("Selective debug metadata filtering", function()
  it("removes debug metadata but preserves PGO and other metadata", function()
    local input_ir = {
      "; ModuleID = 'test.ll'",
      "source_filename = \"test.c\"",
      "target datalayout = \"e-m:o-i64:64\"",
      "",
      "define i32 @test(i32 %x) !dbg !10 !prof !20 {",
      "entry:",
      "  %cmp = icmp sgt i32 %x, 0, !dbg !11",
      "  br i1 %cmp, label %if.then, label %if.else, !dbg !12, !prof !21, !tbaa !30",
      "",
      "if.then:",
      "  %add = add i32 %x, 1, !dbg !13",
      "  ret i32 %add, !dbg !14",
      "",
      "if.else:",
      "  %sub = sub i32 %x, 1, !dbg !15",
      "  ret i32 %sub, !dbg !16",
      "}",
      "",
      "; Debug module metadata (should be removed)",
      "!llvm.dbg.cu = !{!0}",
      "!llvm.module.flags = !{!2, !3}",
      "",
      "; Debug metadata definitions (should be removed)",
      "!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1)",
      "!1 = !DIFile(filename: \"test.c\", directory: \"/tmp\")",
      "!10 = distinct !DISubprogram(name: \"test\", scope: !1, file: !1, line: 1)",
      "!11 = !DILocation(line: 2, column: 7, scope: !10)",
      "!12 = !DILocation(line: 2, column: 3, scope: !10)",
      "!13 = !DILocation(line: 3, column: 12, scope: !10)",
      "!14 = !DILocation(line: 3, column: 5, scope: !10)",
      "!15 = !DILocation(line: 5, column: 12, scope: !10)",
      "!16 = !DILocation(line: 5, column: 5, scope: !10)",
      "",
      "; Module flags (should be preserved)",
      "!2 = !{i32 2, !\"Dwarf Version\", i32 4}",
      "!3 = !{i32 2, !\"Debug Info Version\", i32 3}",
      "",
      "; PGO metadata (should be preserved)",
      "!20 = !{!\"function_entry_count\", i64 100000}",
      "!21 = !{!\"branch_weights\", i32 90000, i32 10000}",
      "",
      "; TBAA metadata (should be preserved)",
      "!30 = !{!\"int\", !31, i64 0}",
      "!31 = !{!\"omnipotent char\", !32, i64 0}",
      "!32 = !{!\"Simple C/C++ TBAA\"}",
    }

    local filtered_ir, line_map = ir_utils.filter_debug_metadata(input_ir)
    local filtered_text = table.concat(filtered_ir, "\n")

    -- Verify module-level metadata is preserved
    assert.is_not_nil(filtered_text:match("ModuleID"),
      "Should preserve ModuleID")
    assert.is_not_nil(filtered_text:match("source_filename"),
      "Should preserve source_filename")
    assert.is_not_nil(filtered_text:match("target datalayout"),
      "Should preserve target datalayout")

    -- Verify debug metadata references are removed
    assert.is_nil(filtered_text:match("!dbg"),
      "Should remove !dbg references")

    -- Verify debug metadata definitions are removed
    assert.is_nil(filtered_text:match("!DICompileUnit"),
      "Should remove !DICompileUnit")
    assert.is_nil(filtered_text:match("!DIFile"),
      "Should remove !DIFile")
    assert.is_nil(filtered_text:match("!DISubprogram"),
      "Should remove !DISubprogram")
    assert.is_nil(filtered_text:match("!DILocation"),
      "Should remove !DILocation")

    -- Verify debug module metadata is removed
    assert.is_nil(filtered_text:match("!llvm%.dbg%.cu"),
      "Should remove !llvm.dbg.cu")

    -- Verify PGO metadata is preserved
    assert.is_not_nil(filtered_text:match("!prof !20"),
      "Should preserve !prof references")
    assert.is_not_nil(filtered_text:match("!prof !21"),
      "Should preserve !prof references on branches")
    assert.is_not_nil(filtered_text:match("function_entry_count"),
      "Should preserve function_entry_count definition")
    assert.is_not_nil(filtered_text:match("branch_weights"),
      "Should preserve branch_weights definition")

    -- Verify TBAA metadata is preserved
    assert.is_not_nil(filtered_text:match("!tbaa"),
      "Should preserve !tbaa references")
    assert.is_not_nil(filtered_text:match("omnipotent char"),
      "Should preserve TBAA metadata definitions")

    -- Verify module flags are preserved
    assert.is_not_nil(filtered_text:match("!llvm%.module%.flags"),
      "Should preserve !llvm.module.flags")
    assert.is_not_nil(filtered_text:match("Dwarf Version"),
      "Should preserve module flag definitions")

    -- Verify line mapping is correct
    assert.is_not_nil(line_map, "Should return line_map")
    assert.is_true(#line_map > 0, "line_map should not be empty")
  end)

  it("preserves all metadata when nothing to filter", function()
    local input_ir = {
      "define i32 @test(i32 %x) !prof !20 {",
      "  ret i32 %x",
      "}",
      "!20 = !{!\"function_entry_count\", i64 100000}",
    }

    local filtered_ir = ir_utils.filter_debug_metadata(input_ir)
    local filtered_text = table.concat(filtered_ir, "\n")

    -- Should be identical since there's no debug metadata
    assert.is_not_nil(filtered_text:match("!prof"),
      "Should preserve !prof")
    assert.is_not_nil(filtered_text:match("function_entry_count"),
      "Should preserve PGO metadata")
  end)
end)

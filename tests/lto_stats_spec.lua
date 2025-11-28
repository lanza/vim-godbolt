local lto_stats = require('godbolt.lto_stats')

describe("lto_stats", function()
  describe("parse_di_files", function()
    it("should parse DIFile metadata", function()
      local ir_lines = {
        '!1 = !DIFile(filename: "main.c", directory: "/path/to/project")',
        '!2 = !DIFile(filename: "utils.c", directory: "/path/to/project")',
        '!3 = !DIFile(filename: "helpers.c", directory: "/other/path")',
      }

      local file_map = lto_stats.parse_di_files(ir_lines)

      assert.are.equal("main.c", file_map["!1"].filename)
      assert.are.equal("/path/to/project", file_map["!1"].directory)
      assert.are.equal("utils.c", file_map["!2"].filename)
      assert.are.equal("helpers.c", file_map["!3"].filename)
      assert.are.equal("/other/path", file_map["!3"].directory)
    end)

    it("should handle empty input", function()
      local file_map = lto_stats.parse_di_files({})
      assert.are.same({}, file_map)
    end)
  end)

  describe("parse_function_sources", function()
    it("should map functions to source files", function()
      local ir_lines = {
        'define i32 @main() !dbg !10 {',
        'define i32 @add(i32, i32) !dbg !20 {',
        '!10 = distinct !DISubprogram(name: "main", file: !1, line: 5)',
        '!20 = distinct !DISubprogram(name: "add", file: !2, line: 10)',
      }

      local file_map = {
        ["!1"] = {filename = "main.c", directory = "/path"},
        ["!2"] = {filename = "utils.c", directory = "/path"},
      }

      local func_sources = lto_stats.parse_function_sources(ir_lines, file_map)

      assert.are.equal("main.c", func_sources["main"].filename)
      assert.are.equal("utils.c", func_sources["add"].filename)
    end)
  end)

  describe("detect_cross_module_inlining", function()
    it("should detect inlined cross-module calls", function()
      local before_ir = {
        'define i32 @main() {',
        '  %1 = call i32 @add(i32 1, i32 2)',  -- Cross-module call
        '  %2 = call i32 @multiply(i32 %1, i32 3)',  -- Another cross-module call
        '  ret i32 %2',
        '}',
        'declare i32 @add(i32, i32)',
        'declare i32 @multiply(i32, i32)',
      }

      local after_ir = {
        'define i32 @main() {',
        '  %1 = add i32 1, 2',  -- Inlined!
        '  %2 = call i32 @multiply(i32 %1, i32 3)',  -- Not inlined
        '  ret i32 %2',
        '}',
      }

      local func_sources = {
        ["main"] = {filename = "main.c"},
        ["add"] = {filename = "utils.c"},
        ["multiply"] = {filename = "utils.c"},
      }

      local stats = lto_stats.detect_cross_module_inlining(before_ir, after_ir, func_sources)

      assert.are.equal(2, stats.total_calls_before)
      assert.are.equal(1, stats.total_calls_after)
      assert.are.equal(1, stats.inlined_count)
      assert.are.equal(2, stats.cross_module_calls_before)
      assert.are.equal(1, stats.cross_module_calls_after)
    end)

    it("should track inlines by file", function()
      local before_ir = {
        'define i32 @main() {',
        '  %1 = call i32 @add(i32 1, i32 2)',
        '  %2 = call i32 @multiply(i32 %1, i32 3)',
        '  ret i32 %2',
        '}',
      }

      local after_ir = {
        'define i32 @main() {',
        '  %1 = add i32 1, 2',  -- Both inlined
        '  %2 = mul i32 %1, 3',
        '  ret i32 %2',
        '}',
      }

      local func_sources = {
        ["main"] = {filename = "main.c"},
        ["add"] = {filename = "utils.c"},
        ["multiply"] = {filename = "math.c"},
      }

      local stats = lto_stats.detect_cross_module_inlining(before_ir, after_ir, func_sources)

      assert.is_not_nil(stats.inlines_by_file["main.c"])
      assert.are.equal(2, stats.inlines_by_file["main.c"].count)
      assert.is_true(vim.tbl_contains(stats.inlines_by_file["main.c"].targets, "utils.c"))
      assert.is_true(vim.tbl_contains(stats.inlines_by_file["main.c"].targets, "math.c"))
    end)

    it("should skip LLVM intrinsics", function()
      local before_ir = {
        'define i32 @main() {',
        '  call void @llvm.dbg.declare(metadata ptr %x)',
        '  %1 = call i32 @add(i32 1, i32 2)',
        '  ret i32 %1',
        '}',
      }

      local after_ir = {
        'define i32 @main() {',
        '  call void @llvm.dbg.declare(metadata ptr %x)',
        '  %1 = add i32 1, 2',
        '  ret i32 %1',
        '}',
      }

      local func_sources = {
        ["main"] = {filename = "main.c"},
        ["add"] = {filename = "utils.c"},
      }

      local stats = lto_stats.detect_cross_module_inlining(before_ir, after_ir, func_sources)

      -- Should only count the 'add' call, not llvm.dbg.declare
      assert.are.equal(1, stats.total_calls_before)
      assert.are.equal(0, stats.total_calls_after)
    end)
  end)

  describe("track_dead_code_elimination", function()
    it("should detect removed functions", function()
      local before_ir = {
        'define i32 @main() {',
        '}',
        'define i32 @add(i32, i32) {',
        '}',
        'define i32 @unused_helper() {',
        '}',
      }

      local after_ir = {
        'define i32 @main() {',
        '}',
      }

      local func_sources = {
        ["main"] = {filename = "main.c"},
        ["add"] = {filename = "utils.c"},
        ["unused_helper"] = {filename = "utils.c"},
      }

      local stats = lto_stats.track_dead_code_elimination(before_ir, after_ir, func_sources)

      assert.are.equal(2, stats.functions_removed)
      assert.are.equal(2, #stats.functions_by_file["utils.c"].removed)
      assert.are.equal(1, #stats.functions_by_file["main.c"].kept)
    end)

    it("should group by source file", function()
      local before_ir = {
        'define i32 @main() {}',
        'define i32 @helper1() {}',
        'define i32 @helper2() {}',
        'define i32 @util1() {}',
      }

      local after_ir = {
        'define i32 @main() {}',
        'define i32 @util1() {}',
      }

      local func_sources = {
        ["main"] = {filename = "main.c"},
        ["helper1"] = {filename = "helpers.c"},
        ["helper2"] = {filename = "helpers.c"},
        ["util1"] = {filename = "utils.c"},
      }

      local stats = lto_stats.track_dead_code_elimination(before_ir, after_ir, func_sources)

      assert.are.equal(2, #stats.functions_by_file["helpers.c"].removed)
      assert.are.equal(0, #stats.functions_by_file["helpers.c"].kept)
      assert.are.equal(1, #stats.functions_by_file["main.c"].kept)
      assert.are.equal(1, #stats.functions_by_file["utils.c"].kept)
    end)
  end)

  describe("format_lto_stats", function()
    it("should format statistics correctly", function()
      local inlining_stats = {
        total_calls_before = 10,
        total_calls_after = 5,
        inlined_count = 5,
        cross_module_calls_before = 3,
        cross_module_calls_after = 1,
        inlines_by_file = {
          ["main.c"] = {count = 2, targets = {"utils.c", "math.c"}},
        },
      }

      local dce_stats = {
        functions_removed = 3,
        functions_by_file = {
          ["utils.c"] = {removed = {"unused1", "unused2"}, kept = {"add"}},
        },
      }

      local formatted = lto_stats.format_lto_stats(inlining_stats, dce_stats)

      assert.is_true(formatted:find("Calls before LTO: 10") ~= nil)
      assert.is_true(formatted:find("Total inlined: 5") ~= nil)
      assert.is_true(formatted:find("Cross%-module inlined: 2") ~= nil)
      assert.is_true(formatted:find("Functions removed: 3") ~= nil)
    end)
  end)
end)

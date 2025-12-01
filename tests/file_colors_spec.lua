local file_colors = require('godbolt.file_colors')

describe("file_colors", function()
  describe("assign_file_colors", function()
    it("should assign unique colors to files", function()
      local filenames = { "main.c", "utils.c", "helpers.c" }
      local color_map = file_colors.assign_file_colors(filenames)

      assert.are.equal("GodboltFile1", color_map["main.c"])
      assert.are.equal("GodboltFile2", color_map["utils.c"])
      assert.are.equal("GodboltFile3", color_map["helpers.c"])
    end)

    it("should wrap colors after 8 files", function()
      local filenames = {}
      for i = 1, 10 do
        table.insert(filenames, string.format("file%d.c", i))
      end

      local color_map = file_colors.assign_file_colors(filenames)

      -- First 8 should use colors 1-8
      assert.are.equal("GodboltFile1", color_map["file1.c"])
      assert.are.equal("GodboltFile8", color_map["file8.c"])

      -- 9 and 10 should wrap to colors 1 and 2
      assert.are.equal("GodboltFile1", color_map["file9.c"])
      assert.are.equal("GodboltFile2", color_map["file10.c"])
    end)

    it("should handle empty input", function()
      local color_map = file_colors.assign_file_colors({})
      assert.are.same({}, color_map)
    end)
  end)

  describe("create_color_legend", function()
    it("should create legend lines", function()
      local color_map = {
        ["main.c"] = "GodboltFile1",
        ["utils.c"] = "GodboltFile2",
      }

      local legend = file_colors.create_color_legend(color_map)

      assert.is_true(#legend > 0)
      assert.are.equal("Source Files:", legend[1])

      -- Should contain both filenames
      local legend_text = table.concat(legend, "\n")
      assert.is_true(legend_text:find("main.c") ~= nil)
      assert.is_true(legend_text:find("utils.c") ~= nil)
    end)

    it("should handle empty color map", function()
      local legend = file_colors.create_color_legend({})
      assert.are.equal("Source Files:", legend[1])
      assert.are.equal(1, #legend)
    end)
  end)
end)

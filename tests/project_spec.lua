local project = require('godbolt.project')

describe("project", function()
  describe("find_project_root", function()
    it("should find project root with .git directory", function()
      -- Create a temporary directory structure
      local temp_dir = vim.fn.tempname()
      vim.fn.mkdir(temp_dir)
      vim.fn.mkdir(temp_dir .. "/.git")
      vim.fn.mkdir(temp_dir .. "/src")

      local root = project.find_project_root(temp_dir .. "/src")

      assert.is_not_nil(root)
      assert.are.equal(temp_dir, root)

      -- Cleanup
      vim.fn.delete(temp_dir, "rf")
    end)

    it("should find project root with CMakeLists.txt", function()
      local temp_dir = vim.fn.tempname()
      vim.fn.mkdir(temp_dir)
      vim.fn.mkdir(temp_dir .. "/src")
      vim.fn.writefile({}, temp_dir .. "/CMakeLists.txt")

      local root = project.find_project_root(temp_dir .. "/src")

      assert.is_not_nil(root)
      assert.are.equal(temp_dir, root)

      vim.fn.delete(temp_dir, "rf")
    end)

    it("should find project root with compile_commands.json", function()
      local temp_dir = vim.fn.tempname()
      vim.fn.mkdir(temp_dir)
      vim.fn.mkdir(temp_dir .. "/build")
      vim.fn.writefile({ "{}" }, temp_dir .. "/compile_commands.json")

      local root = project.find_project_root(temp_dir .. "/build")

      assert.is_not_nil(root)
      assert.are.equal(temp_dir, root)

      vim.fn.delete(temp_dir, "rf")
    end)

    it("should return nil when no project root found", function()
      local temp_dir = vim.fn.tempname()
      vim.fn.mkdir(temp_dir)

      local root = project.find_project_root(temp_dir)

      -- Without any markers, it should return nil
      assert.is_nil(root)

      vim.fn.delete(temp_dir, "rf")
    end)
  end)

  describe("find_compile_commands", function()
    it("should find compile_commands.json in project root", function()
      local temp_dir = vim.fn.tempname()
      vim.fn.mkdir(temp_dir)
      vim.fn.mkdir(temp_dir .. "/.git") -- marker for project root
      vim.fn.writefile({ "{}" }, temp_dir .. "/compile_commands.json")

      local cc_path = project.find_compile_commands(temp_dir)

      assert.is_not_nil(cc_path)
      assert.are.equal(temp_dir .. "/compile_commands.json", cc_path)

      vim.fn.delete(temp_dir, "rf")
    end)

    it("should find compile_commands.json in build directory", function()
      local temp_dir = vim.fn.tempname()
      vim.fn.mkdir(temp_dir)
      vim.fn.mkdir(temp_dir .. "/.git")
      vim.fn.mkdir(temp_dir .. "/build")
      vim.fn.writefile({ "{}" }, temp_dir .. "/build/compile_commands.json")

      local cc_path = project.find_compile_commands(temp_dir)

      assert.is_not_nil(cc_path)
      assert.are.equal(temp_dir .. "/build/compile_commands.json", cc_path)

      vim.fn.delete(temp_dir, "rf")
    end)

    it("should find compile_commands.json in cmake-build-* directory", function()
      local temp_dir = vim.fn.tempname()
      vim.fn.mkdir(temp_dir)
      vim.fn.mkdir(temp_dir .. "/.git")
      vim.fn.mkdir(temp_dir .. "/cmake-build-debug")
      vim.fn.writefile({ "{}" }, temp_dir .. "/cmake-build-debug/compile_commands.json")

      local cc_path = project.find_compile_commands(temp_dir)

      assert.is_not_nil(cc_path)
      assert.are.equal(temp_dir .. "/cmake-build-debug/compile_commands.json", cc_path)

      vim.fn.delete(temp_dir, "rf")
    end)

    it("should return nil when no compile_commands.json found", function()
      local temp_dir = vim.fn.tempname()
      vim.fn.mkdir(temp_dir)
      vim.fn.mkdir(temp_dir .. "/.git")

      local cc_path = project.find_compile_commands(temp_dir)

      assert.is_nil(cc_path)

      vim.fn.delete(temp_dir, "rf")
    end)
  end)

  describe("get_build_dir", function()
    it("should extract build directory from compile_commands.json path", function()
      local cc_path = "/project/build/compile_commands.json"

      local build_dir = project.get_build_dir(cc_path)

      assert.are.equal("/project/build", build_dir)
    end)

    it("should handle cmake-build-* paths", function()
      local cc_path = "/project/cmake-build-release/compile_commands.json"

      local build_dir = project.get_build_dir(cc_path)

      assert.are.equal("/project/cmake-build-release", build_dir)
    end)
  end)
end)

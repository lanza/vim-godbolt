local M = {}

-- Detect project root by looking for marker files/directories
-- @param start_path: path to start searching from (default: current buffer)
-- @return: project root path or nil
function M.find_project_root(start_path)
  start_path = start_path or vim.fn.expand("%:p:h")

  -- Priority-ordered markers (higher priority = checked first)
  local vcs_markers = { ".git", ".hg", ".svn" }
  local strong_markers = { "compile_commands.json", "Cargo.toml", "package.json" }
  local build_markers = { "CMakeLists.txt", "Makefile", "makefile", "build.ninja", "meson.build" }
  local weak_markers = { ".clang-format", ".clang-tidy", "compile_flags.txt" }

  local current = start_path
  local vcs_root = nil
  local strong_root = nil
  local build_root = nil
  local weak_root = nil

  -- Walk up directory tree, collecting all potential roots
  while current ~= "/" do
    -- Check for VCS markers (highest priority)
    if not vcs_root then
      for _, marker in ipairs(vcs_markers) do
        local marker_path = current .. "/" .. marker
        if vim.fn.isdirectory(marker_path) == 1 then
          vcs_root = current
          break
        end
      end
    end

    -- Check for strong project markers
    if not strong_root then
      for _, marker in ipairs(strong_markers) do
        local marker_path = current .. "/" .. marker
        if vim.fn.filereadable(marker_path) == 1 then
          strong_root = current
          break
        end
      end
    end

    -- Check for build system markers
    if not build_root then
      for _, marker in ipairs(build_markers) do
        local marker_path = current .. "/" .. marker
        if vim.fn.filereadable(marker_path) == 1 then
          build_root = current
          break
        end
      end
    end

    -- Check for weak markers
    if not weak_root then
      for _, marker in ipairs(weak_markers) do
        local marker_path = current .. "/" .. marker
        if vim.fn.filereadable(marker_path) == 1 then
          weak_root = current
          break
        end
      end
    end

    -- Go up one directory
    current = vim.fn.fnamemodify(current, ":h")
  end

  -- Return highest priority root found
  return vcs_root or strong_root or build_root or weak_root
end

-- Find compile_commands.json in the project
-- Searches in common locations:
-- - project root
-- - build/
-- - cmake-build-*/
-- - out/
-- @param project_root: project root directory (optional, will auto-detect)
-- @return: path to compile_commands.json or nil
function M.find_compile_commands(project_root)
  project_root = project_root or M.find_project_root()

  if not project_root then
    return nil
  end

  -- Common locations for compile_commands.json
  local search_paths = {
    project_root .. "/compile_commands.json",
    project_root .. "/build/compile_commands.json",
    project_root .. "/out/compile_commands.json",
    project_root .. "/Debug/compile_commands.json",
    project_root .. "/Release/compile_commands.json",
  }

  -- Also search cmake-build-* directories
  local handle = vim.loop.fs_scandir(project_root)
  if handle then
    while true do
      local name, type = vim.loop.fs_scandir_next(handle)
      if not name then break end

      if type == "directory" and name:match("^cmake%-build%-") then
        table.insert(search_paths, project_root .. "/" .. name .. "/compile_commands.json")
      end
    end
  end

  -- Return first found
  for _, path in ipairs(search_paths) do
    if vim.fn.filereadable(path) == 1 then
      return path
    end
  end

  return nil
end

-- Get the build directory from compile_commands.json location
-- @param compile_commands_path: path to compile_commands.json
-- @return: build directory path
function M.get_build_dir(compile_commands_path)
  return vim.fn.fnamemodify(compile_commands_path, ":h")
end

return M

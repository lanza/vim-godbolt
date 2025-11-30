-- Test the YAML parser for optimization remarks

describe("YAML Remarks Parser", function()
  -- We need to duplicate the parse function since it's local
  -- In production, we'd expose it via the module or test it through public API
  local function parse_remarks_yaml(yaml_file)
    if not yaml_file or vim.fn.filereadable(yaml_file) ~= 1 then
      return {}
    end

    local remarks_by_pass = {}
    local content = vim.fn.readfile(yaml_file)
    if not content or #content == 0 then
      return {}
    end

    local pass_name_map = {
      ["inline"] = "InlinerPass",
      ["sroa"] = "SROAPass",
      ["instcombine"] = "InstCombinePass",
      ["vectorize"] = "VectorizePass",
    }

    local current_record = {}

    for _, line in ipairs(content) do
      if line:match("^%-%-%-") then
        if current_record.Pass and current_record.Name then
          local yaml_pass_name = current_record.Pass
          local pass_name = pass_name_map[yaml_pass_name]
          if not pass_name then
            pass_name = yaml_pass_name:gsub("^%l", string.upper) .. "Pass"
          end

          if not remarks_by_pass[pass_name] then
            remarks_by_pass[pass_name] = {}
          end

          local category = "pass"
          if current_record.Type == "Missed" then
            category = "missed"
          elseif current_record.Type == "Analysis" then
            category = "analysis"
          end

          table.insert(remarks_by_pass[pass_name], {
            category = category,
            message = current_record.Name,
            location = {
              file = current_record.File,
              line = current_record.Line,
              column = current_record.Column,
            },
          })
        end

        current_record = {}
        local record_type = line:match("^%-%-%-[%s]*!(%w+)")
        if record_type then
          current_record.Type = record_type
        end
      else
        local key, value = line:match("^([%w]+):%s*(.*)$")
        if key and value then
          value = value:gsub("^['\"]", ""):gsub("['\"]$", "")

          if key == "Pass" then
            current_record.Pass = value
          elseif key == "Name" then
            current_record.Name = value
          elseif key == "DebugLoc" then
            local file = value:match("File: ([^,}]+)")
            local line_num = value:match("Line: (%d+)")
            local col = value:match("Column: (%d+)")
            if file then
              current_record.File = file:gsub("^['\"%s]+", ""):gsub("['\"%s]+$", "")
            end
            if line_num then
              current_record.Line = tonumber(line_num)
            end
            if col then
              current_record.Column = tonumber(col)
            end
          end
        end
      end
    end

    if current_record.Pass and current_record.Name then
      local yaml_pass_name = current_record.Pass
      local pass_name = pass_name_map[yaml_pass_name]
      if not pass_name then
        pass_name = yaml_pass_name:gsub("^%l", string.upper) .. "Pass"
      end

      if not remarks_by_pass[pass_name] then
        remarks_by_pass[pass_name] = {}
      end

      local category = "pass"
      if current_record.Type == "Missed" then
        category = "missed"
      elseif current_record.Type == "Analysis" then
        category = "analysis"
      end

      table.insert(remarks_by_pass[pass_name], {
        category = category,
        message = current_record.Name,
        location = {
          file = current_record.File,
          line = current_record.Line,
          column = current_record.Column,
        },
      })
    end

    return remarks_by_pass
  end

  it("parses sample YAML file", function()
    local remarks = parse_remarks_yaml("tests/fixtures/sample_remarks.yaml")
    assert(remarks ~= nil, "Should return remarks table")
  end)

  it("maps inline to InlinerPass", function()
    local remarks = parse_remarks_yaml("tests/fixtures/sample_remarks.yaml")
    assert(remarks["InlinerPass"] ~= nil, "Should have InlinerPass")
    assert(#remarks["InlinerPass"] == 3, "Should have 3 inline remarks")
  end)

  it("parses Passed remarks correctly", function()
    local remarks = parse_remarks_yaml("tests/fixtures/sample_remarks.yaml")
    local inline_remarks = remarks["InlinerPass"]

    assert(inline_remarks[1].category == "pass", "Category should be 'pass'")
    assert(inline_remarks[1].message == "Inlined", "Message should be 'Inlined'")
    assert(inline_remarks[1].location.line == 10, "Line should be 10")
    assert(inline_remarks[1].location.column == 5, "Column should be 5")
  end)

  it("parses Missed remarks correctly", function()
    local remarks = parse_remarks_yaml("tests/fixtures/sample_remarks.yaml")

    assert(remarks["InlinerPass"][3].category == "missed", "Category should be 'missed'")
    assert(remarks["InlinerPass"][3].message == "NotInlined", "Message should be 'NotInlined'")
  end)

  it("parses Analysis remarks correctly", function()
    local remarks = parse_remarks_yaml("tests/fixtures/sample_remarks.yaml")

    assert(remarks["VectorizePass"] ~= nil, "Should have VectorizePass")
    assert(remarks["VectorizePass"][1].category == "analysis", "Category should be 'analysis'")
  end)

  it("returns empty table for non-existent file", function()
    local remarks = parse_remarks_yaml("nonexistent.yaml")
    assert(vim.tbl_isempty(remarks), "Should return empty table")
  end)
end)

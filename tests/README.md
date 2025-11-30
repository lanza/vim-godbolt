# godbolt.nvim Tests

This directory contains tests for the godbolt.nvim plugin using a custom test framework that matches snacks.nvim conventions.

## Running Tests

```bash
# Run all tests
./scripts/test

# Run specific test file
./scripts/test tests/yaml_parser_spec.lua

# Run multiple specific files
./scripts/test tests/yaml_parser_spec.lua tests/remarks_integration_spec.lua
```

## Test Structure

Tests follow the snacks.nvim conventions:

- `tests/minit.lua` - Custom test bootstrap providing describe/it/assert globals
- `tests/fixtures/` - Test data (YAML files, C++ code, etc.)
- `tests/*_spec.lua` - Test files using `describe` and `it`
- `scripts/test` - Test runner script

## Framework

The test framework uses a custom minit.lua implementation that provides:
- **describe/it** - BDD-style test organization matching snacks.nvim
- **luassert-compatible assertions** - Drop-in compatible assertion API without external dependencies
- **Neovim Lua environment** - Full access to vim.* APIs

The framework was designed to match snacks.nvim's test structure but works around luassert installation issues by providing a compatible assertion API built on Lua's native `assert()`.

## Writing Tests

```lua
describe("My Feature", function()
  it("does something correctly", function()
    local result = my_function()
    assert(result == expected, "Should match expected value")
  end)
end)
```

## Assertion API

The framework provides luassert-compatible assertions:

### Equality
```lua
assert.are.equal(expected, actual)      -- Value equality
assert.are.same(table1, table2)         -- Deep table comparison
assert.is_not.same(table1, table2)      -- Tables should differ
```

### Nil checks
```lua
assert.is_not_nil(value)
assert.is_nil(value)
```

### Boolean
```lua
assert.is_true(value)
assert.is_false(value)
assert.is.truthy(value)   -- Any truthy value
assert.is.falsy(value)    -- nil or false
```

### Type checks
```lua
assert.is_string(value)
assert.is_table(value)
assert.is_number(value)
```

### Basic assert
```lua
assert(condition, "error message")
```

## Test Files

### `yaml_parser_spec.lua`
Tests the YAML optimization remarks parser:
- Parses YAML file format correctly
- Maps YAML pass names to pipeline pass names (e.g., "inline" → "InlinerPass")
- Handles different remark categories (Passed, Missed, Analysis)
- Parses location information (file, line, column)

### `remarks_integration_spec.lua`
End-to-end integration test:
- Compiles C++ test file with optimization remarks enabled
- Verifies YAML file is created
- Checks that remarks are attached to correct passes
- Tests prefix matching for pass names

### Existing Tests
The project has extensive existing tests for:
- Pipeline parsing (`pipeline_spec.lua`)
- LTO functionality (`lto_spec.lua`, `lto_phase3_spec.lua`, `lto_stats_spec.lua`)
- Compiler options (`clang_pipeline_spec.lua`, `compile_commands_spec.lua`)
- Output handling (`output_preference_spec.lua`)
- Integration tests (`integration_spec.lua`)

## Test Environment

Tests run with:
- Full access to the godbolt.nvim plugin code
- Neovim's Lua APIs (vim.fn, vim.api, etc.)
- Real compiler (clang) for integration tests
- Test fixtures in `tests/fixtures/`

## Test Results

Current status: **77/78 tests passing** (98.7%)

The one failing test ("parses two functions with function passes - THE KEY TEST") is a pre-existing issue in the pipeline parser where InstCombinePass on bar incorrectly contains @foo.

## Troubleshooting

**Module not found errors:** Ensure your plugin code is in the expected location

**Compilation errors in integration tests:** Verify clang is installed and accessible

## Godbolt-like for Neovim

A simple Neovim plugin that compiles your code to assembly in a split window, similar to Godbolt Compiler Explorer. If the first line of the file starts with `// godbolt:` or `; godbolt:`, the rest of the line will be appended as compiler arguments.

You can see an example here:

![](sample.png)

This also works for Swift:

![](swift.png)

## Configuration

Configure the plugin in your `init.lua`:

```lua
require('godbolt').setup({
  -- Define the compilers you want to use
  clang = 'clang',
  swiftc = 'swiftc',
  opt = 'opt',

  -- Define compiler arguments
  cpp_args = '-std=c++20',
  c_args = '-std=c17',
  swift_args = '',
  ll_args = '',

  -- Customize window command (optional)
  -- window_cmd = 'split' -- instead of default 'vertical botright new'

  -- Line mapping configuration (Godbolt-style source-to-assembly mapping)
  line_mapping = {
    enabled = true,         -- Enable automatic line mapping
    auto_scroll = false,    -- Don't auto-scroll windows (just highlight)
    throttle_ms = 150,      -- Throttle cursor updates (ms)
  },
})
```

All fields are optional and will use sensible defaults if not specified.

## Usage

Run `:VGodbolt` to compile the current file to assembly in a new split window.

You can pass additional compiler arguments:
```vim
:VGodbolt -O3
:VGodbolt -O2 -march=native
```

You can also specify per-file arguments using a comment on the first line:
```cpp
// godbolt: -O2 -march=native
int main() {
  return 42;
}
```

For assembly files (.s) or LLVM IR files (.ll), use `;` for comments:
```llvm
; godbolt: -O3
define i32 @main() {
  ret i32 42
}
```

### Output Type Detection

The plugin automatically detects the output type based on compiler flags and sets the appropriate filetype:

- **`-emit-llvm`** → LLVM IR (`filetype=llvm`)
- **`-emit-cir`** → ClangIR (`filetype=mlir`)
- **`-emit-ast`** → AST dump (`filetype=text`)
- **`-emit-obj`** or **`-c`** → Object file (shown via objdump, `filetype=asm`)
- **`.ll` files** → Always LLVM IR (`filetype=llvm`)
- **Default** → Assembly (`filetype=asm`)

Examples:
```vim
:VGodbolt -emit-llvm -O2          " Outputs LLVM IR
:VGodbolt -emit-cir               " Outputs ClangIR (MLIR)
```

Or use file-level comments:
```cpp
// godbolt: -emit-llvm -O3
int main() { return 42; }
```

### Warnings and Errors

Compiler warnings and errors are separated from the output and displayed in the message log (`:messages`) instead of cluttering the output buffer.

For example, if you run:
```vim
:VGodbolt -masm=intel
```

You'll see in `:messages`:
```
clang++ "file.cpp" -S -fno-asynchronous-unwind-tables -masm=intel -std=c++20 -o -
clang: warning: argument unused during compilation: '-masm=intel' [-Wunused-command-line-argument]
```

While the output buffer will only contain the clean assembly output. This keeps your compilation output clean and readable while still preserving important diagnostic information.

### Line Mapping (Godbolt-style)

The plugin automatically maps source lines to compiled output lines (and vice versa), similar to godbolt.com's Compiler Explorer.

**How it works:**
- Move your cursor in the source file → corresponding assembly/IR lines are highlighted
- Move your cursor in the assembly → corresponding source line is highlighted
- Uses compiler debug information (`.loc` directives) for accurate mapping

**Features:**
- **Bidirectional mapping**: Source ↔ Assembly synchronization
- **Automatic**: Enabled by default, no manual setup needed
- **Performance optimized**: Throttled updates to prevent lag
- **Works at all optimization levels**: -O0, -O2, -O3, etc.

**Requirements:**
- Automatically adds `-g` flag to enable debug information
- **LLVM IR support**: Fully implemented (parses `!dbg` metadata)
- **Assembly support**: Work in progress

**To use LLVM IR (recommended):**
```vim
:VGodbolt -emit-llvm
```

**Configuration:**
```lua
require('godbolt').setup({
  line_mapping = {
    enabled = true,         -- Enable/disable line mapping
    auto_scroll = false,    -- Auto-scroll windows (can be distracting)
    throttle_ms = 150,      -- Delay between updates (performance)
  },
})
```

**Example:**
1. Open a C++ file
2. Run `:VGodbolt`
3. Move your cursor to line 5 in source
4. Lines 42-48 in assembly are automatically highlighted
5. Click on line 45 in assembly → line 5 in source is highlighted

**Note:** Line mapping works best with `-O0` (no optimization) for 1:1 correspondence. At higher optimization levels, one source line may map to multiple assembly blocks due to inlining, unrolling, etc.

## Supported File Types

- **C/C++** (`.c`, `.cpp`) → Uses `clang`/`clang++`
- **Swift** (`.swift`) → Uses `swiftc` with demangling
- **LLVM IR** (`.ll`) → Uses `opt`

## Future Ideas

- Read from a `compile_commands.json` file
- Parse away CFI directives for cleaner output

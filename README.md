# godbolt.nvim

A powerful Neovim plugin that brings Compiler Explorer (godbolt.org) functionality directly into your editor. Compile your code to assembly, LLVM IR, or other intermediate representations in a split window, with bidirectional line mapping and LLVM optimization pipeline visualization.

[![asciicast](Pipeline)](https://asciinema.org/a/KUbt8dRWzYNTE3i8ijrpAKLjN)

## Features

- **Multi-format output**: Assembly, LLVM IR, ClangIR, AST dumps, and object files
- **Bidirectional line mapping**: Click on source code to highlight corresponding assembly/IR, and vice versa
- **LLVM pipeline viewer**: Step through optimization passes for both C/C++ files and LLVM IR
- **Link-Time Optimization (LTO)**: Compile and link multiple files with whole-program optimization
- **LTO pipeline visualization**: Watch cross-module optimizations in action (70+ passes)
- **Multi-language support**: C, C++, Swift, and LLVM IR
- **Per-file compiler arguments**: Use comments to specify flags per file
- **Automatic output detection**: Intelligently detects output type from compiler flags
- **Clean output**: Separates warnings/errors from the main output buffer

## Quick Start

```lua
-- 1. Install the plugin using your package manager
{
  'lanza/godbolt.nvim',
  config = function()
    require('godbolt').setup()
  end,
}

-- 2. Open a C/C++ file and run
:Godbolt -O2

-- 3. To see LLVM optimization passes (C/C++ files):
:GodboltPipeline O2

-- 4. For multi-file Link-Time Optimization:
:GodboltLTO main.c utils.c
:GodboltLTOPipeline main.c utils.c -O2

-- Or for .ll files with custom passes:
:!clang -S -emit-llvm -O0 -Xclang -disable-O0-optnone % -o %:r.ll
:edit %:r.ll
:GodboltPipeline mem2reg,instcombine
```

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'lanza/godbolt.nvim',
  config = function()
    require('godbolt').setup({
      -- Your configuration here (see Configuration section below)
    })
  end,
}
```

Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  'lanza/godbolt.nvim',
  config = function()
    require('godbolt').setup()
  end
}
```

**Requirements:**
- Neovim 0.7+
- `clang`/`clang++` for C/C++ compilation
- `swiftc` for Swift compilation (optional)
- `opt` (LLVM optimizer) for LLVM IR optimization and pipeline viewer (optional)

## Lua API

All commands have corresponding Lua functions that accept an options table for programmatic control:

```lua
local gb = require('godbolt')

-- Basic compilation with output preference
gb.godbolt("", { output = "llvm" })    -- Force LLVM IR output
gb.godbolt("", { output = "asm" })     -- Force assembly output
gb.godbolt("", { output = "auto" })    -- Auto-detect (default)

-- LTO functions (always output LLVM IR)
gb.godbolt_lto(nil, "", { output = "llvm" })           -- Auto-detect files
gb.godbolt_lto({"main.c", "util.c"}, "-O2", { output = "llvm" })

gb.godbolt_lto_pipeline(nil, "-O2", { output = "llvm" })
gb.godbolt_lto_compare(nil, "-O3", { output = "llvm" })
```

**Output Preference Behavior:**
- `output = "llvm"`: Auto-injects `-emit-llvm` when using compile_commands.json
- `output = "asm"`: Uses assembly output (default for clang)
- `output = "auto"`: No injection, uses compile_commands.json flags as-is
- Default for `:Godbolt` command: `"llvm"` (most useful for code inspection)
- Default for LTO commands: `"llvm"` (LTO always outputs LLVM IR)

When `output = "llvm"` is set and compile_commands.json is used, the plugin will automatically add `-emit-llvm` to the compiler flags unless you explicitly specify `-emit-*` or `-S` in your arguments.

## Configuration

Configure the plugin in your `init.lua`:

```lua
require('godbolt').setup({
  -- Compiler paths (optional, uses these defaults)
  clang = 'clang',
  swiftc = 'swiftc',
  opt = 'opt',

  -- Default compiler arguments
  cpp_args = '-std=c++20',
  c_args = '-std=c17',
  swift_args = '',
  ll_args = '',

  -- Window configuration (optional)
  -- window_cmd = 'split' -- instead of default 'vertical botright new'

  -- Line mapping configuration (Godbolt-style source-to-assembly mapping)
  line_mapping = {
    enabled = true,         -- Enable automatic line mapping
    auto_scroll = false,    -- Auto-scroll windows when cursor moves (only scrolls if off-screen)
    throttle_ms = 150,      -- Throttle cursor updates (ms) for performance
    silent_on_failure = false,  -- Show error messages if debug info is missing
    show_compilation_cmd = true,  -- Show compilation command when debug info fails
  },

  -- Display configuration
  display = {
    strip_debug_metadata = true,   -- Hide debug metadata (!123 = !{...}) in LLVM IR
    annotate_variables = true,     -- Show variable names as comments (e.g., "; %5 = x")
  },

  -- Pipeline viewer configuration
  pipeline = {
    enabled = true,         -- Enable pipeline viewer
    show_stats = true,      -- Show instruction and basic block statistics
    start_at_final = false, -- Start at first pass instead of final result
    filter_unchanged = false, -- Filter out passes that don't change the IR
  },
})
```

All fields are optional and will use sensible defaults if not specified.

## Commands

### Basic Compilation

**`:Godbolt [compiler-args]`**

Compiles the current file to assembly/IR in a new split window.

**Auto-Detection from compile_commands.json:**

If you run `:Godbolt` without arguments, it will automatically use compiler flags from `compile_commands.json` for the current file if found:
```vim
" Auto-detect compiler flags from compile_commands.json
:Godbolt

" Or manually specify flags (overrides compile_commands.json)
:Godbolt -O3 -march=native
```

The plugin extracts flags like `-O2`, `-std=c++20`, `-I`, `-D` from your build system configuration and applies them automatically.

**Examples:**
```vim
:Godbolt              " Auto-detect flags or basic compilation
:Godbolt -O3          " With optimization
:Godbolt -O2 -march=native
:Godbolt -emit-llvm   " Output LLVM IR instead of assembly
:Godbolt -emit-cir    " Output ClangIR (MLIR)
```

### Pipeline Viewer

**`:GodboltPipeline [passes]`**

Runs LLVM optimization passes and opens an interactive 3-pane viewer showing each pass's transformations.

**Supported file types:**
- `.ll` files: Use custom pass lists or O-levels
- `.c`/`.cpp` files: Use O-levels only (O0, O1, O2, O3)

Examples:
```vim
" For C/C++ files - view frontend optimization passes
:GodboltPipeline O2                 " Use O2 optimization level
:GodboltPipeline O3                 " Use O3 optimization level

" For .ll files - use custom passes or O-levels
:GodboltPipeline                    " Use default O2 pipeline
:GodboltPipeline O3                 " Use O3 optimization level
:GodboltPipeline mem2reg,instcombine " Run specific passes

" Workflow for custom passes on C/C++ code:
" 1. First compile to LLVM IR with O0
:Godbolt -emit-llvm -O0 -Xclang -disable-O0-optnone
" 2. Then run custom passes on the .ll file
:edit %:r.ll
:GodboltPipeline mem2reg,sroa,instcombine
```

**Note:** For C/C++ files, custom pass lists are not supported due to clang's compilation model. Compile to `.ll` first if you need custom passes.

**Pass Scope Indicators:**

The pipeline viewer shows scope indicators for each pass:
- **[M]** - Module pass: operates on the entire module (all functions, globals)
- **[F]** - Function pass: operates on a single function
- **[C]** - CGSCC pass: operates on a call graph strongly-connected component

Module passes show the full module before/after, while function passes show only the specific function being optimized.

**Pipeline Navigation Commands:**

- **`:NextPass`** - Navigate to the next optimization pass
- **`:PrevPass`** - Navigate to the previous optimization pass
- **`:GotoPass [N]`** - Jump to pass number N (or show picker if N omitted)
- **`:FirstPass`** - Jump to the first pass
- **`:LastPass`** - Jump to the last pass

**Keybindings in Pipeline Viewer:**

In the pass list pane:
- **`j`/`k`** - Navigate through all visible lines (modules, group headers, function entries)
- **`Tab`/`Shift-Tab`** - Jump to next/previous changed pass (auto-unfolds groups)
- **`Enter`** - Select and view the pass/function under cursor
- **`o`** - Toggle fold/unfold for groups (▸ → ▾)
- **`q`** - Quit the pipeline viewer
- **`g[`** - Jump to first pass
- **`g]`** - Jump to last pass

In the before/after panes:
- **`]p` / `[p`** or **`Tab` / `Shift-Tab`** - Next/Previous pass
- Standard diff commands (`]c`, `[c` for next/previous diff)

**Pipeline Viewer Features:**

- **Smart Grouping**: Function/CGSCC passes are grouped together
  - Groups display as `▸ [F] PassName (N functions)` when folded
  - Press `o` or `Enter` to unfold and see individual functions
  - Module passes (`[M]`) automatically close all open groups
  - Interleaved passes are correctly merged into groups
- **Auto-Unfold Navigation**: `Tab` automatically unfolds groups when navigating to changed passes
- **Sorted Functions**: Within each group, changed functions appear first
- **Visual Indicators**:
  - `>` marks the currently selected pass/function
  - `●` marks the selected function entry within an unfolded group
  - Changed passes/functions are highlighted in color
  - Unchanged passes/functions are grayed out
- **All Groups Start Folded**: Even groups with 1000+ functions start folded for usability

### Link-Time Optimization (LTO)

**`:GodboltLTO [file1.c file2.c ...]`**

Compiles and links multiple source files with Link-Time Optimization (LTO), displaying the unified LLVM IR with cross-module optimizations applied.

**Auto-Detection from compile_commands.json:**

If you don't provide any files, the command will automatically detect your project structure:
```vim
" Auto-detect all files from compile_commands.json
:GodboltLTO

" Or manually specify files
:GodboltLTO main.c utils.c
```

The plugin automatically detects your project root by looking for (in priority order):
1. Version control markers (`.git`, `.hg`, `.svn`)
2. Strong project markers (`compile_commands.json`, `Cargo.toml`, `package.json`)
3. Build system files (`CMakeLists.txt`, `Makefile`)
4. Config files (`.clang-format`, `.clang-tidy`)

Then searches for `compile_commands.json` in:
- Project root
- `build/`
- `cmake-build-*/`
- `out/`
- `Debug/` / `Release/`

To generate `compile_commands.json`:
```bash
# CMake
cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON .

# Or create a symlink in project root
ln -s build/compile_commands.json .
```

**What is LTO?**

Link-Time Optimization enables whole-program optimization across multiple source files:
- **Cross-module inlining**: Functions from one file can be inlined into another
- **Global dead code elimination**: Unused functions across all files are removed
- **Interprocedural optimization**: Optimizations that span function and file boundaries

**Examples:**

```vim
" Auto-detect from compile_commands.json
:GodboltLTO

" Compile two files with LTO
:GodboltLTO main.c utils.c

" Compile multiple files
:GodboltLTO src/main.c src/helpers.c src/math.c

" Mix C and C++ (auto-detected from file extension)
:GodboltLTO main.cpp utils.cpp
```

**What you'll see:**
- Functions from `utils.c` inlined into `main.c`
- Unused helper functions completely eliminated
- Constants propagated across files
- The unified LLVM IR after all link-time optimizations

**`:GodboltLTOPipeline [file1.c file2.c ...] [-O2]`**

Visualizes the LLVM optimization passes that run during link-time optimization. Shows how the linker transforms your code across multiple files.

**Auto-Detection:**
```vim
" Auto-detect from compile_commands.json
:GodboltLTOPipeline -O2

" Or manually specify files
:GodboltLTOPipeline main.c utils.c -O2
```

**Examples:**

```vim
" Auto-detect files, view with O2
:GodboltLTOPipeline -O2

" View LTO passes with O2 optimization
:GodboltLTOPipeline main.c utils.c -O2

" View with O3 optimization
:GodboltLTOPipeline main.c utils.c -O3

" View with O0 (minimal optimization)
:GodboltLTOPipeline main.c utils.c -O0
```

**`:GodboltLTOCompare [file1.c file2.c ...] [-O2]`**

Opens a 3-pane comparison view showing before/after LTO transformation with detailed statistics:

**Auto-Detection:**
```vim
" Auto-detect from compile_commands.json
:GodboltLTOCompare -O2

" Or manually specify files
:GodboltLTOCompare main.c utils.c -O2
```

**Layout:**
```
┌─────────────────────┬─────────────────────┬─────────────────────┐
│  Before LTO         │  LTO Statistics     │  After LTO          │
│  (merged modules)   │  (center pane)      │  (color-coded IR)   │
└─────────────────────┴─────────────────────┴─────────────────────┘
```

**Left Pane - Before LTO:**
- Shows merged LLVM IR from all input files before link-time optimization
- All functions are present (not yet eliminated)
- Function calls are explicit (not yet inlined)

**Center Pane - Statistics:**
Shows detailed transformation metrics:

1. **Source File Legend:**
   ```
   Source Files:
     main.c    (highlighted in cyan in right pane)
     utils.c   (highlighted in green in right pane)
   ```

2. **Cross-Module Inlining:**
   ```
   Cross-Module Inlining:
     Function calls before LTO: 6
     Function calls after LTO:  0
     Total inlined: 6

     Cross-module calls before: 6
     Cross-module calls after:  0
     Cross-module inlined: 6

     Inlined by source file:
       • main.c:
         6 inlines from: utils.c
   ```
   This shows:
   - How many function calls existed before LTO
   - How many were inlined (disappeared)
   - Which files had functions inlined from which other files
   - Specifically tracks **cross-module inlining** (calls between different source files)

3. **Dead Code Elimination:**
   ```
   Dead Code Elimination:
     Functions removed: 4

     By file:
       • main.c: removed [compute]
       • main.c: kept [main]
       • utils.c: removed [add, multiply, square]
   ```
   This shows:
   - Total number of functions eliminated
   - Which functions from each source file were removed
   - Which functions survived optimization
   - Helps identify unused code across your project

**Right Pane - After LTO (Color-Coded):**
- Shows final optimized LLVM IR after all link-time optimizations
- **Functions are syntax-highlighted by source file:**
  - Code from `main.c` appears in one color (e.g., cyan)
  - Code from `utils.c` appears in another color (e.g., green)
  - Uses 8 distinct colors that wrap for more files
- Highlights applied using `nvim_buf_add_highlight()` to entire function bodies
- Makes it easy to see which file each remaining code came from

**Examples:**

```vim
" Compare with O2 optimization
:GodboltLTOCompare main.c utils.c -O2

" Compare multiple files
:GodboltLTOCompare src/main.c src/helpers.c src/math.c -O3
```

**Real Example Output:**

Given `main.c` with `compute()` that calls `add()`, `multiply()`, and `square()` from `utils.c`:

The statistics pane will show:
- "6 inlines from utils.c" (the 3 functions were called from 2 places each)
- "Functions removed: 4" (compute, add, multiply, square all got inlined and eliminated)
- "kept [main]" (only main() survives)

The right pane will show the final optimized `main()` with all the math computed inline, color-coded to show which parts came from which source file.

**What you'll see:**
- 70+ optimization pass stages during link-time
- Cross-module inlining decisions
- Dead code elimination across files
- Constant propagation between modules
- Same 3-pane viewer as `:GodboltPipeline`
- Before/after IR for each pass with diff highlighting

**Navigation:**
- All standard pipeline navigation commands work:
  - `:NextPass` / `:PrevPass`
  - `]p` / `[p` keybindings
  - `:GotoPass [N]`
  - `j`/`k` in pass list pane

**Real-World Example:**

Given these files:

`main.c`:
```c
int add(int a, int b);      // Defined in utils.c
int multiply(int a, int b); // Defined in utils.c
int square(int x);          // Defined in utils.c

int compute(int x, int y) {
  return add(x, y) + multiply(x, y) + square(x);
}

int main() {
  return compute(5, 3);
}
```

`utils.c`:
```c
int add(int a, int b) { return a + b; }
int multiply(int a, int b) { return a * b; }
int square(int x) { return multiply(x, x); }
```

**Without LTO** (separate compilation):
```vim
:Godbolt main.c
" You see: Calls to external functions add(), multiply(), square()
```

**With LTO**:
```vim
:GodboltLTO main.c utils.c
" You see: All functions inlined, computation may be constant-folded
" The IR might show main() just returns a constant!
```

**View the optimization process**:
```vim
:GodboltLTOPipeline main.c utils.c -O2
" Navigate through passes to see:
" 1. Initial merged module with all functions
" 2. InlinerPass: add() gets inlined into compute()
" 3. InlinerPass: multiply() gets inlined into square() and compute()
" 4. InlinerPass: square() gets inlined into compute()
" 5. ConstantPropagation: compute(5, 3) becomes constant
" 6. GlobalDCE: Unused functions eliminated
" 7. Final result: main() { return 43; }
```

**Configuration:**

```lua
require('godbolt').setup({
  -- ... other config ...

  lto = {
    enabled = true,           -- Enable LTO support
    linker = "ld.lld",       -- Linker to use (ld.lld recommended)
    keep_temps = false,       -- Keep temporary object files for inspection
    save_temps = true,        -- Save intermediate compilation files
  },
})
```

**Requirements:**
- `clang` / `clang++` (for compilation)
- `ld.lld` (LLVM linker)
- `llvm-dis` (for converting bitcode to readable IR)

These tools are typically included with your LLVM installation.

### Utility Commands

**`:GodboltDebug [on|off]`**

Toggle debug mode to see detailed logging for troubleshooting pipeline issues.

```vim
:GodboltDebug on       " Enable debug mode
:GodboltDebug off      " Disable debug mode
:GodboltDebug          " Toggle debug mode
```

**`:GodboltStripOptnone`**

Strip `optnone` attributes from the current LLVM IR file. Useful when you have IR compiled with `-O0` that you want to optimize.

```vim
:GodboltStripOptnone   " Strips optnone and reloads the buffer
```

**`:GodboltShowCommand`**

Show the last compilation command used by `:Godbolt`. Useful for debugging line mapping issues or understanding what flags were used.

```vim
:GodboltShowCommand    " Displays the last compilation command
```

## Usage Examples

### Per-File Compiler Arguments

You can specify compiler arguments directly in your source files using special comments on the first line:
```cpp
// godbolt: -O2 -march=native
int main() {
  return 42;
}
```

For assembly files (`.s`) or LLVM IR files (`.ll`), use `;` for comments:
```llvm
; godbolt: -O3
define i32 @main() {
  ret i32 42
}
```

These arguments are combined with any arguments passed to `:Godbolt`.

### Pipeline Comments

For LLVM IR files, you can also specify pipeline configuration in comments:

```llvm
; godbolt-pipeline: mem2reg,instcombine,simplifycfg
; godbolt-level: O3
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
:Godbolt -emit-llvm -O2          " Outputs LLVM IR
:Godbolt -emit-cir               " Outputs ClangIR (MLIR)
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
:Godbolt -masm=intel
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
:Godbolt -emit-llvm
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
2. Run `:Godbolt`
3. Move your cursor to line 5 in source
4. Lines 42-48 in assembly are automatically highlighted
5. Click on line 45 in assembly → line 5 in source is highlighted

**Note:** Line mapping works best with `-O0` (no optimization) for 1:1 correspondence. At higher optimization levels, one source line may map to multiple assembly blocks due to inlining, unrolling, etc.

### Advanced LLVM IR Features

When viewing LLVM IR output (`:Godbolt -emit-llvm`), the plugin provides several advanced features:

**1. Clean IR Display**
- Debug metadata (`!123 = !{...}`) is hidden by default for readability
- Full IR with metadata is preserved internally for line mapping
- Toggle with `display.strip_debug_metadata = false` in config

**2. Column-Level Precision**
- Highlights the exact column/token in source code (not just the line)
- Uses column information from `!DILocation` metadata
- Highlights ~10 characters starting at the precise column
- Falls back to line highlighting when column info unavailable

**3. Auto-Scroll**
- Automatically scrolls the opposite pane to show the mapped line
- Only scrolls when the line is off-screen (not jarring)
- Centers the target line in the window
- Enable with `line_mapping.auto_scroll = true`
- Works bidirectionally (source ↔ IR)

**4. Variable Name Annotations**
- Shows source variable names next to SSA registers
- Example: `%5 = alloca i32  ; %5 = x`
- Parses `!DILocalVariable` metadata and `llvm.dbg.declare` calls
- Displayed as virtual text comments (non-intrusive)
- Enable/disable with `display.annotate_variables`

**Example configuration:**
```lua
require('godbolt').setup({
  line_mapping = {
    auto_scroll = true,  -- Enable auto-scroll
  },
  display = {
    strip_debug_metadata = true,  -- Clean IR display
    annotate_variables = true,    -- Show variable names
  },
})
```

**Usage:**
```vim
:Godbolt -emit-llvm -O2

" Move cursor in source → IR window scrolls and highlights exact column
" Move cursor in IR → source window scrolls and highlights
" Variable names appear as comments in IR
```

### LLVM Optimization Pipeline Viewer

The pipeline viewer is a unique feature that lets you step through LLVM optimization passes one at a time, seeing exactly what each pass does to your code.

**Workflow:**

1. Compile your code to LLVM IR:
   ```bash
   clang -S -emit-llvm -O0 -Xclang -disable-O0-optnone yourfile.c -o yourfile.ll
   ```

2. Open the IR file in Neovim and run:
   ```vim
   :GodboltPipeline O2
   ```

3. The plugin opens a 3-pane layout:
   - **Left pane**: List of all optimization passes
   - **Center pane**: IR before the current pass
   - **Right pane**: IR after the current pass (with diff highlighting)

4. Navigate through passes using:
   - `j`/`k` in the pass list
   - `:NextPass` / `:PrevPass` commands
   - `]p` / `[p` keybindings in the diff panes

**Features:**

- **Per-function optimization**: Each pass shows the specific function it operated on
- **Statistics**: See instruction count and basic block count changes per pass
- **Diff mode**: Automatic diff highlighting between before/after states
- **Smart navigation**: Automatically handles function-scoped passes
- **Filter unchanged passes**: Optionally hide passes that didn't modify the IR

**Common Issues:**

If you see "No passes captured" with `optnone` warning:
- Your IR was compiled with `-O0` which adds `optnone` attributes
- Use `:GodboltStripOptnone` to remove them, or
- Recompile with `-Xclang -disable-O0-optnone`

**Example Pipeline Workflow:**

```vim
" 1. Open your C file
:edit example.c

" 2. Compile to IR without optnone
:!clang -S -emit-llvm -O0 -Xclang -disable-O0-optnone example.c -o example.ll

" 3. Open the IR file
:edit example.ll

" 4. Run the pipeline viewer
:GodboltPipeline O2

" 5. Navigate through passes
:NextPass
:NextPass
:GotoPass 10
```

## Supported File Types

- **C/C++** (`.c`, `.cpp`) → Uses `clang`/`clang++`
- **Swift** (`.swift`) → Uses `swiftc` with automatic demangling
- **LLVM IR** (`.ll`) → Uses `opt` for optimization passes

## Tips and Tricks

### Quick LLVM IR Generation

Create a shell alias or Neovim command for quick IR generation:

```bash
# In your .bashrc or .zshrc
alias llvm-ir='clang -S -emit-llvm -O0 -Xclang -disable-O0-optnone'

# Then use it:
llvm-ir yourfile.c -o yourfile.ll
```

### Combining with Terminal

Use `:Godbolt` output as a learning tool alongside your code:

```vim
" Open your source in a split
:vsplit yourfile.c

" Compile to assembly in the right pane
:Godbolt -O2

" Now you can see your source and assembly side-by-side
```

### Custom Optimization Passes

Experiment with specific LLVM passes to understand their effect:

```vim
:GodboltPipeline mem2reg
:GodboltPipeline instcombine,simplifycfg
:GodboltPipeline loop-unroll,loop-vectorize
```

### Viewing Multiple Optimization Levels

Compare different optimization levels:

```vim
:Godbolt -O0
" Then create another split:
:Godbolt -O3
" Use :diffthis in both buffers to compare
```

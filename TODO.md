# TODO & Feature Ideas

## Completed Features

### Pipeline Viewer Enhancements
- [x] **Pass Grouping with Fold/Unfold** - Organize function passes by name
  - Group function/CGSCC passes together using open groups algorithm
  - Merges interleaved passes (e.g., FuncPassF on main, FuncPassG on main, FuncPassF on foo → groups correctly)
  - Module passes close all open groups, creating clean boundaries
  - Collapsible groups with `▸` and `▾` fold icons
  - `o` key to toggle folds, Enter to fold/select
  - Visual hierarchy with indented function entries
  - All groups start folded (even 1000+ function groups) for usability
- [x] **Smart Navigation** - Tab/Shift-Tab jump to changed passes with auto-unfold
  - Tab automatically unfolds groups when navigating to them
  - j/k walks all visible lines (modules, group headers, function entries)
  - No navigation loops - can move up/down freely
  - Position-based selection for duplicate function entries
- [x] **Enhanced Highlighting** - Better visual distinction
  - Custom highlight groups for fold icons, group headers, function entries
  - Changed function passes use same color as changed module passes
  - Theme-aware colors (dark/light background support)
  - Different colors for Module [M], Function [F], and CGSCC [C] scopes
  - Distinct highlighting for selected markers (>, ●)
  - Gray out unchanged passes for easy visual scanning
- [x] **Function Sorting** - Changed functions appear first
  - Functions within groups sorted by: changed first, then original order
  - Makes it easy to see which functions had changes when unfolding
- [x] **UTF-8 Pattern Matching** - Proper handling of fold icons and markers
  - Correct handling of multi-byte UTF-8 characters (▸▾●)
  - Right-aligned pass numbers (handles both single and double digits)
- [x] **Comprehensive Test Suite** - 24 tests covering all functionality
  - Pattern matching tests (module, group, function entries)
  - Folding behavior tests (all groups start folded, has_changes flag)
  - Navigation specification tests (documenting expected behavior)
- [x] **Configurable Stats Logging** - Control message output
  - `show_stats = false` by default (prevents message line wrapping)
  - Can be enabled via config: `pipeline = { show_stats = true }`

### LTO (Link-Time Optimization)
- [x] **LTO Comparison View** - Compare source files before and after LTO
  - Side-by-side diff view
  - Enhanced statistics with deltas
  - Support for multiple source files

### Project Integration
- [x] **compile_commands.json Support** - Seamless build system integration
  - Auto-detect compilation database
  - Extract compiler flags per file
  - Support for both :Godbolt and :GodboltPipeline commands
  - Priority-based search (current dir → project root → parent dirs)

### Output Control
- [x] **Output Preference Control** - Choose between LLVM IR and assembly
  - `output_preference` config option: "auto", "llvm", or "asm"
  - Auto-upgrade to LLVM IR when using compile_commands.json
  - Introspection flags enforced on all clang invocations:
    - `-fno-discard-value-names` - Keep SSA value names
    - `-fstandalone-debug` - Complete debug info

## Pending Features

### Pipeline Viewer - Future Enhancements
- [ ] **Loop Pass Support** - Track loop-level optimizations
  - Parse loop scope passes (e.g., "LoopFullUnrollPass on loop %for.body in function foo")
  - Display loop hierarchy within functions
  - Show which loops were optimized
  - Highlight loop transformations (unrolling, vectorization, etc.)
- [ ] **Capture-Time Filtering** - Filter functions during compilation
  - Use `--filter-print-funcs=<regex>` LLVM flag
  - Config option: `pipeline = { filter_funcs = "main|foo|bar" }`
  - Whitelist/blacklist mode
- [ ] **Runtime Filtering UI** - Interactive filtering while viewing
  - Press 'f' to select specific functions
  - Press 'c' to toggle "changed only" mode
  - Dynamic pass list updates

- [ ] DILexicalBlockScope exploration for scope-aware features
- [ ] Complete assembly line mapping (parse `.loc` directives)

---

### MLIR Support
- [ ] **MLIR Pipeline Viewer** - Leverage existing pipeline infrastructure
  - Support for `mlir-opt` tool
  - Visualize transformations between MLIR dialects (linalg → affine → SCF → LLVM dialect)
  - Per-pass diff view with statistics
  - Support for custom MLIR pass pipelines

- [ ] **MLIR Line Mapping** - Bidirectional source ↔ MLIR mapping
  - Parse MLIR location metadata
  - Support for different MLIR dialects
  - Multi-level mapping (source → high-level IR → low-level IR)

### MLIR Features
- [ ] MLIR Dialect Browser - Navigate between dialect conversions
  - Tree view of dialect hierarchy
  - Highlight dialect-specific operations
  - Quick reference for MLIR ops

### Developer Experience
- [ ] **Live Recompilation Mode** - Great for iterative development
  - Auto-recompile on save
  - Incremental compilation
  - Show diff from previous compilation
  - Watch mode for iterative optimization

### Optimization Analysis
- [ ] **Optimization Level Diff Viewer** - Very useful for learning
  - Side-by-side comparison: -O0 vs -O1 vs -O2 vs -O3
  - Show what each optimization level changes
  - Metrics: code size, instruction count, complexity

- [ ] **Vectorization Report Viewer** - Helps with performance optimization
  - Parse compiler vectorization remarks
  - Highlight vectorized loops
  - Show why loops weren't vectorized
  - Suggest optimization opportunities

### Compiler Support
- [ ] **Multi-Compiler Support** - Broader appeal
  - GCC integration (alongside Clang)
  - MSVC support (Windows)
  - ICC (Intel Compiler)
  - Side-by-side comparison of different compilers

### Navigation & UI
- [ ] **Symbol Browser/Navigator** - Improves usability
  - Jump to function definitions in assembly
  - Cross-reference viewer
  - Call hierarchy
  - Symbol search

- [ ] **Telescope Integration**
  - Fuzzy find passes
  - Jump to symbols
  - Search through IR/assembly
  - Command palette

### External Integration
- [ ] **Godbolt.org API Integration** - Connects to existing ecosystem
  - Share code snippets to godbolt.org
  - Load shared examples
  - Compare with online results
  - Access to multiple compiler versions

### Visualization
- [ ] **Control Flow Graph (CFG) Viewer**
  - Visualize basic blocks and branches
  - Integration with graphviz/mermaid
  - Interactive graph navigation
  - Highlight critical paths

- [ ] **Register Allocation Visualization**
  - Show register usage across function
  - Highlight register pressure
  - Spill/reload visualization
  - Register lifetime analysis

- [ ] **Data Flow Visualization**
  - Track variable flow through IR/assembly
  - Def-use chains
  - Dependency graphs
  - Highlight data dependencies

### Performance Analysis
- [ ] **Performance Metrics Integration** - Deep analysis
  - Instruction latency/throughput estimates
  - Pipeline stall prediction
  - Cache behavior hints
  - uops.info integration for x86

- [ ] **Code Size Metrics Dashboard**
  - Track binary size changes
  - Function-level size breakdown
  - Identify optimization opportunities for size reduction

### Language Support
- [ ] **Cross-Compilation Support**
  - Target different architectures (x86, ARM, RISC-V, etc.)
  - Embedded targets (AVR, MSP430, etc.)
  - Architecture selection UI
  - QEMU integration for testing

### Version Control
- [ ] **Git Integration** - Track changes over time
  - Compare assembly across commits
  - Track code size evolution
  - Performance regression detection
  - Assembly diff in PR reviews

### Interactive Features
- [ ] Interactive Flag Explorer - Helps discover compiler options
  - UI for browsing compiler flags
  - See immediate impact of flag changes
  - Flag recommendation system
  - Save flag presets

- [ ] Assembly Editor with Round-Trip
  - Edit assembly directly
  - Compile back to object code
  - Test modifications
  - Useful for learning/experimentation

### Advanced Optimization Analysis
- [ ] Inlining Visualization
  - Show inline expansion decisions
  - Call graph visualization
  - Toggle inlining on/off for specific functions

- [ ] Loop Analysis Tools
  - Loop unrolling visualization
  - Vectorization opportunities
  - Loop-carried dependencies
  - Trip count analysis

- [ ] Macro Expansion Viewer
  - Show C/C++ macro expansions
  - Template instantiation viewer
  - Preprocessor output with source mapping

- [ ] Memory Layout Visualization
  - Stack frame layout
  - Structure padding/alignment
  - Cache line boundaries
  - Memory access patterns

### Integration Features
- [ ] Debugger Integration
  - Step through assembly with nvim-dap
  - Set breakpoints from assembly view
  - Inspect registers/memory
  - Correlate source, IR, and assembly during debugging

- [ ] Build System Integration
  - Run via CMake/Ninja/Make targets
  - Build specific translation units
  - Show build commands
  - Error/warning navigation

- [ ] Remote Compilation Support
  - Compile on remote servers
  - Access to specific compiler versions
  - Cross-platform compilation
  - CI/CD integration

- [ ] Docker/Container Integration
  - Run compilations in containers
  - Access to different environments
  - Reproducible builds
  - Version matrix testing

- [ ] Compiler Explorer Backend
  - Host your own godbolt instance
  - Use multiple compiler versions
  - Custom tool configurations

### Export & Sharing
- [ ] Export Capabilities
  - Export to HTML (syntax highlighted)
  - Generate PDF reports
  - Markdown export for documentation
  - LaTeX output for papers

- [ ] Snippet Library
  - Save interesting examples
  - Tag and categorize snippets
  - Share within team
  - Template system

### Testing & Validation
- [ ] Assembly Testing Framework
  - Write tests for assembly output
  - Verify optimization properties
  - Regression testing
  - CI integration

- [ ] Fuzzing Integration
  - Compare assembly from fuzzer inputs
  - Find optimization bugs
  - Validate transformations

### Learning & Documentation
- [ ] Instruction Reference System
  - Built-in x86/ARM/etc. instruction reference
  - Show instruction details on hover
  - Timing information
  - Usage examples

- [ ] Optimization Tutorial Mode
  - Interactive lessons
  - Guided optimization exercises
  - Best practices suggestions
  - Anti-pattern detection

- [ ] Assembly Pattern Detection
  - Identify common patterns (loops, function calls, etc.)
  - Suggest improvements
  - Performance anti-pattern warnings
  - Security issue detection (buffer overflows, etc.)

### UI/UX Enhancements
- [ ] Custom Themes for Line Mapping
  - Configurable highlight colors
  - Different styles for different mapping types
  - Colorblind-friendly options

- [ ] Split View Layouts
  - Flexible layout configurations
  - Save/restore layouts
  - Multi-window support
  - Tab management

- [ ] Search & Filter in Assembly/IR
  - Search for specific instructions
  - Filter by instruction type
  - Regex support
  - Bookmarking system

### Platform-Specific Features
- [ ] Embedded Development
  - MCU-specific optimizations
  - Code size focus
  - Memory constraint analysis
  - Startup code visualization

- [ ] GPU/Accelerator Support
  - CUDA PTX output
  - SPIR-V visualization
  - Metal/HLSL/GLSL support
  - Compute shader analysis

### Assembly & Output Improvements
- [ ] **CFI Directive Filtering** - Make assembly output more readable
  - Toggle CFI directives on/off
  - Filter other assembly directives (.section, .align, etc.)
  - Customizable filter rules
  - "Clean view" mode with minimal noise

- [ ] **Complete Assembly Line Mapping** - Finish WIP feature
  - Parse `.loc` directives properly
  - Support for DWARF debug info
  - Handle inline assembly blocks
  - Work with different debug formats (DWARF, CodeView)

### Assembly Enhancement
- [ ] Multiple Assembly Syntax Support
  - Toggle between AT&T and Intel syntax
  - Support for ARM, RISC-V, MIPS assembly
  - Architecture-specific optimization hints

- [ ] Assembly Annotation System
  - Automatically annotate assembly with instruction timing/latency
  - Show which source lines generated which assembly blocks
  - Add comments explaining what each instruction does
  - Instruction reference tooltips/popups



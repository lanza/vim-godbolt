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

Todo?:
* Read from a `compile_commands.json` file.
* Add a different command for `-Xclang -fsyntax-only -Xclang -ast-dump`
* Add a different command for `-emit-llvm`
* Add a different command to run `-flto`
* Parse away some of the cfi statements.

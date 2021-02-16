## Godbolt-like for vim

A simple vim plugin that binds \gb to open a split with the assembly of the
current source file. If the first line of the file starts with `// godbolt: `
the rest of the line will be appended to the list of arguments. You can see an
example here:

![](sample.png)

This also works for Swift:

![](swift.png)

The following variables can be used to modify the behavior (the defaults are
shown):

```
# define the compiler you want to use
let g:godbolt_swiftc = '/usr/binswiftc' # defaults to '/usr/bin/swiftc'
let g:godbolt_clang = 'clang' # defaults to 'clang'

# define some extra args to include
let g:godbolt_cpp_args = "-std=c++20"
let g:godbolt_c_args = "-std=c17"
let g:godbolt_swift_args = ""
```

Todo?:
* Read from a `compile_commands.json` file.
* Add a different command for `-Xclang -fsyntax-only -Xclang -ast-dump`
* Add a different command for `-emit-llvm`
* Add a different command to run `-flto`
* Parse away some of the cfi statements.

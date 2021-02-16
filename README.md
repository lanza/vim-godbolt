## Godbolt-like for vim

A simple vim plugin that binds \gb to open a split with the assembly of the
current source file. If the first line of the file starts with `// godbolt: `
the rest of the line will be appended to the list of arguments. You can see an
example here:

![](sample.png)

This also works for Swift:

![](swift.png)

define i32 @simple(i32 %x) {
entry:
  %a = alloca i32
  store i32 %x, i32* %a
  %loaded = load i32, i32* %a
  %result = add i32 %loaded, 1
  ret i32 %result
}

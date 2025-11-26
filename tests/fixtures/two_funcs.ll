define i32 @foo(i32 %x) {
entry:
  %a = alloca i32
  store i32 %x, i32* %a
  %loaded = load i32, i32* %a
  %result = add i32 %loaded, 1
  ret i32 %result
}

define i32 @bar(i32 %y) {
entry:
  %b = alloca i32
  store i32 %y, i32* %b
  %loaded = load i32, i32* %b
  %result = mul i32 %loaded, 2
  ret i32 %result
}

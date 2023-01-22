
if !exists("g:godbolt_cpp_args")
  let g:godbolt_cpp_args = "-std=c++20"
endif
if !exists("g:godbolt_c_args")
  let g:godbolt_c_args = "-std=c17"
endif
if !exists("g:godbolt_swift_args")
  let g:godbolt_swift_args = ""
endif

if !exists("g:godbolt_clang")
  let g:godbolt_clang = 'clang'
endif
if !exists("g:godbolt_swift")
  let g:godbolt_swiftc = 'swiftc'
endif

function! g:Godbolt(...)
  let l:args = join(a:000, ' ')
  let l:file = expand("%")
  let l:emission = " -S "
  let l:first_line = getbufline(bufnr("%"), 1, 1)[0]
  "echom l:first_line
  if l:first_line =~? "godbolt"
    let l:buffer_args = substitute(l:first_line, "// godbolt:", "", "")
  else
    let l:buffer_args = ""
  endif
  "echom l:buffer_args
  if exists("g:godbolt_window_cmd")
    execute g:godbolt_window_cmd
  else
    vertical botright new
  endif
  if l:buffer_args =~ '-emit-llvm'
    setlocal ft=llvm
  else
    setlocal ft=asm
  endif
  setlocal buftype=nofile
  setlocal bufhidden=hide
  setlocal noswapfile
  setlocal nonumber
  let l:file_and_args = "\"" . l:file . "\"" . " " . l:args
  if l:file =~ "cpp"
    let g:last_godbolt_cmd = ".!" . g:godbolt_clang . '++ '
          \ . l:file_and_args . " "
          \ . l:emission . " "
          \ . " -fno-asynchronous-unwind-tables "
          \ . " -masm=intel "
          \ . g:godbolt_cpp_args . " "
          \ . l:buffer_args . " "
          \ . " -o - "
  elseif l:file =~ "swift"
    let g:last_godbolt_cmd = ".!" . g:godbolt_swiftc . ' '
          \ . l:file_and_args . " "
          \ . l:emission . " "
          \ . " -Xllvm --x86-asm-syntax=intel "
          \ . g:godbolt_swift_args . " "
          \ . l:buffer_args . " "
          \ . " -o - | xcrun swift-demangle"
  elseif l:file =~ ".c"
    let g:last_godbolt_cmd = ".!" . g:godbolt_clang . ' '
          \ . l:file_and_args . " "
          \ . l:emission . " "
          \ . " -fno-asynchronous-unwind-tables "
          \ . " -masm=intel "
          \ . g:godbolt_c_args
          \ . l:buffer_args . " "
          \ . " -o - "
  else
    " this is just a duplicate of the above c case
    let g:last_godbolt_cmd = ".!" . g:godbolt_clang . ' '
          \ . l:file_and_args . " "
          \ . l:emission . " "
          \ . " -fno-asynchronous-unwind-tables "
          \ . " -masm=intel "
          \ . g:godbolt_c_args
          \ . l:buffer_args . " "
          \ . " -o - "
  endif
  echom g:last_godbolt_cmd
  execute(g:last_godbolt_cmd)
  if exists('#User#VimdGodbolt')
    doautocmd User VimGodbolt
  endif
endfunction

command! -nargs=* VGodbolt :call g:Godbolt(<q-args>)


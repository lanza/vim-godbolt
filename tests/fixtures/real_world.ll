; ModuleID = '/private/tmp/IHJj/qs.c'
source_filename = "/private/tmp/IHJj/qs.c"
target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "arm64-apple-macosx26.0.0"

@__const.main.arr = private unnamed_addr constant [6 x i32] [i32 10, i32 7, i32 8, i32 9, i32 1, i32 5], align 4
@.str = private unnamed_addr constant [4 x i8] c"%d \00", align 1, !dbg !0

; Function Attrs: noinline nounwind ssp uwtable(sync)
define void @quicksort(ptr noundef %arr, i32 noundef %low, i32 noundef %high) #0 !dbg !17 {
entry:
  %arr.addr = alloca ptr, align 8
  %low.addr = alloca i32, align 4
  %high.addr = alloca i32, align 4
  %pivot = alloca i32, align 4
  %i = alloca i32, align 4
  %j = alloca i32, align 4
  %temp = alloca i32, align 4
  %temp15 = alloca i32, align 4
  %pi = alloca i32, align 4
  store ptr %arr, ptr %arr.addr, align 8
    #dbg_declare(ptr %arr.addr, !23, !DIExpression(), !24)
  store i32 %low, ptr %low.addr, align 4
    #dbg_declare(ptr %low.addr, !25, !DIExpression(), !26)
  store i32 %high, ptr %high.addr, align 4
    #dbg_declare(ptr %high.addr, !27, !DIExpression(), !28)
  %0 = load i32, ptr %low.addr, align 4, !dbg !29
  %1 = load i32, ptr %high.addr, align 4, !dbg !31
  %cmp = icmp slt i32 %0, %1, !dbg !32
  br i1 %cmp, label %if.then, label %if.end28, !dbg !32

if.then:                                          ; preds = %entry
    #dbg_declare(ptr %pivot, !33, !DIExpression(), !35)
  %2 = load ptr, ptr %arr.addr, align 8, !dbg !36
  %3 = load i32, ptr %high.addr, align 4, !dbg !37
  %idxprom = sext i32 %3 to i64, !dbg !36
  %arrayidx = getelementptr inbounds i32, ptr %2, i64 %idxprom, !dbg !36
  %4 = load i32, ptr %arrayidx, align 4, !dbg !36
  store i32 %4, ptr %pivot, align 4, !dbg !35
    #dbg_declare(ptr %i, !38, !DIExpression(), !39)
  %5 = load i32, ptr %low.addr, align 4, !dbg !40
  %sub = sub nsw i32 %5, 1, !dbg !41
  store i32 %sub, ptr %i, align 4, !dbg !39
    #dbg_declare(ptr %j, !42, !DIExpression(), !44)
  %6 = load i32, ptr %low.addr, align 4, !dbg !45
  store i32 %6, ptr %j, align 4, !dbg !44
  br label %for.cond, !dbg !46

for.cond:                                         ; preds = %for.inc, %if.then
  %7 = load i32, ptr %j, align 4, !dbg !47
  %8 = load i32, ptr %high.addr, align 4, !dbg !49
  %cmp1 = icmp slt i32 %7, %8, !dbg !50
  br i1 %cmp1, label %for.body, label %for.end, !dbg !51

for.body:                                         ; preds = %for.cond
  %9 = load ptr, ptr %arr.addr, align 8, !dbg !52
  %10 = load i32, ptr %j, align 4, !dbg !55
  %idxprom2 = sext i32 %10 to i64, !dbg !52
  %arrayidx3 = getelementptr inbounds i32, ptr %9, i64 %idxprom2, !dbg !52
  %11 = load i32, ptr %arrayidx3, align 4, !dbg !52
  %12 = load i32, ptr %pivot, align 4, !dbg !56
  %cmp4 = icmp slt i32 %11, %12, !dbg !57
  br i1 %cmp4, label %if.then5, label %if.end, !dbg !57

if.then5:                                         ; preds = %for.body
  %13 = load i32, ptr %i, align 4, !dbg !58
  %inc = add nsw i32 %13, 1, !dbg !58
  store i32 %inc, ptr %i, align 4, !dbg !58
    #dbg_declare(ptr %temp, !60, !DIExpression(), !61)
  %14 = load ptr, ptr %arr.addr, align 8, !dbg !62
  %15 = load i32, ptr %i, align 4, !dbg !63
  %idxprom6 = sext i32 %15 to i64, !dbg !62
  %arrayidx7 = getelementptr inbounds i32, ptr %14, i64 %idxprom6, !dbg !62
  %16 = load i32, ptr %arrayidx7, align 4, !dbg !62
  store i32 %16, ptr %temp, align 4, !dbg !61
  %17 = load ptr, ptr %arr.addr, align 8, !dbg !64
  %18 = load i32, ptr %j, align 4, !dbg !65
  %idxprom8 = sext i32 %18 to i64, !dbg !64
  %arrayidx9 = getelementptr inbounds i32, ptr %17, i64 %idxprom8, !dbg !64
  %19 = load i32, ptr %arrayidx9, align 4, !dbg !64
  %20 = load ptr, ptr %arr.addr, align 8, !dbg !66
  %21 = load i32, ptr %i, align 4, !dbg !67
  %idxprom10 = sext i32 %21 to i64, !dbg !66
  %arrayidx11 = getelementptr inbounds i32, ptr %20, i64 %idxprom10, !dbg !66
  store i32 %19, ptr %arrayidx11, align 4, !dbg !68
  %22 = load i32, ptr %temp, align 4, !dbg !69
  %23 = load ptr, ptr %arr.addr, align 8, !dbg !70
  %24 = load i32, ptr %j, align 4, !dbg !71
  %idxprom12 = sext i32 %24 to i64, !dbg !70
  %arrayidx13 = getelementptr inbounds i32, ptr %23, i64 %idxprom12, !dbg !70
  store i32 %22, ptr %arrayidx13, align 4, !dbg !72
  br label %if.end, !dbg !73

if.end:                                           ; preds = %if.then5, %for.body
  br label %for.inc, !dbg !74

for.inc:                                          ; preds = %if.end
  %25 = load i32, ptr %j, align 4, !dbg !75
  %inc14 = add nsw i32 %25, 1, !dbg !75
  store i32 %inc14, ptr %j, align 4, !dbg !75
  br label %for.cond, !dbg !76, !llvm.loop !77

for.end:                                          ; preds = %for.cond
    #dbg_declare(ptr %temp15, !80, !DIExpression(), !81)
  %26 = load ptr, ptr %arr.addr, align 8, !dbg !82
  %27 = load i32, ptr %i, align 4, !dbg !83
  %add = add nsw i32 %27, 1, !dbg !84
  %idxprom16 = sext i32 %add to i64, !dbg !82
  %arrayidx17 = getelementptr inbounds i32, ptr %26, i64 %idxprom16, !dbg !82
  %28 = load i32, ptr %arrayidx17, align 4, !dbg !82
  store i32 %28, ptr %temp15, align 4, !dbg !81
  %29 = load ptr, ptr %arr.addr, align 8, !dbg !85
  %30 = load i32, ptr %high.addr, align 4, !dbg !86
  %idxprom18 = sext i32 %30 to i64, !dbg !85
  %arrayidx19 = getelementptr inbounds i32, ptr %29, i64 %idxprom18, !dbg !85
  %31 = load i32, ptr %arrayidx19, align 4, !dbg !85
  %32 = load ptr, ptr %arr.addr, align 8, !dbg !87
  %33 = load i32, ptr %i, align 4, !dbg !88
  %add20 = add nsw i32 %33, 1, !dbg !89
  %idxprom21 = sext i32 %add20 to i64, !dbg !87
  %arrayidx22 = getelementptr inbounds i32, ptr %32, i64 %idxprom21, !dbg !87
  store i32 %31, ptr %arrayidx22, align 4, !dbg !90
  %34 = load i32, ptr %temp15, align 4, !dbg !91
  %35 = load ptr, ptr %arr.addr, align 8, !dbg !92
  %36 = load i32, ptr %high.addr, align 4, !dbg !93
  %idxprom23 = sext i32 %36 to i64, !dbg !92
  %arrayidx24 = getelementptr inbounds i32, ptr %35, i64 %idxprom23, !dbg !92
  store i32 %34, ptr %arrayidx24, align 4, !dbg !94
    #dbg_declare(ptr %pi, !95, !DIExpression(), !96)
  %37 = load i32, ptr %i, align 4, !dbg !97
  %add25 = add nsw i32 %37, 1, !dbg !98
  store i32 %add25, ptr %pi, align 4, !dbg !96
  %38 = load ptr, ptr %arr.addr, align 8, !dbg !99
  %39 = load i32, ptr %low.addr, align 4, !dbg !100
  %40 = load i32, ptr %pi, align 4, !dbg !101
  %sub26 = sub nsw i32 %40, 1, !dbg !102
  call void @quicksort(ptr noundef %38, i32 noundef %39, i32 noundef %sub26), !dbg !103
  %41 = load ptr, ptr %arr.addr, align 8, !dbg !104
  %42 = load i32, ptr %pi, align 4, !dbg !105
  %add27 = add nsw i32 %42, 1, !dbg !106
  %43 = load i32, ptr %high.addr, align 4, !dbg !107
  call void @quicksort(ptr noundef %41, i32 noundef %add27, i32 noundef %43), !dbg !108
  br label %if.end28, !dbg !109

if.end28:                                         ; preds = %for.end, %entry
  ret void, !dbg !110
}

; Function Attrs: noinline nounwind ssp uwtable(sync)
define i32 @main() #0 !dbg !111 {
entry:
  %retval = alloca i32, align 4
  %arr = alloca [6 x i32], align 4
  %n = alloca i32, align 4
  %i = alloca i32, align 4
  store i32 0, ptr %retval, align 4
    #dbg_declare(ptr %arr, !114, !DIExpression(), !118)
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %arr, ptr align 4 @__const.main.arr, i64 24, i1 false), !dbg !118
    #dbg_declare(ptr %n, !119, !DIExpression(), !120)
  store i32 6, ptr %n, align 4, !dbg !120
  %arraydecay = getelementptr inbounds [6 x i32], ptr %arr, i64 0, i64 0, !dbg !121
  %0 = load i32, ptr %n, align 4, !dbg !122
  %sub = sub nsw i32 %0, 1, !dbg !123
  call void @quicksort(ptr noundef %arraydecay, i32 noundef 0, i32 noundef %sub), !dbg !124
    #dbg_declare(ptr %i, !125, !DIExpression(), !127)
  store i32 0, ptr %i, align 4, !dbg !127
  br label %for.cond, !dbg !128

for.cond:                                         ; preds = %for.inc, %entry
  %1 = load i32, ptr %i, align 4, !dbg !129
  %2 = load i32, ptr %n, align 4, !dbg !131
  %cmp = icmp slt i32 %1, %2, !dbg !132
  br i1 %cmp, label %for.body, label %for.end, !dbg !133

for.body:                                         ; preds = %for.cond
  %3 = load i32, ptr %i, align 4, !dbg !134
  %idxprom = sext i32 %3 to i64, !dbg !135
  %arrayidx = getelementptr inbounds [6 x i32], ptr %arr, i64 0, i64 %idxprom, !dbg !135
  %4 = load i32, ptr %arrayidx, align 4, !dbg !135
  %call = call i32 (ptr, ...) @printf(ptr noundef @.str, i32 noundef %4), !dbg !136
  br label %for.inc, !dbg !136

for.inc:                                          ; preds = %for.body
  %5 = load i32, ptr %i, align 4, !dbg !137
  %inc = add nsw i32 %5, 1, !dbg !137
  store i32 %inc, ptr %i, align 4, !dbg !137
  br label %for.cond, !dbg !138, !llvm.loop !139

for.end:                                          ; preds = %for.cond
  ret i32 0, !dbg !141
}

; Function Attrs: nocallback nofree nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #1

declare i32 @printf(ptr noundef, ...) #2

attributes #0 = { noinline nounwind ssp uwtable(sync) "frame-pointer"="non-leaf" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+ccdp,+ccidx,+ccpp,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8a" }
attributes #1 = { nocallback nofree nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "frame-pointer"="non-leaf" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="apple-m1" "target-features"="+aes,+altnzcv,+ccdp,+ccidx,+ccpp,+complxnum,+crc,+dit,+dotprod,+flagm,+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8a" }

!llvm.dbg.cu = !{!7}
!llvm.module.flags = !{!10, !11, !12, !13, !14, !15}
!llvm.ident = !{!16}

!0 = !DIGlobalVariableExpression(var: !1, expr: !DIExpression())
!1 = distinct !DIGlobalVariable(scope: null, file: !2, line: 29, type: !3, isLocal: true, isDefinition: true)
!2 = !DIFile(filename: "/private/tmp/IHJj/qs.c", directory: "", checksumkind: CSK_MD5, checksum: "7f83a79d17121a2e5da2150a09a7ed23")
!3 = !DICompositeType(tag: DW_TAG_array_type, baseType: !4, size: 32, elements: !5)
!4 = !DIBasicType(name: "char", size: 8, encoding: DW_ATE_signed_char)
!5 = !{!6}
!6 = !DISubrange(count: 4)
!7 = distinct !DICompileUnit(language: DW_LANG_C11, file: !8, producer: "lanza clang version 22.0.0git (https://github.com/lanza/llvm-project d7d344cb7ac46b86492dcaed9736c43c35f731f0)", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug, globals: !9, splitDebugInlining: false, nameTableKind: Apple, sysroot: "/")
!8 = !DIFile(filename: "/private/tmp/IHJj/qs.c", directory: "/tmp/IHJj", checksumkind: CSK_MD5, checksum: "7f83a79d17121a2e5da2150a09a7ed23")
!9 = !{!0}
!10 = !{i32 7, !"Dwarf Version", i32 5}
!11 = !{i32 2, !"Debug Info Version", i32 3}
!12 = !{i32 1, !"wchar_size", i32 4}
!13 = !{i32 8, !"PIC Level", i32 2}
!14 = !{i32 7, !"uwtable", i32 1}
!15 = !{i32 7, !"frame-pointer", i32 1}
!16 = !{!"lanza clang version 22.0.0git (https://github.com/lanza/llvm-project d7d344cb7ac46b86492dcaed9736c43c35f731f0)"}
!17 = distinct !DISubprogram(name: "quicksort", scope: !2, file: !2, line: 3, type: !18, scopeLine: 3, flags: DIFlagPrototyped, spFlags: DISPFlagDefinition, unit: !7, retainedNodes: !22)
!18 = !DISubroutineType(types: !19)
!19 = !{null, !20, !21, !21}
!20 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !21, size: 64)
!21 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!22 = !{}
!23 = !DILocalVariable(name: "arr", arg: 1, scope: !17, file: !2, line: 3, type: !20)
!24 = !DILocation(line: 3, column: 20, scope: !17)
!25 = !DILocalVariable(name: "low", arg: 2, scope: !17, file: !2, line: 3, type: !21)
!26 = !DILocation(line: 3, column: 31, scope: !17)
!27 = !DILocalVariable(name: "high", arg: 3, scope: !17, file: !2, line: 3, type: !21)
!28 = !DILocation(line: 3, column: 40, scope: !17)
!29 = !DILocation(line: 4, column: 7, scope: !30)
!30 = distinct !DILexicalBlock(scope: !17, file: !2, line: 4, column: 7)
!31 = !DILocation(line: 4, column: 13, scope: !30)
!32 = !DILocation(line: 4, column: 11, scope: !30)
!33 = !DILocalVariable(name: "pivot", scope: !34, file: !2, line: 5, type: !21)
!34 = distinct !DILexicalBlock(scope: !30, file: !2, line: 4, column: 19)
!35 = !DILocation(line: 5, column: 9, scope: !34)
!36 = !DILocation(line: 5, column: 17, scope: !34)
!37 = !DILocation(line: 5, column: 21, scope: !34)
!38 = !DILocalVariable(name: "i", scope: !34, file: !2, line: 6, type: !21)
!39 = !DILocation(line: 6, column: 9, scope: !34)
!40 = !DILocation(line: 6, column: 13, scope: !34)
!41 = !DILocation(line: 6, column: 17, scope: !34)
!42 = !DILocalVariable(name: "j", scope: !43, file: !2, line: 7, type: !21)
!43 = distinct !DILexicalBlock(scope: !34, file: !2, line: 7, column: 5)
!44 = !DILocation(line: 7, column: 14, scope: !43)
!45 = !DILocation(line: 7, column: 18, scope: !43)
!46 = !DILocation(line: 7, column: 10, scope: !43)
!47 = !DILocation(line: 7, column: 23, scope: !48)
!48 = distinct !DILexicalBlock(scope: !43, file: !2, line: 7, column: 5)
!49 = !DILocation(line: 7, column: 27, scope: !48)
!50 = !DILocation(line: 7, column: 25, scope: !48)
!51 = !DILocation(line: 7, column: 5, scope: !43)
!52 = !DILocation(line: 8, column: 11, scope: !53)
!53 = distinct !DILexicalBlock(scope: !54, file: !2, line: 8, column: 11)
!54 = distinct !DILexicalBlock(scope: !48, file: !2, line: 7, column: 38)
!55 = !DILocation(line: 8, column: 15, scope: !53)
!56 = !DILocation(line: 8, column: 20, scope: !53)
!57 = !DILocation(line: 8, column: 18, scope: !53)
!58 = !DILocation(line: 9, column: 10, scope: !59)
!59 = distinct !DILexicalBlock(scope: !53, file: !2, line: 8, column: 27)
!60 = !DILocalVariable(name: "temp", scope: !59, file: !2, line: 10, type: !21)
!61 = !DILocation(line: 10, column: 13, scope: !59)
!62 = !DILocation(line: 10, column: 20, scope: !59)
!63 = !DILocation(line: 10, column: 24, scope: !59)
!64 = !DILocation(line: 11, column: 18, scope: !59)
!65 = !DILocation(line: 11, column: 22, scope: !59)
!66 = !DILocation(line: 11, column: 9, scope: !59)
!67 = !DILocation(line: 11, column: 13, scope: !59)
!68 = !DILocation(line: 11, column: 16, scope: !59)
!69 = !DILocation(line: 12, column: 18, scope: !59)
!70 = !DILocation(line: 12, column: 9, scope: !59)
!71 = !DILocation(line: 12, column: 13, scope: !59)
!72 = !DILocation(line: 12, column: 16, scope: !59)
!73 = !DILocation(line: 13, column: 7, scope: !59)
!74 = !DILocation(line: 14, column: 5, scope: !54)
!75 = !DILocation(line: 7, column: 34, scope: !48)
!76 = !DILocation(line: 7, column: 5, scope: !48)
!77 = distinct !{!77, !51, !78, !79}
!78 = !DILocation(line: 14, column: 5, scope: !43)
!79 = !{!"llvm.loop.mustprogress"}
!80 = !DILocalVariable(name: "temp", scope: !34, file: !2, line: 15, type: !21)
!81 = !DILocation(line: 15, column: 9, scope: !34)
!82 = !DILocation(line: 15, column: 16, scope: !34)
!83 = !DILocation(line: 15, column: 20, scope: !34)
!84 = !DILocation(line: 15, column: 22, scope: !34)
!85 = !DILocation(line: 16, column: 18, scope: !34)
!86 = !DILocation(line: 16, column: 22, scope: !34)
!87 = !DILocation(line: 16, column: 5, scope: !34)
!88 = !DILocation(line: 16, column: 9, scope: !34)
!89 = !DILocation(line: 16, column: 11, scope: !34)
!90 = !DILocation(line: 16, column: 16, scope: !34)
!91 = !DILocation(line: 17, column: 17, scope: !34)
!92 = !DILocation(line: 17, column: 5, scope: !34)
!93 = !DILocation(line: 17, column: 9, scope: !34)
!94 = !DILocation(line: 17, column: 15, scope: !34)
!95 = !DILocalVariable(name: "pi", scope: !34, file: !2, line: 18, type: !21)
!96 = !DILocation(line: 18, column: 9, scope: !34)
!97 = !DILocation(line: 18, column: 14, scope: !34)
!98 = !DILocation(line: 18, column: 16, scope: !34)
!99 = !DILocation(line: 19, column: 15, scope: !34)
!100 = !DILocation(line: 19, column: 20, scope: !34)
!101 = !DILocation(line: 19, column: 25, scope: !34)
!102 = !DILocation(line: 19, column: 28, scope: !34)
!103 = !DILocation(line: 19, column: 5, scope: !34)
!104 = !DILocation(line: 20, column: 15, scope: !34)
!105 = !DILocation(line: 20, column: 20, scope: !34)
!106 = !DILocation(line: 20, column: 23, scope: !34)
!107 = !DILocation(line: 20, column: 28, scope: !34)
!108 = !DILocation(line: 20, column: 5, scope: !34)
!109 = !DILocation(line: 21, column: 3, scope: !34)
!110 = !DILocation(line: 22, column: 1, scope: !17)
!111 = distinct !DISubprogram(name: "main", scope: !2, file: !2, line: 24, type: !112, scopeLine: 24, spFlags: DISPFlagDefinition, unit: !7, retainedNodes: !22)
!112 = !DISubroutineType(types: !113)
!113 = !{!21}
!114 = !DILocalVariable(name: "arr", scope: !111, file: !2, line: 25, type: !115)
!115 = !DICompositeType(tag: DW_TAG_array_type, baseType: !21, size: 192, elements: !116)
!116 = !{!117}
!117 = !DISubrange(count: 6)
!118 = !DILocation(line: 25, column: 7, scope: !111)
!119 = !DILocalVariable(name: "n", scope: !111, file: !2, line: 26, type: !21)
!120 = !DILocation(line: 26, column: 7, scope: !111)
!121 = !DILocation(line: 27, column: 13, scope: !111)
!122 = !DILocation(line: 27, column: 21, scope: !111)
!123 = !DILocation(line: 27, column: 23, scope: !111)
!124 = !DILocation(line: 27, column: 3, scope: !111)
!125 = !DILocalVariable(name: "i", scope: !126, file: !2, line: 28, type: !21)
!126 = distinct !DILexicalBlock(scope: !111, file: !2, line: 28, column: 3)
!127 = !DILocation(line: 28, column: 12, scope: !126)
!128 = !DILocation(line: 28, column: 8, scope: !126)
!129 = !DILocation(line: 28, column: 19, scope: !130)
!130 = distinct !DILexicalBlock(scope: !126, file: !2, line: 28, column: 3)
!131 = !DILocation(line: 28, column: 23, scope: !130)
!132 = !DILocation(line: 28, column: 21, scope: !130)
!133 = !DILocation(line: 28, column: 3, scope: !126)
!134 = !DILocation(line: 29, column: 23, scope: !130)
!135 = !DILocation(line: 29, column: 19, scope: !130)
!136 = !DILocation(line: 29, column: 5, scope: !130)
!137 = !DILocation(line: 28, column: 27, scope: !130)
!138 = !DILocation(line: 28, column: 3, scope: !130)
!139 = distinct !{!139, !133, !140, !79}
!140 = !DILocation(line: 29, column: 25, scope: !126)
!141 = !DILocation(line: 30, column: 3, scope: !111)


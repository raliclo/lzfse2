@echo off
chcp 65001 > nul
setlocal EnableDelayedExpansion
:: Usage: decode-win.bat <dataset> [n] [write]
:: Default: decode to nul (no disk writes) for speed benchmark.
:: With [write]: decode to decoded\<dataset>\<algo> and compare each algo output with TGZ output.
:: Prerequisite: run encode-win.bat first to produce the compressed files.

set "_tgz_tar=tar"
if "%LZFSE_REQUIRE_NATIVE_ZLIB%"=="1" (
    if not defined SWIFT_TAR_BIN (
        echo [Error] native zlib mode requires SWIFT_TAR_BIN. >&2
        exit /b 1
    )
    if not exist "%SWIFT_TAR_BIN%" (
        echo [Error] SWIFT_TAR_BIN not found: %SWIFT_TAR_BIN% >&2
        exit /b 1
    )
    set "_tgz_tar=%SWIFT_TAR_BIN%"
    echo [Info] TGZ backend: %SWIFT_TAR_BIN% ^(native zlib^)
)

set "_zstd_tar="
if "%LZFSE_REQUIRE_NATIVE_ZSTD%"=="1" (
    if not defined SWIFT_TAR_BIN (
        echo [Error] native zstd mode requires SWIFT_TAR_BIN. >&2
        exit /b 1
    )
    if not exist "%SWIFT_TAR_BIN%" (
        echo [Error] SWIFT_TAR_BIN not found: %SWIFT_TAR_BIN% >&2
        exit /b 1
    )
    set "_zstd_tar=%SWIFT_TAR_BIN%"
    echo [Info] ZSTD backend: %SWIFT_TAR_BIN% ^(native libzstd^)
)

set "_dataset=%~1"
set "_logprefix=%~nx1"
if "%_logprefix%"=="" set "_logprefix=dataset"
set "_n=%~2"
set "_write=0"
if /I "%~3"=="write" set "_write=1"
set "_decode_output_note=write to nul"
if "%_write%"=="1" set "_decode_output_note=write to file"
set "_mode_suffix=-nul"
if "%_write%"=="1" set "_mode_suffix=-file"

if "%_dataset%"=="" (
    echo Usage: decode-win.bat ^<dataset^> [n] [write]
    exit /b 1
)

set "_missing=0"
for %%F in (
    "%_dataset%.tgz"
    "%_dataset%.lzfse.other3"
    "%_dataset%.lzfse.other3.optimal3"
    "%_dataset%.lzfse.bvx3"
    "%_dataset%.lzfse.lazy2"
    "%_dataset%.lzfse.optimal"
    "%_dataset%.tar.lz4"
    "%_dataset%.tar.zst"
) do (
    if not exist %%F (
        echo [WARN] Compressed file not found: %%F
        set "_missing=1"
    )
)
if "%_missing%"=="1" (
    echo [WARN] Some compressed files missing - run encode-win.bat first.
)

if not exist bench_logs mkdir bench_logs
if not exist bench_results_csv mkdir bench_results_csv
if "%_write%"=="1" if not exist decoded mkdir decoded
set "_nsuffix="
if not "%_n%"=="" set "_nsuffix=-n%_n%"

echo [Info] Warming cache for decode benchmark... %TIME:~0,8%
call :warmCache "%_dataset%"

if "%_write%"=="1" (
    echo [Info] Starting decode benchmark with write output to decoded\%_logprefix% ... %TIME:~0,8%
) else (
    echo [Info] Starting decode benchmark... %TIME:~0,8%
)

echo [Info] Running tgz decode benchmark... %TIME:~0,8%
call :nanoTimeElapsed call :decodeTgz "%_dataset%" > "bench_logs\%_logprefix%-decodeTgz%_nsuffix%%_mode_suffix%-results.txt" 2>&1
call :appendDecodedFolderSize "%_dataset%" "bench_logs\%_logprefix%-decodeTgz%_nsuffix%%_mode_suffix%-results.txt"
call :writeDecodeOutputMode "bench_logs\%_logprefix%-decodeTgz%_nsuffix%%_mode_suffix%-results.txt"
echo [DONE] tgz decode %TIME:~0,8%

echo [Info] Running lzfse other3 decode benchmark... %TIME:~0,8%
call :nanoTimeElapsed call :decodeOther3 "%_dataset%" "%_n%" > "bench_logs\%_logprefix%-decodeOther3%_nsuffix%%_mode_suffix%-results.txt" 2>&1
call :appendDecodedFolderSize "%_dataset%" "bench_logs\%_logprefix%-decodeOther3%_nsuffix%%_mode_suffix%-results.txt"
call :writeDecodeOutputMode "bench_logs\%_logprefix%-decodeOther3%_nsuffix%%_mode_suffix%-results.txt"
echo [DONE] lzfse other3 decode %TIME:~0,8%

echo [Info] Running lzfse other3_optimal3 decode benchmark... %TIME:~0,8%
call :nanoTimeElapsed call :decodeOptimal3 "%_dataset%" "%_n%" > "bench_logs\%_logprefix%-decodeOptimal3%_nsuffix%%_mode_suffix%-results.txt" 2>&1
call :appendDecodedFolderSize "%_dataset%" "bench_logs\%_logprefix%-decodeOptimal3%_nsuffix%%_mode_suffix%-results.txt"
call :writeDecodeOutputMode "bench_logs\%_logprefix%-decodeOptimal3%_nsuffix%%_mode_suffix%-results.txt"
echo [DONE] lzfse other3_optimal3 decode %TIME:~0,8%

echo [Info] Running lzfse bvx3 decode benchmark... %TIME:~0,8%
call :nanoTimeElapsed call :decodeBVX3 "%_dataset%" "%_n%" > "bench_logs\%_logprefix%-decodeBVX3%_nsuffix%%_mode_suffix%-results.txt" 2>&1
call :appendDecodedFolderSize "%_dataset%" "bench_logs\%_logprefix%-decodeBVX3%_nsuffix%%_mode_suffix%-results.txt"
call :writeDecodeOutputMode "bench_logs\%_logprefix%-decodeBVX3%_nsuffix%%_mode_suffix%-results.txt"
echo [DONE] lzfse bvx3 decode %TIME:~0,8%

echo [Info] Running lzfse lazy2 decode benchmark... %TIME:~0,8%
call :nanoTimeElapsed call :decodeLazy2 "%_dataset%" "%_n%" > "bench_logs\%_logprefix%-decodeLazy2%_nsuffix%%_mode_suffix%-results.txt" 2>&1
call :appendDecodedFolderSize "%_dataset%" "bench_logs\%_logprefix%-decodeLazy2%_nsuffix%%_mode_suffix%-results.txt"
call :writeDecodeOutputMode "bench_logs\%_logprefix%-decodeLazy2%_nsuffix%%_mode_suffix%-results.txt"
echo [DONE] lzfse lazy2 decode %TIME:~0,8%

echo [Info] Running lzfse optimal decode benchmark... %TIME:~0,8%
call :nanoTimeElapsed call :decodeOptimal "%_dataset%" "%_n%" > "bench_logs\%_logprefix%-decodeOptimal%_nsuffix%%_mode_suffix%-results.txt" 2>&1
call :appendDecodedFolderSize "%_dataset%" "bench_logs\%_logprefix%-decodeOptimal%_nsuffix%%_mode_suffix%-results.txt"
call :writeDecodeOutputMode "bench_logs\%_logprefix%-decodeOptimal%_nsuffix%%_mode_suffix%-results.txt"
echo [DONE] lzfse optimal decode %TIME:~0,8%

echo [Info] Running lz4 decode benchmark... %TIME:~0,8%
call :nanoTimeElapsed call :decodeLZ4 "%_dataset%" > "bench_logs\%_logprefix%-decodeLZ4%_nsuffix%%_mode_suffix%-results.txt" 2>&1
call :appendDecodedFolderSize "%_dataset%" "bench_logs\%_logprefix%-decodeLZ4%_nsuffix%%_mode_suffix%-results.txt"
call :writeDecodeOutputMode "bench_logs\%_logprefix%-decodeLZ4%_nsuffix%%_mode_suffix%-results.txt"
echo [DONE] lz4 decode %TIME:~0,8%

echo [Info] Running zstd decode benchmark... %TIME:~0,8%
call :nanoTimeElapsed call :decodeZSTD "%_dataset%" > "bench_logs\%_logprefix%-decodeZSTD%_nsuffix%%_mode_suffix%-results.txt" 2>&1
call :appendDecodedFolderSize "%_dataset%" "bench_logs\%_logprefix%-decodeZSTD%_nsuffix%%_mode_suffix%-results.txt"
call :writeDecodeOutputMode "bench_logs\%_logprefix%-decodeZSTD%_nsuffix%%_mode_suffix%-results.txt"
echo [DONE] zstd decode %TIME:~0,8%

if "%_write%"=="1" goto verifyWrite
goto verifyStream

:verifyWrite
echo [Info] Verifying decoded folders against TGZ output... %TIME:~0,8%
call :verifyDecodedNonEmpty TGZ "bench_logs\%_logprefix%-decodeTgz%_nsuffix%%_mode_suffix%-results.txt" "decoded\%_logprefix%\tgz"
call :verifyAgainstTgz "LZFSE Other3" "bench_logs\%_logprefix%-decodeOther3%_nsuffix%%_mode_suffix%-results.txt" "decoded\%_logprefix%\other3"
if not errorlevel 1 call :removeDecodedFolder "decoded\%_logprefix%\other3"
call :verifyAgainstTgz "LZFSE Optimal3" "bench_logs\%_logprefix%-decodeOptimal3%_nsuffix%%_mode_suffix%-results.txt" "decoded\%_logprefix%\optimal3"
if not errorlevel 1 call :removeDecodedFolder "decoded\%_logprefix%\optimal3"
call :verifyAgainstTgz "LZFSE BVX3" "bench_logs\%_logprefix%-decodeBVX3%_nsuffix%%_mode_suffix%-results.txt" "decoded\%_logprefix%\bvx3"
if not errorlevel 1 call :removeDecodedFolder "decoded\%_logprefix%\bvx3"
call :verifyAgainstTgz "LZFSE Lazy2" "bench_logs\%_logprefix%-decodeLazy2%_nsuffix%%_mode_suffix%-results.txt" "decoded\%_logprefix%\lazy2"
if not errorlevel 1 call :removeDecodedFolder "decoded\%_logprefix%\lazy2"
call :verifyAgainstTgz "LZFSE Optimal" "bench_logs\%_logprefix%-decodeOptimal%_nsuffix%%_mode_suffix%-results.txt" "decoded\%_logprefix%\optimal"
if not errorlevel 1 call :removeDecodedFolder "decoded\%_logprefix%\optimal"
call :verifyAgainstTgz LZ4 "bench_logs\%_logprefix%-decodeLZ4%_nsuffix%%_mode_suffix%-results.txt" "decoded\%_logprefix%\lz4"
if not errorlevel 1 call :removeDecodedFolder "decoded\%_logprefix%\lz4"
call :verifyAgainstTgz ZSTD "bench_logs\%_logprefix%-decodeZSTD%_nsuffix%%_mode_suffix%-results.txt" "decoded\%_logprefix%\zstd"
if not errorlevel 1 call :removeDecodedFolder "decoded\%_logprefix%\zstd"
goto afterVerify

:verifyStream
echo [Info] Verifying decode correctness (tar tf check)... %TIME:~0,8%
call :verifyStreamTgz
call :verifyStreamOther3
call :verifyStreamOptimal3
call :verifyStreamBVX3
call :verifyStreamLazy2
call :verifyStreamOptimal
call :verifyStreamLZ4
call :verifyStreamZSTD

:afterVerify

echo [Info] Summarising decode results... %TIME:~0,8%
python summarize_win.py --results-dir . --decode-output bench_results_csv\decode_summary.csv
if errorlevel 1 exit /b 1
echo [OK] bench_results_csv\decode_summary.csv written %TIME:~0,8%

echo [Info] Decode verification complete. %TIME:~0,8%
goto :EOF

:decodeTgz
if "%_write%"=="1" (
    call :prepareOut "decoded\%_logprefix%\tgz"
    "!_tgz_tar!" xzf "%~1.tgz" -C "decoded\%_logprefix%\tgz" > nul
) else (
    "!_tgz_tar!" --to-stdout -xzf "%~1.tgz" > nul 2>&1
)
exit /b

:decodeOther3
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
if "%_write%"=="1" (
    call :prepareOut "decoded\%_logprefix%\other3"
    .\lzfse.exe -decode -i "%~1.lzfse.other3" -so -algo other3 %_n_opt% | tar xf - -C "decoded\%_logprefix%\other3" > nul
) else (
    .\lzfse.exe -decode -i "%~1.lzfse.other3" -so -algo other3 %_n_opt% > nul 2>&1
)
exit /b

:decodeOptimal3
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
if "%_write%"=="1" (
    call :prepareOut "decoded\%_logprefix%\optimal3"
    .\lzfse.exe -decode -i "%~1.lzfse.other3.optimal3" -so -algo other3 %_n_opt% | tar xf - -C "decoded\%_logprefix%\optimal3" > nul
) else (
    .\lzfse.exe -decode -i "%~1.lzfse.other3.optimal3" -so -algo other3 %_n_opt% > nul 2>&1
)
exit /b

:decodeBVX3
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
if "%_write%"=="1" (
    call :prepareOut "decoded\%_logprefix%\bvx3"
    .\lzfse.exe -decode -i "%~1.lzfse.bvx3" -so -algo bvx3 %_n_opt% | tar xf - -C "decoded\%_logprefix%\bvx3" > nul
) else (
    .\lzfse.exe -decode -i "%~1.lzfse.bvx3" -so -algo bvx3 %_n_opt% > nul 2>&1
)
exit /b

:decodeLazy2
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
if "%_write%"=="1" (
    call :prepareOut "decoded\%_logprefix%\lazy2"
    .\lzfse.exe -decode -i "%~1.lzfse.lazy2" -so -algo bvx3 -lazy2 %_n_opt% | tar xf - -C "decoded\%_logprefix%\lazy2" > nul
) else (
    .\lzfse.exe -decode -i "%~1.lzfse.lazy2" -so -algo bvx3 -lazy2 %_n_opt% > nul 2>&1
)
exit /b

:decodeOptimal
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
if "%_write%"=="1" (
    call :prepareOut "decoded\%_logprefix%\optimal"
    .\lzfse.exe -decode -i "%~1.lzfse.optimal" -so -algo bvx3 -optimal %_n_opt% | tar xf - -C "decoded\%_logprefix%\optimal" > nul
) else (
    .\lzfse.exe -decode -i "%~1.lzfse.optimal" -so -algo bvx3 -optimal %_n_opt% > nul 2>&1
)
exit /b

:decodeLZ4
if "%_write%"=="1" (
    call :prepareOut "decoded\%_logprefix%\lz4"
    lz4 -d -c -q "%~1.tar.lz4" | tar xf - -C "decoded\%_logprefix%\lz4" > nul
) else (
    lz4 -d -c -q "%~1.tar.lz4" > nul 2>&1
)
exit /b

:decodeZSTD
:: Native mode extracts in one process; the external branch pipes zstd.exe into
:: tar. Decode needs no level flag -- the level is recorded in the frame.
if "%LZFSE_REQUIRE_NATIVE_ZSTD%"=="1" goto :decodeZSTDNative
if "%_write%"=="1" (
    call :prepareOut "decoded\%_logprefix%\zstd"
    zstd -d -c -q "%~1.tar.zst" | tar xf - -C "decoded\%_logprefix%\zstd" > nul
) else (
    zstd -d -c -q "%~1.tar.zst" > nul 2>&1
)
exit /b

:decodeZSTDNative
if "%_write%"=="1" (
    call :prepareOut "decoded\%_logprefix%\zstd"
    "!_zstd_tar!" -x -f "%~1.tar.zst" -C "decoded\%_logprefix%\zstd" > nul
) else (
    "!_zstd_tar!" --to-stdout -x -f "%~1.tar.zst" > nul 2>&1
)
exit /b

:verifyStreamTgz
"%_tgz_tar%" tzf "%_dataset%.tgz" > nul 2>&1
if !ERRORLEVEL! == 0 ( echo [PASS] TGZ & call :writeVerify "bench_logs\%_logprefix%-decodeTgz%_nsuffix%%_mode_suffix%-results.txt" PASS ) else ( echo [FAIL] TGZ & call :writeVerify "bench_logs\%_logprefix%-decodeTgz%_nsuffix%%_mode_suffix%-results.txt" FAIL )
exit /b

:verifyStreamOther3
.\lzfse.exe -decode -i "%_dataset%.lzfse.other3" -so -algo other3 | tar tf - > nul 2>&1
if !ERRORLEVEL! == 0 ( echo [PASS] LZFSE Other3 & call :writeVerify "bench_logs\%_logprefix%-decodeOther3%_nsuffix%%_mode_suffix%-results.txt" PASS ) else ( echo [FAIL] LZFSE Other3 & call :writeVerify "bench_logs\%_logprefix%-decodeOther3%_nsuffix%%_mode_suffix%-results.txt" FAIL )
exit /b

:verifyStreamOptimal3
.\lzfse.exe -decode -i "%_dataset%.lzfse.other3.optimal3" -so -algo other3 | tar tf - > nul 2>&1
if !ERRORLEVEL! == 0 ( echo [PASS] LZFSE Optimal3 & call :writeVerify "bench_logs\%_logprefix%-decodeOptimal3%_nsuffix%%_mode_suffix%-results.txt" PASS ) else ( echo [FAIL] LZFSE Optimal3 & call :writeVerify "bench_logs\%_logprefix%-decodeOptimal3%_nsuffix%%_mode_suffix%-results.txt" FAIL )
exit /b

:verifyStreamBVX3
.\lzfse.exe -decode -i "%_dataset%.lzfse.bvx3" -so -algo bvx3 | tar tf - > nul 2>&1
if !ERRORLEVEL! == 0 ( echo [PASS] LZFSE BVX3 & call :writeVerify "bench_logs\%_logprefix%-decodeBVX3%_nsuffix%%_mode_suffix%-results.txt" PASS ) else ( echo [FAIL] LZFSE BVX3 & call :writeVerify "bench_logs\%_logprefix%-decodeBVX3%_nsuffix%%_mode_suffix%-results.txt" FAIL )
exit /b

:verifyStreamLazy2
.\lzfse.exe -decode -i "%_dataset%.lzfse.lazy2" -so -algo bvx3 -lazy2 | tar tf - > nul 2>&1
if !ERRORLEVEL! == 0 ( echo [PASS] LZFSE Lazy2 & call :writeVerify "bench_logs\%_logprefix%-decodeLazy2%_nsuffix%%_mode_suffix%-results.txt" PASS ) else ( echo [FAIL] LZFSE Lazy2 & call :writeVerify "bench_logs\%_logprefix%-decodeLazy2%_nsuffix%%_mode_suffix%-results.txt" FAIL )
exit /b

:verifyStreamOptimal
.\lzfse.exe -decode -i "%_dataset%.lzfse.optimal" -so -algo bvx3 -optimal | tar tf - > nul 2>&1
if !ERRORLEVEL! == 0 ( echo [PASS] LZFSE Optimal & call :writeVerify "bench_logs\%_logprefix%-decodeOptimal%_nsuffix%%_mode_suffix%-results.txt" PASS ) else ( echo [FAIL] LZFSE Optimal & call :writeVerify "bench_logs\%_logprefix%-decodeOptimal%_nsuffix%%_mode_suffix%-results.txt" FAIL )
exit /b

:verifyStreamLZ4
lz4 -d -c -q "%_dataset%.tar.lz4" | tar tf - > nul 2>&1
if !ERRORLEVEL! == 0 ( echo [PASS] LZ4 & call :writeVerify "bench_logs\%_logprefix%-decodeLZ4%_nsuffix%%_mode_suffix%-results.txt" PASS ) else ( echo [FAIL] LZ4 & call :writeVerify "bench_logs\%_logprefix%-decodeLZ4%_nsuffix%%_mode_suffix%-results.txt" FAIL )
exit /b

:verifyStreamZSTD
if "%LZFSE_REQUIRE_NATIVE_ZSTD%"=="1" goto :verifyStreamZSTDNative
zstd -d -c -q "%_dataset%.tar.zst" | tar tf - > nul 2>&1
goto :verifyStreamZSTDResult
:verifyStreamZSTDNative
"!_zstd_tar!" -t -f "%_dataset%.tar.zst" > nul 2>&1
:verifyStreamZSTDResult
if !ERRORLEVEL! == 0 ( echo [PASS] ZSTD & call :writeVerify "bench_logs\%_logprefix%-decodeZSTD%_nsuffix%%_mode_suffix%-results.txt" PASS ) else ( echo [FAIL] ZSTD & call :writeVerify "bench_logs\%_logprefix%-decodeZSTD%_nsuffix%%_mode_suffix%-results.txt" FAIL )
exit /b

:prepareOut
powershell -NoProfile -Command "if (Test-Path -LiteralPath '%~1') { Remove-Item -LiteralPath '%~1' -Recurse -Force }; New-Item -ItemType Directory -Force -Path '%~1' | Out-Null"
exit /b

:verifyAgainstTgz
:: %~1 = display name, %~2 = result file, %~3 = output folder
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0compare-decoded-win.ps1" -Reference "decoded\%_logprefix%\tgz" -Candidate "%~3" -Name "%~1" -ResultFile "%~2"
exit /b

:verifyDecodedNonEmpty
:: %~1 = display name, %~2 = result file, %~3 = output folder
powershell -NoProfile -Command "$path='%~3'; $count=0; if (Test-Path -LiteralPath $path) { $count=@(Get-ChildItem -LiteralPath $path -Recurse -File -Force).Count }; if ($count -gt 0) { Write-Output('[PASS] %~1'); '==> Verify: PASS' | Out-File -Append -Encoding UTF8 -LiteralPath '%~2'; exit 0 }; Write-Output('[FAIL] %~1'); Write-Output('  output has no files: '+$path); '==> Verify: FAIL' | Out-File -Append -Encoding UTF8 -LiteralPath '%~2'; '==> Verify diff:' | Out-File -Append -Encoding UTF8 -LiteralPath '%~2'; ('output has no files: '+$path) | Out-File -Append -Encoding UTF8 -LiteralPath '%~2'; exit 1"
exit /b

:removeDecodedFolder
:: Remove per-algorithm decoded output after comparison. Keep decoded\<dataset>\tgz as reference.
powershell -NoProfile -Command "if (Test-Path -LiteralPath '%~1') { Remove-Item -LiteralPath '%~1' -Recurse -Force }"
exit /b

:warmCache
for %%F in (
    "%~1.tgz"
    "%~1.lzfse.other3"
    "%~1.lzfse.other3.optimal3"
    "%~1.lzfse.bvx3"
    "%~1.lzfse.lazy2"
    "%~1.lzfse.optimal"
    "%~1.tar.lz4"
    "%~1.tar.zst"
) do (
    if exist %%F (
        powershell -NoProfile -Command "$null=[IO.File]::ReadAllBytes('%%~F')" 2>nul
    )
)
exit /b

:appendFileSize
:: %~1 = compressed file path, %~2 = log file path
powershell -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; if (Test-Path '%~1') { $s=(Get-Item '%~1').Length; Write-Output('==> Encoded size: '+$s+' bytes') } else { Write-Output('Compressed file not found: %~1') }" >> "%~2"
exit /b

:appendDecodedFolderSize
:: %~1 = source dataset folder (original uncompressed data), %~2 = log file path
powershell -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; $p='%~1'; if (Test-Path -LiteralPath $p -PathType Container) { $s=(Get-ChildItem -LiteralPath $p -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum; if ($null -eq $s) { $s=0 } } else { $s=0 }; Write-Output('==> Decoded size: '+$s+' bytes')" >> "%~2"
exit /b

:writeDecodeOutputMode
powershell -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Write-Output('==> Decode output: %_decode_output_note%')" >> "%~1"
exit /b

:writeVerify
:: %~1 = result file path, %~2 = PASS or FAIL
powershell -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Write-Output('==> Verify: %~2')" >> "%~1"
exit /b

:nanoTimeElapsed
for /f %%T in ('powershell -NoProfile -Command "[System.Diagnostics.Stopwatch]::GetTimestamp()"') do set "_t0=%%T"
%1 %2 %3 %4 %5
set _rc=%ERRORLEVEL%
for /f %%T in ('powershell -NoProfile -Command "[System.Diagnostics.Stopwatch]::GetTimestamp()"') do set "_t1=%%T"
powershell -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; $ns=([long]'%_t1%'-[long]'%_t0%')*1000000000/[System.Diagnostics.Stopwatch]::Frequency; Write-Output ('==> Process took: '+$ns.ToString('D10')+' nanoseconds')"
exit /b %_rc%

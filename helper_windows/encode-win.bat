@echo off
chcp 65001 > nul
setlocal EnableDelayedExpansion

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
    echo [Info] ZSTD backend: %SWIFT_TAR_BIN% ^(native libzstd, level 9^)
)

if "%~1"=="" (
    echo Usage: encode-win.bat ^<dataset^> [n] [write]
    exit /b 1
)

set "_dataset=%~1"
set "_logprefix=%~nx1"
if "%_logprefix%"=="" set "_logprefix=dataset"
for /f "tokens=1,* delims=|" %%A in ('powershell -NoProfile -Command "$item=Get-Item -LiteralPath '%_dataset%'; Write-Output ((Split-Path -Parent $item.FullName)+'|'+$item.Name)"') do (
    set "_tar_parent=%%~A"
    set "_tar_leaf=%%~B"
)
set "_write=0"
if /I "%~3"=="write" set "_write=1"
set "_encode_output_note=write to nul"
if "%_write%"=="1" set "_encode_output_note=write to file"
set "_mode_suffix=-nul"
if "%_write%"=="1" set "_mode_suffix=-file"

:: Warm-cache: pre-read the whole dataset so every compression format is timed under the same warm-cache condition.
echo [Info] Warm-cache dataset / Pre-reading dataset to warm OS cache...
call :tarWarmup "%_dataset%"

if not exist bench_logs mkdir bench_logs
if not exist bench_results_csv mkdir bench_results_csv

set "_nsuffix="
if not "%~2"=="" set "_nsuffix=-n%~2"

powershell -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Write-Output('[Info] Starting tgz, lzfse, tlz4, zstd benchmark... %TIME:~0,8%')"

echo [Info] Running tgz encode benchmark... %TIME:~0,8%
call :nanoTimeElapsed call :encodeTgz "%_dataset%" > ".\bench_logs\%_logprefix%-encodeTgz%_nsuffix%%_mode_suffix%-results.txt"
call :appendFileSize "%_dataset%.tgz" "bench_logs\%_logprefix%-encodeTgz%_nsuffix%%_mode_suffix%-results.txt"
call :writeEncodeOutputMode "bench_logs\%_logprefix%-encodeTgz%_nsuffix%%_mode_suffix%-results.txt"
echo [DONE] tgz encode %TIME:~0,8%

echo [Info] Running lzfse other3 encode benchmark... %TIME:~0,8%
call :nanoTimeElapsed call :encodeOther3 "%_dataset%" "%~2" > ".\bench_logs\%_logprefix%-encodeOther3%_nsuffix%%_mode_suffix%-results.txt"
call :appendFileSize "%_dataset%.lzfse.other3" "bench_logs\%_logprefix%-encodeOther3%_nsuffix%%_mode_suffix%-results.txt"
call :writeEncodeOutputMode "bench_logs\%_logprefix%-encodeOther3%_nsuffix%%_mode_suffix%-results.txt"
echo [DONE] lzfse other3 encode %TIME:~0,8%

echo [Info] Running lzfse other3_optimal3 encode benchmark... %TIME:~0,8%
call :nanoTimeElapsed call :encodeOptimal3 "%_dataset%" "%~2" > ".\bench_logs\%_logprefix%-encodeOptimal3%_nsuffix%%_mode_suffix%-results.txt"
call :appendFileSize "%_dataset%.lzfse.other3.optimal3" "bench_logs\%_logprefix%-encodeOptimal3%_nsuffix%%_mode_suffix%-results.txt"
call :writeEncodeOutputMode "bench_logs\%_logprefix%-encodeOptimal3%_nsuffix%%_mode_suffix%-results.txt"
echo [DONE] lzfse other3_optimal3 encode %TIME:~0,8%

echo [Info] Running lzfse bvx3 encode benchmark... %TIME:~0,8%
call :nanoTimeElapsed call :encodeBVX3 "%_dataset%" "%~2" > ".\bench_logs\%_logprefix%-encodeBVX3%_nsuffix%%_mode_suffix%-results.txt"
call :appendFileSize "%_dataset%.lzfse.bvx3" "bench_logs\%_logprefix%-encodeBVX3%_nsuffix%%_mode_suffix%-results.txt"
call :writeEncodeOutputMode "bench_logs\%_logprefix%-encodeBVX3%_nsuffix%%_mode_suffix%-results.txt"
echo [DONE] lzfse bvx3 encode %TIME:~0,8%

echo [Info] Running lzfse lazy2 encode benchmark... %TIME:~0,8%
call :nanoTimeElapsed call :encodeLazy2 "%_dataset%" "%~2" > ".\bench_logs\%_logprefix%-encodeLazy2%_nsuffix%%_mode_suffix%-results.txt"
call :appendFileSize "%_dataset%.lzfse.lazy2" "bench_logs\%_logprefix%-encodeLazy2%_nsuffix%%_mode_suffix%-results.txt"
call :writeEncodeOutputMode "bench_logs\%_logprefix%-encodeLazy2%_nsuffix%%_mode_suffix%-results.txt"
echo [DONE] lzfse lazy2 encode %TIME:~0,8%

echo [Info] Running lzfse optimal encode benchmark... %TIME:~0,8%
call :nanoTimeElapsed call :encodeOptimal "%_dataset%" "%~2" > ".\bench_logs\%_logprefix%-encodeOptimal%_nsuffix%%_mode_suffix%-results.txt"
call :appendFileSize "%_dataset%.lzfse.optimal" "bench_logs\%_logprefix%-encodeOptimal%_nsuffix%%_mode_suffix%-results.txt"
call :writeEncodeOutputMode "bench_logs\%_logprefix%-encodeOptimal%_nsuffix%%_mode_suffix%-results.txt"
echo [DONE] lzfse optimal encode %TIME:~0,8%

echo [Info] Running lz4 encode benchmark... %TIME:~0,8%
call :nanoTimeElapsed call :encodeLZ4 "%_dataset%" > ".\bench_logs\%_logprefix%-encodeLZ4%_nsuffix%%_mode_suffix%-results.txt"
call :appendFileSize "%_dataset%.tar.lz4" "bench_logs\%_logprefix%-encodeLZ4%_nsuffix%%_mode_suffix%-results.txt"
call :writeEncodeOutputMode "bench_logs\%_logprefix%-encodeLZ4%_nsuffix%%_mode_suffix%-results.txt"
echo [DONE] lz4 encode %TIME:~0,8%

echo [Info] Running zstd encode benchmark... %TIME:~0,8%
call :nanoTimeElapsed call :encodeZSTD "%_dataset%" > ".\bench_logs\%_logprefix%-encodeZSTD%_nsuffix%%_mode_suffix%-results.txt"
call :appendFileSize "%_dataset%.tar.zst" "bench_logs\%_logprefix%-encodeZSTD%_nsuffix%%_mode_suffix%-results.txt"
call :writeEncodeOutputMode "bench_logs\%_logprefix%-encodeZSTD%_nsuffix%%_mode_suffix%-results.txt"
echo [DONE] zstd encode %TIME:~0,8%

echo [Info] Summarising benchmark results... %TIME:~0,8%
python summarize_win.py --results-dir . --output bench_results_csv\encode_summary.csv
if errorlevel 1 exit /b 1
echo [OK] bench_results_csv\encode_summary.csv written %TIME:~0,8%
goto :EOF

:appendFileSize
:: %~1 = output file, %~2 = log file
if "%_write%"=="1" (
    powershell -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; if (Test-Path '%~1') { $s=(Get-Item '%~1').Length; Write-Output('==> Encoded size: '+$s+' bytes') } else { Write-Output('Output file not found: %~1') }" >> "%~2"
) else (
    powershell -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Write-Output('==> Encoded size: 0 bytes') " >> "%~2"
)
exit /b

:writeEncodeOutputMode
powershell -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Write-Output('==> Encode output: %_encode_output_note%')" >> "%~1"
exit /b

:encodeOther3
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
call :setTarSource "%~1"
if "%_write%"=="1" (
    cmd /d /c pushd "!_tar_parent!" ^&^& tar -cf - "!_tar_leaf!" | .\lzfse.exe -encode -algo other3 %_n_opt% -si -o "%~1.lzfse.other3"
) else (
    cmd /d /c pushd "!_tar_parent!" ^&^& tar -cf - "!_tar_leaf!" | .\lzfse.exe -encode -algo other3 %_n_opt% -si -so > nul 2>&1
)
exit /b

:encodeOptimal3
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
call :setTarSource "%~1"
if "%_write%"=="1" (
    cmd /d /c pushd "!_tar_parent!" ^&^& tar -cf - "!_tar_leaf!" | .\lzfse.exe -encode -algo other3 -optimal3 %_n_opt% -si -o "%~1.lzfse.other3.optimal3"
) else (
    cmd /d /c pushd "!_tar_parent!" ^&^& tar -cf - "!_tar_leaf!" | .\lzfse.exe -encode -algo other3 -optimal3 %_n_opt% -si -so > nul 2>&1
)
exit /b

:encodeBVX3
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
call :setTarSource "%~1"
if "%_write%"=="1" (
    cmd /d /c pushd "!_tar_parent!" ^&^& tar -cf - "!_tar_leaf!" | .\lzfse.exe -encode -algo bvx3 %_n_opt% -si -o "%~1.lzfse.bvx3"
) else (
    cmd /d /c pushd "!_tar_parent!" ^&^& tar -cf - "!_tar_leaf!" | .\lzfse.exe -encode -algo bvx3 %_n_opt% -si -so > nul 2>&1
)
exit /b

:encodeLazy2
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
call :setTarSource "%~1"
if "%_write%"=="1" (
    cmd /d /c pushd "!_tar_parent!" ^&^& tar -cf - "!_tar_leaf!" | .\lzfse.exe -encode -algo bvx3 -lazy2 %_n_opt% -si -o "%~1.lzfse.lazy2"
) else (
    cmd /d /c pushd "!_tar_parent!" ^&^& tar -cf - "!_tar_leaf!" | .\lzfse.exe -encode -algo bvx3 -lazy2 %_n_opt% -si -so > nul 2>&1
)
exit /b

:encodeOptimal
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
call :setTarSource "%~1"
if "%_write%"=="1" (
    cmd /d /c pushd "!_tar_parent!" ^&^& tar -cf - "!_tar_leaf!" | .\lzfse.exe -encode -algo bvx3 -optimal %_n_opt% -si -o "%~1.lzfse.optimal"
) else (
    cmd /d /c pushd "!_tar_parent!" ^&^& tar -cf - "!_tar_leaf!" | .\lzfse.exe -encode -algo bvx3 -optimal %_n_opt% -si -so > nul 2>&1
)
exit /b

:encodeLZ4
call :setTarSource "%~1"
if "%_write%"=="1" (
    cmd /d /c pushd "!_tar_parent!" ^&^& tar -cf - "!_tar_leaf!" | lz4 -9 -q -f - "%~1.tar.lz4"
) else (
    cmd /d /c pushd "!_tar_parent!" ^&^& tar -cf - "!_tar_leaf!" | lz4 -9 -q -c - > nul 2>&1
)
exit /b

:encodeZSTD
call :setTarSource "%~1"
:: Native mode is one in-process step, not tar piped into zstd.exe. The level is
:: passed explicitly rather than inherited: this is a measurement harness, so it
:: should pin what it measures instead of tracking a default that may move. 9
:: matches the external branch below, which is what makes the two comparable --
:: while the native level was silently 3, the gap read as an implementation
:: difference when it was a level difference.
if "%LZFSE_REQUIRE_NATIVE_ZSTD%"=="1" goto :encodeZSTDNative
if "%_write%"=="1" (
    cmd /d /c pushd "!_tar_parent!" ^&^& tar -cf - "!_tar_leaf!" | zstd -9 -q -f -o "%~1.tar.zst"
) else (
    cmd /d /c pushd "!_tar_parent!" ^&^& tar -cf - "!_tar_leaf!" | zstd -9 -q -c - > nul 2>&1
)
exit /b

:encodeZSTDNative
if "%_write%"=="1" (
    "!_zstd_tar!" -c --zstd --zstd-level 9 -f "%~1.tar.zst" -C "!_tar_parent!" "!_tar_leaf!"
) else (
    "!_zstd_tar!" -c --zstd --zstd-level 9 -f - -C "!_tar_parent!" "!_tar_leaf!" > nul 2>&1
)
exit /b

:tarWarmup
call :setTarSource "%~1"
cmd /d /c pushd "!_tar_parent!" ^&^& tar -cf - "!_tar_leaf!" > nul 2>&1
exit /b

:tarCfStdout
pushd "!_tar_parent!" || exit /b 1
tar -cf - "!_tar_leaf!"
set "_tar_rc=%ERRORLEVEL%"
popd
exit /b %_tar_rc%

:tarCzfStdout
pushd "!_tar_parent!" || exit /b 1
tar czf - "!_tar_leaf!"
set "_tar_rc=%ERRORLEVEL%"
popd
exit /b %_tar_rc%
:setTarSource
exit /b

:nanoTimeElapsed
:: Usage: call :nanoTimeElapsed <command> [args...]
for /f %%T in ('powershell -NoProfile -Command "[System.Diagnostics.Stopwatch]::GetTimestamp()"') do set "_t0=%%T"
%1 %2 %3 %4 %5
set _rc=%ERRORLEVEL%
for /f %%T in ('powershell -NoProfile -Command "[System.Diagnostics.Stopwatch]::GetTimestamp()"') do set "_t1=%%T"
powershell -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; $ns=([long]'%_t1%'-[long]'%_t0%')*1000000000/[System.Diagnostics.Stopwatch]::Frequency; Write-Output ('==> Process took: '+$ns.ToString('D10')+' nanoseconds')"
exit /b %_rc%

:encodeTgz
:: Usage: call :encodeTgz <folder_or_file>
call :setTarSource "%~1"
if "%_write%"=="1" (
    cmd /d /c pushd "!_tar_parent!" ^&^& "!_tgz_tar!" czf - "!_tar_leaf!" > "%~1.tgz"
) else (
    cmd /d /c pushd "!_tar_parent!" ^&^& "!_tgz_tar!" czf - "!_tar_leaf!" > nul 2>&1
)
exit /b

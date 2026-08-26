@echo off
chcp 65001 > nul
:: Usage: run_round.bat [-swift_tar]
::   -swift_tar : test mode, points tar at the already-built swift_tar.exe
::                (PATH shim, system PATH untouched); without this flag,
::                behaves exactly as before (system tar). Requires running
::                swift_tar\compile_tar-win.bat first to produce
::                release\swift_tar.exe.
:: NOTE: comments below stay English-only where newly added -- non-ASCII
:: bytes on a comment line were found to corrupt cmd.exe's parsing of
:: subsequent lines in this environment (reproduced independent of chcp).
setlocal EnableDelayedExpansion
set "LZFSE_REQUIRE_NATIVE_ZLIB=0"
set "LZFSE_REQUIRE_NATIVE_ZSTD=0"
cd /d "%~dp0"
:: 每輪開始前清除舊狀態檔，確保本輪資料全新 / Clear status file so this round starts fresh
type nul > windows_round_status.txt
echo [INFO] 開始新一輪測試 / Starting a new round of testing  >> windows_round_status.txt
echo [INFO] 時間戳記 / Timestamp: %TIME:~0,8% >> windows_round_status.txt
echo [INFO] 目前路徑 / Current directory: %CD% >> windows_round_status.txt
echo [INFO] 目前磁碟空間 / Current disk space: >> windows_round_status.txt
powershell -Command "Get-CimInstance Win32_LogicalDisk | Select-Object Caption,@{N='Size_GB';E={[math]::Round($_.Size/1GB,1)}},@{N='Free_GB';E={[math]::Round($_.FreeSpace/1GB,1)}} | Format-Table -AutoSize"   >> windows_round_status.txt 2>&1

:: swift_tar test PATH shim (system PATH untouched): only when -swift_tar is
:: explicitly passed, copy the already-built release\swift_tar.exe to
:: tar.exe in a shim dir and prepend it to this session's PATH, so every
:: child process (encode-win.bat/decode-win.bat etc.) resolves bare `tar` to
:: swift_tar; PATH is left untouched otherwise.
:: Retry with backoff: the shim tar.exe can be transiently locked right after
:: being (re)written (AV real-time scan on the freshly copied exe). A plain
:: "copy /Y" failing here was observed to leave a stale/missing shim in
:: place while the script still continued -- every later `tar` call
:: throughout encode-win.bat/decode-win.bat then fails fast, and
:: summarize_win.py silently falls back to reporting old bench_logs results
:: instead of fresh data, making a broken round look like it succeeded. Same
:: retry pattern already used for installing lzfse.exe below.
set "USE_SWIFT_TAR=0"
for %%A in (%*) do if /i "%%~A"=="-swift_tar" set "USE_SWIFT_TAR=1"
if "%USE_SWIFT_TAR%"=="1" (
    set "_swift_tar_exe=..\swift_tar\release\swift_tar.exe"
    set "_swift_tar_version=..\swift_tar\version-win.txt"
    if not exist "!_swift_tar_exe!" (
        echo SWIFT_TAR_NOT_FOUND %TIME:~0,8% >> windows_round_status.txt
        echo [Error] -swift_tar requested but !_swift_tar_exe! not found. Run swift_tar\compile_tar-win.bat first. / 已指定 -swift_tar 但找不到 !_swift_tar_exe!，請先執行 swift_tar\compile_tar-win.bat。 >&2
        exit /b 1
    )
    if not exist "!_swift_tar_version!" (
        echo SWIFT_TAR_VERSION_NOT_FOUND %TIME:~0,8% >> windows_round_status.txt
        echo [Error] -swift_tar requires ..\swift_tar\version-win.txt to verify native zlib linkage. >&2
        exit /b 1
    )
    :: The stamp is per platform -- version-win.txt here, version-mac.txt on
    :: macOS -- so a build on one platform cannot overwrite the other's record.
    :: findstr /x exact-line match is unreliable against it since
    :: generate_version.zsh is a zsh script that writes LF-only line endings,
    :: not the CRLF Windows findstr /x expects; use a substring match instead.
    :: NOTE: keep comments in this block free of parenthesis characters --
    :: :: comments are parsed as pseudo-labels, and stray parentheses inside
    :: them corrupt cmd.exe's paren-counting for the enclosing if-block.
    findstr /c:"zlib_linkage=static" "!_swift_tar_version!" > nul
    if errorlevel 1 (
        echo SWIFT_TAR_NATIVE_ZLIB_NOT_VERIFIED %TIME:~0,8% >> windows_round_status.txt
        echo [Error] -swift_tar requires zlib_linkage=static in version-win.txt. >&2
        exit /b 1
    )
    :: ZSTD is gated the same way as TGZ. Without this the ZSTD rows measured the
    :: external zstd.exe while the round was labelled as a swift_tar round, which
    :: is the gap OPTIMIZATION.md recorded as unresolved.
    findstr /c:"zstd_linkage=static" "!_swift_tar_version!" > nul
    if errorlevel 1 (
        echo SWIFT_TAR_NATIVE_ZSTD_NOT_VERIFIED %TIME:~0,8% >> windows_round_status.txt
        echo [Error] -swift_tar requires zstd_linkage=static in version-win.txt. >&2
        exit /b 1
    )
    set "_swift_tar_shim_dir=%TEMP%\lzfse2-swift-tar-shim"
    if not exist "!_swift_tar_shim_dir!" mkdir "!_swift_tar_shim_dir!"
    powershell -NoProfile -Command "$src='!_swift_tar_exe!'; $dst='!_swift_tar_shim_dir!\tar.exe'; for ($i=1; $i -le 10; $i++) { try { Copy-Item -LiteralPath $src -Destination $dst -Force; exit 0 } catch { Write-Output ('shim copy retry '+$i+': '+$_.Exception.Message); Start-Sleep -Milliseconds 500 } }; exit 1" >> windows_round_status.txt 2>&1
    if errorlevel 1 (
        echo SWIFT_TAR_SHIM_FAILED %TIME:~0,8% >> windows_round_status.txt
        echo [Error] could not install swift_tar PATH shim after retries. / 重試多次後仍無法安裝 swift_tar PATH shim。 >&2
        exit /b 1
    )
    set "SWIFT_TAR_BIN=!_swift_tar_shim_dir!\tar.exe"
    set "LZFSE_REQUIRE_NATIVE_ZLIB=1"
    set "LZFSE_REQUIRE_NATIVE_ZSTD=1"
    set "PATH=!_swift_tar_shim_dir!;%PATH%"
    set "_swift_tar_version_output=%TEMP%\lzfse2-swift-tar-version.txt"
    "!SWIFT_TAR_BIN!" --version > "!_swift_tar_version_output!" 2>&1
    if errorlevel 1 (
        echo SWIFT_TAR_VERSION_FAILED %TIME:~0,8% >> windows_round_status.txt
        type "!_swift_tar_version_output!" >> windows_round_status.txt
        exit /b 1
    )
    findstr /b /c:"swift_tar " "!_swift_tar_version_output!" > nul
    if errorlevel 1 (
        echo SWIFT_TAR_IDENTITY_FAILED %TIME:~0,8% >> windows_round_status.txt
        type "!_swift_tar_version_output!" >> windows_round_status.txt
        exit /b 1
    )
    echo USING_SWIFT_TAR !SWIFT_TAR_BIN! NATIVE_ZLIB=static NATIVE_ZSTD=static %TIME:~0,8% >> windows_round_status.txt
    type "!_swift_tar_version_output!" >> windows_round_status.txt
    del /q "!_swift_tar_version_output!" > nul 2>&1

    :: The USING_SWIFT_TAR line above records build provenance only.
    :: version-win.txt says the EXE was linked against static libzstd, which
    :: cannot show which implementation actually ran. R47-Win logged
    :: NATIVE_ZLIB=static and still measured
    :: the external zstd.exe on every ZSTD row, so provenance has misled once
    :: already. The subroutine proves it at run time and aborts if it cannot.
    call :verifyNativeZstd
    if errorlevel 1 exit /b 1

    :: Self-test: verify swift_tar round-trips correctly against the
    :: platform's standard tar before trusting it for the whole round.
    :: Calls SWIFT_TAR_BIN explicitly, the same native-zlib backend exported
    :: to encode-win.bat/decode-win.bat/rss-win.bat. Catches a broken
    :: build/shim immediately instead of discovering it an hour later as
    :: silently-stale benchmark data.
    "!SWIFT_TAR_BIN!" -test > .\swift_tar-test-windows.txt 2>&1
    if errorlevel 1 (
        echo SWIFT_TAR_TEST_FAILED %TIME:~0,8% >> windows_round_status.txt
        type .\swift_tar-test-windows.txt >> windows_round_status.txt
        echo [FAIL] swift_tar self-test failed, see swift_tar-test-windows.txt / swift_tar 自我測試失敗，詳見 swift_tar-test-windows.txt >&2
        pause
        exit /b 1
    )
    type .\swift_tar-test-windows.txt >> windows_round_status.txt
    echo SWIFT_TAR_TEST_OK %TIME:~0,8% >> windows_round_status.txt
)

:: 確保 bench_logs 存在，並把本目錄既有的 *-results.txt 先移入（保持本目錄乾淨）
:: Ensure bench_logs exists and move any existing *-results.txt there first (keep cwd clean)
if not exist bench_logs mkdir bench_logs
move /Y *-results.txt bench_logs\ > nul 2>&1

:: 清除舊的 summary CSV，確保本輪資料從零累積
:: Clear stale summary CSVs so this round accumulates from scratch
if not exist bench_results_csv mkdir bench_results_csv
del /Q bench_results_csv\encode_summary.csv bench_results_csv\decode_summary.csv bench_results_csv\rss_summary.csv > nul 2>&1
echo [INFO] Cleared encode_summary.csv, decode_summary.csv, rss_summary.csv %TIME:~0,8% >> windows_round_status.txt

:: System hardware info snapshot / 系統硬體資訊快照
echo [INFO] Running system-info-win.bat %TIME:~0,8% >> windows_round_status.txt
call .\system-info-win.bat >> windows_round_status.txt 2>&1
if errorlevel 1 (
    echo SYSTEM_INFO_FAILED %TIME:~0,8% >> windows_round_status.txt
    echo [WARN] system info collection failed, continuing
)
:: git gc (前置清理)
echo RUNNING git gc %TIME:~0,8% >> windows_round_status.txt
git gc --prune=now --aggressive >> windows_round_status.txt 2>&1

:: compile
echo RUNNING compile %TIME:~0,8% >> windows_round_status.txt

set "_build_exe=lzfse-build-%RANDOM%.exe"
swiftc -O ../lzfse-cli.swift -o "%_build_exe%" >> windows_round_status.txt 2>&1

if errorlevel 1 (
    echo COMPILE_FAILED %TIME:~0,8% >> windows_round_status.txt
    echo [FAIL] 編譯失敗 / Compilation failed
    pause
    exit /b 1
)

powershell -NoProfile -Command "$src='%_build_exe%'; $dst='lzfse.exe'; for ($i=1; $i -le 10; $i++) { try { if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force }; Move-Item -LiteralPath $src -Destination $dst -Force; exit 0 } catch { Write-Output ('compile install retry '+$i+': '+$_.Exception.Message); Start-Sleep -Milliseconds 500 } }; exit 1" >> windows_round_status.txt 2>&1
if errorlevel 1 (
    echo COMPILE_INSTALL_FAILED %TIME:~0,8% >> windows_round_status.txt
    exit /b 1
)
del /Q "%_build_exe:.exe=.lib%" "%_build_exe:.exe=.exp%" > nul 2>&1

echo COMPILE_OK %TIME:~0,8% >> windows_round_status.txt

:: test
.\lzfse.exe -test > .\lzfse-test-windows.txt
if %ERRORLEVEL% neq 0 (
    echo TEST_FAILED %TIME:~0,8% >> windows_round_status.txt
    echo [FAIL] 測試失敗，詳見 lzfse-test-windows.txt / Test failed, see lzfse-test-windows.txt
    pause
    exit /b 1
)

cat .\lzfse-test-windows.txt
echo TEST_OK %TIME:~0,8% >> windows_round_status.txt

set "_bench_n=40"
set "_bench_datasets=..\claw-code ..\llama.cpp"

for %%D in (%_bench_datasets%) do (
    echo [INFO] Running encode-win.bat %%D !_bench_n! nul !TIME:~0,8! >> windows_round_status.txt
    call .\encode-win.bat "%%~D" !_bench_n! >> windows_round_status.txt 2>&1
    if errorlevel 1 (
        echo BENCHMARK_NUL_FAILED %%D !TIME:~0,8! >> windows_round_status.txt
        exit /b 1
    )
    echo [DONE] encode nul %%D !TIME:~0,8! >> windows_round_status.txt

    echo [INFO] Running encode-win.bat %%D !_bench_n! write !TIME:~0,8! >> windows_round_status.txt
    call .\encode-win.bat "%%~D" !_bench_n! write >> windows_round_status.txt 2>&1
    if errorlevel 1 (
        echo BENCHMARK_FILE_FAILED %%D !TIME:~0,8! >> windows_round_status.txt
        exit /b 1
    )
    echo [DONE] encode write %%D !TIME:~0,8! >> windows_round_status.txt

    echo [INFO] Running decode-win.bat %%D !_bench_n! nul !TIME:~0,8! >> windows_round_status.txt
    call .\decode-win.bat "%%~D" !_bench_n! >> windows_round_status.txt 2>&1
    if errorlevel 1 (
        echo DECODE_NUL_BENCHMARK_FAILED %%D !TIME:~0,8! >> windows_round_status.txt
        echo [WARN] decode nul benchmark failed for %%D, continuing
    )
    echo [DONE] decode nul %%D !TIME:~0,8! >> windows_round_status.txt

    echo [INFO] Running decode-win.bat %%D !_bench_n! write !TIME:~0,8! >> windows_round_status.txt
    call .\decode-win.bat "%%~D" !_bench_n! write >> windows_round_status.txt 2>&1
    if errorlevel 1 (
        echo DECODE_FILE_BENCHMARK_FAILED %%D !TIME:~0,8! >> windows_round_status.txt
        echo [WARN] decode file benchmark failed for %%D, continuing
    )
    echo [DONE] decode write %%D !TIME:~0,8! >> windows_round_status.txt

    echo [INFO] Running rss-win.bat %%D !_bench_n! nul !TIME:~0,8! >> windows_round_status.txt
    call .\rss-win.bat "%%~D" !_bench_n! >> windows_round_status.txt 2>&1
    if errorlevel 1 (
        echo RSS_NUL_FAILED %%D !TIME:~0,8! >> windows_round_status.txt
        echo [WARN] rss nul measurement failed for %%D, continuing
    )
    echo [DONE] rss nul %%D !TIME:~0,8! >> windows_round_status.txt

    echo [INFO] Running rss-win.bat %%D !_bench_n! write !TIME:~0,8! >> windows_round_status.txt
    call .\rss-win.bat "%%~D" !_bench_n! write >> windows_round_status.txt 2>&1
    if errorlevel 1 (
        echo RSS_FILE_FAILED %%D !TIME:~0,8! >> windows_round_status.txt
        echo [WARN] rss file measurement failed for %%D, continuing
    )
    echo [DONE] rss write %%D !TIME:~0,8! >> windows_round_status.txt
)
:: Step 2: Windows benchmark summary (encode + decode) / Windows benchmark 摘要
echo [INFO] Running summarize_win.py %TIME:~0,8% >> windows_round_status.txt
set "_summary_log=%TEMP%\lzfse-summary-%RANDOM%.log"
python summarize_win.py > "%_summary_log%" 2>&1
set "_summary_rc=%ERRORLEVEL%"
type "%_summary_log%"
type "%_summary_log%" >> windows_round_status.txt
del /Q "%_summary_log%" > nul 2>&1
if not "%_summary_rc%"=="0" (
    echo SUMMARY_FAILED %TIME:~0,8% >> windows_round_status.txt
    exit /b %_summary_rc%
)
echo SUMMARY_OK %TIME:~0,8% >> windows_round_status.txt

:: Step 3: macOS vs Windows comparison / macOS vs Windows 比較
del /Q bench_results_csv\comparison.csv2 > nul 2>&1
for %%D in (%_bench_datasets%) do (
    echo [INFO] Running comparison_win.py %%~nxD !TIME:~0,8! >> windows_round_status.txt
    set "_comparison_output=bench_results_csv\comparison.csv2"
    set "_comparison_log=%TEMP%\lzfse-comparison-%%~nxD-%RANDOM%.log"
    python comparison_win.py --dataset "%%~nxD" --output "!_comparison_output!" > "!_comparison_log!" 2>&1
    set "_comparison_rc=!ERRORLEVEL!"
    type "!_comparison_log!"
    type "!_comparison_log!" >> windows_round_status.txt
    del /Q "!_comparison_log!" > nul 2>&1
    if not "!_comparison_rc!"=="0" (
        echo COMPARISON_FAILED %%~nxD !TIME:~0,8! >> windows_round_status.txt
        exit /b !_comparison_rc!
    )
    echo [DONE] comparison %%~nxD !TIME:~0,8! >> windows_round_status.txt
)
:: git gc (後置收尾)
git gc --prune=now --aggressive >> windows_round_status.txt 2>&1
echo DONE %TIME:~0,8% >> windows_round_status.txt

echo [OK] 全部完成 / All done
pause
exit /b 0

:: ===========================================================================
:: verifyNativeZstd -- prove ZSTD is handled in-process, not by zstd.exe.
::
:: PATH is stripped to the shim plus System32, putting any external zstd.exe
:: out of reach, and swift_tar is then asked to write a zstd archive and read
:: it back. Shelling out fails here, in seconds, rather than silently
:: measuring the wrong tool for the next ninety minutes.
::
:: Not airtight: a swift_tar that located zstd.exe by absolute path would still
:: pass. It discriminates the case that actually occurred, which is resolution
:: through PATH.
::
:: This file has no other subroutine; it is placed after the main flow, which
:: ends in exit /b 0 above so control cannot fall through into it. Labels must
:: stay outside every parenthesised block -- cmd.exe does not handle them
:: reliably inside one, and a goto would abandon the rest of the block.
:: NOTE: keep the comments here free of parenthesis characters.
:: ===========================================================================
:verifyNativeZstd
setlocal EnableDelayedExpansion
set "_nz_dir=%TEMP%\lzfse2-native-zstd-probe"
if exist "!_nz_dir!" rmdir /s /q "!_nz_dir!"
mkdir "!_nz_dir!"
echo native zstd probe> "!_nz_dir!\probe.txt"
set "PATH=%_swift_tar_shim_dir%;%SystemRoot%\System32"
"%SWIFT_TAR_BIN%" -c --zstd --zstd-level 9 -f "!_nz_dir!\probe.tar.zst" -C "!_nz_dir!" probe.txt >> windows_round_status.txt 2>&1
if errorlevel 1 goto :nativeZstdFailed
"%SWIFT_TAR_BIN%" --identify -f "!_nz_dir!\probe.tar.zst" > "!_nz_dir!\identify.txt" 2>&1
if errorlevel 1 goto :nativeZstdFailed
findstr /c:"zstd" "!_nz_dir!\identify.txt" > nul
if errorlevel 1 goto :nativeZstdFailed
"%SWIFT_TAR_BIN%" --cat -f "!_nz_dir!\probe.tar.zst" > "!_nz_dir!\probe.tar" 2>> windows_round_status.txt
if errorlevel 1 goto :nativeZstdFailed
type "!_nz_dir!\identify.txt" >> windows_round_status.txt
echo NATIVE_ZSTD_PROVEN in-process, external zstd.exe out of PATH %TIME:~0,8% >> windows_round_status.txt
rmdir /s /q "!_nz_dir!" > nul 2>&1
endlocal
exit /b 0

:nativeZstdFailed
echo NATIVE_ZSTD_PROBE_FAILED %TIME:~0,8% >> windows_round_status.txt
if exist "!_nz_dir!\identify.txt" type "!_nz_dir!\identify.txt" >> windows_round_status.txt
rmdir /s /q "!_nz_dir!" > nul 2>&1
endlocal
echo [Error] swift_tar could not handle zstd with the external zstd.exe out of PATH. >&2
echo [Error] This round would measure the external tool on every ZSTD row. Aborting. >&2
echo [Error] swift_tar 在外部 zstd.exe 不在 PATH 時無法處理 zstd。本輪的 ZSTD 各列會量到外部工具，中止。 >&2
exit /b 1

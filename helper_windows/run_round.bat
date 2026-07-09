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
    if not exist "!_swift_tar_exe!" (
        echo SWIFT_TAR_NOT_FOUND %TIME:~0,8% >> windows_round_status.txt
        echo [Error] -swift_tar requested but !_swift_tar_exe! not found. Run swift_tar\compile_tar-win.bat first. / 已指定 -swift_tar 但找不到 !_swift_tar_exe!，請先執行 swift_tar\compile_tar-win.bat。 >&2
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
    set "PATH=!_swift_tar_shim_dir!;%PATH%"
    echo USING_SWIFT_TAR !_swift_tar_shim_dir!\tar.exe %TIME:~0,8% >> windows_round_status.txt
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
del /Q bench_results_csv\comparison.csv > nul 2>&1
for %%D in (%_bench_datasets%) do (
    echo [INFO] Running comparison_win.py %%~nxD !TIME:~0,8! >> windows_round_status.txt
    set "_comparison_output=bench_results_csv\comparison.csv"
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

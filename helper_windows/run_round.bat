@echo off
chcp 65001 > nul
echo [INFO] 開始新一輪測試 / Starting a new round of testing  > windows_round_status.txt
echo [INFO] 時間戳記 / Timestamp: %TIME:~0,8% >> windows_round_status.txt
echo [INFO] 目前路徑 / Current directory: %CD% >> windows_round_status.txt
echo [INFO] 目前磁碟空間 / Current disk space: >> windows_round_status.txt
powershell -Command "Get-CimInstance Win32_LogicalDisk | Select-Object Caption,@{N='Size_GB';E={[math]::Round($_.Size/1GB,1)}},@{N='Free_GB';E={[math]::Round($_.FreeSpace/1GB,1)}} | Format-Table -AutoSize"   >> windows_round_status.txt 2>&1

:: 確保 bench_logs 存在，並把本目錄既有的 *-results.txt 先移入（保持本目錄乾淨）
:: Ensure bench_logs exists and move any existing *-results.txt there first (keep cwd clean)
if not exist bench_logs mkdir bench_logs
move /Y *-results.txt bench_logs\ > nul 2>&1

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

move /Y "%_build_exe%" lzfse.exe >> windows_round_status.txt 2>&1
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

call .\encode-win.bat ..\claw-code 40 >> windows_round_status.txt 2>&1
if errorlevel 1 (
    echo BENCHMARK_FAILED %TIME:~0,8% >> windows_round_status.txt
    exit /b 1
)

:: Step 1: Decode benchmark / 解壓縮基準測試（在 summarize 前執行以便納入報告）
echo [INFO] Running decode-win.bat %TIME:~0,8% >> windows_round_status.txt
call .\decode-win.bat ..\claw-code 40 >> windows_round_status.txt 2>&1
if errorlevel 1 (
    echo DECODE_BENCHMARK_FAILED %TIME:~0,8% >> windows_round_status.txt
    echo [WARN] decode benchmark 失敗，繼續 / decode benchmark failed, continuing
)

:: RSS peak memory measurement / 峰值記憶體量測（encode + decode，lzfse / lz4 / zstd / tgz）
echo [INFO] Running rss-win.bat %TIME:~0,8% >> windows_round_status.txt
call .\rss-win.bat ..\claw-code 40 >> windows_round_status.txt 2>&1
if errorlevel 1 (
    echo RSS_FAILED %TIME:~0,8% >> windows_round_status.txt
    echo [WARN] rss measurement 失敗，繼續 / RSS measurement failed, continuing
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

:: Step 3: macOS vs Windows comparison / macOS vs Windows 比較
echo [INFO] Running comparison_win.py %TIME:~0,8% >> windows_round_status.txt
set "_comparison_log=%TEMP%\lzfse-comparison-%RANDOM%.log"
python comparison_win.py > "%_comparison_log%" 2>&1
set "_comparison_rc=%ERRORLEVEL%"
type "%_comparison_log%"
type "%_comparison_log%" >> windows_round_status.txt
del /Q "%_comparison_log%" > nul 2>&1
if not "%_comparison_rc%"=="0" (
    echo COMPARISON_FAILED %TIME:~0,8% >> windows_round_status.txt
    exit /b %_comparison_rc%
)

:: git gc (後置收尾)
git gc --prune=now --aggressive >> windows_round_status.txt 2>&1
echo DONE %TIME:~0,8% >> windows_round_status.txt

echo [OK] 全部完成 / All done
pause

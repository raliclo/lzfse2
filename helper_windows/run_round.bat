@echo off
chcp 65001 > nul
echo [INFO] 開始新一輪測試 / Starting a new round of testing  > windows_round_status.txt
echo [INFO] 時間戳記 / Timestamp: %TIME:~0,8% >> windows_round_status.txt
echo [INFO] 目前路徑 / Current directory: %CD% >> windows_round_status.txt
echo [INFO] 目前磁碟空間 / Current disk space: >> windows_round_status.txt
powershell -Command "Get-CimInstance Win32_LogicalDisk | Select-Object Caption,@{N='Size_GB';E={[math]::Round($_.Size/1GB,1)}},@{N='Free_GB';E={[math]::Round($_.FreeSpace/1GB,1)}} | Format-Table -AutoSize"   >> windows_round_status.txt 2>&1

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

call .\benchmark_windows.bat ..\claw-code 40 >> windows_round_status.txt 2>&1
if errorlevel 1 (
    echo BENCHMARK_FAILED %TIME:~0,8% >> windows_round_status.txt
    exit /b 1
)

:: benchmark_windows.bat 目前將最新結果留在本目錄；summarize_win.py 會同時
:: 掃描本目錄與 bench_logs，並選取時間最新的紀錄。


:: Step 1: Windows benchmark summary / Windows benchmark 摘要
echo [INFO] Running summarize_win.py %TIME:~0,8% >> windows_round_status.txt
python summarize_win.py | powershell -NoProfile -Command "$input | Tee-Object -Append -FilePath windows_round_status.txt"

:: Step 2: macOS vs Windows comparison / macOS vs Windows 比較
echo [INFO] Running comparison_win.py %TIME:~0,8% >> windows_round_status.txt
python comparison_win.py | powershell -NoProfile -Command "$input | Tee-Object -Append -FilePath windows_round_status.txt"

:: git gc (後置收尾)
git gc --prune=now --aggressive >> windows_round_status.txt 2>&1
echo DONE %TIME:~0,8% >> windows_round_status.txt

echo [OK] 全部完成 / All done
pause

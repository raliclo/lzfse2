@echo off
chcp 65001 > nul
cd ..
swiftc -O lzfse-cli.swift -o ./helper_windows/lzfse.exe

if %ERRORLEVEL% neq 0 (
    echo.
    echo [FAIL] 編譯失敗 / Compilation failed
    pause
    exit /b %ERRORLEVEL%
)
cd helper_windows

echo [OK] 編譯成功 / Compilation succeeded

.\lzfse.exe -test > .\lzfse-test-windows.txt
echo [OK] 測試完成，結果寫入 lzfse-test-windows.txt / Test done, results in lzfse-test-windows.txt
pause

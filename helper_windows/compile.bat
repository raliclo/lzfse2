@echo off
:: compile
echo RUNNING compile %TIME:~0,8% 

set "_build_exe=lzfse-build-%RANDOM%.exe"
swiftc -O ../lzfse-cli.swift -o "%_build_exe%" 

if errorlevel 1 (
    echo COMPILE_FAILED %TIME:~0,8%
    echo [FAIL] 編譯失敗 / Compilation failed
    pause
    exit /b 1
)

move /Y "%_build_exe%" lzfse.exe 
if errorlevel 1 (
    echo COMPILE_INSTALL_FAILED %TIME:~0,8%
    exit /b 1
)
del /Q "%_build_exe:.exe=.lib%" "%_build_exe:.exe=.exp%" > nul 2>&1

echo COMPILE_OK %TIME:~0,8%
pause

@echo off
:: compile
echo RUNNING compile %TIME:~0,8% 

:: Use the newest installed Swift, not whatever this window inherited: an upgrade deletes the
:: old version, and a window opened before it still names it (2026-11-07: swiftc not found,
:: SDKROOT still 6.4.1). The choice is made in zsh; see swift_windows_env.zsh --help.
set "LZFSE_SWIFT_VERSION="
for /f "usebackq delims=" %%L in (`zsh "%~dp0swift_windows_env.zsh" --cmd`) do set "%%L"
if not defined LZFSE_SWIFT_VERSION (
    echo COMPILE_FAILED %TIME:~0,8%
    echo [FAIL] no Swift toolchain with a matching runtime, or zsh not on PATH
    pause
    exit /b 1
)
set "PATH=%LZFSE_SWIFT_RT%;%LZFSE_SWIFT_TC%;%PATH%"
echo Swift %LZFSE_SWIFT_VERSION%: %LZFSE_SWIFT_TC%

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

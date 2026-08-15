@echo off
chcp 65001 >nul
REM build-cli-win.bat -- 一鍵建置 lzfse CLI 自包含包（透過 Git Bash 執行 build-cli-win.zsh）
REM build-cli-win.bat -- one-click build for the self-contained lzfse CLI zip (runs build-cli-win.zsh via Git Bash)
REM
REM 用法 / Usage: 直接在檔案總管中按兩下本檔即可。
REM               Just double-click this file in File Explorer.

setlocal
cd /d "%~dp0"

REM 尋找 Git Bash / Locate Git Bash
set "BASH=C:\Program Files\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=C:\Program Files (x86)\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
REM scoop-installed Git: the shim lacks the MSYS env (no cygpath); use the real bash under apps\git.
if not exist "%BASH%" if defined SCOOP set "BASH=%SCOOP%\apps\git\current\usr\bin\bash.exe"
if not exist "%BASH%" set "BASH=%USERPROFILE%\scoop\apps\git\current\usr\bin\bash.exe"
REM Final fallback: first bash on PATH, excluding WSL launchers (System32, WindowsApps) and scoop shims (\shims\, no MSYS env) that cannot run this build.
if not exist "%BASH%" (
  for /f "delims=" %%i in ('where bash 2^>nul ^| findstr /v /i /c:"\System32\" ^| findstr /v /i /c:"\WindowsApps\" ^| findstr /v /i /c:"\shims\"') do if not defined BASHPATH set "BASHPATH=%%i"
)
if defined BASHPATH if not exist "%BASH%" set "BASH=%BASHPATH%"
if not exist "%BASH%" (
  echo.
  echo [錯誤/ERROR] 找不到 Git Bash / Git Bash not found.
  echo 請安裝 Git for Windows: https://gitforwindows.org
  echo.
  pause
  exit /b 1
)

echo === Building lzfse-cli.zip via "%BASH%" ===
echo.

REM 以登入 shell 執行，讓 ~/.bash_profile 設定的 Swift / VS 工具鏈 PATH 生效
REM Run as a login shell so the Swift / VS toolchain PATH from ~/.bash_profile applies
"%BASH%" -lc "cd \"$(cygpath -u '%CD%')\" && ./build-cli-win.zsh"
set "RC=%ERRORLEVEL%"

echo.
echo === build-cli-win.bat finished (exit code %RC%) ===
pause
exit /b %RC%

@echo off
setlocal

set "BASH=C:\Program Files\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=C:\Program Files (x86)\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if not exist "%BASH%" if defined SCOOP set "BASH=%SCOOP%\apps\git\current\usr\bin\bash.exe"
if not exist "%BASH%" set "BASH=%USERPROFILE%\scoop\apps\git\current\usr\bin\bash.exe"

if not exist "%BASH%" (
  echo [ERROR] Git Bash not found.
  exit /b 1
)

"%BASH%" -lc "git_core=\"$(cygpath -u \"$(git --exec-path)\")\"; export PATH=\"$git_core:$PATH\"; cd \"$(cygpath -u '%CD%')\" && git submodule status"
exit /b %ERRORLEVEL%

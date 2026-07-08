@echo off
chcp 65001 > nul
:: scoop_release.bat -- rebuild lzfse-cli.zip and refresh bucket\lzfse.json's hash
:: NOTE: comments in this file are English-only on purpose -- non-ASCII
:: bytes on a comment line were found to corrupt cmd.exe's parsing of
:: subsequent lines in this environment (reproduced independent of chcp).
cd /d "%~dp0"

call .\build-cli-win.bat
if errorlevel 1 (
    echo [FAIL] build-cli-win.bat failed / release\lzfse-cli.zip was not rebuilt
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File update_scoop_manifest.ps1 -ZipPath release\lzfse-cli.zip -ManifestPath ..\bucket\lzfse.json
if errorlevel 1 (
    echo [FAIL] updating ..\bucket\lzfse.json failed
    pause
    exit /b 1
)

echo [OK] release\lzfse-cli.zip rebuilt and ..\bucket\lzfse.json refreshed
pause

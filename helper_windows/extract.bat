@echo off
chcp 65001 > nul
:: Usage: extract.bat <archive> [probe]
:: Windows port of extract() from zshrc.sh
:: probe mode: decode to nul (memProbe / peak-RSS not available on Windows)

set "_file=%~1"
set "_probe=%~2"

if "%_file%"=="" (
    echo 使用方法: extract ^<archive^> [probe]
    echo Usage:    extract ^<archive^> [probe]
    exit /b 1
)

if not exist "%_file%" (
    echo '%_file%' is not a valid file
    exit /b 1
)

:: LZFSE_BENCH_N → -n arg (mirrors zsh n_args logic)
set "_n_args="
if defined LZFSE_BENCH_N set "_n_args=-n %LZFSE_BENCH_N%"

:: Match extensions from most specific to least specific
echo %_file%| findstr /i /r "\.lzfse\.bvx3\.lazy2$"   > nul 2>&1
if not errorlevel 1 goto :ext_bvx3_lazy2
echo %_file%| findstr /i /r "\.lzfse\.bvx3\.optimal$" > nul 2>&1
if not errorlevel 1 goto :ext_bvx3_optimal
echo %_file%| findstr /i /r "\.lzfse\.bvx3$"          > nul 2>&1
if not errorlevel 1 goto :ext_bvx3
echo %_file%| findstr /i /r "\.lzfse\.other3$"        > nul 2>&1
if not errorlevel 1 goto :ext_other3
echo %_file%| findstr /i /r "\.lzfse\.apple$"         > nul 2>&1
if not errorlevel 1 goto :ext_apple
echo %_file%| findstr /i /r "\.tar\.lz4$"             > nul 2>&1
if not errorlevel 1 goto :ext_tar_lz4
echo %_file%| findstr /i /r "\.tar\.zst$"             > nul 2>&1
if not errorlevel 1 goto :ext_zst
echo %_file%| findstr /i /r "\.tgz$"                  > nul 2>&1
if not errorlevel 1 goto :ext_tgz
echo %_file%| findstr /i /r "\.tar\.gz$"              > nul 2>&1
if not errorlevel 1 goto :ext_tgz
echo %_file%| findstr /i /r "\.tar\.bz2$"             > nul 2>&1
if not errorlevel 1 goto :ext_tar_bz2
echo %_file%| findstr /i /r "\.tar\.xz$"              > nul 2>&1
if not errorlevel 1 goto :ext_tar_xz
echo %_file%| findstr /i /r "\.zip$"                  > nul 2>&1
if not errorlevel 1 goto :ext_zip
echo %_file%| findstr /i /r "\.7z$"                   > nul 2>&1
if not errorlevel 1 goto :ext_7z
echo %_file%| findstr /i /r "\.lz4$"                  > nul 2>&1
if not errorlevel 1 goto :ext_lz4
echo '%_file%' cannot be extracted via extract
exit /b 1

:ext_bvx3_lazy2
if "%_probe%"=="probe" (
    echo [INFO] probe mode: decoding to nul ^(peak-RSS measurement not available on Windows^)
    lzfse.exe -decode -i "%_file%" -o nul -algo bvx3 -lazy2 %_n_args%
    exit /b
)
echo lzfse.exe -decode -i %_file% -so -algo bvx3 -lazy2 %_n_args% ^| tar -xf -
lzfse.exe -decode -i "%_file%" -so -algo bvx3 -lazy2 %_n_args% | tar -xf -
exit /b

:ext_bvx3_optimal
if "%_probe%"=="probe" (
    echo [INFO] probe mode: decoding to nul ^(peak-RSS measurement not available on Windows^)
    lzfse.exe -decode -i "%_file%" -o nul -algo bvx3 -optimal %_n_args%
    exit /b
)
echo lzfse.exe -decode -i %_file% -so -algo bvx3 -optimal %_n_args% ^| tar -xf -
lzfse.exe -decode -i "%_file%" -so -algo bvx3 -optimal %_n_args% | tar -xf -
exit /b

:ext_bvx3
if "%_probe%"=="probe" (
    echo [INFO] probe mode: decoding to nul ^(peak-RSS measurement not available on Windows^)
    lzfse.exe -decode -i "%_file%" -o nul -algo bvx3 %_n_args%
    exit /b
)
echo lzfse.exe -decode -i %_file% -so -algo bvx3 %_n_args% ^| tar -xf -
lzfse.exe -decode -i "%_file%" -so -algo bvx3 %_n_args% | tar -xf -
exit /b

:ext_other3
if "%_probe%"=="probe" (
    echo [INFO] probe mode: decoding to nul ^(peak-RSS measurement not available on Windows^)
    lzfse.exe -decode -i "%_file%" -o nul -algo other3 %_n_args%
    exit /b
)
echo lzfse.exe -decode -i %_file% -so -algo other3 %_n_args% ^| tar -xf -
lzfse.exe -decode -i "%_file%" -so -algo other3 %_n_args% | tar -xf -
exit /b

:ext_apple
if "%_probe%"=="probe" (
    echo [INFO] probe mode: decoding to nul ^(peak-RSS measurement not available on Windows^)
    lzfse.exe -decode -i "%_file%" -o nul -algo apple %_n_args%
    exit /b
)
echo lzfse.exe -decode -i %_file% -so -algo apple %_n_args% ^| tar -xf -
lzfse.exe -decode -i "%_file%" -so -algo apple %_n_args% | tar -xf -
exit /b

:ext_tar_lz4
if "%_probe%"=="probe" (
    echo [INFO] probe mode: decoding to nul ^(peak-RSS measurement not available on Windows^)
    lz4 -d -q -f "%_file%" nul
    exit /b
)
lz4 -T0 -d -q -c "%_file%" | tar -xf -
exit /b

:ext_zst
if "%_probe%"=="probe" (
    echo [INFO] probe mode: decoding to nul ^(peak-RSS measurement not available on Windows^)
    zstd -d -q -f "%_file%" -o nul
    exit /b
)
zstd -d -c "%_file%" | tar -xf -
exit /b

:ext_tgz
if "%_probe%"=="probe" (
    echo [INFO] probe mode: decoding to nul ^(peak-RSS measurement not available on Windows^)
    tar tzf "%_file%" > nul
    exit /b
)
tar xzf "%_file%"
exit /b

:ext_tar_bz2
tar xjf "%_file%"
exit /b

:ext_tar_xz
tar xf "%_file%"
exit /b

:ext_zip
unzip "%_file%"
exit /b

:ext_7z
7z x "%_file%"
exit /b

:ext_lz4
unlz4 "%_file%"
exit /b

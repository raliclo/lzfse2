@echo off
chcp 65001 > nul
:: Usage: decode-win.bat <dataset> [n]
:: Decode benchmark for all 7 formats; mirrors encode-win.bat encode logic.
:: All formats decode to nul (no disk writes) to measure pure decode speed.
:: Prerequisite: run encode-win.bat first to produce the compressed files.

set "_dataset=%~1"
set "_logprefix=%~nx1"
if "%_logprefix%"=="" set "_logprefix=dataset"
set "_n=%~2"

if "%_dataset%"=="" (
    echo Usage: decode-win.bat ^<dataset^> [n]
    exit /b 1
)

:: Check required compressed files exist / ?????????
set "_missing=0"
for %%F in (
    "%_dataset%.tgz"
    "%_dataset%.lzfse.other3"
    "%_dataset%.lzfse.bvx3"
    "%_dataset%.lzfse.lazy2"
    "%_dataset%.lzfse.optimal"
    "%_dataset%.tar.lz4"
    "%_dataset%.tar.zst"
) do (
    if not exist %%F (
        echo [WARN] Compressed file not found: %%F
        set "_missing=1"
    )
)
if "%_missing%"=="1" (
    echo [WARN] Some compressed files missing - run encode-win.bat first.
)

if not exist bench_logs mkdir bench_logs
if not exist bench_results_csv mkdir bench_results_csv
set "_nsuffix="
if not "%_n%"=="" set "_nsuffix=-n%_n%"

:: Warm-cache: read all compressed files into OS page cache
echo [Info] Warming cache for decode benchmark...
call :warmCache "%_dataset%"

echo [Info] Starting decode benchmark...

echo [Info] Running tgz decode benchmark...
call :nanoTimeElapsed call :decodeTgz "%_dataset%" > "bench_logs\%_logprefix%-decodeTgz%_nsuffix%-results.txt"
call :appendFileSize "%_dataset%.tgz" "bench_logs\%_logprefix%-decodeTgz%_nsuffix%-results.txt"

echo [Info] Running lzfse other3 decode benchmark...
call :nanoTimeElapsed call :decodeOther3 "%_dataset%" "%_n%" > "bench_logs\%_logprefix%-decodeOther3%_nsuffix%-results.txt"
call :appendFileSize "%_dataset%.lzfse.other3" "bench_logs\%_logprefix%-decodeOther3%_nsuffix%-results.txt"

echo [Info] Running lzfse bvx3 decode benchmark...
call :nanoTimeElapsed call :decodeBVX3 "%_dataset%" "%_n%" > "bench_logs\%_logprefix%-decodeBVX3%_nsuffix%-results.txt"
call :appendFileSize "%_dataset%.lzfse.bvx3" "bench_logs\%_logprefix%-decodeBVX3%_nsuffix%-results.txt"

echo [Info] Running lzfse lazy2 decode benchmark...
call :nanoTimeElapsed call :decodeLazy2 "%_dataset%" "%_n%" > "bench_logs\%_logprefix%-decodeLazy2%_nsuffix%-results.txt"
call :appendFileSize "%_dataset%.lzfse.lazy2" "bench_logs\%_logprefix%-decodeLazy2%_nsuffix%-results.txt"

echo [Info] Running lzfse optimal decode benchmark...
call :nanoTimeElapsed call :decodeOptimal "%_dataset%" "%_n%" > "bench_logs\%_logprefix%-decodeOptimal%_nsuffix%-results.txt"
call :appendFileSize "%_dataset%.lzfse.optimal" "bench_logs\%_logprefix%-decodeOptimal%_nsuffix%-results.txt"

echo [Info] Running lz4 decode benchmark...
call :nanoTimeElapsed call :decodeLZ4 "%_dataset%" > "bench_logs\%_logprefix%-decodeLZ4%_nsuffix%-results.txt"
call :appendFileSize "%_dataset%.tar.lz4" "bench_logs\%_logprefix%-decodeLZ4%_nsuffix%-results.txt"

echo [Info] Running zstd decode benchmark...
call :nanoTimeElapsed call :decodeZSTD "%_dataset%" > "bench_logs\%_logprefix%-decodeZSTD%_nsuffix%-results.txt"
call :appendFileSize "%_dataset%.tar.zst" "bench_logs\%_logprefix%-decodeZSTD%_nsuffix%-results.txt"

echo [Info] Summarising decode results...
powershell -NoProfile -Command "$csv=@('format,nanoseconds,encoded_bytes'); Get-ChildItem 'bench_logs\*-decode*-results.txt' | Sort-Object Name | ForEach-Object { $m=[regex]::Match($_.BaseName,'(decode\w+(?:-n\d+)?)-results'); $fmt=if($m.Success){$m.Groups[1].Value}else{$_.BaseName}; $c=Get-Content $_.FullName -Raw; if ($c) { $ns=([regex]::Match($c,'Process took:\s+(\d+)')).Groups[1].Value; $b=([regex]::Match($c,'Encoded size:\s+(\d+)')).Groups[1].Value; $csv+=$fmt+','+$ns+','+$b } }; $csv | Out-File 'bench_results_csv\decode_summary.csv' -Encoding UTF8"
echo [OK] bench_results_csv\decode_summary.csv written

:: Correctness verification: decode each format (single-thread, no -n) and pipe to tar tf
:: Appends "==> Verify: PASS/FAIL" to each result file; summarize_win.py reads this field.
echo [Info] Verifying decode correctness (tar tf check)...

tar tzf "%_dataset%.tgz" > nul 2>&1
if %ERRORLEVEL% == 0 (
    echo [PASS] TGZ
    call :writeVerify "bench_logs\%_logprefix%-decodeTgz%_nsuffix%-results.txt" PASS
) else (
    echo [FAIL] TGZ
    call :writeVerify "bench_logs\%_logprefix%-decodeTgz%_nsuffix%-results.txt" FAIL
)

.\lzfse.exe -decode -i "%_dataset%.lzfse.other3" -so -algo other3 | tar tf - > nul 2>&1
if %ERRORLEVEL% == 0 (
    echo [PASS] LZFSE Other3
    call :writeVerify "bench_logs\%_logprefix%-decodeOther3%_nsuffix%-results.txt" PASS
) else (
    echo [FAIL] LZFSE Other3
    call :writeVerify "bench_logs\%_logprefix%-decodeOther3%_nsuffix%-results.txt" FAIL
)

.\lzfse.exe -decode -i "%_dataset%.lzfse.bvx3" -so -algo bvx3 | tar tf - > nul 2>&1
if %ERRORLEVEL% == 0 (
    echo [PASS] LZFSE BVX3
    call :writeVerify "bench_logs\%_logprefix%-decodeBVX3%_nsuffix%-results.txt" PASS
) else (
    echo [FAIL] LZFSE BVX3
    call :writeVerify "bench_logs\%_logprefix%-decodeBVX3%_nsuffix%-results.txt" FAIL
)

.\lzfse.exe -decode -i "%_dataset%.lzfse.lazy2" -so -algo bvx3 -lazy2 | tar tf - > nul 2>&1
if %ERRORLEVEL% == 0 (
    echo [PASS] LZFSE Lazy2
    call :writeVerify "bench_logs\%_logprefix%-decodeLazy2%_nsuffix%-results.txt" PASS
) else (
    echo [FAIL] LZFSE Lazy2
    call :writeVerify "bench_logs\%_logprefix%-decodeLazy2%_nsuffix%-results.txt" FAIL
)

.\lzfse.exe -decode -i "%_dataset%.lzfse.optimal" -so -algo bvx3 -optimal | tar tf - > nul 2>&1
if %ERRORLEVEL% == 0 (
    echo [PASS] LZFSE Optimal
    call :writeVerify "bench_logs\%_logprefix%-decodeOptimal%_nsuffix%-results.txt" PASS
) else (
    echo [FAIL] LZFSE Optimal
    call :writeVerify "bench_logs\%_logprefix%-decodeOptimal%_nsuffix%-results.txt" FAIL
)

lz4 -d -c -q "%_dataset%.tar.lz4" | tar tf - > nul 2>&1
if %ERRORLEVEL% == 0 (
    echo [PASS] LZ4
    call :writeVerify "bench_logs\%_logprefix%-decodeLZ4%_nsuffix%-results.txt" PASS
) else (
    echo [FAIL] LZ4
    call :writeVerify "bench_logs\%_logprefix%-decodeLZ4%_nsuffix%-results.txt" FAIL
)

zstd -d -c -q "%_dataset%.tar.zst" | tar tf - > nul 2>&1
if %ERRORLEVEL% == 0 (
    echo [PASS] ZSTD
    call :writeVerify "bench_logs\%_logprefix%-decodeZSTD%_nsuffix%-results.txt" PASS
) else (
    echo [FAIL] ZSTD
    call :writeVerify "bench_logs\%_logprefix%-decodeZSTD%_nsuffix%-results.txt" FAIL
)

echo [Info] Decode verification complete.
goto :EOF

:: ?? Decode subroutines (decode to nul - no disk writes) ??????????????????

:decodeTgz
:: Decompress gzip stream to nul to measure decode speed without disk writes
tar xzf  "%~1.tgz" > nul 2>&1
exit /b

:decodeOther3
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
.\lzfse.exe -decode -i "%~1.lzfse.other3" -so -algo other3 %_n_opt% > nul 2>&1
exit /b

:decodeBVX3
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
.\lzfse.exe -decode -i "%~1.lzfse.bvx3" -so -algo bvx3 %_n_opt% > nul
exit /b

:decodeLazy2
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
.\lzfse.exe -decode -i "%~1.lzfse.lazy2" -so -algo bvx3 -lazy2 %_n_opt% > nul 2>&1
exit /b

:decodeOptimal
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
.\lzfse.exe -decode -i "%~1.lzfse.optimal" -so -algo bvx3 -optimal %_n_opt% > nul 2>&1
exit /b

:decodeLZ4
lz4 -d -c -q "%~1.tar.lz4" > nul 2>&1
exit /b

:decodeZSTD
zstd -d -c -q "%~1.tar.zst" > nul 2>&1
exit /b

:: Helpers 

:warmCache
:: Pre-read all compressed files into OS page cache before timing
for %%F in (
    "%~1.tgz"
    "%~1.lzfse.other3"
    "%~1.lzfse.bvx3"
    "%~1.lzfse.lazy2"
    "%~1.lzfse.optimal"
    "%~1.tar.lz4"
    "%~1.tar.zst"
) do (
    if exist %%F (
        powershell -NoProfile -Command "$null=[IO.File]::ReadAllBytes('%%~F')" 2>nul
    )
)
exit /b

:appendFileSize
:: %~1 = compressed file path, %~2 = log file path
powershell -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; if (Test-Path '%~1') { $s=(Get-Item '%~1').Length; Write-Output('==> Encoded size: '+$s+' bytes') } else { Write-Output('Compressed file not found: %~1') }" >> "%~2"
exit /b

:writeVerify
:: %~1 = result file path, %~2 = PASS or FAIL
powershell -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Write-Output('==> Verify: %~2')" >> "%~1"
exit /b

:nanoTimeElapsed
:: Nanosecond timer matching encode-win.bat / ?????? encode-win.bat ??
for /f %%T in ('powershell -NoProfile -Command "[System.Diagnostics.Stopwatch]::GetTimestamp()"') do set "_t0=%%T"
%1 %2 %3 %4 %5
set _rc=%ERRORLEVEL%
for /f %%T in ('powershell -NoProfile -Command "[System.Diagnostics.Stopwatch]::GetTimestamp()"') do set "_t1=%%T"
powershell -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; $ns=([long]'%_t1%'-[long]'%_t0%')*1000000000/[System.Diagnostics.Stopwatch]::Frequency; Write-Output ('==> Process took: '+$ns.ToString('D10')+' nanoseconds')"
exit /b %_rc%

@echo off
chcp 65001 > nul
:: Warm-cache：預讀整個資料集進 OS page cache，消除「第一個格式 cold-cache」造成的壓縮計時偏差（見 OPTIMIZATION.md R15/R16 cold-cache 註）
:: Warm-cache: pre-read the whole dataset so every compression format is timed under the same warm-cache condition (removes first-format cold-cache skew).
echo [Info] Warm-cache 預讀資料集 / Pre-reading dataset to warm OS cache... 
call :tarWarmup "%1"

if not exist bench_logs mkdir bench_logs
set "_nsuffix="
if not "%~2"=="" set "_nsuffix=-n%~2"
powershell -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Write-Output('[Info] 開始執行 tgz, lzfse, tlz4, zstd 基準測試... / Starting tgz, lzfse, tlz4, zstd benchmark...')"

echo [Info] Running tgz encode benchmark...
call :nanoTimeElapsed call :encodeTgz "%1" > .\bench_logs\%~1-encodeTgz%_nsuffix%-results.txt
call :appendFileSize "%~1.tgz" "bench_logs\%~1-encodeTgz%_nsuffix%-results.txt"

echo [Info] Running lzfse other3 encode benchmark...
call :nanoTimeElapsed call :encodeOther3 "%1" "%2" > .\bench_logs\%~1-encodeOther3%_nsuffix%-results.txt
call :appendFileSize "%~1.lzfse.other3" "bench_logs\%~1-encodeOther3%_nsuffix%-results.txt"

echo [Info] Running lzfse bvx3 encode benchmark...
call :nanoTimeElapsed call :encodeBVX3 "%1" "%2" > .\bench_logs\%~1-encodeBVX3%_nsuffix%-results.txt
call :appendFileSize "%~1.lzfse.bvx3" "bench_logs\%~1-encodeBVX3%_nsuffix%-results.txt"

echo [Info] Running lzfse lazy2 encode benchmark...
call :nanoTimeElapsed call :encodeLazy2 "%1" "%2" > .\bench_logs\%~1-encodeLazy2%_nsuffix%-results.txt
call :appendFileSize "%~1.lzfse.lazy2" "bench_logs\%~1-encodeLazy2%_nsuffix%-results.txt"

echo [Info] Running lzfse optimal encode benchmark...
call :nanoTimeElapsed call :encodeOptimal "%1" "%2" > .\bench_logs\%~1-encodeOptimal%_nsuffix%-results.txt
call :appendFileSize "%~1.lzfse.optimal" "bench_logs\%~1-encodeOptimal%_nsuffix%-results.txt"

echo [Info] Running lz4 encode benchmark...
call :nanoTimeElapsed call :encodeLZ4 "%1" > .\bench_logs\%~1-encodeLZ4%_nsuffix%-results.txt
call :appendFileSize "%~1.tar.lz4" "bench_logs\%~1-encodeLZ4%_nsuffix%-results.txt"

echo [Info] Running zstd encode benchmark...
call :nanoTimeElapsed call :encodeZSTD "%1" > bench_logs\%~1-encodeZSTD%_nsuffix%-results.txt
call :appendFileSize "%~1.tar.zst" "bench_logs\%~1-encodeZSTD%_nsuffix%-results.txt"

echo [Info] 彙整基準測試結果 / Summarising benchmark results...
powershell -NoProfile -Command "$csv=@('format,nanoseconds,encoded_bytes'); Get-ChildItem 'bench_logs\*-results.txt' | Sort-Object Name | ForEach-Object { $m=[regex]::Match($_.BaseName,'(encode\w+(?:-n\d+)?)-results'); $fmt=if($m.Success){$m.Groups[1].Value}else{$_.BaseName}; $c=Get-Content $_.FullName -Raw; $ns=([regex]::Match($c,'Process took:\s+(\d+)')).Groups[1].Value; $b=([regex]::Match($c,'Encoded size:\s+(\d+)')).Groups[1].Value; $csv+=$fmt+','+$ns+','+$b }; $csv | Out-File 'benchmark_summary.csv' -Encoding UTF8"
echo [OK] benchmark_summary.csv written
goto :EOF

:appendFileSize
:: %~1 = 輸出檔案路徑, %~2 = log 檔案路徑
powershell -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; if (Test-Path '%~1') { $s=(Get-Item '%~1').Length; Write-Output('==> Encoded size: '+$s+' bytes') } else { Write-Output('Output file not found: %~1') }" >> "%~2"
exit /b

:encodeOther3
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
tar -cf - "%~1" | .\lzfse.exe -encode -algo other3 %_n_opt% -si -o "%~1.lzfse.other3"
exit /b

:encodeBVX3
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
tar -cf - "%~1" | .\lzfse.exe -encode -algo bvx3 %_n_opt% -si -o "%~1.lzfse.bvx3"
exit /b

:encodeLazy2
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
tar -cf - "%~1" | .\lzfse.exe -encode -algo bvx3 -lazy2 %_n_opt% -si -o "%~1.lzfse.lazy2"
exit /b

:encodeOptimal
set "_n_opt="
if not "%~2"=="" set "_n_opt=-n %~2"
tar -cf - "%~1" | .\lzfse.exe -encode -algo bvx3 -optimal %_n_opt% -si -o "%~1.lzfse.optimal"
exit /b

:encodeLZ4
tar -cf - "%~1" | lz4 -9 -q -f - "%~1.tar.lz4"
exit /b

:encodeZSTD
tar -cf - "%~1" | zstd -9 -q -f -o "%~1.tar.zst"
exit /b

:tarWarmup
tar -cf - "%~1" > nul 2>&1
exit /b

:nanoTimeElapsed
:: 用法 / Usage: call :nanoTimeElapsed <command> [args...]
:: 對應 zsh nanoTimeElapsed "$@" / Maps to zsh nanoTimeElapsed "$@"
:: 注意：%* 在 call :label 子程序內展開的是外層腳本參數，必須用 %1 %2 %3... 取代
for /f %%T in ('powershell -NoProfile -Command "[System.Diagnostics.Stopwatch]::GetTimestamp()"') do set "_t0=%%T"
%1 %2 %3 %4 %5
set _rc=%ERRORLEVEL%
for /f %%T in ('powershell -NoProfile -Command "[System.Diagnostics.Stopwatch]::GetTimestamp()"') do set "_t1=%%T"
powershell -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; $ns=([long]'%_t1%'-[long]'%_t0%')*1000000000/[System.Diagnostics.Stopwatch]::Frequency; Write-Output ('==> Process took: '+$ns.ToString('D10')+' 奈秒/nanoseconds')"
exit /b %_rc%

:encodeTgz
:: 用法 / Usage: call :encodeTgz <folder_or_file>
:: 對應 zsh getar / Maps to zsh getar
:: XZ_OPT 在 gzip(-z) 下無效，Windows tar czf 直接用 gzip 壓縮
tar czf "%~1.tgz" "%~1"
exit /b

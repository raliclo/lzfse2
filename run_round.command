#!/bin/zsh
# Cowork 自動化執行器：compile → 測試守門 → benchmark
# Auto-runner: compile → gate on tests → benchmark
cd /Users/raliclo/proj/lzfse2 || exit 1
git gc --prune=now --aggressive > round_status.txt 2>&1
echo "RUNNING compile $(date +%H:%M:%S)" >> round_status.txt
rm -f ./lzfse
./compile.sh >> round_status.txt 2>&1
if [[ ! -x ./lzfse ]]; then
    echo "COMPILE_FAILED $(date +%H:%M:%S)" >> round_status.txt
    exit 1
fi
if grep -q "✗" lzfse-test.txt; then
    echo "TEST_FAILED $(date +%H:%M:%S)" >> round_status.txt
    exit 1
fi
echo "TEST_OK $(date +%H:%M:%S)" >> round_status.txt
echo "RUNNING benchmark $(date +%H:%M:%S)" >> round_status.txt
./benchmark.sh >> round_status.txt 2>&1
sudo ./benchmark2.sh >> round_status.txt 2>&1
rc=$?
if [[ $rc -eq 0 ]]; then
    echo "BENCH_DONE $(date +%H:%M:%S)" >> round_status.txt
else
    echo "BENCH_FAILED $rc $(date +%H:%M:%S)" >> round_status.txt
fi
git gc --prune=now --aggressive >> round_status.txt 2>&1

# 翻譯文件為英文版（繁中 → 英文；輸出檔名加 -en）
echo "RUNNING md-translate $(date +%H:%M:%S)" >> round_status.txt
./helper/md-translate.sh >> round_status.txt 2>&1

sudo ./gitOwner.sh
exit $rc

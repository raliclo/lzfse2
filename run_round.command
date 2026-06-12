#!/bin/zsh
# Cowork 自動化執行器：compile → 測試守門 → benchmark
# Auto-runner: compile → gate on tests → benchmark
cd /Users/raliclo/proj/lzfse2 || exit 1
echo "RUNNING compile $(date +%H:%M:%S)" > round_status.txt
rm -f ./lzfse
./compile.sh
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
./benchmark.sh
echo "BENCH_DONE $(date +%H:%M:%S)" >> round_status.txt

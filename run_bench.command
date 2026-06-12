#!/bin/zsh
# 只跑 benchmark（編譯與測試已由 run_compile.command 完成）
cd /Users/raliclo/proj/lzfse2 || exit 1
echo "RUNNING benchmark $(date +%H:%M:%S)" > round_status.txt
./benchmark.sh
echo "BENCH_DONE $(date +%H:%M:%S)" >> round_status.txt

#!/bin/zsh
setopt NULL_GLOB


source ./zshrc.sh

# lzfse is always rebuilt here, but never as root. compile.sh writes
# /opt/homebrew/bin/lzfse-debug, and once that file is root-owned every later
# non-root build dies with `ld: can't write output file`. gitOwner.sh only chowns
# the project directory, so nothing repairs it. This script normally runs under
# `sudo ./benchmark2.sh`, so drop back to the invoking user for the build.
# 此處一律重新編譯 lzfse，但絕不以 root 執行。compile.sh 會寫入
# /opt/homebrew/bin/lzfse-debug，該檔一旦變成 root 所有，之後每次非 root 的建置
# 都會以 `ld: can't write output file` 失敗。gitOwner.sh 只 chown 專案目錄，不會
# 修復它。本腳本通常以 `sudo ./benchmark2.sh` 執行，故編譯時降回呼叫者身分。
if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "$SUDO_USER" --preserve-env=PATH ./compile.sh
else
    ./compile.sh
fi
compile_rc=$?
if [[ $compile_rc -ne 0 ]]; then
    echo "benchmark2.sh aborted: compile.sh failed with status $compile_rc" >&2
    exit $compile_rc
fi

# Step.1 初始化狀態與輸出路徑 / Initialize status and output paths.
export ROUND_STATUS_FILE="${ROUND_STATUS_FILE:-round_status.txt}"
export LZ4BENCH_LOG_DIR="${LZ4BENCH_LOG_DIR:-lz4bench_log}"
cleanTempFiles() {
    rm -rf claw-code.*(N)
    rm -rf xbenchTest
    rm -rf llama.cpp.*(N)
}
roundStatus() {
    echo "$@ $(date +%H:%M:%S)" >> "$ROUND_STATUS_FILE"
}

# Step.2 清理前輪暫存檔 / Clean temporary artifacts from previous rounds.
cleanTempFiles

# Steps 3 to 6 — the lz4bench sweeps and the Time Profiler traces — run in
# benchmark.sh, which executes before this script. The step numbering continues
# from there rather than restarting, so a round's status log reads as one
# sequence. A copy of the sweep machinery used to sit here but was never called;
# it printed "[Info] Running Benchmark WITH probe mode" into the log of a script
# that runs no benchmarks, which made the log actively misleading.
# Steps 3 至 6——lz4bench 掃描與 Time Profiler trace——在 benchmark.sh 中執行，該
# 腳本先於本腳本執行。步驟編號由該處延續而非重新起算，使一輪的狀態記錄讀起來
# 是單一序列。此處原本有一份掃描機制的副本，但從未被呼叫；它會把「[Info] Running
# Benchmark WITH probe mode」印進一個不執行任何 benchmark 的腳本的記錄中，反而造成
# 誤導。
mkdir -p "$LZ4BENCH_LOG_DIR"

# Step.7 執行 powermetrics power benchmark / Run powermetrics power benchmark.
roundStatus "RUNNING_POWER_BENCHMARK"
./helper/power_benchmark.command >> "$ROUND_STATUS_FILE" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
    roundStatus "POWER_BENCHMARK_FAILED $rc"
    exit $rc
fi
roundStatus "POWER_BENCHMARK_DONE"

# Step.8 匯出並分析 trace / Export and analyze traces.
# 若本輪未產生新 trace（tracer.command 已停用），trace_analysis.command 會優雅跳過並沿用上一輪的 trace/analysis 結果，exit 0。
roundStatus "RUNNING_TRACE_ANALYSIS"
./helper/trace_analysis.command
rc=$?
if [[ $rc -ne 0 ]]; then
    roundStatus "TRACE_ANALYSIS_FAILED $rc"
    exit $rc
fi
roundStatus "TRACE_ANALYSIS_DONE"

# Step.9 彙整 CPU call tree 熱點 / Summarize CPU call tree hotspots.
# 同上，若無新 trace，cpu_call_tree_analysis.command 沿用上一輪結果並 exit 0。
roundStatus "RUNNING_CPU_CALL_TREE_ANALYSIS"
./helper/cpu_call_tree_analysis.command >> "$ROUND_STATUS_FILE" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
    roundStatus "CPU_CALL_TREE_ANALYSIS_FAILED $rc"
    exit $rc
fi
roundStatus "CPU_CALL_TREE_ANALYSIS_DONE"

# Step.10 壓縮 Git 物件，降低大量 trace 產物後的 repo 體積 / Compact Git objects after trace outputs.
roundStatus "RUNNING_GIT_GC"
git gc --prune=now --aggressive >> "$ROUND_STATUS_FILE" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
    roundStatus "GIT_GC_FAILED $rc"
    exit $rc
fi
roundStatus "GIT_GC_DONE"

# Step.11 由 benchmark/memProbe/trace 重建 BenchMarkResult.csv / Rebuild BenchMarkResult.csv.
roundStatus "RUNNING_BENCHMARK_RESULT_REBUILD"
./helper/benchmark_result_rebuild.command --write >> "$ROUND_STATUS_FILE" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
    roundStatus "BENCHMARK_RESULT_REBUILD_FAILED $rc"
    exit $rc
fi
roundStatus "BENCHMARK_RESULT_REBUILD_DONE"

# Step.12 整合 powermetrics CPU power 到 BenchMarkResult.csv / Integrate CPU power into BenchMarkResult.csv.
# （best_points.csv 尚未產生，power_summary_integrate 僅更新 BenchMarkResult.csv）
roundStatus "RUNNING_POWER_SUMMARY_INTEGRATE"
./helper/power_summary_integrate.command >> "$ROUND_STATUS_FILE" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
    roundStatus "POWER_SUMMARY_INTEGRATE_FAILED $rc"
    exit $rc
fi
roundStatus "POWER_SUMMARY_INTEGRATE_DONE"

# Step.13 產生 Best Points 分析，輸出至 best_points/ / Generate Best Points analysis into best_points/.
roundStatus "RUNNING_BEST_POINTS_ANALYSIS"
./helper/best_points_analysis.command >> "$ROUND_STATUS_FILE" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
    roundStatus "BEST_POINTS_ANALYSIS_FAILED $rc"
    exit $rc
fi
roundStatus "BEST_POINTS_ANALYSIS_DONE"

# Step.14 產生 Win/Mac 比較報告 / Generate Win/Mac comparison report.
roundStatus "RUNNING_COMPARISON"
python3 ./helper_windows/comparison_win.py >> "$ROUND_STATUS_FILE" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
    roundStatus "COMPARISON_FAILED $rc"
    exit $rc
fi
roundStatus "COMPARISON_DONE"

# Step.15 翻譯文件為英文版（繁中 → 英文；輸出檔名加 -en）
roundStatus "RUNNING_MD_TRANSLATE"
./helper/md-translate/md-translate-mac.sh >> "$ROUND_STATUS_FILE" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
    roundStatus "TRANSLATE_FAILED $rc"
    exit $rc
fi
roundStatus "MD_TRANSLATE_DONE"

echo "Done."

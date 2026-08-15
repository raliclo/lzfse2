#!/bin/zsh
setopt NULL_GLOB


# Settings from run_round.command arrive in a file, not the environment: sudo
# runs with env_reset here and refuses --preserve-env for these names. Sourced
# before zshrc.zsh because the functions there read SWIFT_TAR_BIN and
# LZFSE_REQUIRE_NATIVE_ZLIB at call time, and PATH must already carry the
# tar->swift_tar shim by then. Absent when run without -swift_tar, which is why
# the test is silent rather than an error.
# 來自 run_round.command 的設定以檔案傳遞，而非環境變數：本機 sudo 採 env_reset，
# 且拒絕以 --preserve-env 傳遞這些名稱。於 zshrc.zsh 之前載入，因為其中的函式在呼叫
# 當下才讀取 SWIFT_TAR_BIN 與 LZFSE_REQUIRE_NATIVE_ZLIB，且屆時 PATH 必須已含
# tar→swift_tar 的 shim。未帶 -swift_tar 時此檔不存在，故此處靜默略過而非報錯。
[[ -f ./.bench_env ]] && source ./.bench_env

source ./zshrc.zsh

# lzfse is always rebuilt here, but never as root. compile.zsh writes
# /opt/homebrew/bin/lzfse-debug, and once that file is root-owned every later
# non-root build dies with `ld: can't write output file`. gitOwner.sh only chowns
# the project directory, so nothing repairs it. This script normally runs under
# `sudo ./benchmark2.zsh`, so drop back to the invoking user for the build.
# 此處一律重新編譯 lzfse，但絕不以 root 執行。compile.zsh 會寫入
# /opt/homebrew/bin/lzfse-debug，該檔一旦變成 root 所有，之後每次非 root 的建置
# 都會以 `ld: can't write output file` 失敗。gitOwner.sh 只 chown 專案目錄，不會
# 修復它。本腳本通常以 `sudo ./benchmark2.zsh` 執行，故編譯時降回呼叫者身分。
if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "$SUDO_USER" --preserve-env=PATH ./compile.zsh
else
    ./compile.zsh
fi
compile_rc=$?
if [[ $compile_rc -ne 0 ]]; then
    echo "benchmark2.zsh aborted: compile.zsh failed with status $compile_rc" >&2
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

# Clean up on the way out, not only at the happy path's checkpoints. The sweeps
# below already call cleanTempFiles between runs, but a Ctrl-C or any failure
# outside the diskcheck path used to leave xbenchTest (an extracted tree, about
# the size of the corpus at ~1.4 GB) plus the per-format archives behind. The
# results live in $LZ4BENCH_LOG_DIR and BenchMarkResult.csv, neither of which
# cleanTempFiles touches, so running it on EXIT costs nothing.
# 離開時一併清理，而非只在正常流程的節點清理。下方的掃描本就會在各次執行之間呼叫
# cleanTempFiles，但 Ctrl-C、或 diskcheck 以外的任何失敗，原本會留下 xbenchTest
# （解壓樹，約當語料大小 1.4 GB）與各格式封存。結果檔位於 $LZ4BENCH_LOG_DIR 與
# BenchMarkResult.csv，皆不在 cleanTempFiles 的範圍內，故於 EXIT 執行它不付任何代價。
trap 'cleanTempFiles' EXIT INT TERM

roundStatus() {
    echo "$@ $(date +%H:%M:%S)" >> "$ROUND_STATUS_FILE"
}

# Step.2 清理前輪暫存檔 / Clean temporary artifacts from previous rounds.
cleanTempFiles

# Steps 3 to 6 — the lz4bench sweeps and the Time Profiler traces — run in
# benchmark.zsh, which executes before this script. The step numbering continues
# from there rather than restarting, so a round's status log reads as one
# sequence. A copy of the sweep machinery used to sit here but was never called;
# it printed "[Info] Running Benchmark WITH probe mode" into the log of a script
# that runs no benchmarks, which made the log actively misleading.
# Steps 3 至 6——lz4bench 掃描與 Time Profiler trace——在 benchmark.zsh 中執行，該
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
./helper/md-translate/md-translate-mac.zsh >> "$ROUND_STATUS_FILE" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
    roundStatus "TRANSLATE_FAILED $rc"
    exit $rc
fi
roundStatus "MD_TRANSLATE_DONE"

echo "Done."

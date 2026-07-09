#!/bin/zsh
setopt NULL_GLOB


source ./zshrc.sh
source ./compile.sh

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

# Step.3 設定 benchmark 掃描參數 / Configure benchmark sweep parameters.
# 下一輪啟用記憶體峰值量測（probe）：正式壓縮/解壓 benchmark 完成後，才量所有格式 encode+decode peak RSS。
# 預設開啟；要關閉就在呼叫前 export LZFSE_MEMPROBE=0。probe 會額外重跑各格式 encode/decode，耗時略增。
# 本輪固定同碼掃 -n 40 / 8 / 4，結果檔名會帶 -n40 / -n8 / -n4。
# Enable peak-RSS probe for the next round (default on); set LZFSE_MEMPROBE=0 to disable.
export LZFSE_MEMPROBE="${LZFSE_MEMPROBE:-1}"
typeset -a LZFSE_N_SWEEP
if [[ -n "${LZFSE_N_SWEEP_OVERRIDE:-}" ]]; then
    LZFSE_N_SWEEP=(${=LZFSE_N_SWEEP_OVERRIDE})
else
    LZFSE_N_SWEEP=(40 8 4)
fi
if [[ "$LZFSE_MEMPROBE" == "1" ]]; then
    echo "[Info] Running Benchmark WITH probe mode (LZFSE_MEMPROBE=1). Peak-RSS probes run after compression/decompression benchmark and will be recorded in the result txt."
else
    echo "[Info] Running Benchmark without probe mode. Results will be saved as ${LZ4BENCH_LOG_DIR}/lz4bench-<dataset>-n<N>.txt."
fi
mkdir -p "$LZ4BENCH_LOG_DIR"

run_lz4bench_sweep() {
    local dataset="$1"
    local n suffix out rc

    cleanup_bench_artifacts() {
        rm -rf "${dataset}".*(N)
        rm -rf xbenchTest
    }

    for n in "${LZFSE_N_SWEEP[@]}"; do
        suffix="-n${n}"
        out="${LZ4BENCH_LOG_DIR}/lz4bench-${dataset}${suffix}.txt"
        export LZFSE_BENCH_N="$n"
        export LZFSE_BENCH_SUFFIX="$suffix"

        cleanup_bench_artifacts
        echo "[Info] Running ${dataset} benchmark with -n ${n}; output=${out}"
        roundStatus "RUNNING_LZ4BENCH ${dataset}${suffix}"
        diskcheck || { echo "Benchmark aborted: insufficient disk space." >&2; roundStatus "LZ4BENCH_FAILED ${dataset}${suffix} diskcheck"; cleanup_bench_artifacts; return 1; }
        lz4bench "$dataset" > "$out" 2>&1
        rc=$?
        cleanup_bench_artifacts
        if [[ $rc -ne 0 ]]; then
            echo "Benchmark aborted: ${dataset} lz4bench -n ${n} failed with status $rc." >&2
            roundStatus "LZ4BENCH_FAILED ${dataset}${suffix} ${rc}"
            return $rc
        fi
        roundStatus "LZ4BENCH_OK ${dataset}${suffix}"
        echo "[Info] Completed ${dataset} benchmark with -n ${n}; output=${out} ,Sleeping 60s before next sweep."
        sleep 60
    done
}
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
roundStatus "RUNNING_TRACE_ANALYSIS"
./helper/trace_analysis.command
rc=$?
if [[ $rc -ne 0 ]]; then
    roundStatus "TRACE_ANALYSIS_FAILED $rc"
    exit $rc
fi
roundStatus "TRACE_ANALYSIS_DONE"

# Step.9 彙整 CPU call tree 熱點 / Summarize CPU call tree hotspots.
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
echo "RUNNING md-translate $(date +%H:%M:%S)" >> round_status.txt
./helper/md-translate-mac.sh >> round_status.txt 2>&1

echo "Done."

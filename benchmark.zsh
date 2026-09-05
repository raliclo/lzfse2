#!/bin/zsh
# benchmark.zsh -- round step 1: the lz4bench sweeps over both corpora.
# benchmark.zsh -- 一輪的第 1 步：對兩份語料執行 lz4bench 掃描。
#
#   ./benchmark.zsh                              # -n 40, 8, 4 over claw-code then llama.cpp
#   LZFSE_MEMPROBE=0 ./benchmark.zsh             # skip the peak-RSS probes / 略過 peak-RSS 量測
#   LZFSE_N_SWEEP_OVERRIDE="8 4" ./benchmark.zsh # sweep a different -n list / 改用其他 -n 清單
#   ./benchmark.zsh --help
#
# Runs for roughly 38 minutes, then `sudo ./benchmark2.zsh` continues the round.
# 約需 38 分鐘，其後以 `sudo ./benchmark2.zsh` 接續整輪。
#
# The 60-second sleeps between sweeps are not padding: they let the machine settle
# so one sweep's thermal state does not bias the next sweep's timings.
# 掃描之間的 60 秒 sleep 並非湊數：那是讓機器回穩，避免前一次掃描的熱度污染下一次的
# 計時結果。
#
# Time Profiler traces are skipped unless LZFSE_POWER_TEST=1 (which
# run_round.command -power-test exports), because they cost a lot of wall time.
# With them off, the later analysis steps reuse the previous round's trace/ output.
# 除非 LZFSE_POWER_TEST=1（由 run_round.command -power-test 匯出），否則跳過 Time
# Profiler trace，因其耗時可觀；未啟用時，後續分析步驟會沿用上一輪 trace/ 的結果。
script_path="${0:A}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,22p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

setopt NULL_GLOB


source ./zshrc.zsh      # 通用 shell 設定，提供 nanoTimeElapsed / general profile
source ./lz4bench.zsh   # benchmark 專用；順序有意義 / benchmark only; the order matters

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
# results live in $LZ4BENCH_LOG_DIR and BenchMarkResult.csv2, neither of which
# cleanTempFiles touches, so running it on EXIT costs nothing.
# 離開時一併清理，而非只在正常流程的節點清理。下方的掃描本就會在各次執行之間呼叫
# cleanTempFiles，但 Ctrl-C、或 diskcheck 以外的任何失敗，原本會留下 xbenchTest
# （解壓樹，約當語料大小 1.4 GB）與各格式封存。結果檔位於 $LZ4BENCH_LOG_DIR 與
# BenchMarkResult.csv2，皆不在 cleanTempFiles 的範圍內，故於 EXIT 執行它不付任何代價。
trap 'cleanTempFiles' EXIT INT TERM

roundStatus() {
    echo "$@ $(date +%H:%M:%S)" >> "$ROUND_STATUS_FILE"
}

# Step.2 清理前輪暫存檔 / Clean temporary artifacts from previous rounds.
cleanTempFiles
sleep 60

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

# Step.4 執行 claw-code benchmark 掃描 / Run claw-code benchmark sweep.
run_lz4bench_sweep claw-code
rc=$?
if [[ $rc -ne 0 ]]; then
    exit $rc
fi
cleanTempFiles

sleep 60

# Step.5 執行 llama.cpp benchmark 掃描 / Run llama.cpp benchmark sweep.
run_lz4bench_sweep llama.cpp
rc=$?
if [[ $rc -ne 0 ]]; then
    exit $rc
fi
cleanTempFiles

unset LZFSE_BENCH_N
unset LZFSE_BENCH_SUFFIX

# Step.6 執行 Time Profiler trace / Run Time Profiler traces.
# 預設跳過（耗時可觀）。以 run_round.command -power-test 啟用，該旗標會匯出
# LZFSE_POWER_TEST=1；未啟用時 trace_analysis 與 cpu_call_tree_analysis 會沿用
# trace/ 中上一輪的結果。
# Skipped by default (it costs a lot of wall time). Enable it with
# run_round.command -power-test, which exports LZFSE_POWER_TEST=1; when it is
# off, trace_analysis and cpu_call_tree_analysis reuse the previous round's
# results from trace/.
if [[ "${LZFSE_POWER_TEST:-0}" == "1" ]]; then
    roundStatus "RUNNING_TRACER"
    ./helper/tracer.command
    rc=$?
    if [[ $rc -ne 0 ]]; then
        roundStatus "TRACER_FAILED $rc"
        exit $rc
    fi
    roundStatus "TRACER_DONE"
else
    roundStatus "TRACER_SKIPPED (use -power-test to enable)"
fi

echo "Step1. Done. Please run sudo ./benchmark2.zsh to continue the benchmark process."

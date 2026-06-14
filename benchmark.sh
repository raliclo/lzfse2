#!/bin/zsh
setopt NULL_GLOB

rm -rf xbenchTest
rm -rf llama.cpp.*(N)
rm -rf claw-code.*(N)
git gc --prune=now --aggressive >> round_status.txt 2>&1

source ./zshrc.sh
source ./compile.sh
sleep 60
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
    echo "[Info] Running Benchmark without probe mode. Results will be saved as lz4bench-<dataset>-n<N>.txt."
fi

run_lz4bench_sweep() {
    local dataset="$1"
    local n suffix out rc

    cleanup_bench_artifacts() {
        rm -rf "${dataset}".*(N)
        rm -rf xbenchTest
    }

    for n in "${LZFSE_N_SWEEP[@]}"; do
        suffix="-n${n}"
        out="lz4bench-${dataset}${suffix}.txt"
        export LZFSE_BENCH_N="$n"
        export LZFSE_BENCH_SUFFIX="$suffix"

        cleanup_bench_artifacts
        echo "[Info] Running ${dataset} benchmark with -n ${n}; output=${out}"
        diskcheck || { echo "Benchmark aborted: insufficient disk space." >&2; cleanup_bench_artifacts; return 1; }
        lz4bench "$dataset" > "$out" 2>&1
        rc=$?
        cleanup_bench_artifacts
        if [[ $rc -ne 0 ]]; then
            echo "Benchmark aborted: ${dataset} lz4bench -n ${n} failed with status $rc." >&2
            return $rc
        fi

        git gc --prune=now --aggressive >> round_status.txt 2>&1
    done
}

run_lz4bench_sweep claw-code
rc=$?
if [[ $rc -ne 0 ]]; then
    exit $rc
fi
rm -rf claw-code.*(N)
rm -rf xbenchTest
rm -rf llama.cpp.*(N)

sleep 60

run_lz4bench_sweep llama.cpp
rc=$?
if [[ $rc -ne 0 ]]; then
    exit $rc
fi

unset LZFSE_BENCH_N
unset LZFSE_BENCH_SUFFIX
rm -rf xbenchTest
rm -rf llama.cpp.*(N)
rm -rf claw-code.*(N)
git gc --prune=now --aggressive >> round_status.txt 2>&1

echo "Done."

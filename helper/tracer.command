#!/bin/zsh
set -u

cd /Users/raliclo/proj/lzfse2 || exit 1

TRACE_DIR="./trace"
PROFILE_BIN="$TRACE_DIR/lzfse-profile"
LOG_OUT="$TRACE_DIR/tracer.log"
STATUS_OUT="$TRACE_DIR/tracer_status.txt"
PACKAGE_COUNT_FILE="$TRACE_DIR/.trace_package_count"
TRACE_TIMEOUT_SECONDS="${TRACE_TIMEOUT_SECONDS:-300}"
XCTRACE_TIME_LIMIT="${XCTRACE_TIME_LIMIT:-5m}"

mkdir -p "$TRACE_DIR"
echo "RUNNING tracer $(date +%H:%M:%S)" > "$STATUS_OUT"

traceRoundStatus() {
    if [[ -n "${ROUND_STATUS_FILE:-}" ]]; then
        echo "$@ $(date +%H:%M:%S)" >> "$ROUND_STATUS_FILE"
    fi
}

tracePackageCount() {
    local packages=( "$TRACE_DIR"/*.trace(N) "$TRACE_DIR"/*.trace.timeout(N) )
    echo "${#packages[@]}"
}

run_xctrace_record() {
    local start_seconds="$SECONDS"
    xcrun xctrace record --time-limit "$XCTRACE_TIME_LIMIT" "$@"
    local rc=$?
    local elapsed=$((SECONDS - start_seconds))
    if [[ $elapsed -ge $TRACE_TIMEOUT_SECONDS ]]; then
        return 124
    fi
    return "$rc"
}

trace_one() {
    local dataset="$1"
    local algo="$2"
    local trace_n="${3:-}"
    local tar_input="$TRACE_DIR/${dataset}.tar"
    local trace_suffix=""
    local n_args=()
    if [[ -n "$trace_n" ]]; then
        trace_suffix="-n${trace_n}"
        n_args=(-n "$trace_n")
    fi
    local trace_out="$TRACE_DIR/${dataset}-${algo}${trace_suffix}.trace"
    local compressed_out="$TRACE_DIR/${dataset}.${algo}${trace_suffix}.out"
    local compressed_active="${compressed_out}.active"

    rm -rf "$trace_out" "$compressed_out" "$compressed_active"
    echo "active ${dataset} ${algo}${trace_suffix} $(date '+%Y-%m-%d %H:%M:%S')" > "$compressed_active"
    echo "[Info] Trace ${dataset} ${algo}${trace_suffix} -> ${trace_out}"

    case "$algo" in
        tgz)
            run_xctrace_record \
                --template "Time Profiler" \
                --output "$trace_out" \
                --launch -- /usr/bin/tar czf "$compressed_out" "$dataset"
            ;;
        zstd)
            run_xctrace_record \
                --template "Time Profiler" \
                --output "$trace_out" \
                --launch -- /opt/homebrew/bin/zstd -9 -T0 -q -f "$tar_input" -o "$compressed_out"
            ;;
        tar.lz4)
            run_xctrace_record \
                --template "Time Profiler" \
                --output "$trace_out" \
                --launch -- /opt/homebrew/bin/lz4 -T0 -6 -q -f "$tar_input" "$compressed_out"
            ;;
        other3)
            run_xctrace_record \
                --template "Time Profiler" \
                --output "$trace_out" \
                --target-stdin "$tar_input" \
                --launch -- "$PROFILE_BIN" -encode -si -o "$compressed_out" -algo other3 "${n_args[@]}"
            ;;
        apple)
            run_xctrace_record \
                --template "Time Profiler" \
                --output "$trace_out" \
                --target-stdin "$tar_input" \
                --launch -- "$PROFILE_BIN" -encode -si -o "$compressed_out" -algo apple "${n_args[@]}"
            ;;
        bvx3)
            run_xctrace_record \
                --template "Time Profiler" \
                --output "$trace_out" \
                --target-stdin "$tar_input" \
                --launch -- "$PROFILE_BIN" -encode -si -o "$compressed_out" -algo bvx3 "${n_args[@]}"
            ;;
        lazy2)
            run_xctrace_record \
                --template "Time Profiler" \
                --output "$trace_out" \
                --target-stdin "$tar_input" \
                --launch -- "$PROFILE_BIN" -encode -si -o "$compressed_out" -algo bvx3 -lazy2 "${n_args[@]}"
            ;;
        optimal)
            run_xctrace_record \
                --template "Time Profiler" \
                --output "$trace_out" \
                --target-stdin "$tar_input" \
                --launch -- "$PROFILE_BIN" -encode -si -o "$compressed_out" -algo bvx3 -optimal "${n_args[@]}"
            ;;
        *)
            echo "[Error] unknown trace algorithm: $algo"
            return 1
            ;;
    esac
    local rc=$?
    rm -f "$compressed_out" "$compressed_active"
    echo "TRACE_OUTPUT_CLEANED ${dataset} ${algo}${trace_suffix} $(date +%H:%M:%S)" >> "$STATUS_OUT"
    traceRoundStatus "TRACE_OUTPUT_CLEANED ${dataset} ${algo}${trace_suffix}"
    if [[ $rc -eq 124 && -d "$trace_out" ]]; then
        rm -rf "${trace_out}.timeout"
        mv "$trace_out" "${trace_out}.timeout"
    fi
    return "$rc"
}

{
    echo "[Info] Clean old trace packages / 清除舊 trace packages"
    echo "CLEAN_OLD_TRACES $(date +%H:%M:%S)" >> "$STATUS_OUT"
    traceRoundStatus "CLEAN_OLD_TRACES"
    rm -rf "$TRACE_DIR"/*.trace(N)
    rm -rf "$TRACE_DIR"/*.trace.timeout(N)
    rm -f "$PACKAGE_COUNT_FILE"

    echo "[Info] Build profile binary / 建立 profiling binary"
    swiftc -O -g lzfse-cli.swift -o "$PROFILE_BIN"

    typeset -a LZFSE_TRACE_N_SWEEP
    if [[ -n "${LZFSE_TRACE_N_SWEEP_OVERRIDE:-}" ]]; then
        LZFSE_TRACE_N_SWEEP=(${=LZFSE_TRACE_N_SWEEP_OVERRIDE})
    else
        LZFSE_TRACE_N_SWEEP=(4 8 40)
    fi

    dataset=""
    for dataset in claw-code llama.cpp; do
        if [[ ! -d "$dataset" ]]; then
            echo "[Error] dataset not found: $dataset"
            exit 1
        fi

        echo "[Info] Prepare tar input for ${dataset} / 建立供 -si 使用的 tar input"
        tar -cf "$TRACE_DIR/${dataset}.tar" "$dataset"

        algo=""
        for algo in tgz zstd tar.lz4; do
            echo "RUNNING trace ${dataset} ${algo} $(date +%H:%M:%S)" >> "$STATUS_OUT"
            traceRoundStatus "RUNNING_TRACE ${dataset} ${algo}"
            if trace_one "$dataset" "$algo"; then
                echo "TRACE_OK ${dataset} ${algo} $(date +%H:%M:%S)" >> "$STATUS_OUT"
                traceRoundStatus "TRACE_DONE ${dataset} ${algo}"
            else
                rc=$?
                if [[ $rc -eq 124 ]]; then
                    echo "TRACE_TIMEOUT ${dataset} ${algo} ${TRACE_TIMEOUT_SECONDS}s $(date +%H:%M:%S)" >> "$STATUS_OUT"
                    traceRoundStatus "TRACE_TIMEOUT ${dataset} ${algo} ${TRACE_TIMEOUT_SECONDS}s"
                    continue
                else
                    echo "TRACE_FAILED ${dataset} ${algo} ${rc} $(date +%H:%M:%S)" >> "$STATUS_OUT"
                    traceRoundStatus "TRACE_FAILED ${dataset} ${algo} ${rc}"
                    exit "$rc"
                fi
            fi
        done

        trace_n=""
        for trace_n in "${LZFSE_TRACE_N_SWEEP[@]}"; do
            for algo in other3 apple bvx3 lazy2 optimal; do
                echo "RUNNING trace ${dataset} ${algo} -n ${trace_n} $(date +%H:%M:%S)" >> "$STATUS_OUT"
                traceRoundStatus "RUNNING_TRACE ${dataset} ${algo} -n ${trace_n}"
                if trace_one "$dataset" "$algo" "$trace_n"; then
                    echo "TRACE_OK ${dataset} ${algo} -n ${trace_n} $(date +%H:%M:%S)" >> "$STATUS_OUT"
                    traceRoundStatus "TRACE_DONE ${dataset} ${algo} -n ${trace_n}"
                else
                    rc=$?
                    if [[ $rc -eq 124 ]]; then
                        echo "TRACE_TIMEOUT ${dataset} ${algo} -n ${trace_n} ${TRACE_TIMEOUT_SECONDS}s $(date +%H:%M:%S)" >> "$STATUS_OUT"
                        traceRoundStatus "TRACE_TIMEOUT ${dataset} ${algo} -n ${trace_n} ${TRACE_TIMEOUT_SECONDS}s"
                        continue
                    else
                        echo "TRACE_FAILED ${dataset} ${algo} -n ${trace_n} ${rc} $(date +%H:%M:%S)" >> "$STATUS_OUT"
                        traceRoundStatus "TRACE_FAILED ${dataset} ${algo} -n ${trace_n} ${rc}"
                        exit "$rc"
                    fi
                fi
            done
        done
    done
} > "$LOG_OUT" 2>&1

rc=$?
rm -f "$TRACE_DIR/claw-code.tar" "$TRACE_DIR/llama.cpp.tar"
package_count="$(tracePackageCount)"
echo "$package_count" > "$PACKAGE_COUNT_FILE"
echo "TRACE_PACKAGE_COUNT_TRACER_END ${package_count} $(date +%H:%M:%S)" >> "$STATUS_OUT"
traceRoundStatus "TRACE_PACKAGE_COUNT_TRACER_END ${package_count}"
if [[ $rc -eq 0 && $package_count -eq 0 ]]; then
    rc=1
    echo "TRACE_FAILED no_trace_packages $(date +%H:%M:%S)" >> "$STATUS_OUT"
    traceRoundStatus "TRACER_TRACE_FAILED no_trace_packages"
fi
echo "EXIT $rc $(date +%H:%M:%S)" >> "$STATUS_OUT"
if [[ $rc -eq 0 ]]; then
    echo "TRACE_DONE $(date +%H:%M:%S)" >> "$STATUS_OUT"
    traceRoundStatus "TRACER_TRACE_DONE"
else
    echo "TRACE_FAILED $(date +%H:%M:%S)" >> "$STATUS_OUT"
    traceRoundStatus "TRACER_TRACE_FAILED"
fi

exit "$rc"

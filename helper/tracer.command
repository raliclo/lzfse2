#!/bin/zsh
set -u

cd /Users/raliclo/proj/lzfse2 || exit 1

TRACE_DIR="./trace"
PROFILE_BIN="$TRACE_DIR/lzfse-profile"
LOG_OUT="$TRACE_DIR/tracer.log"
STATUS_OUT="$TRACE_DIR/tracer_status.txt"

mkdir -p "$TRACE_DIR"
echo "RUNNING tracer $(date +%H:%M:%S)" > "$STATUS_OUT"

trace_one() {
    local dataset="$1"
    local algo="$2"
    local tar_input="$TRACE_DIR/${dataset}.tar"
    local trace_out="$TRACE_DIR/${dataset}-${algo}.trace"
    local compressed_out="$TRACE_DIR/${dataset}.${algo}.out"
    local command_text

    rm -rf "$trace_out" "$compressed_out"
    echo "[Info] Trace ${dataset} ${algo} -> ${trace_out}"

    case "$algo" in
        tgz)
            xcrun xctrace record \
                --template "Time Profiler" \
                --output "$trace_out" \
                --launch -- /usr/bin/tar czf "$compressed_out" "$dataset"
            ;;
        zstd)
            xcrun xctrace record \
                --template "Time Profiler" \
                --output "$trace_out" \
                --launch -- /opt/homebrew/bin/zstd -9 -T0 -q -f "$tar_input" -o "$compressed_out"
            ;;
        tar.lz4)
            xcrun xctrace record \
                --template "Time Profiler" \
                --output "$trace_out" \
                --launch -- /opt/homebrew/bin/lz4 -T0 -6 -q -f "$tar_input" "$compressed_out"
            ;;
        other3)
            command_text="cat '$tar_input' | '$PROFILE_BIN' -encode -si -o '$compressed_out' -algo other3"
            xcrun xctrace record \
                --template "Time Profiler" \
                --output "$trace_out" \
                --launch -- /bin/zsh -lc "$command_text"
            ;;
        apple)
            command_text="cat '$tar_input' | '$PROFILE_BIN' -encode -si -o '$compressed_out' -algo apple"
            xcrun xctrace record \
                --template "Time Profiler" \
                --output "$trace_out" \
                --launch -- /bin/zsh -lc "$command_text"
            ;;
        bvx3)
            command_text="cat '$tar_input' | '$PROFILE_BIN' -encode -si -o '$compressed_out' -algo bvx3"
            xcrun xctrace record \
                --template "Time Profiler" \
                --output "$trace_out" \
                --launch -- /bin/zsh -lc "$command_text"
            ;;
        lazy2)
            command_text="cat '$tar_input' | '$PROFILE_BIN' -encode -si -o '$compressed_out' -algo bvx3 -lazy2"
            xcrun xctrace record \
                --template "Time Profiler" \
                --output "$trace_out" \
                --launch -- /bin/zsh -lc "$command_text"
            ;;
        optimal)
            command_text="cat '$tar_input' | '$PROFILE_BIN' -encode -si -o '$compressed_out' -algo bvx3 -optimal"
            xcrun xctrace record \
                --template "Time Profiler" \
                --output "$trace_out" \
                --launch -- /bin/zsh -lc "$command_text"
            ;;
        *)
            echo "[Error] unknown trace algorithm: $algo"
            return 1
            ;;
    esac
    local rc=$?
    rm -f "$compressed_out"
    return "$rc"
}

{
    echo "[Info] Build profile binary / 建立 profiling binary"
    swiftc -O -g lzfse-cli.swift -o "$PROFILE_BIN"

    dataset=""
    for dataset in claw-code llama.cpp; do
        if [[ ! -d "$dataset" ]]; then
            echo "[Error] dataset not found: $dataset"
            exit 1
        fi

        echo "[Info] Prepare tar input for ${dataset} / 建立供 -si 使用的 tar input"
        tar -cf "$TRACE_DIR/${dataset}.tar" "$dataset"

        algo=""
        for algo in tgz zstd tar.lz4 other3 apple bvx3 lazy2 optimal; do
            echo "RUNNING trace ${dataset} ${algo} $(date +%H:%M:%S)" >> "$STATUS_OUT"
            if trace_one "$dataset" "$algo"; then
                echo "TRACE_OK ${dataset} ${algo} $(date +%H:%M:%S)" >> "$STATUS_OUT"
            else
                rc=$?
                echo "TRACE_FAILED ${dataset} ${algo} ${rc} $(date +%H:%M:%S)" >> "$STATUS_OUT"
                exit "$rc"
            fi
        done
    done
} > "$LOG_OUT" 2>&1

rc=$?
rm -f "$TRACE_DIR/claw-code.tar" "$TRACE_DIR/llama.cpp.tar" "$TRACE_DIR"/*.out(N)
echo "EXIT $rc $(date +%H:%M:%S)" >> "$STATUS_OUT"
if [[ $rc -eq 0 ]]; then
    echo "TRACE_DONE $(date +%H:%M:%S)" >> "$STATUS_OUT"
else
    echo "TRACE_FAILED $(date +%H:%M:%S)" >> "$STATUS_OUT"
fi

exit "$rc"

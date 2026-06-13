#!/bin/zsh
set -u

cd /Users/raliclo/proj/lzfse2 || exit 1

TRACE_DIR="./trace"
TAR_INPUT="$TRACE_DIR/claw-code.tar"
PROFILE_BIN="$TRACE_DIR/lzfse-profile"
TRACE_OUT="$TRACE_DIR/lzfse-claw-optimal.trace"
COMPRESSED_OUT="$TRACE_DIR/claw-code.optimal.lzfse"
LOG_OUT="$TRACE_DIR/tracer.log"
STATUS_OUT="$TRACE_DIR/tracer_status.txt"

mkdir -p "$TRACE_DIR"
echo "RUNNING tracer $(date +%H:%M:%S)" > "$STATUS_OUT"

{
    echo "[Info] Build profile binary / 建立 profiling binary"
    swiftc -O -g lzfse-cli.swift -o "$PROFILE_BIN"

    echo "[Info] Prepare tar input for -si / 建立供 -si 使用的 tar input"
    tar -cf "$TAR_INPUT" claw-code

    echo "[Info] Remove previous trace outputs / 移除前次 trace 輸出"
    rm -rf "$TRACE_OUT" "$COMPRESSED_OUT"

    echo "[Info] Start Time Profiler with stdin path / 使用 -si 路徑啟動 Time Profiler"
    xcrun xctrace record \
        --template "Time Profiler" \
        --output "$TRACE_OUT" \
        --launch -- /bin/zsh -lc \
        "cat '$TAR_INPUT' | '$PROFILE_BIN' -encode -si -o '$COMPRESSED_OUT' -algo bvx3 -optimal"
} > "$LOG_OUT" 2>&1

status=$?
echo "EXIT $status $(date +%H:%M:%S)" >> "$STATUS_OUT"
if [[ $status -eq 0 ]]; then
    echo "TRACE_DONE $(date +%H:%M:%S)" >> "$STATUS_OUT"
else
    echo "TRACE_FAILED $(date +%H:%M:%S)" >> "$STATUS_OUT"
fi

exit $status

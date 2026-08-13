#!/bin/zsh
# =====================================================================
# system_tracer.command — record a System Trace and summarise thread states.
# system_tracer.command — 錄製 System Trace 並彙整執行緒狀態。
#
# Time Profiler answers "where did CPU time go". It cannot answer "what was a
# thread waiting for", because it samples running threads only. System Trace
# records thread state intervals (Running / Blocked / Runnable / Interrupted),
# which core each interval ran on (P or E), and whether it was thermally
# throttled — the three things needed to tell real parallelism from
# oversubscription, semaphore contention, or throttling.
# Time Profiler 回答的是「CPU 時間花在哪裡」。它無法回答「執行緒在等什麼」，因為
# 它只取樣執行中的執行緒。System Trace 記錄執行緒的狀態區間（Running / Blocked /
# Runnable / Interrupted）、每個區間跑在哪個核心（P 或 E），以及是否遭熱節流——
# 這三項正是區分真實平行、過度訂閱、semaphore 競爭與節流所需。
#
# Output goes to trace_system/, never trace/: trace_analysis.command globs
# "$TRACE_DIR"/*.trace and would try to read a System Trace bundle as Time
# Profiler data.
# 輸出寫到 trace_system/ 而非 trace/：trace_analysis.command 以
# "$TRACE_DIR"/*.trace 掃描，會試圖把 System Trace 的 bundle 當成 Time Profiler
# 資料讀取。
#
# Usage / 用法:
#   ./helper/system_tracer.command [-test-only|-parse-only] [-- <cmd> [args...]]
#     (default / 預設)  record, then parse / 先錄製，再解析
#     -test-only        record only, leave the bundle for later / 只錄製
#     -parse-only       parse whatever is already in trace_system/ / 只解析既有結果
#     --                the command to trace; defaults to the RGB1 DOE bench
#                       要追蹤的命令；預設為 RGB1 DOE 量測
# =====================================================================
set -euo pipefail
cd "${0:A:h}/.." || exit 1

SYSTEM_TRACE_DIR="${SYSTEM_TRACE_DIR:-trace_system}"
SYSTEM_TRACE_LIMIT="${SYSTEM_TRACE_LIMIT:-30s}"
SUMMARY_CSV="$SYSTEM_TRACE_DIR/summary_system_trace.csv"

# xctrace writes its raw kernel trace to TMPDIR and only converts it into the
# --output bundle at the end, so TMPDIR — not SYSTEM_TRACE_DIR — is what fills
# up. Measured at roughly 240 MB/s of wall time, system-wide, regardless of
# --time-limit. Point SYSTEM_TRACE_TMPDIR at a volume with room when the boot
# disk is tight.
# xctrace 將原始 kernel trace 寫入 TMPDIR，最後才轉為 --output 指定的 bundle，
# 故撐爆磁碟的是 TMPDIR 而非 SYSTEM_TRACE_DIR。實測約每秒 240 MB（全系統，且與
# --time-limit 無關）。開機磁碟吃緊時，將 SYSTEM_TRACE_TMPDIR 指向有空間的卷。
if [[ -n "${SYSTEM_TRACE_TMPDIR:-}" ]]; then
    mkdir -p "$SYSTEM_TRACE_TMPDIR"
    export TMPDIR="$SYSTEM_TRACE_TMPDIR"
fi

# An interrupted recording does not clean up after itself: killing xctrace left
# 30 GB of orphaned instruments*.ktrace behind, silently, across a few attempts.
# Since interrupting a trace is the normal way to stop one that is too large,
# the cleanup has to be unconditional.
# 被中斷的錄製不會自我清理：終止 xctrace 後留下 30 GB 的孤兒
# instruments*.ktrace，且是靜默累積數次的結果。既然「中斷」正是停止過大 trace
# 的常規手段，此清理必須無條件執行。
cleanup_ktrace() {
    local orphans=("${TMPDIR:-/tmp}"/instruments*.ktrace(N))
    if (( ${#orphans} )); then
        echo "[Clean] removing ${#orphans} orphaned ktrace / 清除孤兒 ktrace" >&2
        rm -rf "${orphans[@]}"
    fi
}
trap cleanup_ktrace EXIT INT TERM

DO_RECORD=1
DO_PARSE=1
typeset -a TARGET_CMD
TARGET_CMD=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -test-only)  DO_PARSE=0; shift ;;
        -parse-only) DO_RECORD=0; shift ;;
        --)          shift; TARGET_CMD=("$@"); break ;;
        -h|--help)   sed -n '2,34p' "$0"; exit 0 ;;
        *)           echo "[Error] unknown flag $1 (see --help)" >&2; exit 1 ;;
    esac
done

# The default target is the RGB1 DOE bench, because the open question this script
# was built for is whether its -n 20 run really uses 20 threads productively.
# 預設目標為 RGB1 DOE 量測，因為本腳本要回答的未決問題，正是它的 -n 20 是否真的
# 有效使用了 20 條執行緒。
if (( ${#TARGET_CMD} == 0 )); then
    DOE="swift_tar/verifications/rgb1/swift_tar_DOE"
    SAMPLES=(swift_tar/verifications/rgb1/sample/t0000[234]0s.rgb1(N))
    if [[ -x "$DOE" ]] && (( ${#SAMPLES} )); then
        TARGET_CMD=("./$DOE" --preset predictive --codec zstd --level 3
                    --slices 20 -n 20 --no-verify --repeat 3 "${SAMPLES[@]}")
    elif (( DO_RECORD )); then
        echo "[Error] no target given and the default DOE bench is unavailable" >&2
        echo "        pass one after --, e.g. -- ./lzfse -encode ..." >&2
        exit 1
    fi
fi

mkdir -p "$SYSTEM_TRACE_DIR"
STAMP="$(date '+%Y%m%d-%H%M%S')"
TRACE_OUT="$SYSTEM_TRACE_DIR/system-${STAMP}.trace"

# ---------------------------------------------------------------------
if (( DO_RECORD )); then
    echo "[Info] date / 日期: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "[Info] target / 目標: ${TARGET_CMD[*]}"
    echo "[Info] limit / 時限: $SYSTEM_TRACE_LIMIT"
    echo "[Info] output / 輸出: $TRACE_OUT"
    # xctrace keeps writing the bundle after the target exits; a bundle read
    # before that finishes fails to export with "Document Missing Template
    # Error". Wait for the save line rather than for the process, so the failure
    # is visible here instead of surfacing later as a corrupt export.
    # xctrace 在目標行程結束後仍會繼續寫入 bundle；在寫入完成前讀取，匯出會以
    # 「Document Missing Template Error」失敗。故等待儲存訊息而非等待行程結束，
    # 使失敗在此處即可見，而非稍後以損毀的匯出檔呈現。
    rec_log="${TRACE_OUT%.trace}.record.log"
    xcrun xctrace record --template "System Trace" \
        --time-limit "$SYSTEM_TRACE_LIMIT" \
        --output "$TRACE_OUT" \
        --launch -- "${TARGET_CMD[@]}" 2>&1 | tee "$rec_log"

    if ! grep -q "Output file saved" "$rec_log"; then
        echo "[Error] xctrace did not finish saving the bundle / 未完成寫入" >&2
        echo "        see $rec_log" >&2
        exit 1
    fi
    echo "[OK] recorded / 已錄製: $TRACE_OUT"
fi

# ---------------------------------------------------------------------
if (( DO_PARSE )); then
    typeset -a BUNDLES
    BUNDLES=("$SYSTEM_TRACE_DIR"/*.trace(N))
    (( ${#BUNDLES} )) || { echo "[Error] no .trace bundles in $SYSTEM_TRACE_DIR" >&2; exit 1 }
    echo "[Info] parsing / 解析: ${#BUNDLES} bundle(s) -> $SUMMARY_CSV"

    for bundle in "${BUNDLES[@]}"; do
        xcrun xctrace export --input "$bundle" \
            --xpath '/trace-toc/run[@number="1"]/data/table[@schema="thread-state"]' \
            > "${bundle%.trace}.thread-state.xml" 2>/dev/null \
            || { echo "[Warn] export failed for ${bundle:t}" >&2; continue }
    done

    python3 helper/system_trace_parse.py "$SYSTEM_TRACE_DIR" "$SUMMARY_CSV"
fi

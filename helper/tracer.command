#!/bin/zsh
set -u

cd /Users/raliclo/proj/lzfse2 || exit 1

TRACE_DIR="./trace"
PROFILE_BIN="$TRACE_DIR/lzfse-profile"
LOG_OUT="$TRACE_DIR/tracer.log"
STATUS_OUT="$TRACE_DIR/tracer_status.txt"
PACKAGE_COUNT_FILE="$TRACE_DIR/.trace_package_count"
TRACE_TIMEOUT_SECONDS="${TRACE_TIMEOUT_SECONDS:-300}"
# 60s is enough: the Time Profiler samples periodically, so a minute already
# yields a representative symbol distribution, and the trace dominated the
# round's wall time at 5m. Raise it only when a specific run needs the tail.
# 60 秒已足夠：Time Profiler 是週期取樣，一分鐘即可得到具代表性的符號分布，而
# 5 分鐘會讓 trace 主導整輪耗時。唯有特定執行需要尾段時才調高。
XCTRACE_TIME_LIMIT="${XCTRACE_TIME_LIMIT:-60s}"

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
    # --time-limit stops recording but xctrace waits for the child to exit.
    # When --target-stdin is used, xctrace closes the pipe after time-limit but
    # the child may still be blocked, causing an infinite mutual wait.
    # Fix: run in background and kill the whole process group after hard deadline.
    # --time-limit 停止錄製，但 xctrace 仍會等待子行程結束。
    # 使用 --target-stdin 時，xctrace 在 time-limit 後關閉 pipe，
    # 但子行程可能仍在阻塞，導致雙方無限互等。
    # 修正：背景執行並在硬性截止後強制終止整個 process group。
    xcrun xctrace record --time-limit "$XCTRACE_TIME_LIMIT" "$@" &
    local xctrace_pid=$!
    local hard_deadline=$((start_seconds + TRACE_TIMEOUT_SECONDS + 30))
    while [[ $SECONDS -lt $hard_deadline ]]; do
        kill -0 "$xctrace_pid" 2>/dev/null || break
        sleep 2
    done
    # Use ps -o state= instead of kill -0 to distinguish a live process from a
    # zombie: kill -0 returns 0 for zombies too, causing false timeouts.
    # Guard pgid against the shell's own PGID, which xctrace inherits when job
    # control is inactive (non-interactive invocation, no set -m).
    # 用 ps -o state= 區分真正存活的行程與 zombie（kill -0 對 zombie 也回傳 0，
    # 會造成誤判 timeout）。同時防止 job control 未啟用時 xctrace 繼承 shell 的
    # PGID，避免誤殺 shell 自身的 process group。
    local proc_state
    proc_state=$(ps -o state= -p "$xctrace_pid" 2>/dev/null | tr -d ' ')
    if [[ -n "$proc_state" && "$proc_state" != "Z" ]]; then
        local pgid my_pgid
        pgid=$(ps -o pgid= -p "$xctrace_pid" 2>/dev/null | tr -d ' ')
        my_pgid=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
        if [[ -n "$pgid" && "$pgid" != "0" && "$pgid" != "$my_pgid" ]]; then
            kill -TERM -"$pgid" 2>/dev/null || sudo kill -TERM -"$pgid" 2>/dev/null
            sleep 3
            kill -KILL -"$pgid" 2>/dev/null || sudo kill -KILL -"$pgid" 2>/dev/null
        fi
        # Bounded wait: avoids blocking forever if SIGKILL is deferred in kernel
        # (e.g. xctrace stuck in an uninterruptible dtrace flush wait on macOS).
        # 有界等待：避免 SIGKILL 被 kernel 延遲時永久阻塞
        # （例如 xctrace 卡在 macOS uninterruptible dtrace flush wait）。
        local giveup=$((SECONDS + 5))
        while [[ $SECONDS -lt $giveup ]] && kill -0 "$xctrace_pid" 2>/dev/null; do
            sleep 1
        done
        disown "$xctrace_pid" 2>/dev/null
        return 124
    fi
    wait "$xctrace_pid"
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
    # Published for the caller: on a non-zero xctrace exit it has to decide
    # whether a usable recording was still produced. / 供呼叫端使用：xctrace
    # 以非零結束時，呼叫端需據此判斷是否仍產出了可用的紀錄。
    LAST_TRACE_OUT="$trace_out"
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
        optimal3)
            run_xctrace_record \
                --template "Time Profiler" \
                --output "$trace_out" \
                --target-stdin "$tar_input" \
                --launch -- "$PROFILE_BIN" -encode -si -o "$compressed_out" -algo other3 -optimal3 "${n_args[@]}"
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
    swiftc -O -g -D PROFILING lzfse-cli.swift -o "$PROFILE_BIN"

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
                elif [[ -d "${LAST_TRACE_OUT:-}" ]] \
                     && xcrun xctrace export --input "$LAST_TRACE_OUT" --toc >/dev/null 2>&1; then
                    # xctrace exits non-zero when --time-limit cuts the target
                    # short, even though the recording is complete and saved.
                    # That is the normal outcome here, not an error: the limit
                    # exists precisely because the Time Profiler samples
                    # periodically and a minute is already representative. The
                    # recording is what matters, so verify it can be parsed and
                    # accept it. Observed with claw-code/other3 -n 4, which
                    # returned 54 alongside a 4.3 MB trace that exported fine --
                    # and aborted a round that had run for 37 minutes.
                    # 當 --time-limit 提前中止目標程序時，xctrace 會以非零結束，即使
                    # 錄製已完整儲存。在此那是正常結果而非錯誤：設定時間上限的理由，
                    # 正是 Time Profiler 採週期取樣、一分鐘已具代表性。真正重要的是
                    # 錄製本身，故改為驗證其可否解析，可解析即接受。實例：
                    # claw-code/other3 -n 4 回傳 54，但其 4.3 MB 的 trace 可正常匯出
                    # ——卻中止了一輪已執行 37 分鐘的量測。
                    echo "TRACE_OK ${dataset} ${algo} (rc ${rc}, recording verified) $(date +%H:%M:%S)" >> "$STATUS_OUT"
                    traceRoundStatus "TRACE_DONE ${dataset} ${algo} (rc ${rc}, verified)"
                else
                    echo "TRACE_FAILED ${dataset} ${algo} ${rc} $(date +%H:%M:%S)" >> "$STATUS_OUT"
                    traceRoundStatus "TRACE_FAILED ${dataset} ${algo} ${rc}"
                    exit "$rc"
                fi
            fi
        done

        trace_n=""
        for trace_n in "${LZFSE_TRACE_N_SWEEP[@]}"; do
            for algo in other3 optimal3 apple bvx3 lazy2 optimal; do
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
                    elif [[ -d "${LAST_TRACE_OUT:-}" ]] \
                         && xcrun xctrace export --input "$LAST_TRACE_OUT" --toc >/dev/null 2>&1; then
                        # Same as the no--n branch above: --time-limit cutting the
                        # target short makes xctrace exit non-zero even though the
                        # recording completed. This is the branch the -n traces take,
                        # and the one that actually aborted a 37-minute round on
                        # claw-code/other3 -n 4 (rc 54, 4.3 MB trace, exported fine).
                        # 與上方無 -n 分支相同：--time-limit 提前中止目標程序，會讓
                        # xctrace 以非零結束，即使錄製已完成。帶 -n 的 trace 走的正是
                        # 本分支，也正是它中止了一輪已跑 37 分鐘的量測
                        # （claw-code/other3 -n 4，rc 54，4.3 MB trace，匯出正常）。
                        echo "TRACE_OK ${dataset} ${algo} -n ${trace_n} (rc ${rc}, recording verified) $(date +%H:%M:%S)" >> "$STATUS_OUT"
                        traceRoundStatus "TRACE_DONE ${dataset} ${algo} -n ${trace_n} (rc ${rc}, verified)"
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

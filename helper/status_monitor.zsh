#!/bin/zsh
# =====================================================================
# status_monitor.zsh -- 過濾 round_status.txt，只印出值得動作的行。
# status_monitor.zsh -- filter round_status.txt down to the lines worth acting on.
#
# 用法 / Usage:
#   helper/status_monitor.zsh              # 跟隨（tail -f），供 Monitor 使用
#   helper/status_monitor.zsh --once       # 掃描既有內容後結束，供跑完後驗收
#   helper/status_monitor.zsh --verdict    # 只印判定與計數，不印逐行
#   helper/status_monitor.zsh -f <file>    # 指定其他狀態檔
#
# 為何需要它 / Why this exists:
#
# 整輪需 9-10 小時，而「沒有訊息」與「還在跑」看起來完全一樣。守候的過濾條件因此必須
# 涵蓋每一種終局，不只成功那一種——只盯成功標記的守候，會在崩潰、卡死、或非預期退出時
# 保持沉默，而沉默讀起來就像一切正常。
# A round takes 9-10 hours and silence is indistinguishable from progress, so the filter
# has to cover every terminal state rather than only the happy path.
#
# **判定依各步驟自己寫出的 *_DONE 標記，不只看 BENCH_DONE。**
#
# 自 `a441b9d`（2026-09-04）起，run_round.command 的 `rc=$?` 緊接在 benchmark2.zsh 之後，
# BENCH_DONE／BENCH_FAILED 與離開碼已反映 benchmark2.zsh 的真實狀態。在那之前 `rc=$?` 位在
# `rm -f .bench_env` 之後，BENCH_DONE 無條件寫出——R49、R50 的 BENCH_DONE 不構成證據。
#
# 即使修好了，BENCH_DONE 也只說「benchmark2.zsh 以 0 結束」，不說「每一步都跑了」：一個被
# 跳過的步驟同樣以 0 結束（trace_analysis 在沒有新 trace 時會沿用上一輪結果並回 0）。所以
# 判定仍以下方 REQUIRED 的逐步標記為準，BENCH_DONE 只是其中一項佐證。
#
# Judge by the per-step *_DONE markers, not by BENCH_DONE alone. Since a441b9d (2026-09-04)
# BENCH_DONE and the exit status reflect benchmark2.zsh's real status; before that they were
# unconditional. Even now BENCH_DONE only says benchmark2.zsh exited zero, not that every step
# ran -- a skipped step exits zero too. REQUIRED below is the list that decides.
# =====================================================================
set -uo pipefail

STATUS="${LZFSE_ROUND_STATUS:-${0:A:h:h}/round_status.txt}"
MODE=follow
while (( $# )); do
    case "$1" in
        --once)    MODE=once ;;
        --verdict) MODE=verdict ;;
        -f)        shift; STATUS="${1:?-f needs a path}" ;;
        -h|--help) sed -n '2,30p' "${0:A}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) print -ru2 -- "unknown option: $1"; exit 2 ;;
    esac
    shift
done

# 失敗訊號。寧可寬也不要窄：多一點雜訊，好過漏掉一次崩潰。
# Failure signals. Wider is better than narrower: some noise beats missing a crash.
FAILURE='LZ4BENCH_FAILED|COMPARED_WITH_TGZ_FAILED|MEMPROBE_FAILED|TRACER_FAILED'
FAILURE+='|POWER_BENCHMARK_FAILED|BEST_POINTS_ANALYSIS_FAILED|BENCHMARK_RESULT_REBUILD_FAILED'
FAILURE+='|POWER_SUMMARY_INTEGRATE_FAILED|COMPARISON_FAILED|MD_TRANSLATE_FAILED'
FAILURE+='|SWIFT_TAR_[A-Z_]*FAILED|BENCH_FAILED|Traceback|password is required'
FAILURE+='|Benchmark aborted|Win_result_invalid|\[FAIL\]'

# 進度訊號。兩種形狀都要涵蓋，因為 *_DONE 的後面不一定是時間戳：
#     TRACER_DONE 22:25:55                  → DONE 後接時間
#     LZ4BENCH_DONE claw-code-n40 13:29:16  → DONE 後接資料集名稱
# 第一版只寫了 `DONE [0-9]`，於是六個資料集的完成通知在一次 9 小時的執行中全部被吃掉，
# 而守候看起來像是「一切正常地安靜」——那正是本檔開頭所說、要避免的那種沉默。
# Two shapes, because what follows *_DONE is not always a timestamp. The first version
# matched only the timestamp form and swallowed every dataset completion across a nine-hour
# run, leaving a silence that reads exactly like health.
PROGRESS='_DONE( |$)'

PATTERN="${FAILURE}|${PROGRESS}"

# 一輪要算完成，這些標記必須全部出現。BENCH_DONE 不在其中：它只代表 benchmark2.zsh 以 0
# 結束，不代表每一步都跑了（見檔頭）。TRACER_DONE 也不在這裡——tracer 只在
# `-power-test`／`-full` 時執行，是否必要由 verdict() 依 round_status.txt 第一行的
# `MODE … power_test=` 決定。先前無條件要求它，使每一個未帶該旗標的輪次都被判成「未完成」。
# A round is complete only when all of these appear. BENCH_DONE is absent because it only says
# benchmark2.zsh exited zero. TRACER_DONE is added by verdict() only when the MODE line says
# power_test=1; requiring it unconditionally marked every round without -power-test incomplete.
REQUIRED=(
    POWER_BENCHMARK_DONE
    TRACE_ANALYSIS_DONE
    CPU_CALL_TREE_ANALYSIS_DONE
    BENCHMARK_RESULT_REBUILD_DONE
    POWER_SUMMARY_INTEGRATE_DONE
    BEST_POINTS_ANALYSIS_DONE
    COMPARISON_DONE
)

verdict() {
    local fails ok_cmp bad_cmp missing=()
    # `grep -c` 在零命中時已經印出 0，而退出碼是 1。先前寫成 `|| print 0` 的後果是
    # 「0」被印兩次，變數成為 "0\n0"，其後的算術以 bad math expression 失敗，判定於是
    # 落到「未完成」那一支——**一輪乾淨的執行被回報成失敗**。這正是本檔要防的那類錯誤，
    # 只是方向相反：不是把失敗說成成功，而是把成功說成失敗。兩者都讓判定失去意義。
    # `grep -c` prints 0 on no match and still exits 1, so `|| print 0` printed it twice
    # and the arithmetic below failed, sending a clean round to the "failed" branch. The
    # same class of defect this file exists to catch, only inverted.
    fails=$(grep -cE "$FAILURE" "$STATUS")
    ok_cmp=$(grep -c 'COMPARED_WITH_TGZ_OK' "$STATUS")
    bad_cmp=$(grep -c 'COMPARED_WITH_TGZ_FAILED' "$STATUS")

    # 本輪的模式，取自 run_round.command 寫的第一個 MODE 行（2026-08-13 `9830278` 起每輪都有）。
    # 沒有 MODE 行的舊 log 無從得知是否帶了 power test，故保守地仍要求 TRACER_DONE。
    # The round's mode, from the MODE line run_round.command writes. Logs older than 9830278
    # have none; for those TRACER_DONE stays required, the conservative choice.
    local mode_line swift_mode power_mode
    local -a required=($REQUIRED)
    mode_line=$(grep -m1 -E '^MODE ' "$STATUS" 2>/dev/null)
    swift_mode=${${mode_line##*swift_tar=}%% *}
    power_mode=${${mode_line##*power_test=}%% *}
    [[ -z $mode_line || $power_mode == 1 ]] && required=(TRACER_DONE $required)

    # 標記一律以行首錨定比對。標記後面接的是空白加時間或資料集名稱，所以 `^名稱( |$)` 就夠；
    # 不錨定的子字串比對會讓一個名稱的前綴或延伸（例如 `llama.cpp-n4` 對上 `llama.cpp-n40`）
    # 被當成命中——那正是 mistakes.md 第 10 條那一類「判別式太寬」。
    # Markers are matched anchored at the start of the line, followed by a space or the end:
    # an unanchored substring match lets a prefix or an extension of a name count as a hit.
    for m in $required; do
        grep -qE "^${m}( |\$)" "$STATUS" 2>/dev/null || missing+=($m)
    done

    print -- "-------------------------------------------------"
    print -- "  狀態檔 / status file : $STATUS"
    if [[ -n $mode_line ]]; then
        print -- "  模式 / mode           : swift_tar=$swift_mode power_test=$power_mode"
    else
        print -- "  模式 / mode           : （log 無 MODE 行，TRACER_DONE 仍列為必要 / no MODE line）"
    fi
    print -- "  失敗訊號 / failures   : $fails"
    print -- "  解壓比對 / extract cmp: OK $ok_cmp  FAILED $bad_cmp"
    if (( ${#missing} )); then
        print -- "  缺少的步驟 / missing  : ${missing[*]}"
    else
        print -- "  缺少的步驟 / missing  : 無 / none"
    fi
    print -- "-------------------------------------------------"
    # 模式不影響「完成與否」，但影響數字能不能與其他輪次比較，所以明講出來。
    # The mode does not decide completeness, but it decides comparability, so say so.
    [[ $swift_mode == 0 ]] && print -- "  注意：swift_tar=0，tar／tgz／zstd 走系統工具，MB/s 不可與 -full 輪次比較。" \
                           && print -- "  Note: swift_tar=0 -- system tar/gzip/zstd; MB/s not comparable with -full rounds."
    [[ $power_mode == 0 ]] && print -- "  注意：power_test=0，本輪未產生新 trace；trace／call-tree 分析沿用上一輪的結果。" \
                           && print -- "  Note: power_test=0 -- no new traces; trace analysis reuses the previous round's."
    if (( fails == 0 && bad_cmp == 0 && ${#missing} == 0 )); then
        print -- "  判定 / verdict: 完成且無失敗 / complete, no failures"
        return 0
    fi
    print -- "  判定 / verdict: 未完成或有失敗 / incomplete or failed"
    return 1
}

[[ -f "$STATUS" ]] || { print -ru2 -- "no status file at $STATUS"; exit 1 }

case "$MODE" in
    verdict) verdict ;;
    once)    grep -E "$PATTERN" "$STATUS"; verdict ;;
    follow)
        # --line-buffered 是必要的：少了它，grep 會把命中行留在自己的緩衝區裡，
        # 而守候的整個用途就是即時看到它們。
        # --line-buffered is required, or grep holds matches in its own buffer and the
        # whole point of watching is lost.
        tail -f "$STATUS" | grep -E --line-buffered "$PATTERN"
        ;;
esac

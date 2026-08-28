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
# **不要用 exit code 判定成敗。** run_round.command 的 `rc=$?` 位在 `rm -f .bench_env`
# 之後，而 `rm -f` 對不存在的檔案也回 0，故 BENCH_DONE 無條件寫出、BENCH_FAILED 那一支
# 永遠不可能執行、整輪永遠 exit 0。2026-08-27 有一輪的 benchmark2.zsh 因 sudo 完全沒跑
# （power 全空）卻回報成功，成因即在此。判定要依各步驟自己寫出的 *_DONE 標記——那些不受
# 該缺陷影響。此處的 REQUIRED 即為該清單。
# Do not judge a round by its exit code: run_round.command captures `rm -f`'s status
# rather than benchmark2.zsh's, so BENCH_DONE is unconditional and the round always exits
# zero. Judge by the per-step markers listed in REQUIRED below.
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

# 一輪要算完成，這些標記必須全部出現。BENCH_DONE 刻意不在其中——它無條件寫出。
# A round is complete only when all of these appear. BENCH_DONE is deliberately absent.
REQUIRED=(
    TRACER_DONE
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
    for m in $REQUIRED; do
        grep -q "$m" "$STATUS" 2>/dev/null || missing+=($m)
    done

    print -- "-------------------------------------------------"
    print -- "  狀態檔 / status file : $STATUS"
    print -- "  失敗訊號 / failures   : $fails"
    print -- "  解壓比對 / extract cmp: OK $ok_cmp  FAILED $bad_cmp"
    if (( ${#missing} )); then
        print -- "  缺少的步驟 / missing  : ${missing[*]}"
    else
        print -- "  缺少的步驟 / missing  : 無 / none"
    fi
    print -- "-------------------------------------------------"
    if (( fails == 0 && bad_cmp == 0 && ${#missing} == 0 )); then
        print -- "  判定 / verdict: 完成且無失敗 / complete, no failures"
        return 0
    fi
    print -- "  判定 / verdict: 未完成或有失敗 / incomplete or failed"
    print -- "  注意：run_round.command 的 exit code 恆為 0，不可用於判定。"
    print -- "  Note: run_round.command always exits 0; do not judge by it."
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

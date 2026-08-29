#!/bin/zsh
# =====================================================================
# run_checked.zsh -- 跑一個指令，並且**不可能**用過濾器把它的失敗藏掉。
# run_checked.zsh -- run a command in a way that cannot filter its failure away.
#
# 這支腳本針對 mistakes.md 第 1 條：「自己的過濾器把失敗藏起來」，總 4 次、分布 3 天，
# 是計數表中**唯一跨日重複**的一條——也就是唯一有證據說明「規則寫在檔案裡不夠」的一條。
#
# 四次的形式各不相同，這正是它每次都繞過去的原因：
#
#     sudo -n kill … 2>/dev/null              藏掉 "a password is required"
#     test.zsh | grep -E 'PASS|通過' | tail -1  取到較早的成功行，藏掉結尾的 FAIL
#     build | grep -cE ': (error|warning):'    藏掉 "permission denied"，因為那不是
#                                              編譯器診斷的樣式
#     grep -c … || print 0                     把一輪乾淨的執行判定為失敗
#
# **共同結構**：過濾器是為了讓輸出好讀而寫的，而它的樣式只涵蓋預期中的訊息。非預期的
# 訊息不符合樣式，於是消失——而消失與「沒有問題」在畫面上完全一樣。
#
# 因此本腳本的核心設計是：**摘要用的樣式是附加的，失敗檢查是強制的。** 你可以用 --want
# 指定想看的行，但那不會取代失敗掃描；兩者並存，且失敗掃描永遠先跑。
#
# This targets mistakes.md entry 1 -- four occurrences across three days, the only entry
# with days_seen > 1 and so the only one with evidence that a rule in a file is not enough.
# Each occurrence wore a different disguise, which is how it kept getting through. The
# design point: the summary pattern is additive and the failure scan is mandatory. --want
# never replaces the scan.
#
# 用法 / Usage:
#   helper/run_checked.zsh [選項] -- <指令...>
#
#   --want PATTERN    另外印出符合此 ERE 的行（可重複）。這是「摘要」，不是「判定」。
#                     Also print lines matching this ERE. A summary, not a verdict.
#   --allow PATTERN   把符合此 ERE 的行排除於失敗掃描之外（可重複）。用於已知無害的
#                     訊息，且**必須附理由**——見 --why。
#                     Exempt matching lines from the failure scan. Requires --why.
#   --why TEXT        說明為何需要 --allow。缺少時 --allow 會被拒絕。
#                     Justification for --allow; without it --allow is refused.
#   --log PATH        完整輸出另存一份，預設寫入暫存檔並於結束時刪除。
#                     Keep the full output; otherwise it goes to a temp file.
#   --quiet           成功時不印摘要（失敗時一律印）。
#                     Suppress the summary on success; failures always print.
#   -h, --help        顯示此說明。
#
# 結束碼 / Exit status:
#   指令本身的結束碼；若為 0 但掃描到失敗樣式，則回傳 1。
#   The command's own status, or 1 if it exited zero while the scan found a failure.
# =====================================================================
set -uo pipefail

typeset -a WANT ALLOW CMD
WHY=""
LOG=""
QUIET=0

while (( $# )); do
    case "$1" in
        --want)  shift; WANT+=("${1:?--want needs a pattern}") ;;
        --allow) shift; ALLOW+=("${1:?--allow needs a pattern}") ;;
        --why)   shift; WHY="${1:?--why needs text}" ;;
        --log)   shift; LOG="${1:?--log needs a path}" ;;
        --quiet) QUIET=1 ;;
        -h|--help) sed -n '2,50p' "${0:A}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --)      shift; CMD=("$@"); break ;;
        *) print -ru2 -- "unknown option: $1 (use -- before the command)"; exit 2 ;;
    esac
    shift
done

(( ${#CMD} )) || { print -ru2 -- "no command given; use: run_checked.zsh [opts] -- <cmd...>"; exit 2 }
if (( ${#ALLOW} )) && [[ -z "$WHY" ]]; then
    print -ru2 -- "--allow requires --why: an exemption without a reason is the mistake this file exists to stop"
    print -ru2 -- "--allow 需要 --why：沒有理由的豁免，正是本檔要防的那個錯誤"
    exit 2
fi

# shell 層級的失敗。這份清單是**強制**的，不受 --want 影響。
# 每一項都在這棵樹上實際出現過，或屬於同一類（指令跑不起來、檔案動不了、權限不足）。
# Shell-level failures. This list is mandatory and unaffected by --want. Each has actually
# appeared here or belongs to the same class: the command could not run, the file could not
# be touched, permission was refused.
FAILPAT='permission denied|Permission denied|Operation not permitted'
FAILPAT+='|command not found|No such file or directory|no such file or directory'
FAILPAT+='|a password is required|a terminal is required'
FAILPAT+='|cannot open|cannot create|cannot write|can'"'"'t write'
FAILPAT+='|Traceback \(most recent call last\)|bad math expression|parameter not set'
FAILPAT+='|Segmentation fault|Abort trap|Killed: 9'
FAILPAT+='|error:|Error:|fatal:|FAILED|\[FAIL\]'
# 本檔第一版漏掉了 `失敗 / FAIL: 2 check(s)`——那是本樹測試腳本的標準失敗行，卻不符合
# `FAILED` 或 `[FAIL]`。**同一個錯誤的第五種偽裝，出現在為了防它而寫的東西裡。**
# 計數必須是「非零」而非「存在」：摘要行 `PASS: 139  FAIL: 0` 也含 FAIL:，若比對存在
# 就會把每一次成功都判成失敗——那是 mistakes.md 第 1 條第 4 例的反向形式。
# The first version of this file missed `失敗 / FAIL: 2 check(s)`, the standard failure
# line of this tree's own tests: a fifth disguise, inside the thing written to stop it.
# The count must be non-zero rather than present, or the summary line `PASS: 139 FAIL: 0`
# would mark every success as a failure -- entry 1's fourth case, inverted.
FAILPAT+='|FAIL: *[1-9]|失敗 */ *FAIL|失敗: *[1-9]'

OWNLOG=0
if [[ -z "$LOG" ]]; then LOG=$(mktemp); OWNLOG=1; fi
cleanup() { (( OWNLOG )) && rm -f "$LOG"; }
trap cleanup EXIT INT TERM

# stdout 與 stderr 合流寫入檔案，而非管線——管線加上 `2>&1 >…` 在 zsh 的 MULTIOS 之下
# 會讓 stdout 同時流向兩處（mistakes.md 第 3 條）。寫檔沒有這個問題。
# Both streams into a file rather than a pipe: `2>&1 >…` into a pipe leaks under zsh's
# MULTIOS (mistakes.md entry 3). A file has no such ambiguity.
"${CMD[@]}" >"$LOG" 2>&1
RC=$?

# 掃描。--allow 的樣式先剔除，其餘一律計入。
# Scan. --allow removes lines first; everything else counts.
scan() {
    if (( ${#ALLOW} )); then
        local f="$LOG.f"; cp "$LOG" "$f"
        local p
        for p in $ALLOW; do grep -vE -- "$p" "$f" > "$f.n" 2>/dev/null && mv "$f.n" "$f"; done
        grep -nE -- "$FAILPAT" "$f"; local r=$?; rm -f "$f" "$f.n"; return $r
    fi
    grep -nE -- "$FAILPAT" "$LOG"
}

HITS=$(scan)
NHITS=$( [[ -n "$HITS" ]] && print -- "$HITS" | wc -l | tr -d ' ' || print 0 )

if (( RC != 0 || NHITS > 0 )); then
    print -ru2 -- "=============================================================="
    print -ru2 -- "run_checked: FAILED / 失敗"
    print -ru2 -- "  command : ${CMD[*]}"
    print -ru2 -- "  exit    : $RC"
    print -ru2 -- "  failures: $NHITS 行符合 shell 層級的失敗樣式 / lines matched"
    if (( RC == 0 && NHITS > 0 )); then
        print -ru2 -- "  注意：指令以 0 結束，但輸出中有失敗訊號——正是 mistakes.md 第 1 條的形狀。"
        print -ru2 -- "  Note: exited zero with failure signals present -- entry 1's exact shape."
    fi
    (( ${#ALLOW} )) && print -ru2 -- "  allow   : ${ALLOW[*]}  (why: $WHY)"
    print -ru2 -- "--- 命中的行 / matched lines ---"
    print -ru2 -- "$HITS" | head -20
    print -ru2 -- "--- 完整輸出末 20 行 / last 20 lines ---"
    tail -20 "$LOG" >&2
    print -ru2 -- "=============================================================="
    (( RC != 0 )) && exit $RC
    exit 1
fi

if (( ! QUIET )); then
    if (( ${#WANT} )); then
        local p
        for p in $WANT; do grep -E -- "$p" "$LOG"; done
    else
        cat "$LOG"
    fi
fi
exit 0

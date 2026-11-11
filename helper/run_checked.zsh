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
#   --timeout SECONDS 整體時間上限，預設 1800；到時以 GNU timeout 終止整個程序群組，
#                     結束碼 124。0 表示不限時（須自行確保有人看著）。
#                     Wall-clock limit, default 1800; on expiry GNU timeout kills the
#                     process group and the status is 124. 0 disables it.
#   -h, --help        顯示此說明。
#
# 為何預設限時：2026-11-03 一次 `run_checked.zsh -- zsh test/run_test.zsh` 在背景啟動後，
# 啟動它的程序已結束，它仍以孤兒身分跑了 30 分鐘以上，沒有人等它的結果，只在消耗 CPU
# 並不斷彈出終端分頁。沒有上限的背景執行，等於沒有擁有者的執行。
# Why a default limit: on 2026-11-03 a background run of this script outlived its
# launcher and kept running as an orphan for 30+ minutes -- nobody waiting on the
# result, only CPU and popping terminal tabs. A background run with no limit has no owner.
#
# 結束碼 / Exit status:
#   指令本身的結束碼；若為 0 但掃描到失敗樣式，則回傳 1；逾時為 124；指令忽略 SIGTERM、
#   15 秒後被 SIGKILL 時為 137。
#   The command's own status, or 1 if it exited zero while the scan found a failure;
#   124 on timeout; 137 when the command ignored SIGTERM and was killed 15 s later.
#   更正 2026-11-11：原本只寫「逾時為 124」，137 的情況沒有說明。
#   CORRECTED 2026-11-11: this said only "124 on timeout"; the 137 case was undocumented.
#
# 限制 / Limits:
#   - 未加 --foreground：指令跑在背景程序群組，從終端機讀輸入的指令（互動提示、要密碼的
#     sudo）依 GNU timeout 的文件會被 SIGTTIN 停住，直到逾時。要互動的指令請用 --timeout 0。
#     No --foreground: the command runs in a background process group, so per GNU timeout's
#     documentation one that reads the terminal (a prompt, sudo asking for a password) stops
#     on SIGTTIN until the limit. Use --timeout 0 for an interactive command.
#   - 「終止整個程序群組」在 macOS／Linux 成立；在 Windows 的 MSYS zsh 下，原生 Windows 子程序
#     不一定隨群組一起被終止。
#     Killing the process group holds on macOS/Linux; under MSYS zsh on Windows, native
#     Windows child processes may outlive it.
# =====================================================================
set -uo pipefail

typeset -a WANT ALLOW CMD
WHY=""
LOG=""
QUIET=0
TIMEOUT=1800

while (( $# )); do
    case "$1" in
        --timeout) shift; TIMEOUT="${1:?--timeout needs seconds}"
                   [[ "$TIMEOUT" == <-> ]] || { print -ru2 -- "--timeout needs a whole number of seconds"; exit 2 } ;;
        --want)  shift; WANT+=("${1:?--want needs a pattern}") ;;
        --allow) shift; ALLOW+=("${1:?--allow needs a pattern}") ;;
        --why)   shift; WHY="${1:?--why needs text}" ;;
        --log)   shift; LOG="${1:?--log needs a path}" ;;
        --quiet) QUIET=1 ;;
        -h|--help) sed -n '2,74p' "${0:A}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
# macOS 預設沒有 GNU timeout；Homebrew coreutils 提供 gtimeout。兩者皆無時照跑但明說未限時，
# 不讓「沒有限時工具」變成「指令跑不起來」。
# macOS has no GNU timeout by default (Homebrew coreutils ships gtimeout). With neither,
# run unlimited and say so, rather than turning a missing tool into a failed command.
TIMEOUT_CMD=""
if (( TIMEOUT > 0 )); then
    # whence 是內建；$+commands 需要 zsh/parameter 模組，模組載不到時會在 set -u 下出錯。
    # whence is a builtin; $+commands needs zsh/parameter and errors under set -u without it.
    if whence -p timeout >/dev/null; then TIMEOUT_CMD=timeout
    elif whence -p gtimeout >/dev/null; then TIMEOUT_CMD=gtimeout
    else print -ru2 -- "run_checked: no timeout/gtimeout found; running WITHOUT the ${TIMEOUT}s limit / 找不到 timeout，本次未限時"
    fi
fi
# 逾時以「經過時間」判定，不只看結束碼：指令自己以 124 結束時原本也被報成逾時（2026-11-11 實測：
# `-- zsh -c 'exit 124'` 立刻結束，卻寫下 TIMED OUT after 60s）；而忽略 SIGTERM 的指令在 --kill-after
# 之後被 SIGKILL，timeout 回傳的是 137 而非 124，原本不寫任何逾時說明（同日實測，2+15 秒後 rc=137）。
# Timeout is decided by elapsed time, not by the status alone: a command that itself exited 124 was
# reported as timed out (measured 2026-11-11: `-- zsh -c 'exit 124'` returned at once and the log said
# TIMED OUT after 60s), and a command ignoring SIGTERM is SIGKILLed after --kill-after, where timeout
# returns 137, not 124, and no note was written (same day: rc=137 after 2+15 s).
typeset -F SECONDS
START=$SECONDS
if [[ -n "$TIMEOUT_CMD" ]]; then
    "$TIMEOUT_CMD" --kill-after=15 "$TIMEOUT" "${CMD[@]}" >"$LOG" 2>&1
else
    "${CMD[@]}" >"$LOG" 2>&1
fi
RC=$?
ELAPSED=$(( SECONDS - START ))
if [[ -n "$TIMEOUT_CMD" ]] && (( ELAPSED >= TIMEOUT )); then
    if (( RC == 124 )); then
        print -r -- "run_checked: TIMED OUT after ${TIMEOUT}s / 逾時，已終止 -- FAILED" >>"$LOG"
    elif (( RC == 137 )); then
        print -r -- "run_checked: TIMED OUT after ${TIMEOUT}s; SIGTERM was ignored, SIGKILL 15s later / 逾時；SIGTERM 被忽略，15 秒後以 SIGKILL 終止 -- FAILED" >>"$LOG"
    fi
fi

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

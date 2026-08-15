#!/bin/zsh
# =====================================================================
# claude_test_sample_script.zsh -- how to launch a full round unattended.
# claude_test_sample_script.zsh -- 完整一輪的無人值守啟動範本。
#
# `run_round.command -full` (= -swift_tar -power-test) is the only combination
# that collects swift_tar figures and fresh traces in one round, so both share
# the same machine state and thermal history. It takes 1-2 hours. Three things
# can ruin that time, and this script checks all three before starting.
# `run_round.command -full`（即 -swift_tar -power-test）是唯一能在同一輪內同時
# 取得 swift_tar 數據與新 trace 的組合，兩者因而共用相同的機器狀態與熱度條件。
# 整輪需 1-2 小時。有三件事會讓這段時間白費，本腳本在開跑前逐一檢查。
#
#   1. sudo -- run_round.command:134 runs `sudo ./benchmark2.zsh` AFTER
#      benchmark.zsh, which alone takes ~38 minutes. The sudo timestamp lasts 5
#      minutes by default, so by then it has long expired and the round stops
#      dead waiting for a password. It does not fail; it waits forever. The
#      keep-alive loop below refreshes the timestamp every 50 s.
#      sudo -- run_round.command:134 的 `sudo ./benchmark2.zsh` 位於 benchmark.zsh
#      「之後」，而後者本身就要約 38 分鐘。sudo timestamp 預設僅 5 分鐘，屆時早已
#      過期，整輪會停在該處等待密碼——它不會失敗，而是無限等待。下方的 keep-alive
#      迴圈每 50 秒刷新一次 timestamp。
#
#   2. Sleep -- a sleeping machine ends the round. This box already runs
#      caffeinate via a LaunchAgent (helper/setup_launchagents.command), so this
#      is normally satisfied; the check is here because a round that dies at
#      minute 50 costs more than one line of verification.
#      睡眠 -- 機器睡著即中斷整輪。本機已由 LaunchAgent 常駐 caffeinate
#      （helper/setup_launchagents.command），通常已滿足；此處仍檢查，因為在第 50
#      分鐘掛掉的代價，遠高於多做這一行驗證。
#
#   3. Disk -- benchmark.zsh calls diskcheck before every -n sweep and aborts
#      below 20 GB. Failing here is safe but wastes whatever has already run.
#      磁碟 -- benchmark.zsh 在每次 -n 掃描前呼叫 diskcheck，低於 20 GB 即中止。
#      在此失敗是安全的，但已跑完的部分就白費了。
#
# Usage / 用法:
#   ./claude_test_sample_script.zsh              # foreground, recommended / 前景，建議
#   ./claude_test_sample_script.zsh --detach     # survives closing the terminal / 可關閉終端
#   ./claude_test_sample_script.zsh --check      # run the checks only / 僅執行檢查
#
# Foreground is the default on purpose. If the keep-alive ever fails, a
# foreground round stops at a visible password prompt you can answer; a detached
# one just hangs. Leaving the terminal open also keeps the machine's load
# steady, which matters because this round records power figures.
# 預設為前景是刻意的。萬一 keep-alive 失效，前景執行會停在看得見的密碼提示、
# 可當場輸入；背景執行則只是靜靜卡住。保持終端開啟也讓機器負載穩定，而這一輪要
# 記錄功率數字，負載變動會污染讀數。
# =====================================================================
set -uo pipefail

HERE="${0:A:h}"
cd "$HERE" || exit 1

MODE="foreground"
case "${1:-}" in
    --detach) MODE="detach" ;;
    --check)  MODE="check"  ;;
    "")       ;;
    *) print -ru2 -- "unknown option: $1 (use --detach or --check)"; exit 2 ;;
esac

ok=0
say()  { print -- "$@" }
good() { print -- "  [OK]   $*" }
warn() { print -- "  [WARN] $*"; ok=1 }
bad()  { print -- "  [FAIL] $*"; ok=1 }

say "== Preflight / 執行前檢查 =="

# --- 1. caffeinate ---------------------------------------------------
# `pmset -g` reports who is holding sleep off, so this checks the effect rather
# than merely whether a caffeinate process exists.
# `pmset -g` 會列出是誰在阻止睡眠，故此處檢查的是「效果」，而非僅檢查 caffeinate
# 程序是否存在。
sleep_line="$(pmset -g 2>/dev/null | grep -E '^\s*sleep\s' | head -1)"
if [[ "$sleep_line" == *"sleep prevented by"* ]]; then
    good "sleep is held off:${sleep_line#*prevented by}"
elif [[ "$sleep_line" =~ 'sleep[[:space:]]+0' ]]; then
    good "system sleep disabled (sleep 0) / 系統睡眠已停用"
else
    warn "nothing is holding sleep off / 無任何程序阻止睡眠"
    say  "         run: caffeinate -dimsu & / 或執行 helper/setup_launchagents.command"
fi

# --- 2. disk ---------------------------------------------------------
# Same 20 GB threshold as diskcheck() in zshrc.zsh, checked up front so a
# shortfall is known now rather than 50 minutes in.
# 與 zshrc.zsh 中 diskcheck() 相同的 20 GB 門檻，提前檢查，讓空間不足在此刻就浮現，
# 而非在第 50 分鐘才發現。
avail_gb=$(( $(df -k . | tail -1 | awk '{print $4}') / 1024 / 1024 ))
if (( avail_gb >= 20 )); then
    good "disk ${avail_gb} GB free (diskcheck needs 20) / 磁碟可用 ${avail_gb} GB"
else
    bad  "disk ${avail_gb} GB free, diskcheck needs 20 / 磁碟僅 ${avail_gb} GB，需 20 GB"
    say  "         reclaim: /private/var/folders caches, or trace/ if you agree to lose it"
fi

# --- 3. corpora ------------------------------------------------------
for d in claw-code llama.cpp; do
    [[ -d "$d" ]] && good "corpus $d present / 語料 $d 存在" \
                  || bad  "corpus $d missing / 找不到語料 $d"
done

# --- 4. repos clean --------------------------------------------------
# A round rewrites committed result files. Starting from a dirty tree makes the
# resulting diff impossible to attribute.
# 整輪會改寫已入版的結果檔。若從有未提交改動的工作區開始，產生的 diff 將無從歸因。
if [[ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    good "lzfse2 tree clean / 工作區乾淨"
else
    warn "lzfse2 has uncommitted changes / 有未提交改動"
    git status --short --untracked-files=no | sed 's/^/           /'
fi

say ""
(( ok == 0 )) || say "== Some checks did not pass; read them before continuing / 有檢查未通過 =="
[[ "$MODE" == "check" ]] && exit $ok

# --- sudo ------------------------------------------------------------
# `sudo -v` only refreshes the timestamp. It is interactive and therefore must
# happen here, before any detaching: nohup closes stdin and sudo could not
# prompt. There is no NOPASSWD rule on this machine -- verified 2026-08-15 --
# so the keep-alive is not optional.
# `sudo -v` 僅更新 timestamp。它需要互動，因此必須在此、在任何背景化之前完成：
# nohup 會關閉 stdin，sudo 屆時無從提示。本機並無 NOPASSWD 設定（2026-08-15 確認），
# 故 keep-alive 並非可選項。
say "== sudo =="
say "  run_round.command needs sudo partway through (benchmark2.zsh, gitOwner.sh)."
say "  run_round.command 中途需要 sudo（benchmark2.zsh、gitOwner.sh）。"
# Try non-interactively first. `sudo -v` insists on a tty even when the timestamp
# is already valid, because its job is to re-validate and it prepares to prompt;
# `sudo -n` just succeeds if a valid timestamp exists. Without this order the
# script refuses to start under any tty-less caller -- cron, a CI runner, an
# agent shell -- even though sudo would have worked perfectly.
# 先嘗試非互動。`sudo -v` 即使在 timestamp 仍有效時也堅持要 tty，因為它的職責是
# 重新驗證、會預備提示密碼；`sudo -n` 則在 timestamp 有效時直接成功。若順序相反，
# 本腳本在任何無 tty 的呼叫者下（cron、CI runner、agent shell）都會拒絕啟動——
# 即使 sudo 其實完全可用。
if sudo -n true 2>/dev/null; then
    good "sudo already valid (non-interactive) / sudo 已可用（非互動）"
elif [[ -t 0 ]]; then
    sudo -v || { print -ru2 -- "sudo failed; aborting / sudo 失敗，中止"; exit 1 }
    good "sudo timestamp acquired / 已取得 sudo timestamp"
else
    print -ru2 -- "sudo needs a password but there is no terminal to ask on."
    print -ru2 -- "sudo 需要密碼，但沒有可供輸入的終端。"
    print -ru2 -- "Run 'sudo -v' in a terminal first, then re-run this script."
    print -ru2 -- "請先在終端執行 'sudo -v'，再重新執行本腳本。"
    exit 1
fi

# 50 s, comfortably inside the 5-minute default timeout.
# 50 秒，明顯短於預設的 5 分鐘逾時。
start_keepalive() {
    while true; do sudo -n true 2>/dev/null || return; sleep 50; done &
    KEEPALIVE_PID=$!
}
stop_keepalive() { [[ -n "${KEEPALIVE_PID:-}" ]] && kill "$KEEPALIVE_PID" 2>/dev/null }

say ""
if [[ "$MODE" == "detach" ]]; then
    # The keep-alive has to live inside the detached shell, or closing the
    # terminal takes it down and the round stalls at the sudo it was protecting.
    # keep-alive 必須存活於背景 shell 之內，否則關閉終端會將它一併帶走，整輪就會
    # 卡在它原本要保護的那個 sudo。
    say "== Detached round / 背景執行 =="
    nohup zsh -c '
        while true; do sudo -n true 2>/dev/null || break; sleep 50; done &
        ka=$!
        ./run_round.command -full
        kill $ka 2>/dev/null
    ' >/dev/null 2>&1 &
    say "  started, pid $! / 已啟動"
    say "  follow: tail -f round_status.txt / 追蹤進度"
    say "  note: if the keep-alive dies the round stalls silently -- check on it."
    say "  注意：keep-alive 若中斷，整輪會靜默卡住，請留意。"
else
    say "== Round / 執行 =="
    say "  keep the terminal open; follow with: tail -f round_status.txt"
    say "  請保持終端開啟；可用 tail -f round_status.txt 追蹤"
    start_keepalive
    trap 'stop_keepalive' EXIT INT TERM
    ./run_round.command -full
    rc=$?
    stop_keepalive
    say ""
    say "== Done, exit $rc / 完成 =="
    say "  results: BenchMarkResult.csv, powerResults/, trace/"
    exit $rc
fi

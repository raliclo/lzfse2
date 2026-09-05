#!/bin/zsh
# check.zsh -- watch disk space and the git push log once a minute, forever.
# check.zsh -- 每分鐘檢視一次磁碟空間與 git push 記錄，持續執行。
#
#   helper/check.zsh          # Ctrl-C to stop / 按 Ctrl-C 停止
#   helper/check.zsh --help
#
# Meant for a spare terminal alongside a benchmark round. diskcheck() applies the
# same 20 GB gate that benchmark.zsh checks before every sweep, so watching it
# here shows a round heading for an abort well before it aborts.
# 供 benchmark 執行期間另開終端觀察之用。diskcheck() 套用的 20 GB 門檻與
# benchmark.zsh 在每次掃描前所檢查的相同，故在此觀察可在整輪真正中止之前就看出徵兆。
#
# The --help branch sits above the two `source` lines deliberately: sourcing
# zshrc.zsh runs a whole shell profile, which is real work to impose on someone
# who only asked for usage.
# --help 分支刻意置於兩行 `source` 之上：載入 zshrc.zsh 會執行整份 shell profile，
# 對只想看用法的人而言是不必要的負擔。
script_path="${0:A}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,18p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

source ~/proj/lzfse2/zshrc.zsh
source ~/proj/lzfse2/lz4bench.zsh   # diskcheck 住在這裡 / diskcheck lives here

while true;do
date;tail /Users/raliclo/proj/git_push.log;diskcheck;sleep 60
done
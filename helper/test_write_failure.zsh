#!/bin/zsh
# =====================================================================
# test_write_failure.zsh -- 輸出寫不進去時，lzfse 必須以非零結束，且不能是訊號。
# test_write_failure.zsh -- when output cannot be written, lzfse must exit non-zero, and not
#                           by a signal.
#
# 用法 / Usage:
#   helper/test_write_failure.zsh [lzfse 執行檔，預設 ./lzfse / binary, default ./lzfse]
#   helper/test_write_failure.zsh --help   印出本說明後結束，不建立任何東西 / print this, create nothing
#
# 為何需要它 / Why this exists:
#
# 舊的 `FileHandle.write(_: Data)` 寫入失敗時拋出 Swift 攔不住的 Objective-C 例外，行程以
# SIGABRT（rc=134）結束，原本的錯誤訊息也一併遺失。stderr 被關閉（`2>&-`）、stdout 被關閉
# （`>&-`）或磁碟寫滿時都會發生。改用 `write(contentsOf:)` 之後，錯誤必須往上傳成 rc=1——
# 不能 `try?` 吞掉，否則截斷的輸出會以 rc=0 結束，比當掉更難發現。
# The legacy `FileHandle.write(_: Data)` raises an Objective-C exception Swift cannot catch,
# so a closed stderr, a closed stdout or a full disk aborted the process with rc=134. After the
# switch to `write(contentsOf:)` the error has to surface as rc=1 -- swallowing it with `try?`
# would let truncated output exit 0, which is worse than the crash.
#
# 這支檢查必須仍可能失敗：修正前的執行檔在 stdout 關閉的解壓案例得 rc=134（macOS）或 132（Windows、Linux），判 FAIL。
# This check must still be able to fail: against the pre-fix binary the closed-stdout decode
# cases return rc=134 on macOS or 132 on Windows and Linux, and are reported FAIL.
#
# 判定 / Verdicts:
#   err    退出碼在 1..127（非零且不是訊號）/ exit status in 1..127 (non-zero, not a signal)
#   nz     退出碼非零，訊號亦可（SIGPIPE 是管線斷開的標準結果）/ non-zero; a signal is fine
#   ok     退出碼 0 且輸出與原檔逐位元組相同 / exit 0 and output byte-identical to the input
# =====================================================================

# --help 在 mktemp 與 RAM disk 之前回答。原本沒有這個分支，`--help` 被當成執行檔路徑而以
# 「找不到執行檔」結束——沒有開始工作，但也沒有回答。
# --help answers before the mktemp and the RAM disk. It used to be taken as the binary path
# and end with "binary not found": no work started, but no answer either.
script_path="${0:A}"
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,30p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi
# 其他以 - 開頭的參數是打錯的選項，不是執行檔路徑。/ Any other leading - is a mistyped option.
if [[ "${1:-}" == -* ]]; then
    print -u2 -- "未知的選項 / unknown option: $1（見 --help / see --help）"
    exit 2
fi

BIN=${1:-./lzfse}
BIN=${BIN:A}
[[ -x $BIN ]] || { print -u2 -- "找不到執行檔 / binary not found: $BIN"; exit 2 }

T=$(mktemp -d "${TMPDIR:-/tmp}/lzfse_wfail.XXXXXX") || exit 2
RAMDEV=""
cleanup() {
    [[ -n $RAMDEV ]] && hdiutil detach "$RAMDEV" -quiet
    rm -rf -- "$T"
}
trap cleanup EXIT

# 檔案大小用 wc -c，不用 `stat -f %z`：後者是 BSD 語法，GNU stat（MSYS、Linux）的 -f 是查詢
# 檔案系統，於是在 Windows／WSL 上大小取錯。算術展開去掉 macOS wc 補的前導空白。2026-10-07 之前
# 本檔因此只能在 macOS 執行。
# Size via wc -c, not `stat -f %z`: that is BSD syntax, and GNU stat (MSYS, Linux) reads -f
# as "filesystem status". The arithmetic expansion drops the padding macOS wc adds. Until
# 2026-10-07 this file therefore ran on macOS only.
fsize() { local n; n=$(wc -c < "$1"); print -r -- $(( n )) }

# 約 16 MiB 的輸入，跨過多個 4 MiB 分塊，好走到平行與逐批寫出的路徑。
# About 16 MiB of input, spanning several 4 MiB chunks so the parallel and batched paths run.
SRC=${0:A:h:h}/lzfse-cli.swift
: > "$T/in"
while (( $(fsize "$T/in") < 16 * 1024 * 1024 )); do cat "$SRC" >> "$T/in"; done

# Apple 編碼器需要 Compression framework，只有 macOS 有；其他平台的 lzfse 會以「此平台沒有
# Compression framework」拒絕。以實際試編判斷而非看 uname——問的是這個執行檔能不能，不是
# 這是哪個作業系統。沒有時 apple 的各項以 SKIP 列出，其餘照跑。
# The Apple encoder needs the Compression framework, which only macOS has; elsewhere lzfse
# refuses. Probe by trying it rather than by uname -- the question is what this binary can
# do. Without it the apple cases are listed as SKIP and the rest still run.
algos=(other3 bvx3) pipe_algos=(other3)
print -r -- probe > "$T/probe"
if "$BIN" -encode -algo apple -i "$T/probe" -o "$T/probe.lz" 2>/dev/null; then
    algos+=(apple) pipe_algos+=(apple)
else
    print -- "SKIP  apple（此執行檔沒有 Apple 編碼器 / this binary has no Apple encoder）"
fi

typeset -i pass=0 fail=0
check() {   # check <判定 verdict> <名稱 name> <rc> [輸出檔 output]
    local want=$1 name=$2 rc=$3 out=$4 ok=0
    case $want in
        err) (( rc >= 1 && rc <= 127 )) && ok=1 ;;
        nz)  (( rc != 0 )) && ok=1 ;;
        ok)  (( rc == 0 )) && cmp -s "$T/in" "$out" && ok=1 ;;
    esac
    if (( ok )); then pass+=1; print -- "PASS  $name  rc=$rc"
    else fail+=1; print -- "FAIL  $name  rc=$rc（預期 / expected $want）"; fi
}

for algo in $algos; do
    "$BIN" -encode -algo $algo -i "$T/in" -o "$T/in.$algo" 2>/dev/null
    rc=$?
    (( rc == 0 )) || { print -u2 -- "建立測試輸入失敗 / cannot build fixture: $algo rc=$rc"; exit 2 }
done

# 正控制：一般往返必須成功且逐位元組相同。/ Positive control: a normal round trip.
for algo in $algos; do
    "$BIN" -decode -algo $algo -i "$T/in.$algo" -o "$T/out.$algo" 2>/dev/null
    check ok "roundtrip $algo" $? "$T/out.$algo"
done

# stderr 關閉，且走一條會呼叫 eprint 的錯誤路徑。/ Closed stderr on an error path that prints.
"$BIN" -decode -i "$T/missing" -o /dev/null 2>&-
check err "stderr closed, missing input" $?

# stdout 關閉。/ Closed stdout.
for algo in $algos; do
    "$BIN" -encode -algo $algo -i "$T/in" -so >&- 2>/dev/null
    check err "stdout closed, encode $algo" $?
    "$BIN" -decode -algo $algo -i "$T/in.$algo" -so >&- 2>/dev/null
    check err "stdout closed, decode $algo (file)" $?
done
# stdin 輸入走 decodeStreamToHandle；Apple 產生的單流經 other3 解碼會走 .fallback 後援。
# stdin input takes decodeStreamToHandle; an Apple stream decoded as other3 takes .fallback.
"$BIN" -decode -algo other3 -si -so < "$T/in.other3" >&- 2>/dev/null
check err "stdout closed, decode other3 (stdin)" $?
if (( ${algos[(Ie)apple]} )); then
    "$BIN" -decode -algo other3 -i "$T/in.apple" -so >&- 2>/dev/null
    check err "stdout closed, decode apple stream via fallback" $?
fi

# 管線在讀了一個位元組後關閉：輸出被截斷，不得回 0。
# The pipe closes after one byte: the output is truncated and must not exit 0.
for algo in $pipe_algos; do
    "$BIN" -decode -algo $algo -i "$T/in.$algo" -so 2>/dev/null | head -c 1 > /dev/null
    check nz "broken pipe, decode $algo" ${pipestatus[1]}
done

# 磁碟寫滿：1 MiB 的 RAM disk 裝不下 16 MiB 的輸出。只在 macOS 上有 hdiutil。
# Disk full: a 1 MiB RAM disk cannot hold 16 MiB of output. hdiutil exists only on macOS.
# `hdiutil attach -nomount` 已棄用，改用 `diskutil image attach --noMount`。
# `hdiutil attach -nomount` is deprecated; use `diskutil image attach --noMount`.
if command -v hdiutil > /dev/null 2>&1; then
    RAMDEV=$(diskutil image attach --noMount ram://2048)
    RAMDEV=${RAMDEV%%[[:space:]]*}
    if [[ -n $RAMDEV ]] && diskutil eraseVolume HFS+ lzfse_wfail "$RAMDEV" > /dev/null; then
        for algo in $pipe_algos; do
            "$BIN" -decode -algo $algo -i "$T/in.$algo" -o /Volumes/lzfse_wfail/out 2>/dev/null
            check err "disk full, decode $algo" $?
            rm -f /Volumes/lzfse_wfail/out
        done
    else
        print -- "SKIP  disk full（無法建立 RAM disk / cannot create a RAM disk）"
    fi
else
    print -- "SKIP  disk full（沒有 hdiutil / no hdiutil）"
fi

print -- "通過 / passed: $pass  失敗 / failed: $fail"
(( fail == 0 ))

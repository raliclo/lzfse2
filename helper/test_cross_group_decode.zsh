#!/bin/zsh
# =====================================================================
# test_cross_group_decode.zsh -- 平行解碼中途失敗、改走循序時，輸出不得重複，有效串流不得被拒。
# test_cross_group_decode.zsh -- when parallel decode fails part way and falls back to
#                                sequential, output must not repeat and a valid stream must
#                                not be rejected.
#
# 用法 / Usage:
#   helper/test_cross_group_decode.zsh [lzfse 執行檔，預設 ./lzfse / binary, default ./lzfse]
#   helper/test_cross_group_decode.zsh --help   印出本說明後結束，不建立任何東西 / print this, create nothing
#
# 平行解碼依累計原始大小在 chunkRaw（4 MiB）的倍數處切組，各組獨立解。外來串流的區塊邊界若
# 恰好落在那個倍數上，而下一組有 match 往回參照前一組，平行解就會失敗、循序解則成功。我們自
# 己的編碼器每個分塊重新開始，不會產生這種串流；Apple 的編碼器區塊很大（實測 0.16–11.6 MB），
# 邊界也不會剛好落在 4 MiB 倍數上。所以這裡用拼接造出一個：
#
#   [未壓縮區塊 bvx-，原始大小 4 MiB − s] + [本工具編出的串流，第一個區塊原始大小 s]
#
# 第一組 = 未壓縮區塊 + 第一個壓縮區塊，剛好 4 MiB；第二組的 match 參照第一個壓縮區塊。
# `-n 1` 讓每組自成一批，第一批寫出後第二批才失敗——修正前 stdin 路徑把整份再寫一次（rc=0，
# 輸出多出 4 MiB），檔案路徑則把有效串流判為損毀（rc=1）。
#
# Parallel decode cuts groups where the cumulative raw size hits a multiple of chunkRaw
# (4 MiB) and decodes each on its own. A foreign stream whose block ends land on such a
# multiple, with a match reaching back into the previous group, fails in parallel and decodes
# sequentially. Neither our encoder nor Apple's produces one, so this check splices one
# together. With `-n 1` the first batch is written before the second fails: before the fix the
# stdin path wrote the whole stream again (rc=0, 4 MiB extra) and the file path rejected the
# valid stream (rc=1).
#
# 這支檢查必須仍可能失敗：拿修正前的執行檔跑，n=1 的案例應判 FAIL。
# Against the pre-fix binary the n=1 cases must report FAIL.
# =====================================================================

# --help 在 mktemp 之前回答。原本沒有這個分支，`--help` 被當成執行檔路徑而以「找不到執行檔」
# 結束——沒有開始工作，但也沒有回答。
# --help answers before the mktemp. It used to be taken as the binary path and end with
# "binary not found": no work started, but no answer either.
script_path="${0:A}"
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,33p' "$script_path" | sed 's/^# \{0,1\}//'
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

T=$(mktemp -d "${TMPDIR:-/tmp}/lzfse_xgroup.XXXXXX") || exit 2
trap 'rm -rf -- "$T"' EXIT

# 檔案大小用 wc -c，不用 `stat -f %z`：後者是 BSD 語法，GNU stat（MSYS、Linux）的 -f 是查詢
# 檔案系統，於是在 Windows／WSL 上大小取錯，前提檢查必定失敗。算術展開去掉 macOS wc 補的前導
# 空白。2026-10-07 之前本檔因此只能在 macOS 執行。
# Size via wc -c, not `stat -f %z`: that is BSD syntax, and GNU stat (MSYS, Linux) reads -f
# as "filesystem status", so the precondition always failed there. The arithmetic expansion
# drops the padding macOS wc adds. Until 2026-10-07 this file ran on macOS only.
fsize() { local n; n=$(wc -c < "$1"); print -r -- $(( n )) }

# 3,000,000 位元組的重複文字：本工具會編成兩個以上的區塊，後面的區塊參照第一個。
# 3,000,000 bytes of repetitive text: encodes to two or more blocks, the later ones
# referencing the first.
SRC=${0:A:h:h}/lzfse-cli.swift
: > "$T/big"
while (( $(fsize "$T/big") < 8 * 1024 * 1024 )); do cat "$SRC" >> "$T/big"; done
head -c 3000000 "$T/big" > "$T/x"
"$BIN" -encode -algo other3 -i "$T/x" -o "$T/x.lz" 2>/dev/null || { print -u2 -- "編碼失敗 / encode failed"; exit 2 }

magic=$(head -c 4 "$T/x.lz")
s=$(od -A n -t u4 -j 4 -N 4 "$T/x.lz" | tr -d ' ')
total=$(fsize "$T/x")
if [[ $magic != bvx2 ]] || (( s <= 0 || s >= total )); then
    print -u2 -- "前提不成立：需要第一個區塊為 bvx2 且不是唯一區塊（magic=$magic s=$s）"
    print -u2 -- "precondition failed: need a first bvx2 block that is not the only one"
    exit 2
fi

U=$(( 4 * 1024 * 1024 - s ))
head -c $U "$T/big" > "$T/u"
hex=$(printf '%08x' $U)
# 未壓縮區塊標頭：'bvx-' + 原始大小（32 位元小端）。/ Uncompressed header: 'bvx-' + raw size, LE32.
printf "bvx-\\x${hex[7,8]}\\x${hex[5,6]}\\x${hex[3,4]}\\x${hex[1,2]}" > "$T/cross.lz"
cat "$T/u" "$T/x.lz" >> "$T/cross.lz"
cat "$T/u" "$T/x" > "$T/expect"

# 截斷版：拿掉最後 64 位元組（含結尾標記），是真正損毀的串流。
# Truncated copy: drop the last 64 bytes, end marker included -- a genuinely corrupt stream.
head -c $(( $(fsize "$T/cross.lz") - 64 )) "$T/cross.lz" > "$T/trunc.lz"

typeset -i pass=0 fail=0
check() {   # check <名稱 name> <條件成立 0/1 condition> <說明 detail>
    if (( $2 )); then pass+=1; print -- "PASS  $1  $3"
    else fail+=1; print -- "FAIL  $1  $3"; fi
}

for n in 1 2 40; do
    "$BIN" -decode -algo other3 -n $n -si -so < "$T/cross.lz" > "$T/out" 2>/dev/null
    rc=$?; cmp -s "$T/expect" "$T/out"; same=$(( $? == 0 ))
    check "valid stream, stdin, n=$n" $(( rc == 0 && same )) "rc=$rc 大小/size=$(fsize "$T/out")/$(fsize "$T/expect")"
    "$BIN" -decode -algo other3 -n $n -i "$T/cross.lz" -o "$T/out" 2>/dev/null
    rc=$?; cmp -s "$T/expect" "$T/out"; same=$(( $? == 0 ))
    check "valid stream, file,  n=$n" $(( rc == 0 && same )) "rc=$rc 大小/size=$(fsize "$T/out")/$(fsize "$T/expect")"
done

# 損毀的串流：必須非零結束（且不是訊號），輸出不得超過正確長度。
# Corrupt stream: must exit non-zero (not a signal) and never write more than the true length.
for n in 1 40; do
    "$BIN" -decode -algo other3 -n $n -si -so < "$T/trunc.lz" > "$T/out" 2>/dev/null
    rc=$?; sz=$(fsize "$T/out")
    check "truncated, stdin, n=$n" $(( rc >= 1 && rc <= 127 && sz <= $(fsize "$T/expect") )) "rc=$rc size=$sz"
    "$BIN" -decode -algo other3 -n $n -i "$T/trunc.lz" -o "$T/out" 2>/dev/null
    rc=$?; sz=$(fsize "$T/out")
    check "truncated, file,  n=$n" $(( rc >= 1 && rc <= 127 && sz <= $(fsize "$T/expect") )) "rc=$rc size=$sz"
done

print -- "通過 / passed: $pass  失敗 / failed: $fail"
(( fail == 0 ))

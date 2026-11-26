#!/usr/bin/env zsh
# Verify release readers with padding after tar EOF. / 驗證發布讀取端可處理 tar 結尾後的補零。
set -euo pipefail
ROOT=${0:A:h:h}
case $(uname -s) in
  Darwin) platform=macos-$(uname -m) ;;
  Linux) platform=linux-$(uname -m)-glibc ;;
  *) print 'SKIP: needs a POSIX shell executable fixture / 需要 POSIX shell 執行檔測資'; exit 0 ;;
esac
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
VERSION=9.9.9 TAG=v9.9.9 TAG_SHA=12345678abcdef00
stem=lzfse-$VERSION-$platform
mkdir -p "$work/source/$stem"
# The stand-in exercises the verifier's control flow, not compression. / 替身驗證控制流程，不測壓縮演算法。
cat > "$work/source/$stem/lzfse" <<'FIXTURE'
#!/bin/sh
# v9.9.9 / 12345678
case "$1" in
  -version) printf 'lzfse 9.9.9 (v9.9.9 / 12345678) %s\n' "$TEST_PLATFORM"; exit 0 ;;
  -test) printf 'fixture: ✓\n'; exit 0 ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in -i) shift; input=$1 ;; -o) shift; output=$1 ;; esac
  shift
done
cp "$input" "$output"
FIXTURE
chmod 755 "$work/source/$stem/lzfse"
archive=$work/$stem.tar.zst
(cd "$work/source"; COPYFILE_DISABLE=1 tar -cf - "$stem"; dd if=/dev/zero bs=1048576 count=4 2>/dev/null) \
  | zstd -q -c > "$archive"
sha256_of() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
print -r -- "$(sha256_of "$archive")  ${archive:t}" > "$archive.sha256"
TEST_PLATFORM=$platform zsh "$ROOT/verify_archive.zsh" "$archive" "$platform"
print 'PASS: verifier accepts tar padding / 驗證器接受 tar 補零'

# Load only the archive checker; do not run publish or contact GitHub. / 僅載入封存檢查函式，不發布或連線 GitHub。
die() { print -ru2 -- "$1"; exit 1; }
say() { print -r -- "$*"; }
eval "$(sed -n '/^check_archive() {/,/^}/p' "$ROOT/publish.zsh")"
check_archive "$work" "$platform"
print 'PASS: publisher accepts tar padding / 發布檢查接受 tar 補零'

head -c 8 "$archive" > "$work/truncated.tar.zst"
print -r -- "$(sha256_of "$work/truncated.tar.zst")  truncated.tar.zst" > "$work/truncated.tar.zst.sha256"
if TEST_PLATFORM=$platform zsh "$ROOT/verify_archive.zsh" "$work/truncated.tar.zst" "$platform" > "$work/error.log" 2>&1; then
  print -ru2 'FAIL: truncated zstd accepted / 錯誤接受截斷的 zstd'
  exit 1
fi
print 'PASS: truncated zstd is refused / 截斷的 zstd 被拒絕'

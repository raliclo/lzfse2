#!/bin/zsh
# =====================================================================
# tar_ab.sh — controlled A/B: system tar vs swift_tar, encode/decode
#             wall time + peak RSS (no sudo).
# tar_ab.sh —— 受控 A/B：系統 tar vs swift_tar，量測 encode/decode 的
#             牆鐘時間與 peak RSS（免 sudo）。
#
# Usage / 用法：tar_comparison/tar_ab.sh [corpus]   (預設 claw-code)
# =====================================================================
set -u
cd "${0:A:h}/.." || exit 1          # repo root / 專案根目錄
CORPUS="${1:-claw-code}"
SWIFT_TAR_BIN="${SWIFT_TAR_BIN:-/opt/homebrew/bin/swift_tar}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

timeRss() {  # name bin
  local name="$1" bin="$2" arc="$TMP/$1.tgz" dest="$TMP/$1_out"
  local e=$(/usr/bin/time -l "$bin" czf "$arc" "$CORPUS" 2>&1 >/dev/null)
  local er=$(echo "$e" | awk '/ real/{print $1}')
  local erss=$(echo "$e" | awk '/maximum resident/{print $1}')
  mkdir -p "$dest"
  local d=$(/usr/bin/time -l "$bin" xzf "$arc" -C "$dest" 2>&1 >/dev/null)
  local dr=$(echo "$d" | awk '/ real/{print $1}')
  local drss=$(echo "$d" | awk '/maximum resident/{print $1}')
  rm -rf "$dest" "$arc"
  printf "%-10s enc_s=%-7s enc_rss_mb=%-8.1f dec_s=%-7s dec_rss_mb=%-8.1f\n" \
     "$name" "$er" "$((erss/1048576.0))" "$dr" "$((drss/1048576.0))"
}

echo "[Info] corpus: $CORPUS ($(du -sh "$CORPUS" | awk '{print $1}'))"
echo "== Pass1: encode/decode seconds + peak RSS =="
timeRss systemtar /usr/bin/tar
timeRss swifttar  "$SWIFT_TAR_BIN"

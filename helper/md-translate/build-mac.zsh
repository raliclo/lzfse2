#!/usr/bin/env zsh
set -euo pipefail

# Build the Apple Translation implementation on macOS.
# 在 macOS 建置 Apple Translation 實作。

# Not ${0:A:h}: the installed zsh does not treat a Windows drive path as
# absolute, so with $0 = C:/... it prepends the cwd and yields a directory that
# does not exist. Upstream fixes this ("Treat Windows drive paths as absolute in
# :A, :a and :P") but that build is not installed. This form is also what every
# other script in the repo uses.
# 不用 ${0:A:h}：安裝版 zsh 不把 Windows 磁碟機路徑視為絕對路徑，當 $0 為 C:/...
# 時會把 cwd 接在前面，得到不存在的目錄。上游已修（"Treat Windows drive paths as
# absolute in :A, :a and :P"），但該版本尚未安裝。此寫法亦為本 repo 其他腳本的通用作法。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:-$SCRIPT_DIR/bin/md-translate}"

mkdir -p "$(dirname "$OUTPUT")"
swiftc -O "$SCRIPT_DIR/md-translate.swift" -o "$OUTPUT"
echo "Built / 建置完成：$OUTPUT"

#!/usr/bin/env bash
set -euo pipefail

# Build the Apple Translation implementation on macOS.
# 在 macOS 建置 Apple Translation 實作。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${1:-$SCRIPT_DIR/bin/md-translate}"

mkdir -p "$(dirname "$OUTPUT")"
swiftc -O "$SCRIPT_DIR/md-translate.swift" -o "$OUTPUT"
echo "Built / 建置完成：$OUTPUT"

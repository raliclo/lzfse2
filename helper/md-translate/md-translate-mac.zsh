#!/usr/bin/env zsh
set -u

# md-translate-mac.zsh — compile md-translate.swift and run translation
# Output binary: helper/md-translate/bin/md-translate
# Note: import Translation requires macOS 15+ / Xcode; cannot be compiled on Windows.

# Not ${0:A:h} -- the installed zsh mis-resolves a Windows drive path there; see
# build-mac.zsh. This is the form the rest of the repo uses.
# 不用 ${0:A:h}——安裝版 zsh 會誤解 Windows 磁碟機路徑，詳見 build-mac.zsh。
# 此為本 repo 其他腳本通用的寫法。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BIN="$SCRIPT_DIR/bin/md-translate"
STATUS_FILE="$SCRIPT_DIR/translate_status.txt"
PIPELINE_STATUS_FILE="${ROUND_STATUS_FILE:-$REPO_ROOT/round_status.txt}"

mkdir -p "$SCRIPT_DIR/bin"

# Compile
"$SCRIPT_DIR/build-mac.zsh" "$BIN" >> "$PIPELINE_STATUS_FILE" 2>&1
COMPILE_EXIT=$?
echo "RUNNING md-translate $(date +%H:%M:%S)" > "$STATUS_FILE"

if [[ $COMPILE_EXIT -ne 0 ]]; then
    echo "TRANSLATE_COMPILE_FAILED $COMPILE_EXIT $(date +%H:%M:%S)" >> "$PIPELINE_STATUS_FILE"
    exit "$COMPILE_EXIT"
fi
if [[ ! -x "$BIN" ]]; then
    echo "TRANSLATE_BINARY_MISSING $(date +%H:%M:%S)" >> "$PIPELINE_STATUS_FILE"
    exit 1
fi

"$BIN" -i "$REPO_ROOT/OPTIMIZATION.md" -o "$REPO_ROOT/OPTIMIZATION-en.md" \
    -from zh-Hant -to en >> "$STATUS_FILE" 2>&1
TRANSLATE_EXIT=$?
if [[ $TRANSLATE_EXIT -ne 0 ]]; then
    echo "TRANSLATE_OPTIMIZATION_FAILED $TRANSLATE_EXIT $(date +%H:%M:%S)" >> "$PIPELINE_STATUS_FILE"
    exit "$TRANSLATE_EXIT"
fi

"$BIN" -i "$REPO_ROOT/README.zh-TW.md" -o "$REPO_ROOT/README.md" \
    -from zh-Hant -to en >> "$STATUS_FILE" 2>&1
TRANSLATE_EXIT=$?
if [[ $TRANSLATE_EXIT -ne 0 ]]; then
    echo "TRANSLATE_README_FAILED $TRANSLATE_EXIT $(date +%H:%M:%S)" >> "$PIPELINE_STATUS_FILE"
    exit "$TRANSLATE_EXIT"
fi

echo "TRANSLATE_DONE $(date +%H:%M:%S)" >> "$PIPELINE_STATUS_FILE"

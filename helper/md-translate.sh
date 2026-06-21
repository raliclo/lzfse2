#!/usr/bin/env bash
# md-translate.sh — compile md-translate.swift and run translation
# Output binary: helper/windows/md-translate.exe  (built on macOS; Apple Translation framework)
# Note: import Translation requires macOS 15+ / Xcode; cannot be compiled on Windows.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$SCRIPT_DIR/windows/md-translate.exe"

mkdir -p "$SCRIPT_DIR/windows"

# Compile
swiftc -O "$REPO_ROOT/md-translate.swift" -o "$BIN" >> "$REPO_ROOT/round_status.txt" 2>&1
COMPILE_EXIT=$?

if [[ $COMPILE_EXIT -ne 0 ]]; then
    echo "TRANSLATE_SKIPPED (compile failed, exit $COMPILE_EXIT) $(date +%H:%M:%S)" >> "$REPO_ROOT/round_status.txt"
elif [[ ! -x "$BIN" ]]; then
    echo "TRANSLATE_SKIPPED (binary not executable) $(date +%H:%M:%S)" >> "$REPO_ROOT/round_status.txt"
else
    "$BIN" -i "$REPO_ROOT/OPTIMIZATION.md"   -o "$REPO_ROOT/OPTIMIZATION-en.md" >> "$REPO_ROOT/translate_status.txt" 2>&1
    "$BIN" -i "$REPO_ROOT/README.zh-TW.md"  -o "$REPO_ROOT/README.md"           >> "$REPO_ROOT/translate_status.txt" 2>&1
    echo "TRANSLATE_DONE $(date +%H:%M:%S)" >> "$REPO_ROOT/round_status.txt"
fi

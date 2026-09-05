#!/usr/bin/env zsh
# md-translate-mac.zsh -- build md-translate, then translate the docs zh-Hant to en.
# md-translate-mac.zsh -- 建置 md-translate，再將文件由繁體中文翻譯為英文。
#
#   helper/md-translate/md-translate-mac.zsh   # output binary: bin/md-translate
#   helper/md-translate/md-translate-mac.zsh --help
#
# Step 15 of a round, called by benchmark2.zsh. Translates OPTIMIZATION.md into
# OPTIMIZATION-en.md, and README.zh-TW.md into README.md.
# 一輪的第 15 步，由 benchmark2.zsh 呼叫。將 OPTIMIZATION.md 譯為 OPTIMIZATION-en.md，
# 並將 README.zh-TW.md 譯為 README.md。
#
# macOS only: md-translate.swift does `import Translation`, which needs macOS 15+
# and Xcode, so it cannot be compiled on Windows. Every failure appends its own
# marker to $ROUND_STATUS_FILE and exits non-zero, so a round stops at the step
# that failed rather than carrying on with stale English files.
# 僅限 macOS：md-translate.swift 使用 `import Translation`，需要 macOS 15+ 與 Xcode，
# 無法在 Windows 上編譯。任何失敗都會在 $ROUND_STATUS_FILE 附加各自的標記並以非零狀態
# 離開，使整輪停在失敗的那一步，而非帶著過期的英文檔繼續。
set -u

script_path="${0:A}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,19p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

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

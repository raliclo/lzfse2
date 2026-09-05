#!/usr/bin/env zsh
# build-mac.zsh -- compile md-translate.swift into the md-translate binary.
# build-mac.zsh -- 將 md-translate.swift 編譯為 md-translate 執行檔。
#
#   helper/md-translate/build-mac.zsh                # default output ./bin/md-translate
#   helper/md-translate/build-mac.zsh /path/to/out   # 指定輸出路徑
#   helper/md-translate/build-mac.zsh --help
#
# macOS only: md-translate.swift does `import Translation`, which needs macOS 15+
# and the Xcode SDK, so it cannot be built on Windows. md-translate-mac.zsh calls
# this script and passes the output path explicitly.
# 僅限 macOS：md-translate.swift 使用 `import Translation`，需要 macOS 15+ 與 Xcode
# SDK，故無法在 Windows 上建置。md-translate-mac.zsh 會呼叫本腳本並明確傳入輸出路徑。
set -euo pipefail

script_path="${0:A}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '2,13p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

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

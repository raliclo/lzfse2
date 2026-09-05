#!/usr/bin/env zsh
#
# build-cli-win.zsh — 在 helper_windows 編譯 lzfse-cli.swift 為 lzfse.exe，
#                    並連同 Swift runtime DLL 打包成自包含的 lzfse-cli.zip。
# build-cli-win.zsh — Build lzfse-cli.swift into lzfse.exe under helper_windows and
#                    package it with the Swift runtime DLLs into a self-contained lzfse-cli.zip.
#
# 仿照 lzfse-ui/build-win.zsh 的方式（.build 資料夾、build.log、bsdtar 打包）。
# Mirrors lzfse-ui/build-win.zsh (a .build folder, build.log, bsdtar packaging).
#
# 與 build-win.zsh 的關鍵差異 / Key difference from build-win.zsh:
#   CLI 要「保留」結尾的 runCLI()（它是執行入口），不像 UI 要以 grep -v 移除。
#   The CLI KEEPS the trailing runCLI() (its entry point); the UI strips it with grep -v.
#
# 從 helper_windows/ 目錄執行 / Run from the helper_windows/ directory:
#     ./build-cli-win.zsh
#     ./build-cli-win.zsh --help
#
# 需求 / Requirements:
#   - Git for Windows（提供 Git Bash、cygpath、grep）/ provides Git Bash, cygpath, grep
#   - Swift for Windows 工具鏈（swiftc）+ Visual Studio Build Tools（C++）+ Windows SDK
#   - C:\Windows\System32\tar.exe（Windows 內建的 bsdtar，用於打包 zip）
#     C:\Windows\System32\tar.exe (the bsdtar shipped with Windows), for zip packaging

set -e

script_path="${0:A}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '3,23p' "$script_path" | sed 's/^# \{0,1\}//'
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Must be the System32 bsdtar, not whatever `tar` PATH resolves to: in Git Bash
# that is GNU tar, which cannot write ZIP at all and would fail late, after the
# whole build. Check the identity up front instead.
# 必須是 System32 的 bsdtar，不能用 PATH 上的 `tar`：在 Git Bash 下那是 GNU tar，
# 根本無法寫 ZIP，且會在整個建置跑完之後才失敗。故在此先驗明身分。
WIN_TAR="/c/Windows/System32/tar.exe"
if [ ! -x "$WIN_TAR" ] || ! "$WIN_TAR" --version 2>&1 | grep -q bsdtar; then
    echo "ERROR: 需要 Windows 內建的 bsdtar / need the bsdtar shipped with Windows at $WIN_TAR" >&2
    exit 1
fi
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_NAME="lzfse"
BUILD_DIR="${SCRIPT_DIR}/.build"
LOG="${BUILD_DIR}/build.log"

echo "Building ${APP_NAME}.exe (CLI)..."

# 1. 自動偵測 Swift runtime DLL 目錄（…/Programs/Swift/Runtimes/<ver>/usr/bin）
#    由 swiftc 路徑推導（不依賴 cygpath / LOCALAPPDATA）。
#    Auto-detect the Swift runtime DLL directory, derived from the swiftc path
#    (no cygpath / LOCALAPPDATA dependency).
SWIFT_BIN="$(dirname "$(command -v swiftc)")"      # …/Toolchains/<v>/usr/bin
SWIFT_ROOT="${SWIFT_BIN%/Toolchains/*}"            # …/Programs/Swift
RT_BIN="$(dirname "$(find "$SWIFT_ROOT/Runtimes" -name swiftCore.dll 2>/dev/null | head -1)")"
if [ -z "$RT_BIN" ] || [ ! -d "$RT_BIN" ]; then
    echo "ERROR: 找不到 Swift runtime（swiftCore.dll）/ Swift runtime not found under $SWIFT_ROOT/Runtimes" >&2
    exit 1
fi
echo "Swift runtime: $RT_BIN"

# 2. 重建 .build 資料夾 / Re-create the .build folder
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 3. 編譯 lzfse-cli.swift（保留 runCLI() 入口）/ compile lzfse-cli.swift (keep the runCLI() entry)
#    輸出同時寫入 .build/build.log / output is tee'd to .build/build.log
set -o pipefail
swiftc -O "${PROJECT_ROOT}/lzfse-cli.swift" -o "${BUILD_DIR}/${APP_NAME}.exe" 2>&1 | tee "$LOG"

# 4. staging：exe + Swift runtime DLL（自包含，可在未裝 Swift 的機器執行）
#    staging: exe + Swift runtime DLLs (self-contained; runs on machines without Swift)
STAGE="${BUILD_DIR}/dist/${APP_NAME}-cli"
rm -rf "${BUILD_DIR}/dist"
mkdir -p "$STAGE"
cp "${BUILD_DIR}/${APP_NAME}.exe" "$STAGE/"
cp "$RT_BIN"/*.dll "$STAGE/"

# 5. 以 Windows 內建的 bsdtar 打包成 zip，取代 PowerShell Compress-Archive。
#    C:\Windows\System32\tar.exe 是 bsdtar（libarchive），-a 依副檔名選格式，
#    -C 進入 staging 的上層再收 lzfse-cli/，故 zip 內保有與原本相同的目錄前綴。
#    走 -C 也就不必再把 /c/... 前綴改寫成 C:/... 餵給 PowerShell。
#    Package into a zip with the bsdtar that ships in Windows, replacing PowerShell's
#    Compress-Archive. C:\Windows\System32\tar.exe is bsdtar (libarchive); -a picks the
#    format from the extension, and -C steps into the staging parent so the archive keeps
#    the same lzfse-cli/ prefix as before. Using -C also removes the need to rewrite the
#    /c/... prefix into C:/... for PowerShell.
# 輸出到 release/ 子資料夾 / output into the release/ subfolder
mkdir -p "${SCRIPT_DIR}/release"
ZIP="${SCRIPT_DIR}/release/${APP_NAME}-cli.zip"
rm -f "$ZIP"
"$WIN_TAR" -a -c -f "$ZIP" -C "$(dirname "$STAGE")" "$(basename "$STAGE")"

# (N) null-glob so a DLL-less staging dir reports 0 rather than aborting: zsh's
# default NOMATCH is a shell error, which 2>/dev/null cannot suppress.
# (N) null-glob，使沒有 DLL 的 staging 目錄回報 0 而非中止：zsh 預設的 NOMATCH
# 是 shell 層級的錯誤，2>/dev/null 攔不住。
DLL_COUNT="$(ls "$STAGE"/*.dll(N) 2>/dev/null | wc -l | tr -d ' ')"
echo ""
echo "✓ Build complete!"
echo "Package:    ${ZIP}"
echo "  contents: ${APP_NAME}-cli/ { ${APP_NAME}.exe + ${DLL_COUNT} Swift runtime DLLs }"
echo "Build log:  ${LOG}"
echo ""
echo "解壓後在 ${APP_NAME}-cli/ 目錄內執行 ${APP_NAME}.exe（自包含，免裝 Swift）。"
echo "Extract and run ${APP_NAME}.exe inside ${APP_NAME}-cli/ (self-contained; no Swift install needed)."

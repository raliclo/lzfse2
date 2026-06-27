#!/bin/bash
#
# build-cli-win.sh — 在 helper_windows 編譯 lzfse-cli.swift 為 lzfse.exe，
#                    並連同 Swift runtime DLL 打包成自包含的 lzfse-cli.zip。
# build-cli-win.sh — Build lzfse-cli.swift into lzfse.exe under helper_windows and
#                    package it with the Swift runtime DLLs into a self-contained lzfse-cli.zip.
#
# 仿照 lzfse-ui/build-win.sh 的方式（.build 資料夾、build.log、cygpath、Compress-Archive）。
# Mirrors lzfse-ui/build-win.sh (a .build folder, build.log, cygpath, Compress-Archive).
#
# 與 build-win.sh 的關鍵差異 / Key difference from build-win.sh:
#   CLI 要「保留」結尾的 runCLI()（它是執行入口），不像 UI 要以 grep -v 移除。
#   The CLI KEEPS the trailing runCLI() (its entry point); the UI strips it with grep -v.
#
# 從 helper_windows/ 目錄執行 / Run from the helper_windows/ directory:
#     ./build-cli-win.sh
#
# 需求 / Requirements:
#   - Git for Windows（提供 Git Bash、cygpath、grep）/ provides Git Bash, cygpath, grep
#   - Swift for Windows 工具鏈（swiftc）+ Visual Studio Build Tools（C++）+ Windows SDK
#   - PowerShell（Windows 內建，用於 Compress-Archive）/ built-in, for Compress-Archive

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

# 5. 用 PowerShell Compress-Archive 打包成 zip。
#    PowerShell 接受 C:/... 正斜線路徑，故以 sed 把 /c/... 前綴轉成 C:/...（不依賴 cygpath）。
#    Package into a zip via PowerShell Compress-Archive. PowerShell accepts forward-slash
#    Windows paths (C:/...), so convert the /c/... prefix with sed (no cygpath dependency).
# 輸出到 release/ 子資料夾 / output into the release/ subfolder
mkdir -p "${SCRIPT_DIR}/release"
ZIP="${SCRIPT_DIR}/release/${APP_NAME}-cli.zip"
rm -f "$ZIP"
WIN_DIST="$(printf '%s' "${STAGE}" | sed -E 's#^/([a-zA-Z])/#\1:/#')"
WIN_ZIP="$(printf '%s' "${ZIP}" | sed -E 's#^/([a-zA-Z])/#\1:/#')"
powershell.exe -NoProfile -NonInteractive -Command \
  "Compress-Archive -Path '${WIN_DIST}' -DestinationPath '${WIN_ZIP}' -CompressionLevel Optimal -Force"

DLL_COUNT="$(ls "$STAGE"/*.dll 2>/dev/null | wc -l | tr -d ' ')"
echo ""
echo "✓ Build complete!"
echo "Package:    ${ZIP}"
echo "  contents: ${APP_NAME}-cli/ { ${APP_NAME}.exe + ${DLL_COUNT} Swift runtime DLLs }"
echo "Build log:  ${LOG}"
echo ""
echo "解壓後在 ${APP_NAME}-cli/ 目錄內執行 ${APP_NAME}.exe（自包含，免裝 Swift）。"
echo "Extract and run ${APP_NAME}.exe inside ${APP_NAME}-cli/ (self-contained; no Swift install needed)."

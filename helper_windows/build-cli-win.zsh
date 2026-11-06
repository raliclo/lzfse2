#!/usr/bin/env zsh
#
# build-cli-win.zsh — 在 helper_windows 編譯 lzfse-cli.swift 為 lzfse.exe（Swift runtime 靜態連結），
#                    並連同 VC++ runtime DLL 打包成自包含的 lzfse-cli.zip。
# build-cli-win.zsh — Build lzfse-cli.swift into lzfse.exe under helper_windows (Swift runtime linked
#                    in statically) and package it with the VC++ runtime DLLs into a self-contained lzfse-cli.zip.
#   2026-11-06 以前 zip 附的是整組 Swift runtime DLL；現在 exe 已含 Swift runtime，只需 VC++ 的三個 DLL。
#   Until 2026-11-06 the zip carried the whole Swift runtime; the exe now holds it, so only three VC++ DLLs ride along.
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
#     自動選用最新安裝的版本（swift_windows_env.zsh），不信任繼承來的 PATH／SDKROOT。
#     The newest installed version is picked (swift_windows_env.zsh); the inherited PATH/SDKROOT is not trusted.
#   - C:\Windows\System32\tar.exe（Windows 內建的 bsdtar，用於打包 zip）
#     C:\Windows\System32\tar.exe (the bsdtar shipped with Windows), for zip packaging

set -e

script_path="${0:A}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    sed -n '3,27p' "$script_path" | sed 's/^# \{0,1\}//'
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

# 1. 選用最新安裝的 Swift：swift_windows_env.zsh 設定 PATH／SDKROOT，並給出相配的 runtime 目錄。
#    Use the newest installed Swift: swift_windows_env.zsh sets PATH/SDKROOT and names the matching runtime.
#    更正 2026-11-06：原本由 `command -v swiftc` 推導根目錄，再取 `find Runtimes -name swiftCore.dll | head -1`。
#    swiftc 來自繼承的 PATH（升級後可能指向已刪除的版本），而 find 的順序不是版本序，裝了兩版時可能收錄
#    比編譯用的 swiftc 舊的 runtime。
#    CORRECTED 2026-11-06: this derived the root from `command -v swiftc`, then took
#    `find Runtimes -name swiftCore.dll | head -1`. swiftc came from the inherited PATH (which can name a version
#    an upgrade deleted), and find's order is not version order, so with two installed it could bundle an older
#    runtime than the swiftc that compiled.
source "${SCRIPT_DIR}/swift_windows_env.zsh"
RT_BIN="${swift_windows_runtime_bin:-}"
if [ -z "$RT_BIN" ] || [ ! -f "$RT_BIN/swiftCore.dll" ]; then
    echo "ERROR: 找不到相配的 Swift 工具鏈與 runtime / no matching Swift toolchain and runtime under %LOCALAPPDATA%/Programs/Swift" >&2
    exit 1
fi
echo "Swift ${swift_windows_version}: $(command -v swiftc)"
echo "Swift runtime: $RT_BIN"

# 2. 重建 .build 資料夾 / Re-create the .build folder
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 3. 編譯 lzfse-cli.swift（保留 runCLI() 入口）/ compile lzfse-cli.swift (keep the runCLI() entry)
#    輸出同時寫入 .build/build.log / output is tee'd to .build/build.log
#    -static-stdlib：Swift runtime 直接連結進 exe。連結時的三個 LNK4217（Blocks runtime）原因見 release.zsh
#    的 Windows 分支；保留可見，不壓掉。
#    -static-stdlib links the Swift runtime into the exe. The link's three LNK4217 warnings (Blocks runtime)
#    are explained in release.zsh's Windows branch; they are left visible, not silenced.
set -o pipefail
swiftc -O -static-stdlib "${PROJECT_ROOT}/lzfse-cli.swift" -o "${BUILD_DIR}/${APP_NAME}.exe" 2>&1 | tee "$LOG"

# 4. staging：exe + 它實際匯入的 runtime DLL（自包含，可在未裝 Swift 或 VC++ 可轉散發套件的機器執行）。
#    順著 PE import 遞移收集 Swift runtime 目錄裡有的 DLL：MSVCP140 又匯入 VCRUNTIME140_1，單層看不到。
#    靜態連結後只應找到 VC++ 的 DLL；若找到任何 Swift DLL，代表 -static-stdlib 沒有生效，直接失敗。
#    staging: exe + the runtime DLLs it actually imports (self-contained; runs without Swift or the VC++
#    redistributable). Walk the PE imports transitively, keeping what the Swift runtime directory holds:
#    MSVCP140 imports VCRUNTIME140_1, which one level never shows. With the static link only VC++ DLLs
#    should turn up; any Swift DLL means -static-stdlib did not take, and the build fails.
STAGE="${BUILD_DIR}/dist/${APP_NAME}-cli"
rm -rf "${BUILD_DIR}/dist"
mkdir -p "$STAGE"
cp "${BUILD_DIR}/${APP_NAME}.exe" "$STAGE/"
OBJDUMP="$(command -v llvm-objdump)" || { echo "ERROR: llvm-objdump 不在 PATH / llvm-objdump is not on PATH" >&2; exit 1; }
typeset -A seen=()
typeset -a queue=("${BUILD_DIR}/${APP_NAME}.exe") swift_dlls=()
while (( ${#queue} )); do
    current=${queue[1]}; shift queue
    # 先存下 objdump 的輸出再解析：放在 for 的字詞清單裡，它的失敗會被讀成「沒有 import」。
    # Capture objdump first: inside a for word list its failure would read as "no imports".
    dump="$("$OBJDUMP" -p "$current")"
    for dep in ${(f)"$(printf '%s\n' "$dump" | awk '/DLL Name:/ { print $3 }')"}; do
        case ${dep:l} in
            swift*.dll|foundation*.dll|_foundation*.dll|dispatch.dll|blocksruntime.dll) swift_dlls+=($dep) ;;
        esac
        [[ -n $dep && -z ${seen[$dep]:-} && -f $RT_BIN/$dep ]] || continue
        seen[$dep]=1
        cp "$RT_BIN/$dep" "$STAGE/"
        queue+=("$RT_BIN/$dep")
    done
done
if (( ${#swift_dlls} )); then
    echo "ERROR: ${APP_NAME}.exe 仍匯入 Swift runtime DLL（${swift_dlls[*]}）/ still imports Swift runtime DLLs; -static-stdlib did not take" >&2
    exit 1
fi

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
echo "  contents: ${APP_NAME}-cli/ { ${APP_NAME}.exe (Swift runtime linked in) + ${DLL_COUNT} VC++ runtime DLLs }"
echo "Build log:  ${LOG}"
echo ""
echo "解壓後在 ${APP_NAME}-cli/ 目錄內執行 ${APP_NAME}.exe（自包含，免裝 Swift）。"
echo "Extract and run ${APP_NAME}.exe inside ${APP_NAME}-cli/ (self-contained; no Swift install needed)."

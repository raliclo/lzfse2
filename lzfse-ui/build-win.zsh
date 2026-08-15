#!/usr/bin/env zsh
#
# build-win.zsh — 建置 LZFSE_UI_Win（SwiftCrossUI / WinUIBackend）
# build-win.zsh — Build LZFSE_UI_Win (SwiftCrossUI / WinUIBackend)
#
# 從 lzfse-ui/ 目錄執行 / Run from the lzfse-ui/ directory:
#     ./build-win.zsh            # release 建置 / release build
#     ./build-win.zsh -c debug   # 傳遞額外參數給 swift build / extra args passed to swift build
#
# 需求 / Requirements:
#   - Swift for Windows 工具鏈（已驗證 6.3.2，x86_64-windows-msvc）
#     Swift for Windows toolchain (verified with 6.3.2, x86_64-windows-msvc)
#   - Visual Studio Build Tools（C++ 工作負載）+ Windows 10/11 SDK
#     —— WinUIBackend 的 WinRT/WinUI 投影需要。
#     Visual Studio Build Tools (C++ workload) + Windows 10/11 SDK
#     — required by WinUIBackend's WinRT/WinUI projection.
#   - 首次建置會由 SwiftPM 自動拉取 swift-cross-ui 及其相依套件（需網路）。
#     The first build lets SwiftPM fetch swift-cross-ui and its dependencies (needs network).
#
# 本腳本依使用者選擇：將 lzfse-cli 當函式庫 import，
# 並以 grep -v 移除 lzfse-cli.swift 結尾的 runCLI() 呼叫後一起編入同一個 target。
# Per the chosen approach: import lzfse-cli as a library, stripping the trailing
# runCLI() call from lzfse-cli.swift with grep -v before compiling it into the target.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_NAME="LZFSE_UI_Win"
BUILD_DIR="${SCRIPT_DIR}/.win-build"
TARGET_DIR="${BUILD_DIR}/Sources/${APP_NAME}"
ICON_PNG="${SCRIPT_DIR}/AppIcon.png"
ICON_ICO="${BUILD_DIR}/AppIcon.ico"
ICON_RC="${BUILD_DIR}/AppIcon.rc"
ICON_RES="${BUILD_DIR}/AppIcon.res"
ICON_PS1="${SCRIPT_DIR}/make-icon.ps1"

# Must be the System32 bsdtar, not PATH's `tar`: in Git Bash that is GNU tar,
# which cannot write ZIP at all.
# 必須是 System32 的 bsdtar，不能用 PATH 上的 `tar`：Git Bash 下那是 GNU tar，
# 完全無法寫 ZIP。
WIN_TAR="/c/Windows/System32/tar.exe"

# `command -v` replaces a PowerShell Get-Command probe -- a plain PATH lookup
# never needed a whole PowerShell process, and reaching for one to *inspect*
# something is the easy slip the scripting policy calls out.
# 以 `command -v` 取代 PowerShell 的 Get-Command 探測——單純的 PATH 查找不需要
# 啟動一個 PowerShell 行程；為了「查詢」而動用 PowerShell 正是腳本政策點名的滑坡。
# Kept in MSYS form because llvm-rc is invoked directly rather than through
# cmd.exe -- see the call site for why that matters.
# 保留 MSYS 形式，因為 llvm-rc 是直接呼叫而非經由 cmd.exe——理由見呼叫處。
LLVM_RC="$(command -v llvm-rc.exe 2>/dev/null || true)"

echo "Building ${APP_NAME}..."

# 1. 重建 SwiftPM 套件骨架 / Re-scaffold the SwiftPM package
rm -rf "${BUILD_DIR}/Sources"
mkdir -p "$TARGET_DIR"

# Windows Explorer/taskbar icon:
# Use the same AppIcon.png as the macOS app, generate a Windows .ico, compile
# it into a .res resource, then pass that resource to the linker.
ICON_LINKER_FLAGS=""
if [ -f "$ICON_PNG" ] && [ -n "$LLVM_RC" ]; then
    echo "Generating Windows app icon resource..."
    ICON_PNG_WIN="$(printf '%s' "${ICON_PNG}" | sed -E 's#^/([a-zA-Z])/#\1:/#')"
    ICON_ICO_WIN="$(printf '%s' "${ICON_ICO}" | sed -E 's#^/([a-zA-Z])/#\1:/#')"
    ICON_RC_WIN="$(printf '%s' "${ICON_RC}" | sed -E 's#^/([a-zA-Z])/#\1:/#')"
    ICON_RES_WIN="$(printf '%s' "${ICON_RES}" | sed -E 's#^/([a-zA-Z])/#\1:/#')"

    # The icon generator now lives in make-icon.ps1 next to this script rather
    # than being written out at build time. It is the project's only PowerShell
    # file; see the header there for why it cannot be zsh.
    # 圖示產生器現在是與本腳本同層的 make-icon.ps1，不再於建置時寫出。它是本專案
    # 唯一的 PowerShell 檔案；無法改寫為 zsh 的理由見該檔開頭。
    ICON_PS1_WIN="$(printf '%s' "${ICON_PS1}" | sed -E 's#^/([a-zA-Z])/#\1:/#')"
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
        -File "$ICON_PS1_WIN" -SourcePng "$ICON_PNG_WIN" -OutIco "$ICON_ICO_WIN"

    printf 'IDI_APP_ICON ICON "%s"\n' "$ICON_ICO_WIN" > "$ICON_RC"
    # llvm-rc is a native exe, so call it directly: routing it through
    # `cmd.exe /d /c` meant MSYS rewrote the /d and /c switches into paths and
    # the command died as `'urrent' is not recognized`. Switching shell does not
    # help -- the zsh port mangles them identically. The flag is -fo, not /fo,
    # for the same reason: /fo is rewritten to <git-install>/fo.
    # llvm-rc 是原生執行檔，故直接呼叫：先前經由 `cmd.exe /d /c` 會使 MSYS 把
    # /d 與 /c 改寫成路徑，指令以 `'urrent' is not recognized` 失敗。換 shell 無效
    # ——zsh port 的改寫行為完全相同。旗標用 -fo 而非 /fo 也是同一原因：/fo 會被
    # 改寫為 <git 安裝路徑>/fo。
    "$LLVM_RC" -fo "$ICON_RES_WIN" "$ICON_RC_WIN"
    ICON_LINKER_FLAGS="                    \"-Xlinker\", \"${ICON_RES_WIN}\","
else
    echo "Warning: AppIcon.png or llvm-rc.exe not found; using default Windows exe icon."
fi

# 2. 移除 lzfse-cli.swift 結尾的 runCLI()，當函式庫編入
#    Strip the trailing runCLI() from lzfse-cli.swift and compile it as a library
grep -v '^runCLI()$' "${PROJECT_ROOT}/lzfse-cli.swift" > "${TARGET_DIR}/lzfse-cli.swift"

# 3. 複製 UI 原始碼 / Copy the UI source
cp "${SCRIPT_DIR}/lzfse-ui-win.swift" "${TARGET_DIR}/lzfse-ui-win.swift"

# 4. 產生 Package.swift（依使用者指定的 moreSwift/swift-cross-ui fork）
#    Generate Package.swift (using the user-specified moreSwift/swift-cross-ui fork)
cat > "${BUILD_DIR}/Package.swift" << EOF
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LZFSE_UI_Win",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/raliclo/swift-cross-ui.git",
            branch: "develop"
        ),
    ],
    targets: [
        .executableTarget(
            name: "LZFSE_UI_Win",
            dependencies: [
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
            ],
            linkerSettings: [
                // 以 Windows（GUI）子系統連結，避免啟動時跳出主控台視窗；
                // 仍用標準 C 進入點 mainCRTStartup 呼叫 Swift @main 的 main()。
                // Link as the Windows (GUI) subsystem so no console window pops up on launch;
                // keep the standard C entry point mainCRTStartup, which calls Swift @main's main().
                .unsafeFlags([
${ICON_LINKER_FLAGS}
                    "-Xlinker", "/SUBSYSTEM:WINDOWS",
                    "-Xlinker", "/ENTRY:mainCRTStartup",
                ])
            ]
        ),
    ]
)
EOF

# 5. 建置 / Build
#    輸出同時寫入 .win-build/build.log（該資料夾已被 .gitignore 忽略）
#    Tee output to .win-build/build.log (that folder is ignored by .gitignore)
LOG="${BUILD_DIR}/build.log"
cd "$BUILD_DIR"
set -o pipefail
if [ "$#" -eq 0 ]; then
    swift build -c release 2>&1 | tee "$LOG"
else
    swift build "$@" 2>&1 | tee "$LOG"
fi

# 6. 打包 exe + 執行期必要檔案成 zip，複製到 lzfse-ui/
#    Package the exe with its required runtime files into a zip, copy to lzfse-ui/
EXE_SRC="${BUILD_DIR}/.build/x86_64-unknown-windows-msvc/release/${APP_NAME}.exe"
[ -f "$EXE_SRC" ] || EXE_SRC="${BUILD_DIR}/.build/release/${APP_NAME}.exe"
REL_DIR="$(dirname "$EXE_SRC")"

# 6a. Build the companion CLI so the packaged Equivalent Command can use .\lzfse.exe.
#     Run helper_windows/compile.bat from its own directory because it expects ../lzfse-cli.swift.
#     Feed stdin from NUL so the final PAUSE in compile.bat does not block automated packaging.
HELPER_DIR="${PROJECT_ROOT}/helper_windows"
CLI_EXE="${HELPER_DIR}/lzfse.exe"
echo ""
echo "Building companion CLI via helper_windows/compile.bat..."
(cd "$HELPER_DIR" && cmd.exe /d /c "compile.bat < NUL")
if [ ! -f "$CLI_EXE" ]; then
    echo "ERROR: helper_windows/compile.bat did not produce ${CLI_EXE}" >&2
    exit 1
fi

STAGE="${BUILD_DIR}/dist/${APP_NAME}"
rm -rf "${BUILD_DIR}/dist"
mkdir -p "$STAGE"

# 執行期必要檔案 / Required runtime files:
#   - <app>.exe                          主程式 / the app
#   - SwiftJava.dll                      Swift 端相依 / Swift-side dependency
#   - swift-winui_CWinAppSDK.resources/  內含 WindowsAppRuntime Bootstrap DLL，
#                                        WindowsAppRuntimeInitializer 由此相對路徑載入
#                                        contains the bootstrap DLL loaded by the initializer
cp "$REL_DIR/${APP_NAME}.exe" "$STAGE/"
cp "$CLI_EXE" "$STAGE/"
cp "$ICON_ICO" "$STAGE/"
cp "$REL_DIR/SwiftJava.dll" "$STAGE/" 2>/dev/null || true
cp -r "$REL_DIR/swift-winui_CWinAppSDK.resources" "$STAGE/"

# 輸出到 release/ 子資料夾 / output into the release/ subfolder
mkdir -p "${SCRIPT_DIR}/release"
ZIP="${SCRIPT_DIR}/release/${APP_NAME}.zip"
rm -f "$ZIP"
# 以 Windows 內建的 bsdtar 打包，取代 PowerShell Compress-Archive；-C 進入 dist/
# 再收 ${APP_NAME}/，zip 內的目錄前綴與原本相同，也不必再改寫路徑前綴。
# Package with the bsdtar shipped in Windows instead of PowerShell's Compress-Archive;
# -C steps into dist/ and adds ${APP_NAME}/, so the archive keeps the same directory
# prefix as before and no path-prefix rewriting is needed.
"$WIN_TAR" -a -c -f "$ZIP" -C "${BUILD_DIR}/dist" "${APP_NAME}"

echo ""
echo "✓ Build complete!"
echo "Package:    ${ZIP}"
echo "  contents: ${APP_NAME}/ { ${APP_NAME}.exe, AppIcon.ico, lzfse.exe, SwiftJava.dll, swift-winui_CWinAppSDK.resources/ }"
echo "Build log:  ${LOG}"
echo ""
echo "解壓後執行 ${APP_NAME}/${APP_NAME}.exe 即可測試。"
echo "Extract and run ${APP_NAME}/${APP_NAME}.exe to test."
echo "需求 / Requires:"
echo "  - Windows App Runtime 1.5（含 DDLM）已安裝 / installed (incl. DDLM)"
echo "  - Swift for Windows runtime 在 PATH（本機工具鏈即可）/ on PATH (the local toolchain suffices)"

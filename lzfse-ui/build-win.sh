#!/bin/bash
#
# build-win.sh — 建置 LZFSE_UI_Win（SwiftCrossUI / WinUIBackend）
# build-win.sh — Build LZFSE_UI_Win (SwiftCrossUI / WinUIBackend)
#
# 從 lzfse-ui/ 目錄執行 / Run from the lzfse-ui/ directory:
#     ./build-win.sh            # release 建置 / release build
#     ./build-win.sh -c debug   # 傳遞額外參數給 swift build / extra args passed to swift build
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
ICON_PS1="${BUILD_DIR}/make-icon.ps1"
LLVM_RC_WIN="$(powershell.exe -NoProfile -NonInteractive -Command "(Get-Command llvm-rc.exe -ErrorAction SilentlyContinue).Source" | tr -d '\r')"

echo "Building ${APP_NAME}..."

# 1. 重建 SwiftPM 套件骨架 / Re-scaffold the SwiftPM package
rm -rf "${BUILD_DIR}/Sources"
mkdir -p "$TARGET_DIR"

# Windows Explorer/taskbar icon:
# Use the same AppIcon.png as the macOS app, generate a Windows .ico, compile
# it into a .res resource, then pass that resource to the linker.
ICON_LINKER_FLAGS=""
if [ -f "$ICON_PNG" ] && [ -n "$LLVM_RC_WIN" ]; then
    echo "Generating Windows app icon resource..."
    ICON_PNG_WIN="$(printf '%s' "${ICON_PNG}" | sed -E 's#^/([a-zA-Z])/#\1:/#')"
    ICON_ICO_WIN="$(printf '%s' "${ICON_ICO}" | sed -E 's#^/([a-zA-Z])/#\1:/#')"
    ICON_RC_WIN="$(printf '%s' "${ICON_RC}" | sed -E 's#^/([a-zA-Z])/#\1:/#')"
    ICON_RES_WIN="$(printf '%s' "${ICON_RES}" | sed -E 's#^/([a-zA-Z])/#\1:/#')"

    cat > "$ICON_PS1" <<'PS1'
param([string]$SourcePng, [string]$OutIco)
Add-Type -AssemblyName System.Drawing
$source = [System.Drawing.Image]::FromFile($SourcePng)
try {
    $sizes = @(16, 24, 32, 48, 64, 128, 256)
    $frames = New-Object System.Collections.Generic.List[byte[]]
    foreach ($size in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.DrawImage($source, 0, 0, $size, $size)
        } finally {
            $g.Dispose()
        }
        $ms = New-Object System.IO.MemoryStream
        try {
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $frames.Add($ms.ToArray())
        } finally {
            $ms.Dispose()
            $bmp.Dispose()
        }
    }

    $fs = [System.IO.File]::Create($OutIco)
    $bw = New-Object System.IO.BinaryWriter $fs
    try {
        $bw.Write([UInt16]0)
        $bw.Write([UInt16]1)
        $bw.Write([UInt16]$sizes.Count)
        $offset = 6 + (16 * $sizes.Count)
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $size = [int]$sizes[$i]
            $data = [byte[]]$frames[$i]
            $iconSize = [byte]$(if ($size -eq 256) { 0 } else { $size })
            $bw.Write($iconSize)
            $bw.Write($iconSize)
            $bw.Write([byte]0)
            $bw.Write([byte]0)
            $bw.Write([UInt16]1)
            $bw.Write([UInt16]32)
            $bw.Write([UInt32]$data.Length)
            $bw.Write([UInt32]$offset)
            $offset += $data.Length
        }
        foreach ($data in $frames) {
            $bw.Write([byte[]]$data)
        }
    } finally {
        $bw.Dispose()
        $fs.Dispose()
    }
} finally {
    $source.Dispose()
}
PS1
    ICON_PS1_WIN="$(printf '%s' "${ICON_PS1}" | sed -E 's#^/([a-zA-Z])/#\1:/#')"
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
        -File "$ICON_PS1_WIN" -SourcePng "$ICON_PNG_WIN" -OutIco "$ICON_ICO_WIN"

    printf 'IDI_APP_ICON ICON "%s"\n' "$ICON_ICO_WIN" > "$ICON_RC"
    cmd.exe /d /c "${LLVM_RC_WIN} /fo ${ICON_RES_WIN} ${ICON_RC_WIN}"
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

# 用 PowerShell Compress-Archive 打包成 zip。
# （本機 bsdtar 不支援寫入 zip 格式 → 改用 PowerShell 內建；產出含頂層 ${APP_NAME}/ 資料夾）
# Package into a zip via PowerShell Compress-Archive.
# (the local bsdtar lacks zip *write* support → use PowerShell's built-in; the zip
#  contains a top-level ${APP_NAME}/ folder)
# 輸出到 release/ 子資料夾 / output into the release/ subfolder
mkdir -p "${SCRIPT_DIR}/release"
ZIP="${SCRIPT_DIR}/release/${APP_NAME}.zip"
rm -f "$ZIP"
# PowerShell 接受 C:/... 正斜線路徑，故只需把 Git Bash 的 /c/... 前綴轉成 C:/...（純 sed，不依賴 cygpath）
# PowerShell accepts forward-slash Windows paths (C:/...), so just convert the /c/... prefix
# to C:/... with sed (no cygpath dependency).
WIN_DIST="$(printf '%s' "${BUILD_DIR}/dist/${APP_NAME}" | sed -E 's#^/([a-zA-Z])/#\1:/#')"
WIN_ZIP="$(printf '%s' "${ZIP}" | sed -E 's#^/([a-zA-Z])/#\1:/#')"
powershell.exe -NoProfile -NonInteractive -Command \
  "Compress-Archive -Path '${WIN_DIST}' -DestinationPath '${WIN_ZIP}' -CompressionLevel Optimal -Force"

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

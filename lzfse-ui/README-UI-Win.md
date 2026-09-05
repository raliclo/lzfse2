# LZFSE_UI_Win — Windows GUI / Windows 圖形介面

SwiftCrossUI（WinUIBackend）打造的 LZFSE 壓縮/解壓縮圖形介面，對應 macOS 版 `lzfse-ui.swift`。
A SwiftCrossUI (WinUIBackend) GUI for LZFSE compression/decompression, the Windows
counterpart of the macOS `lzfse-ui.swift`.

- UI 原始碼 / UI source: `lzfse-ui-win.swift`
- 建置腳本 / Build script: `build-win.zsh`
- 壓縮 codec / Codec: 直接 import 專案根目錄的 `lzfse-cli.swift`（建置時以 `grep -v` 移除結尾 `runCLI()`）
  imports the project-root `lzfse-cli.swift` as a library (the trailing `runCLI()` is stripped with `grep -v` at build time)

---

## ⚠️ 執行需求 / Runtime Requirements

### 1. Windows App Runtime 1.5（**必須含 DDLM**）/ Windows App Runtime 1.5 (**DDLM required**)

WinUIBackend 透過 bootstrapper 動態載入 **Windows App SDK 1.5**。
swift-winui 寫死請求 1.5（`WINDOWSAPPSDK_RELEASE_MAJORMINOR = 0x00010005`），
因此**必須安裝 1.5 runtime 的完整套件組**，特別是 **DDLM（Dynamic Dependency Lifetime Manager）**。

WinUIBackend dynamically loads **Windows App SDK 1.5** via its bootstrapper.
swift-winui hard-codes a request for 1.5 (`WINDOWSAPPSDK_RELEASE_MAJORMINOR = 0x00010005`),
so the **complete 1.5 runtime must be installed**, in particular the
**DDLM (Dynamic Dependency Lifetime Manager)** package.

> **常見陷阱 / Common pitfall**：機器上常只有 1.5 的 *framework* 套件（被其他 app 順帶安裝），
> 但缺 **DDLM `5001.x`**。此時 UI 啟動會立即崩潰（exit 132 / SIGILL），錯誤為：
> A machine often has only the 1.5 *framework* package (pulled in by some other app) but is
> missing the **DDLM `5001.x`**. The UI then crashes immediately on launch (exit 132 / SIGILL):
>
> ```
> WARI_INIT_ERROR: Package dependency criteria could not be resolved.
> WinUI/SwiftApplication.swift:64: Fatal error: fatal
> ```

#### 檢查是否已安裝 1.5 DDLM / Check whether the 1.5 DDLM is installed

```powershell
Get-AppxPackage -Name "*DDLM*" | Where-Object { $_.Version -match "^5001" } |
  Select-Object Name, Architecture, Version
```

有輸出（例如 `Microsoft.WinAppRuntime.DDLM.5001.373.1736.0-x6  X64`）即代表就緒。
空白代表**未安裝**，請依下方安裝。
Output (e.g. `Microsoft.WinAppRuntime.DDLM.5001.373.1736.0-x6  X64`) means it's ready.
Empty output means it's **missing** — install it as below.

#### 安裝 1.5 完整 runtime（含 DDLM）/ Install the complete 1.5 runtime (incl. DDLM)

`winget install Microsoft.WindowsAppRuntime.1.5` **不夠**——它只裝 framework，**不會註冊 DDLM**
（DDLM 需要系統管理員權限做 machine-wide provisioning）。
請改用 Microsoft 官方 redistributable，**以系統管理員執行**：

`winget install Microsoft.WindowsAppRuntime.1.5` is **not enough** — it installs only the
framework and does **not** register the DDLM (which needs admin-level machine-wide
provisioning). Use the official Microsoft redistributable, **run as Administrator**:

```powershell
# 下載官方 1.5 x64 redistributable / Download the official 1.5 x64 redistributable
Invoke-WebRequest -UseBasicParsing `
  -Uri "https://aka.ms/windowsappsdk/1.5/latest/windowsappruntimeinstall-x64.exe" `
  -OutFile "$env:TEMP\WindowsAppRuntimeInstall-1.5-x64.exe"

# 以系統管理員執行（會跳 UAC，請按「是」）/ Run elevated (approve the UAC prompt)
Start-Process "$env:TEMP\WindowsAppRuntimeInstall-1.5-x64.exe" `
  -ArgumentList "--force","--quiet" -Verb RunAs -Wait
```

安裝後再次以上方指令確認 DDLM `5001.x` 已出現。
After installing, re-run the check above and confirm DDLM `5001.x` appears.

### 2. Swift for Windows runtime 在 PATH / Swift for Windows runtime on PATH

exe 依賴 Swift runtime DLL（swiftCore.dll、Foundation.dll 等）。在已安裝 Swift 工具鏈的機器上，
這些 DLL 已在 PATH，無需額外處理。**zip 不含 Swift runtime DLL。**

The exe depends on the Swift runtime DLLs (swiftCore.dll, Foundation.dll, …). On a machine
with the Swift toolchain installed they're already on PATH. **The zip does not bundle them.**

---

## 從 zip 執行 / Run from the zip

`build-win.zsh` 會在 `lzfse-ui/release/` 產出 `LZFSE_UI_Win.zip`，內含：
`build-win.zsh` produces `LZFSE_UI_Win.zip` in `lzfse-ui/release/`, containing:

```
LZFSE_UI_Win/
├─ LZFSE_UI_Win.exe                                          # 主程式 / the app
├─ lzfse.exe                                                 # 隨附 CLI / companion CLI
├─ AppIcon.ico                                               # 圖示 / icon
├─ SwiftJava.dll                                             # Swift 相依 / dependency
└─ swift-winui_CWinAppSDK.resources/
   └─ Microsoft.WindowsAppRuntime.Bootstrap.dll             # bootstrapper（由相對路徑載入）
```

解壓後執行資料夾內的 `LZFSE_UI_Win.exe` 即可。
Extract and run `LZFSE_UI_Win.exe` inside the folder.

> Bootstrap DLL 必須留在 `swift-winui_CWinAppSDK.resources\` 子資料夾——
> `WindowsAppRuntimeInitializer` 以相對路徑載入它，請勿移動或攤平目錄結構。
> Keep the bootstrap DLL inside the `swift-winui_CWinAppSDK.resources\` subfolder —
> `WindowsAppRuntimeInitializer` loads it via that relative path; don't flatten the layout.

---

## 建置 / Build

```bash
# 從 lzfse-ui/ 目錄執行 / Run from the lzfse-ui/ directory
./build-win.zsh
```

**建置需求 / Build requirements**：
- **zsh（必要，需另外安裝）** / **zsh (required, separate install)**
  `build-win.zsh` 的 shebang 是 `#!/usr/bin/env zsh`，是 zsh 腳本而非 bash 腳本。
  **Git Bash 不附帶 zsh**，所以只裝 Git for Windows 是不夠的；請另外安裝 Windows 版 zsh
  （例如 `scoop install zsh`），或在已有 zsh 的環境中執行。
  `build-win.zsh` has a `#!/usr/bin/env zsh` shebang — it is a zsh script, not a bash script.
  **Git Bash does not ship zsh**, so Git for Windows alone is not enough; install a Windows
  zsh (e.g. `scoop install zsh`) or run it from an environment that already has one.
- **Git for Windows** — 仍需要，用來提供 `grep`、`sed` 等 POSIX 工具（路徑轉換用 `sed`，不依賴 `cygpath`）。
  下載 / Download: <https://gitforwindows.org>
  Still needed, for the POSIX tools (`grep`, `sed`, …) the script uses; path conversion uses
  `sed`, not `cygpath`.
- Swift for Windows 工具鏈（已驗證 6.3.2，x86_64-windows-msvc）/ toolchain (verified 6.3.2)
  ——同時提供圖示資源所需的 `llvm-rc.exe` / also supplies the `llvm-rc.exe` used for the icon resource
- Visual Studio Build Tools（C++ 工作負載）+ Windows 10/11 SDK
- Windows 內建的 bsdtar（`C:\Windows\System32\tar.exe`）用於打包 zip。腳本寫死這個路徑，
  刻意避開 PATH 上的 `tar`：Git Bash 的那個是 GNU tar，完全無法寫 ZIP。**不再使用 PowerShell 的
  `Compress-Archive`。**
  The bsdtar bundled with Windows (`C:\Windows\System32\tar.exe`) does the zipping. The script
  hard-codes that path to avoid PATH's `tar`, which under Git Bash is GNU tar and cannot write
  ZIP at all. PowerShell's `Compress-Archive` is **no longer used**.
- PowerShell（Windows 內建）僅用於執行 `make-icon.ps1` 產生 `.ico`
  PowerShell (built into Windows) is used only to run `make-icon.ps1`, which produces the `.ico`
- 首次建置由 SwiftPM 自動拉取 `https://github.com/raliclo/swift-cross-ui.git` 的 `develop` 分支及其相依（需網路）
  the first build fetches the `develop` branch of `https://github.com/raliclo/swift-cross-ui.git`
  and its dependencies (needs network)

建置流程 / The script will：
1. 以 `grep -v '^runCLI()$'` 將 `../lzfse-cli.swift` 當函式庫編入 / strip `runCLI()` and import the codec as a library
2. `swift build -c release`（log 寫入 `.win-build/build.log`）
3. 以 `helper_windows/compile.bat` 建置隨附的 `lzfse.exe` CLI / build the companion `lzfse.exe` CLI via `helper_windows/compile.bat`
4. 以 Windows 內建 bsdtar 打包 exe + 必要執行檔成 `lzfse-ui/release/LZFSE_UI_Win.zip`
   package everything into `lzfse-ui/release/LZFSE_UI_Win.zip` with the Windows bsdtar

---

## 功能 / Features

| 功能 / Feature | 說明 / Notes |
| --- | --- |
| 壓縮 / 解壓縮切換 | Compress / Decompress |
| 演算法 Other3 / BVX3 | Apple 演算法在 Windows 不提供（無 Compression framework）/ Apple algo unavailable on Windows |
| Lazy2 / Optimal | 僅 BVX3 編碼時可用 / BVX3 encode only |
| 並行任務數 n | Parallel tasks |
| 檔案 / 資料夾壓縮 | 資料夾經 `tar` 打包 / folders via `tar` |
| lzfseX 壓縮包偵測與解包 | auto-detect & extract lzfseX archives |

> WinUI 的開檔對話框一次只能選「檔案」或「資料夾」其一，故壓縮輸入提供兩顆按鈕。
> WinUI's open dialog allows files *or* folders (not both) per dialog, hence two input buttons.

---

## Current Windows status / Windows current progress

As of the 2026-07-07 Windows UI / benchmark status:

- `build-win.zsh` builds the SwiftCrossUI app, then runs `helper_windows/compile.bat` to build a fresh companion CLI.
- `build-win.zsh` currently pins the SwiftCrossUI dependency to the `develop` branch of `https://github.com/raliclo/swift-cross-ui.git` instead of the previous `0.7.0` up-to-next-minor requirement.
- `build-win.zsh` also embeds the Windows app icon into `LZFSE_UI_Win.exe`: it uses the same `AppIcon.png` source image as the macOS app, generates `.win-build/AppIcon.ico`, compiles `.win-build/AppIcon.res` with `llvm-rc.exe`, and links that resource into the exe. File Explorer and the Windows taskbar should therefore show the LZFSE UI icon. If Windows still shows an old/default icon, use a fresh extraction folder or restart Explorer to clear the icon cache.
- The Windows UI now exposes `Optimal3 Parsing / 標準格式最優解析` under Other3 encode mode. The equivalent command becomes `-algo other3 -optimal3`; output remains standard Apple-compatible LZFSE.
- The file section is more compact: `Reset / 重置` and `Compress / Decompress` now sit on the right side of the `Files / 檔案` header instead of taking a separate bottom row.
- The final `LZFSE_UI_Win.zip` is written to `lzfse-ui/release/` and contains:

  ```text
  LZFSE_UI_Win/
  |-- LZFSE_UI_Win.exe
  |-- lzfse.exe
  |-- AppIcon.ico
  |-- SwiftJava.dll
  `-- swift-winui_CWinAppSDK.resources/
      `-- Microsoft.WindowsAppRuntime.Bootstrap.dll
  ```

- UI decompression runs the same binary-safe command shown in **Equivalent Command** instead of using the internal Swift/UI pipe path.
- The command is executed with the working directory set to the folder containing `LZFSE_UI_Win.exe`, so `.\lzfse.exe` resolves to the packaged CLI in the same folder.
- This avoids Windows PowerShell corrupting binary tar streams when piping `-so` directly.
- Before extraction, the UI lists the tar entries. If they start with `../`, the UI automatically adds `--strip-components 1` during extraction. This handles archives such as `../claw-code/...` that Windows bsdtar otherwise rejects with `Path contains '..'`.
- Windows benchmark infrastructure is active for both `claw-code` and `llama.cpp` datasets:
  - `helper_windows/run_round.bat` runs encode-to-nul, encode-to-file, decode-to-nul, decode-to-file, RSS probes, summary generation, and macOS-vs-Windows comparison.
  - CSV outputs live under `helper_windows/bench_results_csv/`: `encode_summary.csv`, `decode_summary.csv`, `rss_summary.csv`, `BenchMarkResult-Win.csv`, and one combined `comparison.csv` with `dataset` as the first column.
  - Result logs live under `helper_windows/bench_logs/`.
  - R42-Win completed on 2026-07-05: `lzfse.exe -test` passed, `comparison.csv` now includes `LZFSE (Optimal3)` for both datasets, and all Windows decode verify results are `PASS`.
  - R42-Win details and the `Optimal3` vs `Optimal` compression-ratio explanation are recorded in `OPTIMIZATION.md`.

Equivalent decode command pattern:

```powershell
cmd /d /c ".\lzfse.exe -decode -i ""C:/path/input.lzfse"" -n 8 -so | tar -xf - -C ""C:/path/output-folder"""
```

Manual command for archives whose entries start with `../`:

```powershell
cmd /d /c ".\lzfse.exe -decode -i ""C:/path/input.lzfse"" -n 8 -so | tar -xf - --strip-components 1 -C ""C:/path/output-folder"""
```

Windows helper maintenance notes:

- `helper_windows/run_round.bat` no longer pipes Python summary output through PowerShell `Tee-Object`; it writes through temporary log files and raw `type >> windows_round_status.txt` to avoid mixed-encoding status logs.
- Project-owned `.bat` files are normalized to CRLF.

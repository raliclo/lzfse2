# LZFSE_UI_Win — Windows GUI / Windows 圖形介面

SwiftCrossUI（WinUIBackend）打造的 LZFSE 壓縮/解壓縮圖形介面，對應 macOS 版 `lzfse-ui.swift`。
A SwiftCrossUI (WinUIBackend) GUI for LZFSE compression/decompression, the Windows
counterpart of the macOS `lzfse-ui.swift`.

- UI 原始碼 / UI source: `lzfse-ui-win.swift`
- 建置腳本 / Build script: `build-win.sh`
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

`build-win.sh` 會在 `lzfse-ui/` 產出 `LZFSE_UI_Win.zip`，內含：
`build-win.sh` produces `LZFSE_UI_Win.zip` in `lzfse-ui/`, containing:

```
LZFSE_UI_Win/
├─ LZFSE_UI_Win.exe                                          # 主程式 / the app
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
./build-win.sh
```

**建置需求 / Build requirements**：
- **Git for Windows（提供 Git Bash）** / **Git for Windows (provides Git Bash)**
  `build-win.sh` 是 bash 腳本，須在 **Git Bash** 中執行。Git for Windows 已內建本腳本所需的
  `bash`、`grep`、`sed`、`tar`（bsdtar）等工具，**無需另外安裝**（路徑轉換用 `sed`，不依賴 `cygpath`）。
  下載 / Download: <https://gitforwindows.org>
  `build-win.sh` is a bash script and must run in **Git Bash**. Git for Windows bundles the
  `bash`, `grep`, `sed` and `tar` (bsdtar) the script needs — **no separate install required**
  (path conversion uses `sed`, not `cygpath`).
- Swift for Windows 工具鏈（已驗證 6.3.2，x86_64-windows-msvc）/ toolchain (verified 6.3.2)
- Visual Studio Build Tools（C++ 工作負載）+ Windows 10/11 SDK
- PowerShell（Windows 內建，用於 `Compress-Archive` 打包）/ PowerShell (built into Windows, used for `Compress-Archive`)
- 首次建置由 SwiftPM 自動拉取 `moreSwift/swift-cross-ui` v0.7.0 及其相依（需網路）
  the first build fetches `moreSwift/swift-cross-ui` v0.7.0 and dependencies (needs network)

建置流程 / The script will：
1. 以 `grep -v '^runCLI()$'` 將 `../lzfse-cli.swift` 當函式庫編入 / strip `runCLI()` and import the codec as a library
2. `swift build -c release`（log 寫入 `.win-build/build.log`）
3. 打包 exe + 必要執行檔成 `LZFSE_UI_Win.zip` 複製到 `lzfse-ui/` / package into the zip in `lzfse-ui/`

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

As of the current Windows UI round:

- `build-win.sh` builds the SwiftCrossUI app, then runs `helper_windows/compile.bat` to build a fresh companion CLI.
- `build-win.sh` also embeds the Windows app icon into `LZFSE_UI_Win.exe`: it uses the same `AppIcon.png` source image as the macOS app, generates `.win-build/AppIcon.ico`, compiles `.win-build/AppIcon.res` with `llvm-rc.exe`, and links that resource into the exe. File Explorer and the Windows taskbar should therefore show the LZFSE UI icon. If Windows still shows an old/default icon, use a fresh extraction folder or restart Explorer to clear the icon cache.
- The final `LZFSE_UI_Win.zip` contains:

  ```text
  LZFSE_UI_Win/
  |-- LZFSE_UI_Win.exe
  |-- lzfse.exe
  |-- SwiftJava.dll
  `-- swift-winui_CWinAppSDK.resources/
      `-- Microsoft.WindowsAppRuntime.Bootstrap.dll
  ```

- UI decompression runs the same binary-safe command shown in **Equivalent Command** instead of using the internal Swift/UI pipe path.
- The command is executed with the working directory set to the folder containing `LZFSE_UI_Win.exe`, so `.\lzfse.exe` resolves to the packaged CLI in the same folder.
- This avoids Windows PowerShell corrupting binary tar streams when piping `-so` directly.
- Before extraction, the UI lists the tar entries. If they start with `../`, the UI automatically adds `--strip-components 1` during extraction. This handles archives such as `../claw-code/...` that Windows bsdtar otherwise rejects with `Path contains '..'`.

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

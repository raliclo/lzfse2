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

## Windows-specific behaviour / Windows 專屬行為

這一節記錄的是 Windows 版**目前的行為**，不是某一輪的進度。原本的寫法是
「As of the 2026-07-07 status」加上一串「now exposes」「currently pins」——那是對某個
讀者看不見的舊狀態所做的差異描述，時間一過就無法判讀。輪次記帳已移出，見本節末。

This section records how the Windows build **currently behaves**. It used to be framed
as a dated status list full of "now exposes" and "currently pins" — diffs against a state
no reader can see. The round bookkeeping has been moved out; see the end of this section.

- `build-win.zsh` 建置 SwiftCrossUI app，接著執行 `helper_windows/compile.bat` 產生
  隨附的 CLI。/ Builds the SwiftCrossUI app, then builds the companion CLI.
- SwiftCrossUI 相依項釘在 `https://github.com/raliclo/swift-cross-ui.git` 的 `develop`
  分支。/ The SwiftCrossUI dependency is pinned to the `develop` branch.
- Windows app icon 由與 macOS 版相同的 `AppIcon.png` 產生：先做出
  `.win-build/AppIcon.ico`，以 `llvm-rc.exe` 編成 `.win-build/AppIcon.res`，再連結進
  exe。若檔案總管仍顯示舊圖示，換一個全新的解壓資料夾或重啟 Explorer 以清除圖示快取。
- Other3 編碼模式下提供 `Optimal3 Parsing / 標準格式最優解析`，等效命令為
  `-algo other3 -optimal3`，輸出仍是標準 Apple-compatible LZFSE。
- `Reset / 重置` 與 `Compress / Decompress` 位於 `Files / 檔案` 標題列右側。
- 最終的 `LZFSE_UI_Win.zip` 寫入 `lzfse-ui/release/`，內容為：

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
**量測結果不記在這裡。** `OPTIMIZATION.md` 是每一輪的記錄所在，本檔只說明產出物在哪：
`helper_windows/run_round.bat` 由 `helper_windows/` 執行，CSV 落在
`helper_windows/bench_results_csv/`（`encode_summary.csv`、`decode_summary.csv`、
`rss_summary.csv` 為單標頭 `.csv`；`BenchMarkResult-Win.csv2` 與 `comparison.csv2` 為
雙標頭 `.csv2`，須以 `csv2` 讀寫），log 落在 `helper_windows/bench_logs/`，進度寫入
`helper_windows/windows_round_status.txt`。

先前此處列有 R42-Win 的完成日期與逐項結果，那與 `OPTIMIZATION.md` 重複——而該段自己
就寫著「R42-Win details ... are recorded in OPTIMIZATION.md」。兩份記錄同一件事必然漂移，
且此處那一份沒有跟上：五個 CSV 中有兩個早已改名為 `.csv2`。

Measurements are not recorded here; `OPTIMIZATION.md` is where each round lives. This
file only says where the artifacts land. The previous version duplicated R42-Win's
results while itself pointing at `OPTIMIZATION.md` for them, and had already drifted —
two of the five CSVs became `.csv2` and this list still called them `.csv`.

Equivalent decode command pattern:

```powershell
cmd /d /c ".\lzfse.exe -decode -i ""C:/path/input.lzfse"" -n 8 -so | tar -xf - -C ""C:/path/output-folder"""
```

Manual command for archives whose entries start with `../`:

```powershell
cmd /d /c ".\lzfse.exe -decode -i ""C:/path/input.lzfse"" -n 8 -so | tar -xf - --strip-components 1 -C ""C:/path/output-folder"""
```

兩則關於 `helper_windows/` 的約定，記在此處是因為 Windows 的東西都聚在這一頁，但它們
管的是**那個目錄**，不是本子專案：

- `run_round.bat` 不經 PowerShell `Tee-Object` 輸出摘要，改以暫存 log 加
  `type >> windows_round_status.txt` 寫入，避免混合編碼的狀態檔。（已查證：該檔目前
  `Tee-Object` 出現 0 次。）
- 專案自有的 `.bat` 一律為 CRLF。**理由不是 cmd.exe 要求 CRLF——純 LF 的批次檔可以正常
  執行**；真正會壞的是**同一個檔案內混用**兩種行尾，那會讓 cmd.exe 誤判 `if (...)` 區塊。
  維持整檔一致才是重點。（已查證：八個 `.bat` 的 CR 數與行數相等，即每行皆為 CRLF。）

Two conventions that govern `helper_windows/`, not this subproject; they live here only
because the Windows material is collected on this page. The CRLF rule is about internal
consistency, not a cmd.exe requirement — a pure-LF batch file runs fine, whereas mixing
both endings inside one file makes cmd.exe misparse an enclosing `if (...)` block.

# lzfse2

[English](README.md) | 繁體中文

`lzfse2` 是以 Swift 實作的 LZFSE 命令列壓縮／解壓工具。它包含位元相容、多核心的編碼器與解碼器，也提供可選的私有 `bvx3` 格式以換取更高壓縮率。

## 功能

- `other3` 是預設引擎，輸出標準 LZFSE 串流，可由 Apple Compression 與本工具解碼。
- `other3 -optimal3` 是標準 LZFSE 格式的 DP 最優解析模式；壓縮率比一般 `other3` 更好，輸出仍維持 Apple 相容。
- `apple` 在可用時使用 Apple `COMPRESSION_LZFSE` 實作。
- `bvx3` 使用私有擴充區塊，具備較大的視窗與字母表。壓縮率可能更好，但只有本工具能解碼。
- `bvx3 -lazy2` 與 `bvx3 -optimal` 是私有格式的高壓縮率 parser 模式，適合壓縮率優先的離線壓縮。
- 解碼器接受所有支援的區塊型別，包含 Apple 產生的 LZFSE 串流。
- 支援檔案、stdin/stdout 串流，以及內建往返與相容性測試。

## 建置

直接使用 Swift 編譯：

```sh
swiftc -O lzfse-cli.swift -o lzfse
```

`-O` 旗標啟用優化，包含 `@inline(__always)` 指令，改善熱點路徑效能（FSE 編碼、位元組序列化、解碼）。詳見 [OPTIMIZATION.md](OPTIMIZATION.md)。

或執行輔助腳本：

```sh
./compile.zsh
```

`compile.zsh` 也會將二進位檔複製到 `/opt/homebrew/bin`，因此該步驟可能需要本機寫入權限。

## macOS 圖形介面（LZFSE_UI）

macOS 版 UI 使用 SwiftUI，位於 `lzfse-ui/lzfse-ui.swift`，與 CLI 共用同一份 `lzfse-cli.swift` codec。

**建置：**

```sh
cd lzfse-ui
./build-ui.zsh
open "LZFSE_UI.app"
```

`build-ui.zsh` 會從 `AppIcon.png` 產生 `AppIcon.icns`，放入 app bundle 並設定 `CFBundleIconFile=AppIcon`。手動編譯範例：

```sh
swiftc -O ../lzfse-cli.swift lzfse-ui.swift \
  -framework SwiftUI -target arm64-apple-macos13.0
```

macOS UI 目前提供 Apple / Other3 / BVX3，並支援：

- Other3：`Optimal3 / 最優解析` → equivalent command 為 `-algo other3 -optimal3`
- BVX3：`Lazy2` / `Optimal`
- 檔案與資料夾壓縮、lzfseX tar stream 解包、Equivalent Command 顯示
- 按下 Compress / Decompress 後，Status 會立即顯示 `Compressing... / 壓縮中...` 或 `Decompressing... / 解壓縮中...`

## Windows 圖形介面（LZFSE_UI_Win）

以 SwiftCrossUI（WinUIBackend）打造的 Windows 圖形前端，對應 macOS 的 `lzfse-ui/lzfse-ui.swift`。它連結同一份 codec，並隨附 `lzfse.exe`。

**建置**（需 Git for Windows、Swift for Windows 6.3.2、VS Build Tools + Windows SDK）：

```sh
cd lzfse-ui
./build-win.zsh            # 或在檔案總管按兩下 build-win.bat
# → lzfse-ui/release/LZFSE_UI_Win.zip （GUI app + 隨附 lzfse.exe）
```

目前 Windows UI/build 的重點：

- `build-win.zsh` 會先建置 SwiftCrossUI app，再執行 `helper_windows/compile.bat` 取得最新 `lzfse.exe`，並打包進 `LZFSE_UI_Win.zip`。
- SwiftCrossUI dependency 目前使用 `https://github.com/raliclo/swift-cross-ui.git` 的 `develop` branch，以取得新的 folder selection API。
- Windows 版資料夾選擇已改用 SwiftCrossUI `chooseFile(... allowSelectingFiles: false, allowSelectingDirectories: true)`，由 WinUIBackend 的 `FolderPicker` 處理；不再使用自製 `SHBrowseForFolderW` helper。
- UI 提供 `Optimal3 / 最優解析`（`-algo other3 -optimal3`）、BVX3 Lazy2 / Optimal、Equivalent Command、封裝的 `.\lzfse.exe` 解包命令。
- `Reset / 重置` 與 Compress / Decompress 按鈕已移到 `Files / 檔案` 標題列右側，以降低視窗高度需求。
- 按下 Compress / Decompress 後，Status 會立即顯示進行中狀態。
- Windows exe/taskbar/File Explorer icon 使用與 macOS 相同的 `AppIcon.png` 來源。

**自包含 CLI 包**（`lzfse.exe` + Swift runtime DLL，免裝 Swift 即可執行）：

```sh
cd helper_windows
./build-cli-win.zsh        # 或按兩下 build-cli-win.bat
# → helper_windows/release/lzfse-cli.zip
```

**執行需求：** GUI 需安裝 **Windows App SDK 1.5 runtime（含 DDLM 套件）**，否則無法啟動（exit 132）。DDLM 安裝、功能與疑難排解詳見 [lzfse-ui/README-UI-Win.md](lzfse-ui/README-UI-Win.md)。

## 用法

```sh
./lzfse -h
```

```text
Usage: lzfse -encode|-decode [-algo apple|other3|bvx3] [-lazy2|-optimal|-optimal3] [-si|-i input] [-so|-o output] [-test] [-h]
```

使用預設 `other3` 引擎壓縮檔案：

```sh
./lzfse -encode -i input_file -o output_file.lzfse
```

指定引擎壓縮：

```sh
./lzfse -encode -algo apple -i input_file -o output_file.lzfse.apple
./lzfse -encode -algo bvx3 -i input_file -o output_file.lzfse.bvx3
```

使用標準 LZFSE 格式的 Optimal3 parser（Apple 相容，但壓縮較慢）：

```sh
./lzfse -encode -algo other3 -optimal3 -i input_file -o output_file.lzfse.other3.optimal3
```

使用 `bvx3` 較高壓縮率 parser 模式壓縮 tar 串流：

```sh
tar -cf - input_dir | ./lzfse -encode -si -o input_dir.lazy2.lzfse -algo bvx3 -lazy2
tar -cf - input_dir | ./lzfse -encode -si -o input_dir.optimal.lzfse -algo bvx3 -optimal
```

解壓檔案：

```sh
./lzfse -decode -i input_file.lzfse -o output_file
```

解壓 `bvx3` 產物：

```sh
./lzfse -decode -i file.lzfse -o out.tar -algo bvx3
```

同一個工具內建解碼路徑也能解 `-algo apple` 或 Apple Compression 產生的標準 LZFSE 串流：

```sh
./lzfse -decode -i file.lzfse.apple -o out.tar -algo bvx3
```

透過 stdin/stdout 串流處理：

```sh
cat input_file | ./lzfse -encode -si -so > output_file.lzfse
./lzfse -decode -i input_file.lzfse -so > output_file
```

`-optimal3` 只是 **other3 encoder 的 parser / match selection 模式**。它使用 DP 最優解析改善壓縮比，但輸出仍是標準 LZFSE / bvx2 bitstream，因此解壓端與一般 `other3` 相同，不需要加 `-optimal3`：

```bash
./lzfse -encode -i a.tar -o a.lzfse.other3.optimal3 -algo other3 -optimal3
./lzfse -decode -i a.lzfse.other3.optimal3 -so
```

`-lazy2` 和 `-optimal` 只是 **bvx3 encoder 的 parser / match selection 模式**，不改 `bvx3` bitstream 格式。壓出來的檔案仍是 `bvx3` 私有格式，所以解壓時只需要指定 `-algo bvx3`：

```bash
./lzfse -decode -i file.lzfse -o out.tar -algo bvx3
```

也就是：

```bash
./lzfse -encode -si -o a.lazy2.lzfse -algo bvx3 -lazy2
./lzfse -decode -i a.lazy2.lzfse -so -algo bvx3
```

```bash
./lzfse -encode -si -o a.optimal.lzfse -algo bvx3 -optimal
./lzfse -decode -i a.optimal.lzfse -so -algo bvx3
```

解壓端不需要、也不應該加 `-lazy2` 或 `-optimal`。這兩個 flag 對 decode 沒有格式意義。

### Windows PowerShell tar 解包注意事項

不要在 Windows PowerShell 直接使用 `.\lzfse.exe -decode -so | tar ...`，PowerShell 可能把 binary stdout 當文字管線處理而破壞 tar stream。請改用 `cmd /d /c` 讓 binary pipe 由 `cmd.exe` 處理：

```powershell
cmd /d /c ".\lzfse.exe -decode -i ""C:/path/input.lzfse"" -n 8 -so | tar -xf - -C ""C:/path/output-folder"""
```

若封存是用父層相對路徑建立，內容路徑可能是 `../name/...`；Windows bsdtar 會因安全檢查回報 `Path contains '..'`。這種情況請在解包時移除最前面的 `..` path component：

```powershell
cmd /d /c ".\lzfse.exe -decode -i ""C:/path/input.lzfse"" -n 8 -so | tar -xf - --strip-components 1 -C ""C:/path/output-folder"""
```

### 解壓 tar 封存至目錄 / Decode tar archive to directory

```sh
# 正常解壓 / Normal decode
lzfse -decode -i file.lzfse -so | tar -xf - -C /dest

# Debug 模式：overshoot / block 失敗時印詳細資訊到 stderr
# Debug mode: prints overshoot / block failure details to stderr
lzfse -decode -i file.lzfse -debug -so 2>debug/decode_debug.txt | tar -xf - -C /dest
```

執行內建測試：

```sh
./lzfse -test
```

## 引擎

| 引擎 | 輸出相容性 | 說明 |
| --- | --- | --- |
| `other3` | 標準 LZFSE | 預設。多核心、lazy matching，輸出可由 Apple 解碼。 |
| `other3 -optimal3` | 標準 LZFSE | 標準格式內的 DP 最優解析；壓縮比優於 Other3，但 encode 較慢、RSS 較高。 |
| `apple` | 標準 LZFSE | 使用 Apple Compression framework。 |
| `bvx3` | 本工具私有格式 | 較大的視窗與字母表可提升壓縮率；Apple 無法解碼。 |

`other3 -optimal3` 的定位是「標準相容格式內能做到的 optimal parse」。它不等同於 `bvx3 -optimal`：後者使用私有 bvx3 `encodeBlockV3`、更大的 match 長度與距離表達能力，因此壓縮比仍可明顯優於 Optimal3，但不具 Apple 相容性。

`bvx3` 編碼時，`-lazy2` 與 `-optimal` 會選擇較慢但可能提升壓縮率的 parser 模式。它們不會建立不同的解碼格式；一般 `bvx3`、`bvx3 -lazy2`、`bvx3 -optimal` 產物都使用 `-algo bvx3` 解碼。

解碼時，`-algo other3` 與 `-algo bvx3` 使用同一個內建區塊解碼器。這個解碼器接受所有支援的 LZFSE 區塊型別，包含 `-algo apple` 或 Apple Compression 產生的標準串流。`-algo apple` 則會改用 Apple framework decoder。


## zsh 輔助函式

此儲存庫包含一段 `zshrc` 範例，可將目錄先打包為 `tar` 串流，再交給本工具壓縮。

```zsh
# 解壓常見封存格式。
extract () {
    if [ -f "$1" ] ; then
        case "$1" in
            *.lzfse.other3.optimal3) echo "lzfse -decode -i $1 -so -algo other3 | tar -xf - " ; lzfse -decode -i "$1" -so -algo other3 | tar -xf - ;;
            *.lzfse.bvx3.optimal)   echo "lzfse -decode -i $1 -so -algo bvx3   | tar -xf - " ; lzfse -decode -i "$1" -so -algo bvx3   | tar -xf - ;;
            *.lzfse.bvx3.lazy2)     echo "lzfse -decode -i $1 -so -algo bvx3   | tar -xf - " ; lzfse -decode -i "$1" -so -algo bvx3   | tar -xf - ;;
            *.lzfse.bvx3)      echo "lzfse -decode -i $1 -so -algo bvx3   | tar -xf - " ; lzfse -decode -i $1 -so -algo bvx3   | tar -xf -  ;;
            *.lzfse.other3)    echo "lzfse -decode -i $1 -so -algo other3 | tar -xf - " ; lzfse -decode -i $1 -so -algo other3 | tar -xf -  ;;
            *.lzfse.apple)     echo "lzfse -decode -i $1 -so -algo apple  | tar -xf - " ; lzfse -decode -i $1 -so -algo apple  | tar -xf -  ;;
            *.tar.lz4)         lz4 -T0 -d -q -c "$1" | tar -xf - ;;
            *.zst)             zstd -d -c "$1" | tar -xf - ;;
            *.tar.xz)          tar xf "$1" ;;
            *.tar.bz2)         tar xjf "$1" ;;
            *.tar.gz|*.tgz)    tar xzf "$1" ;;
            *.bz2)             bunzip2 "$1" ;;
            *.rar)             unrar e "$1" ;;
            *.gz)              gunzip "$1" ;;
            *.tar)             tar xf "$1" ;;
            *.tbz2)            tar xjf "$1" ;;
            *.zip)             unzip "$1" ;;
            *.Z)               uncompress "$1" ;;
            *.xz)              xz -d "$1" ;;
            *.7z)              7z x "$1" ;;
            *.lz4)             unlz4 "$1" ;;
            *.lzma)            tar --lzma -xvf "$1" ;;
            *.lz4a)            unlz4a "$1" ;;
            *)                 echo "'$1' cannot be extracted via extract()" ;;
        esac
    else
        echo "'$1' is not a valid file"
    fi
}

# 將檔案或目錄打成 tar 串流後，以 LZFSE 壓縮。
lzfseX() {
    if [[ -z "$1" ]]; then
        echo "Usage: lzfseX <file-or-directory> [apple|other3|optimal3|bvx3|lazy2|optimal]"
        return 1
    fi

    local algo="${2:-other3}"
    local extension="lzfse.other3"
    local flags=("-algo" "$algo")
    [[ "$algo" == "apple" ]] && extension="lzfse.apple"
    [[ "$algo" == "bvx3" ]] && extension="lzfse.bvx3"
    [[ "$algo" == "other3" ]] && extension="lzfse.other3"
    [[ "$algo" == "optimal3" ]] && extension="lzfse.other3.optimal3" && flags=("-algo" "other3" "-optimal3")
    [[ "$algo" == "lazy2" ]] && extension="lzfse.bvx3.lazy2" && flags=("-algo" "bvx3" "-lazy2")
    [[ "$algo" == "optimal" ]] && extension="lzfse.bvx3.optimal" && flags=("-algo" "bvx3" "-optimal")

    echo tar -cf - -C "$(dirname "$1")" "$(basename "$1")" "|" lzfse -encode -si -o "$1.$extension" "${flags[@]}"
    tar -cf - -C "$(dirname "$1")" "$(basename "$1")" | lzfse -encode -si -o "$1.$extension" "${flags[@]}"

    echo "--- 壓縮資訊 ---"
    du -sh "$1"
    du -sh "$1.$extension"
}
```

編輯後重新載入 shell：

```sh
source ~/.zshrc
```
## powermetrics

修改步驟
開啟 visudo：
```
sudo EDITOR=nano visudo
```

新增一行如下：
```
raliclo ALL=(ALL) NOPASSWD: /usr/bin/powermetrics, /usr/bin/true, /Users/raliclo/proj/lzfse2/benchmark.zsh, /Users/raliclo/proj/lzfse2/benchmark2.zsh, /Users/raliclo/proj/lzfse2/run_round.command, /Users/raliclo/proj/lzfse2/helper/reboot.command,/Users/raliclo/proj/lzfse2/gitOwner.sh
```

儲存並離開（同樣按下 Ctrl + O -> Enter -> Ctrl + X）。

## 基準測試

最新測試使用 `claw-code`（約 1351 MiB）與 `llama.cpp`（約 1385 MiB）兩組資料集，兩個數字皆取自 `BenchMarkResult.csv2` 的 `raw_size_mib` 欄。測試機器為 Mac mini，配備 Apple M4 10 核心 CPU、16 GB 記憶體與 256 GB 儲存空間。完整逐點資料位於 [`BenchMarkResult.csv2`](BenchMarkResult.csv2)，跨 n4 / n8 / n40 的最佳／最差點整理位於 [`best_points/best_points.md`](best_points/best_points.md)。

Windows round 已補齊 `other3 -optimal3`，Windows 結果位於 [`helper_windows/bench_results_csv/BenchMarkResult-Win.csv2`](helper_windows/bench_results_csv/BenchMarkResult-Win.csv2)，跨平台合併比較位於 [`helper_windows/bench_results_csv/comparison.csv2`](helper_windows/bench_results_csv/comparison.csv2)。Windows 本輪 `-n 40` 表示單次 inflight chunk count；macOS `n=40` 是 40 次平均，兩者的測試語意不同，尤其 decode 寫檔路徑會受到 NTFS / bsdtar / file creation 成本影響。

### 一輪需時多久 / How long a round takes

**完整一輪約 1.5–2 小時。** 自動化工具（含 LLM agent）若以逾時包裝執行，逾時值必須涵蓋整段時間，否則會在中途被中止而白費——這已實際發生過一次。更穩妥的做法是讓它脫離工具的生命週期執行（Windows 用 `Start-Process`，macOS 用 `nohup`），再以狀態檔判斷完成，而非等程序結束。

A full round takes roughly 1.5 to 2 hours. Any automation that wraps it in a
timeout must cover the whole span, or the round is killed partway and the time
is wasted -- which has happened. Safer still is to detach it from the tool's
lifecycle (`Start-Process` on Windows, `nohup` on macOS) and judge completion
from the status file rather than from process exit.

Windows（`helper_windows/run_round.bat -swift_tar`，2026-08-15 實測，n=40，Ryzen 5 7535HS）：

| 階段 | claw-code（1.4 GB 單一大檔） | llama.cpp（40,675 個小檔） |
|---|---:|---:|
| encode nul | 4m23s | 14m41s |
| encode write | 3m18s | 4m02s |
| decode nul | 1m15s | 2m28s |
| decode write | 12m42s | **44m+**（含解壓樹逐檔驗證） |
| rss nul | 4m25s | ~4m |
| rss write | 4m07s | ~4m |
| 小計 | **約 30m** | **約 73m** |

外加 `system-info-win.bat` 約 1m34s、前後兩次 `git gc`、以及收尾的 `summarize_win.py` 與 `comparison_win.py`。

最耗時的單一階段是 **llama.cpp 的 decode write**：40,675 個小檔逐一落盤後還要逐檔比對解壓樹，佔整輪約一半時間。它也是最容易讓人誤判為卡住的階段——期間狀態檔會長時間沒有新的 `[INFO] Running` 行。

macOS（`run_round.command -full`）另含 powermetrics 功耗量測與 Time Profiler trace，且 `-n` 掃 40/8/4 三組，因此更久；`claude_test_sample_script.zsh` 的說明以 1–2 小時為準。

The single longest phase is llama.cpp's decode-write, which writes 40,675 small
files and then compares the extracted tree file by file -- about half the round.
It is also the phase most easily mistaken for a hang, since no new
`[INFO] Running` line appears in the status file for a long stretch. The macOS
round additionally collects powermetrics energy figures and Time Profiler
traces, and sweeps `-n` over 40/8/4, so it runs longer.

### 測試機硬體比較

Windows 資訊由 [`helper_windows/system-info-win.bat`](helper_windows/system-info-win.bat) 產生，原始 log 位於 [`helper_windows/bench_logs/system-info.txt`](helper_windows/bench_logs/system-info.txt)，時間戳記為 `2026-07-05 18:06:28`。Mac 欄位依本輪 README / benchmark 記錄；未在 log 中保存的細節以「未記錄」標示。

| 項目 | macOS 測試機 | Windows 測試機 |
| --- | --- | --- |
| 系統 / 機型 | Mac mini | ASUS TUF Gaming A15 `FA507NV_FA507NV` |
| CPU | Apple M4 | AMD Ryzen 5 7535HS with Radeon Graphics |
| CPU cores / threads | 10 cores（thread 數未記錄；Apple Silicon 為核心數配置） | 6 cores / 12 threads |
| CPU frequency | 未記錄於本輪 README；Apple Silicon 動態頻率 | Max clock 3301 MHz |
| CPU cache | 未記錄 | L2 3072 KB；L3 16384 KB |
| 記憶體 | 16 GB unified memory | 31.25 GB total；2×16 GB DDR5 SO-DIMM，模組速度 5600 MT/s，configured 4800 MT/s |
| GPU | Apple M4 integrated GPU（核心數未記錄） | AMD Radeon(TM) Graphics（WMI VRAM 512 MB）+ NVIDIA GeForce RTX 4060 Laptop GPU（nvidia-smi: 8188 MiB） |
| Storage | 256 GB internal storage | Micron `MTFDKBA512QGN-1BN1AABGA` NVMe SSD，476.94 GB，Healthy |

### Mac / Windows 效能對照（n=40，Win 側 R47-Win、Mac 側 R50-Mac）

下表每一格都取自 [`comparison.csv2`](helper_windows/bench_results_csv/comparison.csv2)，不是手抄的。標題不再寫死輪次，因為該檔會被每一輪重寫而標題不會——舊標題曾寫「R42」，Mac 側其實已落後八輪。Win 側數字可在 `OPTIMIZATION.md` 的 R47-Win 一節逐格對上。

重建方式（勿手動編輯下表；`note` 欄含引號內逗號，`awk -F,`／`cut -d,` 會靜默切錯並讓其右每欄左移一格）：

```zsh
csv2 -get <記錄>:<欄> -i helper_windows/bench_results_csv/comparison.csv2
# 記錄 2/3/4/6 = llama.cpp 的 Other3/Optimal3/BVX3/Optimal
# 記錄 10/11/12/14 = claw-code 的同四項
```

壓縮比以 TGZ 為 1.0000；數值越低代表檔案越小。Decode 為 write-to-file / tar extract 路徑，因此更接近 UI 實際解包體驗。

| 資料集 | 格式 | Win Enc MB/s | Mac Enc MB/s | Win/Mac Enc | Win Dec MB/s | Mac Dec MB/s | Win/Mac Dec | Win 比率 | Mac 比率 | Verify |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| claw-code | Other3 | 184.55 | 592.21 | 0.312 | 146.68 | 861.07 | 0.170 | 0.9812 | 0.9813 | PASS |
| claw-code | **Optimal3** | **33.22** | **67.01** | **0.496** | **142.50** | **946.06** | **0.151** | **0.9344** | **0.9346** | PASS |
| claw-code | BVX3 | 200.90 | 495.56 | 0.405 | 131.84 | 907.34 | 0.145 | 0.9243 | 0.9248 | PASS |
| claw-code | Optimal | 18.11 | 35.74 | 0.507 | 145.82 | 860.96 | 0.169 | 0.8252 | 0.8257 | PASS |
| llama.cpp | Other3 | 65.90 | 236.74 | 0.278 | 30.34 | 154.66 | 0.196 | 0.9966 | 0.9971 | PASS |
| llama.cpp | **Optimal3** | **42.42** | **83.19** | **0.510** | **30.02** | **114.88** | **0.261** | **0.9739** | **0.9705** | PASS |
| llama.cpp | BVX3 | 64.91 | 254.72 | 0.255 | 29.94 | 137.48 | 0.218 | 0.9792 | 0.9796 | PASS |
| llama.cpp | Optimal | 33.20 | 58.25 | 0.570 | 29.75 | 144.23 | 0.206 | 0.9390 | 0.9347 | PASS |

重點：

- `other3 -optimal3` 在 Windows 與 macOS 都通過 decode verify，輸出仍是標準 Apple-compatible LZFSE。
- `claw-code` 上 Optimal3 相對 Other3 壓縮比改善約 4.77%（Windows：0.9812 → 0.9344），但 encode 速度約為 Other3 的 18.0%。
- `llama.cpp` 上 Optimal3 改善較小，約 2.28%（Windows：0.9966 → 0.9739）。**Windows encode 約為 Mac 的一半（Win/Mac 0.510）**——此處先前寫的是「與 Mac 幾乎相同（1.03×）」，那是抄自更早一輪的數字而未隨 `comparison.csv2` 更新，結論方向與實測相反。
- Windows decode write-to-file 明顯慢於 macOS（八列落在 0.145–0.261×），主要反映 Windows tar extraction / NTFS file creation 路徑，不代表 LZFSE decode core 單獨差距。
- 每列的 `Windows n meaning` 皆為 `inflight=40 (1 run)`——**單次量測**。本樹已有六次「差異在交錯重量後消失」的紀錄（+81%、+21%、+9.5%、+13.6%、−10.7%、+22.4%），故上表適合用於數量級與方向，不適合用於精確的跨平台比值。
- 若目標是最高壓縮率，`bvx3 -optimal` 仍優於 Optimal3；若目標是 Apple/標準 LZFSE 相容，Optimal3 是目前標準格式內的高壓縮率模式。

以下長表來自既有 best-points 分析，用於保留完整 Mac RSS / CPU energy 脈絡；R42 `Optimal3` 的跨平台重點已列於上方表格，完整細節請見 [`OPTIMIZATION.md`](OPTIMIZATION.md) 的 R42-Mac / R42-Win 章節。`log nX` 只表示 TGZ、Apple、TLZ4、ZSTD 的來源 log 批次，`-n` 不影響這些外部算法。Energy Ratio 以同輪、同資料集 TGZ CPU energy 為 `1.0000`；小於 1 代表比 TGZ 省 CPU energy，大於 1 代表較耗能。

### 最新最佳點摘要

以下兩表由 [`best_points/best_points.md`](best_points/best_points.md) 投影而來，而該檔本身由 `BenchMarkResult.csv2` 產生——**請勿手動編輯**。此處的 8 欄是該檔 22 欄的子集：

```zsh
csv2 -get <記錄>:<欄> --md-table 1 -i best_points/best_points.md   # claw-code
csv2 -get <記錄>:<欄> --md-table 2 -i best_points/best_points.md   # llama.cpp
# 欄 1 格式、2 最佳壓縮比、3 最佳壓縮 MB/s、5 最佳解壓 MB/s、
#    7/8 Encode RSS 低/高、9/10 Decode RSS、19/20 與 21/22 為兩組 energy ratio
```

先前手抄的版本**整整漏掉 Optimal3 與 Apple 兩列**，且有損毀的格子——英文版的 `1838` 是 decode energy ratio 被寫壞，`0.5 (950 \`n4\`)` 則是 `0.5950` 被括號切成兩半（中文版此格正確）。

#### claw-code

| 格式 | 最佳壓縮比 | 最佳壓縮 MB/s | 最佳解壓 MB/s | Encode RSS 範圍 | Decode RSS 範圍 | Encode Energy Ratio 範圍 | Decode Energy Ratio 範圍 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 1.0000 (`log n4`) | 325.34 (`log n8`) | 608.24 (`log n8`) | 162.9 MB (`log n40`)–174.4 MB (`log n4`) | 41.8 MB (`log n8`)–42.1 MB (`log n4`) | 1.0000 (log n4)–1.0000 (log n4) | 1.0000 (log n4)–1.0000 (log n4) |
| Other3 | 0.9813 (`n4`) | 592.21 (`n40`) | 925.87 (`n8`) | 136.6 MB (`n4`)–353.9 MB (`n40`) | 65.9 MB (`n4`)–315.7 MB (`n40`) | 0.4423 (n40)–0.7260 (n4) | 0.6571 (n40)–1.0619 (n4) |
| Optimal3 | 0.9346 (`n4`) | 67.01 (`n40`) | 946.06 (`n40`) | 217.7 MB (`n4`)–563.8 MB (`n40`) | 69.7 MB (`n4`)–321.5 MB (`n40`) | 5.2464 (n40)–7.4107 (n4) | 0.5644 (n40)–0.9250 (n4) |
| BVX3 | 0.9248 (`n4`) | 575.39 (`n8`) | 907.34 (`n40`) | 125.6 MB (`n4`)–373.8 MB (`n40`) | 68.0 MB (`n4`)–316.1 MB (`n40`) | 0.4111 (n40)–0.7230 (n4) | 0.7620 (n40)–1.3296 (n4) |
| Lazy2 | 0.8690 (`n4`) | 68.72 (`n40`) | 922.35 (`n40`) | 195.1 MB (`n4`)–508.2 MB (`n40`) | 66.5 MB (`n4`)–328.8 MB (`n40`) | 1.6819 (n40)–2.2284 (n4) | 0.6688 (n40)–1.2055 (n4) |
| Optimal | 0.8257 (`n4`) | 35.74 (`n40`) | 860.96 (`n40`) | 220.3 MB (`n4`)–589.3 MB (`n40`) | 70.3 MB (`n4`)–334.1 MB (`n40`) | 7.3220 (n40)–10.0002 (n4) | 0.8181 (n40)–1.2723 (n4) |
| Apple | 0.9820 (`log n4`) | 154.08 (`log n8`) | 892.34 (`log n40`) | 1259.3 MB (`log n8`)–1356.5 MB (`log n40`) | 470.2 MB (`log n4`)–470.2 MB (`log n4`) | 0.6661 (log n8)–0.6832 (log n4) | 0.4851 (log n40)–0.5345 (log n8) |
| TLZ4 | 1.1785 (`log n4`) | 616.63 (`log n8`) | 1274.57 (`log n4`) | 82.4 MB (`log n8`)–83.3 MB (`log n4`) | 34.0 MB (`log n4`)–34.0 MB (`log n4`) | 0.4340 (log n4)–0.4340 (log n4) | 0.1473 (log n4)–0.1473 (log n4) |
| ZSTD | 0.8165 (`log n4`) | 529.83 (`log n8`) | 789.08 (`log n8`) | 394.8 MB (`log n40`)–397.5 MB (`log n8`) | 1145.1 MB (`log n8`)–1364.1 MB (`log n40`) | 0.5971 (log n4)–0.5971 (log n4) | 0.4073 (log n4)–0.4073 (log n4) |

#### llama.cpp

| 格式 | 最佳壓縮比 | 最佳壓縮 MB/s | 最佳解壓 MB/s | Encode RSS 範圍 | Decode RSS 範圍 | Encode Energy Ratio 範圍 | Decode Energy Ratio 範圍 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 1.0000 (`log n4`) | 347.60 (`log n40`) | 434.81 (`log n40`) | 161.7 MB (`log n40`)–178.2 MB (`log n4`) | 39.3 MB (`log n4`)–42.8 MB (`log n8`) | 1.0000 (log n4)–1.0000 (log n4) | 1.0000 (log n4)–1.0000 (log n4) |
| Other3 | 0.9971 (`n4`) | 409.11 (`n40`) | 459.39 (`n8`) | 141.6 MB (`n4`)–271.6 MB (`n40`) | 74.9 MB (`n4`)–349.8 MB (`n40`) | 0.4007 (n40)–0.6847 (n4) | 0.5044 (n40)–0.9154 (n4) |
| Optimal3 | 0.9705 (`n4`) | 83.36 (`n40`) | 499.02 (`n8`) | 204.7 MB (`n4`)–555.9 MB (`n40`) | 67.1 MB (`n4`)–349.5 MB (`n40`) | 4.6920 (n40)–6.7917 (n4) | 0.4054 (n40)–0.6887 (n4) |
| BVX3 | 0.9796 (`n4`) | 381.76 (`n40`) | 486.53 (`n8`) | 138.0 MB (`n4`)–359.8 MB (`n40`) | 70.5 MB (`n4`)–348.4 MB (`n40`) | 0.4652 (n40)–0.7308 (n4) | 0.6985 (n40)–1.0428 (n4) |
| Lazy2 | 0.9522 (`n4`) | 163.05 (`n40`) | 497.03 (`n40`) | 361.8 MB (`n4`)–658.2 MB (`n8`) | 65.9 MB (`n4`)–347.8 MB (`n40`) | 0.8832 (n40)–1.1946 (n4) | 0.4206 (n40)–0.7102 (n4) |
| Optimal | 0.9347 (`n4`) | 57.28 (`n40`) | 483.04 (`n8`) | 213.3 MB (`n4`)–575.0 MB (`n40`) | 70.6 MB (`n4`)–347.6 MB (`n40`) | 5.9326 (n40)–8.3281 (n4) | 0.6891 (n40)–1.0912 (n4) |
| Apple | 0.9993 (`log n4`) | 159.45 (`log n40`) | 470.51 (`log n8`) | 929.1 MB (`log n4`)–1042.9 MB (`log n8`) | 614.4 MB (`log n4`)–614.5 MB (`log n8`) | 0.6581 (log n40)–0.6633 (log n8) | 0.6325 (log n4)–0.7245 (log n8) |
| TLZ4 | 1.0592 (`log n4`) | 351.03 (`log n40`) | 573.73 (`log n8`) | 79.2 MB (`log n4`)–84.7 MB (`log n8`) | 34.1 MB (`log n4`)–34.1 MB (`log n4`) | 0.6284 (log n4)–0.6284 (log n4) | 0.1743 (log n4)–0.1743 (log n4) |
| ZSTD | 0.9297 (`log n4`) | 471.38 (`log n4`) | 505.80 (`log n8`) | 497.6 MB (`log n40`)–499.2 MB (`log n4`) | 629.5 MB (`log n4`)–785.0 MB (`log n40`) | 0.3905 (log n4)–0.3905 (log n4) | 0.2486 (log n4)–0.2486 (log n4) |

目前資料顯示：Optimal 在兩組資料上都取得 BVX3 family 最佳壓縮比（claw-code 0.8257、llama.cpp 0.9347），但其 encode Energy Ratio 遠高於 TGZ（7.32–10.00 與 5.93–8.33），適合離線壓縮而非追求最低單次 encode 成本。**encode Energy Ratio 在所有 n 值均低於 1 的只有 Other3 與 BVX3**——此句原本還包含 Lazy2，但現行數字不支持：Lazy2 在 claw-code 為 1.68–2.23，在 llama.cpp 最高達 1.19。Decode 對 concurrency 較敏感；n40 通常是最低能耗點，而多個格式在 n4 會高於 TGZ。

### RSS 與 CPU 能耗取捨

依 [`LPDDR_power_estimation/LPDDR_power_info.md`](LPDDR_power_estimation/LPDDR_power_info.md) 的連續存取估算，LPDDR4X / LPDDR5 約為 `150 / 120 mW/GB`。RSS 從約 60 MB 增至 300 MB，增量約 240 MB（0.234 GB），對應 DRAM 額外功率約 `35 / 28 mW`。

若再納入 memory controller / PHY 約 20–40% 的額外成本，記憶體子系統增量約 `34–49 mW`。即使把這視為整段持續活動的保守上限，執行 40 秒約增加 `1.4–2.0 J`；若只有約 4 秒，則約 `0.14–0.20 J`。

先前受控輪次中，Optimal decode 從 n4 提升至 n40 時，RSS 約由 `68.5 / 71.1 MB` 升至 `308.9 / 348.9 MB`，CPU energy 則由 `17.13 / 11.33 J` 降至 `8.39 / 5.86 J`（約 `-51% / -48%`）。CPU 節省量級遠高於不到 1 秒期間約數百分之一焦耳的估算記憶體增量。因此在目前桌面測試與約 300 MB RSS 範圍內，優先降低 CPU 執行時間／總能耗是較佳整體取捨，約 300 MB RSS 可視為有條件接受。

這是依 active-memory 單位功耗建立的模型估算，不是本輪 DRAM 實測；RSS 也不等於所有頁面都持續讀寫。結論只用於能源取捨，不代表可忽略記憶體容量、系統 memory pressure 或多工作負載併行問題。最新 best-points 的 Optimal encode n40 RSS 為 `589.3 MB`（claw-code）與 `575.0 MB`（llama.cpp）——取自 `best_points/best_points.md` 的「最高 Encode RSS」欄——仍明顯超過 300 MB 基準，應繼續調查 DP buffer、chunk in-flight 與暫存陣列生命週期。

### 適用場景：伺服器端更新包壓縮

Optimal compression 適合「伺服器端壓縮一次、client 端下載與解壓多次」的分發模型，例如大型 server-side code update、App 或遊戲更新包、CDN 靜態資產。高成本 encode 可在發布端離線完成，並由大量下載次數攤提，不應只用單次 encode energy 判斷整體效率。

目前 Optimal 相對 BVX3 / Other3 產物更小；在大規模分發時，每個 client 都能減少下載 bytes，因而降低網路傳輸時間與 radio / Wi-Fi 活動時間。累積到大量 iPhone 或其他 client 後，傳輸端節省可能比伺服器增加的一次性壓縮成本更重要，但仍需以實際網路與裝置能耗量測確認。

client 端只執行 decode。Optimal、Lazy2 與一般 BVX3 使用相同格式與 decoder；在記憶體容量允許且採較高 concurrency 時，約 300–350 MB decode RSS 的估算記憶體成本可能小於 CPU／傳輸節省，因此整體方向有利於 client-side energy。這是工作假設，不是所有 iPhone 型號或 memory-pressure 情境下的通用結論。

系統層評估應使用：`一次 encode energy + 所有 client 的傳輸 energy + 所有 client 的 decode energy`。下載次數越多、壓縮大小差距越大，Optimal 的 server-side 高 encode 成本越容易被攤平；若只是單次本機壓縮，則未必划算。

App Store 僅作應用場景類比：目前 `bvx3` 是私有格式，實際部署需要 client 端整合對應 decoder，並符合平台更新、簽章與封裝流程；本文件不宣稱現有格式可直接替換 App Store 的正式更新格式。

### 測試結果

`lzfse-test.txt` 展示了各種資料型態的往返與相容性測試：
- **高度重複資料**：壓縮至 ~1–2%（從 19.2 KB 縮至 222–235 bytes）
- **低熵資料**：壓縮至 0.3–0.4%
- **隨機（不可壓）**：~100% 大小（略微膨脹）
- **結構化資料**：8.5–16.5% 壓縮比（Lazy2 更佳）
- **交錯距離模式**：0.7–0.8% 壓縮比
- **文字大樣本**：25.9–26.7% 壓縮比（Lazy2 改進）

所有格式皆保持相容性：`other3` 與 `bvx3` 的輸出可由本工具解碼，Apple Compression framework 可解碼 `other3` 串流。

這些數字僅作為範例。正式比較效能前，請以具代表性的資料與硬體重新測試。

## 授權

請參閱儲存庫授權資訊。`lzfse-cli.swift` 中的實作註解說明了源自 Apple LZFSE 參考格式定義的 BSD-3-Clause 脈絡。

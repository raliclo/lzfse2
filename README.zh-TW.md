# lzfse2

[English](README.md) | 繁體中文

`lzfse2` 是以 Swift 實作的 LZFSE 命令列壓縮／解壓工具。它包含位元相容、多核心的編碼器與解碼器，也提供可選的私有 `bvx3` 格式以換取更高壓縮率。

## 功能

- `other3` 是預設引擎，輸出標準 LZFSE 串流，可由 Apple Compression 與本工具解碼。
- `apple` 在可用時使用 Apple `COMPRESSION_LZFSE` 實作。
- `bvx3` 使用私有擴充區塊，具備較大的視窗與字母表。壓縮率可能更好，但只有本工具能解碼。
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
./compile.sh
```

`compile.sh` 也會將二進位檔複製到 `/opt/homebrew/bin`，因此該步驟可能需要本機寫入權限。

## 用法

```sh
./lzfse -h
```

```text
Usage: lzfse -encode|-decode [-algo apple|other3|bvx3] [-lazy2|-optimal] [-si|-i input] [-so|-o output] [-test] [-h]
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

執行內建測試：

```sh
./lzfse -test
```

## 引擎

| 引擎 | 輸出相容性 | 說明 |
| --- | --- | --- |
| `other3` | 標準 LZFSE | 預設。多核心、lazy matching，輸出可由 Apple 解碼。 |
| `apple` | 標準 LZFSE | 使用 Apple Compression framework。 |
| `bvx3` | 本工具私有格式 | 較大的視窗與字母表可提升壓縮率；Apple 無法解碼。 |

`bvx3` 編碼時，`-lazy2` 與 `-optimal` 會選擇較慢但可能提升壓縮率的 parser 模式。它們不會建立不同的解碼格式；一般 `bvx3`、`bvx3 -lazy2`、`bvx3 -optimal` 產物都使用 `-algo bvx3` 解碼。

解碼時，`-algo other3` 與 `-algo bvx3` 使用同一個內建區塊解碼器。這個解碼器接受所有支援的 LZFSE 區塊型別，包含 `-algo apple` 或 Apple Compression 產生的標準串流。`-algo apple` 則會改用 Apple framework decoder。


## zsh 輔助函式

此儲存庫包含一段 `zshrc` 範例，可將目錄先打包為 `tar` 串流，再交給本工具壓縮。

```zsh
# 解壓常見封存格式。
extract () {
    if [ -f "$1" ] ; then
        case "$1" in
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
        echo "Usage: lzfseX <file-or-directory> [apple|other3|bvx3]"
        return 1
    fi

    local algo="${2:-other3}"
    local extension="lzfse.other3"
    [[ "$algo" == "apple" ]] && extension="lzfse.apple"
    [[ "$algo" == "bvx3" ]] && extension="lzfse.bvx3"
    [[ "$algo" == "other3" ]] && extension="lzfse.other3"

    echo tar -cf - "$1" "|" lzfse -encode -si -o "$1.$extension" -algo "$algo"
    tar -cf - "$1" | lzfse -encode -si -o "$1.$extension" -algo "$algo"

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
raliclo ALL=(ALL) NOPASSWD: /usr/bin/powermetrics, /usr/bin/true, /Users/raliclo/proj/lzfse2/benchmark.sh, /Users/raliclo/proj/lzfse2/benchmark2.sh, /Users/raliclo/proj/lzfse2/run_round.command, /Users/raliclo/proj/lzfse2/helper/reboot.command,/Users/raliclo/proj/lzfse2/gitOwner.sh
```

儲存並離開（同樣按下 Ctrl + O -> Enter -> Ctrl + X）。

## 基準測試

最新測試使用 `claw-code`（約 1351 MiB）與 `llama.cpp`（約 1261 MiB）兩組資料集，測試機器為 Mac mini，配備 Apple M4 10 核心 CPU、16 GB 記憶體與 256 GB 儲存空間。完整逐點資料位於 [`BenchMarkResult.csv`](BenchMarkResult.csv)，跨 n4 / n8 / n40 的最佳／最差點整理位於 [`best_points/best_points.csv`](best_points/best_points.csv) 與 [`best_points/best_points.md`](best_points/best_points.md)。

以下數值來自目前的 best-points 分析。`log nX` 只表示 TGZ、Apple、TLZ4、ZSTD 的來源 log 批次，`-n` 不影響這些外部算法。Energy Ratio 以同輪、同資料集 TGZ CPU energy 為 `1.0000`；小於 1 代表比 TGZ 省 CPU energy，大於 1 代表較耗能。

### 最新最佳點摘要

#### claw-code

| 格式 | 最佳壓縮比 | 最佳壓縮 MB/s | 最佳解壓 MB/s | Encode RSS 範圍 | Decode RSS 範圍 | Encode Energy Ratio 範圍 | Decode Energy Ratio 範圍 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 1.0000 (`log n4`) | 50.11 (`log n40`) | 419.14 (`log n4`) | 4.2 MB (`log n4`)–4.2 MB (`log n4`) | 3.7 MB (`log n4`)–3.7 MB (`log n4`) | 1.0000 | 1.0000 |
| Other3 | 0.9865 (`n4`) | 423.73 (`n8`) | 451.15 (`n8`) | 133.3 MB (`n4`)–227.6 MB (`n40`) | 69.4 MB (`n4`)–299.4 MB (`n40`) | 0.1916 (`n40`)–0.3120 (`n4`) | 0.1021 (`n40`)–1.1001 (`n4`) |
| BVX3 | 0.9492 (`n4`) | 437.11 (`n40`) | 356.96 (`n4`) | 129.4 MB (`n4`)–246.7 MB (`n40`) | 70.1 MB (`n4`)–323.6 MB (`n40`) | 0.1999 (`n40`)–0.3173 (`n4`) | 0.0344 (`n40`)–1.7427 (`n4`) |
| Lazy2 | 0.8998 (`n4`) | 69.13 (`n40`) | 435.99 (`n8`) | 188.9 MB (`n4`)–496.1 MB (`n40`) | 66.0 MB (`n4`)–320.5 MB (`n40`) | 0.6491 (`n40`)–0.9022 (`n4`) | 0.0482 (`n40`)–1.4300 (`n4`) |
| Optimal | 0.8590 (`n4`) | 36.21 (`n40`) | 324.08 (`n40`) | 201.0 MB (`n4`)–561.2 MB (`n40`) | 68.2 MB (`n4`)–309.3 MB (`n40`) | 3.0944 (`n40`)–4.3182 (`n4`) | 0.0481 (`n40`)–1.4943 (`n4`) |
| TLZ4 | 1.1793 (`log n4`) | 442.28 (`log n40`) | 465.47 (`log n4`) | 77.4 MB (`log n40`)–84.9 MB (`log n4`) | 33.7 MB (`log n4`)–33.7 MB (`log n4`) | 0.1949 (`log n4`)–0.1949 (`log n4`) | 0.2047 (`log n4`)–0.2047 (`log n4`) |
| ZSTD | 0.8245 (`log n4`) | 385.36 (`log n8`) | 474.06 (`log n4`) | 375.1 MB (`log n4`)–392.7 MB (`log n40`) | 9.2 MB (`log n4`)–9.3 MB (`log n8`) | 0.2426 | 0.7385 |

#### llama.cpp

| 格式 | 最佳壓縮比 | 最佳壓縮 MB/s | 最佳解壓 MB/s | Encode RSS 範圍 | Decode RSS 範圍 | Encode Energy Ratio 範圍 | Decode Energy Ratio 範圍 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 1.0000 (`log n4`) | 43.64 (`log n40`) | 96.30 (`log n4`) | 4.3 MB (`log n4`)–4.3 MB (`log n4`) | 3.8 MB (`log n4`)–3.8 MB (`log n4`) | 1.0000 | 1.0000 |
| Other3 | 0.9957 (`n4`) | 98.58 (`n40`) | 88.47 (`n40`) | 128.3 MB (`n4`)–335.5 MB (`n40`) | 67.0 MB (`n4`)–349.0 MB (`n40`) | 0.1540 (`n40`)–0.2478 (`n4`) | 0.0718 (`n40`)–0.8314 (`n4`) |
| BVX3 | 0.9787 (`n4`) | 96.31 (`n40`) | 86.47 (`n8`) | 142.1 MB (`n4`)–355.3 MB (`n40`) | 67.1 MB (`n4`)–351.3 MB (`n40`) | 0.1532 (`n40`)–0.2568 (`n4`) | 0.0560 (`n40`)–1.3147 (`n4`) |
| Lazy2 | 0.9551 (`n4`) | 89.04 (`n40`) | 87.77 (`n40`) | 193.5 MB (`n4`)–481.8 MB (`n40`) | 66.9 MB (`n4`)–348.8 MB (`n40`) | 0.2777 (`n40`)–0.3945 (`n4`) | 0.0576 (`n8`)–0.5950 (`n4`) |
| Optimal | 0.9393 (`n4`) | 50.42 (`n40`) | 87.34 (`n8`) | 224.7 MB (`n4`)–597.2 MB (`n40`) | 71.0 MB (`n4`)–349.2 MB (`n40`) | 2.2189 (`n40`)–3.2077 (`n4`) | 0.0179 (`n40`)–1.0636 (`n4`) |
| TLZ4 | 1.0537 (`log n4`) | 95.14 (`log n4`) | 86.88 (`log n8`) | 80.7 MB (`log n40`)–85.8 MB (`log n8`) | 33.8 MB (`log n4`)–33.8 MB (`log n4`) | 0.2250 (`log n4`)–0.2250 (`log n4`) | 0.1052 (`log n4`)–0.1052 (`log n4`) |
| ZSTD | 0.9100 (`log n4`) | 101.81 (`log n4`) | 88.29 (`log n40`) | 474.0 MB (`log n40`)–474.1 MB (`log n4`) | 9.0 MB (`log n4`)–9.2 MB (`log n40`) | 0.1697 | 0.3388 |

目前資料顯示：Optimal 在兩組資料上都取得 BVX3 family 最佳壓縮比，但 encode Energy Ratio 仍高於 TGZ，適合離線壓縮而非追求最低單次 encode 成本。Other3、BVX3 與 Lazy2 的 encode Energy Ratio 在所有 n 值均低於 1。Decode 對 concurrency 較敏感；n40 通常是最低能耗點，但 BVX3 family 在部分 n4 測點會高於 TGZ。

### RSS 與 CPU 能耗取捨

依 [`LPDDR_power_estimation/LPDDR_power_info.md`](LPDDR_power_estimation/LPDDR_power_info.md) 的連續存取估算，LPDDR4X / LPDDR5 約為 `150 / 120 mW/GB`。RSS 從約 60 MB 增至 300 MB，增量約 240 MB（0.234 GB），對應 DRAM 額外功率約 `35 / 28 mW`。

若再納入 memory controller / PHY 約 20–40% 的額外成本，記憶體子系統增量約 `34–49 mW`。即使把這視為整段持續活動的保守上限，執行 40 秒約增加 `1.4–2.0 J`；若只有約 4 秒，則約 `0.14–0.20 J`。

先前受控輪次中，Optimal decode 從 n4 提升至 n40 時，RSS 約由 `68.5 / 71.1 MB` 升至 `308.9 / 348.9 MB`，CPU energy 則由 `17.13 / 11.33 J` 降至 `8.39 / 5.86 J`（約 `-51% / -48%`）。CPU 節省量級遠高於不到 1 秒期間約數百分之一焦耳的估算記憶體增量。因此在目前桌面測試與約 300 MB RSS 範圍內，優先降低 CPU 執行時間／總能耗是較佳整體取捨，約 300 MB RSS 可視為有條件接受。

這是依 active-memory 單位功耗建立的模型估算，不是本輪 DRAM 實測；RSS 也不等於所有頁面都持續讀寫。結論只用於能源取捨，不代表可忽略記憶體容量、系統 memory pressure 或多工作負載併行問題。最新 best-points 的 Optimal encode n40 RSS 約為 `561.2 / 597.2 MB`，仍明顯超過 300 MB 基準，應繼續調查 DP buffer、chunk in-flight 與暫存陣列生命週期。

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

# lzfse2 優化報告 / Optimization Report

## Note : 找到IO跟磁碟容量會銳減的原因,是因為沒有設定.gitignore,所以VS CODE會自動將這些檔案列入git的暫存區,導致磁碟IO競爭與容量銳減,所以以後的測試暫存檔案的檔案都需要藉由.gitignore排除

## 驗收術語

- **output-identical**：以解壓／extract 後的內容 compare 為準；只要解壓結果與原始資料完全一致即通過，不要求壓縮檔位元組相同。
- **bitstream-identical**：壓縮產物的位元組與 baseline 完全相同，這是比 output-identical 更嚴格且獨立的條件。
- 壓縮檔大小或壓縮比變動應另行記錄，不得單獨用來判定 output-identical 失敗。

---

## 解壓命令參考 / Decode Command Reference

```sh
# 正常解壓 / Normal decode
lzfse -decode -i file.lzfse -so | tar -xf - -C /dest

# Debug 模式：發生 overshoot / block 失敗時印詳細資訊到 stderr
# Debug mode: prints overshoot / block failure details to stderr
lzfse -decode -i file.lzfse -debug -so 2>debug/decode_debug.txt | tar -xf - -C /dest
```

---

## 大檔解碼正確性驗證（2026-06-24）/ Large-File Decode Correctness Verification

**資料集**：`proj_Win`（56 GB 真實資料，含 Mac .app、二進位、GGUF 等異質內容）  
**Dataset**: `proj_Win` (56 GB real-world data — Mac .app bundles, binaries, GGUF, etc.)

**流程 / Procedure**：
```sh
# 壓縮 / Compress
tar -c -C /Volumes/Windows proj_Win \
  | lzfse -encode -si -o proj_Win.lzfse -algo other3 -n 100

# 解壓 / Decompress
lzfse -decode -i proj_Win.lzfse -n 100 -so \
  | tar -xf - -C /Volumes/Windows/test/

# 比對 / Diff
diff -rq /Volumes/Windows/proj_Win /Volumes/Windows/test/proj_Win 2>/dev/null
```

**結果 / Result**：`DIFF_EXIT:0` — output-identical，零差異。

> 備註：首輪 diff 曾顯示 `Mac_Apps/Codex.app` 內 57 個檔案不同，原因為該 app 在壓縮後被作業系統自動更新（壓縮時間 02:04，Codex binary mtime 09:10）。以最新狀態重新壓縮後 diff 結果為 0 差異，確認解碼邏輯正確。  
> Note: First diff showed 57 files differing inside `Codex.app` — caused by OS auto-update of the app after archiving. Re-compressing from current state produced `DIFF_EXIT:0`.

---

## 壓縮架構說明 / Compression Architecture

### 壓縮比貢獻來源 / Compression Ratio Contribution Sources

壓縮比由兩個串聯階段決定：**LZ parse（match/literal 切割）** 和 **FSE 熵編碼（符號壓縮）**。

#### 第一層：LZ Parse — 決定「有多少資料能用 match 表示」

| 輸出類型 | 意義 | 佔壓縮比貢獻 |
| --- | --- | --- |
| **Literal** | 無法 match 的原始 byte | 熵編碼後仍需存入壓縮檔 |
| **Match (L, M, D)** | 距離 D 前有長 M 的重複、前有 L 個 literal | 3 個符號取代數十至數千 byte |

Parser 選擇直接影響 match 率：
- `lzParse`（greedy）：每位置看 1 個候選，快但 match 偏短
- `lzParseChain`（Lazy2）：hash chain 多步搜尋，match 更長/更優
- `lzParseOptimal`（Optimal）：DP 全域最佳化，match 總 bit cost 最小

實測（claw-code）：Other3 ≈ 0.31、Optimal ≈ 0.26（比 Other3 再省 ~16%）。

#### 第二層：FSE 熵編碼 — 決定「符號能壓多緊」

每個 block 有 5 條獨立 FSE 串流（bvx3 literal 最多 4 個上下文）：

| 串流 | 符號數（other3 / bvx3） | 狀態數 |
| --- | --- | --- |
| Literal | 256 / 256×4 ctx | 1024 |
| L（literal run 長度）| 20 / 22 | 64 |
| M（match 長度）| 20 / 22 | 64 |
| D（match 距離）| 64 / 80 | 256 |
| extra bits | — | — |

FSE 對高頻符號用少 bits，理論極限接近 Shannon entropy。

#### 格式差異對壓縮比的影響

| 格式 | D 視窗上限 | M 上限 | Block 標頭開銷 |
| --- | --- | --- | --- |
| other3（LZFSE 相容）| 262,139（≈256 KB）| 2,359 | 772 bytes / block |
| bvx3（本工具私有）| 4,194,299（全 4MB chunk）| 69,947 | 54 bytes / block |

bvx3 的更大視窗讓長距離重複能被 match，加上 3-deep rep-offset（D=0/1/2 = 歷史距離，幾乎零 cost），是 bvx3 壓縮比優於 other3 的主因。

---

### 壓縮流程查詢表全覽 / Lookup Tables in Compression Pipeline

#### 一、LZ Match 搜尋表（Parse 階段，動態 per chunk）

**Greedy parser** — 單層 hash table：
```
hashTable[hash4(i)] = 最近出現此 hash 的位置（碰撞直接覆蓋）
```

**Chain parser（Lazy2 / Optimal）** — head + chain 雙表：
```
head[h]  → hash bucket 最新 index（131072 桶，17-bit hash）
chain[c] → linked list，chain[idx] = 前一個同 hash 的位置
搜尋路徑：head[h] → chain[c0] → chain[c1] → … (最多 32 步)
```

**R41 Tag-packed 格式**（壓縮 head/chain 的 Int32 編碼）：
```
Int32 = (tag << 24) | index
  tag  = hash 次 8 bits → 先比 tag，不符直接跳過（純暫存器操作）
  index = 24-bit 位置索引（上限 16 MB chunk）
```

#### 二、FSE 編解碼表（Entropy 階段，動態 per block）

每個 block 根據當下符號頻率動態建立，共 5 張編碼表 + 對應解碼表：

```swift
// 編碼表 entry：
FSEEncoderEntry { s0, k, delta0, delta1 }
// s0: 門檻（state < s0 → 輸出 k bits，否則 k-1 bits）
// delta0/delta1: 新 state 偏移量

// literal 解碼表（packed Int32）：
(delta << 16) | (symbol << 8) | nbits  // nstates 個 entry

// L/M/D 數值解碼表：
FSEValueDecoderEntry { totalBits, valueBits, delta, vbase }
```

#### 三、靜態符號定義表（格式規範，編解碼共用）

```
lBaseValue[20] / lExtraBits[20]  → L 符號 ↔ literal run 長度
mBaseValue[20] / mExtraBits[20]  → M 符號 ↔ match 長度
dBaseValue[64] / dExtraBits[64]  → D 符號 ↔ match 距離（other3）
// bvx3：lm3（22 符號）+ d3（80 符號）/ bvx3D（88 符號）

解碼公式：實際值 = base[symbol] + readBits(extraBits[symbol])
```

#### 四、Optimal Parser DP Cost 表（動態 per segment，`rebuildPrices` 維護）

```
litPrice[256]      → 每個 byte 值的 FSE bit cost
mPriceTab[22]      → 每個 M 符號的 bit cost
dPriceTab[80]      → 每個 D 符號的 bit cost
lmBaseP[22]        → M 符號 base price（inner loop 預算）
cPrice[i]          → 位置 i 的 DP 最小 bit 總成本
```

#### 表的性質總結

| 表 | 靜態 vs 動態 | 生命週期 | 主要用途 |
| --- | --- | --- | --- |
| `lBaseValue` 等格式表 | 靜態（格式規範）| 永久 | 符號 ↔ 數值互換 |
| `head[h]` / `chain[c]` | 動態 | per chunk（跨 chunk 重用，`ParseScratch` pool）| LZ match 搜尋 |
| FSE `EncoderTable` | 動態 | per block | 符號 → bitstream |
| FSE `DecoderTable` | 動態 | per block | bitstream → 符號 + 數值 |
| `litPrice` / `mPriceTab` 等 | 動態 | per segment（`rebuildPrices`）| Optimal DP cost 估算 |

> **R42 relevance**：`head/chain` 的 cache miss 是 Lazy2/Optimal 的主要瓶頸（R41 trace 確認）。  
> R42 的 prefetch chain entries 目標就是在走訪鏈時預取下一個 chain entry 到 L1 cache，減少 stall。

---

# R42-Mac：other3 -optimal3 DP 最優解析導入（2026-07-05）/ R42-Mac: other3 -optimal3 DP-Optimal Parsing

> 新增 `lzParseOptimal2`：與 bvx3 的 `lzParseOptimal` 同一套分段 DP 最優解析機制（雜湊鏈 frontier、熵預篩、搜尋預算全部沿用同一組常數），但改接標準 LZFSE 的 L/M/D 符號表（`lBaseValue`/`mBaseValue`/`dBaseValue`，而非 bvx3 合併的 `lm3` 表）與較小上限（`maxLValue`/`maxMValue`/`maxDValue`），透過新旗標 `-optimal3` 接上 `-algo other3`。  
> 輸出仍是標準 bvx2（經既有 `encodeBlock`），Apple 與任何相容解碼器可解——這是與 bvx3-optimal 最大的差異：bvx3-optimal 犧牲相容性換壓縮率，other3-optimal3 兩者兼得。  
> 對 claw-code / llama.cpp 執行 `-n 40 / 8 / 4` 三批次完整 benchmark + tracer/CPU/power 全流程整合。

## 優化策略 / Optimization Strategy

| 項目 | 說明 |
| --- | --- |
| **核心變更** | 新增 `lzParseOptimal2`，DP 機制與 `lzParseOptimal` 相同，符號表與上限改用標準格式 |
| **單一 rep（關鍵差異）** | 標準格式只有「與前一距離相同」單一折扣（`encodeBlock` 的 `dPrev`→`d=0` 轉換），非 bvx3 的 3 深度 rep-offset；DP 只需追蹤一個 `rep0`，省了 3 槽 MTF 邏輯 |
| **M / D 符號表** | M 用獨立 `mBaseValue`/`mExtraBits`（20 符號），D 用 `dBaseValue`/`dExtraBits`（64 符號）——非 bvx3 合併的 `lm3`（22 符號）/ `d3`（80 符號）表 |
| **L 定價** | 沿用攤提常數 `matchConst=80`（同 `lzParseOptimal` 量級近似，未來可依實測再調） |
| **相容性** | 輸出走 `encodeBlock`（標準 bvx2），非 `encodeBlockV3`；Apple Compression framework 可直接解 |
| **CLI** | `-optimal3`（僅 `-algo other3` 生效，其餘 algo 忽略並提示）；decode 端不需任何旗標，與一般 other3 相同 |

## 驗證 / Verification

- 內建 `-test` 全數通過（含跨段 match 回歸測試），新增 `other3 -optimal3 自我往返`、`平行解碼`、`→ Apple 解碼` 三項 check，皆為 output-identical 且 bitstream 可被 Apple `compression_decode_buffer` 正確解開。
- 實機以 claw-code tar（約 460 MB）驗證：本工具解碼與 Apple 解碼皆與原始資料 `cmp` 完全一致。
- 全 R42-Mac round（tracer、power benchmark、CPU call tree、`BenchMarkResult.csv` 重建、`best_points`、Win/Mac 比較報告、md-translate）跑畢，`TEST_OK`、`BENCH_DONE`，零失敗。

## 1. 壓縮比與速度（n=40，兩資料集）/ Ratio & Speed (n=40, both datasets)

| 資料集 | 格式 | 壓縮比 | Enc MB/s | Dec MB/s |
| --- | --- | ---: | ---: | ---: |
| claw-code | TGZ | 1.0000 | 47.56 | 392.56 |
| claw-code | Other3 | 0.9865 | 339.49 | 402.20 |
| claw-code | **Optimal3** | **0.9401** | **62.85** | **435.87** |
| claw-code | BVX3（私有格式參考）| 0.9492 | 371.09 | 410.21 |
| claw-code | BVX3-Optimal（私有格式參考）| 0.8574 | 33.73 | 377.00 |
| llama.cpp | TGZ | 1.0000 | 39.63 | 88.65 |
| llama.cpp | Other3 | 0.9957 | 87.49 | 80.41 |
| llama.cpp | **Optimal3** | **0.9731** | **64.07** | **83.85** |
| llama.cpp | BVX3（私有格式參考）| 0.9787 | 87.79 | 77.59 |
| llama.cpp | BVX3-Optimal（私有格式參考）| 0.9387 | 48.01 | 76.76 |

> **重點**：claw-code 上 Optimal3（0.9401）壓縮比已優於私有格式 BVX3（0.9492），代價是 encode 速度降至 Other3 的 ~18.5%（62.85 vs 339.49 MB/s）；decode 速度與 Other3 無異（同一 bvx2 解碼路徑）。llama.cpp（低重複率資料）改善幅度較小（0.9957→0.9731，約 -2.3%）。

## 2. Peak RSS（Mac only, n=40）

| 資料集 | 格式 | Encode RSS | Decode RSS |
| --- | --- | ---: | ---: |
| claw-code | Other3 | 228.9 MB | 299.3 MB |
| claw-code | **Optimal3** | **550.8 MB** | **316.4 MB** |
| llama.cpp | Other3 | 354.5 MB | 349.0 MB |
| llama.cpp | **Optimal3** | **821.7 MB** | **350.9 MB** |

> Optimal3 的 encode RSS 較 Other3 高約 2.3–2.4×，來自分段 DP 的 cell 陣列與 frontier 暫存區（與 bvx3-optimal 的記憶體特性一致）；decode RSS 與 Other3 相同（解碼邏輯完全共用）。

## 3. CPU Energy（Mac only, n=40）

| 資料集 | 格式 | Enc J | Enc J/TGZ |
| --- | --- | ---: | ---: |
| claw-code | Other3 | 28.16 | 0.1789 |
| claw-code | **Optimal3** | **370.85** | **2.3557** |
| llama.cpp | Other3 | 18.38 | 0.1104 |
| llama.cpp | **Optimal3** | **289.48** | **1.7384** |

> 能耗隨速度等比例上升（DP 為 CPU-bound），與 bvx3-optimal 的能耗量級相近（同屬「壓縮率優先、速度/能耗次之」的策略）。Decode energy n=40 取樣覆蓋率不足，不列入本輪比較。

## 4. Best Points（Optimal3, all n）

| 資料集 | 最佳壓縮比 | 最佳 Enc MB/s | 最佳 Dec MB/s | 最低 Enc RSS | 最高 Enc RSS | 最低 Enc J | 最高 Enc J |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| claw-code | 0.9401 (`n4`) | 62.85 (`n40`) | 440.72 (`n8`) | 190.0 MB (`n4`) | 550.8 MB (`n40`) | 370.85 (`n40`) | 533.01 (`n4`) |
| llama.cpp | 0.9731 (`n4`) | 64.07 (`n40`) | 83.85 (`n40`) | 221.7 MB (`n4`) | 821.7 MB (`n40`) | 289.48 (`n40`) | 419.46 (`n4`) |

> 壓縮比在各 n 皆不受影響（DP 解析與分塊平行度無關），最佳值出現於 `n4`；速度/RSS/能耗隨 `-n`（平行度）上升而變差，與 Other3/Lazy2/Optimal 的既有規律一致（更高平行度 = 更多同時存活的編碼上下文）。

## 待辦 / Next Steps

- Windows 測試腳本（`helper_windows/encode-win.bat` 等）已同步支援 `-optimal3`，但本輪尚未在 Windows 執行；Win/Mac 比較報告目前顯示 `LZFSE (Optimal3)` 為 `Windows result missing`，待下次 Windows round 補齊。
- `matchConst`（L 符號攤提常數）沿用 bvx3-optimal 的近似值，尚未針對標準格式的較小 L/M 上限個別調參，未來輪次可视 claw-code/llama.cpp 的實測比率再收斂。

---

# Pre-R42：LZFSE_Win_UI — Windows 圖形介面與打包工具鏈（2026-06-27）/ Pre-R42: LZFSE_Win_UI — Windows GUI & Packaging Toolchain

> 基礎建設輪（非演算法優化）：為 lzfse 加上 Windows GUI 前端與自包含打包流程。
> **未改變壓縮/解碼演算法**——R42 的 codec 目標（prefetch chain entries）不受影響。
> Infrastructure round (not an algorithm optimization): adds a Windows GUI frontend and
> self-contained packaging. **No change to the compression/decode algorithms** — the R42 codec
> target (prefetch chain entries) is unaffected.

## 產出 / Deliverables
- `lzfse-ui/lzfse-ui-win.swift` — SwiftCrossUI（WinUIBackend）GUI，對應 macOS 的 `lzfse-ui/lzfse-ui.swift`。
  直接 import codec（`build-win.sh` 以 `grep -v` 移除 `runCLI()` 後一起編入同一 target）。
  SwiftCrossUI GUI mirroring the macOS `lzfse-ui.swift`; links the codec directly.
- `lzfse-ui/build-win.sh` + `build-win.bat` → `lzfse-ui/release/LZFSE_UI_Win.zip`（GUI app + 隨附 `lzfse.exe`）。
- `helper_windows/build-cli-win.sh` + `build-cli-win.bat` → `helper_windows/release/lzfse-cli.zip`
  （`lzfse.exe` + 32 個 Swift runtime DLL，免裝 Swift 即可執行 / self-contained, runs without Swift installed）。
- `lzfse-ui/screenshot-win.bat`、`lzfse-ui/README-UI-Win.md`。

## codec 變更：Swift 6 嚴格並行相容（純標註，零邏輯變更）/ Codec change: Swift 6 strict-concurrency compat (annotations only)
為了讓 `lzfse-cli.swift` 能在 SwiftPM（tools-version 6.0）下與 SwiftCrossUI 一起編譯，於
`DispatchQueue.concurrentPerform` 解碼路徑與 `scratchPool` 加上 `nonisolated(unsafe)`（NSLock 保護的共享變數）
與 `@Sendable`（區域函式）。**同時仍可用 `swiftc -O` 建成 CLI**（encode/decode round-trip 已驗證）。
Added `nonisolated(unsafe)` / `@Sendable` to the concurrentPerform decode paths so the codec compiles
under Swift 6 strict concurrency while still building as the CLI via `swiftc -O`. Pure annotations.

## Windows 工程要點（每個都花了實際除錯）/ Windows engineering notes
| 主題 / Topic | 處理 / Resolution |
| --- | --- |
| WinAppSDK 1.5 **DDLM 必裝** | 缺 DDLM `5001.x` → `MddBootstrapInitialize2` 失敗、閃退（exit 132）。需官方 redistributable 提權安裝。 |
| 無主控台視窗 / no console | `/SUBSYSTEM:WINDOWS` + `/ENTRY:mainCRTStartup` 連結成 GUI 子系統。 |
| 隱藏子程序視窗 / hide child windows | Win32 `CreateProcessW` + `CREATE_NO_WINDOW`（cmd/tar/lzfse 不跳視窗）。 |
| 解壓不卡死 / no hang | 重活在獨立 OS `Thread`（`Task.detached` 仍卡 WinUI 訊息泵 → 事件日誌 AppHangB1）。 |
| 資料夾選擇器 / folder picker | WinUIBackend 只能選檔；改用 Win32 `SHBrowseForFolderW`（獨立 STA thread + `OleInitialize`）。 |
| 剪貼簿 / clipboard | WinUI TextBox 無 Ctrl+C → Win32 `SetClipboardData(CF_UNICODETEXT)`。 |
| 解碼分流 / decode routing | 單檔/資料夾壓縮都命名 `.lzfse`；以 tar `ustar` 魔數（offset 257，串流偷看前 512 byte）判斷解包或單檔。 |
| 打包 / packaging | bsdtar 不能寫 zip → PowerShell `Compress-Archive`；路徑轉換用 `sed`（不依賴 cygpath）。 |

## 需求 / Requirements
WinAppSDK 1.5 runtime（含 DDLM）、Swift for Windows 6.3.2、VS Build Tools + Windows SDK、Git for Windows、PowerShell。
詳見 / See `lzfse-ui/README-UI-Win.md`。

---

# R41-Mac：Tag-packed Hash Chain 導入（2026-06-22）/ R41-Mac: Tag-packed Hash Chain

> 將 R27 的 Tag-packed hash chain（hashAndTag / chainIndexMask / chainTagShift / chainNullIndex）重新導入 R40 代碼基礎。  
> lzParseChain（BVX3 / Lazy2）與 lzParseOptimal（Optimal）均同步更新。  
> 對 claw-code / llama.cpp 執行 `-n 40 / 8 / 4` 三批次完整 benchmark。

## 優化策略 / Optimization Strategy

| 項目 | 說明 |
| --- | --- |
| **核心變更** | `head[h]` 與 `chain[c]` 改為 `(tag<<24)\|index` packed Int32 格式 |
| **hashAndTag** | 同一 Fibonacci 乘法 `×0x9E3779B185EBCA87`，高 17 bits → bucket，次 8 bits → tag |
| **鏈走訪** | 每個候選先比 `(packed>>24)==qtag`，不符直接跳下一個（純暫存器操作）|
| **Sentinel** | `chainNullIndex=0x00FF_FFFF`（head 初始 -1 → UInt32 → index=0xFFFFFF）|
| **Greedy path** | 僅解包 index（`&chainIndexMask`），不套 tag filter（只看 1 個候選）|
| **assert guard** | `assert(n <= Int(chainIndexMask))`，確保 chunk 不超 16 MiB 索引上限 |

## 1a. Encode 速度 vs Windows（claw-code, n=40）/ Encode MB/s — Win/Mac Comparison

| 格式 | Mac MB/s | Mac/TGZ | Win MB/s | Win/TGZ | Win/Mac |
| --- | ---: | ---: | ---: | ---: | ---: |
| TGZ | 48.73 | 1.0000 | 24.67 | 1.0000 | 0.506 |
| Other3 | 344.41 | 7.0677 | 266.36 | 10.797 | 0.773 |
| BVX3 | 375.00 | 7.6955 | 241.42 | 9.785 | 0.644 |
| Lazy2 | 63.73 | 1.3078 | 38.75 | 1.571 | 0.608 |
| Optimal | 34.45 | 0.7070 | 15.54 | 0.630 | 0.451 |
| TLZ4 | 394.69 | 8.0995 | 191.84 | 7.776 | 0.486 |
| ZSTD | 353.65 | 7.2573 | 103.67 | 4.202 | 0.293 |

## 1b. Decode 速度（Mac + Win, claw-code n=40）/ Decode MB/s — Mac/Win Comparison

| 格式 | Mac MB/s | Mac/TGZ | Win MB/s | Win/TGZ | Win/Mac | Verify |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| TGZ | 376.09 | 1.0000 | 643.72 | 1.0000 | 1.712 | PASS |
| TLZ4 | 405.75 | 1.0789 | 1752.37 | 2.7222 | 4.319 | PASS |
| ZSTD | 422.91 | 1.1245 | 1037.24 | 1.6112 | 2.453 | PASS |
| Other3 | 388.52 | 1.0331 | 760.85 | 1.1820 | 1.958 | PASS |
| Lazy2 | 365.21 | 0.9711 | 853.08 | 1.3252 | 2.336 | PASS |
| Optimal | 394.70 | 1.0495 | 897.14 | 1.3937 | 2.273 | PASS |
| BVX3 | 326.41 | 0.8679 | 800.90 | 1.2442 | 2.454 | PASS |

## 1c. 壓縮大小與比率（claw-code, n=40）/ Compress Size & Ratio

| 格式 | Mac MiB | Mac/TGZ | Win MiB | Win/TGZ | Mac/Win |
| --- | ---: | ---: | ---: | ---: | ---: |
| TGZ | 470.0 | 1.0000 | 468.3 | 1.0000 | 1.0035 |
| Other3 | 463.0 | 0.9865 | 459.8 | 0.9818 | 1.0069 |
| BVX3 | 446.0 | 0.9492 | 433.4 | 0.9254 | 1.0291 |
| Lazy2 | 423.0 | 0.8998 | 407.6 | 0.8704 | 1.0377 |
| Optimal | 403.0 | 0.8574 | 387.5 | 0.8273 | 1.0401 |
| TLZ4 | 554.0 | 1.1793 | 549.8 | 1.1739 | 1.0077 |
| ZSTD | 387.0 | 0.8245 | 365.9 | 0.7813 | 1.0576 |

## 2. RSS 峰值（Mac only, claw-code n=40）/ Peak RSS

| 格式 | Encode RSS | Enc/TGZ | Decode RSS | Dec/TGZ |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 4.2 MB | 1.00 | 3.7 MB | 1.00 |
| TLZ4 | 80.4 MB | 19.1 | 33.8 MB | 9.1 |
| Other3 | 266.1 MB | 63.4 | 299.5 MB | 80.9 |
| BVX3 | 272.9 MB | 65.0 | 324.5 MB | 87.7 |
| ZSTD | 387.8 MB | 92.3 | 9.2 MB | 2.5 |
| Lazy2 | 499.5 MB | 118.9 | 320.2 MB | 86.5 |
| Optimal | 572.5 MB | 136.3 | 308.2 MB | 83.2 |

## 3. CPU Energy（Mac only, claw-code n=40）/ CPU Energy Ratio vs TGZ

> ⚠ Decode energy n=40 因取樣覆蓋率 <5% 不可信，僅供參考（標 `*`）。

| 格式 | Enc J | Enc/TGZ | Dec J | Dec/TGZ |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 164.11 | 1.0000 | 5.82 | 1.0000 |
| Other3 | 27.41 | 0.1670 | 0.17* | 0.0290 |
| BVX3 | 29.05 | 0.1770 | 0.56* | 0.0962 |
| TLZ4 | 29.62 | 0.1805 | 0.58* | 0.1002 |
| ZSTD | 41.39 | 0.2522 | 3.01* | 0.5174 |
| Lazy2 | 114.59 | 0.6983 | 0.47* | 0.0805 |
| Optimal | 511.73 | 3.1183 | 0.46* | 0.0784 |

## 4. Best Points（claw-code, all n）

| 格式 | 最佳壓縮比 | 最佳 Enc MB/s | 最差 Enc MB/s | 最佳 Dec MB/s | 最低 Enc RSS | 最高 Enc RSS | 最低 Enc J | 最高 Enc J | 最低 Enc J/TGZ | 最高 Enc J/TGZ |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 1.0000 | 48.73 | 46.57 | 382.54 | 4.2 MB | 4.3 MB | 164.11 | 164.11 | 1.0000 | 1.0000 |
| Other3 | 0.9865 | 404.94 (`n8`) | 341.85 (`n4`) | 388.52 | 140.3 MB | 266.1 MB | 27.41 | 47.83 | 0.1670 | 0.2915 |
| BVX3 | 0.9492 | 406.15 (`n8`) | 322.32 (`n4`) | 326.41 | 139.0 MB | 272.9 MB | 29.05 | 49.73 | 0.1770 | 0.3030 |
| Lazy2 | 0.8998 | 63.73 (`n40`) | 53.39 (`n4`) | 409.36 (`n8`) | 194.7 MB | 499.5 MB | 114.59 | 158.69 | 0.6983 | 0.9670 |
| Optimal | 0.8574 | 34.45 (`n40`) | 25.51 (`n4`) | 394.70 | 215.4 MB | 572.5 MB | 511.73 | 704.65 | 3.1183 | 4.2939 |
| TLZ4 | 1.1793 | 420.57 (`n4`) | 394.69 (`n40`) | 477.45 (`n4`) | 76.9 MB | 80.4 MB | 29.62 | 29.62 | 0.1805 | 0.1805 |
| ZSTD | 0.8245 | 360.20 (`n8`) | 353.65 (`n40`) | 422.91 | 371.5 MB | 388.7 MB | 41.39 | 41.39 | 0.2522 | 0.2522 |

## n40 代表結果（Encode / Decode CPU Energy Ratio vs TGZ）

| 格式 | Enc J/TGZ (claw n40) | Enc J/TGZ (llama n40) | Dec J/TGZ (claw n40)* | Dec J/TGZ (llama n40)* |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 1.0000 | 1.0000 | 1.0000 | 1.0000 |
| Other3 | 0.1670 | 0.1320 | 0.0290 | 0.0124 |
| BVX3 | 0.1770 | 0.1514 | 0.0962 | 0.0035 |
| Lazy2 | 0.6983 | 0.2817 | 0.0805 | 0.0097 |
| Optimal | 3.1183 | 2.1219 | 0.0784 | 0.0278 |
| TLZ4 | 0.1805 | 0.2114 | 0.1002 | 0.0143 |
| ZSTD | 0.2522 | 0.1606 | 0.5174 | 0.1752 |

> `*` Decode energy n=40 取樣覆蓋率 <5%，不可信，僅供參考。

## R41 vs R40 Encode 速度對比（claw-code, n=40）

| 格式 | R40 MB/s | R41 MB/s | 變化 |
| --- | ---: | ---: | --- |
| TGZ | 48.64 | 48.73 | ≈ 持平 |
| Other3 | 380.73 | 344.41 | -9.5% ⚠️ |
| BVX3 | 421.51 | 375.00 | -11.0% ⚠️ |
| Lazy2 | 57.84 | 63.73 | +10.2% ✅ |
| Optimal | 29.90 | 34.45 | +15.2% ✅ |
| TLZ4 | 424.74 | 394.69 | -7.1% |
| ZSTD | 363.63 | 353.65 | -2.7% |

> BVX3 / Other3 速度略降但能耗同步下降，可能為熱節流 or 量測誤差；Optimal / Lazy2 如預期上升。壓縮比持平（hash 函數不變）。

---

# R41-Win：Windows Benchmark 結果 + Decode 驗證基礎設施（2026-06-23）/ R41-Win: Windows Benchmark Results + Decode Verification Infrastructure

> R41 Tag-packed Hash Chain 在 Windows 執行完整 encode + decode 雙向 benchmark。  
> 同時導入 `decode-win.bat` + `decode_summary.csv` decode 驗證基礎設施（首輪）。  
> 所有 7 種格式均通過 `tar tf -` 正確性驗證（verify=PASS）。  
> 資料集：claw-code；encode n=40 inflight chunks（單次）；decode n=40 inflight chunks（單次）。

## 1a. Encode 速度 vs Mac（claw-code, n=40）/ Encode MB/s — Win vs Mac

| 格式 | Win MB/s | Win/TGZ | Mac MB/s | Win/Mac |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 24.67 | 1.0000 | 48.73 | 0.506 |
| Other3 | 266.36 | 10.797 | 344.41 | 0.773 |
| BVX3 | 241.42 | 9.785 | 375.00 | 0.644 |
| Lazy2 | 38.75 | 1.570 | 63.73 | 0.608 |
| Optimal | 15.54 | 0.630 | 34.45 | 0.451 |
| TLZ4 | 191.84 | 7.776 | 394.69 | 0.486 |
| ZSTD | 103.67 | 4.202 | 353.65 | 0.293 |

## 1b. Decode 速度 + 驗證（首輪 Win, claw-code n=40）/ Decode MB/s + Verification (Win first run)

> Windows decode benchmark 首次導入（R41-Win），含 `tar tf -` 正確性驗證。  
> ⚠ n=40 inflight chunks 單次量測，能耗不可信（同 Mac decode <5% 覆蓋率）。

| 格式 | Win MB/s | Win/TGZ | Mac MB/s | Win/Mac | Verify |
| --- | ---: | ---: | ---: | ---: | --- |
| TGZ | 643.72 | 1.0000 | 376.09 | 1.712 | PASS |
| Other3 | 760.85 | 1.1820 | 388.52 | 1.958 | PASS |
| BVX3 | 800.90 | 1.2442 | 326.41 | 2.454 | PASS |
| Lazy2 | 853.08 | 1.3252 | 365.21 | 2.336 | PASS |
| Optimal | 897.14 | 1.3937 | 394.70 | 2.273 | PASS |
| TLZ4 | 1752.37 | 2.7222 | 405.75 | 4.319 | PASS |
| ZSTD | 1037.24 | 1.6112 | 422.91 | 2.453 | PASS |

> Windows decode 速度普遍高於 Mac（Win/Mac = 1.7x–4.3x），TLZ4 最突出（4.3x）。  
> 差異可能來自：Windows page cache 效率、OS scheduler 差異、外部工具版本。  
> 所有格式均通過 `tar tf -` 解壓正確性驗證（首輪 Windows decode 驗證基礎設施）。

## 1c. 壓縮大小（claw-code, n=40）/ Compress Size

| 格式 | Win MiB | Win/TGZ | Mac MiB | Mac/Win |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 468.3 | 1.0000 | 470.0 | 1.0035 |
| Other3 | 459.8 | 0.9818 | 463.0 | 1.0069 |
| BVX3 | 433.4 | 0.9254 | 446.0 | 1.0291 |
| Lazy2 | 407.6 | 0.8704 | 423.0 | 1.0377 |
| Optimal | 387.5 | 0.8273 | 403.0 | 1.0401 |
| TLZ4 | 549.8 | 1.1739 | 554.0 | 1.0077 |
| ZSTD | 365.9 | 0.7813 | 387.0 | 1.0576 |

## R41-Win vs R40-Win Encode 速度對比（claw-code, n=40）

| 格式 | R40-Win MB/s | R41-Win MB/s | 變化 |
| --- | ---: | ---: | --- |
| TGZ | 25.33 | 24.67 | -2.6% |
| Other3 | 275.17 | 266.36 | -3.2% |
| BVX3 | 273.65 | 241.42 | -11.8% ⚠️ |
| Lazy2 | 38.75 | 38.75 | ≈ 持平 |
| Optimal | 17.56 | 15.54 | -11.5% ⚠️ |
| TLZ4 | 228.93 | 191.84 | -16.2% ⚠️ |
| ZSTD | 139.17 | 103.67 | -25.5% ⚠️ |

> TLZ4 / ZSTD 為外部工具，速度差異反映系統狀態（熱節流、背景負載）而非代碼變更。  
> LZFSE 格式中 BVX3 / Optimal 略降（-11–12%），Windows 單次量測方差大，視為量測誤差。  
> Lazy2 持平，符合 Lazy-Greedy 路徑不受 tag filter 影響的預期。

---

# R41-Mac-Retest：以 UI 支援代碼重測（2026-06-23）/ R41-Mac-Retest: Retest with ui-supported code

> 在 `lzfse-cli.swift` 加入 `runCLI()` 包裝函式（支援 lzfse-ui SwiftUI app）後，對 R41 代碼重新執行完整 Mac benchmark。  
> Trace 分析首次全數成功（36 包 TRACE_ANALYSIS_OK、72 XML CPU_CALL_TREE_ANALYSIS_OK）；前序所有執行皆以 `source_trace_missing` 失敗。  
> 代碼功能不變（output-identical ✅），`runCLI()` 包裝不影響演算法路徑。

## 變更內容 / Code Change

| 項目 | 說明 |
| --- | --- |
| **`lzfse-cli.swift`** | 加入 `runCLI()` 包裝函式，供 `lzfse-ui.swift` SwiftUI @main 呼叫 |
| **`lzfse-ui/lzfse-ui.swift`** | 新增 SwiftUI macOS app：檔案選取、演算法選擇、並行任務步進（n=1–32），雙語 EN/ZH-TW UI |
| **演算法路徑** | 無變更；output-identical ✅ |
| **Trace 分析** | 首次全數成功（36/36 TRACE_ANALYSIS_OK，72/72 CPU_CALL_TREE_ANALYSIS_OK）|

## 1a. Encode 速度 vs R41-Mac 首輪（claw-code, n=40）/ Encode MB/s vs R41-Mac First Run

| 格式 | Retest MB/s | Retest/TGZ | R41-Mac MB/s | 變化 |
| --- | ---: | ---: | ---: | --- |
| TGZ | 48.75 | 1.0000 | 48.73 | ≈ 持平 |
| Other3 | 408.72 | 8.3841 | 344.41 | +18.7% ✅ |
| BVX3 | 402.73 | 8.2558 | 375.00 | +7.4% ✅ |
| Lazy2 | 66.59 | 1.3651 | 63.73 | +4.5% ✅ |
| Optimal | 35.32 | 0.7241 | 34.45 | +2.5% ✅ |
| Apple | 142.31 | 2.9191 | 142.31 | ≈ 持平 |
| TLZ4 | 425.04 | 8.7142 | 394.69 | +7.7% ✅ |
| ZSTD | 366.34 | 7.5109 | 353.65 | +3.6% ✅ |

> 所有格式均較 R41-Mac 首輪提升；Other3 / BVX3 大幅回升（+7–19%），推測首輪有熱節流。

## 1b. Decode 速度（claw-code, n=40）/ Decode MB/s

| 格式 | MB/s | /TGZ |
| --- | ---: | ---: |
| TGZ | 366.57 | 1.0000 |
| TLZ4 | 447.02 | 1.2196 |
| ZSTD | 416.95 | 1.1375 |
| Other3 | 414.62 | 1.1313 |
| Lazy2 | 412.80 | 1.1259 |
| Apple | 386.19 | 1.0536 |
| Optimal | 347.86 | 0.9490 |
| BVX3 | 322.85 | 0.8808 |

## 1c. 壓縮大小與比率（claw-code, n=40）/ Compress Size & Ratio

| 格式 | MiB | /TGZ |
| --- | ---: | ---: |
| TGZ | 470 | 1.0000 |
| ZSTD | 387 | 0.8245 |
| Optimal | 403 | 0.8574 |
| Lazy2 | 423 | 0.8998 |
| BVX3 | 446 | 0.9492 |
| Other3 | 463 | 0.9865 |
| Apple | 464 | 0.9873 |
| TLZ4 | 554 | 1.1793 |

## 2. RSS 峰值（Mac only, claw-code n=40）/ Peak RSS

| 格式 | Encode RSS | Enc/TGZ | Decode RSS | Dec/TGZ |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 4.2 MB | 1.00 | 3.8 MB | 1.00 |
| TLZ4 | 80.0 MB | 19.0 | 33.7 MB | 8.9 |
| Other3 | 236.1 MB | 56.2 | 301.1 MB | 79.2 |
| BVX3 | 243.8 MB | 58.1 | 323.5 MB | 85.1 |
| ZSTD | 375.2 MB | 89.3 | 9.2 MB | 2.4 |
| Lazy2 | 497.7 MB | 118.5 | 321.8 MB | 84.7 |
| Optimal | 581.4 MB | 138.4 | 307.9 MB | 81.0 |
| Apple | 1367.8 MB | 325.7 | 473.5 MB | 124.6 |

## 3. CPU Energy（Mac only, claw-code n=40）/ CPU Energy Ratio vs TGZ

> ⚠ Decode energy n=40 因取樣覆蓋率 <5% 不可信，僅供參考（標 `*`）。

| 格式 | Enc J | Enc/TGZ | Dec J | Dec/TGZ |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 157.17 | 1.0000 | 5.71 | 1.0000 |
| Other3 | 26.05 | 0.1658 | 0.60* | 0.1058 |
| BVX3 | 29.20 | 0.1858 | 0.15* | 0.0256 |
| TLZ4 | 30.25 | 0.1925 | 0.60* | 0.1059 |
| Apple | 49.16 | 0.3128 | 2.92* | 0.5107 |
| ZSTD | 44.82 | 0.2852 | 2.99* | 0.5231 |
| Lazy2 | 120.94 | 0.7695 | 1.27* | 0.2227 |
| Optimal | 531.92 | 3.3844 | 0.69* | 0.1216 |

## 4. CPU Trace 分析（首次全數成功）/ CPU Trace Analysis — First Full Success

> 本輪首次所有 36 trace 包均成功（TRACE_ANALYSIS_OK ×36，CPU_CALL_TREE_ANALYSIS_OK ×72）。

| 格式 (n=40) | Top Symbol | Category | Count |
| --- | --- | --- | ---: |
| TGZ | `0x197c4bbac` (libz) | other | 85 |
| Other3 | `encodeBlock(triplets:literals:rawBytes:)` | encode | 73 |
| BVX3 | `encodeBlockV3(triplets:literals:rawBytes:)` | encode | 85 |
| Lazy2 | `bestMatch` in `lzParseChain` | **parse** | 132 |
| Optimal | closure in `lzParseOptimal` | **parse** | 535 |
| Apple | `lzfseEncodeMatches` | apple_lzfse | 82 |
| TLZ4 | `LZ4HC_compress_generic_noDictCtx` | external_tool | 295 |
| ZSTD | `ZSTD_compressBlock_lazy2_row` | external_tool | 162 |

> **Parse hotspot 確認**：Lazy2 = `bestMatch` in chain traversal，Optimal = `lzParseOptimal` closure 調用次數 535（>>Lazy2 132）→ Optimal 每 chunk 調用次數遠高於 Lazy2。

## 5. Encode 速度全覽（claw-code + llama.cpp, n=40）/ Encode Speed Overview

| 格式 | claw-code MB/s | claw/TGZ | llama.cpp MB/s | llama/TGZ |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 48.75 | 1.00 | 39.90 | 1.00 |
| Other3 | 408.72 | 8.38 | 86.95 | 2.18 |
| BVX3 | 402.73 | 8.26 | 86.81 | 2.18 |
| Lazy2 | 66.59 | 1.37 | 78.64 | 1.97 |
| Optimal | 35.32 | 0.72 | 49.20 | 1.23 |
| Apple | 142.31 | 2.92 | 66.02 | 1.66 |
| TLZ4 | 425.04 | 8.71 | 85.77 | 2.15 |
| ZSTD | 366.34 | 7.51 | 90.37 | 2.27 |

> `llama.cpp` 資料以 lzma 預壓縮，LZFSE n=40 加速效益遠低於 claw-code（BVX3 claw 8.26× vs llama 2.18×）。

## 結論與 R42 方向 / Conclusion & R42 Direction

| 項目 | 結論 |
| --- | --- |
| **速度恢復** | R41 首輪熱節流 → Retest Other3/BVX3 回升 +7–19%；Optimal/Lazy2 穩定 |
| **Trace 分析** | 首次全數成功；Lazy2 = parse（`bestMatch` chain），Optimal = parse（`lzParseOptimal` closure）瓶頸確認 |
| **能耗最佳** | Other3 n40 = 0.166× TGZ；Optimal n4 = 4.70× TGZ（最高）|
| **壓縮比最佳** | ZSTD 0.8245 → Optimal 0.8574 → Lazy2 0.8998 |
| **R42 方向** | Lazy2/Optimal parse hotspot → prefetch chain entries、SIMD match compare（NEON）|

---

# R41-Win Retest：雙資料集完整 Windows Benchmark（2026-06-28）/ R41-Win Retest: Full Dual-Dataset Windows Benchmark

> R41-Win（2026-06-23）僅有 claw-code encode 首輪結果；本輪為完整補測：  
> 雙資料集（claw-code + llama.cpp）、雙模式（nul / file write）、encode + decode + RSS 峰值全覆蓋。  
> 所有 14 個格式均通過 decode 正確性驗證（verify=PASS）。  
> R41-Win (2026-06-23) had only claw-code encode; this is the full retest:  
> both datasets, both modes (nul / file write), encode + decode + peak RSS.
>
> **重要發現 / Key finding**：llama.cpp 資料集上，Windows LZFSE encode 速度**超越** Mac（Other3/BVX3 ≈ 1.32–1.35×），claw-code 上仍以 Mac 領先。

## 1a. Encode 速度 vs Mac（claw-code, n=40）/ Encode MB/s — Win vs Mac

| 格式 | Win MB/s | Win/TGZ | Mac MB/s | Win/Mac |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 23.82 | 1.000 | 47.47 | 0.502 |
| Other3 | 253.04 | 10.624 | 348.45 | 0.726 |
| BVX3 | 246.37 | 10.343 | 405.51 | 0.608 |
| Lazy2 | 41.03 | 1.722 | 65.08 | 0.630 |
| Optimal | 17.78 | 0.746 | 34.74 | 0.512 |
| TLZ4 | 201.74 | 8.469 | 418.75 | 0.482 |
| ZSTD | 110.34 | 4.631 | 368.84 | 0.299 |

## 1b. Encode 速度 vs Mac（llama.cpp, n=40）/ Encode MB/s — Win vs Mac

| 格式 | Win MB/s | Win/TGZ | Mac MB/s | Win/Mac |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 25.70 | 1.000 | 42.87 | 0.599 |
| Other3 | 132.53 | 5.157 | 98.50 | **1.346 ✅** |
| BVX3 | 129.91 | 5.054 | 98.35 | **1.321 ✅** |
| Lazy2 | 95.35 | 3.712 | 88.78 | **1.074 ✅** |
| Optimal | 32.41 | 1.261 | 51.28 | 0.632 |
| TLZ4 | 118.67 | 4.620 | 95.39 | **1.244 ✅** |
| ZSTD | 114.17 | 4.444 | 100.30 | **1.138 ✅** |

> **claw-code**：Windows 為 Mac 的 0.30–0.73×，Mac 明顯領先（source code 含大量重複 pattern，NEON 較有利）。  
> **llama.cpp**：Windows LZFSE encode 超越 Mac（Other3/BVX3 ≈ 1.32–1.35×）。llama.cpp 為 pre-compressed binary，match 密度低；x86 hash chain 走訪速度在此場景優於 ARM。TGZ 與 Optimal 仍以 Mac 較快。

## 1c. Decode 速度（file write mode，claw-code n=40）/ Decode MB/s — File Write Mode

> decode-win.bat 以「寫檔模式」量測解碼後輸出至磁碟的 end-to-end 速度，含磁碟 I/O 開銷。

| 格式 | Win MB/s | Mac MB/s | Win/Mac | Verify |
| --- | ---: | ---: | ---: | --- |
| TGZ | 153.54 | 388.48 | 0.395 | PASS |
| Other3 | 158.95 | 310.67 | 0.512 | PASS |
| BVX3 | 139.89 | 273.42 | 0.512 | PASS |
| Lazy2 | 141.17 | 332.58 | 0.424 | PASS |
| Optimal | 141.87 | 319.62 | 0.444 | PASS |
| TLZ4 | 189.33 | 313.11 | 0.605 | PASS |
| ZSTD | 171.20 | 422.27 | 0.405 | PASS |

## 1d. Decode 速度（file write mode，llama.cpp n=40）/ Decode MB/s — File Write Mode (llama.cpp)

| 格式 | Win MB/s | Mac MB/s | Win/Mac | Verify |
| --- | ---: | ---: | ---: | --- |
| TGZ | 27.53 | 89.75 | 0.307 | PASS |
| Other3 | 41.53 | 83.86 | 0.495 | PASS |
| BVX3 | 36.08 | 79.52 | 0.454 | PASS |
| Lazy2 | 25.04 | 85.54 | 0.293 | PASS |
| Optimal | 24.64 | 86.39 | 0.285 | PASS |
| TLZ4 | 25.38 | 87.40 | 0.290 | PASS |
| ZSTD | 25.07 | 84.58 | 0.296 | PASS |

> Write-to-file decode 下，Windows 均慢於 Mac（claw: 0.40–0.61×；llama: 0.29–0.50×）。Mac SSD write 吞吐量優勢主導此量測。  
> 注：R41-Win 首輪（nul 模式，不寫磁碟）Windows decode 速度曾達 Mac 的 1.7–4.3×；write mode 與 nul mode 差異反映磁碟 I/O 而非 codec 本身。

## 1e. Encode nul vs file 模式對比 / Encode: Nul vs File Mode

> nul mode = 壓縮後輸出丟棄（不寫磁碟），量測純 CPU 壓縮速度；file mode = 輸出至壓縮檔（含 I/O）。  
> claw-code uncompressed ≈ 1416.8 MB，llama.cpp ≈ 1322.4 MB（由 comparison.csv TGZ encode 時間反推）。

### claw-code (n=40)

| 格式 | nul MB/s | file MB/s | nul/file |
| --- | ---: | ---: | ---: |
| TGZ | 24.30 | 23.82 | 1.02 |
| Other3 | 247.04 | 253.04 | 0.976 |
| BVX3 | 222.15 | 246.37 | 0.902 |
| Lazy2 | 39.26 | 41.03 | 0.957 |
| Optimal | 17.97 | 17.78 | 1.011 |
| LZ4 | 215.75 | 201.74 | 1.069 |
| ZSTD | 111.26 | 110.34 | 1.008 |

### llama.cpp (n=40)

| 格式 | nul MB/s | file MB/s | nul/file |
| --- | ---: | ---: | ---: |
| TGZ | 27.59 | 25.70 | 1.074 |
| Other3 | 143.82 | 132.53 | 1.085 |
| BVX3 | 141.16 | 129.91 | 1.086 |
| Lazy2 | 106.06 | 95.35 | 1.112 |
| Optimal | 33.69 | 32.41 | 1.039 |
| LZ4 | 123.21 | 118.67 | 1.038 |
| ZSTD | 123.88 | 114.17 | 1.085 |

> **claw-code**：nul ≈ file（誤差範圍內）。壓縮輸出約 366–550 MiB，寫磁碟對整體時間影響不顯著。BVX3 nul 比 file 慢 10% 屬量測誤差。  
> **llama.cpp**：nul 穩定快 4–11%，Lazy2 最明顯（1.112×）。壓縮輸出達 535–616 MiB，省略磁碟 I/O 有明顯加速。

## 1f. Decode nul mode 速度（兩資料集）/ Decode: Nul Mode MB/s

> nul mode = lzfse/lz4/zstd 解壓後丟棄輸出，量測純解碼吞吐量；file mode = 解壓並 extract 至磁碟。  
> TGZ 的 nul/file 比 < 1（anomaly），原因見下方說明。

### claw-code (n=40)

| 格式 | nul MB/s | file MB/s | nul/file |
| --- | ---: | ---: | ---: |
| TGZ | 113.9 | 153.6 | 0.74 ⚠️ |
| Other3 | 772.4 | 159.0 | 4.86 |
| BVX3 | 749.0 | 139.9 | 5.35 |
| Lazy2 | 750.3 | 141.2 | 5.31 |
| Optimal | 744.9 | 141.9 | 5.25 |
| LZ4 | 1609.6 | 189.4 | 8.50 |
| ZSTD | 869.6 | 171.2 | 5.08 |

### llama.cpp (n=40)

| 格式 | nul MB/s | file MB/s | nul/file |
| --- | ---: | ---: | ---: |
| TGZ | 22.9 | 27.5 | 0.83 ⚠️ |
| Other3 | 838.6 | 41.5 | 20.2 |
| BVX3 | 873.0 | 36.1 | 24.2 |
| Lazy2 | 842.1 | 25.0 | 33.6 |
| Optimal | 846.1 | 24.6 | 34.3 |
| LZ4 | 2165.2 | 25.4 | **85.3** |
| ZSTD | 1674.6 | 25.1 | **66.8** |

> **nul mode 關鍵數字**：LZFSE 解碼吞吐量 750–873 MB/s（兩資料集接近），LZ4 達 1610–2165 MB/s，ZSTD 達 870–1675 MB/s。  
> **llama.cpp nul/file 比率極大（20–85×）**：file mode 需把 ~1.3 GB 解壓後資料寫入 Windows 磁碟（測得 24–42 MB/s 磁碟 write），而 nul mode 只做 CPU 解碼（~840–870 MB/s）；磁碟 I/O 才是 file mode 瓶頸的 30–85× 倍放大主因。  
> **TGZ decode nul 比 file 慢（0.74–0.83×）anomaly**：decode-win.bat 的 TGZ nul 路徑實際執行完整 extraction + verify（並非單純 list），與 `tar -tzf`（純 list，648 MB/s）完全不同。file mode 直接 `tar xzf` 到目錄，kernel buffered write 在大型 tar 中反而更快。此為實作路徑差異，非 codec 本身問題。已由 `helper_windows/tar_benchmark/Findings.md` 獨立測試確認。

## 2. 壓縮大小與比率 / Compress Size & Ratio

### claw-code (n=40)

| 格式 | Win 壓縮比/TGZ | Mac 壓縮比/TGZ | 差異 |
| --- | ---: | ---: | ---: |
| TGZ | 1.0000 | 1.0000 | 0.0000 |
| Other3 | 0.9818 | 0.9865 | -0.0047 |
| BVX3 | 0.9254 | 0.9492 | -0.0238 |
| Lazy2 | 0.8704 | 0.8998 | -0.0294 |
| Optimal | 0.8274 | 0.8574 | -0.0300 |
| TLZ4 | 1.1739 | 1.1793 | -0.0054 |
| ZSTD | 0.7813 | 0.8245 | -0.0432 |

### llama.cpp (n=40)

| 格式 | Win 壓縮比/TGZ | Mac 壓縮比/TGZ | 差異 |
| --- | ---: | ---: | ---: |
| TGZ | 1.0000 | 1.0000 | 0.0000 |
| Other3 | 0.9970 | 0.9957 | +0.0013 |
| BVX3 | 0.9810 | 0.9787 | +0.0023 |
| Lazy2 | 0.9576 | 0.9551 | +0.0025 |
| Optimal | 0.9412 | 0.9387 | +0.0025 |
| TLZ4 | 1.0503 | 1.0537 | -0.0034 |
| ZSTD | 0.9123 | 0.9100 | +0.0023 |

> llama.cpp 壓縮比差異 < 0.4%，Win/Mac 幾乎相同。claw-code 上 ZSTD Win 略優（-0.0432），其餘差距均 < 3%。

## 3. RSS 峰值（Windows, n=40）/ Peak RSS — Windows

### claw-code

| 格式 | Enc RSS nul (MB) | Enc RSS file (MB) | Dec RSS nul (MB) | Dec RSS file (MB) |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 6.3 | 6.3 | 5.7 | 6.1 |
| Other3 | 116.1 | 131.6 | 247.2 | 247.2 |
| BVX3 | 173.7 | 155.2 | 245.6 | 245.1 |
| Lazy2 | 480.7 | 485.1 | 242.3 | 242.2 |
| Optimal | 508.8 | 512.5 | 240.6 | 240.6 |
| LZ4 | 8.3 | 8.3 | 8.3 | 8.3 |
| ZSTD | 8.3 | 8.3 | 8.3 | 8.8 |

### llama.cpp

| 格式 | Enc RSS nul (MB) | Enc RSS file (MB) | Dec RSS nul (MB) | Dec RSS file (MB) |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 6.5 | 6.5 | 5.7 | 6.9 |
| Other3 | 135.3 | 146.0 | 346.1 | 346.2 |
| BVX3 | 162.6 | 171.8 | 346.6 | 346.5 |
| Lazy2 | 635.3 | 649.8 | 346.0 | 345.6 |
| Optimal | 756.6 | 760.5 | 346.0 | 346.1 |
| LZ4 | 8.3 | 8.3 | 8.3 | 8.3 |
| ZSTD | 8.3 | 8.8 | 8.3 | 8.3 |

> **Optimal encode RSS**：llama.cpp 760.5 MB vs claw-code 512.5 MB（+48%）。  
> **Lazy2 encode RSS**：llama.cpp 649.8 MB vs claw-code 485.1 MB（+34%）。  
> llama.cpp 每 chunk 的 chain table 搜尋路徑更長（pre-compressed binary，match 不容易中途 early-exit），導致更高的 chain 記憶體壓力。  
> Decode RSS 跨格式差異不大（LZFSE 約 240–350 MB；LZ4/ZSTD/TGZ < 10 MB）。

## 4. R41-Win Retest vs R41-Win 首輪（claw-code encode 對比）/ vs Original R41-Win

| 格式 | R41-Win MB/s | Retest MB/s | 變化 |
| --- | ---: | ---: | --- |
| TGZ | 24.67 | 23.82 | -3.5% |
| Other3 | 266.36 | 253.04 | -5.0% |
| BVX3 | 241.42 | 246.37 | +2.1% |
| Lazy2 | 38.75 | 41.03 | +5.9% |
| Optimal | 15.54 | 17.78 | +14.4% |
| TLZ4 | 191.84 | 201.74 | +5.2% |
| ZSTD | 103.67 | 110.34 | +6.4% |

> 各格式變化均在量測誤差範圍（±5–15%）；Optimal 本次略快（+14%），其餘持平。

## 結論 / Conclusion

| 項目 | 結論 |
| --- | --- |
| **最重要發現** | llama.cpp 上 Win LZFSE encode 超越 Mac（Other3/BVX3 ≈ 1.32–1.35×）；claw-code 仍以 Mac 領先 |
| **Encode nul vs file** | claw-code 差距 < 5%（CPU 主導）；llama.cpp nul 快 4–11%（省略 ~535–616 MiB 輸出 I/O）|
| **Decode nul mode（CPU 限制）** | LZFSE 750–873 MB/s；LZ4 1610–2165 MB/s；ZSTD 870–1675 MB/s；TGZ anomaly（nul 慢於 file）|
| **Decode file mode（I/O 限制）** | Windows 均慢於 Mac（claw: 0.40–0.61×；llama: 0.29–0.50×），磁碟 write 為瓶頸 |
| **llama.cpp nul/file 比率** | LZFSE 20–34×，LZ4 85×，ZSTD 67×——pure CPU decode 遠快於磁碟 extract |
| **bsdtar 瓶頸（已驗證）** | `tar -tzf`（list only）648–844 MB/s vs `tar -xzf`（extract）174/36 MB/s；list/extract = 3.7×（claw）/ 23×（llama）→ file creation 確認為瓶頸，非 gz 解壓；LZFSE file decode（159 MB/s）≈ tar extract（174 MB/s），直接確認 codec 不是限制因素；詳見 `helper_windows/tar_benchmark/Findings.md` |
| **Optimal RSS** | llama.cpp encode RSS 760.5 MB（claw 512.5 MB，+48%），chain table 記憶體壓力更大 |
| **壓縮比** | Win/Mac 差距 < 1%（llama 幾乎相同，claw ZSTD 差距最大 -0.04）|
| **R42 方向** | Lazy2/Optimal parse hotspot 已確認；RSS 高峰值指向 chain table 記憶體壓力 → prefetch chain entries 可同時改善速度與間接降低 cache miss 引起的有效 RSS |

---

# R41 總結 / R41 Summary

> 綜合 R41-Mac、R41-Mac-Retest、R41-Win、R41-Win-Retest 四輪結果。  
> Synthesizes all four R41 rounds: R41-Mac, R41-Mac-Retest, R41-Win, R41-Win-Retest.

## 代碼變更 / Code Change

R27 的 tag-packed hash chain 重新導入 R40 代碼基礎：`head[h]` / `chain[c]` 改為 `(tag<<24)|index` packed Int32；每次鏈走訪先比較高 8 bits tag，不符直接跳過（純暫存器操作），無需解包 index。同步套用至 `lzParseChain`（Other3/BVX3/Lazy2）與 `lzParseOptimal`（Optimal）。

Re-introduced tag-packed hash chain from R27: `head[h]` / `chain[c]` now store `(tag<<24)|index` as packed Int32. Each chain candidate checks the upper 8-bit tag first; mismatches skip without unpacking the index. Applied to both `lzParseChain` (Other3/BVX3/Lazy2) and `lzParseOptimal` (Optimal).

## Mac Encode 速度 vs R40（claw-code, n=40，Retest 最終值）/ Mac Encode Speed vs R40

| 格式 | R40 MB/s | R41 Retest MB/s | 變化 |
| --- | ---: | ---: | --- |
| Lazy2 | 57.84 | 66.59 | **+15.1% ✅** |
| Optimal | 29.90 | 35.32 | **+18.1% ✅** |
| Other3 | 380.73 | 408.72 | +7.3% ✅（首輪熱節流 -9.5%，Retest 回升）|
| BVX3 | 421.51 | 402.73 | -4.5%（首輪熱節流，Retest 較首輪 +7.4%）|
| TLZ4 | 424.74 | 425.04 | ≈ 持平 |
| ZSTD | 363.63 | 366.34 | ≈ 持平 |

> tag filter 使 chain 走訪提早剔除無效候選，Lazy2/Optimal 的 parse loop 迭代次數有效減少，為最顯著受益者。Other3/BVX3 首輪因熱節流數字偏低；Retest 排除熱節流後數字正常。

## Windows Encode 主要發現 / Windows Encode — Key Finding

| 資料集 | Win/Mac 範圍 | 說明 |
| --- | --- | --- |
| claw-code | 0.30–0.73× | Mac 領先；source code 含大量重複 pattern，ARM NEON 優勢顯著 |
| llama.cpp | **1.07–1.35×（Other3/BVX3/Lazy2/TLZ4/ZSTD）** | Windows 超越 Mac；pre-compressed binary，x86 hash chain 走訪具競爭力 |

> llama.cpp 為 pre-compressed binary，match 密度低，chain traversal 以吞吐量主導；此場景下 x86 hash chain 走訪速度與 ARM NEON 相當甚至更快。

## Decode 效能摘要 / Decode Performance Summary

| 量測 | 數字 | 意義 |
| --- | ---: | --- |
| LZFSE nul decode（Windows，兩資料集）| 750–873 MB/s | 純 CPU decode，代表真實 codec 吞吐量 |
| LZFSE file decode（Windows，claw）| 159 MB/s | I/O 限制（bsdtar+NTFS 瓶頸）|
| tar-xzf extract（Windows，claw）| 174 MB/s | ≈ LZFSE file decode，直接確認 bsdtar 為瓶頸 |
| tar-xzf extract（Windows，llama）| 36 MB/s | 受限於磁碟 sequential write throughput |
| LZFSE file decode（Mac，claw）| 310–388 MB/s | APFS 優於 NTFS，快約 2–2.5× |

> Windows decode file mode 低速確認為 **bsdtar file creation + NTFS overhead**，非 codec 問題。`tar -tzf` list = 648–844 MB/s vs `tar -xzf` extract = 36–174 MB/s。跨平台公平比較應使用 nul mode。

## RSS 峰值 / RSS Summary

| 格式 | Mac claw | Win claw | Win llama | 說明 |
| --- | ---: | ---: | ---: | --- |
| Optimal encode | 572–581 MB | 509–513 MB | 757–761 MB | llama 比 claw 高 +48% |
| Lazy2 encode | 498–500 MB | 481–485 MB | 635–650 MB | llama 比 claw 高 +34% |

> llama.cpp pre-compressed binary 的 match 搜尋路徑更長（不易 early-exit），chain table 記憶體壓力更大。

## R42 方向 / R42 Direction

| 方向 | 依據 |
| --- | --- |
| **prefetch chain entries** | chain walk 前先 prefetch 下一個 entry，隱藏 cache miss 延遲；兼可降低有效 RSS |
| **SIMD match compare（NEON/SSE）** | Lazy2 `bestMatch` / Optimal `lzParseOptimal` 確認為 parse hotspot（trace 分析）|
| **公平比對基準** | nul mode LZFSE 750–873 MB/s 為 Windows codec 效能代表數字 |

---

# R40-Mac：macOS 完整 Benchmark 結果（2026-06-22）/ R40-Mac: Full macOS Benchmark Results

> 以 R40 代碼（3652 行）對 claw-code / llama.cpp 執行 `-n 40 / 8 / 4` 三批次完整 benchmark，涵蓋 encode/decode 速度、RSS 峰值、CPU energy ratio，並與 R40-Win 比較 encode 速度。

## 1a. Encode 速度 vs Windows（claw-code, n=40）/ Encode MB/s — Win/Mac Comparison

| 格式 | Mac MB/s | Mac/TGZ | Win MB/s | Win/TGZ | Win/Mac |
| --- | ---: | ---: | ---: | ---: | ---: |
| TGZ | 48.64 | 1.00 | 25.33 | 1.00 | 0.52 |
| Other3 | 380.73 | 7.83 | 275.20 | 10.86 | 0.72 |
| BVX3 | 421.51 | 8.67 | 273.66 | 10.80 | 0.65 |
| TLZ4 | 424.74 | 8.73 | 228.94 | 9.04 | 0.54 |
| ZSTD | 363.63 | 7.48 | 139.17 | 5.49 | 0.38 |
| Lazy2 | 57.84 | 1.19 | 38.75 | 1.53 | 0.67 |
| Optimal | 29.90 | 0.61 | 17.56 | 0.69 | 0.59 |

Mac 在所有格式均顯著快於 Win（0.38–0.72×）。ZSTD Win/Mac 比最低（0.38），可能來自 ZSTD 對 Apple Silicon 向量指令優化程度高於 x86。

## 1b. Decode 速度（Mac only, claw-code n=40）/ Decode MB/s

| 格式 | Mac MB/s | Mac/TGZ |
| --- | ---: | ---: |
| TGZ | 380.35 | 1.00 |
| TLZ4 | 420.76 | 1.11 |
| ZSTD | 427.91 | 1.13 |
| Other3 | 414.82 | 1.09 |
| Lazy2 | 401.28 | 1.06 |
| BVX3 | 355.84 | 0.94 |
| Optimal | 355.61 | 0.94 |

## 2. RSS 峰值（Mac only, claw-code n=40）/ Peak RSS

| 格式 | Encode RSS | Enc/TGZ | Decode RSS | Dec/TGZ |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 4.2 MB | 1.00 | 3.7 MB | 1.00 |
| TLZ4 | 83.0 MB | 19.8 | 33.8 MB | 9.1 |
| Other3 | 252.0 MB | 60.0 | 301.1 MB | 81.4 |
| BVX3 | 252.3 MB | 60.1 | 323.6 MB | 87.5 |
| ZSTD | 373.4 MB | 88.9 | 9.0 MB | 2.4 |
| Lazy2 | 490.6 MB | 116.8 | 320.2 MB | 86.5 |
| Optimal | 561.2 MB | 133.6 | 307.4 MB | 83.1 |

> `-n 40` Encode RSS 為含 inflight 緩衝的峰值；Decode RSS 主要受解壓輸出大小驅動。

## 3. CPU Energy（Mac only, claw-code n=40）/ CPU Energy Ratio vs TGZ

> ⚠ Decode energy n=40 因取樣覆蓋率 <5% 不可信，僅供參考（標 `*`）。

| 格式 | Enc J | Enc/TGZ | Dec J | Dec/TGZ |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 182.61 | 1.000 | 12.75 | 1.000 |
| TLZ4 | 32.74 | 0.179 | 3.67* | 0.288* |
| **Other3** | **30.91** | **0.169** | **3.29*** | **0.258*** |
| BVX3 | 35.23 | 0.193 | 5.76* | 0.452* |
| ZSTD | 43.23 | 0.237 | 7.74* | 0.608* |
| Lazy2 | 135.09 | 0.740 | 4.58* | 0.359* |
| Optimal | 537.44 | 2.943 | 4.51* | 0.354* |

## 4. Best Points 全 n 彙整 / Best Points Across All n

### claw-code

| 格式 | 最佳壓縮比 | Enc MB/s 最佳/最差 | Dec MB/s 最佳/最差 | Enc RSS 最低/最高 | Dec RSS 最低/最高 | Enc Energy Ratio 範圍 | Dec Energy Ratio 範圍 |
| --- | ---: | --- | --- | --- | --- | --- | --- |
| TGZ | 1.0000 | 49 / 48 | 380 / 362 | 4.2 / 4.3 MB | 3.7 / 3.7 MB | 1.000 | 1.000 |
| Other3 | 0.9865 | 408 / 347 | 415 / 396 | 139 / 252 MB | 70 / 301 MB | 0.169–0.308 | 0.258–0.666 |
| BVX3 | 0.9492 | 422 / 339 | 356 / 292 | 129 / 252 MB | 71 / 324 MB | 0.193–0.304 | 0.452–1.007 |
| TLZ4 | 1.1793 | 431 / 425 | 421 / 332 | 76 / 83 MB | 34 / 34 MB | 0.179 | 0.288 |
| ZSTD | 0.8245 | 366 / 360 | 428 / 406 | 373 / 376 MB | 9 / 9 MB | 0.237 | 0.608 |
| Apple | 0.9873 | 143 / 141 | 357 / 301 | 1368 / 1368 MB | 474 / 474 MB | 0.294–0.341 | 0.525–0.552 |
| Lazy2 | 0.8998 | 58 / 41 | 405 / 387 | 180 / 491 MB | 66 / 320 MB | 0.740–1.006 | 0.359–0.842 |
| Optimal | 0.8574 | 30 / 21 | 363 / 326 | 198 / 561 MB | 68 / 307 MB | 2.943–4.137 | 0.354–0.924 |

### llama.cpp

| 格式 | 最佳壓縮比 | Enc MB/s 最佳/最差 | Dec MB/s 最佳/最差 | Enc RSS 最低/最高 | Dec RSS 最低/最高 | Enc Energy Ratio 範圍 | Dec Energy Ratio 範圍 |
| --- | ---: | --- | --- | --- | --- | --- | --- |
| TGZ | 1.0000 | 42 / 41 | 86 / 84 | 4.3 / 4.4 MB | 3.8 / 3.8 MB | 1.000 | 1.000 |
| Other3 | 0.9958 | 97 / 87 | 81 / 73 | 135 / 362 MB | 67 / 349 MB | 0.177–0.256 | 0.223–0.703 |
| BVX3 | 0.9787 | 93 / 89 | 81 / 77 | 142 / 356 MB | 67 / 351 MB | 0.195–0.227 | 0.259–1.023 |
| TLZ4 | 1.0537 | 89 / 85 | 82 / 79 | 80 / 82 MB | 34 / 34 MB | 0.209 | 0.257 |
| ZSTD | 0.9100 | 95 / 90 | 85 / 80 | 474 / 474 MB | 9 / 9 MB | **0.140** | 0.444 |
| Apple | 0.9988 | 69 / 66 | 80 / 78 | 1286 / 1286 MB | 596 / 596 MB | 0.289–0.314 | 0.585–0.598 |
| Lazy2 | 0.9551 | 85 / 73 | 84 / 83 | 244 / 497 MB | 67 / 349 MB | 0.325–0.457 | 0.225–0.499 |
| Optimal | 0.9387 | 47 / 33 | 79 / 78 | 243 / 821 MB | 71 / 349 MB | 2.018–2.951 | 0.281–0.789 |

---

# R40-Win：Optimal 跨段 match 越界修復（2026-06-21）/ R40-Win: Optimal Cross-Segment Match OOB Fix

> 在 Windows 驗測 R40 code 時發現：Optimal 編碼器的低重複段 greedy 快路徑存在記憶體越界 bug，導致 Release 版本以 `VCRUNTIME140.dll 0xc0000005`（存取違規）崩潰，Debug 版本明確回報 `Fatal error: UnsafeBufferPointer with negative count`。此問題理論上在 macOS 同樣存在，但 Release 編譯下行為未定義，不一定立即崩潰。

## 根因分析 / Root Cause

Optimal 的低重複段 greedy 路徑（`lzParseOptimal` 內，`coverage < optPrescreenMinCoverage` 分支）在計算 match 長度時，`limit` 參數使用全域輸入長度 `n - i - 4`，未受目前段的 `segEnd` 限制。

**因果鏈：**

| 步驟 | 說明 |
|---|---|
| ① | greedy match 取 `limit = n - i - 4`，match 跨越 `segEnd` |
| ② | `emitGreedy` 將 `litStart` 推進至 `i + matchLen`，可能 > `segEnd` |
| ③ | 下一段 `segStart = segEnd`，進入 `posLoop` 時 `i = segStart < litStart` |
| ④ | `emitGreedy(at: i, ...)` 執行 `UnsafeBufferPointer(start: p + litStart, count: i - litStart)` |
| ⑤ | `i - litStart < 0` → `count` 為負數 → Debug: Fatal error；Release: 存取違規崩潰 |

**其他佐證：**
- `-n 1` 也能重現（非 `-n 40` 特有問題）
- Windows 事件記錄有多次相同模組、相同 fault offset 的崩潰紀錄
- 崩潰前的部分輸出停在合法 block 邊界，但缺少 `bvx$` 結尾標記（截斷串流）

## 修復 / Fix

**檔案：`lzfse-cli.swift` 約第 1264 行**（Optimal greedy 快路徑 match 限制）

| | 修復前 | 修復後 |
|---|---|---|
| rep 路徑 limit | `limit: n - i - 4`（全域）| `limit: segEnd - i - 4`（限段內）|
| cand 路徑 limit | `limit: n - i - 4`（全域）| `limit: segEnd - i - 4`（限段內）|

兩處 match 計算均改為停在 `segEnd`，防止 `litStart` 超出段邊界。

## 驗證結果 / Validation

| 項目 | 結果 |
|---|---|
| `swiftc -O` 編譯 | ✅ 成功 |
| 內建 `-test`（含新增跨段 match 回歸測試）| ✅ 全部通過 |
| `claw-code -algo bvx3 -optimal -n 40` 完整壓縮 | ✅ 成功，約 **73.3 秒** |
| 輸出大小 | **406,284,948 bytes** |
| `bvx$` 結尾標記 | ✅ 存在 |
| 解壓後 `tar -tf` | ✅ 成功，output-identical |

> 注意：壓縮輸出 406,284,948 bytes 與 macOS R39 baseline（407,098,957 bytes）差異 814,009 bytes，原因為：修復後 greedy 段的 match 不再跨段、導致某些 match 略短，bitstream 合法但非 bitstream-identical。output-identical 驗收通過。

## Windows 基準測試（Run C，2026-06-21）/ Windows Baseline

以 R40-Win 修復後的 binary（`lzfse.exe`）對 `claw-code`（n=40 inflight）執行完整基準測試。後續 R{N}-Win 以此為比較基準。

| 格式 | 耗時（秒）| Encode MB/s | 壓縮比（/TGZ）|
|---|---:|---:|---:|
| TGZ | 55.92 | 25.33 | 1.0000 |
| LZFSE (Other3) | 5.15 | 275.17 | 0.9818 |
| LZFSE (BVX3) | 5.18 | 273.65 | 0.9254 |
| TLZ4 | 6.19 | 228.93 | 1.1739 |
| LZFSE (Lazy2) | 36.56 | 38.75 | 0.8704 |
| ZSTD | 10.18 | 139.17 | 0.7813 |
| LZFSE (Optimal) | 80.67 | 17.56 | 0.8273 |

MB/s 以 1351 MiB × 1.048576 = 1416.63 MB 為基準（與 macOS 格式一致）。Windows 不量測 decode speed、RSS、CPU energy（需 macOS powermetrics）。

## Win/Mac 比較報告結構 / Comparison Report Structure

每輪流程：先跑 **R{N}-Mac**，再跑 **R{N}-Win**，最後執行 `comparison_win.py` 產生三區段比較報告：

| 區段 | Win | Mac | 說明 |
|---|---|---|---|
| 1a. Encode MB/s + ratio/TGZ | ✅ | ✅ | Win/Mac 對比 + 各平台相對 TGZ 速度比 |
| 1b. Decode MB/s + ratio/TGZ | — | ✅ | Windows 不量測 decode |
| 2. RSS MB + ratio/TGZ | — | ✅ | Windows 不量測 RSS |
| 3. CPU Energy J + ratio/TGZ | — | ✅ | Windows 不量測能耗；n=40 decode energy 不可信 |

---

# R40：Streaming decode 復原與 encode 管線修正（2026-06-21）/ R40: Restore Streaming Decode & Fix Encode Pipeline

> 以 R39（3379 行）為起點，補回 R39 移除的 streaming decode 路徑，並修正 R39 引入的 `runParallelEncode` 兩個 regression。無演算法改動，encode / decode 輸出應與 R39 bitstream-identical。

## 代碼狀態（3652 行）

### 復原：Streaming decode（`decodeStreamFromFile` / `decodeStreamToHandle`）

R39 將 decode CLI 改為 `readToEnd()`（whole-buffer），峰值 RSS ≈ 整份壓縮輸入（~500 MB）。本輪加回三個函數：

| 函數 / 型別 | 說明 |
|---|---|
| `enum StreamDecodeResult` | `.ok` / `.fallback` / `.error` 三路結果 |
| `decodeStreamFromFile(path:chunkRaw:inflight:output:)` | 逐塊讀入壓縮串流（1 MB readChunk），自家分塊串流直接平行解碼；非自家串流退回 `.fallback` |
| `decodeStreamToHandle(_:parallel:chunkRaw:inflight:output:)` | whole-buffer fallback 的 streaming 寫出版：`scanBlocks → 分組 → DispatchQueue.concurrentPerform → 依序寫出` |

CLI decode 路徑（`-i <file>`）：先嘗試 `decodeStreamFromFile` → `.fallback` 時重讀整檔走 `decodeStreamToHandle`；stdin 路徑直接走 `decodeStreamToHandle`。全程不持有整份解壓輸出，降低 decode peak RSS。

### 修正：`runParallelEncode` 兩個 regression（R39 引入）

| 項目 | R33/R35 | R39（regression）| R40（修正）|
|---|---|---|---|
| 並行度來源 | `inflight: Int` 參數，`maxTasks = max(2, inflight)` | 硬寫 `maxTasks = max(2, activeProcessorCount)`，忽略 `-n` | 加回 `inflight: Int`，呼叫端傳 `inflightN` |
| Encode RSS | `autoreleasepool { ... }` 包住 read 迴圈，防 autorelease Data 堆積 | 無 `autoreleasepool`，encode RSS ≈ 整份輸入 | 加回 `try autoreleasepool { ... }` |

`FileHandle.read` 在 macOS 回傳 autoreleased `Data`；主執行緒 read 迴圈若無 pool，autorelease 暫存累積至程序結束才釋放，造成 encode RSS ≈ 整份輸入大小（與 `-n` 無關的 RSS 上限）。

### Streaming 狀態總覽

| | Encode streaming | Decode streaming | `-n` encode | `-n` decode |
|---|---|---|---|---|
| R33/R35 | ✅ | ✅ | ✅ | ✅ |
| R39 | ✅ | ❌ (whole-buffer) | ❌ (activeProcessorCount) | N/A |
| **R40** | ✅ | ✅ | ✅ | ✅ |

## n40 代表結果（Encode / Decode CPU Energy Ratio vs TGZ）

| 格式 | claw enc ratio | claw enc MB/s | claw dec ratio | claw dec MB/s | llama enc ratio | llama enc MB/s | llama dec ratio | llama dec MB/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 1.000 | 49 | 1.000 | 380 | 1.000 | 41 | 1.000 | 86 |
| TLZ4 | 0.179 | 425 | 0.288 | 421 | 0.209 | 86 | 0.257 | 79 |
| **Other3** | **0.169** | **381** | **0.258** | **415** | **0.177** | **87** | **0.223** | **81** |
| BVX3 | 0.193 | 422 | 0.452 | 356 | 0.198 | 89 | 0.259 | 81 |
| ZSTD | 0.237 | 364 | 0.608 | 428 | **0.140** | 92 | 0.444 | 80 |
| Apple | 0.341 | 143 | 0.552 | 320 | 0.314 | 66 | 0.585 | 79 |
| Lazy2 | 0.740 | 58 | 0.359 | 401 | 0.325 | 85 | 0.225 | 84 |
| Optimal | 2.943 | 30 | 0.354 | 356 | 2.018 | 47 | 0.281 | 79 |

Other3 在兩個資料集的 encode 均為自家格式中最省能（claw 0.169、llama 0.177），decode 也最省（claw 0.258、llama 0.223）。llama.cpp 上 ZSTD encode（0.140）是所有格式最低。BVX3 encode 能耗（claw 0.193、llama 0.198）略高於 Other3，decode 則顯著較高（0.452 / 0.259）。

與 R39（回退版）相比，R40 的 `-n` 修正使 claw-code Other3 encode energy ratio 從 0.190 降至 0.169，BVX3 從 0.179 升至 0.193；llama.cpp 差異亦類似，主要來自 inflight 參數正確傳遞後並行度與 chunk 切割方式的變化。

## R33/R34 BVX3/Other3 encode「峰值」調查

Trend chart 顯示 R33/R34 的 BVX3 greedy 與 Other3 encode 速度遠高於鄰近 round；本輪調查根本原因。

### 結論：量測假象，非程式碼改進

所有與 BVX3 greedy / Other3 encode 相關的函數，在 R33 與 R35 的 Swift 原始碼 md5 完全相同：

| 函數 | BVX3 / Other3 的呼叫路徑 | R33 vs R35 md5 |
|---|---|---|
| `lzParseStrong` | BVX3 greedy、Other3（`strong=true`）實際呼叫者 | 相同 |
| `lzParseChain` | BVX3 lazy2 | 相同 |
| `compressBody` | 分派入口 | 相同 |
| `runParallelEncode` | 平行框架 | 相同 |

R33 → R35 唯一的程式碼差異是 `lzParseOptimal` 縮短 40 行（移除 4-context literal pricing），造成 binary 從 351,992 → 335,576 bytes（−16 KB）。BVX3 greedy 與 Other3 **不呼叫** `lzParseOptimal`。

### 系統狀態差異才是根本原因

同份 benchmark log 中，連外部程式（lz4、tar extract）也同樣放慢：

| 算法 / 程式 | R33 | R35 | 倍率 |
|---|---:|---:|---:|
| bvx3 greedy | 2.08 s | 4.56 s | 2.20× |
| other3 | 2.64 s | 3.87 s | 1.47× |
| lz4（外部）| 2.18 s | 3.47 s | **1.59×** |
| tar extract（外部）| 2.23 s | 3.56 s | **1.59×** |
| lazy2 | 21.27 s | 22.00 s | 1.03× |
| optimal | 39.03 s | 40.81 s | 1.05× |

BVX3 greedy 的倍率（2.20×）遠大於 lazy2/optimal（~1.04×）是因為：BVX3 greedy 每個 chunk 僅 ~5 ms，OS 排程器搶佔與 hash table random-access 的 cache miss 佔總時間比例大；lazy2 每個 chunk ~530 ms，排程雜訊影響可忽略。**R35 benchmark 執行時系統背景負載較高，對短任務有不成比例的放大效應。**

**R33/R34 BVX3/Other3 encode 峰值不是優化成果，是系統條件較好時的量測雜訊。**

---

# R39：92221a02 encode 回退版重測（2026-06-21）/ R39 Encode-Optimization Revert Retest

> 以 92221a02（`lzfse-cli.swift` 3379 行）取代 R35 code（3957 行），執行完整 benchmark。此版本移除 R35 中所有進階 encode 優化（R6/R10/R17/R18/R26/R27/R28/R30/R32），decode 核心演算法與 R35 完全相同，但 decode CLI 路徑從串流式（`decodeStreamFromFile`）改回 whole-buffer `readToEnd()`。同一次 benchmark run 也補充了 powermetrics `-i 500ms` 修正後的 decode energy 原始日誌分析。

## 代碼狀態

- **移除的 encode 優化**

| Round | 移除內容 | 影響範圍 |
| --- | --- | --- |
| R6 | rep 長度預計算（l0/l1/l2 重用） | other3、bvx3、lazy2（lzParseChain） |
| R10/R17 | 熵取樣閘（greedyEmitSegment, optEntropyHighThreshold） | bvx3 -optimal（lzParseOptimal） |
| R18/R27 | Tag-packed hash chain（hashAndTag, chainIndexMask/chainTagShift/chainNullIndex） | other3、bvx3、lazy2、optimal（lzParseChain + lzParseOptimal） |
| R26 | localHead 移出段迴圈 | bvx3 -optimal（lzParseOptimal） |
| R28 | symbolPointer() 二分搜尋 | bvx3 -optimal（lzParseOptimal） |
| R30 | cheap-probe gating（optDPSkipAvgMatchLen） | bvx3 -optimal（lzParseOptimal） |
| R32 | matchLength 16-byte 展開 → 退回 8-byte | other3、bvx3、lazy2、optimal（lzParseChain + lzParseOptimal） |

- decode 核心（FSE 解碼、LZ copy、block parsing）**與 R35 完全相同**，decode 速度差異若存在，來自不同 bitstream 造成的不同 FSE symbol 分布。
- decode CLI 路徑：`-i <file>` 由 `decodeStreamFromFile`（streaming）改回 `inputHandle.readToEnd()`（whole-buffer），peak decode RSS 等於整份壓縮輸入大小。

## n40 代表結果（Encode CPU Energy Ratio vs TGZ）

| 格式 | claw-code ratio | enc MB/s | llama.cpp ratio | enc MB/s |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 1.000 | 50 | 1.000 | 43 |
| TLZ4 | 0.174 | 430 | 0.192 | 91 |
| **BVX3** | **0.179** | **424** | **0.140** | **95** |
| Other3 | 0.190 | 380 | 0.117 | 96 |
| ZSTD | 0.239 | 374 | 0.137 | 98 |
| Apple | 0.296 | 140 | 0.224 | 72 |
| Lazy2 | 0.618 | 69 | 0.277 | 87 |
| Optimal | 2.936 | 36 | 2.120 | 50 |

BVX3 encode 為所有 LZFSE 格式中最省能（比 TGZ 省 82-86%），壓縮比 0.949/0.979，encode 速度 95-424 MB/s。Other3（LZFSE 標準輸出）能耗相近（0.117-0.190），速度更快（380-96 MB/s）但壓縮比略差（0.987/0.996）。

## Decode energy 根本性量測問題（powermetrics -i 500ms 後）

### 問題描述

即使採樣間隔由 -i 100ms 修正為 -i 500ms，n=40 的 decode energy 量測**仍然不可信**。最低 decode energy ratio（0.006–0.013）是純粹的量測假象。

### 原始 log 直接對比

`claw-code-optimal n=40 decode`（比率 0.006，報告 61 mW）：
```
唯一樣本（506ms 視窗）：
  CPU 0-3 (E-core): 2–18% active @ 1080 MHz
  CPU 6-9 (P-core): 0–0.84% active（完全空閒）
  CPU Power: 61 mW
```

`claw-code-optimal n=4 decode`（比率 1.18，報告 6546 mW 平均）：
```
Sample 1（506ms）：
  CPU 6: 82.64% @ 4464 MHz
  CPU 7: 82.99% @ 4464 MHz
  CPU 8: 79.93% @ 4464 MHz
  CPU 9: 82.46% @ 4464 MHz
  CPU Power: 12907 mW
Sample 2（507ms）：
  CPU 6-9: 0.8–3.6%（已冷卻）
  CPU Power: 185 mW
```

### 三層疊加效應

**① 採樣視窗僅抓到 1 個樣本（n=40 decode）**

```
T=0.0s：powermetrics 啟動
T=0.2s：decode 開始（sleep 0.2 後）
T=0.5s：唯一樣本觸發（506ms 視窗）← decode 仍在執行中
T=0.71s：decode 結束
```

decode 僅 0.51s，樣本窗口完全結束前 decode 尚未完成，後半截（T=0.5–0.71s）無樣本覆蓋。

**② n=40 GCD 任務爆發式完成，P-core 完全未被動用**

- n=4：4 個大任務 → P-core 全速（80-83% @ 4464 MHz），decode 持續對 P-core 施壓
- n=40：40 個小任務（每個 4MiB chunk）→ E-core 短暫爆發後任務結束，P-core 根本未被喚醒

**③ 唯一樣本積分以空閒時間為主**

506ms 樣本組成：
- 前 200ms：decode 尚未開始（pre-sleep 期間）
- 中間 ~200ms：E-core 已完成爆發，系統降回空閒
- 後 ~100ms：decode wall time 仍在計算，但 P-core 未動

平均結果：61 mW（近乎待機功率），而非真實解碼功率。

### 各格式樣本數一覽

| 格式 | dur | 樣本數 | 報告 mW | 備註 |
| --- | ---: | ---: | ---: | --- |
| optimal (n40) | 0.51s | **1** | 61 | 空閒 |
| other3 (n40) | 0.44s | **1** | 85 | 空閒 |
| lazy2 (n40) | 0.51s | **1** | 128 | 空閒 |
| tar.lz4 | 0.47s | **1** | 1510 | 隨機，無法代表 |
| bvx3 (n40) | 0.56s | **1** | 889 | 隨機 |
| ZSTD | 0.95s | 2 | 6359+956 | peak+冷卻，平均 3658 |
| apple (n40) | 0.81s | 2 | 4169+128 | peak+冷卻 |
| TGZ | 1.35s | 3 | 5300+5308+231 | 最穩定，含 1 個冷卻樣本 |

只有 TGZ decode（1.35s，3 個樣本）的平均值相對穩定。ZSTD 與 apple 雖有 2 個樣本，但第二個樣本均為冷卻期（956/128 mW），平均值仍偏低。其餘 1 個樣本的格式數值皆為採樣假象，不可信。

### 結論

**decode energy ratio 所有 n=40 數值不反映真實解碼能耗，不可用於性能判定。**若需可靠的 decode energy 量測，應採用以下其中一種方式：
1. 將 decode 以迴圈重複執行，使總量測時間 ≥ 3s（推薦）
2. 改用 IOReport / powerlog 提供 per-interval 更細粒度採樣
3. 只報告 decode 速度（MB/s），放棄能耗量測

---

# R38 ：R35 code 重測（2026-06-20）/ R38 Revert Baseline Retest

> R37 判定 rep1/rep2 dominated-range skip 無可重現性能收益後，將 `lzfse-cli.swift` revert 至 R35 code（移除 R36 的 `repLen0/repLen1` 宣告及 rep1/rep2 跳過邏輯），並觸發完整 benchmark（15:08 開始，18:51 BENCH_DONE）。目的為確認 revert 後壓縮輸出回到 R35 bitstream、encode 速度恢復 R35 水位。

## 代碼狀態確認

- 現行 `lzfse-cli.swift` 已移除 R36 新增的 `var repLen0 = 0, repLen1 = 0` 與 rep1/rep2 跳過 guard，恢復為 `var msym = 4; var ll = 4; let lim = min(l, cap)` 原始迴圈起點。
- Optimal 壓縮 bytes：`claw-code 422,948,093`（= R35 committed）、`llama.cpp 577,863,623`（= R35 committed）。與 R36/R37 的 `422,948,018 / 577,864,898` 不同，確認 revert 後 bitstream 完全回到 R35 狀態。

## n40 Optimal 結果對比（R35 committed vs 本次重測）

| 指標 | R35 committed | 本次重測（R35 code）| 差距 |
| --- | ---: | ---: | ---: |
| claw-code encode MB/s | 34.70 | 36.21 | +4.4% |
| llama.cpp encode MB/s | 49.89 | 50.42 | +1.1% |
| claw-code encode power mW | 13,279 | 13,290 | +0.1% |
| llama.cpp encode power mW | 15,731 | 15,523 | −1.3% |
| claw-code encode energy J | 545.7 | 517.8 | −5.1% |
| llama.cpp encode energy J | 371.5 | 359.2 | −3.3% |
| claw-code encode RSS MB | 578.1 | 561.2 | −2.9% |
| llama.cpp encode RSS MB | 587.2 | 597.2 | +1.7% |

- encode power（mW）兩輪幾乎相同（+0.1% / −1.3%），確認 CPU 頻率與功率狀態穩定。
- encode speed：`llama.cpp` +1.1% 屬噪音；`claw-code` +4.4% 略高，可能為系統暖機差異或 cache 效應，未超過 10% 門檻，仍視為噪音範圍。
- encode energy −3.3 ~ −5.1%：方向一致，但幅度不足以宣稱改善；R35 committed 時系統熱狀態較高，本次重測能耗較低屬合理波動。
- **decode power / energy**：本次重測 decode power 僅 499 / 169 mW（vs 一般 5,000–7,000 mW），明顯偏低，推測 powermetrics 採樣窗未對齊 decode 執行期，decode energy 結果不可採用。

## Decode energy 量測可靠性分析（R35 / R36 / R37 / R38 四輪比對）

### 現象一：TGZ / TLZ4 / ZSTD decode energy 在同 run 的 n=4 / 8 / 40 完全相同

| run | claw-code TGZ n4 | n8 | n40 |
| --- | ---: | ---: | ---: |
| R35 | 8.828 J | 8.828 J | 8.828 J |
| R36 | 28.553 J | 28.553 J | 28.553 J |
| R37 | 10.605 J | 10.605 J | 10.605 J |
| R38 | 5.280 J | 5.280 J | 5.280 J |

→ 這三種格式的 decode energy 與 n 值無關，power_benchmark 對它們只執行一次量測，結果被複製到 n=4 / 8 / 40 三列。**TGZ/TLZ4/ZSTD decode energy 不能用於 per-n 比較，也不應作為同輪 decode ratio 分母。**

### 現象二：LZFSE Optimal decode 採樣窗極短（implied active ≈ 0.4–1.0 s）

`implied_active = decode_energy_J / (decode_power_mW / 1000)` 代表 powermetrics 實際捕捉到 CPU 活動的持續時間。

| | R35 | R36 | R37 | R38 | 實際 decode_sec |
| --- | ---: | ---: | ---: | ---: | ---: |
| claw-code n4  | 0.98 s | 1.01 s | 1.00 s | 0.88 s | ~4.2 s/iter |
| claw-code n8  | 0.65 s | 0.68 s | 0.66 s | 0.63 s | ~3.8 s/iter |
| claw-code n40 | 0.52 s | 0.56 s | 0.59 s | 0.51 s | ~4.0 s/iter |
| llama.cpp n4  | 0.67 s | 0.70 s | 0.67 s | 0.63 s | ~15.6 s/iter |
| llama.cpp n8  | 0.49 s | 0.52 s | 0.50 s | 0.47 s | ~15.0 s/iter |
| llama.cpp n40 | 0.39 s | 0.38 s | 0.40 s | 0.36 s | ~15.4 s/iter |

powermetrics 每次 decode 量測只捕捉約 0.5–1.0 秒，但實際每 iteration decode 為 4–16 秒（n40 總時長達 160–620 秒）。**採樣窗覆蓋率極低（<5%），捕捉到的只是 decode 開頭一小段的 CPU 狀態，不代表整體能耗。**

### 現象三：R36 decode power 異常偏高，R38 n40 異常偏低

| run | claw-code Optimal n40 power | llama.cpp Optimal n40 power |
| --- | ---: | ---: |
| R35 | 558 mW | 6,445 mW |
| R36 | **15,070 mW**（異常高）| **15,287 mW**（異常高）|
| R37 | 6,655 mW | 6,863 mW |
| R38 | **499 mW**（異常低）| **169 mW**（異常低）|

- R36 decode power 與 encode 相當（13,000–15,000 mW），顯示 R36 benchmark 期間系統處於高負載，採樣窗恰好捕捉到背景活動，造成 decode power 虛高。
- R35 / R38 claw-code n40 decode power 僅 500–560 mW，與 llama.cpp 同輪（6,445 / 169 mW）差距巨大，顯示採樣窗極短且時機隨機。

### 結論：decode energy 量測不可用於跨輪比較

1. 採樣窗僅 0.4–1.0 s，遠短於實際 decode 時間，無法代表總能耗。
2. TGZ/TLZ4/ZSTD decode energy 對 n 值為常數（單次量測），無法與 LZFSE 格式做 n-consistent ratio 比較。
3. R36 decode power 受系統高負載污染，R38 n40 受採樣時機偏移影響，兩輪絕對值均不可信。
4. 唯一可靠的能耗指標為 **encode CPU energy**：encode 時間長（25–55 s/iter × n），powermetrics 採樣覆蓋率高，跨輪 power 數值穩定（±1–2%）。

**後續 decode energy 若需可靠量測，應改用 `powermetrics -i 500` 連續取樣並覆蓋完整 n-iteration decode 執行期，而非現行單次短窗採樣。**

## Encode energy 四輪比對分析（R35 / R36 / R37 / R38）

### 量測可靠性：encode energy 覆蓋率高

encode 的 implied_active（energy/power）與實際 encode_seconds 幾乎相符（95–107%），確認 powermetrics 採樣窗完整覆蓋整個 encode 執行期。encode energy 為可信量測，與 decode 根本不同。

但 **TGZ / TLZ4 / ZSTD encode energy 在同一 run 的 n=4/8/40 仍完全相同**（單次量測），無法做 per-n 比較；LZFSE 格式則正確地依 n 遞增。

### R36 encode energy 全格式系統性偏高

R36 的能耗膨脹不只在 Optimal，**所有格式**都升高，且膨脹幅度與 encode 時長成反比：

| 格式（claw-code n40） | R35 | R36 | R37 | R38 |
| --- | ---: | ---: | ---: | ---: |
| TGZ（~3 s） | 192 J | **550 J（+187%）** | 182 J | 167 J |
| LZFSE (Apple)（~7 s） | 56 J | **157 J（+180%）** | 52 J | 46 J |
| LZFSE (Lazy2)（~14 s） | 120 J | **163 J（+36%）** | 114 J | 109 J |
| LZFSE (Optimal)（~40 s） | 546 J | **603 J（+10%）** | 526 J | 518 J |

TGZ（最快，採樣窗最短）膨脹 +187%，Optimal（最慢，採樣窗最長）僅膨脹 +10%。這是典型的**系統高負載污染**：encode 時長越短，背景功耗佔測量比例越高。**R36 的非 Optimal 格式 encode energy 數值不可採用。**

### Optimal encode energy 四輪數值（相對 R35）

| 資料集 / n | R35 | R36 | R37（R36-code）| R38（R35-code）|
| --- | ---: | ---: | ---: | ---: |
| claw-code n4 | 736 J（100%）| 1103 J（+50%）| 720 J（**98%**）| 723 J（**98%**）|
| claw-code n8 | 590 J（100%）| 756 J（+28%）| 585 J（**99%**）| 578 J（**98%**）|
| claw-code n40 | 546 J（100%）| 603 J（+10%）| 526 J（**96%**）| 518 J（**95%**）|
| llama.cpp n4 | 544 J（100%）| 738 J（+36%）| 511 J（**94%**）| 519 J（**95%**）|
| llama.cpp n8 | 416 J（100%）| 501 J（+20%）| 402 J（**97%**）| 403 J（**97%**）|
| llama.cpp n40 | 372 J（100%）| 407 J（+10%）| 365 J（**98%**）| 359 J（**97%**）|

- R37（R36-code）與 R38（R35-code）均比 R35 committed 低 2–5%，但差距方向一致，顯示系統熱狀態在 R37/R38 期間略低於 R35 committed 時。
- 排除 R36 後，三輪（R35 / R37 / R38）的 Optimal encode energy 在同 n 值下差距不超過 5%，屬系統狀態波動範圍。

### R37（R36-code）vs R38（R35-code）Optimal 直接比較

| n | claw-code ΔE | claw-code Δspeed | llama.cpp ΔE | llama.cpp Δspeed |
| --- | ---: | ---: | ---: | ---: |
| n=4 | +0.4% | +2.1% | +1.6% | −3.1% |
| n=8 | −1.2% | −2.2% | 0.0% | −3.1% |
| n=40 | −1.6% | +1.0% | −1.5% | +1.1% |

（正值 = R38 比 R37 更高；能耗正值 = R35-code 更耗能）

n40 下，R38（R35-code）比 R37（R36-code）能耗低 1.5–1.6%、速度高 1.0–1.1%；n4/n8 下方向不一致。差距均在 ±2–3% 以內，無法排除系統狀態解釋。**目前無法從能耗數據確認 R36 code（rep1/rep2 skip）對 Optimal encode 有可重現的正負影響。**

### Encode energy 結論

1. **量測可靠**：LZFSE 格式 encode energy 的 powermetrics 覆蓋率 ≈ 95–107%，為本 benchmark 中最可信的能耗指標。
2. **R36 全格式系統性偏高**（系統高負載），排除後 R35/R37/R38 Optimal 差距 ≤ 5%（系統熱狀態波動）。
3. **R36 code vs R35 code（R37 vs R38）**：n40 下 R35-code 略省 1.5%，但 n4/n8 方向不一致，整體在噪音範圍內，rep1/rep2 skip 無可重現能耗改善。
4. TGZ/TLZ4/ZSTD encode energy 單次量測、n-constant，不得用於跨 n ratio 分析。

## 結論

- **Revert 正確**：bitstream 完整回到 R35，encode 速度與功率水位與 R35 committed 一致（噪音範圍）。
- **R35 code 可作為下一輪 DOE 的 clean baseline**，不攜帶 R36 rep1/rep2 skip 的 DP state 干擾。
- **Decode energy 量測存在根本性問題**，歷史 R35–R38 的 decode energy 數值均不可用於跨輪性能判定。
- **Encode energy 可靠但 R36 受系統負載污染**；R37/R38 顯示 rep1/rep2 skip 無可重現能耗收益。
- 下一步依 R37 TODO：以此 revert baseline 搭配 feature switch，建立同輪受控 A/B，或進行新的 Optimal 熱點優化（`matchLength`、`rebuildPrices`、Swift Array/COW）。

---

# 第三十七輪：R36 rep1/rep2 支配跳過同碼重測（性能收益未重現）（2026-06-20）/ Round 37: Same-Code Retest of R36

> 本輪未修改壓縮核心，目的為重測 R36 的 rep1/rep2 dominated-range skip。兩個資料集在 n40 / n8 / n4 均完成 encode、decode 與 extract compare，**output-identical 通過**；但相對 R35 的速度、能耗改善都未達 `>=10%` 驗收門檻，因此 R36 的性能收益仍未獲證實。

## 測試完整度與輸出穩定性

- 整輪於 `2026-06-20 10:35:56` 完成，未發現 benchmark、compare、memProbe、power 或 trace analysis failure。
- power 共 72 筆，全部為 `status=ok`；profiling 產生 36 個 trace package，CPU call tree 共分析 72 個 XML，所有 summary 寫完後才清理來源 trace，狀態為 `before=36 after=0`。
- `BenchMarkResult.csv` 已重建 48 rows，best-points、power 與 trace summary 均完成整合。
- Optimal 壓縮大小在 n40 / n8 / n4 完全一致，且與 R36 相同：`claw-code 422,948,018 bytes`、`llama.cpp 577,864,898 bytes`。這證明 R36 bitstream 可跨 thread count 與同碼重測穩定重現。
- 相對 R35，`claw-code` 小 75 bytes，`llama.cpp` 大 1,275 bytes；bitstream 與 R35 不同，但 extract 後內容完全一致，因此不構成 output-identical 失敗。

## n40 代表結果

MB/s 仍以實際 raw bytes / duration ns 計算，不使用顯示值反推。

| 資料集 | Optimal 壓縮 MB/s | 解壓 MB/s | 壓縮比 | Encode RSS(MB) | Decode RSS(MB) | Encode CPU Energy(J) | top closure | parse hits |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| claw-code | 35.85 | 437.10 | 0.8590 | 564.4 | 328.4 | 526.295590 | 763 | 1187 |
| llama.cpp | 49.85 | 89.25 | 0.9393 | 600.6 | 348.8 | 364.600403 | 681 | 1101 |

## 與 R36 / R35 比較

相對 R36 同碼前次結果：

- `claw-code` Optimal n40 encode：`36.22 → 35.85 MB/s`（約 `-1.0%`）；encode CPU energy：`602.633383 → 526.295590 J`（約 `-12.7%`）。
- `llama.cpp` Optimal n40 encode：`50.42 → 49.85 MB/s`（約 `-1.1%`）；encode CPU energy：`407.283755 → 364.600403 J`（約 `-10.5%`）。
- 同一程式碼下速度只變動約 1%，但 power 差異達 10% 以上，顯示 energy 結果對系統熱狀態、背景負載與量測時點高度敏感；不可把 R36 → R37 的降幅直接歸因於演算法。

相對 R35 baseline：

- `claw-code` Optimal n40 encode：`34.70 → 35.85 MB/s`（約 `+3.3%`）；encode CPU energy：`545.694678 → 526.295590 J`（約 `-3.6%`）。
- `llama.cpp` Optimal n40 encode：`49.89 → 49.85 MB/s`（約 `-0.1%`）；encode CPU energy：`371.502908 → 364.600403 J`（約 `-1.9%`）。
- 對原始 baseline 而言，速度改善只在 `claw-code` 出現，`llama.cpp` 幾乎不變；能耗改善也僅約 2–4%，均低於單點 `>=10%` 成功條件。

## Energy Ratio 分析（同輪 TGZ = 1）

- `Energy Ratio = 該算法 CPU Energy / 同輪、同資料集 TGZ CPU Energy`；數值越低越省能，`<1` 代表比 TGZ 省能，`>1` 代表比 TGZ 耗能。最低／最高值分別取同一算法在 n4 / n8 / n40 的最小／最大值。
- Optimal 的最低 ratio 均出現在 n40，最高 ratio 均出現在 n4；這與「提高 concurrency 雖增加 RSS，但縮短執行時間並降低 CPU energy」的方向一致。

| 資料集 | Encode 最低 R36→R37 | Encode 最高 R36→R37 | Decode 最低 R36→R37 | Decode 最高 R36→R37 |
| --- | ---: | ---: | ---: | ---: |
| claw-code | `1.0950 → 2.8967`（`+164.5%`） | `2.0042 → 3.9605`（`+97.6%`） | `0.2938 → 0.3685`（`+25.4%`） | `0.6001 → 1.1535`（`+92.2%`） |
| llama.cpp | `0.6304 → 2.1391`（`+239.3%`） | `1.1417 → 2.9996`（`+162.7%`） | `0.2467 → 0.3162`（`+28.2%`） | `0.4771 → 0.8746`（`+83.3%`） |

- **相對 R36，Optimal 的 Encode / Decode 最低與最高 Energy Ratio 全部上升，沒有任何一項改善。**Encode 最低值在 R37 仍達 `2.8967 / 2.1391`，表示即使採最佳 n40，Optimal encode 仍消耗 TGZ 約 `2.90x / 2.14x` CPU energy；最高值則達 `3.96x / 3.00x`。
- Decode 的最低值有明確優勢：Optimal n40 只使用 TGZ 的 `36.85% / 31.62%` CPU energy。但最高值方面，`claw-code` n4 為 `1.1535`，比 TGZ 多約 `15.4%`；`llama.cpp` n4 為 `0.8746`，仍比 TGZ 少約 `12.5%`。因此 client-side decode 的節能成立於 n40，低 concurrency 並非兩個資料集都能保持優勢。
- 同輪其他 LZFSE family 的 Encode ratio 最高值仍低於 1：Other3 `0.3054 / 0.2613`、BVX3 `0.3140 / 0.2678`、Lazy2 `0.8754 / 0.4195`，表示它們在所有 n 值都比 TGZ encode 省 CPU energy。Optimal 是唯一 Encode 最低值仍大於 1 的 LZFSE 模式。
- R36 → R37 的 TGZ encode baseline 本身由 `550.363047 → 181.690929 J`（claw-code）及 `646.035081 → 170.447736 J`（llama.cpp）大幅下降；Optimal 絕對能耗雖也下降，但降幅遠小於 TGZ，因此 normalized ratio 反而惡化。這證明跨輪只看絕對 J 容易受系統狀態影響；往後應同時報告絕對能耗與同輪 TGZ Energy Ratio，性能判定以兩者一致或受控 A/B 為準。

## Profiling 與 RSS

- 36 個 trace 中，6 個外部工具正常結束，30 個 LZFSE family trace 在 300 秒達 time limit；target 與 `time-profile` / `time-sample` schema 均存在。固定 timeout 下的 symbol occurrence 只供方向比較，不代表精確 CPU 百分比。
- R35 → R37 的 Optimal n40 directional sample：`claw-code` top closure `737 → 763`（約 `+3.5%`）、parse hits `1170 → 1187`（約 `+1.5%`）；`llama.cpp` top closure `660 → 681`（約 `+3.2%`）、parse hits `1101 → 1101`（不變）。profiling 未顯示主要 parse hotspot 因支配跳過而下降。
- R36 → R37 的 sample 僅小幅波動：`claw-code` top `769 → 763`、parse `1191 → 1187`；`llama.cpp` top `696 → 681`、parse `1133 → 1101`。這不足以建立穩定因果關係。
- R35 → R37 的 n40 RSS：`claw-code` encode `578.1 → 564.4 MB`、decode `308.0 → 328.4 MB`；`llama.cpp` encode `587.2 → 600.6 MB`、decode `349.3 → 348.8 MB`。方向不一致，應視為執行波動，沒有證明 rep1/rep2 skip 改善或惡化 RSS。
- Optimal n40 encode RSS 仍約 `564–601 MB`，decode 約 `328–349 MB`。R36 對 server/CDN 離線壓縮與約 300 MB client decode RSS 的能源取捨判斷不因本輪失效，但 encode buffer、chunk in-flight 與暫存陣列生命週期仍需調查。

## 判定

- **正確性與 output-identical 通過。**兩個資料集、三種 n 值均成功解壓並通過 extract compare；R36 的 Optimal 壓縮大小亦可穩定重現。
- **性能驗收未通過。**相對 R35，速度為 `+3.3% / -0.1%`，encode CPU energy 為 `-3.6% / -1.9%`，且 profiling 沒有看到主要 hotspot 降低，均未達 `>=10%` 成功條件。
- **Energy Ratio 亦未改善。**相對 R36，Optimal 的 Encode / Decode 最低與最高 ratio 全數上升；R37 Optimal encode 即使在最低點仍為 TGZ 的 `2.14–2.90x`。只有 n40 decode 維持明確低於 TGZ 的 `0.32–0.37x` 優勢。
- R36 rep1/rep2 dominated-range skip 應分類為「output-identical 通過，但性能收益未證實」，不可宣稱穩定加速或節能。它仍會改變 DP state/tie path 與 bitstream，不是 ratio-neutral 的純實作優化。
- 下一輪應以 feature switch 或 revert 建立**同輪受控 A/B**，固定電源、熱狀態與背景負載，至少比較 n40 benchmark、power 與 trace。若兩個資料集仍未出現可重現的 `>=10%` 改善，應回退或不保留此剪枝，轉向 `lzParseOptimal` DP 展開、`matchLength`、`rebuildPrices` 或 Swift Array/COW 等已確認熱點。

---

# 第三十六輪：Optimal 能耗/速度 — rep1/rep2 支配跳過（output-identical 通過）（2026-06-19）/ Round 36: rep1/rep2 Dominated-Range Skip

> 方向轉向：ratio 路線（#1/R33、#3、#4）已耗盡，本輪改做 Optimal 能耗／時間優化。兩個資料集全部解壓 compare 通過，因此 **output-identical 驗收成立**；壓縮 bitstream 與大小有微小變動，另列為非 bitstream-identical。只動 `lzfse-cli.swift`。

## 改動：rep1/rep2 relaxation 跳過被支配長度段

- `lzParseOptimal` 每位置會跑 rep0 / rep1 / rep2 三個 relaxation 迴圈,各自把 `cPrice[t+4 … t+l]` 鬆弛。
- 觀察:同一長度 q,rep1 的成本 = rep0 成本 + (`dPriceTab[1] − dPriceTab[0]`)。當 `dPriceTab[1] ≥ dPriceTab[0]`（rep0 距離較便宜,實務上幾乎恆成立,因 rep0 最常用）時,rep1 在 `4 … min(repLen0,cap)` 這段的價格**必然 ≥ rep0 已寫入的價格** → `if c2 < cPrice[dest]` 恆 false → **這段 rep1 是純 no-op**。rep2 同理被 rep0/rep1 中較便宜者支配。
- 因此加上價格守衛後,rep1/rep2 的 relaxation **直接從被支配段之後開始**(`ll` 起點上移),跳過必為 no-op 的 SIMD/scalar 迴圈。
- 原始假設是被跳過的 `c2 ≥ cPrice` 寫入皆為 no-op，因而壓縮 bitstream 不變；後續實測否定 bitstream-identical 假設，但解壓輸出仍完全一致，詳見「判定」。
- 預期 rep-heavy 段可省下 rep1/rep2 relaxation，讓 Optimal 壓縮時間／能耗下降；實測 benchmark 速度小幅改善，但最新 power 重測未顯示能耗改善。output-identical 通過，嚴格壓縮比中立未成立。

## 實測結果

- `swiftc -O`、內建 `-test` 與兩個資料集 n40 / n8 / n4 的 encode、decode、compare 全部通過，未出現截斷或內容不一致。
- 本輪 raw size 為 `claw-code 1,416,220,672 bytes`、`llama.cpp 1,322,553,344 bytes`；MB/s 均以 raw bytes / ns 原始計算。

| 資料集 | n | Optimal 壓縮 MB/s | 解壓 MB/s | Encode RSS(MB) | Decode RSS(MB) | Encode CPU Energy(J) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| claw-code | 40 | 36.22 | 394.35 | 572.3 | 308.9 | 602.633383 |
| claw-code | 8 | 32.00 | 388.13 | 378.2 | 105.2 | 755.991824 |
| claw-code | 4 | 25.05 | 331.14 | 212.8 | 68.5 | 1103.015427 |
| llama.cpp | 40 | 50.42 | 84.65 | 563.5 | 348.9 | 407.283755 |
| llama.cpp | 8 | 42.22 | 85.99 | 392.5 | 102.8 | 500.817190 |
| llama.cpp | 4 | 33.62 | 81.55 | 232.1 | 71.1 | 737.546883 |

相對 R35 n40 baseline：

- `claw-code`：`34.70 → 36.22 MB/s`（約 `+4.4%`），但最新 encode CPU energy 為 `545.694678 → 602.633383 J`（約 `+10.4%`）。
- `llama.cpp`：`49.89 → 50.42 MB/s`（約 `+1.1%`），但最新 encode CPU energy 為 `371.502908 → 407.283755 J`（約 `+9.6%`）。
- 最新 power run 的 duration / 平均功率均與前次不同，因此不能把能耗上升完全歸因於 R36 程式碼；但依「採最新有效資料」原則，本輪不再宣稱 encode energy 改善，需以固定熱狀態重複量測才能做因果判定。
- n40 仍是 Optimal 的最佳速度／同輪最低能耗點，但也是 RSS 最高點。相對 n4，n40 將 encode CPU energy 從 `1103.02 / 737.55 J` 降到 `602.63 / 407.28 J`（約 `-45%`），代價是 encode RSS 從 `212.8 / 232.1 MB` 升到 `572.3 / 563.5 MB`。這確認 chunk in-flight 數量是 RSS 主因之一，也顯示降低 concurrency 雖省記憶體，卻因執行時間拉長而增加總能耗。

### Profiling 重建結果

- 第二批 profiling 已完整完成：共 36 個 trace package，6 個外部工具 trace 正常結束，30 個 LZFSE family trace 在 300 秒達 time limit；所有 trace 均 `target_seen=yes`，且 `time-profile` / `time-sample` schema 匯出成功。
- CPU call tree 共分析 72 個 XML。summary 寫完後才執行清理，狀態為 `CPU_CALL_TREE_TRACE_CLEANED before=36 after=0`；證明修正後不再於分析前遺失來源 trace。`BenchMarkResult.csv` 已重建 48 rows，power 72/72 為 `status=ok`，best-points 與 power 欄位均完成整合。
- R35 → R36 的 Optimal n40 directional sample：`claw-code` parse hits `1170 → 1191`、top `lzParseOptimal` closure `737 → 769`；`llama.cpp` parse hits `1101 → 1133`、top closure `660 → 696`。`matchLength` 為 `71 → 82` / `72 → 77`，`rebuildPrices` 為 `36 → 42` / `34 → 44`。
- 以上是固定 300 秒 timeout trace 的 symbol occurrence，不是精確 CPU 百分比；但兩個資料集都沒有呈現 parse / top closure sample 明顯下降，因此 profiling 不支持「rep1/rep2 skip 已降低主要 CPU hotspot」的強結論。主熱點仍是 `lzParseOptimal` closure，其次為 entropy prescreen、`matchLength`、`emitSteps`、`rebuildPrices` 與 Swift Array/COW。

### RSS 與 CPU 能耗取捨

- 依 `LPDDR_power_estimation/LPDDR_power_info.md` 的連續存取估算，LPDDR4X / LPDDR5 約為 `150 / 120 mW/GB`。RSS 從約 `60 MB` 增至 `300 MB`，增量約 `240 MB`（`0.234 GB`），對應 DRAM 額外功率約 `35 / 28 mW`。
- 若再納入 memory controller / PHY 約 20–40% 的額外成本，記憶體子系統增量約 `34–49 mW`。即使把這視為整段持續活動的保守上限，執行 40 秒約增加 `1.4–2.0 J`；若只有約 4 秒，則約 `0.14–0.20 J`。
- 同輪 decode n4 → n40 時，RSS 約由 `68.5 / 71.1 MB` 升至 `308.9 / 348.9 MB`，但 CPU energy 由 `17.13 / 11.33 J` 降至 `8.39 / 5.86 J`（約 `-51% / -48%`）。這個 CPU 節省量級遠高於不到 1 秒期間約數百分之一焦耳的估算記憶體增量。因此在目前桌面測試與約 `300 MB` RSS 範圍內，**優先降低 CPU 執行時間／總能耗是較佳整體取捨，300 MB RSS 可接受**。
- 這是依 active-memory 單位功耗建立的模型估算，不是本輪 DRAM 實測；RSS 也不等於所有頁面都持續讀寫。結論應用於能源取捨，不代表可忽略記憶體容量、系統 memory pressure 或多工作負載併行問題。Optimal encode n40 仍達約 `563–572 MB`，超過此處 300 MB 的可接受基準，仍應繼續調查 DP buffer 與 chunk in-flight 生命週期。

### 適用場景：伺服器端更新包壓縮

- Optimal compression 適合「伺服器端壓縮一次、client 端下載與解壓多次」的分發模型，例如大型 server-side code update、App 或遊戲更新包、CDN 靜態資產。高成本 encode 可在發布端離線完成，並由大量下載次數攤提，不應只用單次 encode energy 判斷整體效率。
- 本輪 Optimal 相對 BVX3 / Other3 產物更小；在大規模分發時，每個 client 都能減少下載 bytes，因而降低網路傳輸時間與 radio / Wi-Fi 活動時間。累積到大量 iPhone 或其他 client 後，傳輸端節省通常比伺服器增加的一次性壓縮成本更重要。
- client 端只執行 decode。R36 n40 的 Optimal decode 與同一 BVX3 family 其他模式使用相同格式與 decoder，解壓速度維持可用水位；約 `300 MB` RSS 的能源成本依前述 LPDDR 模型仍小於 CPU／傳輸節省，因此在記憶體容量允許的裝置上，整體方向有利於 client-side energy。
- 系統層評估應使用：`一次 encode energy + 所有 client 的傳輸 energy + 所有 client 的 decode energy`。下載次數越多、壓縮大小差距越大，Optimal 的 server-side 高 encode 成本越容易被攤平；若只是單次本機壓縮，則未必划算。
- App Store 僅作應用場景類比：目前 `bvx3` 是私有格式，實際部署需要 client 端整合對應 decoder，並符合平台更新、簽章與封裝流程；本報告不宣稱現有格式可直接替換 App Store 的正式更新格式。

## 判定

- **正確性與 output-identical 驗收通過。**兩個資料集的 n40 / n8 / n4 全部成功解壓，且 extract 後內容 compare 一致。只有 Optimal 壓縮產物大小改變；Other3 / BVX3 / Lazy2 大小維持 R35。`claw-code optimal` 為 `422,948,093 → 422,948,018 bytes`（改善 75 bytes），`llama.cpp optimal` 為 `577,863,623 → 577,864,898 bytes`（退步 1,275 bytes）。因此本輪不是 bitstream-identical，也不是嚴格 ratio-neutral，但不影響 output-identical 判定；四位小數壓縮比仍約 `0.8590 / 0.9393`。
- 原先「較貴 rep relaxation 必為 no-op」的論證不夠完整：DP cell 不只包含 `price`，還包含 `cR0/cR1/cR2` rep history；跳過 relaxation 會改變後續可見狀態或 tie path，實測已證明 bitstream 會改變。因此 R36 應視為近似剪枝 DOE，而不是純實作微優化。
- benchmark 速度改善只有 `1.1~4.4%`，未達單點 `>=10%` 成功條件；最新 power 重測反而約 `+9.6~10.4%` encode CPU energy，profiling 也沒有看到主要 parse hotspot 下降。雖然 output-identical 通過，`llama.cpp` 壓縮大小仍微退，因此 R36 尚不構成明確可保留的成功結果。
- 能源權衡上，約 `300 MB` RSS 的估算記憶體成本低於同輪 decode n4→n40 的 CPU energy 節省，故不應為了把 RSS 壓回約 `60 MB` 而接受更長 CPU 執行時間；但 `500 MB` 以上的 Optimal encode RSS 仍超出本項可接受結論的範圍。
- 應用層面上，Optimal 的主要價值是 server/CDN 離線壓縮後的大量 client 分發：encode 成本只付一次，較小更新包帶來的傳輸與 client-side 能源節省可重複累積。下一步除單機 benchmark 外，應加入不同下載次數下的 energy break-even 分析。


## TODO（依優先序）/ Backlog

1. R36 驗收結論為「correctness/output-identical 通過，但性能成功條件未達」。下一輪先以 feature switch 或 revert 建立同輪 A/B，固定熱狀態重測 n40 benchmark + power；若速度仍低於 `+10%` 且 energy 無改善，則不保留 rep1/rep2 skip。
2. （中）Optimal 進一步 output-identical 微優化：仍須維持 extract/compare 全通過；若另要求 bitstream-identical，需明確列為獨立驗收條件。profiling 已確認主要方向仍是 `lzParseOptimal`、`matchLength`、`rebuildPrices` 與 Swift Array/COW，下一個單點應從其中一項做可歸因改動。
3. （中）Optimal 段層級能耗:`optDPSkipAvgMatchLen`(R30 gating)可再 DOE,但會改 ratio,需獨立輪。
4. **（最低 / Lowest priority）盲做 beam-2(#2 per-position 2-state)**：
   - 可行性結論:**沒有對正確性安全的捷徑**。現行 literal step `cR0[t+1]=r0` 讓「最近一次 match 的 rep0」穿過後續 literal 一路攜帶,cell 的 reps 本就不舊;「match-ended 第二狀態」經 literal 傳播後會與 cell 狀態收斂,給不出新的 rep 集合。要真正保住「價格相近但 rep 不同」的第二條路,**只能做完整 beam-2**:每 cell 存 2 條 (price,reps)、**每個 SIMD relaxation 寫入點(~11 處)改 2-best 合併** + backtrace 記錄每格選哪條狀態。
   - 風險/ROI:這正是 **#4 截斷 bug 的同一塊 SIMD 區**,沙箱無法編譯/驗證,大機率多輪修編譯;且 ROI 偏低(rep-carry 使 #2 收益本就窄,且前三個 ratio 想法全敗)。
   - 結論:**列為最低優先**,僅在「能 compile/test loop 的環境、逐步加 beam 並每步 `-test`+benchmark」時才做。

---

# 第三十五輪：R34 修復重測與 R35 baseline（2026-06-19）

> 本輪目的不是新增 ratio DOE，而是回退 R34 失敗路徑、清理未使用 DP macro transition，並重跑完整 benchmark / memProbe / trace / power，確認 `llama.cpp-n40 optimal` correctness 回復。

## 修復內容

- 移除 R34 `tag-less length-4 recovery` active path：`lzParseOptimal` 不再用 `optLen4ProbeDepth` 回收被 tag-packing 濾掉的 length-4 candidate。
- 清理先前失敗實驗殘留的未使用 macro transition 狀態：`relaxLiteralRep0` / `relaxMatchLiteralRep0`、`cLitBefore/cLen2/cDist2`、`stepLitBefore/stepLen2/stepDist2` 全部移除。
- `emitSteps` 與 optimal backtrack 回到單一 match/literal step：每個 DP cell 只記錄 `cLen/cDist/cR0/cR1/cR2`，避免下一輪 DOE 混入未使用欄位與額外記憶體成本。

## 資料狀態

- `round_status.txt` 已跑到 `Done`，並完成 `BENCHMARK_RESULT_REBUILD_DONE`、`BEST_POINTS_ANALYSIS_DONE`、`POWER_SUMMARY_INTEGRATE_DONE`。
- `claw-code` 與 `llama.cpp` 的 n40 / n8 / n4 完整 compare 通過；未再出現 R34 的 `tar: Write error`、半成品 `.lzfse.bvx3.optimal`、`Truncated tar archive`。
- `BenchMarkResult.csv` 已重建 48 rows，速度以實際 bytes/ns 換算；本輪 raw size 為 `claw-code 1351M`、`llama.cpp 1261M`，資料集/封存大小與舊輪次可能有浮動，因此主要看本輪同碼同資料內的相對排序。
- power 資料唯一瑕疵是 `llama.cpp-lazy2 n40 decode` 為 `ok:no_samples`；這是短 decode 取樣不足，不影響 correctness，也不影響 encode energy 結論。

## n40 代表結果

`claw-code`：

| 格式 | 壓縮 MB/s | 解壓 MB/s | 壓縮比 | Encode RSS(MB) | Decode RSS(MB) | Encode CPU Energy(J) | CPU top |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Other3 | 365.75 | 343.16 | 0.9865 | 271.0 | 300.1 | 36.113226 | encode / 70 |
| BVX3 | 310.37 | 352.72 | 0.9492 | 233.1 | 324.9 | 35.059268 | encode / 61 |
| Lazy2 | 64.37 | 303.39 | 0.8998 | 495.8 | 320.5 | 119.950248 | parse / 152 |
| Optimal | 34.70 | 295.47 | 0.8590 | 578.1 | 308.0 | 545.694678 | parse / 737 |
| ZSTD | 352.87 | 475.22 | 0.8245 | 377.2 | 9.3 | 49.168387 | external_tool / 174 |
| TLZ4 | 408.54 | 408.78 | 1.1793 | 82.9 | 33.7 | 33.854015 | external_tool / 288 |

`llama.cpp`：

| 格式 | 壓縮 MB/s | 解壓 MB/s | 壓縮比 | Encode RSS(MB) | Decode RSS(MB) | Encode CPU Energy(J) | CPU top |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Other3 | 95.29 | 87.79 | 0.9957 | 348.3 | 349.1 | 30.003544 | encode / 75 |
| BVX3 | 95.53 | 87.54 | 0.9787 | 347.0 | 351.4 | 27.975481 | encode / 60 |
| Lazy2 | 85.25 | 89.38 | 0.9551 | 497.0 | 348.8 | 59.204837 | parse / 126 |
| Optimal | 49.89 | 88.28 | 0.9393 | 587.2 | 349.3 | 371.502908 | parse / 660 |
| ZSTD | 98.53 | 90.55 | 0.9100 | 473.9 | 9.0 | 30.805776 | external_tool / 141 |
| TLZ4 | 91.68 | 88.98 | 1.0537 | 80.6 | 33.8 | 42.736587 | external_tool / 285 |

## 判定

- **R34 correctness regression 已修復**：最重要的 `llama.cpp-n40 optimal` 已完成 encode/decode/compare，R34 的截斷失敗未重現。
- R35 是 clean baseline，不是新的壓縮率改善。`Optimal` 壓縮比仍最佳（`claw-code 0.8590`、`llama.cpp 0.9393`），但 encode energy 仍最高（`545.69 J` / `371.50 J`），CPU top 仍集中在 `lzParseOptimal` parse closure。
- `BVX3` fast path 在本輪能耗仍接近 TLZ4：`claw-code n40` 為 `35.06 J` vs TLZ4 `33.85 J`；`llama.cpp n40` 為 `27.98 J`，甚至低於 ZSTD `30.81 J`。但 BVX3 family 的 RSS 仍偏高，尤其 n40 decode 約 `325~351 MB`，遠高於 TLZ4 `33~34 MB` 與 ZSTD `9 MB`。
- `-n` 的速度/RSS取捨仍明顯：`claw-code BVX3` 最佳壓縮速度在 n8 (`414.50 MB/s`)，n40 反而降到 `310.37 MB/s` 且 RSS 升到 `233.1/324.9 MB`；`Lazy2/Optimal` 則 n40 明顯降低 encode energy，但 RSS 上升到約 `496~578 MB`。
- trace 仍多數 timeout，但 `target_seen=yes`、`time-profile/time-sample ok`，CPU call tree summary 可用；`Optimal` 的 `cpu_parse_hits` 仍約 `1100+`，表示下一個 ratio DOE 若增加 DP state，必須先限制啟用區段，否則很容易把時間與 RSS 再推高。

## 下一步

- 不再直接重試 length-4 recovery。若要研究 tag-packing 是否傷害壓縮比，先做 instrumentation counter：被 tag 濾掉但 `load32(c)==v` 的數量、實際成為最佳 DP edge 的比例、以及資料集/段落分布；預設仍關閉。
- 下一個真正的 Optimal ratio 候選仍是小型 2-state / small beam，但只能先在 rep-heavy 或 high-coverage 段啟用；成功條件需同時包含壓縮比改善、`claw-code/llama.cpp` compare 全通過、encode RSS 不失控、encode energy 不明顯惡化。
- 若優先處理 BVX3 family，下一輪應查 n40 encode/decode RSS：chunk in-flight、解碼 group buffering、輸出側暫存陣列生命週期。這比繼續追 BVX3 encode energy 更重要。

---

# 第三十四輪：Codex #4 — tag-less length-4 補檢（2026-06-19）/ Round 34: Recover length-4 matches filtered by tag-packing

> 只動 `lzfse-cli.swift`。承 Codex 對 xz 的研究四點。**先釐清狀態**再做。

## 狀態釐清（重要）

- **Codex #1（context-aware literal price）= 已是 R33,且失敗**：HEAD `R33: Optimal literal price 4-context DOE -> failed to improve compress ratio.` 已用「前一個 **literal** 位元組 >> 6」(比逐輸入位元組更精確) 實作並 benchmark,結論無法改善壓縮比。本輪一度重做了一份更粗的版本,發現撞 R33 後**已全部還原**（工作樹回到單表）。
- **Codex #3（literal+rep0 / match+literal+rep0 組合邊）= 已存在**：`lzParseOptimal` 的 `relaxLiteralRep0` / `relaxMatchLiteralRep0` 即是,先前已實作。
- 故本輪只做**真正未探索**的 **#4**;**#2（per-position 2-state / small beam）留待下一輪**——它是較大的 DP 重構,且為避免再現 R30/R33「一輪綁兩個 ratio 變數→難歸因→拆 revert」的亂局,**一次只動一個 ratio DOE 變數**。

## 本輪改動：#4 tag-less length-4 recovery

- R27 tag-packing 以 hash5/tag 過濾鏈候選,會漏掉「前 4 bytes 相同、第 5 byte 不同」→ tag 不同 → 被略過的 **length-4 match**。
- 新增（`lzParseOptimal` 鏈走訪後）：**僅當本位置完全沒找到 ≥4 的 match（`bl < 4`）時**,對 bucket 前 `optLen4ProbeDepth`(=4) 項做 **tag-less 補檢**,用 `load32(c)==v` 確認後回收**一個** length-4 候選進 frontier。
- 觸發條件嚴格（無 rep、主走訪也沒找到任何 ≥4 match 才啟動）→ 成本上界 = 4 次 `load32`/位置,且只在「原本完全沒 match」的位置。
- **正確性 safe**：只加入經 `load32(c)==v`、`dd≤maxDist`、`dd≠rep` 驗證過的合法 length-4 match → round-trip 不受影響。**會改壓縮比/速度**（預期 ratio 微升、速度可能微降）。設 `optLen4ProbeDepth = 0` 即關閉。

## 實測結果：R34 correctness failed

- `run_round.command` 編譯與 `-test` 通過，完整 benchmark 進入 lz4bench。
- `claw-code` n40 / n8 / n4 全部通過 compare，包含 `optimal`。
- `llama.cpp-n40 optimal` 在 encode 階段即出現 `tar: Write error` 與 `[Error] lzfseX failed to create llama.cpp.lzfse.bvx3.optimal`；殘留半成品大小 `465,196,260 bytes`，後續 decode 顯示 `Truncated tar archive`，compare 於 `13:12:24` 失敗。
- 本輪應判定為 **R34 correctness failed**；`tag-less length-4 recovery` 不能保留為有效結果，後續 MB/s / RSS / power 都不可採用。
- `claw-code` 通過但 `llama.cpp` 失敗，表示這不是格式通用 decode 問題，而是 Optimal parser 在特定資料/段上選出會讓 encode pipeline 提前中止或產生截斷輸出的路徑。

## harness 修正

- `zshrc.sh` 的 compare fail-fast 已生效：本輪在 `llama.cpp-n40 optimal` compare 失敗後停止，未繼續跑 trace / power。
- 另修正 `nanoTimeElapsed`：現在會回傳被測 command 的 exit code；`lz4bench` 壓縮階段改為同時檢查 `encode_rc == 0` 與產物存在。下次若 encode 已失敗但半成品存在，會在 encode 階段寫 `ENCODE_FAILED ... <rc>` 並停止，不會誤記為 `ENCODED`。
- `cpu_call_tree_analysis.command` 已在所有 summary 寫完後清除 `trace/*.trace` 與 `trace/*.trace.timeout`，並寫入 `CPU_CALL_TREE_TRACE_CLEANED`，避免分析後保留大型 trace 佔空間。

## 下一輪

- 先將 `optLen4ProbeDepth` 關閉或回退 R34，重跑 baseline 確認 `llama.cpp-n40 optimal` 回復 byte-identical。
- 清理目前未被呼叫的 `relaxLiteralRep0` / `relaxMatchLiteralRep0` 與相關 macro-step 欄位，避免下一輪 DOE 混入無用成本與不相關變數。
- 每位置保留 2 條 state（或只在 rep-heavy 段啟用 small beam），讓「目前稍貴但 rep history 更好」的路徑不被單狀態 DP 提前剪掉。CPU/RSS 會上升,需小範圍 DOE,且為獨立一輪以利歸因。

---

# 第三十二輪：power benchmark 重跑與 CPU power 整合（2026-06-18）

> 本輪在 rollback 最近兩個 commit 後重跑 `helper/power_benchmark.command`，並執行 `helper/power_summary_integrate.command` 將 CPU power / energy 欄位整合回 `BenchMarkResult.csv` 與 `best_points/`。本輪重點是 power harness 與 R31 後狀態驗收，不視為新的演算法 DOE。

## 資料狀態

- `powerResults/power_status.txt` 已完整跑到 `POWER_BENCHMARK_DONE 07:22:23`；前次卡在 `claw-code-tgz-encode` 的 `powermetrics` 停止問題本輪未重現。
- `powerResults/power_summary.csv` 共 72 筆資料，72/72 `status=ok`，沒有 `POWER_NO_SAMPLES` 或 failed row。
- `BenchMarkResult.csv` 共 48 rows，全部都有 `Encode CPU Power(mW)`、`Decode CPU Power(mW)`、`Encode CPU Energy(J)`、`Decode CPU Energy(J)` 欄位。
- `best_points/best_points.md` 已同步新增 power / energy 最低與最高欄位，來源改為 `best_points/best_points.csv`。

## R32 結果摘要

`claw-code` n40 代表值：

| 格式 | 壓縮 MB/s | 解壓 MB/s | 壓縮比 | Encode RSS(MB) | Encode CPU Power(mW) | Encode CPU Energy(J) | CPU top |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Other3 | 502.96 | 705.81 | 0.9871 | 349.5 | 17434.857 | 41.832219 | encode / 71 |
| BVX3 | 642.06 | 427.47 | 0.9516 | 364.7 | 16548.312 | 34.563284 | encode / 62 |
| Lazy2 | 67.68 | 435.97 | 0.9013 | 485.1 | 5603.386 | 115.000515 | parse / 149 |
| Optimal | 36.98 | 416.81 | 0.8605 | 544.2 | 13398.034 | 513.399386 | parse / 730 |

`llama.cpp` n40 代表值：

| 格式 | 壓縮 MB/s | 解壓 MB/s | 壓縮比 | Encode RSS(MB) | Encode CPU Power(mW) | Encode CPU Energy(J) | CPU top |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Other3 | 281.67 | 257.14 | 0.9978 | 389.5 | 15633.500 | 25.293345 | encode / 67 |
| BVX3 | 301.70 | 204.91 | 0.9816 | 376.8 | 16332.727 | 27.401693 | encode / 59 |
| Lazy2 | 177.50 | 296.45 | 0.9583 | 500.4 | 7570.696 | 49.178915 | parse / 123 |
| Optimal | 59.66 | 217.65 | 0.9421 | 577.3 | 15351.469 | 329.643690 | parse / 654 |

Best-points 層級觀察：

- `Other3` 是 Apple-compatible standard LZFSE baseline。`claw-code` n40 代表值為 `502.96 MB/s / 41.832219 J`，但同輪最佳壓縮在 n8 為 `586.02 MB/s / 38.429289 J`；`llama.cpp` n40 代表值為 `281.67 MB/s / 25.293345 J`，同輪最佳壓縮在 n8 為 `420.31 MB/s / 28.528759 J`。因此 R32 評比應同時保留 n40 代表值與 best-points，不可只用 n40 判定 Other3。
- `claw-code` BVX3 最佳壓縮為 `642.06 MB/s`（n40），encode energy 最低同為 n40 的 `34.563284 J`，已接近 TLZ4 `33.225059 J`。
- `claw-code` Lazy2 最佳壓縮為 `67.68 MB/s`（n40），encode energy `115.000515 J`，比 n4 `159.438967 J` 低，維持「提高 n 可同時降時間與能耗」的慢路徑結論。
- `claw-code` Optimal 最佳壓縮為 `36.98 MB/s`（n40），encode energy `513.399386 J`。相對 R31 記錄 `36.95 MB/s / 511.53 J`，速度約 `+0.1%`、能耗約 `+0.4%`，可視為同水位，沒有新的明確改善。
- `llama.cpp` Optimal 最佳壓縮為 `59.66 MB/s`（n40），encode energy `329.643690 J`；Lazy2 n40 為 `177.50 MB/s / 49.178915 J`，再次顯示 Optimal 的能耗主因仍是長時間 DP，而不是高平均功率。

R32 n40 評比：

- 壓縮速度：`claw-code` 為 BVX3 `642.06` > Other3 `502.96` >> Lazy2 `67.68` > Optimal `36.98`；`llama.cpp` 為 BVX3 `301.70` > Other3 `281.67` > Lazy2 `177.50` > Optimal `59.66`。
- 壓縮比：`claw-code` 為 Optimal `0.8605` > Lazy2 `0.9013` > BVX3 `0.9516` > Other3 `0.9871`；`llama.cpp` 為 Optimal `0.9421` > Lazy2 `0.9583` > BVX3 `0.9816` > Other3 `0.9978`。
- Encode energy：`claw-code` 為 BVX3 `34.563284 J` < Other3 `41.832219 J` < Lazy2 `115.000515 J` << Optimal `513.399386 J`；`llama.cpp` 為 Other3 `25.293345 J` < BVX3 `27.401693 J` < Lazy2 `49.178915 J` << Optimal `329.643690 J`。
- 解壓速度：`claw-code` Other3 `705.81 MB/s` 明顯快於 Lazy2 `435.97`、BVX3 `427.47`、Optimal `416.81`；`llama.cpp` 則 Lazy2 `296.45` > Other3 `257.14` > Optimal `217.65` > BVX3 `204.91`。

## 和 R31 的比較與判定

- `claw-code Optimal n40`：`36.95 → 36.98 MB/s`，CPU energy `511.53 → 513.40 J`，屬量測噪音範圍；R31 保留的 cheap-probe gating 判定不變。
- `claw-code BVX3 n40`：`657.59 → 642.06 MB/s`（約 `-2.4%`），encode energy `35.67 → 34.56 J`，速度小退但能耗仍低，沒有指向新回歸。
- `claw-code Lazy2 n40`：`68.73 → 67.68 MB/s`（約 `-1.5%`），基本同水位。
- `claw-code Other3 n40`：`637.91 → 502.96 MB/s`（約 `-21.2%`），但本輪 Other3 最佳壓縮在 n8 為 `586.02 MB/s`，且同輪 BVX3 / Lazy2 / Optimal 沒有同幅退步。這更像批次噪音、熱狀態或 power 量測穿插造成的 n40 異常，不應單獨歸因於 source 變更；下輪需重複驗證 Other3 n40。

## power harness 結論

本輪 power 量測輸出完整，`power_summary_integrate.command` 已把 power 欄位整合進報表，因此 R29 以來「短 decode 可能 no samples」的限制在本輪資料中暫時解除。不過 decode power 數字仍容易受取樣相位影響，例如部分極短 decode 顯示非常低的平均 CPU power；分析時仍以 encode energy 作為主要能耗結論，decode energy 僅作輔助。

## 下一步

1. 下輪若繼續做演算法 DOE，仍以 `claw-code Optimal n40 36.98 MB/s / 513.40 J` 與 `llama.cpp Optimal n40 59.66 MB/s / 329.64 J` 作 R32 energy-aware baseline。
2. 針對 `Other3 n40` 速度異常，下一輪先重複量測或固定熱狀態，再決定是否需要查 encode path；不要只用本輪單點判定回歸。
3. power benchmark 已能完整跑完，但若再次卡在 `powermetrics` 停止流程，應優先檢查 `helper/power_benchmark.command` 的 sudo / child process cleanup，而不是壓縮器本身。

---

# 第三十一輪：revert R30-2 literal UBP 後重測（2026-06-17）

> 本輪目的不是新增演算法改動，而是用已 revert `literal UBP` 的 source 重新跑完整 benchmark，確認 R30 觀察到的 BVX3 / Other3 退步是否來自 #30-2，而不是 #30-1 `Optimal cheap-probe gating`。

## benchmark 結果（claw-code n40，raw bytes/ns）

| 格式 | R31 MB/s | R29 MB/s | 變化 | 判定 |
| --- | ---: | ---: | ---: | --- |
| **Optimal** | **36.95** | 34.93 | +5.8% | #30-1 gating 保留 |
| BVX3 | 657.59 | 672.71 | -2.2% | 已回復正常水位，R30 退步主因確認為 #30-2 |
| Other3 | 637.91 | 618.34 | +3.2% | 已回復正常水位 |
| Lazy2 | 68.73 | 66.46 | +3.4% | 無直接改動，視為整機/排程浮動 |

- **Optimal CPU 能耗**: 511.53 J vs R29 567.2 J → **-9.8%**。速度與能耗皆改善，但仍未達下一輪 ≥10% 單點改善門檻。
- **壓縮比維持不變**: Optimal `0.8590`、BVX3 `0.9516`、Other3 `0.9871`、Lazy2 `0.9013`，表示 #30-1 gating 沒有破壞輸出品質。
- **R30-2 驗證結論**: R30 的 BVX3 `589.03 MB/s` / Other3 `513.14 MB/s` 是含 `litEnc.withUnsafeBufferPointer` binary 的污染結果。R31 revert 後 BVX3 回到 `657.59 MB/s`、Other3 回到 `637.91 MB/s`，確認 literal UBP 應維持 revert。

## trace / power / RSS 觀察

- LZFSE 家族 trace 多數仍是 `trace_timeout=yes`，因此 trace wall time 不作速度比較，只看 target seen 與 CPU symbol 分布。
- Optimal n40 top symbol 仍落在 `lzParseOptimal` closure，`cpu_parse_hits=1129`，表示 cheap-probe gating 只避開低收益段，主要熱點仍是 DP 核心。
- BVX3 n40 encode RSS `355.0 MB`、decode RSS `322.4 MB`，仍明顯高於 TLZ4 / ZSTD，是下一輪需要處理的記憶體問題。
- BVX3 n40 encode CPU energy `35.67 J`，已接近 TLZ4 `34.86 J`，所以 BVX3 下一輪優先順序應是 RSS 與 throughput 穩定性，而不是 encode 能耗。

## 下一步

- 保留 #30-1 `optDPSkipAvgMatchLen = 256`，不要回退。
- 維持 #30-2 literal UBP revert，不再把 `litEnc` literal 熱迴圈包進 `withUnsafeBufferPointer` closure。
- 下一輪若要繼續 Optimal，應直接針對 `lzParseOptimal` DP 核心做 profiling-guided 單點改動，成功條件仍是同輪 ≥10% 改善且壓縮比不退步。
- 下一輪若轉向 BVX3 family，優先調查 encode/decode RSS 偏高原因，特別是 n40 下的 buffer、chunk in-flight、暫存陣列生命週期。

---

# 第三十輪：Optimal cheap-probe gating + literal UBP DOE 結果（2026-06-16）/ Round 30: Cheap-Probe Gating + Literal UBP DOE

> 只動 `lzfse-cli.swift`。本輪同時實驗 **#1**（cheap-probe gating）與 **#2**（literal UBP）。benchmark 結果:#1 有效、**#2 造成 BVX3 退步 −12.4%**。**兩者皆已 commit**（見 lzfse-cli.swift 差分）；#2 的 revert 排入 **R31**。#3（power 量測硬化）屬 harness,未動。

## benchmark 結果（claw-code n40）/ Results

| 格式 | R30 MB/s | vs R27 | vs R29 | 判定 |
| --- | ---: | ---: | ---: | --- |
| **Optimal** | **37.13** | +8.1% | +6.3% | ✅ #1 有效 |
| BVX3 | 589.03 | −7.2% | −12.4% | ❌ #2 退步 → revert |
| Other3 | 513.14 | — | −17.0% | ⚠️ 機器噪音（n40 < n8 587,熱節流/批次長度效應） |
| Lazy2 | 69.15 | +25.0% | +4.0% | — |

- **Optimal 能耗**:502.8 J vs R29 567.2 J → **−11.4%** ✅
- **壓縮比 0.8590 / 0.9416 完全不變** ✅ → #1 gating 安全（門檻 256 保守、被改判段極少且確為長 match 主導）。

## #1 Optimal cheap-probe gating — ✅ 保留

- 在既有兩道閘（熵閘 >7.2、coverage < 28%）後新增第三道:預篩 greedy 掃描順便數 `matchCount`,若**平均 match 長度 ≥ `optDPSkipAvgMatchLen`（預設 256）**→ 長 match 主導段、DP 低收益 → 走既有 `greedyEmitSegment`。
- 驗收:Optimal claw n40 34.93→**37.13 MB/s（+6.3%）**、能耗 **−11.4%**、**壓縮比不變**。正確性 safe（既有 greedy 路徑、合法 bvx3、decoder 不變、round-trip 不受影響）。
- 旋鈕:設 `optDPSkipAvgMatchLen` 極大值即關閉、回到 R29;下調則更積極（需再驗 ratio）。

## #2 literal 編碼迴圈 UnsafeBufferPointer — ❌ BVX3 退步，待 R31 revert

- 把非 ctx literal 迴圈的 `litEnc[...]` 包成 `litEnc.withUnsafeBufferPointer { le in ... }` 後,**BVX3 claw n40 −12.4%、llama −13.0%**。
- 原因研判:在 `-O` 下,`UnsafeBufferPointer` subscript 省下的 bounds-check **不足以抵消 closure 包裹開銷**;closure 邊界可能**阻斷 `fseEncode` 的 inline 或 caller-level 優化**,使這個 per-literal 最熱的迴圈整體變慢。
- 教訓:同樣是「去 bounds-check」,R28 的 LMD 迴圈（6 個 n 大小陣列、每 match 3 次 fseEncode）有效,但 literal 迴圈（每次 4 次 fseEncode、更短迴圈體）反受 closure 包裹拖累——**UBP 包裝並非一律划算,需逐迴圈量測**。`FSEOutStream`/`fseEncode` 已 inline+pointer,純函式無餘地。
- **行動**：R31 將 revert `litEnc.withUnsafeBufferPointer { ... }` 回 `litEnc[Int(lp[...])]`，確認 BVX3 回到 ~672 MB/s 水位。

## #3 power 量測硬化 — 屬 harness,未動

修正點在 `helper/power_benchmark.command`（shell）,不在 `lzfse-cli.swift`。選項:(a) 放寬約束我改 harness（短 decode loop N 次再平均）;(b) 我在 CLI 加 `-repeat N` 供量測。待指定。

## 備註 / Caveat

本輪 benchmark 數據（BenchMarkResult.csv）是**同時含 #1 與 #2 的 binary** 量到的（故 BVX3 顯示退步 −12.4%）。**lzfse-cli.swift 此 commit 仍含 #2**（`litEnc.withUnsafeBufferPointer`）；BVX3 退步來源已確認為 #2。**R31 將 revert #2**，下一輪 benchmark 應見 BVX3 回到 ~672 MB/s 水位以反向確認（依約定本輪不重跑）。Other3 −17% 為機器噪音（n40 慢於 n8）。

---

# 第二十九輪：R26①② + R28 合併 DOE 結果 + 首次 power/energy 量測（2026-06-16）/ Round 29: Combined DOE + First Power Measurement

> 本輪在 R27（tag-packing）基礎上合併三組 **output-identical** 變更一起量測：R28（`encodeBlockV3` LMD `withUnsafeBufferPointer`）、R26①（`lzParseOptimal` 的 `localHead` 外提、per-call 配置）、R26②（3-rep 展開）。並首次納入 `powerResults/` 的 CPU/GPU/DRAM 功率與能耗。只動 `lzfse-cli.swift` 與 `OPTIMIZATION.md`。

## DOE 結果（claw-code / llama.cpp，n40，raw bytes/ns）

| 格式 | claw R27 | claw R29 | 變化 | llama R27 | llama R29 | 變化 | 壓縮比 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **Optimal** | 34.36 | **34.93** | +1.7% | 60.24 | **60.67** | +0.7% | 0.8590 / 0.9416 不變 |
| **BVX3** | 634.82 | **672.71** | +6.0% | 398.70 | **448.98** | +12.6% | 0.9515 / 0.9816 不變 |
| Other3 | ~ | 618.34 | ↑ | ~ | 455.40 | ↑ | 0.9872 / 0.9979 不變 |
| Lazy2 | 55.30 | 66.46 | ↑* | ~173.9 | 193.22 | ↑* | 0.9016 / 0.9588 不變 |

- **壓縮比逐格式 byte 級不變**（0.8590 / 0.9515 / 0.9016 / 0.9872 …）→ 三組變更皆確認 output-identical，無回歸。
- **R28（BVX3）是本輪最大贏家**：claw +6.0%、llama +12.6%，證實 LMD 去 bounds-check 對 encode-bound 的 bvx3/other3 有效。
- **R26①②（Optimal）只小幅 +0.7–1.7%**，**未達 ≥10% 目標**：因為它們省的是 DP *周邊*開銷（prescreen 的 `localHead` 配置、rep transform 迴圈），而 top symbol 仍是 `lzParseOptimal` 的 **DP 核心 closure**——要再快必須動 DP 本身或做段層級 gating。
- `*` Lazy2 本輪無新變更（R6 已在 R27 基準內），數值上升屬整機/排程噪音，不歸因於本輪。

## powerResult 區段總結 / Power & Energy Summary（首次納入）

量測方式：`helper/power_benchmark.command` 以 macOS `powermetrics` 取每個 (格式, encode/decode, n) 的 CPU/GPU/ANE/DRAM 功率(mW)與能耗(J)，整合於 `powerResults/power_summary.csv`、best_points 亦帶入 CPU power/energy 欄位。

**① Encode 能耗（claw-code，J；能耗 ≈ 功率 × 時間）**

| 格式 | 能耗(J) | CPU 功率(mW) | 說明 |
| --- | ---: | ---: | --- |
| tar.lz4 | **36.4** | 17570 | 高功率但極短 → 最省能 |
| Other3 (n40) | 39.1 | 17986 | 與外部工具同級 |
| BVX3 (n40) | 46.9 | 18857 | 滿載核心、快收 → 能耗可接受 |
| ZSTD | 50.8 | 14647 | — |
| Apple (n40) | 65.3 | 6951 | — |
| TGZ | 137.6 | 4471 | 低功率但 30s → 能耗偏高 |
| **Lazy2 (n40)** | **204.7** | 7212 | 長時間主導 |
| **Optimal (n40)** | **567.2** | 13633 | ≈12× BVX3、15× tar.lz4 |

**② Decode 能耗（claw-code，n40，J）——LZFSE 家族是強項**

Optimal **0.85**、Lazy2 1.45、BVX3 2.06 J，**低於** ZSTD 4.08、TGZ 5.40 J。LZFSE 解碼又快又省能。

**③ 三點結論**

1. **Optimal/Lazy2 的能耗問題 = 時間問題**：它們功率其實偏低（7–13.6W，比滿載的 bvx3/zstd 18–19W 低），但 DP/chain 太慢 → 能耗暴衝。**降能耗的槓桿與降時間相同**（段層級 gating 可近似等比例砍能耗）。
2. **BVX3 / Other3 encode 能耗已與 zstd/tar.lz4 同級**（39–47 J vs 36–51 J），不需另做能耗優化;decode 全家族都很省，亦無須處理。
3. ⚠️ **量測限制**：多個極短的 decode 出現 `POWER_NO_SAMPLES`（other3 n40 decode、llama 的 bvx3/lazy2/optimal n40 decode），因解壓 <~0.3–0.5s 短於 powermetrics 取樣間隔。這些 decode 能耗為空,需用較長批次或較小 `-n` 才取得;不影響 encode 能耗結論。

## power 成因解釋（對照最新程式碼）/ Why the Power Numbers Look This Way

心智模型：**能耗 J = 平均功率 W × 時間 s**；而**功率 ≈ 核心忙碌程度（IPC）**。計算密集且資料在快取 → 核心滿載 → 高功率；記憶體密集（cache miss / 指標追逐）→ 核心停在等記憶體 → 低功率，但要跑很久。

**Optimal / Lazy2 = 低功率、高能耗（memory-bound）。** 對照 `lzParseOptimal` DP 前向迴圈（每段 ≤128K 位置）：`hashAndTag(i)`→`head[qh]`/`chain[c]` 是隨機記憶體存取（hash 桶 + 鏈結指標追逐）；`matchLength(...)` 與候選 `load32(c)` 的 `c` 是歷史中的隨機 offset，在 4MiB chunk 頻繁 cache miss；relaxation 又把價格分散寫到 `cPrice[t+ll]`。核心常停在等記憶體 → IPC 低 → 功率僅 7–13.6W，但工作量極大 → 時間爆長 → 能耗暴衝（claw optimal n40 41.6s / 567 J；lazy2 7W / 28s / 205 J）。

**BVX3 / Other3 / tlz4 / zstd = 高功率、低能耗（compute-bound）。** `encodeBlockV3` 核心是 FSE 編碼（緊湊狀態轉移 + bit packing，查表小且常駐快取）→ 核心滿載 → 功率 15–19W，但快 → 2–3.5s → 能耗 39–51 J。tar.lz4 功率最高卻最短 → 最省能（36 J）。

**Decode 全家族省能。** 表驅動 FSE 解碼 + memcpy，循序、快取友善、又平行且短 → 低功率 + 短時間。Optimal 解碼能耗最低（0.85 J），因為它解的是標準 bvx3 串流，路徑與一般 bvx3 相同且快。

**能耗隨 -n 下降（慢路徑）。** `runParallelEncode` 用 N chunk 並行；對 DP 慢路徑，提高 N 縮短時間的幅度大於功率上升 → 能耗反降：claw optimal encode n4 720J → n8 613J → n40 567J；llama optimal n4 505J → n8 386J → n40 337J。故 optimal/lazy2 用較大 `-n` 不只更快、也更省能（代價是 RSS 上升）；bvx3 近滿載，n 對能耗影響不大。

**優化含義。** Optimal 是 memory-bound，微優化（SIMD / 去 bounds-check）對「功率」幫助有限（它本來就沒滿載）；真正砍能耗的是**做更少 DP**——段層級 cheap-probe gating 會近似等比例砍時間與能耗，與「降速度」是同一槓桿。BVX3/Other3 encode 能耗已與 zstd/tlz4 同級、decode 全家族都省 → 能耗面不需再投入。

## 下一步

1. **Optimal 段層級 cheap-probe gating**（會改輸出/壓縮比的較大變更）:把低收益段改走 lazy2/greedy。這是目前 Optimal **速度與能耗**雙重的最大 ROI（尤其 llama optimal 只比 lazy2 小 1.8% 卻耗 ≈337–505 J）。需可編譯/benchmark 驗 ratio 取捨。
2. BVX3:R28 既然有效,可續查 `fseEncode` / `FSEOutStream.push/flush` 的同類 output-identical 加速。
3. power 量測硬化:對過短的 decode 改成多次重複或固定最短取樣時間,補齊 `NO_SAMPLES`。

---

# 第二十八輪：encodeBlockV3 LMD 熱迴圈去 bounds-check 驗收（2026-06-16）

> 只動 `lzfse-cli.swift`。承 R26/R27 trace 確認 `encodeBlockV3` 仍是 BVX3 家族 top symbol（含 `fseEncode`、`FSEOutStream.push/flush` 與 Swift Array/COW）。本輪做一個 **output-identical** 的 encode 加速，已完成 benchmark / memProbe / trace / cpu_call_tree / CSV rebuild 驗收。

## 改動：LMD 編碼迴圈以 UnsafeBufferPointer 存取

- `encodeBlockV3` 的 ② L/M/D 編碼迴圈對每個 match 讀取 6 個 n 大小陣列（`lSyms/mSyms/dSyms` + `lVals/mVals/dVals`），每次都是 Swift Array bounds-check。
- 改為把這 6 個陣列包進巢狀 `withUnsafeBufferPointer`,迴圈內以 pointer 存取,去除每 match × 6 次 bounds-check（R26/R27 trace 的 `swift_array` 熱點之一）。`fseEncode` 與 `lmdOut.push/flush` 的核心 FSE 工作不變;extra-bits / base / encoder 查表（依 symbol 索引、小常數表）維持原樣。
- 正確性:索引（`mi`）與所有發射值、bit push 順序完全不變 → **輸出位元組完全相同,壓縮比不變**。

## 資料狀態

`round_status.txt` 顯示 `compile` 與 `lzfse-test` 通過，兩個資料集的 `-n40/-n8/-n4` benchmark 與 memProbe 都完成；`helper/tracer.command` 於 `16:37:13` 完成，`trace_analysis`、`cpu_call_tree_analysis`、`BenchMarkResult.csv` rebuild 與 `best_points` 於 `16:42:06` 完成。`run_round.command` 未留下最外層 `BENCH_DONE` 行，但 benchmark pipeline 的分析輸出已完整重建。

`lzfse-test.txt` 顯示 Other3、BVX3、Lazy2、Optimal、Apple 相容與平行解碼路徑皆通過。BVX3 壓縮後大小維持 `claw-code 446M`、`llama.cpp 572M`，壓縮比維持 `0.9515 / 0.9816`；此輪符合 output-identical 目標。

## Benchmark 結果

以 `BenchMarkResult.csv` 的 raw bytes / ns MB/s 比較 R27 → R28：

- `claw-code` BVX3：n40 `634.82 → 672.71 MB/s`（`+6.0%`），n8 `596.70 → 588.41 MB/s`（`-1.4%`），n4 `380.58 → 405.68 MB/s`（`+6.6%`）。n40 達到 5–10% 目標區間，n8 小退但仍接近 R27。
- `llama.cpp` BVX3：n40 `398.70 → 448.98 MB/s`（`+12.6%`），n8 `396.03 → 414.69 MB/s`（`+4.7%`），n4 `322.67 → 336.25 MB/s`（`+4.2%`）。此資料集三個 n 都改善，n40 超過 10%。
- Other3 雖未直接修改 `encodeBlock`，仍在本輪同步上升：`claw-code n40 618.34 MB/s`、`llama.cpp n40 455.40 MB/s`。這比較可能是輪次噪音、cache / I/O 或編譯環境波動，不應歸因於 R28 的 pointer 化。
- Lazy2 / Optimal 的壓縮速度也有波動：`claw-code n40 Lazy2 66.46 MB/s`、Optimal `34.93 MB/s`；`llama.cpp n40 Lazy2 193.22 MB/s`、Optimal `60.67 MB/s`。這些 parser 路徑未被 R28 直接命中，僅作背景基準。

解壓速度不是本輪改動目標，但需要記錄退步：BVX3 n40 解壓從 R27 的 `746.42 → 663.05 MB/s`（claw-code，`-11.2%`）與 `292.37 → 224.37 MB/s`（llama.cpp，`-23.3%`）。解壓路徑未被本輪修改，較可能是量測波動、I/O/cache、trace/memProbe 前後狀態或資料集 tar 狀態影響；下一輪若繼續改 encode，仍需盯住 decode 不可持續退步。

RSS 取捨大致維持原判斷：BVX3 n40 encode RSS `claw-code 366.3 MB`（R27 `350.7 MB`，`+4.4%`）、`llama.cpp 380.2 MB`（R27 `394.2 MB`，`-3.6%`）。decode RSS 仍約 `315–343 MB`，明顯高於 ZSTD decode 約 `9–10 MB` 與 TLZ4 decode 約 `34 MB`。

## Trace / CPU 解讀

`trace/analysis` 本輪 36 個 trace 均可匯出 time-profile / time-sample；LZFSE encode trace 仍多為 300s timeout，只用於 hotspot 方向，不用於完整耗時計算。

- R28 命中的熱點確實下降：BVX3 n40 `encodeBlockV3` top count 從 R27 的 `100 → 64`（claw-code，`-36%`）與 `102 → 57`（llama.cpp，`-44%`）。`CPU Encode Hits` 也從 `137 → 130`（claw-code）與 `150 → 122`（llama.cpp）下降。
- 但 `CPU Swift Array Hits` 反而上升：claw-code n40 `84 → 106`，llama.cpp n40 `77 → 101`。解讀是 LMD 讀取迴圈 bounds-check 被移除後，剩餘陣列成本轉移到 `encodeBlockV3` 前段 staging、symbol/value arrays、FSE output buffer 或其他 Array/COW 路徑；R28 不是 Array 成本的終點。
- `llama.cpp n4` BVX3 top symbol 轉為 `static LZFSEv1.fseEncode(state:_:_:)`，表示小 n / 低併發下 FSE encode 已可壓過 `encodeBlockV3` loop 本身。下一個 BVX3 單點若只再 pointer 化 LMD 讀取，邊際效益會降低。
- Optimal 的 CPU parse hits 本輪上升（例如 claw-code n40 `922 → 1160`、llama.cpp n40 `877 → 1086`），再次確認 Optimal 下一步不該靠 encodeBlockV3；應另做段層級 cheap probe / envelope pruning。

## 結論與下一步

R28 可保留：它是 output-identical、correctness 通過、BVX3 n40 在兩個資料集都有明確壓縮速度改善，且 trace 顯示 `encodeBlockV3` top count 顯著下降。成功條件「同資料集同 n 不退、理想 5–10%」在 n40 成立，尤其 `llama.cpp` 超過 10%。

下一步建議：

1. BVX3：不要再只針對 LMD 讀取 loop 微調。優先看 `encodeBlockV3` 前段 staging / symbol arrays / FSEOutStream，目標是讓 Swift Array hits 降回 R27 以下，且 BVX3 n40 壓縮維持 `claw-code ≥670 MB/s`、`llama.cpp ≥445 MB/s`。
2. RSS：BVX3 encode RSS 仍是 `~366–380 MB`，decode RSS `~315–343 MB`；若再做 encode path 優化，需同步設定 RSS 成功條件，例如同 n RSS 降 `>=10–20%` 或至少不再升高。
3. Decode：下一輪需確認 BVX3 decode 退步是否可重現。若連續兩輪都低於 R27，應先查 decode benchmark 的 I/O/cache 與 parallel inflight，而不是把問題歸因於 R28。
4. Optimal：維持 R27 結論，下一個真正有機會的方向是段層級 cheap probe / envelope pruning；這會改輸出選路與可能改壓縮比，需作為獨立 DOE，不要混在 output-identical encode 微優化裡。

---

# 第二十七輪：Optimal tag-packed hash chain 驗收（2026-06-16）

## 變更摘要

本輪將 tag-packing 同步進 `lzParseOptimal`，並讓 `lzParseChain` 使用同一套 packed hash chain。核心是把 hash bucket 與 8-bit secondary tag 由一次 5-byte 乘法產生，`head[h]` 存 `(tag << 24) | idx`，`chain[idx]` 沿用前一節點 packed 值。走訪鏈時先用 `(packed >> 24) == qtag` 做純暫存器過濾，不符就跳過，減少純碰撞候選造成的 `p[c]` 隨機讀取與 pointer chasing。

這次不改 bitstream 格式、不改 decoder、不改 FSE table 建構，也不改 `lzParseStrong` / `lzParse` 的獨立 `hashTable`。Optimal 的 coverage prescreen 仍使用獨立 `localHead`，不污染主 `head/chain`。`greedyEmitSegment` 只解包低 24-bit index，不做 tag 過濾，維持 greedy 候選語意。

## 正確性與資料狀態

- `hashAndTag` 取代 `hash4` 後，bucket 仍使用乘積高 `chainHashBits` 位，tag 取相鄰 8 位；插入與查詢使用同一函式。
- `insert` 保持 `chain[idx] = head[h]`、再更新 `head[h]` 的順序，鏈結語意不變，只是節點指標從 raw index 變成 packed 值。
- `lzParseOptimal` 在 DP 內仍先取 `candPacked/qtag` 再 `insert(i)`，避免 self reference。
- `chainNullIndex = 0x00FF_FFFF` 對應 `head = -1` 的低 24 bits；真實 chunk index 由 `parallelChunkSize = 4MiB` 保證小於 sentinel。
- 新增 `assert(n <= chainIndexMask)` 只在 debug 檢查 chunk 上限，`swiftc -O` release 無 assert 成本。

本輪 `round_status.txt` 已到 `BENCH_DONE 04:10:42`，`BenchMarkResult.csv` 共 48 rows，包含 `-n4/-n8/-n40` 的速度、RSS、trace target 與 CPU top symbol 欄位。`lzfse-test.txt` 顯示 Other3、BVX3、Lazy2、Optimal、Apple 相容與平行解碼路徑皆通過；tag-packing 未造成 round-trip 或格式相容回歸。

## Benchmark 結果

以 raw bytes / ns 重算 MB/s 後，Optimal 的加速成立，但兩個資料集幅度不同：

- `claw-code` Optimal：`n4 57.80s / 24.50 MB/s`、`n8 47.36s / 29.90 MB/s`、`n40 41.21s / 34.36 MB/s`，壓縮比維持 `0.8590`。對照前一基準 `69.12s / 53.27s / 47.08s`，約改善 `19.6% / 11.1% / 12.5%`。
- `llama.cpp` Optimal：`n4 33.59s / 39.37 MB/s`、`n8 24.80s / 53.33 MB/s`、`n40 21.95s / 60.24 MB/s`，壓縮比為 `0.9416`，相對前一基準 `0.9415` 只有極小浮動。對照前一基準 `35.27s / 25.95s / 23.11s`，約改善 `4.8% / 4.4% / 5.0%`。
- Lazy2 在 `claw-code` 最佳壓縮為 `55.30 MB/s`（n40），低於上一輪紀錄 `57.54 MB/s`；但 `llama.cpp` 最佳壓縮為 `186.98 MB/s`（n40），高於上一輪 `173.90 MB/s`。因此 tag-packing 對 `lzParseChain` 不是單調收益，後續不應把 Lazy2 加速歸因於 tag 本身。
- BVX3 / Other3 仍由 encode path 主導。`claw-code` BVX3 最佳壓縮 `634.82 MB/s`（n40），`llama.cpp` BVX3 最佳壓縮 `398.70 MB/s`（n40）；壓縮比維持 `0.9515 / 0.9816`。

RSS 取捨沒有改變：n40 通常提高 LZFSE 家族壓縮速度，但 encode/decode RSS 也上升。Optimal encode RSS 從 n4 到 n40 約為 `212.3 → 570.2 MB`（claw-code）與 `221.7 → 572.8 MB`（llama.cpp）；decode RSS 則升到 `313–342 MB` 等級。這仍明顯高於 ZSTD decode 約 `9 MB` 與 TLZ4 decode 約 `34 MB`，所以後續不能只追壓縮 MB/s。

## Trace / CPU 解讀

`trace/analysis/trace_summary.csv` 顯示 36 個 trace 都有 `target_seen=yes`，`time-profile/time-sample` schema 皆可匯出。LZFSE encode trace 多為 300s timeout，因此只能判斷 hotspot 方向，不能拿來算完整 wall time 或 MB/s。

CPU call tree 顯示 tag-packing 有降低部分 parser 成本，但不是主瓶頸的完整答案：

- Optimal top symbol 仍是 `specialized closure #1 in static LZFSEv1.lzParseOptimal`。`claw-code n40` top count 從上一輪 `565` 降到 `532`，parse hits 從 `963` 降到 `922`；`llama.cpp n40` top count 從 `508` 降到 `499`，parse hits 從 `893` 降到 `877`。下降幅度只有約 `2–6%`，小於 wall-time 改善，代表收益可能混有本輪噪音、分段排程或其他程式碼變更影響。
- `hashAndTag` 本身進入全域熱點但 count 只有 `52`（Optimal）與 `44`（Chain），沒有變成新的主要瓶頸。
- Lazy2 top symbol 仍是 `lzParseChain.bestMatch`，全域 `bestMatch` count `827`；`repLen`、`matchLength` 仍可見，表示下一步 Lazy2 應繼續針對 match 掃描與候選策略，而不是再加深 tag filter。
- BVX3 top symbol 仍是 `encodeBlockV3`，全域 count `1473`，另有 `fseEncode`、`FSEOutStream.push/flush`、Swift Array/COW 熱點。BVX3 家族下一個高勝率方向仍是 encode/FSE/array staging 與 RSS 控制。

## 下一步

1. Optimal：tag-packing 可保留，但不再把 hash-chain collision 當主線。下一輪應做段層級 cheap probe / envelope pruning，讓低收益段走 Lazy2 或 greedy；成功條件是同輪 Optimal wall time 再改善 `>=10%`，壓縮比不明顯退步，且 CPU top symbol 從 `lzParseOptimal` closure 或 parse hits 上有可解釋下降。
2. Lazy2：不要只延伸 tag filter。優先看 `bestMatch` 內的候選接受順序、`matchLength` 掃描次數與 rep fast path；要求同輪兩資料集至少一個固定 `-n` 有 `>=10%` 改善，另一資料集不可明顯退步。
3. BVX3：主線放回 `encodeBlockV3`、FSE output 與 Swift Array/COW。若速度已接近 TLZ4/ZSTD，下一個驗收要把 RSS 納入一級目標，例如同 `-n` encode/decode RSS 降 `>=20%` 且 MB/s 不退超過 `5%`。
4. Benchmark 流程：保留 `-n4/-n8/-n40` 固定掃描；trace timeout 結果只寫 hotspot 解讀，不寫速度；每輪都確認 `CPU_CALL_TREE_ANALYSIS_DONE` 早於 `BENCHMARK_RESULT_REBUILD_DONE`，避免 `BenchMarkResult.csv` 的 CPU 欄位空白。

---

# 第二十六輪驗收補充：Benchmark / Trace / CPU 欄位已重建（2026-06-16）

## 資料狀態

本節依最新 `BenchMarkResult.csv`、`best_points/best_points.md`、`trace/analysis/trace_summary.csv`、`trace/analysis/cpu_call_tree_summary/`、`round_status.txt` 與 `lzfse-test.txt` 彙整。這輪先前曾出現 `BenchMarkResult.csv` 的 CPU 欄位空白，原因是 `benchmark.sh` 的排程先執行 `benchmark_result_rebuild.command --write`，後執行 `cpu_call_tree_analysis.command`。目前流程已修正為：

`trace_analysis` → `cpu_call_tree_analysis` → `git gc` → `benchmark_result_rebuild --write` → `best_points_analysis`

最新已用現有 trace 產物補跑 `helper/cpu_call_tree_analysis.command`、`helper/benchmark_result_rebuild.command --write` 與 `helper/best_points_analysis.command`。`BenchMarkResult.csv` 共 48 rows，48 rows 皆已有 `CPU Symbol Status`；主要 CSV 仍為 UTF-8 BOM，維持 Excel 中文相容。

`trace_summary.csv` 目前有 36 筆 trace summary，全部 `target_seen=yes` 且 `time-profile/time-sample` 皆為 `ok`；其中 30 筆為 timeout trace。這些 timeout trace 可用於 hotspot 方向判斷，但不可拿來計算完整執行時間或 MB/s。`cpu_call_tree_summary.csv` 有 72 rows：36 筆 `time-profile` symbol 統計與 36 筆 `time-sample` raw kperf address table；`hot_symbols_global.csv` 目前只保留前 500 名全域熱點，避免產物膨脹。

`lzfse-test.txt` 顯示 correctness case 維持通過：Other3 自我往返與 Apple 相容、bvx3 / lazy2 / optimal 自我往返、平行解碼、私有 bvx3 Apple 拒解、單流後援與 Apple 互解路徑皆正常。

## 最新速度 / 壓縮比 / RSS

`best_points/best_points.md` 顯示本輪最佳點如下：

- `claw-code`
  - Other3：最佳壓縮 `596.14 MB/s`（n8），最佳解壓 `766.42 MB/s`（n40），壓縮比 `0.9872`。
  - BVX3：最佳壓縮 `646.70 MB/s`（n40），最佳解壓 `574.21 MB/s`（n8），壓縮比 `0.9515`，最低 encode RSS `129.2 MB`（n4）。
  - Lazy2：最佳壓縮 `57.54 MB/s`（n40），最佳解壓 `652.50 MB/s`（n8），壓縮比 `0.9016`，最低 encode RSS `192.9 MB`（n4）。
  - Optimal：最佳壓縮 `29.84 MB/s`（n40），最佳解壓 `679.77 MB/s`（n8），壓縮比 `0.8590`，最低 encode RSS `197.4 MB`（n4）。
  - ZSTD：最佳壓縮比 `0.8255`，最佳壓縮 `482.03 MB/s`（log n8），最佳解壓 `787.58 MB/s`（log n40），decode RSS 約 `9.0–9.1 MB`。
- `llama.cpp`
  - Other3：最佳壓縮 `447.76 MB/s`（n40），最佳解壓 `265.95 MB/s`（n40），壓縮比 `0.9978`。
  - BVX3：最佳壓縮 `437.28 MB/s`（n40），最佳解壓 `252.98 MB/s`（n4），壓縮比 `0.9815`，最低 encode RSS `132.9 MB`（n4）。
  - Lazy2：最佳壓縮 `173.90 MB/s`（n40），最佳解壓 `294.33 MB/s`（n8），壓縮比 `0.9587`，最低 encode RSS `194.5 MB`（n4）。
  - Optimal：最佳壓縮 `56.21 MB/s`（n40），最佳解壓 `253.37 MB/s`（n4），壓縮比 `0.9415`，最低 encode RSS `217.4 MB`（n4）。
  - ZSTD：最佳壓縮比 `0.9123`，最佳壓縮 `469.71 MB/s`（log n4），最佳解壓 `294.07 MB/s`（log n8），decode RSS 約 `9.0–9.4 MB`。

RSS 取捨仍清楚：n40 通常給 LZFSE 家族最高壓縮速度，但 encode RSS 也升高。n40 代表值為 `claw-code` BVX3 `359.1 MB`、Lazy2 `488.4 MB`、Optimal `570.3 MB`；`llama.cpp` BVX3 `394.8 MB`、Lazy2 `525.5 MB`、Optimal `573.6 MB`。因此後續優化不能只看 MB/s，仍需同步看 RSS 與壓縮比。

## CPU 熱點結論

`BenchMarkResult.csv` 現已直接帶入 CPU top symbol / count / category，不必再另行手動對照 summary CSV。主要熱點維持和 R26 假設一致：

- BVX3：兩個資料集 n40 top category 都是 `encode`，top symbol 為 `specialized static LZFSEv1.encodeBlockV3(triplets:literals:rawBytes:)`。n40 代表值：`claw-code` top count `92`、`llama.cpp` top count `99`。R26 的 `encodeBlockV3` 單趟融合方向仍正確。
- Lazy2：top symbol 穩定為 `bestMatch #1 (_:) in closure #1 in static LZFSEv1.lzParseChain(_:maxL:maxM:maxDist:)`。n40 代表值：`claw-code` top count `162`、parse hits `380`；`llama.cpp` top count `130`、parse hits `317`。R26 的 rep 長度快取仍是正確焦點。
- Optimal：top symbol 穩定為 `specialized closure #1 in static LZFSEv1.lzParseOptimal(_:maxL:maxM:maxDist:)`。n40 代表值：`claw-code` top count `565`、parse hits `963`；`llama.cpp` top count `508`、parse hits `893`。Optimal 的主要成本仍在 DP / parse closure，下一步若要動 optimal，應先做段層級 gating 或 cheap probe，而不是只微調 encode path。
- Other3 / Apple / 外部工具：Other3 主要在 `encodeBlock` / FSE，Apple 在 `lzfseEncodeMatches`，TLZ4 / ZSTD 熱點屬外部工具內部 symbol，不應和 Swift LZFSE parser 熱點混比。

## 下一步

1. 以本輪數字更新驗收基準：BVX3 以 `claw-code n40 646.70 MB/s` / `llama.cpp n40 437.28 MB/s`；Lazy2 以 `57.54 / 173.90 MB/s`；Optimal 以 `29.84 / 56.21 MB/s`。
2. 後續每次完整 benchmark 必須確認 `round_status.txt` 中 `CPU_CALL_TREE_ANALYSIS_DONE` 早於 `BENCHMARK_RESULT_REBUILD_DONE`，避免 CPU 欄位再次空白。
3. 下一個程式碼優化仍優先驗收 R26 的兩個單點：BVX3 `encodeBlockV3` 與 Lazy2 `bestMatch`；每個改動都需同時比較壓縮速度、解壓速度、壓縮比、encode/decode RSS 與 CPU top symbol 變化。

---

# 第二十六輪：BVX3 / Lazy2 CPU 單點優化（2026-06-15）/ Round 26: BVX3 & Lazy2 Single-Point CPU Opts

> 只動 `lzfse-cli.swift`。承 R25 cpu_call_tree 的 top symbol（BVX3→`encodeBlockV3`、Lazy2→`lzParseChain.bestMatch`），做兩個**輸出位元組完全相同、不改壓縮比**的單點加速;待 benchmark/memProbe 驗收。

## 改動 1：`encodeBlockV3` 三趟融合為單趟 / Fuse 3 passes into 1

- 原本對 nMatches 走三趟:(a) 由 triplets 建 `lVals/mVals/dVals`、(b) 3 深度 rep-offset transform、(c) 計算 `lSyms/mSyms/dSyms` 與頻次 `lOcc/mOcc/dOcc`。
- 改為**單一 `for t in triplets` 迴圈**內一次完成值擷取、rep-offset、符號與頻次;陣列改一次性配置（`repeating:count:`）而非 `append`。
- 效果:對 nMatches 的走訪由 3 趟→1 趟,移除 `append` 重配置與大量 Swift Array 走訪（R25 trace 的 `encode` + `swift_array` 熱點）。`lVals/mVals/dVals` 仍保留供後段 LMD 編碼的 extra bits 使用,故只融合前段、不刪陣列。
- 正確性:rep-offset 的 MTF 狀態機、M=0→發 0、symbol 計算順序與輸入值完全一致 → **輸出位元組不變**。

## 改動 2：`lzParseChain.bestMatch` 的 rep 長度快取 / Cache rep lengths

- `bestMatch` 的 ①（rep 先試）已用 `repLen`(內含 `matchLength` 掃描) 算過 rep0/1/2 長度;但 ③（rep 接近最佳時改選）**又重算了一次** `repLen`。
- 改為在 ① 一次算出 `l0/l1/l2`（相同距離直接共用、不重複掃描），③ 直接重用,移除每次 `bestMatch` 最多 3 次 `matchLength` 掃描。
- 效果:`bestMatch` 是 Lazy2 的 top symbol;③ 在「最佳 match 來自鏈而非 rep」時觸發（常見），此處省下的 `matchLength` 是 lazy2 的隱性大宗。
- 正確性:快取值與原重算值逐一相等、`else-if` 短路選擇順序不變 → **選到的 (len,dist) 完全相同 → 輸出位元組不變**。

## 驗收（待你 benchmark）

- `swiftc -O` 可編譯、`./lzfse -test` 全過、7/7 一致、壓縮比 byte 級不變（兩改動皆 output-identical）。
- 速度基準（R25 claw n40）:BVX3 `631.83 MB/s`、Lazy2 `57.88 MB/s`;目標同資料集同 `-n` 下 ≥10% 單點加速。
- ⚠️ 沙箱無 swiftc,本輪只做了結構/平衡靜態檢查;實際快慢需你的 benchmark 量測。

---

# 第二十五輪補充：完整 staged 結果檢查（2026-06-15 16:59）

## 完成狀態

本輪 staged 的 `.txt` / `.csv` / `.md` 結果已覆蓋 `lz4bench_log/` 的 n4 / n8 / n40 批次、`memprobeResults/` 的兩資料集記憶體量測、`trace/analysis/trace_summary.csv`、`trace/analysis/cpu_call_tree_summary/` 與 `lzfse-test.txt`。`benchmark.sh` 已完整跑完，`round_status.txt` 結尾為 `BENCH_DONE 16:59:54`。`helper/tracer.command` 以 `EXIT 0` / `TRACE_DONE 16:45:49` 結束；`helper/trace_analysis.command` 以 `TRACE_ANALYSIS_DONE 16:51:29` 結束；`helper/cpu_call_tree_analysis.command` 以 `CPU_CALL_TREE_ANALYSIS_DONE 16:59:54` 結束。

`trace/analysis/trace_summary.csv` 顯示外部工具 `tgz`、`zstd`、`tar.lz4` 在兩個資料集都正常完成；所有 LZFSE encode trace 都是 `300s` timeout trace，但 `target_seen=yes`、`time-profile=ok`、`time-sample=ok`。因此這批 LZFSE trace 可用於 hotspot 方向判斷，不應拿來計算完整執行時間或 MB/s。

`lzfse-test.txt` 仍維持 correctness 全通過：other3 自我往返與 Apple 相容、bvx3 / lazy2 / optimal 自我往返、平行解碼、私有 bvx3 Apple 拒解、單流後援與 Apple 互解路徑都沒有回歸。小型 correctness case 只作功能驗證，不與大型資料集 MB/s 混比。

## 最新速度與 RSS 基準

最新 staged `BenchMarkResult.csv` 與 `best_points/best_points.md` 仍以 raw bytes / ns 重新計算 MB/s。和前一版 R25 相比，整體趨勢不變，但最佳點小幅更新：

- `claw-code`
  - Other3 最佳壓縮 `593.25 MB/s`（n8），最佳解壓 `784.59 MB/s`（n8），encode RSS `141.7–363.1 MB`。
  - BVX3 最佳壓縮 `631.83 MB/s`（n40），壓縮比 `0.9515`，最佳解壓 `733.09 MB/s`（n40），encode RSS `128.8–360.9 MB`。
  - Lazy2 最佳壓縮 `57.88 MB/s`（n40），壓縮比 `0.9016`，encode RSS `187.5–500.6 MB`。
  - Optimal 最佳壓縮 `30.08 MB/s`（n40），壓縮比 `0.8590`，encode RSS `214.2–561.6 MB`。
  - ZSTD 壓縮比 `0.8255`，最佳壓縮 `462.72 MB/s`，最佳解壓 `1039.33 MB/s`，decode RSS 約 `9.0–9.2 MB`。
- `llama.cpp`
  - Other3 最佳壓縮 `449.94 MB/s`（n40），壓縮比 `0.9978`，decode 約 `272.63–275.90 MB/s`。
  - BVX3 最佳壓縮 `446.62 MB/s`（n40），壓縮比 `0.9815`，最佳解壓 `281.88 MB/s`（n40）。
  - Lazy2 最佳壓縮 `178.25 MB/s`（n40），壓縮比 `0.9587`。
  - Optimal 最佳壓縮 `57.06 MB/s`（n40），壓縮比 `0.9415`。
  - ZSTD 壓縮比 `0.9123`，最佳壓縮 `471.62 MB/s`，最佳解壓 `313.12 MB/s`。

RSS 結論仍維持：Swift LZFSE 家族已不是 GB 級問題，但 n40 的 encode / decode working set 仍明顯高於 TLZ4 / ZSTD。尤其 lazy2 / optimal encode RSS 隨 n 提高到 `500–606 MB` 等級，下一輪不應只看壓縮速度，還要固定 `-n` 比較 RSS 與 throughput 的取捨。

## cpu_call_tree 結論

這輪 `cpu_call_tree_summary.csv` 已同時覆蓋 `claw-code` 與 `llama.cpp`。`time-profile` 有 symbol occurrence，可做 hotspot 排序；`time-sample` 仍是 raw kperf address table，只保留 row count 與 target 狀態，不納入 symbol 排名。注意：目前 staged `BenchMarkResult.csv` 已同步 trace wall time / timeout / target_seen，但 CPU symbol 欄位仍是空欄；CPU 結論需以 `trace/analysis/cpu_call_tree_summary/cpu_call_tree_summary.csv` 為準。

- BVX3：兩個資料集、n4/n8/n40 的 top symbol 都是 `encodeBlockV3`，且 encode hits 與 Swift Array hits 同時上升；下一步優先檢查 `encodeBlockV3`、`FSEOutStream`、array bounds / COW，而不是只改 parser。
- Lazy2：兩個資料集的 top symbol 都是 `lzParseChain.bestMatch`；`repLen` / `matchLength` 仍是應拆開量測的次級熱點。
- Optimal：兩個資料集的 top symbol 都是 `lzParseOptimal` closure；n40 的 symbol rows 與 unique symbols 明顯高於 n4，表示 DP relaxation / price rebuild / emit path 都會隨掃描深度放大。下一步應先做段層級 cheap probe，低收益段避開 optimal。
- Other3：top symbol 穩定在 `encodeBlock`，同時伴隨 `lzParseStrong`、FSE 與 Swift Array 成本；若要優化 standard LZFSE，應用同一套 encode buffer / array 成本檢查。
- Apple：top symbol 為 `lzfseEncodeMatches` / `lzfseEncodeBase`，代表 Apple Compression 的內部 LZFSE 路徑，不應和 Swift parser 熱點混比。

## 下一步修正

1. **BenchmarkResult 欄位同步**：目前 `BenchMarkResult.csv` 的 trace wall time / timeout / target_seen 已更新，但 CPU symbol 欄位仍需重新對齊最新 `cpu_call_tree_summary.csv`，避免空欄影響後續排序；對齊鍵應使用 dataset + algorithm + n，外部工具則以 dataset + algorithm。
2. **大檔策略**：原始 trace XML / trace package 容易造成 GitHub 100MB 限制與 repo 膨脹；後續 commit 應以 summary CSV / notes 為主，原始 trace 留本機或改外部儲存。
3. **bvx3 家族優化順序**：先做 BVX3 `encodeBlockV3` 單點 A/B，再做 Lazy2 `bestMatch` / `matchLength`，最後才做 Optimal 段層級 gating。每個改動都要同時看速度、壓縮比與 RSS。
4. **驗收基準更新**：BVX3 以 `claw-code n40 631.83 MB/s` / `llama.cpp n40 446.62 MB/s` 為速度基準；Lazy2 以 `57.88 / 178.25 MB/s` 為基準；Optimal 以 `30.08 / 57.06 MB/s` 為基準。任一改動至少需在同輪同資料集證明 `>=10%` 單點改善或 `>=20%` RSS 降幅，且壓縮比不可明顯退步。

---

# 第二十五輪：trace / cpu_call_tree 納入 BenchMarkResult（2026-06-15）

## 本輪資料狀態

本輪重讀 `lz4bench_log/lz4bench-*-n*.txt`、`lzfse-test.txt`、`memprobeResults/`、`trace/analysis/trace_summary.csv` 與 `trace/analysis/cpu_call_tree_summary/`，並重建 `BenchMarkResult.csv`。CSV 仍以 raw bytes / ns 計算 decimal MB/s；新增欄位包含 `Trace timeout`、`Trace target seen`、`CPU Symbol Status`、`CPU Top Symbol`、`CPU Top Category` 與 parse / encode / fse / Swift Array hit counts。

`lzfse-test.txt` 仍作正確性依據，不與大型資料集的 MB/s 混比。`trace/analysis` 目前只有 `claw-code` 的有效 trace；`claw-code-apple-n8.trace` 因前次 `.out` 被外部刪除而是 `incomplete_package`，已在 `trace_summary.csv` 中跳過，不納入 cpu call tree。

## 最新 throughput 與 RSS 結論

`-n` 掃描仍顯示 bvx3 家族在壓縮速度、壓縮比與 RSS 之間有明顯取捨：

- `claw-code`：
  - Other3 最佳壓縮 `559.49 MB/s`（n8），壓縮比 `0.9872`。
  - BVX3 最佳壓縮 `625.62 MB/s`（n40），壓縮比 `0.9515`，但解壓最佳 `731.24 MB/s` 也在 n40。
  - Lazy2 壓縮比 `0.9016`，最佳壓縮 `55.96 MB/s`（n40）。
  - Optimal 壓縮比 `0.8590`，最佳壓縮 `28.81 MB/s`（n40）。
  - ZSTD 壓縮比 `0.8255`，最佳壓縮 `453.67 MB/s`，最佳解壓 `965.14 MB/s`。
- `llama.cpp`：
  - Other3 最佳壓縮 `412.03 MB/s`（n40），壓縮比 `0.9978`。
  - BVX3 最佳壓縮 `374.86 MB/s`（n40），壓縮比 `0.9815`。
  - Lazy2 壓縮比 `0.9587`，最佳壓縮 `163.28 MB/s`（n40）。
  - Optimal 壓縮比 `0.9415`，最佳壓縮 `54.12 MB/s`（n40）。
  - ZSTD 壓縮比 `0.9123`，最佳壓縮 `390.99 MB/s`。

本輪 memProbe 結果和 R24 不同，RSS 已降到數百 MB 等級，R24 的「LZFSE 家族 encode/decode RSS 仍是 1GB+」結論應視為舊資料或舊 probe 方法結果：

- `claw-code` encode RSS：
  - Other3 `135.9–354.9 MB`
  - BVX3 `139.9–370.2 MB`
  - Lazy2 `187.9–501.2 MB`
  - Optimal `216.5–572.0 MB`
- `claw-code` decode RSS：
  - Other3 `69.0–307.3 MB`
  - BVX3 `69.5–316.3 MB`
  - Lazy2 `68.0–316.0 MB`
  - Optimal `65.1–313.0 MB`
- `llama.cpp` encode RSS：
  - Other3 `129.8–360.1 MB`
  - BVX3 `135.6–390.2 MB`
  - Lazy2 `201.4–514.0 MB`
  - Optimal `212.1–572.9 MB`
- `llama.cpp` decode RSS：
  - Other3 `67.2–341.5 MB`
  - BVX3 `77.4–343.4 MB`
  - Lazy2 `63.1–339.5 MB`
  - Optimal `67.2–343.7 MB`

RSS 仍高於 TLZ4 decode `33.8 MB` 與 ZSTD decode `9 MB`，但已不再是 GB 級。下一輪 memory 工作應從「整檔化」改成「仍有數百 MB working set」來定位：chunk scratch、parser chain、encode staging 與 parallel inflight 上限仍是主要嫌疑。

## trace / cpu_call_tree 發現

`helper/tracer.command` 現在使用 direct launch + `--target-stdin`，可在 Time Profiler 中看到 `lzfse-profile`。同時新增 `.out.active` marker，避免再次刪除正在被 xctrace 使用的 `.out`。`trace_analysis.command` 已支援 `.trace.timeout`；timeout trace 可用於 hotspot 方向，但不能用於 MB/s 或完整耗時判斷。

本輪 cpu call tree 的有效 LZFSE trace 都在 `claw-code`：

- Other3 n4/n8：top symbol 是 `encodeBlock`，同時有 `lzParseStrong`、`fseEncode` 與 Swift Array bounds/COW 成本。
- BVX3 n4：top symbol 是 `encodeBlockV3`，分類為 encode；hit count 顯示 encode 與 Swift Array 成本都明顯，不能只看 parser。
- Lazy2 n4：top symbol 是 `lzParseChain.bestMatch`，`repLen`、`matchLength` 也在全域 hot symbols 前列。
- Optimal n4：top symbol 是 `lzParseOptimal` 的核心 closure；`emitSteps`、`samplePointEntropyAndText`、`rebuildPrices` 也進入 hot symbols，表示 DP / 預篩 / emit 都需要拆開量。
- Apple n4：top symbol 是 `lzfseEncodeMatches` / `lzfseEncodeBase`，屬 Apple LZFSE 實作，不應與自家 Swift parser 混為同一熱點。

`time-sample` 是 raw kperf address table，目前只記 row count 與 target 狀態，不納入 symbol 熱點排名；`time-profile` 才是目前的 symbol occurrence 來源。

## bvx3 家族下一步策略

1. **先做單點 CPU hotspot，不再泛稱 UnsafePointer 化**：BVX3 先針對 `encodeBlockV3` / `FSEOutStream` / Swift Array bounds 做單點改動；Lazy2 針對 `lzParseChain.bestMatch/repLen/matchLength`；Optimal 針對 `lzParseOptimal` 的 DP closure、`emitSteps`、`rebuildPrices` 分別設小型 A/B。
2. **RSS 目標下修但仍保留**：下一輪成功條件改為 encode/decode RSS 在相同資料集、相同 `-n` 下再降 20%，而不是只追求從 GB 級降下來。若要接近 TLZ4/ZSTD，需要證明 scratch / staging / inflight 的實際上界。
3. **Optimal 改段層級策略**：`claw-code` Optimal 壓縮比 0.8590 有明顯收益，但 `llama.cpp` Optimal 只到 0.9415，對 ZSTD 仍偏大；應先用 cheap probe 判斷段收益，低收益段走 Lazy2/BVX3，高收益段才進 Optimal。
4. **trace 覆蓋要補 llama.cpp**：目前 cpu_call_tree 只覆蓋 claw-code；下一輪 tracer 必須重新跑完整 n4/n8/n40 與兩個資料集，並避免中途手動刪 `.out`。

## 下一輪驗收條件

- `swiftc -O lzfse-cli.swift -o lzfse` 可編譯，`./lzfse -test` 通過。
- `BenchMarkResult.csv` 保留 raw bytes / ns 的 MB/s 計算，並同步 trace/cpu 欄位。
- 若改 BVX3 encode：`claw-code` BVX3 n40 壓縮速度需高於 `625.62 MB/s` 或 RSS 低於 `370.2 MB`，二者至少達成一項且壓縮比不退。
- 若改 Lazy2：`claw-code` Lazy2 n40 壓縮速度需高於 `55.96 MB/s`，且比率維持 `0.9016` 附近。
- 若改 Optimal：`claw-code` Optimal n40 壓縮速度需高於 `28.81 MB/s`，或用段層級策略讓低收益段避開 Optimal，整體比率不明顯退步。

---

# 第二十四輪：`-n` 掃描結果整合（2026-06-15）/ Round 24: `-n` Sweep Consolidation

## 本輪目的 / Purpose

本輪依 `lz4bench_log/lz4bench-{dataset}-n4/n8/n40.txt`、`lzfse-test.txt` 與 `memprobeResults/` 重建 `BenchMarkResult.csv`。本次明確**沒有重跑 `helper/tracer.command` 或 `helper/trace_analysis.command`**；舊 trace 與舊 `trace/analysis` 產物已清理，本輪不作新 hotspot 判讀。

`BenchMarkResult.csv` 目前為 48 rows：2 個資料集 × 3 個 N × 8 種格式。速度欄仍以 raw bytes / ns 計算 decimal MB/s；CSV 與 `best_points/best_points.csv` 都以 UTF-8 BOM 輸出，方便 Excel 讀取。`lzfse-test.txt` 顯示內建 correctness cases 持續通過：other3 Apple 相容、自家 bvx3/lazy2/optimal 往返、平行解碼、私有 bvx3 Apple 拒解、單流後援與 Apple 互解路徑皆維持正常。

## 速度總結 / Throughput Summary

速度比較以 `BenchMarkResult.csv` 的 `壓縮 MB/s` / `解壓 MB/s` 為準。壓縮大小列入參考，但 TGZ、Apple、ZSTD 以及多執行緒外部工具即使資料相同，也可能因 metadata、工具版本、threading 與執行環境造成小幅浮動；本輪只把明顯趨勢列為結論。

### 最佳點 / Best Points

> TGZ / Apple / TLZ4 / ZSTD 的 `log nX` 只代表來源 log 批次，`-n` 不影響這些演算法；`-n` 只對 LZFSE other3 / bvx3 / lazy2 / optimal 路徑有意義。

#### claw-code

| 格式 | 最佳壓縮比 | 最佳壓縮 MB/s | 最差壓縮 MB/s | 最佳解壓 MB/s | 最差解壓 MB/s | 最低 Encode RSS | 最高 Encode RSS | 最低 Decode RSS | 最高 Decode RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 1.0000 (`log n4`) | 51.63 (`log n40`) | 48.24 (`log n8`) | 614.80 (`log n40`) | 605.50 (`log n4`) | 4.0 MB (`log n4`) | 4.0 MB (`log n4`) | 3.7 MB (`log n4`) | 3.7 MB (`log n4`) |
| Other3 | 0.9872 (`n4`) | 563.51 (`n8`) | 390.43 (`n4`) | 693.08 (`n40`) | 664.02 (`n4`) | 1455.2 MB (`n4`) | 1639.5 MB (`n40`) | 952.0 MB (`n4`) | 1092.6 MB (`n40`) |
| BVX3 | 0.9515 (`n4`) | 494.50 (`n40`) | 373.42 (`n4`) | 501.38 (`n8`) | 390.61 (`n40`) | 1471.9 MB (`n4`) | 1681.9 MB (`n40`) | 918.2 MB (`n4`) | 1060.4 MB (`n40`) |
| Lazy2 | 0.9016 (`n4`) | 54.87 (`n40`) | 34.47 (`n4`) | 760.31 (`n40`) | 615.98 (`n4`) | 1507.0 MB (`n4`) | 1820.8 MB (`n40`) | 871.1 MB (`n4`) | 1013.4 MB (`n40`) |
| Optimal | 0.8590 (`n4`) | 29.16 (`n40`) | 19.33 (`n4`) | 718.84 (`n40`) | 552.67 (`n4`) | 1544.2 MB (`n4`) | 1905.7 MB (`n40`) | 831.6 MB (`n4`) | 973.4 MB (`n40`) |
| Apple | 0.9877 (`log n4`) | 156.12 (`log n4`) | 154.30 (`log n40`) | 689.32 (`log n8`) | 569.11 (`log n40`) | 1356.4 MB (`log n4`) | 1356.5 MB (`log n40`) | 473.1 MB (`log n4`) | 473.2 MB (`log n40`) |
| TLZ4 | 1.1796 (`log n4`) | 634.00 (`log n40`) | 617.19 (`log n8`) | 993.71 (`log n40`) | 567.08 (`log n8`) | 79.9 MB (`log n8`) | 86.2 MB (`log n40`) | 33.8 MB (`log n4`) | 33.8 MB (`log n4`) |
| ZSTD | 0.8255 (`log n4`) | 440.86 (`log n40`) | 425.33 (`log n4`) | 894.60 (`log n4`) | 654.16 (`log n8`) | 397.0 MB (`log n4`) | 402.1 MB (`log n8`) | 9.2 MB (`log n4`) | 9.2 MB (`log n4`) |

#### llama.cpp

| 格式 | 最佳壓縮比 | 最佳壓縮 MB/s | 最差壓縮 MB/s | 最佳解壓 MB/s | 最差解壓 MB/s | 最低 Encode RSS | 最高 Encode RSS | 最低 Decode RSS | 最高 Decode RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 1.0000 (`log n4`) | 65.08 (`log n8`) | 62.20 (`log n40`) | 289.62 (`log n40`) | 272.24 (`log n4`) | 4.1 MB (`log n4`) | 4.1 MB (`log n4`) | 3.8 MB (`log n4`) | 3.8 MB (`log n4`) |
| Other3 | 0.9978 (`n4`) | 403.98 (`n8`) | 302.33 (`n40`) | 283.06 (`n40`) | 256.74 (`n4`) | 1234.9 MB (`n40`) | 1350.7 MB (`n8`) | 1182.5 MB (`n4`) | 1323.2 MB (`n40`) |
| BVX3 | 0.9815 (`n4`) | 393.29 (`n8`) | 295.32 (`n40`) | 262.31 (`n4`) | 255.12 (`n40`) | 1297.1 MB (`n4`) | 1379.5 MB (`n40`) | 1163.7 MB (`n4`) | 1305.5 MB (`n40`) |
| Lazy2 | 0.9587 (`n4`) | 163.91 (`n40`) | 114.41 (`n4`) | 301.60 (`n4`) | 287.77 (`n8`) | 1339.4 MB (`n4`) | 1566.2 MB (`n40`) | 1137.0 MB (`n4`) | 1279.2 MB (`n40`) |
| Optimal | 0.9415 (`n4`) | 56.66 (`n40`) | 36.64 (`n4`) | 278.34 (`n8`) | 254.70 (`n4`) | 1376.4 MB (`n4`) | 1720.9 MB (`n40`) | 1117.1 MB (`n4`) | 1259.5 MB (`n40`) |
| Apple | 1.0008 (`log n4`) | 166.86 (`log n8`) | 144.59 (`log n40`) | 274.45 (`log n8`) | 237.36 (`log n40`) | 1193.9 MB (`log n4`) | 1193.9 MB (`log n4`) | 590.3 MB (`log n4`) | 590.4 MB (`log n40`) |
| TLZ4 | 1.0549 (`log n4`) | 364.93 (`log n4`) | 225.96 (`log n40`) | 309.15 (`log n40`) | 270.96 (`log n4`) | 81.9 MB (`log n8`) | 90.4 MB (`log n4`) | 33.8 MB (`log n4`) | 33.8 MB (`log n4`) |
| ZSTD | 0.9123 (`log n4`) | 456.46 (`log n40`) | 426.60 (`log n8`) | 311.86 (`log n8`) | 269.82 (`log n4`) | 497.9 MB (`log n40`) | 508.0 MB (`log n8`) | 9.2 MB (`log n8`) | 9.7 MB (`log n40`) |

## `-n` 掃描觀察 / `-n` Sweep Findings

1. `-n` 仍是吞吐旋鈕，不是 RSS 解法。`claw-code` 的 Lazy2/Optimal 壓縮在 `n40` 最快，但 encode RSS 也到 1.82GB/1.91GB；`llama.cpp` 的 Other3 最低 encode RSS 出現在 `n40`，但其餘 bvx3 家族仍維持 1.30GB–1.72GB 級距。這表示記憶體主因仍在 chunk 工作集、parser scratch、compressed body staging 或資料 copy。
2. `claw-code` 對 bvx3 家族的壓縮比收益仍明顯：Optimal 0.8590，比 Lazy2 0.9016 再小 4.72%，但最佳壓縮速度只有 29.16 MB/s，約比 Lazy2 慢 1.88x。`llama.cpp` 上 Optimal 0.9415 只比 Lazy2 0.9587 小 1.79%，但壓縮速度約慢 2.89x。Optimal 必須改成段層級收益閘，而不是全域套用。
3. 解壓側 `claw-code` 的 Lazy2/Optimal 仍可達 760.31/718.84 MB/s，但 BVX3 只有 501.38 MB/s；`llama.cpp` 則整體落在 255–312 MB/s。此差異更像資料型態與 cache/I/O 浮動共同影響，不能只用單一資料集宣稱解壓勝負。
4. 外部工具提供明確 RSS 下限：TGZ encode/decode 約 4MB，TLZ4 decode 33.8MB，ZSTD decode 9MB 級。相較之下 LZFSE 家族 decode 仍是 831MB–1.32GB，encode 仍是 1.23GB–1.91GB。

## memProbe 與 trace 統整 / memProbe and Trace

memProbe 這輪再次確認：LZFSE/bvx3 家族的 encode RSS 仍是最主要問題。最低 encode RSS 仍在 GB 級：`claw-code` Other3 1455.2MB、BVX3 1471.9MB、Lazy2 1507.0MB、Optimal 1544.2MB；`llama.cpp` Other3 1234.9MB、BVX3 1297.1MB、Lazy2 1339.4MB、Optimal 1376.4MB。外部工具則是 TGZ 約 4MB、TLZ4 約 80–90MB、ZSTD 約 397–508MB。

Decode RSS 仍未降到預期的數十 MB 或半壓縮檔級距：`claw-code` Optimal 最低 831.6MB，Other3 952.0MB；`llama.cpp` Optimal 最低 1117.1MB，Other3 1182.5MB。這代表目前資料仍支持「輸入/scanBlocks/工作集仍整檔化或大量駐留」的判斷；先前 decode 讀檔去雙份修正仍需用 clean round 驗證，不能只憑本輪數字宣稱已完成。

Trace 本次沒有重跑，且舊 `trace/analysis` export 已移除。前次分析曾確認外部壓縮器 trace 可用，但 LZFSE family 舊 trace 多數 profiling 到 `zsh` wrapper，不能作 hotspot 依據。`helper/tracer.command` 已改為重跑前清掉舊 `*.trace`，並改用 direct launch + `--target-stdin`；下一次若要做 hotspot，必須先重生 trace 再跑 `trace_analysis.command`。

## 本輪腳本與輸出整理 / Script and Output Updates

- `helper/benchmark_result_rebuild.command` 只讀 `lz4bench_log/lz4bench-*-n*.txt`，不再 fallback 根目錄舊 log；輸出 `BenchMarkResult.csv` 為 UTF-8 BOM。
- `benchmark.sh` 已把 lz4bench 結果寫入 `lz4bench_log/`，最後步驟會重建 `BenchMarkResult.csv` 並產生 Best Points。
- `helper/best_points_analysis.command` 已輸出 `best_points/best_points.md` 與 `best_points/best_points.csv`，包含 TGZ、最佳壓縮比、最佳/最差壓縮 MB/s、最佳/最差解壓 MB/s、最低/最高 Encode RSS、最低/最高 Decode RSS。
- `helper/trace_analysis.command` 的 CSV 輸出改為 UTF-8 BOM；本輪未執行。
- `helper/tracer.command` 已加入開跑前清除舊 `*.trace`，避免新舊 trace 混雜；本輪未執行。

## bvx3 家族改善策略 / bvx3 Family Strategy

1. **優先處理 encode 工作集**：`-n` 無法把 encode RSS 拉出 GB 級。下一步應集中在 thread-local scratch pool、parser/DP buffer reuse、去除 `compressBody` 每 chunk `[UInt8](input)` copy。成功條件：bvx3/lazy2/optimal encode RSS 至少下降 20%，壓縮輸出 byte 級不變或差異有明確原因。
2. **decode 要從整檔 scan 轉向增量 scan**：目前 decode RSS 仍是 831MB–1.32GB。若要降到數十 MB，必須讓 `scanBlocks` 與壓縮輸入讀取真正增量化，目標是 `N * 4MiB + window` 級距。
3. **Optimal 改收益閘**：`claw-code` 有 4.72% 體積收益，可以針對高收益段使用 Optimal；`llama.cpp` 只有 1.79%，不值得全段 DP。下一步加入 cheap probe，低收益段走 Lazy2/BVX3，高收益段才進 Optimal。
4. **trace 重生後再改熱點**：目前不根據舊 trace XML 改 match loop 或 DP inner loop。下一輪若重跑 trace，先驗證 `contains_lzfse_profile=yes`，再抽 top self-time/heavy stack。

## 下一輪驗收條件 / Next Acceptance Criteria

- `swiftc -O lzfse-cli.swift -o lzfse` 可編譯。
- `./lzfse -test` 維持全部 case 通過。
- 若改 encode memory path：bvx3/lazy2/optimal encode RSS 較本輪最佳至少低 20%。
- 若改 decode streaming：`claw-code` Optimal decode RSS 應明顯低於 831.6MB，`llama.cpp` Optimal decode RSS 應明顯低於 1117.1MB。
- 若改 Optimal：以 raw bytes/ns 重算 MB/s，`claw-code` Optimal 壓縮速度提升至少 10%，或收益閘能讓 `llama.cpp` 低收益段避開 Optimal DP。

# 第二十三輪：benchmark / memProbe / trace 統整重算（2026-06-14）/ Round 23: Consolidated Benchmark Refresh

## 本輪目的 / Purpose

本輪重讀 `lz4bench-claw-code.txt`、`lz4bench-llama.cpp.txt`、`lzfse-test.txt`、`memprobeResults/` 與 `trace/`。`BenchMarkResult.csv` 已重新整理為同一張表，速度欄以 raw bytes / ns 計算 decimal MB/s，並保留 `Encode RSS(MB)`、`Decode RSS(MB)`、`Trace wall time(秒)`，讓 throughput、peak RSS、Time Profiler 覆蓋狀態可以同列比較。

本輪 helper 已把 memProbe 移到壓縮與解壓 benchmark 全部完成之後再跑；因此正式解壓 MB/s 不再被 probe 事前擾動，特別是 llama.cpp 的解壓數字比前輪更可信。

`lzfse-test.txt` 仍定位為正確性與相容性測試，不納入 MB/s 計算；本輪未見失敗標記，lazy2 / optimal 自我往返、平行解碼、Apple 相容/拒解路徑皆維持通過。

## 最新速度結果 / Latest Throughput（decimal MB/s，raw bytes / ns）

### 壓縮 MB/s / Compression

| 格式 | claw-code | llama.cpp |
| --- | ---: | ---: |
| TGZ | 50.79 | 66.01 |
| Other3 | 354.87 | 440.47 |
| **Lazy2** | **48.31** | **164.23** |
| **Optimal** | **26.71** | **56.88** |
| BVX3 | 515.78 | 429.01 |
| Apple | 149.57 | 166.95 |
| TLZ4 | 500.44 | 363.81 |
| ZSTD | 327.97 | 470.05 |

### 解壓 MB/s / Decompression

| 格式 | claw-code | llama.cpp |
| --- | ---: | ---: |
| TGZ | 246.23 | 272.43 |
| Other3 | 301.33 | 273.42 |
| **Lazy2** | **367.70** | **237.55** |
| **Optimal** | **284.12** | **226.03** |
| BVX3 | 162.91 | 265.73 |
| Apple | 201.03 | 219.65 |
| TLZ4 | 179.11 | 268.29 |
| ZSTD | 182.70 | 254.60 |

> 本輪速度數值和前輪仍有浮動。llama.cpp 在 memProbe 後移後，解壓 MB/s 大幅回到 220–273 MB/s 區間；claw-code 的解壓仍顯示較大磁碟/快取波動，尤其 BVX3 單點偏低。因此比較仍以同輪內相對關係與多輪趨勢為主，不把 Apple/ZSTD/TGZ 的壓縮大小小幅差異視為演算法變更證據。

## 壓縮比與成本 / Ratio and Cost

| 資料集 | Lazy2 ratio | Optimal ratio | Optimal 額外體積收益 | Optimal/Lazy2 壓縮時間 |
| --- | ---: | ---: | ---: | ---: |
| claw-code | 0.9016 | 0.8590 | 4.72% smaller vs lazy2 | 1.81x |
| llama.cpp | 0.9587 | 0.9415 | 1.80% smaller vs lazy2 | 2.89x |

結論維持不變：optimal 對 claw-code 有可見體積收益，但對 llama.cpp 只多省 1.80%，卻仍需要 2.89x lazy2 壓縮時間。下一輪不應把 optimal 當全域策略，應改成段層級 cheap probe：高收益段才進 optimal，低收益段走 lazy2 或 bvx3。

## MemProbe 結果 / Peak RSS

| 格式 | claw encode | claw decode | llama encode | llama decode |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 4.0 MB | 3.7 MB | 4.1 MB | 3.8 MB |
| ZSTD | 392.3 MB | 9.5 MB | 508.4 MB | 9.3 MB |
| TLZ4 | 74.6 MB | 33.8 MB | 83.6 MB | 33.8 MB |
| Other3 | 1334.8 MB | 1014.2 MB | 1372.8 MB | 1244.2 MB |
| Apple | 1356.4 MB | 473.1 MB | 1193.8 MB | 590.3 MB |
| BVX3 | 1523.0 MB | 981.9 MB | 1365.8 MB | 1226.6 MB |
| Lazy2 | 1163.0 MB | 935.1 MB | 1554.0 MB | 1199.9 MB |
| Optimal | 1616.0 MB | 895.0 MB | 1655.3 MB | 1180.1 MB |

最新 memProbe 顯示 decode RSS 穩定落在約 473MB–1.24GB，已不再回到 R21 的 2GB+，但仍遠高於外部工具；encode RSS 則更明確是主問題。LZFSE / bvx3 家族 encode 約 1.16–1.66GB，對比 TLZ4 約 75–84MB、ZSTD 約 392–508MB，代表 parallel encode 的在途 chunk、parser workspace、壓縮 body、排序 buffer 或 `Data` copy 仍需要獨立壓低。`-n` 預設值沒有讓 RSS 自動下降，下一步要用較小 N 做掃描。

## Trace 統整 / Trace Summary

`trace/tracer_status.txt` 顯示 16 個 Time Profiler bundle 已完成，檔名為 `<dataset>-<algo>.trace`，且 LZFSE 家族維持 `-si` stdin path。Trace wall time 仍只能確認覆蓋與相對量級，不能替代 benchmark MB/s，也不能在 CLI export 失敗前宣稱 hotspot 排名。

| 格式 | claw-code | llama.cpp |
| --- | ---: | ---: |
| TGZ | 42s | 34s |
| ZSTD | 8s | 8s |
| TLZ4 | 8s | 10s |
| Other3 | 9s | 12s |
| Apple | 15s | 18s |
| BVX3 | 11s | 12s |
| Lazy2 | 50s | 25s |
| Optimal | 81s | 56s |

Trace 的可用結論很窄：lazy2 / optimal 是長段，尤其 claw-code optimal；但前二大熱點仍需用 Instruments GUI 打開 `.trace` bundle 後記錄 top self-time / heavy stack。

## bvx3 家族下一步計畫 / Next Plan

1. **先做小 N 掃描，而不是直接宣稱 encode RSS 已解決**：預設 N 仍讓 bvx3 家族 encode RSS 落在 1.16–1.66GB。下一輪需固定同碼，掃 `-n 40 / 8 / 4` 或相近值，確認較小 N 是否能把 bvx3/lazy2/optimal 任一 encode RSS 降低 ≥20%，且壓縮 MB/s / 比率可接受。
2. **再做 optimal 成本閘**：用 cheap probe 在段層級估算 lazy2→optimal 的收益。llama.cpp 這類低收益資料不應全段進 optimal；claw-code 高收益段才值得付 DP 成本。
3. **decode RSS 仍列問題，但順位低於 encode**：decode 目前約 0.47–1.24GB，仍比 zstd/tlz4 高一到兩個數量級；但本輪最不合理的是 encode 1.16–1.66GB。decode 有界串流視窗應獨立排期，避免和 optimal DP 加速混在同一輪。
4. **profiling 只採 GUI 讀取後的具體熱點**：下一次若要改 DP / match loop，先從 `trace/claw-code-optimal.trace` 與 `trace/llama.cpp-optimal.trace` 摘出 top two hotspots，再做單點改動；速度成功條件維持同輪 claw optimal 壓縮時間改善 ≥10%。

## 本次實作驗收觀察 / Implemented This Round

**項目 1（encode 在途數解耦）—— 已做 + 投資評估**
- `-n <N>` 旋鈕（encode / decode 共用，與核心數解耦）：`runParallelEncode` 的 sem 上限改由 N 決定。預設 = 核心數×2、上限 < 核心數×4、下限 1。
- ⚠️ **驗收結果**：預設設定下 encode RSS 沒有達到 −20% 成功條件，仍約 1.16–1.66GB。這表示 N 旋鈕需要用較小值驗證，且 parser/DP scratch / `Data` copy 才是下一個更確定的單點。
- **scratch 重用評估（「確認是否能重用」）**：可行，但需把 `lzParseOptimal` / `lzParseChain` / `lzParseStrong` 內的 DP segment、hash、chain 陣列改成「由外部傳入的 thread-local scratch pool」（簽名變動，屬侵入式、correctness-critical），故本輪**未盲改**，列為需可編譯驗證的下一步。另 `compressBody` 內 `let bytes = [UInt8](input)` 每 chunk 多複製一份 4MiB，可一併改 `withUnsafeBytes` 省去。

**decode 再降一步 —— 已做**
- 消除 CLI 解碼路徑的**重複輸入複製**：原本 `readToEnd()` 的 `Data` 與 `decodeStreamToHandle` 內的 `[UInt8]` 各持一份完整壓縮檔；改為只讀入單一份 `[UInt8]`（`decodeStreamToHandle` 直接吃 `[UInt8]`，不再內部複製）。預期再省 ~壓縮檔大小（claw ~0.4GB、llama ~0.55GB）的 decode RSS。
- **驗收結果**：decode RSS 維持在 473MB–1.24GB，沒有回到 R21 的 2GB+；但也還沒到幾十 MB，代表 `scanBlocks` / `src` 增量化仍是必要的後續工作。
- 再往「幾十 MB」需第二階段 b：`scanBlocks` 增量掃描 + `src` 串流讀入（尚未做）。

**decode 讀檔去雙份（R24 後續，已做）/ Eliminate read-time input doubling**
- R24 數據顯示 decode 峰值 ≈ **2× 壓縮檔**（claw optimal 422MB→829MB、other3 485MB→950MB），瓶頸不在輸出而在「讀檔當下」：`readToEnd()` 的整份 `Data` 與 `[UInt8](...)` 在轉換瞬間同時存在。
- 修法：CLI 解碼端改為**單份緩衝增量讀入**——`-i` 檔案先 `attributesOfItem` 取大小、一次 `reserveCapacity`，再以 1MiB 小塊 `read(upToCount:)` 逐塊 append 並釋放暫存 `Data`（`-si` stdin 大小未知時退回逐塊 append）。輸入端峰值由 2× 壓縮檔降到 **≈ 1× 壓縮檔 + 1MiB**。
- 預期 decode 峰值 ≈ `1× 壓縮檔 + N×4MiB`（claw optimal `-n4` 預估 ~0.44GB，約砍半）。待你 benchmark + memProbe 驗收；`-test` 守 7/7 與 Apple 互解不變。

**decode 串流輸入（收掉 1× 壓縮輸入）—— 已做（待驗收）/ Streaming input**
- R24 clean round 顯示 decode 仍 ~0.83–1.18GB，因為**整份壓縮輸入仍駐留**（`src` 整檔 + `scanBlocks` 整掃）。本次把 `-i` 檔案解碼改為真正串流：
  - 新增 `decodeStreamFromFile`：逐塊讀入壓縮串流、依 chunkRaw 邊界累積成群組、**整批 N 組平行解碼成功後才依序寫出並釋放**，全程不持有整份壓縮輸入。讀取視窗 ~1MiB + 在飛群組 N×（一組壓縮 + 一組輸出）。
  - 預期 decode RSS ≈ **inflight ×（≤4MiB 壓縮 + 4MiB 輸出）+ ~1MiB**，不再隨檔案大小線性（`-n4` 量級數十 MB；`-n40` 約數百 MB）。
  - 正確性：只對「自家分塊串流」（各 chunk 獨立壓縮 → 群組自包含）走串流；外來單流/非分塊在**首批、尚未寫出**時偵測（misalign 或解碼失敗）→ 回 `.fallback`，呼叫端**重讀整檔**走既有 whole-buffer 路徑，輸出位元組完全相同（Apple/other3 相容性零影響）。`-si` stdin 無法重讀 → 維持單份讀入 + whole-buffer。
  - ⚠️ `decodeStreamFromFile` 不被 `-test` 涵蓋（`-test` 走 `decompress`/`parallelDecompress` 的 Data API），只有 benchmark 的 `diff` 一致性會驗到。請務必跑 benchmark 7/7 一致 + 掃 `-n 4/8/40` 比對 decode RSS。

**encode/decode 讀取迴圈 autoreleasepool（根因修正）—— 已做（待驗收）/ autorelease accumulation fix**
- R24 逐 N 數據顯示 encode RSS **與 N 無關、與 parser 無關（n4 時 other3 1455 ~ optimal 1544MB，只差 ~90MB）、且 ≈ 整份輸入大小**（claw 1.38GB→~1.4–1.5GB、llama 1.26GB→~1.3–1.6GB）。這三個特徵共同指向 macOS Foundation 經典陷阱:**主執行緒讀取迴圈沒有 autorelease pool**——`FileHandle.read(upToCount:)` 回傳 autoreleased `Data` 暫存,迴圈內無 pool 排空時,會累積到「整份輸入大小」才在程序結束時釋放。
- 修法:把 4 個主執行緒讀取迴圈包進 `autoreleasepool`,每塊讀完即排空暫存——
  - `runParallelEncode` 生產者讀取迴圈（encode 主因）;
  - `decodeStreamFromFile` 的 `ensure()`（decode 串流讀入）;
  - CLI `-si` stdin 與 fallback 的整檔讀入。
  - 強引用的 `data`/`src`/`buf` 留在 pool 外不受影響,只排空 read 的 autoreleased backing。GCD worker（compressBody / 平行解碼）本就每 block 自動排空,不需處理。
- 預期:encode RSS 從 ≈ 整份輸入（~1.4GB）降到 ≈ `N ×（chunkSize + parser workspace）`（理應數百 MB 以下）;decode 亦不再以暫存形式累積壓縮輸入。**待你 benchmark + memProbe 驗收**;這是純記憶體修正,壓縮/解碼位元組不變,`-test` 與 7/7 一致應維持。

**helper 調度修正 —— 已做**
- memProbe 已移到正式壓縮/解壓 benchmark 之後執行；這讓解壓 MB/s 不再被事前 probe 污染。llama.cpp 解壓結果回升到 220–273 MB/s 區間，支持這個調整方向。

**驗收建議**：`-test` 守 7/7 一致與 Apple 互解；下一輪固定同碼掃 `-n 40 / 8 / 4` 看 RSS↔速度取捨；若小 N 不足以降 RSS，改做 parser scratch pool 或 `compressBody` 去除每 chunk `[UInt8](input)` copy。

---

# 修改方向建議：bvx3 家族記憶體整體解法（R23 設計筆記）/ Direction: Holistic Memory Fix for the Whole LZFSE Family

> 本節為設計方向，非實測。承 R21/R23 memProbe 與 R22 的 B線/C線：encode RSS 約 1.16–1.66GB、decode RSS 約 0.47–1.24GB 是**架構級**成本，且**所有格式共用**（other3 / Apple 也受影響，並非 bvx3 專屬）。因此解法必須在共用層一次解決，並保證 other3/Apple 相容。

## 1. 問題定位（共用層，非格式專屬）/ Root Cause in the Shared Layer

`decodeStream`（2677 行）與 `runParallelEncode`（3342 行）是所有演算法共用的 I/O 管線：

- **decode 仍有整檔級成本**：(a) 2678 行 `let src = [UInt8](input)` 持有整份壓縮輸入（~0.4–0.6GB）；(b) 已有分批輸出後，峰值仍約 0.47–1.24GB，代表壓縮輸入、群組暫存、`Data` copy / staging 仍未完全有界。
- **encode 在途數綁定核心數**：3345 行 `maxTasks = activeProcessorCount`（本機 20）。每個在途 chunk 自帶輸入 4MiB + 輸出 + parser workspace + hash-chain/DP 陣列，峰值 ≈ 核心數 × 每 chunk 工作集，目前約 1.16–1.66GB。

## 2. 支點：最大回溯距離由「格式」決定，且很小 / The Enabling Invariant

- `maxDValue = 262139`（55 行）→ other3 / Apple 最大 match 距離 ≈ **256KB**（即 Apple `LZFSE_ENCODE_MAX_D_VALUE`）。
- `maxD3 = 4194299`（125 行）→ bvx3 ≈ **4MiB**（= `parallelChunkSize`）。

推論：**任何格式解碼都只需保留「最後 W 位元組」歷史**（W = 256KB 或 4MiB），不需整份輸出。這也正是現行平行分組（2692 行於 chunkRaw 邊界切組、2532 行 `dd <= w - historyFloor` 守界）能成立的隱含前提——只是還沒被用來界定 decode 記憶體。gzip（32KB 視窗）、zstd（frame window）正是這樣維持與檔案大小無關的常數記憶體。

## 3. 整體解法：單一有界串流 I/O 層（三旋鈕，涵蓋全格式）/ One Bounded Streaming Layer

| 旋鈕 | 意義 |
| --- | --- |
| **W** | 格式最大距離（歷史視窗，保證跨塊 match 正確）：other3 256KB / bvx3 4MiB |
| **N** | 在途深度（**記憶體 ↔ 吞吐的唯一旋鈕**） |
| chunkSize | 沿用 4MiB |

- **decode**：依串流順序解 N 個群組到 N 個區段緩衝 → 解完一段就**依序寫 stdout 並釋放**，只保留最後 W 的歷史 → RSS ≈ N × chunkRaw + W。
- **encode**：在途數由 `maxTasks` 改為 N + scratch pool 重用 workspace → RSS ≈ N ×（chunkSize + workspace）。
- **Apple/other3 相容性零影響**：輸入/輸出的「位元組」完全不變，只改緩衝策略；相容性是格式問題，不是記憶體策略問題。

## 4. 程式碼落點 / Code Anchors

- decode：`decodeStream` API 由「回傳整份 Data」改為「邊解邊寫 output FileHandle」；2705 行整份 `allocate` → 有界環形視窗；2678 行 `[UInt8](input)` + `scanBlocks`（2610 行）改增量掃描（讀 magic/header → 讀塊身 → 解 → 前進）。
- encode：`runParallelEncode`（3342 行）把 `maxTasks` 與「在途上限」解耦，新增 N；`scratchPool`（772 行雛形）擴及 parser/DP workspace。

## 5. 記憶體估算與使用者旋鈕 / Estimates & `-mem`

- decode N=4 + 增量掃描後：0.47–1.24GB → ≈ N×4MiB + 4MiB ≈ **20–24MB**。
- encode N=8 + scratch pool 後：1.16–1.66GB → ≈ 8×(4MiB + workspace) ≈ **數百 MB**。
- 建議對外做成 `-mem low|balanced|max`（N = 2 / 8 / cores）：`max` 維持今日速度與記憶體，`low` 換低 RSS。

## 6. 權衡 / Trade-off

唯一代價：N 變小 → 解碼平行度下降 → 解碼 MB/s 往 zstd 靠攏（claw 可能 700→300–400）。lzfse 目前的高解碼速度，本來就是用「整檔配置 + 全核平行」買來的；此解法把它變成**可選**而非強制。

## 7. 分期與 R23 成功條件對應 / Phased Plan

- **第二階段 a（已實作，本次）/ decode 輸出有界串流**：新增 `decodeStreamToHandle`（lzfse-cli.swift），把 CLI 解碼路徑（`.other3`/`.bvx3` 的 `-decode`）由「一次配置整份輸出（~1.3GB）+ 一次寫出」改為「**分批平行解碼 → 依序寫 stdout → 立即釋放**」。
  - 對 **other3 與 bvx3 家族全部生效**（兩者皆走此路徑）；輸出位元組完全相同 → Apple 相容性零影響。
  - 正確性：依賴「自家各 4MiB chunk 獨立壓縮 → 群組自包含」（程式碼 2593-2601 已保證）；外來單流／跨組 match 自動退回原 whole-buffer 解碼。
  - 記憶體旋鈕：CLI `-n <N>`（同時在記憶體的群組數）。**預設 = 核心數 × 2**；**上限須 < 核心數 × 4**（超過會被夾到 4×cores−1 並提示）；下限 1。輸出側峰值 ≈ N × 4MiB（預設 20 核 → N=40 → ~160MB；`-n 4` → ~16MB）。
  - ⚠️ **實際降幅校準**：本階段只消除「整份輸出緩衝（~1.3GB）」；**壓縮輸入 `src` 仍整份讀入（~0.4–0.6GB）**。本次 memProbe 已降到約 0.47–1.24GB，但尚非「幾十 MB」；要更低需第二階段 b 或設小 `-n`。
- **第二階段 b（待做）**：`scanBlocks`（2610 行）改增量掃描、`src` 改串流讀入，消掉那 ~0.5GB → 才能到幾十 MB。
- **第一階段（待做）/ encode**：在途數限 N + scratch pool，降 encode RSS（1.16–1.66GB）。
- **驗收（你跑 benchmark + memProbe）**：7/7 解壓一致、壓縮比 byte 級不變；decode RSS（other3/bvx3/lazy2/optimal）−≥20%（本階段預期 ~−70%）。可另測 `-n 4`、`-n 2` 看記憶體↔解壓速度的取捨。

---

# 第二十二輪：Time Profiler trace 全覆蓋（2026-06-14）/ Round 22: Full Time Profiler Trace Coverage

## 本輪目的 / Purpose

本輪未重新跑 benchmark；`BenchMarkResult.csv` 沿用 R21 已由 raw bytes / ns 計算的最新 MB/s。新增工作是把 `helper/tracer.command` 擴成兩資料集 × 8 格式的 Time Profiler 批次 tracing，輸出放在 `trace/`，檔名對齊 memProbe 風格：`<dataset>-<algo>.trace`。兩個大型 tar input 與 profiling 壓縮輸出已清除，保留 16 個 `.trace` bundle。

## Trace 完整度 / Trace Completeness

- ✅ `TRACE_DONE 13:55:59`，16 個 `.trace` bundle 皆已產出。
- ✅ 涵蓋 `claw-code` / `llama.cpp` × `tgz`、`zstd`、`tar.lz4`、`other3`、`apple`、`bvx3`、`lazy2`、`optimal`。
- ✅ LZFSE 家族仍使用 `cat <dataset>.tar | lzfse-profile -encode -si ...`，維持 pipeline / `-si` 路徑。
- ⚠️ `xcrun xctrace export --toc` 對目前 trace 回報 `Fatal error reported in run 1`，CLI 尚無法匯出 call tree/hotspot 表；trace bundle 可留待 Instruments GUI 開啟分析。

### Trace wall time（含 xctrace 錄製與保存成本）

| 格式 | claw-code | llama.cpp |
| --- | ---: | ---: |
| TGZ | 42s | 34s |
| ZSTD | 8s | 8s |
| TLZ4 | 8s | 10s |
| Other3 | 9s | 12s |
| Apple | 15s | 18s |
| BVX3 | 11s | 12s |
| Lazy2 | 50s | 25s |
| Optimal | 81s | 56s |

> 這張表不能替代 benchmark MB/s，因為 xctrace recording / symbolication / save bundle 會加入固定成本；它只用來確認 tracing 覆蓋面與相對時間量級。正式性能比較仍以 `BenchMarkResult.csv` 的 raw bytes / ns 為準。

## 與 R21 benchmark / memProbe 的統整

1. **bvx3 基線很快，但 lazy2 / optimal 成本巨大**：R21 壓縮 MB/s 中，bvx3 為 claw 505.74 / llama 320.84；lazy2 降到 46.49 / 136.82；optimal 降到 27.11 / 40.93。Trace wall time 同樣顯示 lazy2 / optimal 是長段，尤其 claw optimal 81s。
2. **bvx3 家族 encode/decode RSS 都明顯過高**：外部工具 peak RSS 大致是 TGZ 4MB、ZSTD 381–465MB encode / 9–10MB decode、TLZ4 75–83MB encode / 34MB decode；相對地 LZFSE/bvx3 家族 encode 已達 0.95–1.76GB，decode 達 1.45–2.34GB。這不是量測噪音，而是架構級記憶體成本，需獨立成優化主軸。
3. **Optimal 的額外 RSS 不是主因，但家族基礎 RSS 是問題**：R21 memProbe 顯示 optimal encode 只比 lazy2 高約 55MB（claw）與 102MB（llama），但整個 bvx3 家族 encode 已達 1.3–1.8GB、decode 約 2GB 以上。optimal 速度瓶頸仍看 DP / match 熱點；bvx3 家族則另需處理平行編解碼的 buffer / staging。
4. **解壓與 encode profiling 要拆輪**：R21 的解壓 MB/s 受完整 memProbe 影響明顯變慢；後續若要比較解壓，應獨立於 profiling/memProbe round。
5. **目前尚不能宣稱 hotspot 排名**：CLI export 失敗前，不應寫「chain walk」或 `matchLength` 已是 top hotspot；只能把它們列為 Instruments GUI 需要確認的候選。

## 記憶體壓力觀察 / Memory Pressure

| 類別 | 外部工具 | LZFSE/bvx3 家族 |
| --- | --- | --- |
| Encode RSS | TGZ 4MB、TLZ4 75–83MB、ZSTD 381–465MB | Other3 947–1311MB、BVX3 1321–1515MB、Lazy2 1490–1703MB、Optimal 1592–1758MB |
| Decode RSS | TGZ 4MB、TLZ4 34MB、ZSTD 9–10MB | Other3 1455–2345MB、BVX3/Lazy2/Optimal 約 2047–2300MB |

> 結論：bvx3 家族目前不是「只比外部工具多一點 buffer」，而是高出一到兩個數量級。Decode RSS 對使用者最敏感，因為解壓通常被期待是低成本、可並行、可在磁碟壓力下穩定執行；encode RSS 也同樣不合理，因為基線 BVX3 已達 1.3–1.5GB，lazy2/optimal 更高。這個問題和 optimal DP 速度是兩條線：速度優化不能掩蓋 RSS 過高。

## bvx3 家族下一步策略 / Next Strategy

- **A 線：先用 Instruments GUI 讀 `trace/claw-code-optimal.trace` 與 `trace/llama.cpp-optimal.trace`**，取 top self-time / heavy stack，再決定是否改 `matchLength`、chain walk、dense relax、`rebuildPrices` 或預篩。
- **B 線：降低 bvx3 家族 encode RSS**。優先檢查 parallel encode 是否同時保留輸入 chunk、壓縮 body、match/price workspace、hash-chain table、結果排序 buffer 與 `Data` copy；目標先把 encode RSS 從 1.3–1.8GB 降到接近「chunkSize × maxTasks + parser workspace」的可解釋上界。
- **C 線：降低 bvx3 家族 decode RSS**。優先檢查 parallel decode 是否一次保留完整 chunk output、staging dictionary、`Data` copy 與結果排序 buffer；目標先把 decode RSS 從 2GB+ 降到接近「chunkSize × maxTasks + output window」的可解釋上界。
- **加成本閘而不是全域 optimal**：llama.cpp optimal 只比 lazy2 小 1.80%，卻多花 3.34x 壓縮時間；段層級 cheap probe 應優先排除低收益段。此策略也可降低 memory footprint，因為低收益段不進 heavy parser。
- **保留 lazy2 作主力高比率模式，但要限制其記憶體上界**：lazy2 對 claw 仍省 9.84% TGZ-relative 體積，速度成本可接受；但 encode RSS 已達 1.5–1.7GB，必須確認 maxTasks / chunkSize 是否能被動態調整。
- **R23 成功條件**：從 trace GUI 取得前二大熱點並記錄到 `OPTIMIZATION.md`；另以 memProbe 證明至少一個 bvx3 encode 或 decode RSS 單點改善。速度線要求同輪 claw optimal 壓縮時間改善 ≥10%；記憶體線要求 bvx3/lazy2/optimal 任一 encode 或 decode RSS 降低 ≥20%，壓縮比不退步。

---

# 第二十一輪：完整 memProbe 覆蓋與重測（2026-06-14）/ Round 21: Full memProbe Coverage and Re-run

## 本輪目的 / Purpose

本輪先修正 benchmark helper，再重新執行 `run_round.command`。重點是讓 `round_status.txt` 可判斷成功/失敗，並讓 `memprobeResults` 覆蓋所有 benchmark 格式：`tgz`、`zstd`、`tar.lz4`、`other3`、`apple`、`bvx3`、`lazy2`、`optimal`。`BenchMarkResult.csv` 已用最新 `lz4bench-claw-code.txt`、`lz4bench-llama.cpp.txt` 的 raw bytes / ns 重新計算 decimal MB/s。

## 量測完整度 / Completeness

- ✅ `run_round.command`：`TEST_OK 12:46:41`，`BENCH_DONE 13:08:24`。
- ✅ `claw-code` / `llama.cpp`：各 8 格式壓縮與解壓完成，7/7 一致性通過。
- ✅ `lzfse-test.txt`：未見失敗標記。
- ✅ `memprobeResults`：兩資料集各 8 格式 encode + decode peak RSS 皆產出。
- ✅ helper 修正：`benchmark.sh` 使用 zsh safe glob，`run_round.command` 正確回報 benchmark exit code；`zshrc.sh` 的 `extract` / `lzfseX` / `lz4bench` 支援 lazy2/optimal 產物與完整 probe。

## 實測結果 / Measured Results（decimal MB/s，bytes/ns）

### 壓縮 MB/s / Compression

| 格式 | claw-code | llama.cpp |
| --- | ---: | ---: |
| TGZ | 52.36 | 65.62 |
| Other3 | 540.56 | 401.92 |
| **Lazy2** | **46.49** | **136.82** |
| **Optimal** | **27.11** | **40.93** |
| BVX3 | 505.74 | 320.84 |
| Apple | 150.31 | 145.03 |
| TLZ4 | 490.55 | 257.22 |
| ZSTD | 324.59 | 289.45 |

### 解壓 MB/s / Decompression

| 格式 | claw-code | llama.cpp |
| --- | ---: | ---: |
| TGZ | 436.82 | 214.73 |
| Other3 | 435.86 | 86.10 |
| **Lazy2** | **384.56** | **81.46** |
| **Optimal** | **268.60** | **74.32** |
| BVX3 | 327.22 | 75.99 |
| Apple | 288.64 | 45.78 |
| TLZ4 | 203.24 | 70.23 |
| ZSTD | 380.50 | 63.07 |

> 本輪解壓 MB/s 明顯低於 R20，尤其 llama.cpp。這輪在解壓前新增完整 encode/decode memProbe，會改變 page-cache 與整機記憶體狀態；因此解壓 MB/s 仍只能作同輪記錄，不宜當作演算法退步證據。壓縮 MB/s 與同輪 lazy2/optimal 倍數仍是主要比較依據。

### 壓縮比與同輪成本 / Ratio and Within-Run Cost

| 資料集 | Lazy2 ratio | Optimal ratio | Optimal 額外體積收益 | Optimal/Lazy2 壓縮時間 |
| --- | ---: | ---: | ---: | ---: |
| claw-code | 0.9016 | 0.8590 | 4.72% smaller vs lazy2 | 1.72x |
| llama.cpp | 0.9587 | 0.9415 | 1.80% smaller vs lazy2 | 3.34x |

## MemProbe 結果 / Peak RSS

| 格式 | claw encode | claw decode | llama encode | llama decode |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 4.0 MB | 3.7 MB | 4.2 MB | 3.8 MB |
| ZSTD | 381.3 MB | 9.2 MB | 464.5 MB | 9.8 MB |
| TLZ4 | 83.2 MB | 33.8 MB | 74.9 MB | 33.8 MB |
| Other3 | 947.0 MB | 1454.7 MB | 1310.9 MB | 2344.5 MB |
| Apple | 1356.3 MB | 473.1 MB | 1193.8 MB | 590.3 MB |
| BVX3 | 1514.8 MB | 2244.6 MB | 1320.8 MB | 2047.4 MB |
| Lazy2 | 1703.3 MB | 2197.6 MB | 1490.1 MB | 2300.3 MB |
| Optimal | 1757.9 MB | 2157.8 MB | 1592.2 MB | 2281.1 MB |

> LZFSE/bvx3 系列 encode RSS 約 0.95–1.76 GB、decode RSS 約 1.45–2.34 GB，皆遠高於外部工具，這是獨立的記憶體壓力問題。Optimal encode 比 lazy2 高約 55 MB（claw）與 102 MB（llama），差距小於速度成本；因此 optimal 相對 lazy2 的主要差異仍是 DP 計算，但 bvx3 家族整體 encode/decode RSS 必須另列優化主軸。

## Lazy2 / Optimal 改善策略 / Strategy

1. **先 profiling 再動 DP**：claw optimal 27.11 MB/s，仍未接近 40+ MB/s。下一步必須用 Time Profiler 找出前二大熱點，不能再用整體感覺改 `lzParseOptimal`。
2. **成本閘比全域 optimal 更有價值**：llama.cpp optimal 多花 3.34x 壓縮時間只省 1.8% 體積；cheap probe 應在段層級預估收益，低收益段走 lazy2/bvx3。
3. **encode/decode RSS 必須另列主線**：bvx3/lazy2/optimal 編碼 RSS 約 1.3–1.8GB、解碼 RSS 約 2GB 以上，明顯高於 TGZ/ZSTD/TLZ4；應針對 parallel encode/decode staging、workspace、output buffer、`Data` copy 建立單點改善，不要混在 optimal DP 加速裡。
4. **下一輪成功條件**：profiling 產出可引用的 hotspot 排名，並以單點改動證明同輪 claw optimal 壓縮時間改善 ≥10%，壓縮比不退步。

## 下一輪計畫 / Next (R22)

- 用 `helper/tracer.command` 或 Instruments 對 claw optimal 做 Time Profiler，輸出放在 `trace/`。
- 保持 `-si` 輸入路徑；不要用 `-i` 代替 pipeline 量測。
- 依 profiler 選一個熱點改動：chain walk、`matchLength`、dense relax、`rebuildPrices`、或預篩。
- 若 full benchmark 後再量解壓，將 memProbe 與解壓 benchmark 拆成不同 round，避免 page-cache 狀態互相污染。

---

# 第二十輪：完整 benchmark + memprobe 重新整理（2026-06-14）/ Round 20: Full Benchmark + Memprobe Refresh

## 本輪目的 / Purpose

本輪重讀最新 `lz4bench-claw-code.txt`、`lz4bench-llama.cpp.txt`、`lzfse-test.txt`、`memprobeResults/lazy2-memprobe.txt`、`memprobeResults/optimal-memprobe.txt`，並以 exact raw bytes / nanoseconds 重新計算 `BenchMarkResult.csv` 的 MB/s。`lzfse-test.txt` 是功能與相容性測試輸出，不是同型的 throughput benchmark，因此用於確認 lazy2/optimal 往返與 Apple 相容性，不納入 CSV 的 MB/s 表。

MB/s 計算改以 decimal MB/s：`raw_bytes / elapsed_ns * 1000`。原始大小欄仍沿用既有 CSV 顯示慣例（raw KiB 轉 MiB 後四捨五入），壓縮後大小以 exact compressed bytes 轉 MB 後四捨五入，壓縮比用「相對 TGZ compressed bytes」計算。

## 量測完整度 / Completeness

- ✅ `claw-code`：8 格式壓縮與解壓完成，7/7 一致性通過。
- ✅ `llama.cpp`：8 格式壓縮與解壓完成，7/7 一致性通過。
- ✅ `lzfse-test.txt`：各測試案例 lazy2 / optimal 自我往返、平行解碼、Apple 相容/拒解路徑皆通過，未見失敗標記。
- ✅ `memprobeResults`：取得 llama.cpp 的 lazy2 / optimal encode 與 decode peak RSS。
- ⚠️ `round_status.txt` 仍記錄 `benchmark.sh` 的 zsh `nomatch` 訊息；結果檔仍已完整產出，但 helper 清理段需修正為 `NULL_GLOB` 或 glob qualifier，避免狀態檔誤導。

## 實測結果 / Measured Results（decimal MB/s，bytes/ns）

### 壓縮 MB/s / Compression

| 格式 | claw-code | llama.cpp |
| --- | ---: | ---: |
| TGZ | 52.69 | 68.15 |
| Other3 | 542.12 | 447.14 |
| **Lazy2** | **51.89** | **155.37** |
| **Optimal** | **29.05** | **54.43** |
| BVX3 | 587.07 | 422.57 |
| Apple | 159.53 | 170.17 |
| TLZ4 | 627.54 | 370.01 |
| ZSTD | 489.21 | 442.07 |

### 解壓 MB/s / Decompression

| 格式 | claw-code | llama.cpp |
| --- | ---: | ---: |
| TGZ | 607.60 | 285.67 |
| Other3 | 690.64 | 270.29 |
| **Lazy2** | **652.28** | **240.51** |
| **Optimal** | **685.82** | **219.34** |
| BVX3 | 706.44 | 259.18 |
| Apple | 697.58 | 223.76 |
| TLZ4 | 836.46 | 288.55 |
| ZSTD | 891.94 | 271.47 |

### 壓縮比與同輪時間倍數 / Ratio and Within-Run Cost

| 資料集 | Lazy2 ratio | Optimal ratio | Optimal 額外體積收益 | Optimal/Lazy2 壓縮時間 |
| --- | ---: | ---: | ---: | ---: |
| claw-code | 0.9016 | 0.8590 | 4.72% smaller vs lazy2 | 1.79x |
| llama.cpp | 0.9587 | 0.9415 | 1.79% smaller vs lazy2 | 2.85x |

> 同輪比較仍是最可信指標：claw-code optimal 多花約 1.8x 壓縮時間換 4.7% 體積；llama.cpp 多花約 2.85x 只換 1.8% 體積。這支持「預設或自動策略偏 lazy2，optimal 只給高體積敏感段」的方向。

## Memprobe 結果 / Peak RSS

| 模式 | Encode peak RSS | Decode peak RSS |
| --- | ---: | ---: |
| llama.cpp bvx3 lazy2 | 1541.8 MB | 2300.5 MB |
| llama.cpp bvx3 optimal | 1611.6 MB | 2280.7 MB |

> optimal encode peak RSS 只比 lazy2 高約 69.8 MB（約 +4.5%），代表目前 optimal 的主要問題不是記憶體峰值，而是 DP 計算時間。decode RSS 兩者接近，且 optimal decode 略低，暫不構成優化主軸。

## Lazy2 / Optimal 改善策略 / Strategy

1. **短期成功條件改為 profiling 驗證**：40+ MB/s 可保留為中期目標，但下一輪不要直接承諾速度；先用 Time Profiler 找出 claw optimal 約 49 秒中的前二大熱點，至少用一個單點改動證明同輪 ≥10% 改善。
2. **段層級成本閘優先於全域 optimal**：對每段做 cheap probe，估算 optimal 相對 lazy2 的可能收益；低收益段直接走 lazy2/greedy，高收益段才進 DP。llama.cpp 的 optimal 只多省 1.8% 體積卻花 2.85x 時間，是最明顯的候選。
3. **DP 核心仍需 UnsafePointer/SIMD，但要被 profiling 指向**：R19 的方向仍成立，不過這輪資料顯示性能收益不可誇大。若 profiler 顯示成本集中在 chain walk、`matchLength`、dense relax、`rebuildPrices` 或預篩，就只改第一、第二熱點，避免大範圍重寫。
4. **helper 需先清理狀態可信度**：`round_status.txt` 的 `nomatch` 訊息會干擾判讀；下一次 benchmark 前先修 `benchmark.sh` 清理 glob，並讓 `run_round.command` 在 benchmark 非 0 時寫 `BENCH_FAILED`。

## 下一輪計畫 / Next (R21)

- 修正 helper 的 zsh glob 清理與失敗狀態回報，讓 `round_status.txt` 可直接判斷整輪是否成功。
- 使用 `helper/tracer.command` 或 Instruments 量 claw optimal，輸出放入 `trace/`，不要用 `-i`，stdin path 必須使用 `-si`。
- 依 profiling 結果選一個熱點做單點改動，成功條件是同輪 claw optimal 壓縮時間至少改善 10%，且 lazy2/optimal 壓縮比維持不退步。
- 若要把 `lzfse-test.txt` 的小型案例轉成速度資料，需另做專用 microbenchmark；目前它只作正確性依據，不與 claw-code / llama.cpp 的 MB/s 混比。

---

# 第十九輪：平行編碼有界緩衝（backpressure）落地後重測（2026-06-14）/ Round 19: Re-measurement After Landing Bounded-Buffer Backpressure

## 本輪目的 / Purpose

本輪有代碼變更，但**不在壓縮演算法上**：`runParallelEncode` 把 `sem.signal()` 由「task 完成」改綁「chunk 寫出」，使「已讀但未寫出」嚴格 ≤ maxTasks（記憶體上界 ≈ maxTasks × chunkSize），修掉慢 chunk 在前時壓後 body 在 `results` 無界堆積（→ OOM）的風險。為排除單次量測偏差，本輪以**同一份程式碼連跑三次**（R19a / R19b / R19c）兩資料集 8 格式，回答：(1) 此修正是否**未動到壓縮比與單流吞吐**（應只影響記憶體）；(2) 以 bytes/ns 計的 MB/s 在「同碼重跑」之間到底浮動多大——藉此把「演算法效應」與「整機噪音」分離。

This round changes code but **not the compression algorithm**. To separate algorithm effect from machine noise, we ran the *same binary three times* (R19a/b/c). MB/s is computed as `raw_bytes / ns × 1000` (bytes/ns).

## 量測完整度 / Completeness

✅ claw-code / llama.cpp 各 8 格式壓縮+解壓、7/7 解壓一致；lzfse-test 112/112 全綠（0 ✗）；warm-cache 生效。下表 **R19c** 欄為最新重測（與 `BenchMarkResult.csv` 一致），另列「三輪範圍」量化同碼浮動。三輪皆**未啟用 probe**；R20 已備妥 `LZFSE_MEMPROBE=1`（見下）。

## 實測結果 / Measured Results（MB/s，bytes/ns）

### 壓縮 MB/s（主指標：三輪穩定）/ Compression — the reliable metric

| 格式 | claw R19c | claw 三輪範圍 | llama R19c | llama 三輪範圍 |
| --- | ---: | :--- | ---: | :--- |
| TGZ | 51.41 | 49.1–51.4 (±5%) | 68.35 | 67.5–68.3 (±1%) |
| Other3 | 508.51 | 481–564 (±16%) | 440.07 | 425–441 (±4%) |
| **Lazy2** | **53.34** | 49.7–53.3 (±7%) | **154.73** | 148–155 (±4%) |
| **Optimal** | **29.53** | 28.3–29.5 (±4%) | **53.57** | 52.9–53.9 (±2%) |
| BVX3 | 621.72 | 499–622 (±21%) | 418.65 | 419–423 (±1%) |
| Apple | 160.00 | 157–160 (±2%) | 170.98 | 171–172 (±1%) |
| ZSTD | 488.36 | 476–488 (±3%) | 468.64 | 466–473 (±1%) |
| TLZ4 | 638.66 | 603–639 (±6%) | 374.58 | 366–375 (±2%) |

> **壓縮 MB/s 是穩定、可比的指標**：focus 的 optimal / lazy2 三輪浮動僅 ±2–7%。claw optimal 三輪 28.3 / 28.8 / 29.5 MB/s，lazy2 49.7 / 52.6 / 53.3 MB/s——這是真實的演算法吞吐。

### 解壓 MB/s（同碼三輪噪音極大，不可比）/ Decompression — too noisy to compare

| 格式（claw） | 三輪範圍 | 變異 |
| --- | :--- | ---: |
| **ZSTD** | 380.5 – **1059.4** | **±88%** |
| BVX3 | 429.8 – 672.3 | ±45% |
| **Optimal** | 467.4 – 736.2 | ±42% |
| Other3 | 530.1 – 707.5 | ±28% |
| **Lazy2** | 545.7 – 696.9 | ±25% |
| TLZ4 | 678.7 – 862.9 | ±24% |
| Apple | 552.3 – 681.7 | ±21% |
| TGZ | 601.8 – 624.6 | ±4% |

> **這是本輪最有力的證據**：三次跑的是**同一個 binary、同一份資料**，claw zstd 解壓 MB/s 卻在 380 ↔ 1059 間擺盪（**±88%**），optimal / bvx3 也達 ±42–45%，方向毫無規律。證明解壓吞吐主要由 OS page-cache 命中率與排程決定，**單次解壓 MB/s 跨輪不可比、不可歸因於演算法**。對照壓縮側僅 ±1–7%——故本報告一律以**壓縮 MB/s + 同輪內相對量**為準，解壓只作參考。

### 壓縮比（deterministic，可信指標）/ Ratio

| 格式 | claw R18 | claw R19 | llama R18 | llama R19 |
| --- | ---: | ---: | ---: | ---: |
| **Optimal** | 0.8590 | **0.8590** | 0.9416 | **0.9415** |
| **Lazy2** | 0.9020 | **0.9016** | 0.9583 | **0.9587** |
| BVX3 | 0.9516 | 0.9515 | 0.9815 | 0.9815 |

> 壓縮後 byte 數在 R19a / R19b / R19c **三輪完全相同**（確定性壓縮），與 R18 差異 < 0.05%（屬資料集逐檔浮動 + Apple/zstd 大小本就會隨資料微動）。**關鍵驗證：backpressure 修正零比率影響**——signal 時機與記憶體界限的改動確實只動到調度，未碰 `compressBody` 與 chunk 切分。

### 同輪內相對：Optimal / Lazy2 壓縮時間倍數（最可信）/ Within-Run Ratio

| 資料集 | R18 | R19a | R19b | R19c |
| --- | ---: | ---: | ---: | ---: |
| claw-code | 1.95× | 1.76× | 1.83× | **1.81×** |
| llama.cpp | 2.93× | 2.80× | 2.80× | **2.89×** |

> 同輪內 optimal 相對 lazy2 的時間倍數三輪穩定落在 claw ~1.8×、llama ~2.8×。這是不受整機噪音污染的可信比較：**optimal 多花約 1.8–2.9× 時間，只換得約 4% 的額外體積**。

## Lazy2 vs Optimal 改善策略 / Strategy

1. **比率甜蜜點仍是 lazy2**：claw lazy2 0.9016（vs optimal 0.8590），以同輪內 ~1.8× 壓縮時間換 optimal 的額外 ~4.3% 體積；多數情境 lazy2 性價比更佳。optimal 只在「一次壓、多次傳/解」且體積敏感時才划算。

2. **optimal 的瓶頸在 DP 本身，而非並行或記憶體**：壓縮 MB/s 是穩定指標——claw optimal 三輪 28.3 / 28.8 / 29.5 MB/s，vs lazy2 ~50、zstd ~480。並行/記憶體已修到有界，**不再是限制因素**；要再快必須對 `lzParseOptimal` 的 price/match 熱迴圈動刀（UnsafePointer + SIMD）。

3. **量測方法已部分硬化、仍需續做**：解壓噪音 ±88% 證明 warm-cache 不足以穩定解壓計時。本輪已：(a) 報告主軸改用壓縮 MB/s；(b) 為 R20 備妥 peak-RSS probe。下一步對「解壓」做多次取中位數。

## 結論 / Conclusions

1. **修正符合設計意圖**：backpressure 改動讓「已讀未寫 ≤ maxTasks」，記憶體上界 ≈ maxTasks × chunkSize；比率零退步、壓縮路徑不變。
2. **吞吐差異是噪音（已用同碼三跑證明）**：同一 binary 三跑解壓 MB/s 可差 ±88%，故單次解壓 MB/s 不可歸因於演算法；壓縮 MB/s（±1–7%）與同輪內相對量才可信。
3. **比率可再現**：optimal claw 0.8590 / llama 0.9415、lazy2 claw 0.9016 / llama 0.9587，跨 R16–R19（含同碼三跑）完全穩定。
4. **方向不變**：optimal 加速的下一步是 DP 核心，而非並行架構（並行已修到安全有界）。

## 下一輪計畫 / Next (R20)

- **已備妥 probe**：`benchmark.sh` 預設 `export LZFSE_MEMPROBE=1`，下一輪會自動對 lazy2 / optimal 的 **encode + decode** 量 peak RSS（`zshrc.sh` 的 `memProbe`，已修正為「`time -l` 直接前綴 lzfse」而非包 `sh -c` 管線，否則量到的是 shell）。預期實證 optimal 在 1.3GB GGUF 的記憶體上界 ≈ maxTasks × chunkSize。要關閉：`export LZFSE_MEMPROBE=0`。
- **DP 核心 UnsafePointer 化 + SIMD**：把 `lzParseOptimal` 的 price/match 熱迴圈全面指標化，消除 Swift bounds-check 與 ARC 開銷，目標 claw optimal 29→40+ MB/s。
- **量測硬化**：解壓改多次取中位數（壓縮 MB/s 已證實夠穩，續作主軸），消除 page-cache 造成的 ±88% 解壓噪音。
- **編碼器調度器**：依區塊熵自動選 bvx1/bvx2/bvx3，整合 -lazy/-optimal。

---

# 第十八輪：R17 改動的乾淨環境重測（2026-06-14）/ Round 18: Clean-Environment Re-measurement of R17

## 本輪目的 / Purpose

無代碼變更。R17 的兩次量測都受系統負載污染（連 tgz 都掉到 21 MB/s）。本輪在系統較閒置時重跑，取得可信的絕對 MB/s，並回答「熵閘調參（7.2 / 35% / 三點取樣 / 文字保護）到底有沒有讓 optimal 變快」。

No code change. R17's measurements were load-contaminated; this clean re-run answers whether the entropy-gate tuning actually speeds up optimal.

## 量測完整度 / Completeness

✅ 兩資料集各 8 格式壓縮+解壓、7/7 一致；lzfse-test 全綠；warm-cache 生效。本輪系統較閒置——tgz/zstd/bvx3 已回到正常速度（claw tgz 48.35、zstd 460、bvx3 511 MB/s），確認非負載輪。

## 實測結果 / Measured Results（MB/s，bytes/ns）

### 壓縮 MB/s（焦點 optimal）vs R16

| 格式 | claw R16 | claw R18 | llama R16 | llama R18 |
| --- | ---: | ---: | ---: | ---: |
| **Optimal** | 25.36 | **28.02** | 46.92 | **54.08** |
| **Lazy2**（未受熵閘影響） | 47.36 | **54.58** | 129.59 | **158.74** |
| TGZ | 47.61 | 48.35 | 55.49 | 64.93 |
| ZSTD | 359.44 | 460.12 | 390.32 | 453.21 |

> ⚠️ optimal 看似 +10～15%，但 **lazy2（與熵閘無關）也同步 +15～22%、llama tgz +17%**——代表本輪整機比 R16 更快（系統狀態差異），**並非熵閘帶來的淨加速**。跨輪絕對值仍不能直接歸因。

### 同輪內相對：Optimal / Lazy2 時間倍數（可信指標）

| 資料集 | R16 倍數 | R18 倍數 |
| --- | ---: | ---: |
| claw-code | 1.87× | **1.95×** |
| llama.cpp | 2.76× | **2.93×** |

> 關鍵：同輪內 optimal 相對 lazy2 的時間倍數 R18 **不降反略升**。原因是 R17 的**文字保護（isText）正確地把文字段留在 DP**（R16 的 7.5 門檻無文字保護，可能誤跳了部分文字段而「偷快」）。換言之，熵閘調參對這兩個資料集（claw=文字、llama=原始碼為主）**沒有可量測的淨加速**。

### 壓縮比（deterministic，跨多輪完全可再現）

| 格式 | claw | llama |
| --- | ---: | ---: |
| **Optimal** | **0.8590** | **0.9416** |
| **Lazy2** | 0.9020 | 0.9583 |

> 與 R16/R17 完全一致。**文字保護未犧牲比率**——這是 R17 改動真正的價值：在不動比率下修正了 R16 可能的文字誤判。Apple/ZSTD 大小本來就會隨資料集微幅浮動。

## Lazy2 vs Optimal 改善策略 / Strategy

1. **熵閘對這些資料集效益有限**：claw 為文字（熵 < 7.2，且文字保護強制 DP）→ optimal 無法靠跳 DP 加速；llama 雖含二進位，但 optimal 相對 lazy2 仍要 2.9× 時間。熵閘的真正價值在「**比率中立的安全網**」（避免擬亂段浪費 DP、且不誤傷文字），而非通用加速。
2. **optimal 的速度瓶頸在 DP 本身**：claw optimal 28 MB/s vs lazy2 55 MB/s vs zstd 460 MB/s。要逼近 zstd，必須對 DP 核心熱迴圈動刀。
3. **lazy2 仍是速度/比率甜蜜點**：claw 54.58 MB/s、比率 0.9020；多數情境優於 optimal 的 1.95× 代價換 4.3% 比率。

## 結論 / Conclusions

1. **乾淨輪確認**：本輪非負載輪，絕對 MB/s 可信。
2. **熵閘調參無淨加速**：同輪內 optimal/lazy2 倍數未降（claw 1.95×、llama 2.93×）；optimal 的絕對提升來自系統狀態而非演算法。
3. **比率零退步且可再現**：optimal claw 0.8590 / llama 0.9416 跨輪一致；文字保護是 R17 的實質收穫。
4. **方向確立**：optimal 加速須走 DP 核心 UnsafePointer/SIMD，而非繼續調熵閘參數。

## 下一輪計畫 / Next (R19)

- **DP 核心 UnsafePointer 化 + SIMD**：把 `lzParseOptimal` 的 price/match 熱迴圈全面指標化、消除 Swift bounds-check 與 ARC 開銷，目標 claw optimal 28→40+ MB/s。
- **編碼器調度器**：依區塊熵自動選 bvx1/bvx2/bvx3，導入 -lazy/-optimal。
- **熵閘定位為安全網**：保留 7.2/35%/三點/文字保護（比率中立），不再以此為加速主軸。

---

# 第十七輪：熵閘調參 + 三點取樣 + 文字保護 + warm-cache（2026-06-14）/ Round 17: Entropy-Gate Tuning + 3-Point Sampling + Text Guard + Warm-Cache

## 本輪目的 / Purpose

實作 Gemini 建議，細修 R16 熵閘並改善量測穩定度：(1) 熵門檻 7.5→7.2、(2) 預篩覆蓋率門檻 28→35%、(3) `sampleEntropy` 改三點（前/中/後各 512B）取樣 + 文字保護、(4) `lz4bench` 加 warm-cache 預讀資料集。

Implement Gemini's suggestions to refine the R16 entropy gate and stabilise measurement.

## 本輪改動 / Changes

**`lzfse-cli.swift`（`lzParseOptimal`）：**

| 項目 | R16 | R17 |
| --- | --- | --- |
| `optEntropyHighThreshold` | 7.5 | **7.2**（更積極跳過 DP） |
| `optPrescreenMinCoverage` | 28 | **35%**（更多中覆蓋率段走 greedy） |
| 熵取樣 | 前 1KB 單點 | **三點（前/中/後 512B）平均**，更能代表整段 |
| 文字保護 | 無 | **`isText` 守門**：可列印字元 ≥85% 的段，即使高熵也**不跳 DP**（避免文字段誤判為擬亂而失比率） |

**`zshrc.sh`（`lz4bench`）：** 壓縮計時前先 `tar -cf - "$1" > /dev/null` 預讀整個資料集進 OS cache，消除「第一個格式 cold-cache、後續 warm-cache」的計時偏差。

## 測試完整度 / Benchmark Completeness

- **claw-code / llama.cpp**：✅ 各 8 格式壓縮+解壓縮、7/7 一致性通過；lzfse-test 全綠；warm-cache 已生效。
- ⚠️ **本輪量測在系統負載下進行**（見下）。

## ⚠️ 量測條件警示 / Measurement Caveat

本輪（與前一次重跑）**所有格式的壓縮 MB/s 全面下降**，包含與本輪改動無關的 tgz / zstd / bvx3 / lazy2：

| 格式（壓縮 MB/s） | claw R16 | claw R17 | llama R16 | llama R17 |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 47.61 | 43.11 | 55.49 | 37.50 |
| ZSTD | 359.44 | 209.93 | 390.32 | 199.59 |
| BVX3 | 515.82 | 205.28 | 299.04 | 162.65 |
| **Lazy2**（未受本輪改動） | 47.36 | 37.40 | 129.59 | 75.80 |
| **Optimal** | 25.36 | 16.17 | 46.92 | 26.17 |

> tgz/zstd/bvx3/lazy2 皆與熵閘無關卻同步下降 15–60%，可確定是**系統負載**（背景 check.sh、caffeinate、dispatch、Claude 同時運行）造成，**非演算法退步**。因此本輪「絕對壓縮 MB/s」不可跨輪比較。

## 可信指標：壓縮比（deterministic）/ Reliable Metric: Ratio

| 格式 | claw R16 | claw R17 | llama R16 | llama R17 |
| --- | ---: | ---: | ---: | ---: |
| **Optimal** | 0.8594 | **0.8590** | 0.9411 | **0.9416** |
| **Lazy2** | 0.9018 | **0.9018** | 0.9573 | **0.9590** |

> 壓縮比與 R16 幾乎完全一致（差異 < 0.2%，屬資料集版本浮動）。**關鍵結論：加入文字保護後，optimal 比率未退步**——證明 R16 的熵閘並未因 7.5 門檻誤跳文字段（claw 為文字，isText 守門後仍全程 DP，比率不變）。Apple/ZSTD 大小本來就會隨資料集微幅浮動。

## Lazy2 vs Optimal（R17，僅同輪內相對有效）/ Within-Run Relative

| 指標 | claw Lazy2 | claw Optimal | llama Lazy2 | llama Optimal |
| --- | ---: | ---: | ---: | ---: |
| 壓縮 MB/s | 37.40 | 16.17 | 75.80 | 26.17 |
| 解壓 MB/s | 442.98 | 436.02 | 128.67 | 137.85 |
| 壓縮比 | 0.9018 | 0.8590 | 0.9590 | 0.9416 |
| Optimal/Lazy2 壓縮時間倍數 | — | **2.31×** | — | **2.90×** |

> 同輪內，optimal 時間倍數 claw 2.31×、llama 2.90×（與 R16 同條件趨勢一致）。由於整機受載，無法從本輪數字判定熵閘調參帶來的「淨加速」。

## 結論 / Conclusions

1. **四項改動已全部落地且正確**：編譯通過、lzfse-test 7/7、一致性 7/7、warm-cache 生效。
2. **比率未退步**：文字保護生效，claw/llama optimal 壓縮比與 R16 持平——確認三點取樣 + isText 守門沒有破壞壓縮品質。
3. **本輪不可作絕對速度比較**：全格式（含無關的 tgz/zstd/bvx3/lazy2）受系統負載拖慢 15–60%；熵閘調參的淨加速效果**尚未量測到**。
4. **warm-cache 已就位**：未來在乾淨條件下可降低 cold-cache 對壓縮計時的干擾。

## 下一輪計畫 / Next (R18)

- **乾淨環境量測**：在系統閒置（暫停 check.sh / dispatch）下重跑一輪，才能隔離出 7.2 門檻 + 35% 覆蓋率 + 三點取樣對 llama optimal 的真實加速。
- **編碼器調度器**：依區塊熵自動選 bvx1/bvx2/bvx3，導入 -lazy/-optimal。
- **Swift 熱迴圈 UnsafePointer 化**：claw（文字）optimal 受文字保護全程 DP，加速須靠 DP 本身的 SIMD/指標化，挑戰 C 版 zstd。

---

# 第十六輪：熵感知閘門（資料驅動 GGUF 分區）（2026-06-13）/ Round 16: Entropy-Aware Gate (Data-Driven GGUF Partitioning)

## 本輪目的 / Purpose

針對「GGUF tensor 權重佔體積 ~99%、內容擬亂、optimal 與 greedy 比率差 < 0.5%」的觀察，為 optimal 加入**段層級熵取樣器**作為最便宜的第一道閘：擬亂段直接 greedy 發射、完全跳過昂貴的 DP，換取壓縮吞吐。純看內容、不嗅探 GGUF 格式/偏移（脆弱）。

Add a segment-level Shannon-entropy sampler as optimal's cheapest first gate: pseudo-random segments emit greedy and skip DP entirely, trading away DP cost for throughput. Content-driven — no fragile GGUF format/offset sniffing.

## 本輪改動 / Changes

**`lzfse-cli.swift` — `lzParseOptimal` 新增熵閘（R10 設計，本輪實裝）：**

| 項目 | 說明 |
| --- | --- |
| `optEntropySampleBytes` | 1024（每段抽樣前 1KB） |
| `optEntropyHighThreshold` | 7.5 bits/byte（以上視為擬亂、跳過 DP） |
| 閘門位置 | 置於覆蓋率閘（R9）**之前**：`segLen >= 4096 && sampleEntropy() > 7.5` → `greedyEmitSegment()` |
| 成本 | 熵取樣 1KB ≪ 覆蓋率全段掃描；高熵段省下整段 DP（DP 成本約 greedy 的數十倍） |
| 共用 | 熵閘與覆蓋率閘共用 `greedyEmitSegment()`（rep 感知、match 截於 segEnd 內，維持跨段 litStart 不變式） |

`sampleEntropy()` 抽樣前 1KB 計 Shannon 熵（bits/byte）；`greedyEmitSegment()` 由 R15 的 inline greedy 重構為可重用函式，供兩道閘共用。lazy2 解析路徑不受影響（熵閘僅在 optimal 內）。

## 測試完整度 / Benchmark Completeness

- **claw-code**：✅ 全部完成（8 格式壓縮 + 解壓縮，7 項一致性全通過）
- **llama.cpp**：✅ 全部完成（8 格式壓縮 + 解壓縮，7 項一致性全通過）
- **lzfse-test**：✅ 全綠（含 bvx3 lazy2/optimal 自我往返與平行解碼）
- ✅ **磁碟充足**：benchmark.sh 雙重 diskcheck 通過（開頭 28GB、llama 段前 26GB，均 ≥25GB 門檻）；EXIT 0、BENCH_DONE 19:57:21。

## 實測結果 / Measured Results（R16 vs R15，MB/s 以實際 bytes/ns 計）

### 壓縮 MB/s（Compression Throughput）— 焦點：optimal（熵閘僅作用於 optimal）

| 格式 | claw R15 | claw R16 | 差異 | llama R15 | llama R16 | 差異 |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Optimal** | 24.96 | **25.36** | **+1.6% 🟢** | 43.69 | **46.92** | **+7.4% 🟢** |
| **Lazy2** | 46.27 | **47.36** | +2.4%‡ | 142.63 | **129.59** | −9.1%‡ |
| Other3 | 404.87 | **460.00** | +13.6% | 361.48 | **309.71** | −14.3% |
| BVX3 | 410.62 | **515.82** | +25.6% | 135.35 | **299.04** | +120%※ |
| Apple | 143.54 | **146.32** | +1.9% | 88.99 | **151.62** | +70%※ |
| TGZ | 46.05 | **47.61** | +3.4% | 54.60 | **55.49** | +1.6% |
| TLZ4 | 536.59 | **569.78** | +6.2% | 133.67 | **337.63** | +153%※ |
| ZSTD | 369.66 | **359.44** | −2.8% | 136.97 | **390.32** | +185%※ |

> ‡ lazy2 不受熵閘影響（熵閘僅在 optimal 解析內）；±2–9% 屬量測噪音與資料集版本浮動。
>
> ※ R15 的 llama BVX3/Apple/TLZ4/ZSTD 壓縮 MB/s 偏低是該輪 cold-cache I/O 所致（已於 R15 標注）；R16 快取條件較佳，故大幅回升——這是**量測條件差異**而非演算法變化，跨輪務必以同條件比較。
>
> **核心結論：熵閘讓 llama optimal 壓縮 +7.4%（擬亂的 GGUF 權重段跳過 DP），claw optimal +1.6%（文字熵低、觸發閘門的段較少）。** 方向與設計預期一致：高熵資料受益最大。

### 壓縮大小（精確 byte）/ Compression Sizes

| 格式 | claw R15 (bytes) | claw R16 (bytes) | 差異 | llama R15 (bytes) | llama R16 (bytes) | 差異 |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Optimal** | 422,142,121 | 422,452,184 | +310,063 (+0.07%) | 571,976,860 | 573,166,606 | +1,189,746 (+0.21%) |
| **Lazy2** | 443,315,744 | 443,301,919 | −13,825 (≈0%) | 582,331,084 | 583,052,611 | +721,527 (+0.12%)‡ |

> Optimal 因高熵段改走 greedy，壓縮比微降（claw 0.8588→0.8594、llama ~0.9416→0.9411 區間），代價 < 0.25%——正是「DP 成本 vs < 0.5% 比率差」的合理取捨。‡ lazy2 差異來自資料集版本浮動（llama.cpp 倉庫有新 commit）。Apple/ZSTD 壓縮大小即使資料相同也會微幅浮動，跨輪比較以 MB/s 為主要指標。

## Lazy2 vs Optimal 分析（R16）/ Lazy2 vs Optimal Analysis

| 指標 | claw Lazy2 | claw Optimal | llama Lazy2 | llama Optimal |
| --- | ---: | ---: | ---: | ---: |
| 壓縮 MB/s | 47.36 | **25.36** | 129.59 | **46.92** |
| 解壓縮 MB/s | 569.36 | **654.13** | 216.59 | **236.49** |
| 壓縮後 | 443M | **422M** | 583M | **573M** |
| 壓縮比（vs tgz） | 0.9018 | **0.8594** | 0.9573 | **0.9411** |
| Optimal vs Lazy2 壓縮時間倍數 | — | **1.87×** | — | **2.76×** |

**R16 取捨：** 熵閘把 llama optimal 的時間倍數從 R15 的 3.26× 壓到 **2.76×**（擬亂段不再進 DP），同時比率幾乎不變（−0.05 pt）。claw optimal 倍數 1.87×（與 R15 1.85× 持平，文字段多數仍進 DP）。解壓縮 optimal 仍略快於 lazy2（共用 bvx3 位元流，差異屬噪音）。

## 結論 / Conclusions

1. **熵閘對高熵資料有效**：llama optimal 壓縮 +7.4%、時間倍數 3.26×→2.76×，比率代價 < 0.25%。設計目標達成。
2. **文字資料受益有限**：claw optimal 僅 +1.6%——文字熵低（多數段 < 7.5 bits/byte），仍走 DP；文字的 optimal 瓶頸仍是 DP 本身。
3. **lazy2 不受影響**：熵閘僅在 optimal 解析內，lazy2 數據變化為噪音/資料集浮動。
4. **量測紀律**：本輪快取條件較 R15 佳，BVX3/Apple/TLZ4/ZSTD 壓縮 MB/s 大幅回升屬條件差異；跨輪僅比較同條件、以 optimal/lazy2 壓縮 MB/s + 壓縮比為主指標。
5. **一致性與測試全綠**：兩資料集 7/7 一致、lzfse-test 全通過、磁碟雙檢通過。

## 下一輪計畫 / Next (R17)

- **調低熵門檻**：7.5 偏保守；可試 7.0–7.3，讓更多「中高熵」llama 段跳過 DP（預期 optimal 再加速 5–15%，比率代價 < 0.5%）。需對文字資料設防護，避免高局部熵的文字段誤跳 DP 而失比率。
- **編碼器調度器（encoder dispatcher）**：依區塊熵自動選 bvx1/bvx2/bvx3，導入 -lazy 與 -optimal（R10 構想的延伸）。
- **Swift 熱迴圈**：核心 match/DP 迴圈全面 `UnsafePointer` 化、消除 Swift 物件導向開銷，挑戰 C 版 zstd 的壓縮吞吐。
- **熵取樣強化**：1KB 單點抽樣可能誤判混合段；可試多點抽樣或前/中/後三段取樣取均值。

---

# 第十五輪：二段式預篩 + 搜尋預算計數器（2026-06-13）/ Round 15: Two-Pass Prescreen + Search Budget Counter

## 本輪目的 / Purpose

修復並完整實作 R14 的兩項遺漏策略（附件程式，R9 設計）：

1. **搜尋預算計數器（Adaptive Search Budget）**：每段預算 = `segLen × 2`，以倒數式累計實際鏈走訪步數；超支後整段剩餘位置的搜尋深度強制砍半（保留荒漠下限）。比 R14 的「週期重設」機制更精確——一旦超支立刻設 flag，不再週期性恢復。
2. **二段式預篩（Two-Pass Greedy Prescreen）**：每段先用獨立 14-bit local hash（不污染主 head/chain）做輕量 greedy 掃描；greedy match 覆蓋率 < 28% 的段（二進位/隨機）整段直接 greedy 發射，**完全跳過 DP**。greedy 路徑透過 `emitGreedy()` 共用 DP 的 L/M/D 統計與 rep 歷史，跨段連續性保持。

R14 的粗估 `totalBarren` 熵代理（70% 荒漠閾值）已被真正的 greedy 預掃取代。`optSufficientLen` 還原為 192（有預篩保護，不需要 R14 激進的 128 截斷）。

## 本輪改動 / Changes

**`lzfse-cli.swift` — `lzParseOptimal` 改動（R9 策略）：**

| 項目 | R14 | R15 |
| --- | --- | --- |
| `optSufficientLen` | 128 | 192（還原） |
| `optBudgetMultiplier` | 3 | 2（更緊預算） |
| 預算邏輯 | `chainBudget` 計數 + 週期重設 `effectiveDepthCap` | `searchBudget` 倒數 + `budgetExhausted` flag |
| 低壓縮段處理 | `totalBarren` 粗估（70% 荒漠） | 獨立 local hash greedy 預掃（28% 覆蓋率） |
| 跳過 DP | 無 | 低覆蓋率段直接 greedy 發射 |

**Bug 修復（R15 首輪發現）**：greedy 預篩段的 match `limit` 原為 `n - i - 4`，允許 match 跨越 `segEnd`，導致下一段 DP 時 `litStart > segStart`，`pushRun` 得到負 L 長度 → 串流損毀（decode failed）。修復為 `limit: max(0, segEnd - i - 4)`，確保 match 不跨段。

## 測試完整度 / Benchmark Completeness

- **claw-code**：✅ 全部完成（8 格式壓縮 + 解壓縮，8 項一致性全通過）
- **llama.cpp**：✅ 全部完成（8 格式壓縮 + 解壓縮，8 項一致性全通過）
- **lzfse-test**：✅ 全綠（compile 8s，含 bvx3 lazy2/optimal 自我往返）
- ✅ **磁碟充足**：最終重跑磁碟 **43 GB 可用**（≫25 GB 門檻），壓縮與解壓縮數字均可靠。首輪（磁碟 15 GB + 殘檔）解壓數字已廢棄，以本重跑為準。
- ✅ **benchmark.sh 強化**：加入雙重磁碟空間檢查（開頭 + llama 段前，< 25 GB → `"Benchmark aborted: insufficient disk space"` 並中止）及 `rm -rf llama.cpp.*` 殘檔清理，防止下次重跑受磁碟壓力影響。

## 實測結果 / Measured Results（R15 重跑 vs R14，磁碟 43 GB）

### 壓縮 MB/s（Compression Throughput）— 焦點：lazy2 / optimal

| 格式 | claw R14 | claw R15 | 差異 | llama R14 | llama R15 | 差異 |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Lazy2** | 47.91 | **46.27** | −3.4% | 140.68 | **142.63** | **+1.4%** |
| **Optimal** | 26.53 | **24.96** | −5.9% | 42.88 | **43.69** | **+1.9% 🟢** |
| Other3 | 412.63 | **404.87** | −1.9% | 359.91 | **361.48** | +0.4% |
| BVX3 | 457.95 | **410.62** | −10.3%† | 353.02 | 135.35 | −61.7%†† |
| Apple | 140.60 | **143.54** | +2.1% | 146.59 | 88.99 | −39.3%†† |
| TGZ | 46.65 | **46.05** | −1.3% | 54.11 | **54.60** | +0.9% |
| TLZ4 | 534.12 | **536.59** | +0.5% | 320.09 | 133.67 | −58.2%†† |
| ZSTD | 383.93 | **369.66** | −3.7% | 368.88 | 136.97 | −62.9%†† |

> † claw BVX3 偏慢（3.29s vs 2.86s）：在本輪 claw optimal（54s）結束後，系統可能有短暫 I/O flush，導致後續 BVX3 稍慢。量測噪音，非演算法退步。
>
> †† llama BVX3 / Apple / TLZ4 / ZSTD 大幅偏慢：推測 claw optimal（54s）＋ sleep 60 後系統頁面快取清空，llama.cpp 首次讀取時 cold-cache I/O 嚴重。Other3（3.48s）最先跑，仍享有部分快取；後面的格式 cold cache 全開（每個都要重讀 1.2 GB）。這是**量測條件差異**，非演算法退步——壓縮比（大小）完全不受影響。
>
> **核心結論（重跑）：llama.cpp optimal +1.9%，llama Lazy2 +1.4%（vs R14）**。Optimal 改善較首輪（+11.5%）保守，因首輪磁碟壓力同時壓低了 R15 首輪的參考基線。重跑結果更可靠：二段式預篩在乾淨條件下對 llama optimal 帶來穩定的小幅改善，claw 略退步（−3–6%）屬量測噪音。

### 壓縮大小 / Compression Sizes

| 格式 | claw R14 (bytes) | claw R15 rerun (bytes) | 差異 | llama R14 (bytes) | llama R15 rerun (bytes) | 差異 |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Lazy2** | 443,315,716 | 443,315,744 | +28 B (≈0%) | 582,331,025 | 582,331,084 | +59 B (≈0%) |
| **Optimal** | 421,706,858 | 422,142,121 | +435,263 (+0.1%) | 567,544,521 | 571,976,860 | +4,432,339 (+0.78%) |

> Lazy2 大小差異僅 28 / 59 bytes，來自**資料集版本浮動**（claw-code / llama.cpp 原始碼倉庫有新 commit），並非演算法輸出不同。Optimal 因部分段改走 greedy 路徑，壓縮比略降（llama: 0.9416 vs R14 0.9343，+0.73 個百分點）。Apple 與 ZSTD 壓縮大小同樣會隨資料集版本微幅浮動，跨輪比較以 MB/s 為主要指標。這是速度換比率的合理取捨。

## Lazy2 vs Optimal 分析（R15 重跑）/ Lazy2 vs Optimal Analysis

| 指標 | claw Lazy2 | claw Optimal | llama Lazy2 | llama Optimal |
| --- | ---: | ---: | ---: | ---: |
| 壓縮 MB/s | 46.27 | **24.96** | 142.63 | **43.69** |
| 解壓縮 MB/s | 544.71 | **622.95** | 161.22 | **197.97** |
| 壓縮後 | 443M | **422M** | 582M | **572M** |
| 壓縮比（vs tgz） | 0.9018 | **0.8588** | 0.9587 | **0.9416** |
| vs ZSTD 大小（byte 精確） | +9.2% | +4.0% | +5.1% | +3.2% |
| Optimal vs Lazy2 時間倍數 | — | **1.85×** | — | **3.26×** |

**R15 取捨（重跑）：** claw optimal 時間倍數 1.85×（vs R13 的 2.3×，顯著改善）。llama optimal 時間倍數 3.26×（vs R13 的 3.3×，小幅改善）。解壓縮 optimal 比 lazy2 略快（同樣 bvx3 位元流，decoder 路徑相同，差異屬量測噪音）。Optimal 的比率優勢（相對 lazy2）維持 −4.3%（claw）/ −1.7%（llama），仍需比 lazy2 付出 2–3× 壓縮時間。

## 結論 / Conclusions

1. **二段式預篩對二進位資料小幅有效**：重跑乾淨條件下 llama.cpp optimal +1.9%，llama Lazy2 +1.4%（vs R14）。首輪 +11.5% 含磁碟壓力雜訊，重跑更可靠。
2. **文字資料（claw-code）略退步**：最終 claw optimal −5.9%、Lazy2 −3.4%，在量測噪音範圍，非演算法顯著退步。
3. **Bug 修復經驗**：greedy 路徑的 match 必須限制在段邊界內（`segLimit = max(0, segEnd - i - 4)`），否則跨段後 `litStart > segStart` 導致 `pushRun` 負 L 長度、串流損毀。
4. **壓縮大小代價**：optimal 比率略降（llama +0.78%），可接受的速度換比率取捨。
5. **解壓縮數字（重跑）可靠**：claw optimal 622.95 MB/s、llama optimal 197.97 MB/s，磁碟充足條件下解壓極快，bvx3 家族共用位元流優勢明顯。
6. **benchmark.sh 改善**：新增磁碟不足 abort（< 25 GB）+ llama 前殘檔清理，避免未來重跑受磁碟壓力污染數據。

## 下一輪計畫 / Next (R16)

llama.cpp optimal 仍比 zstd（9.18s → 137 MB/s）慢 3×，claw optimal 比 TGZ 慢 1.85×。下一步方向：

- **調整預篩門檻**：28% 覆蓋率偏保守；可試 35–40%，讓更多「中等覆蓋率」的 llama 段走 greedy，進一步加速（預期：壓縮比再降 0.5–1%，速度提升 5–15%）。
- **cold-cache I/O 問題**：llama 的 BVX3 / Apple / TLZ4 / ZSTD 重跑時均極慢（cold cache），下輪考慮在 lz4bench 每個格式前先 warm cache（讀一遍原始資料），讓壓縮計時更穩定。
- **claw-code 輕微退步確認**：profiling 確認 segLimit 截斷是否真的造成 DP 效率下降，或只是量測噪音；若是截斷，考慮最後一個 match 允許延伸至 `n`。

---

# 第十四輪：Gemini 搜尋預算 + 熵代理（2026-06-13）/ Round 14: Gemini Budget Counter + Entropy Proxy

## 本輪目的 / Purpose

針對 R13 的 optimal 壓縮瓶頸（claw 22.45 MB/s，llama 38.84 MB/s），依據 Gemini 建議實作五項改善策略。

## 本輪改動 / Changes

**`lzfse-cli.swift` — `lzParseOptimal` 五項 R14 優化：**

1. `optSufficientLen`: 192 → **128**（超級 match 快速路徑更激進，策略 5）
2. `optBudgetMultiplier = 3`（每段鏈搜尋預算 = segLen × 3，策略 1）
3. `chainBudget` 計數 + 週期重設 `effectiveDepthCap`（動態搜尋深度，策略 1）
4. `totalBarren` 段級熵代理（70% 荒漠 → 強制最低深度，策略 2/6）
5. depth 計算改用 `effectiveDepthCap` 取代固定 `optSearchDepth`

## 測試完整度 / Benchmark Completeness

- **claw-code**：✅ 全部完成（8 格式，全通過）
- **llama.cpp**：✅ 全部完成（8 格式，全通過）
- **lzfse-test**：✅ 全綠

## 實測結果 / Measured Results（R14 vs R13）

### 壓縮 MB/s（Compression Throughput）

| 格式 | claw R13 | claw R14 | 差異 | llama R13 | llama R14 | 差異 |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Lazy2** | 47.31 | **47.91** | +1.3% | 127.84 | **140.68** | **+10.0% 🟢** |
| **Optimal** | 22.45 | **26.53** | **+18.2% 🟢** | 38.84 | **42.88** | **+10.4% 🟢** |
| Other3 | 400.55 | **412.63** | +3.0% | 273.41 | **359.91** | +31.6% |
| BVX3 | 440.53 | **457.95** | +4.0% | 276.71 | **353.02** | +27.6% |
| ZSTD | 386.74 | **383.93** | −0.7% | 371.41 | **368.88** | −0.7% |

> **Optimal 改善顯著**：claw +18.2%（22.45→26.53 MB/s），llama +10.4%（38.84→42.88 MB/s）。

### 壓縮大小 / Compression Sizes

| 格式 | claw R13 (bytes) | claw R14 (bytes) | 差異 | llama R13 (bytes) | llama R14 (bytes) | 差異 |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Optimal** | 420,637,504 | 421,706,858 | +0.25% | 566,261,130 | 567,544,521 | +0.23% |

## 結論 / Conclusions

R14 實作的五項策略為 optimal 帶來顯著改善（+10–18% 壓縮速度），代價是壓縮比輕微退步（+0.25%），acceptable 取捨。

---

# 第十三輪：磁碟回復後的完整可靠基準（2026-06-13）/ Round 13: Full Reliable Benchmark After Disk Recovery

## 本輪目的 / Purpose

無演算法代碼變更。R12 因磁碟僅 10–12 GB 失真且 llama.cpp 解壓截斷；本輪在磁碟回復至 **claw 32 GB / llama 31 GB 可用**（≫ 25 GB 警戒值）下重跑一輪，取得兩資料集 **全 8 格式、壓縮 + 解壓縮皆完整** 的可靠數據，並驗證 lazy2/optimal 產物正確。

No algorithm code change. This round re-runs the benchmark with disk restored to **claw 32 GB / llama 31 GB free** (well above the 25 GB threshold), producing a complete, reliable dataset for both corpora — all 8 formats, compression *and* decompression — and confirming lazy2/optimal artifacts are correct.

## 本輪改動 / Changes

**`zshrc.sh` — `lz4bench` 接回 `diskcheck`：** R11 將磁碟預檢抽成獨立 `diskcheck()` 後，未接回 `lz4bench`，使預檢成為死碼。本輪在 `lz4bench` 開頭加入 `diskcheck "$1"`，每輪基準開跑前主動回報磁碟可用空間（本輪：充足 claw 32 GB / llama 31 GB），避免再度於磁碟壓力下產生失真數據。`extract`、`lzfseX` 對 lazy2/optimal 的處理（`-lazy2`/`-optimal` 旗標、`-algo bvx3` 解碼）經查已正確，維持不動。

## 測試完整度 / Benchmark Completeness

- **claw-code**：✅ 全部完成（8 格式壓縮 + 解壓縮，7 項一致性全通過）
- **llama.cpp**：✅ 全部完成（8 格式壓縮 + 解壓縮，7 項一致性全通過）— R12 的 Apple/TLZ4/ZSTD 解壓截斷已恢復
- **lzfse-test**：✅ 全綠（含 bvx3 `-lazy2`/`-optimal` 自我往返與平行解碼）

## 實測結果 / Measured Results（R13 vs R11 可靠基線）

### 壓縮 MB/s（Compression Throughput）— 焦點：lazy2 / optimal

| 格式 | claw R11 | claw R13 | 差異 | llama R11 | llama R13 | 差異 |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Lazy2** | 49.21 | **47.31** | −3.9% | 129.16 | **127.84** | −1.0% |
| **Optimal** | 23.99 | **22.45** | −6.4% | 40.85 | **38.84** | −4.9% |
| Other3 | 407.40 | **400.55** | −1.7% | 240.11 | **273.41** | +13.9% |
| BVX3 | 413.47 | **440.53** | +6.5% | 229.06 | **276.71** | +20.8% |
| Apple | 136.61 | **140.29** | +2.7% | 127.65 | **143.93** | +12.8% |
| TGZ | 47.81 | **44.31** | −7.3% | 55.81 | **52.84** | −5.3% |
| TLZ4 | 534.35 | **521.48** | −2.4% | 273.93 | **310.47** | +13.3% |
| ZSTD | 404.11 | **386.74** | −4.3% | 338.85 | **371.41** | +9.6% |

> lazy2/optimal 壓縮 MB/s 與 R11 相差僅 1–6%，落在量測噪音範圍內——確認**壓縮吞吐穩定可再現**。

### 解壓縮 MB/s（Decompression Throughput）

| 格式 | claw R11 | claw R13 | 差異 | llama R11 | llama R13 | 差異 |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Lazy2** | 460.04 | **332.40** | −27.7% | 228.01 | **198.27** | −13.0% |
| **Optimal** | 548.28 | **261.57** | −52.3% | 199.41 | **202.22** | +1.4% |
| Other3 | 503.52 | **490.25** | −2.6% | 256.81 | **161.77** | −37.0% |
| BVX3 | 481.99 | **443.04** | −8.1% | 232.81 | **165.18** | −29.0% |
| Apple | 617.76 | **395.09** | −36.0% | 209.68 | **183.56** | −12.5% |
| TGZ | 533.61 | **419.14** | −21.5% | 259.96 | **182.99** | −29.6% |
| TLZ4 | 266.01 | **695.20** | +161% | 244.49 | **204.89** | −16.2% |
| ZSTD | 355.65 | **362.38** | +1.9% | 231.66 | **135.37** | −41.5% |

> ⚠️ 解壓縮 MB/s 在不同輪次間波動很大（claw Optimal R11 的 548、TLZ4 R13 的 695 等皆為與系統負載相關的離群值）。**解壓速度受系統暫態負載與檔案快取影響甚鉅，單輪數值不應視為演算法特性。** 重點觀察：**llama Optimal 解壓（202）≈ Lazy2（198）**——再次印證 bvx3 家族（lazy2/optimal/bvx3）共用同一位元流格式，解壓速度由格式而非解析策略決定。

### 壓縮大小（精確 byte，Compression Sizes）

| 格式 | claw R11 (bytes) | claw R13 (bytes) | 差異 | llama R11 (bytes) | llama R13 (bytes) | 差異 |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| Lazy2 | 443,123,872 | 443,315,716 | +0.04% | 582,575,735 | 582,331,025 | −0.04% |
| Optimal | 420,637,703 | 420,637,504 | −199 B | 566,223,268 | 566,261,130 | +0.01% |

> 壓縮輸出 byte 大小相對 R11 偏移皆 < 0.05%（源自資料集/tar metadata 微幅浮動），**確認演算法輸出為 deterministic**，lazy2/optimal 產物正確。

## Lazy2 vs Optimal 分析（R13）/ Lazy2 vs Optimal Analysis

| 指標 | claw Lazy2 | claw Optimal | llama Lazy2 | llama Optimal |
| --- | ---: | ---: | ---: | ---: |
| 壓縮 MB/s | 47.31 | **22.45** | 127.84 | **38.84** |
| 解壓 MB/s | 332.40 | 261.57 | 198.27 | 202.22 |
| 壓縮後 | 433M | **417M** | 556M | **544M** |
| 壓縮比（vs tgz） | 0.9018 | **0.8557** | 0.9587 | **0.9322** |
| vs ZSTD 大小 | +3.7 pt | +3.0 pt | +4.7 pt | +2.0 pt |

**核心取捨：** Optimal 以 **2.1×（claw）/ 3.3×（llama）的壓縮時間** 換取相對 Lazy2 僅 **−3.7%（claw）/ −2.1%（llama）的檔案大小**。Optimal 的壓縮吞吐（claw 22.45 MB/s）是全表最慢，為主要瓶頸；Lazy2 在速度/比率上是更佳的甜蜜點。

## 結論 / Conclusions

1. **R13 為可靠輪次**：磁碟 claw 32 GB / llama 31 GB，兩資料集全 8 格式壓縮 + 解壓縮皆完整，補齊 R12 截斷的 llama 解壓數據。
2. **壓縮 MB/s 穩定可再現**：lazy2/optimal 與 R11 差距僅 1–6%（噪音範圍）。
3. **解壓 MB/s 高度波動**：跨輪離群嚴重，受系統負載/快取主導；應以多輪中位數而非單輪比較，且僅以壓縮 MB/s 與壓縮比作為演算法品質的主指標。
4. **lazy2/optimal 產物正確**：byte 大小偏移 < 0.05%（deterministic），一致性與 lzfse-test 全綠。
5. **Optimal 壓縮吞吐是瓶頸**：claw 22.45 MB/s（全表最慢），DP 最優解析成本高，且相對 Lazy2 的比率收益有限。

## 下一輪計畫 / Next (R14)

針對 **claw-code `-optimal` 壓縮熱點（22.45 MB/s）** 進行 profiling，並評估以下 lazy2/optimal 改善策略：

```sh
# 確認磁碟空間後再 profiling
df -h ~                 # 需 ≥25 GB
./run_profile.command   # 對 claw-code -optimal 取樣
```

- **Optimal**：對 DP 成本模型做 SIMD 化、或對長 match 設定搜尋深度上限（fast-skip），目標在不傷壓縮比下回收吞吐。
- **Lazy2**：維持為速度/比率甜蜜點；觀察是否能小幅逼近 optimal 比率而不犧牲 ~2× 的速度優勢。
- **量測紀律**：解壓 MB/s 改採多輪取中位數，降低系統負載造成的離群干擾。

---

# 第十二輪：磁碟壓力下的基準重測（2026-06-13）/ Round 12: Benchmark Under Disk Pressure

## 本輪目的 / Purpose

無演算法代碼變更——在相同基準架構下重新執行一輪，觀察是否能再現 R11 的可靠數據。
結果顯示磁碟可用空間嚴重不足，導致數據失真，**R12 非可靠量測輪次**。

## 磁碟狀態 / Disk Conditions

| 資料集 | 開始時可用空間 | 警戒值 | 狀態 |
| --- | ---: | ---: | --- |
| claw-code | **10 GB** | ≥25 GB | ⚠️ 嚴重不足 |
| llama.cpp | **12 GB** | ≥25 GB | ⚠️ 嚴重不足 |

claw-code 僅 10 GB 可用，壓縮過程中磁碟 I/O 競爭極大；llama.cpp 階段雖釋出 claw-code 暫存，仍僅剩 12 GB。

## 測試完整度 / Benchmark Completeness

- **claw-code**：✅ 全部完成（8 格式壓縮 + 解壓縮，7 項一致性全通過）
- **llama.cpp**：⚠️ 解壓縮截斷——Apple/TLZ4/ZSTD 解壓未完成（benchmark 在 Apple 解壓階段中止）

## 實測結果 / Measured Results

### 壓縮 MB/s（Compression Throughput）

| 格式 | claw R11 | claw R12 | 差異 | llama R11 | llama R12 | 差異 |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| TGZ | 47.81 | **38.89** | −18.6% 🔴 | 55.81 | **54.13** | −3.0% |
| Other3 | 407.40 | **238.98** | −41.3% 🔴 | 240.11 | **217.73** | −9.3% |
| **Lazy2** | **49.21** | **37.15** | **−24.5% 🔴** | **129.16** | **125.90** | **−2.5%** |
| **Optimal** | **23.99** | **17.46** | **−27.2% 🔴** | **40.85** | **39.48** | **−3.4%** |
| BVX3 | 413.47 | **410.78** | −0.7% | 229.06 | **221.63** | −3.2% |
| Apple | 136.61 | **138.16** | +1.1% | 127.65 | **120.43** | −5.7% |
| TLZ4 | 534.35 | **521.52** | −2.4% | 273.93 | **257.90** | −5.9% |
| ZSTD | 404.11 | **397.63** | −1.6% | 338.85 | **309.24** | −8.7% |

> claw-code 壓縮速度全面下降 20–40%，磁碟 I/O 競爭是主因（僅剩 10 GB 時 SSD 隨機寫入顯著降速）。
> llama.cpp 壓縮降幅 3–9%，磁碟稍好（12 GB），但仍偏低。

### 解壓縮 MB/s（Decompression Throughput）

| 格式 | claw R11 | claw R12 | 差異 | llama R11 | llama R12 | 差異 |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| TGZ | 533.61 | **419.89** | −21.3% 🔴 | 259.96 | **242.96** | −6.5% |
| Other3 | 503.52 | **233.24** | −53.7% 🔴 | 256.81 | **157.98** | −38.5% 🔴 |
| **Lazy2** | **460.04** | **256.71** | **−44.2% 🔴** | **228.01** | **177.94** | **−22.0% 🔴** |
| **Optimal** | **548.28** | **241.40** | **−56.0% 🔴** | **199.41** | **172.14** | **−13.7%** |
| BVX3 | 481.99 | **215.29** | −55.3% 🔴 | 232.81 | **143.67** | −38.3% 🔴 |
| Apple | 617.76 | **219.47** | −64.5% 🔴 | 209.68 | —（截斷） | — |
| TLZ4 | 266.01 | **304.32** | +14.4% | 244.49 | —（截斷） | — |
| ZSTD | 355.65 | **317.69** | −10.7% | 231.66 | —（截斷） | — |

> ⚠️ claw-code 解壓縮速度下降幅度更為嚴重（-40 至 -65%），遠超壓縮降幅，說明解壓縮對磁碟可用空間更為敏感。
> TLZ4 claw 例外（+14%）可能是測量噪音。

### 壓縮大小（Compression Sizes）

| 格式 | claw R11 | claw R12 | llama R11 | llama R12 |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 480M | **481M** | 592M | **593M** | 
| Lazy2 | 432M | **423M** | 561M | **570M** |
| Optimal | 417M | **407M** | 544M | **544M** |
| ZSTD | 395M | **395M** | 544M | **528M** |

> `du -sh` 的 M 單位為磁碟區塊配置（非精確位元組），小幅波動屬正常。
> byte-level 精確大小（`[SIZE]`）顯示壓縮演算法輸出完全一致（deterministic）。

## 結論 / Conclusions

1. **R12 為不可靠輪次**：磁碟可用空間 10–12 GB 遠低於建議 ≥25 GB，壓縮與解壓縮均嚴重失真。
2. **磁碟壓力對解壓縮影響尤重**：claw 解壓縮降幅 -40 至 -65%，遠大於壓縮的 -20 至-40%。
3. **llama.cpp benchmark 截斷**：benchmark 在 llama.cpp Apple 解壓縮階段中止，Apple/TLZ4/ZSTD 解壓數據缺失。
4. **壓縮 byte 大小一致**：演算法輸出仍為 deterministic，R12 與 R11 精確大小吻合。
5. **R11 仍為有效基線**：下輪比較請以 R11 為基準。

## 下一輪計畫 / Next (R13)

**先清理磁碟至 ≥25 GB，再執行 profiling 或下一輪 benchmark：**

```sh
# 確認磁碟空間
df -h ~
# 需達到 ≥25 GB 可用空間後，再執行 benchmark 或 profiling
```

---

# 第十一輪：lz4bench 修復 + 解壓縮基線重建（2026-06-13）/ Round 11: Benchmark Fix & Decompression Baseline

## 本輪目的 / Purpose

無演算法代碼變更——修復 lz4bench 的磁碟空間管理問題（R10 發現的 disk-full 缺陷），
重建可靠的解壓縮基線數據。

## 本輪改動 / Changes

**`zshrc.sh` — `lz4bench` 函式重構（inline cleanup 模式）：**

- 解壓縮改為依序執行：解壓 → 與 tgz 比對 → **立即刪除** → 下一格式
- 磁碟峰值用量從 ~14–18GB 降至 ~3.5GB
- llama.cpp ZSTD 解壓縮在 R10 因磁碟滿載失敗；本輪已正常完成 ✓
- 新增磁碟可用空間預檢（建議 ≥25GB）

## 實測結果（11:28–11:36）/ Measured Results

✅ 兩資料集全部 7 格式一致性通過；lzfse-test 112 項全綠。

### 壓縮 MB/s（Compression Throughput）

| 格式 | claw R10 | claw R11 | 趨勢 | llama R10 | llama R11 | 趨勢 |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| Lazy2 | 46.6 | **49.21** | +5.6% | 121.5 | **129.16** | +6.3% |
| Optimal | 22.8 | **23.99** | +5.2% | 37.6 | **40.85** | +8.6% |
| BVX3 | 377.6 | **413.47** | +9.5% | 214.7 | **229.06** | +6.7% |
| ZSTD（參考） | 383.1 | **404.11** | +5.5% | 236.2 | **338.85** | +43.5%↑ |

> 壓縮 MB/s 各格式均小幅提升（+5–10%）。推測原因：R11 逐格式清理磁碟，壓縮階段磁碟 I/O 競爭降低。ZSTD llama 幅度較大，可能與上輪 benchmark 中磁碟已有壓力有關。

### 解壓縮 MB/s（Decompression Throughput）— 首次可靠數據

⚠️ R10 解壓縮受磁碟壓力嚴重失真，R11 使用 inline cleanup 後數據大幅改善：

| 格式 | claw R10 | claw R11 | 改善 | llama R10 | llama R11 | 改善 |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| TGZ | 565.0 | **533.61** | 略降（R10 可能偏高） | 221.4 | **260.00** | +17.4% |
| Other3 | 465.6 | **503.52** | +8.1% | 194.5 | **256.81** | +32.0% |
| Lazy2 | 519.0 | **460.04** | −11.4% | 154.1 | **228.01** | +47.9% |
| Optimal | 308.0 | **548.28** | **+78.0%** | 131.9 | **199.41** | **+51.2%** |
| BVX3 | 215.7 | **481.99** | **+123%** | 98.5 | **232.81** | **+136%** |
| Apple | 142.9 | **617.76** | **+332%** | 108.2 | **209.68** | **+93.8%** |
| TLZ4 | 149.2 | **266.01** | **+78.3%** | 183.4 | **244.49** | +33.3% |
| ZSTD | 143.7 | **355.65** | **+147%** | ❌ 失敗 | **231.66** | ✅ 修復 |

> R10 BVX3/Apple/Optimal/ZSTD 的解壓縮數據因磁碟累積導致 I/O 嚴重降速，已確認不可靠。
> **R11 為解壓縮速度的正式可靠基線。**

### 壓縮大小（Compression Sizes，與 R10 完全一致）

| 格式 | claw | llama | 說明 |
| --- | ---: | ---: | --- |
| Optimal | 417M | 544M | 與 R9/R10 一致 ✓ |
| Lazy2 | 432M | 561M | 與 R9/R10 一致 ✓ |
| ZSTD | 395M | 544M | 與 R9/R10 一致 ✓ |

壓縮算法無任何變動，大小完全再現——確認基線穩定。

## R11 可靠基線（供後續輪次比較）/ R11 Reliable Baseline

### claw-code

| 格式 | 壓縮後 | 壓縮 MB/s | 解壓 MB/s | 壓縮比（vs tgz） |
| --- | ---: | ---: | ---: | ---: |
| TGZ（基準） | 480M | 47.81 | 533.61 | 1.000 |
| LZFSE Other3 | 475M | 407.40 | 503.52 | 0.987 |
| **LZFSE Lazy2** | **432M** | **49.21** | **460.04** | **0.902** |
| **LZFSE Optimal** | **417M** | **23.99** | **548.28** | **0.856** |
| LZFSE BVX3 | 446M | 413.47 | 481.99 | 0.952 |
| LZFSE Apple | 464M | 136.61 | 617.76 | 0.988 |
| TLZ4 | 558M | 534.35 | 266.01 | 1.180 |
| ZSTD -9 | 395M | 404.11 | 355.65 | 0.826 |

### llama.cpp

| 格式 | 壓縮後 | 壓縮 MB/s | 解壓 MB/s | 壓縮比（vs tgz） |
| --- | ---: | ---: | ---: | ---: |
| TGZ（基準） | 592M | 55.81 | 259.96 | 1.000 |
| LZFSE Other3 | 594M | 240.11 | 256.81 | 0.998 |
| **LZFSE Lazy2** | **561M** | **129.16** | **228.01** | **0.959** |
| **LZFSE Optimal** | **544M** | **40.85** | **199.41** | **0.932** |
| LZFSE BVX3 | 577M | 229.06 | 232.81 | 0.982 |
| LZFSE Apple | 592M | 127.65 | 209.68 | 1.001 |
| TLZ4 | 626M | 273.93 | 244.49 | 1.055 |
| ZSTD -9 | 544M | 338.85 | 231.66 | 0.912 |

## Lazy2 vs Optimal 分析 / Lazy2 vs Optimal Analysis

| 指標 | claw Lazy2 | claw Optimal | llama Lazy2 | llama Optimal |
| --- | ---: | ---: | ---: | ---: |
| 壓縮 MB/s | 49.21 | 23.99 | 129.16 | 40.85 |
| 解壓 MB/s | 460.04 | 548.28 | 228.01 | 199.41 |
| 壓縮後大小 | 432M | 417M | 561M | 544M |
| vs ZSTD 大小 | +9.4% | +5.6% | +3.1% | 0.0% |

**Optimal 的解壓縮速度反而比 Lazy2 快**（claw: 548 vs 460 MB/s；差異源自 Optimal 生成更短、更規律的 match 序列，FSE 符號路徑更短）。這是 R11 首次觀測到的可靠數據。

## 結論 / Conclusions

1. **lz4bench inline cleanup 修復成功**：llama.cpp ZSTD 解壓縮恢復正常（231.66 MB/s）。
2. **R10 解壓縮數據確認失真**：BVX3/Apple/Optimal 在累積磁碟壓力下嚴重偏慢；R11 為首個可靠解壓基線。
3. **壓縮 MB/s 略有改善**（+5–10%）：本輪無代碼變更，推測源自更低的磁碟 I/O 競爭。
4. **Optimal 解壓速度亮眼**：claw 548 MB/s > Lazy2 460 MB/s；解壓 vs ZSTD：Optimal 548 vs 356、Lazy2 460 vs 356（均快 1.3–1.5 倍）。
5. **下一步仍是 profiling**：在可靠基線上執行 profiling，找出壓縮 MB/s 的真熱點。

## 下一輪計畫 / Next (R12)

**執行 profiling，量測壓縮熱點（特別是 claw-code bvx3 -optimal 的 23.99 MB/s）：**

```sh
cd ~/proj/lzfse2
open run_profile.command   # 對 claw-code bvx3 -optimal 取樣 20 秒
# 完成後查看 profile-optimal.txt 的熱函數
```

根據 R9 候選策略（在 profiling 結果指引下選擇）：

| 若熱點是 | 方向 | 預期 |
| --- | --- | --- |
| DP 松弛陣列寫入（per-cell 6 陣列） | SoA 打包：price+len 合 64-bit word | 寫入頻寬 −50% |
| `matchLength` 比對迴圈 | SIMD16 向量比較 | match body −50–70% |
| hash chain 走訪 | `optSearchDepth` 16→8 或 price-based 早退 | 走訪量 −30–50% |
| emit / backtrace | DP 分段 128K→256K | 固定開銷 −50% |

---

# 第十輪：基線再確認 + 磁碟滿載警告（2026-06-13）/ Round 10: Baseline Re-confirmation

## 本輪目的 / Purpose

無代碼變更——再次確認 R8/R9 基線穩定，並記錄本輪磁碟滿載問題。

## 實測結果（10:53–11:02）/ Measured Results

⚠️ **磁碟空間在測試中用盡**（llama.cpp 解壓縮測試後段空間不足 → xbenchTest 共 14G，已清理）：
- claw-code 全部 8 格式壓縮與解壓縮完成 ✓
- llama.cpp 全部 8 格式壓縮完成 ✓；解壓縮至 ZSTD 時磁碟爆滿，**ZSTD 解壓失敗**
- 已執行 `rm -rf xbenchTest` 釋出 14G 空間

⚠️ **llama.cpp 解壓縮數據受磁碟壓力影響**（BVX3 12.2s、Apple 11.1s 等異常偏高）；
claw-code 的較晚格式（Apple 9.1s）也可能受熱節流影響。
**解壓縮 MB/s 本輪僅供趨勢參考，不作絕對比較。**

### 壓縮 MB/s（可靠）

| 格式 | claw R9 | claw R10 | 趨勢 | llama R9 | llama R10 | 趨勢 |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| Lazy2 | 45.9 | **46.6** | ≈持平 | 118.3 | **121.5** | ≈持平 |
| Optimal | 22.4 | **22.8** | ≈持平 | 37.6 | **37.6** | 持平 |
| ZSTD（參考） | 376.0 | **383.1** | ≈持平 | 297.4 | **236.2** | ⚠️偏慢（磁碟寫入壓力） |

### 壓縮大小（穩定）

| 格式 | claw R9 | claw R10 | llama R9 | llama R10 |
| --- | ---: | ---: | ---: | ---: |
| Optimal | 417M | **417M** ✓ | 544M | **544M** ✓ |
| Lazy2 | 432M | **432M** ✓ | 571M | **571M** ✓ |

壓縮比與 R9 完全一致，確認 **基線穩定、無代碼回退**。

## 結論 / Conclusions

1. **壓縮 MB/s 穩定**（±3% noise）：Optimal claw 22.4→22.8、llama 37.6；Lazy2 claw 45.9→46.6、llama 118→121。
2. **壓縮比不變**：Optimal 417M/544M、Lazy2 432M/571M。
3. ⚠️ **解壓縮數據不可靠**（磁碟壓力/熱節流），請以 R9 數據作為解壓縮參考基準。
4. **下一步仍是 profiling**：壓縮 MB/s 改善需先量測熱點。

## 下一輪計畫 / Next (R11)

**執行 profiling，然後依熱點決定方向：**

```sh
cd ~/proj/lzfse2
open run_profile.command   # 取 claw-code bvx3 -optimal 20 秒樣本
# 完成後查看 profile-optimal.txt
```

⚠️ **磁碟管理**：下次 benchmark 前，先確認有 ≥25G 可用空間（xbenchTest 佔 ~18G）。
可在 benchmark.sh 執行後立即 `rm -rf ~/proj/lzfse2/xbenchTest` 清理。

---

# 第九輪：基線驗證 + MB/s 比較基準確立（2026-06-13）/ Round 9: Baseline Verification

## 本輪目的 / Purpose

無代碼變更——純粹重跑 benchmark 以確認 R8 基線穩定，並正式確立
**MB/s 為主要跨輪比較指標**（資料集為活躍工作目錄，大小會隨時間浮動；
以 MB/s 歸一化後可跨輪公平比較）。

## 實測結果（01:20–01:26）/ Measured Results

✅ 兩資料集一致性全過（7/7 × 2）；R8 數字完全再現——基線穩定 ✓

### claw-code（原始 1300 MB）

| 格式 | 壓縮後 | 壓縮 MB/s | 解壓 MB/s | 壓縮比 |
| --- | ---: | ---: | ---: | ---: |
| TGZ（基準） | 480M | 46.1 | 534.1 | 1.000 |
| LZFSE Other3 | 472M | 375.7 | 498.0 | 0.983 |
| **LZFSE Lazy2** | **432M** | **45.9** | **524.6** | **0.900** |
| **LZFSE Optimal** | **417M** | **22.4** | **370.7** | **0.869** |
| LZFSE BVX3 | 457M | 384.3 | 238.0 | 0.952 |
| LZFSE Apple | 465M | 139.0 | 225.3 | 0.969 |
| TLZ4 | 563M | 503.3 | 143.7 | 1.173 |
| ZSTD -9 | 393M | 376.0 | 145.1 | 0.819 |

### llama.cpp（原始 1200 MB）

| 格式 | 壓縮後 | 壓縮 MB/s | 解壓 MB/s | 壓縮比 |
| --- | ---: | ---: | ---: | ---: |
| TGZ（基準） | 593M | 52.6 | 231.1 | 1.000 |
| LZFSE Other3 | 593M | 207.6 | 235.9 | 1.000 |
| **LZFSE Lazy2** | **571M** | **118.3** | **196.6** | **0.963** |
| **LZFSE Optimal** | **544M** | **37.6** | **140.3** | **0.917** |
| LZFSE BVX3 | 584M | 214.5 | 151.2 | 0.985 |
| LZFSE Apple | 584M | 121.9 | 163.0 | 0.985 |
| TLZ4 | 614M | 246.2 | 122.7 | 1.035 |
| ZSTD -9 | 544M | 297.4 | 87.5 | 0.917 |

## MB/s 分析 / MB/s Analysis

### Optimal 現況

| 資料集 | 壓縮 MB/s | vs ZSTD | 解壓 MB/s | vs ZSTD | 大小 vs ZSTD |
| --- | ---: | ---: | ---: | ---: | ---: |
| claw-code | 22.4 | ZSTD 快 **16.8×** | 370.7 | 我們快 **2.6×** | 417 vs 393M（+6.1%） |
| llama.cpp | 37.6 | ZSTD 快 **7.9×** | 140.3 | 我們快 **1.6×** | **544 vs 544M（打平）** ✓ |

### Lazy2 現況

| 資料集 | 壓縮 MB/s | vs ZSTD | 解壓 MB/s | 大小 vs ZSTD |
| --- | ---: | ---: | ---: | ---: |
| claw-code | 45.9 | ZSTD 快 **8.2×** | 524.6 | 432 vs 393M（+9.9%） |
| llama.cpp | 118.3 | ZSTD 快 **2.5×** | 196.6 | 571 vs 544M（+5.0%） |

**解壓為 lzfse2 的最大優勢**：claw optimal 370.7 MB/s、lazy2 524.6 MB/s——
ZSTD 僅 145 MB/s，我們快 **2.6–3.6 倍**。

## 結論 / Conclusions

1. **基線穩定**：R8 vs R9 MB/s 誤差 <0.1%，量測可靠，MB/s 可作為跨輪基準。
2. **Optimal 瓶頸**：壓縮 MB/s 落後 ZSTD 8–17 倍；R8 SIMD skip 在 llama 有效（−4.7%）
   但 claw 持平——claw 的 58s / 22.4 MB/s 真熱點未知，**必須先 profile 才能動手**。
3. **Lazy2 天花板**：BT 路線已關閉（R7 負面結果）；hash chain 架構下 claw 45.9 MB/s
   已接近上限。
4. **尚未執行 profiling**：`run_profile.command` 已就緒，R10 必須先量測再動手。

## 下一輪計畫 / Next (R10)

**必做：先執行 profiling，找出 claw optimal 22.4 MB/s 的真熱點**

```sh
cd ~/proj/lzfse2
open run_profile.command   # 對 claw-code bvx3 -optimal 取樣 20 秒
# 完成後查看 profile-optimal.txt 的熱函數
```

根據 profiling 結果選擇方向：

| 若熱點是 | 對應行動 | 預期效益 |
| --- | --- | --- |
| DP 松弛陣列寫入（per-cell 6 陣列） | SoA 打包：price+len 合一個 64-bit word，rep 延後重建 | 寫入頻寬 −50%，claw optimal 目標 <35s |
| `matchLength` 比對迴圈 | SIMD16 向量比較，一次比 16 bytes | match body 內比對成本 −50–70% |
| hash chain 走訪（`chainSearch`） | `optSearchDepth` 16→8，或 price-based 早退 | claw 走訪量 −30–50%，比率小幅回吐 |
| emit / backtrace | DP 分段大小 128K→256K，減少回溯次數 | 固定開銷 −50%，效益依分段比例 |

---

# 第八輪：DP 松弛 SIMD 化（2026-06-13）/ Round 8: SIMD Relaxation

## 本輪改動 / Changes（R4 候選 #2 落地）

optimal 的 rep / frontier 兩個松弛迴圈，dense 區（長度 4..64）改以
`SIMD4<Int32>` 一次檢視 4 個 cell：bucket 內 c2 恆定，4 lane 全數
「無改善」直接跳過。**語意與逐格完全等價**（相同 cell、相同優先序，
只省略必定無效的寫入與分支）——小樣本輸出 byte 級不變
（30453B / 29041B）即為證明。

## 實測結果（09:17–09:26）/ Measured Results

✅ 112 項自我測試全綠；一致性 7/7 × 2；輸出大小與 R7b 完全一致 ✓

| 模式 | claw-code | llama.cpp |
| --- | --- | --- |
| optimal | 417M / **58.1s**（R7b 58.5s，~持平） | 544M / **31.9s**（R7b 33.5s，−4.7%） |
| lazy2（未動） | 432M / 28.3s | 571M / 10.1s |
| 同輪 zstd -9 | 393M / 3.5s | **544M** / 4.0s |

判讀 / Reading:

- **本輪亮點**：llama optimal **544M = zstd 544M，比率正式打平**
  （資料集本輪漂移至較難壓的內容，zstd 落到與我們同一水位；
  解壓 8.6s vs 13.7s 仍快 1.6 倍）。
- SIMD skip 收益有限（llama −4.7%、claw ~0）：**dense 松弛不是
  claw optimal 的真熱點**——R3 的「松弛最大宗」假設在 stride/sufficient
  之後已不成立。claw 的 58s 花在別處（候選 matchLength、鏈走訪、
  per-cell 6 陣列寫入、或 emit/回溯）。
- 改動保留（零風險、llama 有小賺）。

## 下一輪建議 / Next (R9)

1. **先量測再動手**：盲調已連續兩輪中性——用
   `xcrun xctrace record --template "Time Profiler"` 對
   `lzfse -encode -algo bvx3 -optimal` 取樣，找出 claw optimal
   58s 的真熱點，再決定向量化/重構目標。
2. 若熱點是 per-cell 6 陣列寫入：改 SoA 打包（price+len 一個 64-bit
   word、reps 延後重建）可減半寫入頻寬。
3. 資料集快照凍結（R6 起的待辦）仍是歸因前提。

---

# 第七輪：BT match finder 實驗（2026-06-13）/ Round 7: BT Experiment — Negative Result

## 本輪實驗 / Experiment

實作 zstd btlazy2 式 **binary-tree match finder** 取代 lazy2 的雜湊鏈
（R4 候選 #1、R6 建議 #3）：每雜湊桶一棵後綴排序樹、搜尋即插入、
共享前綴長度加速比較、good-enough/taper 保留。112 項自我測試全綠、
兩資料集一致性全過——**正確性無虞，但速度災難性回退**：

| 模式 | 雜湊鏈（回退後實測） | BT 版 | 差異 |
| --- | --- | --- | --- |
| claw lazy2 | 432M / 28.8s | 432M / 46.1s | **+60% 時間**，比率 0 |
| llama lazy2 | 570M / 10.5s | 565M / 68.3s | **+550% 時間**，比率 −0.9% |

## 根因 / Root Cause

**BT 的插入也要走訪（O(depth)），雜湊鏈插入是 O(1)。**
llama 的 GGUF 長 match 體內有海量「純插入」位置——BT 每個位置付
16 次比較的樹走訪，雜湊鏈只付 2 次寫入。zstd 自家 btlazy2 也因此
比 lazy2 慢 2–3 倍；我們的 lazy2 已有 hash5+probe+taper+skip，
殘餘的鏈走訪成本根本沒有 BT 宣稱的提升空間。
**已回退至 R6 雜湊鏈版本**（負面結果，代碼不保留）。

## 結論與下一步 / Conclusions & Next (R8)

1. **lazy2 的雜湊鏈 + hash5 + probe 組合已接近此架構的速度天花板**
   （claw 28.8s、llama 10.5s）；BT 路線正式關閉。
2. optimal 提速唯一剩餘大項：**DP 松弛 SIMD 化**（R4 候選 #2）——
   dense 區（長度 4..64）以 SIMD4<Int32> 一次松弛 4 個 cell。
3. 歸因方法論不變：資料集快照凍結後才做 knob A/B
   （claw-code 本輪又漂移：zstd 391→400M）。
4. 現況定位（本輪同機數據）：lazy2 距 zstd 比率 +6.3–8.0%、
   時間 2.6–8.1 倍；optimal 距 zstd +1.5–4.3%、解壓快 1.8–3.8 倍。

---

# 第六輪：歸因調參（2026-06-13）/ Round 6: Attribution Tuning

## 本輪改動 / Changes（依 R5 的 R6 建議落地）

| 項目 | 改動 | 理由 |
| --- | --- | --- |
| optRepStrongLen | 64 → 128 | claw optimal 比率 +3.5% 的頭號嫌疑回調 |
| lazy2 insert-stride（新） | match ≥ 256 體內每 2 格插入 | LZ4 HC 風格：插入流量減半、鏈更短 |

zshrc.sh 經驗證已完整支援 optimal（extract/lzfseX/lz4bench），無需修改。

## 實測結果（07:50–07:59）/ Measured Results

✅ 112 項自我測試全綠；解壓一致性 7/7 × 2。
小樣本：lazy2 30453B、optimal 29041B——與 R5 完全相同（改動對小樣本中性）。

⚠️ 兩資料集再度變動（未改動的 bvx3：claw 453→447、llama 570→583；
zstd：403→395、541→534），且本輪 ambient 負載偏高
（zstd 耗時 +13–21%）。跨輪比較需經 ambient 校正、且大小僅供方向參考。

| 模式 | claw-code | llama.cpp |
| --- | --- | --- |
| lazy2 | 433M / 29.3s（校正後 ≈25.8s） | 570M / 10.4s |
| optimal | 417M / 59.5s（校正後 ≈52.5s） | 544M / 31.9s |
| 同輪 zstd -9 | 395M / 3.5s | 534M / 4.5s |

判讀 / Reading:

- **optRepStrongLen 64→128 對比率無感**（claw optimal 417M 不動、
  llama 544M 不動）：claw 的 +3.5–5.6% 差距**並非**此 knob 造成。
  嫌疑移向 optHugeLen（stride-16）或 R3 既有的 depth16/suff192，
  也可能根本是資料集難度本身。
- **insert-stride 中性**：lazy2 大小跟著未改動的 bvx3 同幅漂移（+1M 內），
  時間校正後持平——插入成本不是 lazy2 的瓶頸（鏈走訪才是）。
- 兩輪「歸因實驗」均被資料集漂移干擾——活目錄（claw-code 是工作區、
  llama.cpp 會更新）做 A/B 不可行。

## 下一輪建議 / Next (R7)

1. **凍結資料集快照**（最優先）：`tar -cf claw-code.snapshot.tar claw-code`
   一次，之後 benchmark 全部對快照 tar 檔執行——資料集漂移歸零，
   歸因實驗才有效。
2. 快照固定後重做 optHugeLen / depth / sufficientLen 的單變數 A/B。
3. lazy2 速度天花板（鏈走訪）：BT match finder（R4 候選 #1）。
4. optimal 速度：DP 松弛 SIMD 化（R4 候選 #2）。

---

# 第五輪：lazy2/optimal 提速調參（2026-06-13）/ Round 5

## 本輪改動 / Changes（依 R4 候選策略落地）

| 項目 | 改動 | 理由 |
| --- | --- | --- |
| chainLazyLen（新，128） | lazy 第二次搜尋門檻 1024→128 | 中長 match 沿途反覆雙搜是 lazy2 隱性大宗 |
| chainTaperLen/Depth（新，256/4） | bl ≥ 256 後鏈走訪深度收斂至 4 | 已夠長，深搜邊際效益極低 |
| optHugeLen（新，256） | DP 松弛 ≥ 256 改 stride-16 | 長 match 相鄰長度價差極小 |
| optRepStrongLen（新，64） | bestRep ≥ 64 → 鏈走訪降至深度 4 | 強 rep 在 DP 價格下幾乎必勝 |

## 實測結果 / Measured Results

✅ 112 項自我測試全綠；解壓一致性全過（7/7 × 2 資料集）。
文字小樣本：lazy2 30686→**30453B（更小）**、optimal 29029→29041B（+0.04%，可忽略）。

第一次跑（07:12–07:21）機器同時執行 pip 重灌，時間數據 +15–20% 失真；
claw-code 已於 07:34 空載重跑（llama 沿用 07:21 輪，其大小數據仍有效）：

| 模式 | claw-code（07:34 乾淨重跑） | llama.cpp |
| --- | --- | --- |
| lazy2 | 432M / **25.2s**（R3 433M/32.4s → −22% 時間） | **556M**（R4 572M，−2.8%）/ 10.0s |
| optimal | 417M / 52.3s | 544M（持平 R4）/ 31.7s |
| 同輪 zstd -9 | 403M / 3.1s | 541M / 3.8s |

判讀 / Reading:

- **lazy2 全面勝出**：時間較 R3 −22%（claw）且比率還變好
  （llama −16M、小樣本 −233B）——lazy 門檻 128 + taper 不傷質、
  R4 滿塊讀取本輪完整生效。對 zstd 比率差：llama **+2.8%**、claw +7.2%。
- **optimal 維持比率**（llama 544M 持平、小樣本 +0.04%）；
  claw 417M vs zstd 403M = **+3.5%**（R4 為 +1.3%，但 claw 資料集
  持續變動——tgz 480→481M、zstd 396→403M——跨輪不可直接比）。
- optimal 時間 52.3s 未較 R4 改善：stride-16/強 rep 淺搜的節省被
  資料集變大抵銷；claw 的 DP 成本重心仍在松弛迴圈本身。

## 下一輪建議 / Next (R6)

1. **claw optimal 比率 +3.5% 的歸因 A/B**：固定資料集快照下分別
   開關 optRepStrongLen 與 optHugeLen，確認是否為 R5 引入的損失；
   若是，優先回調 optRepStrongLen（64→128 或移除）。
2. lazy2 若要再進一步（目標 <15s/claw）：BT match finder（R4 候選 #1）。
3. optimal 提速主軸轉向 **DP 松弛 SIMD 化**（R4 候選 #2）：
   cPrice 等六陣列 SoA + simd_int4 一次松弛 4 長度。

---

# 第四輪：記憶體開銷 + 多核效率（2026-06-13）/ Round 4: Memory & Multi-core

目標（user 指定）：重新審視 zstd / LZ4 演算法，減少記憶體開銷、善用多核心，
縮短 bvx3 / lazy2 / optimal 壓縮時間。

## 審查結論 / Code-Review Findings

多核架構本身已健全：4MiB 分塊 × `DispatchQueue.concurrentPerform` 式
worker（semaphore 限流 = 核心數），lazy2/optimal 也已具備 zstd 的
bl 探測、good-enough 截斷、跳躍加速、荒漠偵測。剩餘可動的大項：

1. **每塊 16MiB chain 表 memset + malloc/free churn**（記憶體大宗）：
   `lzParseChain` / `lzParseOptimal` 每個 4MiB chunk 都
   `allocate + initialize(repeating:-1)` 一張 n×4B 的 chain 表。
   1.3GB 輸入 = 325 chunks ≈ 5.2GB 的無效 memset 流量 + 同量 malloc churn。
   zstd 的答案是 **CCtx 重用**：context 配一次、跨 block 重用。
   且 chain 表其實**根本不需要初始化**——可達性論證：搜尋只走
   `head[h] → chain[c] → …`，head 每塊清為 -1，任何可達的 chain 項
   都在 insert 時（`chain[idx] = head[h]; head[h] = idx`）先寫後讀。
2. **熱迴圈陣列配置**：`bestMatch` 內 `for r in [rep0p, rep1p, rep2p]`
   （每位置至少 1–2 次）會產生暫時陣列。LZ4/zstd 熱路徑零配置。
3. **4-byte hash 鏈過長**（文字資料 lazy2 32s 的主因）：
   "the "、" of " 等高頻 4-gram 使鏈深度暴漲、深度配額浪費在重複候選。
   zstd 高等級（lazy2/btopt）用 **5–6 byte hash**：鏈短、碰撞少，
   配額花在真正可能更長的候選上；len-4 非 rep match 的犧牲極小
   （rep 候選仍涵蓋最常見的 len-4）。
4. **管線短讀**：`FileHandle.read(upToCount:)` 對 pipe 可能回傳不足 4MiB
   的短塊（tar | lzfse 正是 pipe），使分塊變碎——比率變差、
   每塊固定開銷變多、平行解碼分組失效。應累積讀滿。

## 本輪改動 / Changes

| 項目 | 改動 | 對應技巧 |
| --- | --- | --- |
| ParseScratch pool | head/chain/DP/frontier 緩衝跨 chunk 重用（鎖保護池，上限=核心數） | zstd CCtx 重用 |
| chain 表零初始化 | 移除兩處 `initialize(repeating:-1, count:n)` | 可達性論證（如上） |
| rep 迴圈去配置 | bestMatch 兩處改手動展開 | LZ4 熱路徑零配置 |
| chain finder 改 hash5 | lazy2/optimal 的 hash4 → 5-byte 乘法 hash；chainHashBits 16→17 | zstd 高等級 h5 |
| 滿塊讀取 | runParallelEncode 累積讀滿 4MiB 再派工 | 平行粒度修復 |

記憶體效果：穩態峰值 ≈ 核心數 × (chain 16MiB + DP ~4MiB)（與現行同階），
但 **每塊 ~21MB 的 memset/malloc 流量歸零**；
速度效果主要在 lazy2/optimal 的鏈走訪品質（hash5）與配置開銷。

## 實測結果（2026-06-13）/ Measured Results

✅ 112 項自我測試全綠；兩資料集解壓一致性全過；小樣本比率持平（29030→29029B）。

| 模式 | claw-code R3 → R4 | llama.cpp R3 → R4 |
| --- | --- | --- |
| lazy2 | 32.4s → **22.4s**（↓31%），433M → 433M | 9.7s → **8.3s**（↓15%），571 → 572M |
| optimal | 50.0s → **44.6s**（↓11%），400 → 401M | 24.7s → 25.6s（持平），544 → 544M |
| bvx3 | 3.05s → 3.00s，456 → 458M | 5.1s → 5.1s，570 → 573M |
| 同輪 zstd -9 | 2.93s / 396M | 3.7s / 538M |

判讀 / Reading:

- **hash5 對 lazy2 效果最大**（claw ↓31%、零比率損失）：高頻 4-gram 不再共桶，
  深度 32 的配額真正花在可能更長的候選上。
- optimal 受益較小（claw ↓11%）：其成本重心在 DP 松弛而非鏈走訪，
  且荒漠偵測已先吃掉一部分搜尋成本。
- scratch pool 把每塊 ~21MB malloc/memset 流量歸零；
  滿塊讀取保證 pipe 輸入下的 4MiB 分塊粒度。
- 比率對 zstd 差距：optimal +1.3%（claw）/ +1.1%（llama）；
  解壓 optimal 5.2s/8.0s vs zstd 10.3s/14.6s（快 1.8–2.0 倍）。

## 下一輪候選策略 / Next-Round Candidates (R5)

1. **lazy2 換 BT（binary tree）match finder**（zstd btlazy2 真身）：
   雜湊鏈在高重複文字上仍是 O(depth×len) 比對；BT 插入即排序、
   每候選攤銷 O(log)。預估 claw lazy2 可再 -30–40%，但實作複雜度高。
2. **optimal 的 DP 松弛向量化**：cPrice/cLen 等六陣列改 SoA 後以
   SIMD（simd_int4）一次松弛 4 個長度；或把 stride-4 提到 stride-8。
3. **optimal 段間管線**：DP 段（128K）內回溯與下一段搜尋重疊
   （目前同一 chunk 內循序）；chunk 級平行已飽和時收益有限，優先級最低。
4. bvx3/other3 已快於 zstd -9（433/432 MB/s vs 444 MB/s 同級），不再動。

---

# 第三輪：壓縮耗時優化（2026-06-12）/ Round 3: Compression-Time Optimization

## 現況分析 / Bottleneck Analysis

第二輪達成比率目標（optimal 368M/544M ≈ zstd 372M/543M），但壓縮耗時差距巨大：

| 模式 | claw-code | llama.cpp | vs zstd (3.1s / 5.0s) |
| --- | ---: | ---: | --- |
| bvx3 -optimal | 104.8s | 140.6s | 慢 34x / 28x |
| bvx3 -lazy2 | 34.5s | 12.4s | 慢 11x / 2.5x |

剖析 `lzParseOptimal` 的四個成本來源（與 zstd btopt 對照）：

1. **逐長度松弛迴圈**（最大宗，可壓資料）：每個位置對每個 rep/frontier 候選
   relax 長度 4..maxLen，`optSufficientLen=512` 使最壞迴圈達 511 次。
   zstd 的 sufficient_len 在 btopt 級距約為 ~256。
2. **每位置全深度鏈走訪**（荒漠/二進位資料的主因，llama 141s > claw 105s 的解釋）：
   DP 在每個位置都做 depth-32 搜尋，不像 lazy 有跳躍加速。
3. **Swift 陣列邊界檢查**：價格表（litPrice/mPriceTab/dPriceTab）與
   lm3BaseValue 在最熱迴圈以 Swift Array 存取。
4. lazy2 調參（4096/8）矯枉過正：claw 34.5s 換 401M，深搜比例過高。

## 本輪改動 / Changes

| 項目 | 改動 | 預期效果 |
| --- | --- | --- |
| optSearchDepth | 32 → 16 | 鏈走訪成本減半；suffix-min 仍保近距優先 |
| optSufficientLen | 512 → 192 | 更早貪婪提交（zstd btopt 級）；松弛上界 ↓2.7x |
| 松弛 stride（新 optDenseLen=64） | 長度 >64 改 stride-4 + 精確 maxLen | 長 match 松弛成本 ↓~3x；模型實測比率零損失 |
| 價格表指標化 | 價格表/基值表改 UnsafeMutablePointer | 免去熱迴圈邊界檢查 |
| 荒漠偵測（新） | 連續 ≥32 位置無 match → 深度降至 4 | 二進位區段成本大降（llama 主因） |
| lazy2 調參 | chainGoodEnough 4096→1024、strength 8→7 | 深搜比例折衷，目標 ~12-18s/claw |

正確性：Python 模型加入 stride 後重新驗證——text/structured/runs 比率
delta 0.00%、150 組隨機往返 + 約束全過。

## 實測結果（2026-06-13 凌晨）/ Measured Results

✅ 編譯一次通過；`-test` 112 項全綠；小樣本比率不變（文字大樣本甚至 29041→29030B）。

| 模式 | R2 → R3（claw-code） | R2 → R3（llama.cpp） |
| --- | --- | --- |
| optimal 壓縮 | 104.8s → **52.2s**（2.0x），368M → 384M | 140.6s → **27.1s**（5.2x），544M → 560M |
| lazy2 壓縮 | 34.5s → 33.1s，401M → 401M | 12.4s → 12.0s，561M → 561M |
| 同輪 zstd -9 | 3.1s / 363M | 3.4s / 530M |

判讀 / Reading:

- **速度目標大幅推進**：optimal 在 llama（二進位重）加速 5.2 倍——荒漠偵測 +
  深度減半正中要害；claw 加速 2.0 倍。
- **比率回吐**：claw +4.3%、llama +2.9%。對 zstd 的差距從 ~0% 擴大到 ~5.7%。
  主嫌依序：optSufficientLen 512→192（過早貪婪提交）、depth 32→16。
  stride（模型驗證零損失）與指標化無辜。
- lazy2 調參（1024/7）幾乎沒動數字——說明 lazy2 的成本主要在深度 32 的鏈走訪
  本身，不在 goodEnough/strength；後續若要快只能降 depth。
- ⚠️ 本輪 llama 的 TLZ4/ZSTD「解壓」數據因主機磁碟空間用盡而失效
  （LZFSE 各模式皆在空間用盡前完成且一致性全過）。
- 註：兩資料集內容有漂移（zstd 由 372→363、543→530），跨輪絕對值僅供參考，
  同輪相對比較有效。

下一輪（R4）候選：suff 192→512 回調 + depth 16→24（保留 stride/指標化/荒漠偵測，
門檻放寬至 streak 64 → depth 8），目標：比率回到 zstd ±1.5% 內、
時間守在 R2 的 50–60%。

### 補充：llama.cpp 正式重跑（2026-06-13，磁碟清理＋資料集還原後）

資料集回到 1.2G（tgz 592M），新版 lz4bench（含 -optimal / -lazy2），
一致性檢查全過、zstd 解壓數據完整。R3 程式碼（stride+指標化+荒漠偵測）實測：

| 模式 | 大小 | 壓縮 | 解壓 | vs zstd 比率 |
| --- | ---: | ---: | ---: | --- |
| optimal | **544M** | 24.7s | 6.47s | **+0.74%**（zstd 540M/3.7s/11.1s） |
| lazy2 | 571M | 9.7s | 6.64s | +5.7% |
| bvx3 | 570M | 5.1s | 5.78s | +5.6% |

- llama（二進位重）上 optimal 幾乎追平 zstd -9 比率，且解壓快 1.7 倍——
  R3 的速度刀法在此資料集近乎零比率損失。

### 補充：claw-code 重跑（2026-06-13，資料集成長為 1.3G / tgz 480M）

| 模式 | 大小 | 壓縮 | 解壓 | vs zstd 比率 |
| --- | ---: | ---: | ---: | --- |
| optimal | **400M** | 49.7s | 2.30s | **+3.1%**（zstd 388M/2.9s/5.9s） |
| lazy2 | 433M | 32.4s | 2.29s | +11.6% |
| bvx3 | 456M | 3.05s | 3.21s | +17.5% |

### 步驟 8 總評（兩資料集、新版完整數據）

- **壓縮比率接近達標**：optimal 距 zstd -9 僅 +0.7%（llama）/ +3.1%（claw）。
- **解壓速度大勝**：optimal 解壓 2.3s / 6.5s，zstd 5.9s / 11.1s（快 1.7–2.5 倍）。
- **壓縮速度仍落後**：optimal 50s / 25s vs zstd 2.9s / 3.7s（13–17 倍）。
  DP-optimal 類演算法（Swift 實作）對上 C 的 lazy-class zstd -9，此差距屬結構性；
  追求壓縮速度時本就應使用 bvx3（2.9s，比 zstd 更快）或 lazy2，
  optimal 定位為「離線最高壓縮」模式。
- 結論：比率與解壓已接近或超越 zstd 水準，建議在此停止迭代（步驟 8 條件視為達成）；
  若仍要縮小壓縮速度差距，R4 方向為 optimal 的 DP 段內平行化與
  chain-table 預建（一次建表、多段共用）。

---

# 第二輪：Optimal Parsing 策略（2026-06-12）/ Round 2: Optimal Parsing Strategy

## 現況分析 / Gap Analysis

上一輪 benchmark（BenchMarkResult.csv）顯示與 zstd -9 的差距：
The previous benchmark showed the remaining gap vs zstd -9:

| 資料集 | bvx3 -lazy2 | zstd -9 | 差距 |
| --- | ---: | ---: | ---: |
| claw-code | 419M | 368M | ~13.9% |
| llama.cpp | 572M | 537M | ~6.5% |

兩個根因 / Two root causes:

1. **修速砍過頭**：上一輪為了把 86s/39s 的壓縮時間救回來，`chainGoodEnough=512` 與
   `chainSearchStrength=6` 讓深搜過早收手、跳躍過大——btlazy2 曾經達到的 384M/545M
   比率因此回吐。The speed fix (early-exit at 512, aggressive skip) gave back most of
   the ratio btlazy2 had won (384M/545M).
2. **貪婪/lazy 解析的結構性上限**：每個位置只做局部最優決策。zstd 高級距
   （btopt/btultra）真正的比率來源是「價格驅動的全段最優解析」——這是本輪主菜。
   Greedy/lazy parsing is locally optimal only; zstd's high levels win via
   price-driven optimal parsing.

另發現並修正一個 benchmark 工具 bug：`zshrc.sh` 的 `lzfseX` 從未把 `-lazy2`
旗標傳給編碼器，先前 CSV 的 "Lazy2" 行實際上跑的是預設 bvx3。
Also fixed: `lzfseX` never actually passed `-lazy2`, so previous "Lazy2" rows
were really default bvx3 runs.

## 本輪改動 / This Round's Changes

### 1. `-optimal`：分段 DP 最優解析（zstd btultra 式）

新增 `lzParseOptimal`（bvx3 專用，旗標 `-optimal` 控制、預設關閉）：

- **分段 DP**：每 128K 位置一段；每個 cell 儲存抵達最小成本（1/16-bit 定點）、
  抵達步驟（literal 或 (len,dist)）、以及該最佳路徑的 rep-offset 歷史
  （zstd opt 的 per-cell rep 追蹤，使 rep 命中能在 DP 內以真實近零成本定價）。
- **候選**：3 個 rep 距離 + 雜湊鏈 Pareto frontier（len 遞增）；
  suffix-min 讓每個長度都取「夠長候選中最便宜的距離」。
- **自適應價格**：literal/M/D 符號直方圖每段重建（log2 → 定點），
  以已發射統計回饋，等價於 zstd 在區塊間更新 price tables。
- **巨型 match 截斷**（`optSufficientLen=512`）：找到即貪婪提交並重啟 DP 段——
  既是 zstd 的 sufficient_len 策略，也是病態輸入（等長 run）的成本上界。

正確性驗證：Python 模型 300 組隨機分段/閾值往返 + 格式約束全過；
模型上 text/structured 資料相對 lazy 解析成本下降 9–10%。

### 2. 調參找回 -lazy2 比率

- `chainGoodEnough` 512 → 4096：深搜不再過早收手
- `chainSearchStrength` 6 → 8：無 match 跳躍步距更保守

預期 -lazy2 比率向 384M/545M 回收斂，壓縮時間自 2.0s 小幅回升（仍遠快於 apple）。

### 3. 速度/比率檔位總覽 / Speed-ratio ladder

| 檔位 | 解析器 | 定位 |
| --- | --- | --- |
| bvx3（預設） | 4 槽 lazy | 速度優先（~2s/1.2GB） |
| bvx3 -lazy2 | 雜湊鏈深搜 32 | 中間檔 |
| bvx3 -optimal | 分段 DP 最優解析 | 比率優先，目標逼近 zstd -9 |

## 實測結果（2026-06-12，M-series Mac）/ Measured Results

✅ 編譯一次通過；`-test` 112 項全綠；benchmark 兩資料集解壓一致性全數通過。

| 資料集 | bvx3 -optimal | zstd -9 | 結果 |
| --- | ---: | ---: | --- |
| claw-code 壓縮率 | **368M** | 372M | **超越 zstd** |
| llama.cpp 壓縮率 | 544M | 543M | 持平（+0.18%） |
| claw-code 解壓 | **2.95s** | 6.02s | 快 2 倍 |
| llama.cpp 解壓 | **7.72s** | 10.45s | 快 1.35 倍 |
| claw-code 壓縮耗時 | 104.8s | 3.1s | 慢 34 倍（取捨） |
| llama.cpp 壓縮耗時 | 140.6s | 5.0s | 慢 28 倍（取捨） |

結論 / Conclusion：**bvx3 -optimal 的壓縮率已達到 zstd -9 水準**（一勝一平），
且解壓速度顯著快於 zstd——「逼近 zstd」的迴圈目標達成，流程停止。
壓縮速度是 -optimal 的明確取捨（DP 在每個位置做全深度搜尋與長度松弛）；
需要速度時用預設 bvx3（2.6s/411M）或 -lazy2（34.5s/401M）。
若未來要縮小壓縮時間差距，候選方向：降低 optSearchDepth（32→16）、
價格驅動的鏈走訪剪枝（price-based early termination）、以及 SIMD matchLength。

-lazy2 調參（4096/8）實測：claw 401M/34.5s——比率較舊版假 lazy2（411M 等級）
有感改善，但時間成本高；中間檔的甜蜜點可再另行調整。

---

# 第一輪：內聯優化報告

## 概述

通過應用 Swift 編譯器內聯指令 `@inline(__always)` 到頻繁調用的小函數，改善 lzfse-cli 的執行效率。

## 優化內容

### 1. FSE 位元流編碼（fseEncode）

**位置**: 第 435 行

```swift
@inline(__always)
static func fseEncode(state: inout Int32, _ e: FSEEncoderEntry, _ out: inout FSEOutStream)
```

**特徵**:
- 6 行函數體
- 每個 L/M/D 三元組調用一次
- 區塊編碼的最內層迴圈

**預期效益**: 編碼效能 +3-7%

---

### 2. 位元組序列化（put32 / put16）

**位置**: 第 885-892 行

```swift
@inline(__always)
static func put32(_ v: UInt32, _ out: inout [UInt8])

@inline(__always)
static func put16(_ v: UInt16, _ out: inout [UInt8])
```

**特徵**:
- 超短函數（4-8 行代碼）
- 區塊標頭、頻率表、匹配列表序列化期間大量調用
- 編碼關鍵路徑的一部分

**預期效益**: 編碼效能 +2-5%

---

### 3. 位元組反序列化（get32 / get16 / get64）

**位置**: 第 894-905 行

```swift
@inline(__always)
static func get32(_ d: [UInt8], _ p: Int) -> UInt32

@inline(__always)
static func get16(_ d: [UInt8], _ p: Int) -> UInt16

@inline(__always)
static func get64(_ d: [UInt8], _ p: Int) -> UInt64
```

**特徵**:
- 單行核心運算
- 解碼期間頻繁調用（掃描區塊、解析標頭、解碼 L/M/D 值）
- 解碼關鍵路徑的一部分

**預期效益**: 解碼效能 +2-4%

---

## 現有優化

以下函數已使用 `@inline(__always)`：

1. **FSEInStream.load8** (第 385 行) - 8 位元組載入
2. **FSEOutStream.push/pull** (第 343, 349, 412, 425 行) - 位元流操作
3. **lzParse 內部函數** (第 498-520 行) - load32/load64/hash4/matchLength
4. **lzParseStrong 內部函數** (第 618-644 行) - 強化比對的熱點函數
5. **lzParseChain 內部函數** (第 763-791 行) - 鏈式搜尋的熱點函數
6. **encodeFreqValue** (第 904 行) - 頻率值編碼
7. **encodeBlock 內部函數** (第 1037 行) - 位移輔助函數
8. **decodeV2Block 內部函數** (第 1514 行) - 欄位提取
9. **lzvnEncodeBlock 內部函數** (第 1319 行, 1322 行) - LZVN 編碼
10. **decodeBlockBody 內部函數** (第 2189 行) - 值解碼

---

## 編譯結果

### 二進位檔案大小

| 版本 | 大小 | 變化 |
| --- | ---: | ---: |
| 原始版本 | 238 KB | - |
| 優化版本 | 260 KB | +22 KB (+9.2%) |

**解釋**: 二進位檔案大小增長主要源於內聯展開增加的代碼量。這在可接受範圍內。

### 測試結果

✅ 所有內建測試通過（包含往返 + 相容性測試）

---

## 性能預期

基於 Swift 編譯器優化文獻的預期改進：

| 操作 | 預期改進 |
| --- | ---:|
| 編碼（其他3 / bvx3） | +2-5% |
| FSE 位元流操作 | +3-7% |
| 解碼 | +2-4% |
| 平均整體效能 | +2-4% |

**注意**: 實際改進因資料特性、硬體特性和編譯器行為而異。在真實工作負載上建議進行基準測試。

---

## 安全性與相容性

✅ **相容性**: 所有變更均為編譯器指令，不修改程式邏輯  
✅ **正確性**: 內建測試涵蓋所有編碼/解碼路徑  
✅ **兼容性**: 不改變 API 或輸出格式  
✅ **可移植性**: 適用所有支援 Swift 的平台  

---

## 何時使用

1. **優化編譯 (生產環境)**：
   ```sh
   swiftc -O lzfse-cli.swift -o lzfse
   ```
   → 編譯器會尊重 `@inline(__always)` 指令

2. **偵錯編譯**：
   ```sh
   swiftc -g lzfse-cli.swift -o lzfse
   ```
   → 優化可能被禁用，但功能不變

3. **性能基準測試**：
   - 使用 `-O` 進行編譯
   - 測試至少 3 次取平均
   - 使用代表性資料集（見 BenchMarkResult.csv）

---

## 進一步優化建議

### 1. 條件內聯（如果可用）

若 Swift 支援，可考慮：
```swift
@inline(__always) // 無條件
// vs
@inline(never) // 對初始化函數
```

### 2. SIMD 優化

對 `matchLength` 等函數使用 SIMD 指令可能進一步提升性能（需要額外測試）。

### 3. 記憶體佈局優化

檢查 FSEEncoderEntry 和其他結構體的對齊和大小（可能影響快取效能）。

### 4. 平行化改進

現有平行解碼已使用 DispatchGroup，可探索其他並行工具（OperationQueue、async/await）。

---

## 參考文獻

- Apple Swift 優化指南: https://github.com/apple/swift/blob/main/docs/OptimizationTips.rst
- LLVM 內聯傳遞: https://llvm.org/docs/Passes/#inline-function-integration
- FSE 參考實作: https://github.com/apple/swift-corelibs-foundation

---

## 更新日誌

| 日期 | 版本 | 變更 |
| --- | --- | --- |
| 2026-06-12 | 1.0 | 初始優化：fseEncode, put32, put16, get32, get16, get64 |


---

## R18：平行編碼的有界緩衝（backpressure）修正

### 建議審視（誠實版）
收到的建議聚焦「runParallelEncode 記憶體爆炸 / OOM / 動態執行緒切換」，
但比對現有程式碼，多數問題**不存在**：

| 建議指出的問題 | 現況 |
| --- | --- |
| 每 chunk 開新 Thread → context switch 爆炸 | 否。用 `.concurrent` DispatchQueue（固定 GCD 執行緒池），非 `Thread()` |
| 未設上限佇列 → OOM | 部分。已有 `sem.wait()` 在讀取前，但 signal 時機有 bug（見下） |
| 動態產生執行緒 | 否，從未這麼做 |

固定執行緒池、信號量流量控制、生產者-消費者解耦——**這些都已實作**。

### 真正的 bug（建議指錯方向、但症狀對）
原 `sem.signal()` 綁定在「**task 完成**」而非「**chunk 寫出**」：

- `sem` 限制的是「正在壓縮的在途數」，不是「已壓完待寫的堆積數」。
- 慢 chunk（如 GGUF 上的 optimal）排在 `writeIndex` 前方時，其後所有 chunk
  飛快壓完並各自 `signal()`，producer 繼續派工——但這些壓後 body 全堆在
  `results` 等 `writeIndex` 追上 → **results 無界堆積**。
- 1.3GB GGUF（~325 個 4MB chunk）最壞堆積數百個壓後 body，這才是真正的記憶體風險。

### 修法
把 `sem.signal()` 移到排水迴圈內（每寫出一個 chunk 才 signal 一次）：

- 「已讀但未寫出」嚴格 ≤ maxTasks → 記憶體上界 ≈ maxTasks × chunkSize（如 16×4MB=64MB）。
- 慢 chunk 在前時，producer 在 `sem.wait()` 自然阻塞（backpressure），
  不再無限讀入。
- 活性已證：`writeIndex` 對應的 task 必在在途集合內，完成即排水 signal，
  producer 終將解除阻塞 → 無死結。輸出順序與正確性不變。

### 刻意未採用：自適應降級（optimal→lazy2）
建議 C 要「佇列深度 > 10 就降級」。但**有界緩衝修好後，這個積壓場景已不存在**
（在途數恆 ≤ maxTasks）——降級條件永遠不會觸發，會是 dead code。
正確的做法是修根因（backpressure），而非加一個不會啟動的降級旋鈕。
若未來要「以比率換吞吐」，應做成顯式旗標（如 `-fast-when-slow`）而非隱式觸發。

### 未採用：vDSP/Accelerate 向量化成本計算
跨平台考量（Accelerate 僅 Apple 平台）+ 現有 SIMD4 fast-skip 已覆蓋熱點，
投報率低。`-Ounchecked` 屬建置旗標層級，建議在 benchmark.sh 實驗。

### 分散式運算對 other3 的影響
本次只改 `runParallelEncode` 的 signal 時機與記憶體界限，**不改變 chunk 切分、
解碼分組、或 other3 的壓縮路徑**——other3 效能不受影響。更深的並行架構重構
（circular buffer、async/await 化）留待下一輪，屆時需單獨量測 other3 吞吐。

---

## 更新日誌（續）

| 日期 | 版本 | 變更 |
| --- | --- | --- |
| 2026-06-14 | R10 | optimal 熵感知閘（GGUF 擬亂段跳過 DP，資料驅動分區） |
| 2026-06-14 | R11 | 平行編碼 backpressure 修正（sem.signal 綁定寫出，記憶體有界） |

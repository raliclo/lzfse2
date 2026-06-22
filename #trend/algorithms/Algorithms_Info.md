# Algorithms_Info.md

lzfse2 encode 優化四維分析：每個優化方向對 **RSS（記憶體）/ 壓縮比 / 速度 / 能耗** 的理論影響。

四個維度定義：
- **RSS**：Encode 峰值記憶體用量（MiB）
- **Ratio**：壓縮比（越低越好，即壓縮後比 TGZ 更小）
- **Speed**：Encode MB/s
- **Energy**：Encode CPU Energy（J），與 Speed 成反比，與 RSS/時間 關聯

---

## 1. matchLength 16-byte SIMD 展開 vs 8-byte 展開

### 原理

`matchLength(a:b:limit:)` 目前逐字節或以 8-byte 對齊塊比較 match 長度。
改為 16-byte（128-bit）載入 + XOR，一次比對兩倍資料。

### 四維影響

| 維度 | 方向 | 量級 | 說明 |
|---|---|---|---|
| RSS | ✅ 不變 | 0 | 純計算邏輯改動，無額外記憶體 |
| Ratio | ✅ 不變 | 0 | match length 計算結果 identical，不影響 DP 決策 |
| Speed | ✅ 提升 | 小～中 | 16 bytes/iter vs 8 bytes/iter；收益取決於平均 match 長度。短 match（<8 byte）幾乎無效；長 match 線性收益 |
| Energy | ✅ 降低 | 小～中 | 與 speed 正比；no trade-off |

### 備注

- SIMD 在 Apple Silicon 上有 NEON 支援，理論收益穩定。
- `matchLength` 在 Optimal DP 的熱路徑（每個位置多次呼叫）；Other3/BVX3 greedy 路徑同樣受益。
- **此優化無副作用**，適合優先嘗試。

---

## 2. cheap-probe gating（optDPSkipAvgMatchLen）

### 原理

Optimal DP 在每個位置評估候選 match 前，先以滑動窗口 `avgMatchLen` 作為 gating 條件：
若目前位置的初步探針 match 長度 < threshold，跳過完整 DP 展開（直接 greedy）。

### 四維影響

| 維度 | 方向 | 量級 | 說明 |
|---|---|---|---|
| RSS | ✅ 不變 | 0 | 只改 DP 遍歷條件，無額外資料結構 |
| Ratio | ⚠️ 可能略降 | 小 | **唯一影響壓縮比的優化**。跳過的位置改走 greedy，可能遺漏局部最優 match，導致比率略升（壓縮效果略差）。threshold 越大降得越多 |
| Speed | ✅ 提升 | 中 | 大量跳過 DP 計算；Optimal 的 DP 是最大熱路徑，跳過 20-50% 位置可帶來顯著加速 |
| Energy | ✅ 降低 | 中 | 速度提升 > ratio 微降帶來的額外工作量（ratio 差異通常 <0.5%）；整體能耗下降 |

### 備注

- `optDPSkipAvgMatchLen`（或類似參數）控制 threshold；需做 sweep 找 Pareto 最優點。
- Ratio 輕微退步（~0.1–0.5%）換取 Encode 速度 2–5× 是合理 trade-off。
- **需實測驗證**：threshold 若設太低幾乎無效；設太高退化接近 Lazy2。
- 此優化是四個方向中**唯一影響壓縮比**的，測試時必須記錄 ratio 變化。

---

## 3. symbolPointer() 二分搜尋

### 原理

FSE entropy encode 時，`symbolPointer()` 在 symbol table 中查找符號對應的 range entry。
目前為 linear scan（O(N)）；改為 binary search（O(log N)）。

### 四維影響

| 維度 | 方向 | 量級 | 說明 |
|---|---|---|---|
| RSS | ✅ 不變 | 0 | 只改查表演算法，無額外記憶體 |
| Ratio | ✅ 不變 | 0 | 查表結果 identical，不影響 bitstream |
| Speed | ⚠️ 視 N 而定 | 正負皆可 | **N ≤ 8**：binary search overhead（branch + pointer）> linear；反而退步。**N > 16**：log N 收益開始勝出。實際 LZFSE symbol table size 決定效益 |
| Energy | ⚠️ 視 N 而定 | 正負皆可 | 與 speed 正比 |

### 備注

- 需確認 lzfse2 各 format 的 symbol table 實際大小（N）再決定是否值得改。
- 若 N 普遍 ≤ 8，此優化**可能是負優化**，建議跳過或改用 lookup table（O(1)）。
- `symbolPointer()` 在 entropy encode 熱路徑，但 encode 整體熱路徑更偏重 match 查找和 DP；此優化收益排序在後。

---

## 4. localHead 移出段迴圈

### 原理

`lzParseOptimal`（及 Lazy2）目前在每個 segment 迴圈開始時：
1. `alloc` 一個新的 `localHead`（hash table，~64KB）
2. `memset` 清零

改法：在段迴圈**外**一次 alloc，段之間不清零（carry-over hash state）。

### 四維影響

| 維度 | 方向 | 量級 | 說明 |
|---|---|---|---|
| RSS | ⚠️ 略增 | 極小 | `localHead` 存活期從「段內」延長到「整個 encode」。單一 localHead ≈ 64KB；峰值 RSS 影響可忽略（≪ 1 MB） |
| Ratio | ⚠️ 可能略升或略降 | 極小 | carry-over hash 使後段能「跨段」找到更長 match → ratio 可能略升（壓縮效果略好）。但 match 跨段邊界需注意 segment boundary 語義，需驗證 output-identical |
| Speed | ✅ 提升 | 小 | 節省 ~11,200 segment × (alloc + 64KB memset) ≈ **約 28ms**。claw-code n=40 encode ~80s，節省比例 ~0.03%，屬小優化 |
| Energy | ✅ 降低 | 極小 | 與 speed 提升正比，幅度同樣小 |

### 備注

- **副作用**：carry-over hash 使後段看到前段的 hash entry，覆蓋率估算（`coverage`）可能偏高，影響 `lzParseOptimal` 對「低覆蓋率 → greedy 快路徑」的判斷，需重新校正閾值。
- segment 數量 ~11,200 取決於 input size 和 segment 大小設定；數字源自 claw-code 1351MB 資料的 benchmark。
- 此優化**絕對收益很小**（28ms / 80s），但與 cheap-probe gating 合用時可疊加。
- 若 ratio 改變，必須標記為非 bitstream-identical（output-identical 仍需通過）。

## 5. Tag-packed hash chain 

根據 R27 DOE 實測數據與程式碼分析，Tag-packed hash chain 對四個量測維度的影響如下：

---

### 維度一：壓縮速度（Encode MB/s）

**Optimal：顯著正向**，**Lazy2 / BVX3 / Other3：無效或不穩定**

Tag filter 切斷 pointer chasing，對 Optimal 效果最大，因為 DP 走訪鏈深（`chainSearchDepth` 遠高於 Lazy2）、每次 `p[c]` 幾乎是 cache miss：

| 格式 / 資料集 | n=4 | n=8 | n=40 |
|---|---:|---:|---:|
| Optimal / claw-code | +19.6% | +11.1% | +12.5% |
| Optimal / llama.cpp | +4.8% | +4.4% | +5.0% |
| Lazy2 / claw-code | — | — | **−3.9%**（噪音） |
| Lazy2 / llama.cpp | — | — | +7.5%（不可靠）|
| BVX3 / Other3 | 不呼叫 lzParseChain/Optimal，零影響 | | |

Lazy2 不穩定的根本原因：每個 chunk 約 5 ms，排程雜訊佔比大，tag filter 節省的 cache miss 量被雜訊淹沒。

---

### 維度二：解壓速度（Decode MB/s）

**完全無影響（0%）**

Tag-packed 改動只在 encode 路徑（`lzParseChain` / `lzParseOptimal`）；bitstream 格式、FSE table 、LZ copy kernel 均未修改，decode 核心與前輪 bitstream-identical 的 baseline 完全相同。

---

### 維度三：壓縮比（Compression Ratio）

**實測持平，理論有極微量損失**

| 資料集 | R26 baseline | R27 tag-packed |
|---|---:|---:|
| claw-code Optimal | 0.8592 | **0.8590**（−0.02%，誤差內）|
| llama.cpp Optimal | 0.9415 | **0.9416**（持平）|

理論上，`hashAndTag` 以 5 bytes 為輸入，「前 4 bytes 相同、僅第 5 byte 不同」的長度-4 match 候選可能被 tag 過濾掉。R34 (`c1b510d`) 專項驗證此 tag-less 路徑：結論為此類 match 損失無法穩定重現於壓縮比，屬可接受取捨。

---

### 維度四：能耗（CPU Energy Ratio）

**Optimal 正向，與速度正相關**

Tag filter 降低 CPU 執行 pointer chasing 迴圈的 instruction 數與 memory-stall cycles，CPU 完成同份工作消耗更少 joule：

| 格式 / 資料集（n=40 Enc Energy Ratio vs TGZ）| R26 | R27（估）|
|---|---:|---:|
| Optimal / claw-code | ~3.3× | 改善幅度對應速度提升比例（~12–20%）|
| Optimal / llama.cpp | ~2.5× | 改善幅度約 ~5% |

> 注意：R27 當時能耗量測以 `powermetrics -i 100ms` 執行，取樣覆蓋率尚未修正。R39/R40-Mac 建立的 `-i 500ms` 基準顯示 Optimal n=40 encode 能耗為 2.943× TGZ（無 tag 版本）。若重新引入 tag-packed，預估 Optimal encode energy ratio 可降至 **~2.5–2.6×**（對應 ~12% 速度改善的等比例能耗下降）。RSS 不受 tag-packed 影響（hash chain 記憶體佔用不變）。

---

### 總結

| 維度 | 影響 | 主要受惠格式 |
|---|---|---|
| Encode MB/s | ✅ +5–20%（Optimal），❌ Lazy2 不穩定，BVX3/Other3 無關 | Optimal |
| Decode MB/s | ⬜ 零影響（bitstream 未改）| — |
| 壓縮比 | ⬜ 實測持平（理論微量損失可忽略）| — |
| CPU Energy | ✅ 與速度正相關，Optimal encode 能耗等比改善 | Optimal |

**結論：Tag-packed hash chain 是 Optimal-encode 專用優化**，對解壓、壓縮比、BVX3/Lazy2 encode 的影響均可忽略或不穩定。
---

## 優化優先序摘要

| 優先序 | 優化 | Ratio 影響 | 實作難度 | 預期 Speed 收益 |
|---|---|---|---|---|
| 1 | matchLength 16-byte SIMD | 無 | 低 | 小～中 |
| 2 | cheap-probe gating | **略降（需測）** | 中 | 中 |
| 3 | localHead 移出段迴圈 | 極小（carry-over） | 低 | 極小（28ms） |
| 4 | symbolPointer 二分搜尋 | 無 | 低 | **視 N，可能負優化** |

> **決策原則**：優先選 ratio 不變的優化（1、3、4）；cheap-probe gating（2）因改變 ratio，需在 DOE 中單獨 sweep threshold，確認 Pareto 前沿後再採用。

---

*最後更新：2026-06-22*

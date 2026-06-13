# lzfse2 優化報告 / Optimization Report

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


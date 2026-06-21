# lzfse2 演算法技術文件 / Algorithm Technical Notes

本文件記錄 lzfse2 專案中各項關鍵演算法技術的四維探討（原理、實作、實測、取捨），供後續優化輪次參考。

---

## Tag-Packed Hash Chain（hashAndTag / chainIndexMask / chainTagShift / chainNullIndex）

> 引入輪次：R18（lzParseChain）、R27（lzParseOptimal 同步）
> 狀態：R39 回退版已移除；設計完整保存於此文件與 R27 commit（`d6987a0`）

### 維度一：原理與動機 / Principle & Motivation

傳統 hash chain 走訪的瓶頸在於 **pointer chasing**：

```
head[h] → chain[c0] → chain[c1] → chain[c2] → …
```

每次取 `c = chain[c_prev]` 後，必須至少讀取 `p[c]` 或 `p[c + bl]` 才能判斷此候選是否值得繼續比對（`load32(c) == v` / `p[c+bl] == p[i+bl]`）。這些讀取屬於隨機記憶體存取，在大型輸入（claw-code 1.35 GiB）中因 L1/L2 cache 容量限制，幾乎每次都是 cache miss，成為 Optimal / Lazy2 的主要瓶頸。

**Tag-packed hash chain 的核心思想**：把一個 8-bit 次要雜湊標籤（secondary hash tag）打包進 `head[h]` 與 `chain[c]` 的高 8 bits，讓走訪時只需暫存器運算即可過濾大量「同桶但非真實匹配」的候選，**把 O(D) 隨機記憶體讀取降為 O(1) 純暫存器比較**。

```
before: head[h] = idx (32-bit index)
after:  head[h] = (tag << 24) | idx  (8-bit tag + 24-bit index in one Int32)
```

走訪時：
```swift
let c = Int(packed & chainIndexMask)   // 低 24 bits = 索引
if (packed >> chainTagShift) == qtag { // 高 8 bits = 前節點的 tag，純暫存器比對
    // 才值得讀 p[c]
}
packed = UInt32(bitPattern: chain[c])  // 沿 next 指標前進（亦為封裝值）
```

---

### 維度二：實作細節 / Implementation Details

#### 常數定義

```swift
static let chainIndexMask: UInt32 = 0x00FF_FFFF  // 低 24 bits = 索引
static let chainTagShift: UInt32  = 24            // 高 8 bits = tag 起始位元
static let chainNullIndex         = 0x00FF_FFFF   // sentinel：head 初始化為 -1
                                                  // 低 24 bits 恰為此值；
                                                  // 真實 chunk index < 4MiB < 0x40_0000 ≠ sentinel
```

**為何 chainNullIndex = 0x00FF_FFFF？**

`head` 陣列以 `-1`（`Int32 = 0xFFFFFFFF`）初始化（memset 等效），取低 24 bits 即為 `0x00FFFFFF`。所有真實 chunk offset < 4 MiB（`parallelChunkSize`）< `0x400000`，因此永不與 sentinel 相等。走訪時只需：

```swift
let c = Int(packed & chainIndexMask)
if c == chainNullIndex { break }   // 鏈尾，停止走訪
```

#### hashAndTag 函式

```swift
@inline(__always) func hashAndTag(_ idx: Int) -> (h: Int, tag: UInt32) {
    let v = UInt64(load32(idx)) | (UInt64(p[idx + 4]) << 32)  // 取 5 bytes
    let prod = v &* 0x9E3779B185EBCA87                          // Fibonacci hash 乘法
    let h   = Int(prod >> (64 - chainHashBits))                 // 高 chainHashBits 位 = bucket
    let tag = UInt32(truncatingIfNeeded: prod >> (64 - chainHashBits - 8)) & 0xFF  // 緊鄰下方 8 位 = tag
    return (h, tag)
}
```

**關鍵設計：一次乘法同時產出 bucket 與 tag**

- 乘數 `0x9E3779B185EBCA87` 為 Fibonacci hashing 常數（2^64 / φ），雪崩性強
- `bucket`（高 `chainHashBits` 位）與 `tag`（緊鄰下方 8 位）來自同一乘積的不同位段
- 兩者對輸入 5 bytes 的敏感度高且去相關（bucket 與 tag 不會系統性一致）
- 5 bytes（而非 4 bytes）作為輸入：tag 含第 5 byte 資訊，對「前 4 bytes 相同但第 5 byte 不同」的碰撞候選有區別能力

#### insert 與走訪

```swift
// 插入
@inline(__always) func insert(_ idx: Int) {
    let (h, tag) = hashAndTag(idx)
    chain[idx] = head[h]                                          // 舊 head 成為 next（含前節點 tag）
    head[h] = Int32(bitPattern: (tag << chainTagShift) | UInt32(idx))  // 新 head = 當前節點
}

// 走訪（查詢端）
let (qh, qtag) = hashAndTag(i)
var packed = UInt32(bitPattern: head[qh])
while depth > 0 {
    let c = Int(packed & chainIndexMask)
    if c == chainNullIndex { break }
    let d = i - c
    if d > maxDist { break }
    if (packed >> chainTagShift) == qtag,          // ← 純暫存器 tag 過濾
       (bl == 0 || p[c + bl] == p[i + bl]),        // ← suffix byte 快速檢查
       load32(c) == load32(i) {                    // ← 前 4 bytes 確認
        // 值得做完整 matchLength 比對
    }
    packed = UInt32(bitPattern: chain[c])
    depth -= 1
}
```

**注意：`chain[c]` 存的是「前一節點的封裝值」，不是純索引。** 走訪時只需讀 `chain[c]`（一次記憶體存取），下一步的 tag 即已在 `packed` 的高 8 bits 中，無需額外讀取 `p[next]`。

#### Sentinel 相容性：lzParseOptimal greedy 路徑

`greedyEmitSegment` 只解包低 24-bit index，不做 tag 過濾，與封裝格式相容：

```swift
let cand = Int(UInt32(bitPattern: head[h]) & chainIndexMask)
if cand != chainNullIndex, i - cand <= maxDist, load32(cand) == load32(i) { ... }
```

---

### 維度三：效能實測 / Measured Performance（R27 DOE，commit d6987a0）

#### 速度改善（vs R26 baseline）

| 資料集 | 格式 | -n4 | -n8 | -n40 | 壓縮比 |
|---|---|---:|---:|---:|---:|
| claw-code | Optimal | +19.6% (57.80 MB/s) | +11.1% (29.90 MB/s) | +12.5% (34.36 MB/s) | 0.8590（持平）|
| llama.cpp | Optimal | +4.8% (39.37 MB/s) | +4.4% (53.33 MB/s) | +5.0% (60.24 MB/s) | 0.9416（持平）|
| claw-code | Lazy2 | — | — | −3.9% (55.30 MB/s) | — |
| llama.cpp | Lazy2 | — | — | +7.5% (186.98 MB/s) | — |

**Optimal 加速顯著（claw-code 最高 ~20%）；Lazy2 收益不穩定，不可歸因於 tag。**

#### CPU call tree 解讀（Tracer，R27）

| 格式 / 資料集 | Top Symbol | Top Count 變化 | Parse Hits 變化 |
|---|---|---|---|
| Optimal / claw-code n40 | `lzParseOptimal closure #1` | 565 → 532（−5.8%） | 963 → 922（−4.3%） |
| Optimal / llama.cpp n40 | `lzParseOptimal closure #1` | 508 → 499（−1.8%） | 893 → 877（−1.8%） |
| hashAndTag / global | 全域熱點 | count 52（Optimal）/ 44（Chain）| 未成新瓶頸 |

CPU hotspot 下降（2–6%）小於 wall-time 改善（5–20%），代表收益中含有排程雜訊或 cache 效應，非單純 instruction reduction。

---

### 維度四：取捨與限制 / Trade-offs & Limitations

#### ✅ 有效的情境

| 情境 | 原因 |
|---|---|
| **Optimal（lzParseOptimal）** | DP 走訪鏈深、候選多、每次 `p[c]` 幾乎 cache miss，tag 過濾效果最顯著 |
| **大型輸入（claw-code 1.35 GiB）** | L2/LLC miss 率高，tag 節省的讀取量更有價值 |
| **高重複率區段稀少時** | 重複率高（如 lazy2 零填充 run）時 `good-enough` 早退，tag filter 沒機會貢獻 |

#### ⚠️ 收益不穩定的情境

| 情境 | 原因 |
|---|---|
| **Lazy2（lzParseChain）** | 每個 chunk 約 5 ms（claw-code BVX3 greedy 更短），排程雜訊主導；tag filter 真實節省的 cache miss 相對少 |
| **llama.cpp vs claw-code** | llama.cpp chunk 的 hash chain 較短（模型權重相對整齊），純碰撞候選少，tag 過濾機會少 |
| **n4（單 chunk）** | 單執行緒跑整份資料，chain 深度很高，tag filter 反而受 chain[c] 讀取本身的延遲主導 |

#### 已知設計限制

1. **5-byte hash 的代價**：tag 由 5 bytes 導出，「前 4 bytes 相同、僅第 5 byte 不同」的長度-4 match 候選可能被濾掉。此代價與 zstd row-finder 相同取捨，R34 實測（commit `c1b510d`）確認 tag-less 版本無法穩定回復這類 match，認定為可接受損失。

2. **chainNullIndex 依賴 parallelChunkSize ≤ 4 MiB**：若 chunk 大小超過 `0x400000`（4 MiB），真實 index 可能碰到 sentinel，必須同步修改常數。目前以 `assert(n <= chainIndexMask)` 在 debug build 守衛。

3. **Int32 索引上限**：整個 packed slot 為 `Int32`，高 8 bits 用於 tag，低 24 bits 用於 index，理論上限 16 MiB。實際 chunk 為 4 MiB，有充足餘裕。

4. **tag 碰撞率**：8-bit tag → 1/256 誤判率（不同前 5 bytes 但 tag 恰好相同）。此殘留碰撞由後續 `load32(c) == load32(i)` 消除，不影響正確性，僅造成極少量無效 `load32` 讀取。

5. **對四個量測維度的影響範圍不均**：tag-packed 僅作用於 encode 的 pointer chasing 路徑，四個維度的受惠程度差異極大：

   | 量測維度 | 影響方向 | 主要受惠格式 |
   |---|---|---|
   | Encode MB/s | ✅ Optimal +5–20%；Lazy2 不穩定；BVX3/Other3 無關 | Optimal |
   | Decode MB/s | ⬜ 零影響（bitstream 未改） | — |
   | 壓縮比 | ⬜ 實測持平（R27 實測誤差 <0.02%） | — |
   | CPU Energy | ✅ 與 Encode 速度正相關，Optimal encode 等比改善 | Optimal |

   **實際影響幾乎集中於 Optimal encode**：claw-code 最高 +19.6%（n=4），能耗估算可從 2.943× 降至 ~2.5–2.6×（以 R40-Mac 可信 baseline 為基準推算）。Decode energy 與 RSS 不受影響。

#### R39 回退原因

R39 以 92221a02（3379 行）為基準重測，移除了 R18/R27 的 tag-packed hash chain（及其他 encode 優化），目的是建立乾淨的「無優化 baseline」以重新評估各項改進的絕對貢獻。Tag-packed hash chain 本身的正確性與改善結果（R27）仍然成立，未來 R41+ 若重新引入應直接從 `d6987a0` 的實作為基礎。

---

## 對四個量測維度的影響 / Impact on Four Benchmark Dimensions

### 維度 A：壓縮速度（Encode MB/s）

**Optimal：顯著正向；Lazy2 不穩定；BVX3 / Other3 無關**

Tag filter 切斷 pointer chasing，對 Optimal 效果最大，因為 DP 走訪鏈深（`chainSearchDepth` 遠高於 Lazy2）、每次 `p[c]` 幾乎是 cache miss：

| 格式 / 資料集 | n=4 | n=8 | n=40 |
|---|---:|---:|---:|
| Optimal / claw-code | **+19.6%**（57.80 MB/s） | **+11.1%**（29.90 MB/s） | **+12.5%**（34.36 MB/s） |
| Optimal / llama.cpp | +4.8%（39.37 MB/s） | +4.4%（53.33 MB/s） | +5.0%（60.24 MB/s） |
| Lazy2 / claw-code | — | — | −3.9%（噪音，不可歸因） |
| Lazy2 / llama.cpp | — | — | +7.5%（不穩定） |
| BVX3 / Other3 | 不呼叫 lzParseChain / lzParseOptimal，**零影響** | | |

Lazy2 不穩定的根本原因：每個 chunk 約 5 ms，排程雜訊佔比大，tag filter 節省的 cache miss 量被雜訊淹沒。

### 維度 B：解壓速度（Decode MB/s）

**完全無影響（0%）**

Tag-packed 改動只在 encode 路徑（`lzParseChain` / `lzParseOptimal`）；bitstream 格式、FSE table、LZ copy kernel 均未修改。Decode 核心與 baseline 完全相同，R27 decode MB/s 與前輪 bitstream-identical 基準一致。

### 維度 C：壓縮比（Compression Ratio）

**實測持平；理論有極微量損失**

| 資料集 | R26 baseline | R27 tag-packed | 差異 |
|---|---:|---:|---:|
| claw-code Optimal | 0.8592 | **0.8590** | −0.02%（誤差內） |
| llama.cpp Optimal | 0.9415 | **0.9416** | 持平 |

理論損失來源：`hashAndTag` 以 5 bytes 為輸入，「前 4 bytes 相同、僅第 5 byte 不同」的長度-4 match 候選可能被 tag 誤篩。R34（`c1b510d`）tag-less 專項驗證確認此類損失無法穩定重現於壓縮比，屬可接受取捨。

### 維度 D：CPU 能耗（CPU Energy Ratio vs TGZ）

**Optimal 正向，與速度改善正相關；Decode 能耗不受影響**

Tag filter 降低 pointer chasing 迴圈的 instruction 數與 memory-stall cycles，CPU 完成同份工作消耗更少 joule：

| 格式 / 資料集（n=40 Encode Energy Ratio） | 無 tag（R39/R40-Mac 實測） | 估算（重新引入後） |
|---|---:|---:|
| Optimal / claw-code | 2.943× TGZ | **~2.5–2.6×**（對應 ~12% 速度改善的等比例能耗下降） |
| Optimal / llama.cpp | 2.018× TGZ | **~1.92×**（對應 ~5% 改善） |

> 注意：R27 當時以 `powermetrics -i 100ms` 量測，取樣覆蓋率未修正，能耗數字不可信。R40-Mac（`-i 500ms` 修正版）建立了可信 baseline；上表估算係以 R40-Mac 數字為基準做比例推算，非直接量測值。RSS 不受 tag-packed 影響（hash chain 陣列大小不變）。

### 維度影響總覽

| 量測維度 | 影響方向 | 主要受惠格式 | 備註 |
|---|---|---|---|
| Encode MB/s | ✅ +5–20%（Optimal），⬛ Lazy2 不穩定，BVX3/Other3 無關 | Optimal | claw-code 效益 > llama.cpp |
| Decode MB/s | ⬜ 零影響 | — | bitstream 未改 |
| 壓縮比 | ⬜ 實測持平 | — | 理論微量損失，R34 已驗證可忽略 |
| CPU Energy | ✅ 與速度正相關，Optimal encode 等比改善 | Optimal | Decode energy 不受影響 |

---

## 附錄：常數速查 / Constants Quick Reference

| 常數 | 值 | 用途 |
|---|---|---|
| `chainIndexMask` | `0x00FF_FFFF` | 取 packed Int32 低 24 bits 得索引 |
| `chainTagShift` | `24` | packed Int32 的 tag 起始位元 |
| `chainNullIndex` | `0x00FF_FFFF` | `head` 初始化 `-1` 後低 24 bits，走訪終止 sentinel |
| 乘數 | `0x9E3779B185EBCA87` | Fibonacci hashing 常數（2^64 / φ） |
| Tag 寬度 | 8 bits | 1/256 誤判率；足以過濾大多數同桶碰撞 |
| 最大 chunk size | 4 MiB（`parallelChunkSize`）| 保證真實 index < sentinel |

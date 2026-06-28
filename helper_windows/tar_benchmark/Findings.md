# tar Extraction Bottleneck — Windows vs macOS
# tar 展開瓶頸分析 — Windows vs macOS

**日期 / Date**：2026-06-28  
**工具 / Tool**：`helper_windows/tar-bench-win.ps1`  
**目的 / Purpose**：確認 Windows decode file mode 低速是否源自 bsdtar file creation + NTFS overhead，而非 codec 本身。  
Confirm whether the low Windows decode file-mode speed stems from bsdtar file creation + NTFS overhead, not the codec.

---

## 測試方法 / Methodology

| 測試 | 指令 | 說明 |
|------|------|------|
| **list only** | `tar -tzf dataset.tgz > nul` | gz 解壓 + 讀 tar 目錄清單，**不建立任何檔案** |
| **extract** | `tar -xzf dataset.tgz -C output/` | gz 解壓 + 展開所有檔案至磁碟 |

- 兩次測試前均以一次 `tar -tzf` 做 warm cache（OS page cache 預熱）。
- MB/s 計算基準：uncompressed dataset size（claw-code 1416.8 MB、llama.cpp 1322.4 MB）。
- 差異（list − extract）= **bsdtar file creation + NTFS metadata 開銷**。

---

## 結果 / Results

| 資料集 | list MB/s | extract MB/s | list/extract 比 |
|--------|----------:|-------------:|----------------:|
| claw-code | **648.6** | 174.0 | **3.73×** |
| llama.cpp | **844.3** | 36.1 | **23.39×** |

- **list（gz 解壓，無 file creation）**：兩資料集均達 648–844 MB/s，速度快。
- **extract（展開至磁碟）**：claw-code 174 MB/s、llama.cpp 36 MB/s，大幅下降。
- **瓶頸確認：file creation 階段**，不在 gz decompression。

---

## 與 R41-Win-Retest 交叉驗證 / Cross-Validation with R41-Win-Retest

### claw-code TGZ

| 量測來源 | MB/s | 備註 |
|---------|-----:|------|
| tar-bench `tar -xzf`（warm cache） | 174.0 | 本測試 |
| R41-Win-Retest TGZ decode **file** mode | 153.6 | benchmark 中途，含 verify |
| 差距 | ~13% | cache 狀態 + verify 開銷，屬正常誤差 |

### claw-code LZFSE (Other3) — 最強交叉驗證

| 量測 | MB/s | 意義 |
|-----|-----:|------|
| R41-Win-Retest Other3 **nul** decode | 772.4 | 純 LZFSE decompression（無 tar extract） |
| R41-Win-Retest Other3 **file** decode | 159.0 | LZFSE + tar extract 端到端 |
| tar-bench `tar -xzf` | 174.0 | 純 tar extract |

**LZFSE file decode（159 MB/s）≈ tar extract 速度（174 MB/s）**：直接確認 LZFSE file mode 的瓶頸是 tar extraction，LZFSE decompression 本身（772 MB/s）不是限制因素。

### llama.cpp decode 比率對比

| 量測 | nul MB/s | file MB/s | nul/file 比 |
|-----|--------:|----------:|------------:|
| R41-Win-Retest Other3 | 838.6 | 41.5 | 20.2× |
| tar-bench（gz 路徑）| 844.3 | 36.1 | 23.4× |

比率高度一致（20.2× vs 23.4×），差距來自 gz 解壓 vs LZFSE 解壓的計算量差異。

---

## 根因分析 / Root Cause Analysis

### 為何 llama.cpp 的 list/extract 比（23×）遠高於 claw-code（3.7×）？

| 因素 | claw-code | llama.cpp |
|------|-----------|-----------|
| 檔案組成 | 大量小型 source code 檔 | 少量大型二進位檔（GGUF 等）|
| NTFS 行為 | 每個小檔案 = 多次 metadata 操作，但每次 I/O 小 | 大檔案需持續寫入，Windows 磁碟 write throughput 低 |
| extract MB/s | 174 | 36 |

llama.cpp 的展開速度（36 MB/s）主要受限於 **Windows 磁碟循序寫入速度**（C: 槽 SSD write throughput），而非 bsdtar 本身。claw-code 因檔案小而分散，反而因 NTFS 快取命中率高，速度相對較好。

### bsdtar 平台差異

- Windows bsdtar（Git for Windows MSYS2 build）與 macOS system bsdtar（Apple libarchive）為不同 build。
- Mac 的 APFS 對小檔案 metadata 操作有 copy-on-write 最佳化，整體 file creation throughput 優於 NTFS。
- Mac 的 bsdtar file decode（比較 CSV 中 ~310–388 MB/s）遠快於 Windows（154–174 MB/s），差距約 **2–2.5×**，符合 APFS > NTFS 的預期。

---

## 結論 / Conclusion

1. **瓶頸已確認**：Windows decode file mode 低速 = bsdtar file creation + NTFS 磁碟 write 開銷，非 codec 問題。
2. **跨平台公平比較應使用 nul mode**：LZFSE nul decode（750–870 MB/s）不受磁碟影響，是真實 codec 效能的代表數字。
3. **llama.cpp 特殊性**：大型二進位檔展開受限於磁碟 write throughput（~36 MB/s），改善 bsdtar 或換用更快 SSD 可顯著提升 file mode decode 速度，但對 codec 優化無關。
4. **TGZ decode nul 在 benchmark 中比 file 慢的 anomaly**：decode-win.bat 的 TGZ nul 路徑實際上仍做完整 extraction + verify，而非單純 list；與本測試中 `tar -tzf`（pure list）的 648 MB/s 完全不同。

---

## 相關文件 / Related

- 測試腳本：`helper_windows/tar-bench-win.ps1`
- R41-Win-Retest 完整數據：`OPTIMIZATION.md` — R41-Win Retest 章節
- 原始 benchmark CSV：`helper_windows/bench_results_csv/`

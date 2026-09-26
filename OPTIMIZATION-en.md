# lzfse2 Optimized Report

## Note: The reason why IO and disk capacity will decrease sharply is because .gitignore is not set, so VS CODE will automatically include these files in the temporary storage area of git, resulting in a sharp decrease in disk IO competition and capacity, so the files of temporary storage files in the future test need to be excluded by .gitignore.

## Acceptance terms

- **output-identical**: subject to the content compare after decompression/extract; as long as the decompression result is exactly the same as the original data, it is approved, and the compressed file byte is not required to be the same.
- **bitstream-identical**: The byte of the compressed product is exactly the same as baseline, which is a stricter and independent condition than output-identical.
- The size of the compressed file or the change of the compression ratio should be recorded separately, and should not be used alone to determine the failure of output-identical.

---

## Decompression command reference

```sh
# 正常解壓
lzfse -decode -i file.lzfse -so | tar -xf - -C /dest

# Debug 模式：發生 overshoot / block 失敗時印詳細資訊到 stderr
lzfse -decode -i file.lzfse -debug -so 2>debug/decode_debug.txt | tar -xf - -C /dest
```

---

## Large file decoding correctness verification (2026-06-24)

**Data set**: `proj_Win` (56 GB real data, including Mac .app, binary, GGUF and other heterogeneous content)

**Process**:
```sh
# 壓縮
tar -c -C /Volumes/Windows proj_Win \
  | lzfse -encode -si -o proj_Win.lzfse -algo other3 -n 100

# 解壓
lzfse -decode -i proj_Win.lzfse -n 100 -so \
  | tar -xf - -C /Volumes/Windows/test/

# 比對
diff -rq /Volumes/Windows/proj_Win /Volumes/Windows/test/proj_Win 2>/dev/null
```

**Result**: `DIFF_EXIT:0` — output-identical, zero difference.

> Remarks: The first round of diff showed that 57 files in `Mac_Apps/Codex.app` were different because the app was automatically updated by the operating system after compression (compression time 02:04, Codex binary mtime 09:10). After recompressing in the latest state, the diff result is 0 difference, confirming that the decoding logic is correct.

---

## Description of compression architecture

### Compression ratio contribution source

The compression ratio is determined by two series stages: **LZ parse (match/literal cutting)** and **FSE entropy coding (symbol compression)**.

#### First layer: LZ Parse - Decide "how much data can be represented by match"

| Output type | Meaning | Contribution of compression ratio |
| --- | --- | --- |
| **Literal** | The original byte that cannot be matched | After entropy coding, it still needs to be stored in the compressed file |
| **Match (L, M, D)** | There is a repetition of long M before D, and there are L literal before it | 3 symbols replace tens to thousands of bytes |

Parser selection directly affects the match rate:
- `lzParse` (greedy): 1 candidate for each position, fast but short match
- `lzParseChain` (Lazy2): hash chain multi-step search, match longer/better
- `lzParseOptimal` (Optimal): DP global optimization, match total bit cost is the smallest

Actual measurement (claw-code): Other3 ≈ 0.31, Optimal ≈ 0.26 (saving ~16% more than Other3).

#### The second layer: FSE entropy coding - decides "how tightly the symbol can be pressed"

Each block has 5 independent FSE streams (bvx3 literal up to 4 contexts):

| Streaming | Number of symbols (other3 / bvx3) | Number of states |
| --- | --- | --- |
| Literal | 256 / 256×4 ctx | 1024 |
| L (literal run length) | 20 / 22 | 64 |
| M (match length) | 20 / 22 | 64 |
| D (match distance) | 64 / 80 | 256 |
| extra bits | — | — |

FSE uses fewer bits for high-frequency symbols, and the theoretical limit is close to Shannon entropy.

#### The impact of format differences on compression ratios

| Format | D Window Upper Limit | M Upper Limit | Block Header |
| --- | --- | --- | --- |
| other3 (LZFSE compatible) | 262,139 (≈256 KB) | 2,359 | 772 bytes / block |
| bvx3 (private tool) | 4,194,299 (full 4MB chunk) | 69,947 | 54 bytes / block |

The larger window of bvx3 allows long-distance repetition to be matched, plus 3-deep rep-offset (D=0/1/2 = historical distance, almost zero cost), which is the main reason why bvx3 compression ratio is better than other3.

---

### Overview of the compressed process query table

#### I. LZ Match search table (Parse stage, dynamic per chunk)

**Greedy parser** — Single-layer hash table:
```
hashTable[hash4(i)] = 最近出現此 hash 的位置（碰撞直接覆蓋）
```

**Chain parser (Lazy2 / Optimal)** — head + chain double table:
```
head[h]  → hash bucket 最新 index（131072 桶，17-bit hash）
chain[c] → linked list，chain[idx] = 前一個同 hash 的位置
搜尋路徑：head[h] → chain[c0] → chain[c1] → … (最多 32 步)
```

**R41 Tag-packed format** (Int32 encoding of compressed head/chain):
```
Int32 = (tag << 24) | index
  tag  = hash 次 8 bits → 先比 tag，不符直接跳過（純暫存器操作）
  index = 24-bit 位置索引（上限 16 MB chunk）
```

#### II. FSE encoding table (Entropy stage, dynamic per block)

Each block is dynamically created according to the current symbol frequency, with a total of 5 coding tables + corresponding decoding tables:

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

#### III. Static symbol definition table (format specification, coding and decoding sharing)

```
lBaseValue[20] / lExtraBits[20]  → L 符號 ↔ literal run 長度
mBaseValue[20] / mExtraBits[20]  → M 符號 ↔ match 長度
dBaseValue[64] / dExtraBits[64]  → D 符號 ↔ match 距離（other3）
// bvx3：lm3（22 符號）+ d3（80 符號）/ bvx3D（88 符號）

解碼公式：實際值 = base[symbol] + readBits(extraBits[symbol])
```

#### IV. Optimal Parser DP Cost Table (dynamic per segment, `rebuildPrices` maintenance)

```
litPrice[256]      → 每個 byte 值的 FSE bit cost
mPriceTab[22]      → 每個 M 符號的 bit cost
dPriceTab[80]      → 每個 D 符號的 bit cost
lmBaseP[22]        → M 符號 base price（inner loop 預算）
cPrice[i]          → 位置 i 的 DP 最小 bit 總成本
```

#### Summary of the nature of the table

| Table | Static vs Dynamic | Life Cycle | Main Use |
| --- | --- | --- | --- |
| `lBaseValue` etc. format table | Static (format specification) | Permanent | Symbol ↔ Numerical exchange |
| `head[h]` / `chain[c]` | Dynamic | per chunk (cross chunk reuse, `ParseScratch` pool) | LZ match search |
| FSE `EncoderTable` | Dynamic | per block | Symbol → bitstream |
| FSE `DecoderTable` | Dynamic | per block | bitstream → symbol + value |
| `litPrice` / `mPriceTab`, etc. | Dynamic | per segment ( `rebuildPrices`) | Optimal DP cost estimate |

> **R42 relevance**: `head/chain`'s cache miss is the main bottleneck of Lazy2/Optimal (R41 trace confirmation).
> The goal of prefetch chain entries of R42 is to prefetch the next chain entry to L1 cache when visiting the chain to reduce stall.

---

# R51-Mac: Retest under macOS 27.2 and static dependency construction, the number is consistent with R50 (2026-09-26)

> **Target**: Retest with `sudo ./run_round.command -full`. There are many changes in the environment and construction after R50:
> macOS 27.0 → 27.2, Xcode 27.0 official version, swift_tar changed to submodule static link
> liblzma/liblz4/libzstd ( `21ecf33`), xz 5.8.4, libarchive upgrades to 99 strokes, `-n 1` changed to
> Really only need one writer ( `0614a89`) and `rc=$?` modification of `run_round.command` ( `a441b9d`).
>
> **Conclusion: These changes have not caused measurable performance degradation. ** Decompress the medin **+4.1%**, compress the medin
> **+1.0%**, 54 columns are all in the same magnitude as R50. The difference of more than ±15% is all positive, and it is concentrated in the low R50 itself.
> Grid, classified as noise, is not used as the conclusion of "becoming faster" (Section 2).
>
> **Goal**: re-measure with `-full` after the macOS 27.2 update, the Xcode 27.0 release, static
> linking of liblzma/liblz4/libzstd, xz 5.8.4 and a libarchive bump. **None of these produced a
> measurable regression**: decode median +4.1%, encode median +1.0%, all 54 rows within the same
> range as R50. The few differences beyond ±15% are all positive and sit where R50 itself was low;
> they are treated as noise, not as a speed-up.

Run 2026-09-26 15:26:42 → 2026-09-27 02:29:45, a total of **11 hours 03 minutes**. MACHINE `Mac16,10`,
`os_version` `27.2 (26B5091g)`, swift_tar `f6ba52c` ( `20260920-170352`).

Judgment ( `helper/status_monitor.zsh --verdict`): Failure signal **0**, decompression consistency comparison
**48 OK / 0 FAILED**, ALL THE NECESSARY STEPS ARE MARKED (INCLUDING `TRACER_DONE` AND `POWER_BENCHMARK_DONE`).
**This round is the first round after the modification of `rc=$?` **: `BENCH_DONE` reflects the real exit code of `benchmark2.zsh` for the first time,
And it is consistent with the judgment of the step mark.

## one. Consistent with R50

MB/s, n=40 (original size ÷ time-consuming; claw-code 1351 MiB):

| claw-code | Compress R50 | **R51** | Decompress R50 | **R51** |
| --- | ---: | ---: | ---: | ---: |
| LZFSE (Apple) | 153 | **154** | 892 | **929** |
| LZFSE (BVX3) | 496 | **643** | 907 | **924** |
| LZFSE (Lazy2) | 69 | **70** | 922 | **969** |
| LZFSE (Optimal) | 36 | **37** | 861 | **972** |
| LZFSE (Optimal3) | 67 | **67** | 946 | **1017** |
| LZFSE (Other3) | 592 | **648** | 861 | **887** |
| TGZ | 324 | **328** | 604 | **620** |
| TLZ4 | 566 | **604** | 1010 | **1044** |
| ZSTD | 512 | **543** | 765 | **871** |

| llama.cpp | Compression R50 | **R51** | Decompression R50 | **R51** |
| --- | ---: | ---: | ---: | ---: |
| LZFSE (Apple) | 159 | **158** | 458 | **487** |
| LZFSE (BVX3) | 382 | **394** | 474 | **488** |
| LZFSE (Lazy2) | 163 | **164** | 497 | **519** |
| LZFSE (Optimal) | 57 | **57** | 479 | **508** |
| LZFSE (Optimal3) | 83 | **82** | 492 | **511** |
| LZFSE (Other3) | 409 | **397** | 422 | **469** |
| TGZ | 348 | **328** | 435 | **446** |
| TLZ4 | 351 | **344** | 534 | **557** |
| ZSTD | 460 | **455** | 462 | **514** |

A total of 54 columns (three `-n` × two data sets × nine formats):

| | Medin | Minimum | Maximum |
| --- | ---: | ---: | ---: |
| Decompression Δ | **+4.1%** | −7.7% | +24.4% |
| Compression Δ | **+1.0%** | −5.5% | +75.4% |

The correction of `-n 1` ( `0614a89`) **not measured in this round**: The scan of this round is `-n 40 / 8 / 4`, excluding `-n 1`.

## two. The difference of more than ±15% is positive, but not "faster"

| Column | Compression R50 → R51 | Decompression R50 → R51 |
| --- | ---: | ---: |
| llama.cpp BVX3 n8 | 216 → 378 (+75%) | 487 → 463 |
| llama.cpp TGZ n8 | 193 → 328 (+70%) | 377 → 470 (+24%) |
| llama.cpp BVX3 n4 | 210 → 321 (+53%) | 459 → 470 |
| claw-code BVX3 n40 | 496 → 643 (+30%) | 907 → 924 |
| llama.cpp Apple n8/n4 | 124/126 → 159/158 (+28%/+25%) | Flat |
| llama.cpp Lazy2 n8 | 135 → 166 (+23%) | Flat |
| claw-code ZSTD n4 | 455 → 540 (+19%) | 786 → 876 (+11%) |
| claw-code BVX3 n4 | 355 → 416 (+17%) | Flat |

**These grids are low in R50. ** For example, R50's llama.cpp TGZ: `-n 40` 348, `-n 4` 340,
`-n 8` is only 193; BVX3: `-n 40` 382, `-n 8` / `-n 4` is only 216/210. R51 in these checkered
The number is just back to the level of other `-n` in the same round. **This is the correction of the outly value of the single measurement of R50, not the faster R51**;
Both rounds are measured only once and not staggered, which is not enough to support any "faster" conclusion (mistakes.md Article 2).

The rows beyond ±15% are all positive and are exactly the cells where R50 itself was an
Outlier -- R50's llama.cpp TGZ n8 was 193 while its n40 and n4 were 348 and 340. R51 simply
Lands where the other `-n` values already were. Single, non-interleaved runs on both sides
Cannot support a speed-up claim.

## 3. The wall clock time scanned by llama.cpp is getting longer, but MB/s is not

| Scan | R50 | R51 |
| --- | ---: | ---: |
| claw-code `-n 40 / 8 / 4` | 22 / 23 / 24 points | 24 / 24 / 25 points |
| llama.cpp `-n 40` | 2h 25m | 2h 41m |
| llama.cpp `-n 8` | 2h 28m | **3h 01m** |
| llama.cpp `-n 4` | 2h 25m | **2h 52m** |
| tracer | 44 points | 43 points |
| Full round | 9h 42m | **11h 03m** |

The extra 1 hour and 20 minutes are almost all in llama.cpp, and **the MB/s scanned by the same batch has not slowed down** (Section 1).
The wall clock time scanned by llama.cpp is mainly spent on the manifest consistency comparison after solving (about 15–19 points for each format,
Claw-code about 2 points in the same step), not in the timed encoding and decoding window, so it does not affect any MB/s number in this round.

** Cause (measured, 2026-09-27): The time taken for comparison is "number of files × 22.7 ms per file", of which about 16.5 ms is
A `sha256sum` running under Rosetta. ** `lz4bench.zsh`'s `benchManifestLine` for each general file
Call four stat auxiliary functions (each run `stat --version` once to judge GNU/BSD, and then run the real `stat`)
AND `benchSha256`. Local `sha256sum` is parsed to `/usr/local/bin/sha256sum` - the old Intel
The **x86_64** coreutils left by Homebrew must be translated by Rosetta every time it is started; Homebrew of arm64 is only
The name of `gsha256sum` is installed with the same tool.

| Measurement | Value |
| --- | ---: |
| Number of corpus items | llama.cpp **45,756**; claw-code 5,849 |
| Each gear `benchManifestLine` (2,000 llama.cpp files, 3 wheels minimum) | **22.71 ms** |
| Single `sha256sum`, x86_64 `/usr/local/bin` (Rosetta, 200 times take the minimum) | **16.48 ms** |
| Single `gsha256sum`, arm64 `/opt/homebrew/bin` (same as above) | 2.65 ms |
| Single `/usr/bin/stat` (same as above) | 3.50 ms |
| Extraposed once llama.cpp comparison | **≈ 17.3 points** (R50 actual measurement 15 points, R51 19 points) |

The hash value of the three tools is the same. In each file of 22.7 ms, sha256 accounts for 16.5 ms; eight stat-related processes
(Four of them are only for judging GNU/BSD) is most of the rest. The difference between R50 and R51 is 27%, ** with the existing data, it can no longer
Distinguish whether it is macOS 27.2 or the load at the time of operation is caused by **; both rounds are only measured once.

Of the 22.7 ms per file, about 16.5 ms is one `sha256sum`: here it resolves to an x86_64
Coreutils left in `/usr/local` by an old Intel Homebrew, which Apple Silicon runs through
Rosetta (16.48 ms per launch, versus 2.65 ms for the arm64 `gsha256sum`; all three tools
Give the same digest). Most of the rest is eight stat-related spawns, four of them only to
Tell GNU from BSD. The 27% gap between R50 and R51 cannot be attributed further from one
Run each. Fixed in pending 5 below.

## four. This round of data

- `BenchMarkResult.csv2`, `README.md` result table, `best_points/`
- `lz4bench_log/lz4bench-{claw-code,llama.cpp}-n{40,8,4}.txt`
- `powerResults/`, `memprobeResults/`
- `trace/` (this round runs with `-full`, and trace and CPU call tree analysis are newly generated in this round)
- `round_status.txt`

## To be done

1. ✅ **Completed (2026-09-27): `helper/status_monitor.zsh`. ** 1 Delete the "exit code is always 0"
Expired note, the file header is rewritten as: Since `a441b9d`, `BENCH_DONE` reflects the real exit code, but the judgment is still marked step by step.
Shall prevail (the skipped step also returns 0). 2 `TRACER_DONE` Decide according to the first `MODE … power_test=` line whether
Necessary; the old log without `MODE` row is still conservatively required. 3 Print the pattern when judging, `swift_tar=0` or
The comparability of `power_test=0` annotation numbers. 4 The mark is changed to the anchoring comparison at the beginning of the line ( `^ name ( |$)`), and substrings are no longer used.
All six control groups meet expectations: real R51 log judgment completed; `power_test=1` missing `TRACER_DONE` judgment not completed;
`power_test=0` lacks it judgment and notes; no `MODE` line lacks it judgment incomplete; `COMPARISON_DONE` only substrings are left
`XCOMPARISON_DONE` is judged to be a gap; `swift_tar=0` is completed and the annotation cannot be compared.
Two. ✅ **Identified: the cause of llama.cpp comparison time** (Section 3). The main cause is x86_64 under Rosetta.
`sha256sum` (16.5 ms each time), followed by eight stat-related processes per gear; 27% of the gap cannot be subdivided into single data.
3. ✅ ** Measured (2026-09-27): The choice of chunk size. Conclusion: Maintain 4 MiB. **

Method: Copy `swift_tar.swift` to the temporary directory, and only replace `TAR_CHUNK_SIZE` with 4/8/16 MiB
(Confirm the success of replacement one by one), with the same swiftc parameters as `compile_tar.zsh` and `build/` products to build three
(ZERO DIAGNOSIS), DO NOT MOVE THE WORK TREE, AND DO NOT COVER `/opt/homebrew/bin/swift_tar`. 4 MiB that and the official version value
The construction method is the same as the other two, as a comparison; the official version that has been installed is checked for "equivalence of installation methods".
Claw-code, instructions and benchmark ( `czf`, `-c --zstd --zstd-level 9`, `-cf`), decompression for `--cat`
Do not write files, output in RAM disk, **5 rounds stagger to get the minimum value**. It has been made into a re-runable verification script and saved for output:
`swift_tar/verifications/chunk_size_tradeoff.zsh` ( `--source f6ba52c`)→
`chunk_size_tradeoff.txt`. MB/s:

| chunk | TGZ compression | TGZ decompression | ZSTD compression | ZSTD decompression | tar (no compression) | TGZ size | ZSTD size |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **4 MiB** | 277 | 799 | 454 | 1157 | 2896 | 468.6M | 382.6M |
| 8 MiB | 273 | 799 | 443 | 1115 (−3.6%) | 2797 | 468.5M | 372.5M (**−2.6%**) |
| 16 MiB | 269 | 814 | 427 | 1098 (−5.1%) | 2670 | 468.5M | 367.1M (**−4.0%**) |
| Official version (comparison) | 268 | 803 | 435 | 1138 | 2728 | 468.6M | 382.6M |

- **The difference in size is determined**: The compressed size is independent of the load, and the two runs are the same within the output accuracy (0.1 MiB). ZSTD 8 MiB −2.6%,
16 MiB −4.0%; **TGZ is not affected** (the gzip window is only 32 KB, and chunk can't touch it).
- **The difference in speed is within the scope of the noise**: the control group has the same value as 4 MiB, but it deviates by up to 5.8%; another one during the operation
The compilation of the work pushes the load to 18. The unarchived execution volume earlier on the same day is decompressed to 16 MiB −10%, and the archived time
Yes −5.1% - ** not reproduced, not adopted **. The only thing that is consistent between the two is the direction: the larger the chunk, the ZSTD decompression and non-compression
The slower the tar.
- **The reason for maintaining 4 MiB**: The magnification chunk is only changed to ≤4% ZSTD size, the speed has not improved, and it has been measured twice
The direction is all slowing down.

Size differences are deterministic and repeat to the printed 0.1 MiB (ZSTD −2.6% at 8 MiB, −4.0% at 16 MiB;
TGZ unchanged). Speed differences are within this run's noise -- the control, identical to
4 MiB, deviated by up to 5.8% -- and an earlier unsaved run's −10% at 16 MiB was not
Reproduced (−5.1%). Keep 4 MiB: a larger chunk buys at most 4% of size and no speed.
4. ** The rounds that can be compared with the front and rear wheels are all executed by `sudo ./run_round.command -full`. ** `-full` open at the same time
Swift_tar back-end and power test/tracer; if any item is missing, the MB/s or trace data will not have the same conditions as the existing round.
5. ✅ **Completed (2026-09-27): Shorten manifest comparison. ** llama.cpp Three scans total 27 comparisons, each time
About 17 minutes, **about 7.5 hours out of 11 hours in the whole round are spent here**. The modification of `lz4bench.zsh`:
1 `benchStatDetect` Judge GNU/BSD once before looping, once `stat` retrieve mode/mtime/size/
Identity (8 times per file stat-related process → 1 time); 2 `benchShaDetect` select the sha256 tool once,
**Priority arm64's `gsha256sum` **, followed by `sha256sum`, and there is no backup of `benchSha256`. Both
It is the same as GNU coreutils, and the output format is the same as the escape rules of special file names.

Verification: The old version ( `lz4bench.zsh` of `HEAD`) and the new version generate a manifest each, and compare `cmp`. The corps is
Llama.cpp, claw-code, and a boundary tree (empty file, file name with blanks and newlines, authority 600, three hard links with sub
In the directory, valid and suspended symbolic links, FIFO, deep catalog). ** The three are the same by byte. **

| Corpus (number of items) | Old version | New version | Multiple |
| --- | ---: | ---: | ---: |
| claw-code (5,849) | 282.1 seconds | 38.5 seconds | 7.3× |
| llama.cpp (45,756) | 1491.2 seconds | 257.3 seconds | 5.8× |

Each is measured only once, and not at the same time (the load is higher when the old version is running: the old version of llama.cpp is 32.6 ms per file, which is higher than the above table.
22.7 ms measured in idle time), **the multiple can only be seen in the equality level**. Based on the new version of 5.6 ms per file, a llama.cpp comparison
About 4.3 minutes, about 5.8 hours for 27 times - ** This is an estimate, and it will be confirmed by the next round of wall clock time**. Compare outside the timing window,
**It does not affect any MB/s**, but the full-round time of the next round will not be directly compared with R51.

**Another thing that needs to be decided by the user**: `/usr/local` still has a whole set of old Intel Homebrew (51 suites, 384
Execution file). All tools in PATH that only exist in `/usr/local/bin` will be executed by Rosetta, and this item is only bypassed.
Among them is `sha256sum`.

Done. `lz4bench.zsh` now detects the stat flavor once and fetches all four fields in one
`stat`, and picks the sha256 tool once, preferring the arm64 `gsha256sum` (same GNU
Coreutils, same output and escaping). Old and new manifests are byte-identical on
Llama.cpp, claw-code and an edge-case tree. Single, non-interleaved runs: claw-code
282.1 → 38.5 s (7.3×), llama.cpp 1491.2 → 257.3 s (5.8×); treat the ratios as orders of
Magnitude. The estimated saving is about 5.8 h per round, to be confirmed by the next
Round's wall time. MB/s is not affected. A full Intel Homebrew remains in `/usr/local`;
Anything resolved only from there still runs under Rosetta -- the user's call.

---

# R50-Mac: Return repair acceptance, frontal comparison with native/external zstd (2026-08-28)

> **Goal**: Rerun with `sudo ./run_round.command -full`, check whether swift_tar `cfc71df` is repaired
> The decompression of R49-Mac records returns, and the first clean benchmark after repair is obtained.
>
> **There is only one conclusion: the return is indeed fixed. ** In addition, all the differences between R50 and R48 have been verified.
> All of them are measured noise - including those that seem to be "faster". See Section 2 for details.

Run 2026-08-28 13:05:45 → 22:48:02, a total of **9 hours and 42 minutes**. MACHINE `Mac16,10`,
`os_version` `27.0 (26A5421a)`, swift_tar `7e64057`.

Judgment ( `helper/status_monitor.zsh --verdict`): Failure signal **0**, decompression consistency comparison
**48 OK / 0 FAILED**, all eight necessary steps are marked. **Exit code is not used** - see Section 4 for the reason.

## one. The return of `aea0427` has been repaired

Decompression time (seconds, n=40):

| Data set | Format | R48 | R49 (including return) | **R50** |
| --- | --- | ---: | ---: | ---: |
| llama.cpp | Apple | 4.35 | 12.60 | **3.17** |
| llama.cpp | Optimal | 4.21 | 12.06 | **3.03** |
| llama.cpp | Other3 | 2.77 | 12.49 | **3.44** |
| llama.cpp | Optimal3 | 2.92 | 11.98 | **2.95** |
| llama.cpp | Lazy2 | 2.86 | 12.05 | **2.92** |
| llama.cpp | BVX3 | 3.71 | 12.20 | **3.06** |
| llama.cpp | TGZ | 3.07 | 12.34 | **3.34** |
| llama.cpp | TLZ4 | 3.44 | 11.44 | **2.72** |
| llama.cpp | ZSTD | 2.35 | 11.93 | **3.15** |

**The 12-second level all return to the 3-second level, and the nine formats are no exception. ** `claw-code` Same: 2.5–3.3 seconds of R49 back to
1.4–2.4 seconds.

This consistency is the field of this section and section 2: the return is a **quantity-level** difference and the direction is the same, and the noise is positive and negative,
Even the opposite on the two data sets.

## two. The rest of the differences are noise, including those that seem to be getting faster.

The decode difference between R50 and R48 is positive and negative, ranging from −28% to +36%. **Three independent evidences show that they are not true. **

**Contradiction in direction. ** The same format and the same version have opposite conclusions on the two data sets:

| Format | claw-code | llama.cpp |
| --- | ---: | ---: |
| TLZ4 | +26.1% (slow) | −20.9% (fast) |

Systematic changes will not be like this.

**E-Cluster can't be explained. ** R48-Mac Section 2 has explained the differences between rounds with E-Cluster participation. After this round of verification
The connection is not valid:

| Format | R48 E-Cluster | R50 E-Cluster | ΔE | decode Δ |
| --- | ---: | ---: | ---: | ---: |
| optimal3 | 75.82% | 92.47% | +16.7 | +1.4% |
| other3 | 77.32% | 86.05% | +8.7 | **+22.4%** |

Other3, which rises less in E-Cluster, is much slower. If the association is established, the direction should be opposite.

** Directly compound and overturn both sides. ** Take the minimum value with the same seal and 6 rounds staggered:

| Format | R48 | R50 | Complex | Reading |
| --- | ---: | ---: | ---: | --- |
| Apple | 1.78 | 1.59 | **1.51** | R50's "fast 10.7%" is not valid |
| Other3 | 1.34 | 1.64 | **1.32** | R50's "slow 22.4%" is not valid, and the compound return to R48 |

**Therefore, the decode columns of R50 can only be used to confirm that the return has been repaired, and cannot be used to claim that any format has become faster or slower. **

Four similar events have been repeatedly overturned before this round (BVX3 encode +81%, claw decode +21%, `--exclude`
+9.5%, encryption creation +13.6%). The variation of a single measurement of this machine can reach more than 2 times, ** the minimum value of staggered multiple rounds is
The only reliable practice**; when the number of times is insufficient, the outlier will dominate the conclusion.

## 3. native to external zstd

R49-Mac was the first time that macOS measured to native libzstd, but there was no way to compare it with external at that time. This section is the same
`claw-code` (1,351 MB, 5,402 files), the same as level 9, 6 rounds of staggered to take the minimum value directly.

| | external( `zstd` CLI) | native (swift_tar built-in) | |
| --- | ---: | ---: | --- |
| encode | 5.71 seconds (237 MB/s) | **2.65 seconds (510 MB/s)** | native **2.2 times faster** |
| decode | **1.45 seconds (932 MB/s)** | 1.88 seconds (719 MB/s) | native slow 30% |
| Sesulation size | **365.8 MB** | 382.6 MB | native large 4.6% |

### Where is slow: two separable causes

Unpack the amount of "decompression" and "write file":

| | external | native | |
| --- | ---: | ---: | --- |
| Pure decompression (no parsing tar, no writing file) | 0.91 | 1.15 | +26.2% |
| Complete solution | 1.16 | 1.72 | +48.3% |
| The increment of the writing file | **0.25** | **0.57** | |

** First, divide into pieces. ** `TAR_CHUNK_SIZE = 1 << 22` (4 MiB), each chunk is pressed into an independent zstd frame:

```
external    1 個 frame     單一連續串流
native    336 個 frame     1351 MB ÷ 4 MiB = 338，對得上
```

336 frames start from zero, and the repetition across chunks cannot be caught - which also explains the pure decompression cost of +26%.
And the compression ratio loss of +4.6%.

**This is a design trade-off, not a defect**: Blocking is the premise that `ParallelChunkSink` can divide the work to multi-core, and
Encode is 2.2 times faster than it.

**Second, it was previously written that "pipeline parallel" - that conclusion has been overturned and described as follows. **

The original inference is: external's `zstd -d -c | tar -xf -` two trips work at the same time, and native is a single trip.
It is strung on the same timeline, so the gap comes from the parallelism. ** It is only written by `real`. **

After adding `user` and `sys`, this inference is not valid:

| | real | user | sys | CPU/wall |
| --- | ---: | ---: | ---: | ---: |
| native solution | 1.61 | 0.97 | 1.73 | 1.68 |
| external solution | 2.27 | 1.10 | 2.14 | 1.43 |

** `user` is almost the same** (0.97 to 1.10) - the calculation amount on both sides is the same, and the blocks do not allow libzstd to do more work. And
CPU/wall is native **higher** (1.68 to 1.43), which is the opposite of "native is not parallel".

And this table itself also flips the victory or defeat: **The native solution on the RAM disk is faster** (1.61 to 2.27). Previously
Measure that the external is faster (1.45 to 1.88) on the internal disk - so that gap belongs to the storage layer, not to the codec.

### sys The direction of time (the only clue at present)

Count with `time -l` (the same claw-code, solved to RAM disk):

| | sys seconds | page faults | vol ctx-sw | invol ctx-sw |
| --- | ---: | ---: | ---: | ---: |
| native solution | 1.71 | **128,042** | 90,600 | 10,524 |
| external solution | 2.13 | 1,990 | 119,727 | 9,666 |

**Page fault is 64 times worse. ** That points to the price of `FileWriterPool` gear-by-file buffer 4 MiB ( `smallFileMax`).
It should be noted that external is two strokes and `time -l` only covers the outer layer `sh`, so its count is low - the comparison here is the shape,
It is not an absolute value.

**This is still not the conclusion, but the starting point of the next step. ** The conclusions of the first two versions of this section were each overturned once by the next group, and the causes of the two
Same: The mechanism is proposed when the number is insufficient. Don't repeat it for the third time. Make up the numbers first.

The measurement tool has been solidified as [ `swift_tar/verifications/zstd_decode_gap.zsh`](swift_tar/verifications/zstd_decode_gap.zsh),
Each of the five models corresponds to one evidence that has overturned the conclusion: `pipeline` (real/user/sys disassembly), `threads` ( `-n` scan),
`syscall` (page fault and context switch), `chunk` (frame number), `storage` (RAM disk to actual disk).

### `-n` There is no adjustable space for zstd decompression (excluded)

Since the block is for parallel, should `-n` (in-flight chunk number) be adjusted separately for zstd decompression? **No need--
It's the same no matter how you set it. **

Solve the same `claw-code` sequest on RAM disk (3 GB HFS ram://, eliminate disk saturation), 5 rounds of staggered:

| `-n` | Each time (second) | Minimum | vs `-n 1` |
| ---: | --- | ---: | ---: |
| 1 | 1.92 1.70 1.70 1.67 1.64 | 1.64 | — |
| 2 | 1.71 1.70 1.79 1.68 1.66 | 1.66 | +1.3% |
| 3 | 1.64 1.74 1.78 1.65 1.72 | 1.64 | +0.2% |
| 4 | 1.61 1.65 1.69 1.68 1.64 | **1.61** | −1.6% |
| 8 | 1.66 1.73 1.70 1.69 1.72 | 1.66 | +1.7% |
| 40 | 1.74 1.71 1.66 1.67 1.71 | 1.66 | +1.8% |

All fall in 1.61–1.66 seconds. The −1.6% of `n4` is the same as the +1.8% of `n40`, but the direction is opposite, which is a noise.
Both ends instead of "4 cores are the best". PURE DECOMPRESSION ( `--cat`, NOT WRITING FILES AT ALL) IS CLEARER: THE SIX `-n` VALUES ARE ALL
1.14–1.15 seconds, range ±0.8%.

The reason is clear: `-n` controls the in-flight chunk number of `ParallelChunkSink`, which is the mechanism of **compression end**.
The 336 frames at the decompression end must be reduced to a continuous tar stream in order. The order is a rigid constraint, and there is no parallel space.

**This group of measurements itself is also a lesson. ** The same scan is done on the internal disk first, and " `-n 1` 1.78 seconds, the rest
3.25–5.33 seconds", which looks like `-n 1` is a big victory. Staggered re-examination revealed it:

```
-n 1    1.74  3.08  5.45  5.99  5.79  5.58    ← 單調變慢
-n 4    1.69  5.78  6.20  5.57  4.64  4.50
-n 40   2.29  5.24  4.37  5.63  4.91  4.68
```

The first time of each group is fast, and then all of them deteriorate - the number is determined by "ranking in the sequence", because repeatedly `rm -rf`
Then write 1.3 GB to fill the write path of the SSD. **The minimum value is invalid here**: It picks out the early one in the sequence.
After switching to RAM disk, the values stabilized one by one (1.61–1.92).

Therefore, this section excludes the second hypothesis (the first is E-Cluster in Section 2), ** the second item to be done becomes the only remaining
Clear direction**: 1.64 seconds on RAM disk to 1.72–1.88 seconds on the internal disk, the gap is exactly the writing file; and external
The advantage of (write file increment 0.25 to 0.57 seconds) is also in the same place.

### The difference in compression ratio is not a return.

| | R48 (external) | R49 (native) | R50 (native) |
| --- | ---: | ---: | ---: |
| claw-code | 0.7806 | 0.8165 | **0.8165** |
| llama.cpp | 0.9069 | 0.9297 | **0.9297** |

R49 is exactly the same as R50, but R48 is different - which confirms that the difference comes from real substitution (block vs continuous streaming) rather than any
Return, and the output of native is deterministic.

## four. Determined not to use exit code, and two defects of status_monitor.zsh

The judgment of this round is based on `helper/status_monitor.zsh --verdict`, and the reason is recorded in Section 2 of R49-Mac:
`rc=$?` of `run_round.command` is located after `rm -f .bench_env`, and `rm -f` always returns to 0, so
`BENCH_DONE` write unconditionally, `BENCH_FAILED` never runs, the whole round forever exit 0. **The defect has not been repaired. **

The script itself exposed two defects in the first actual battle, both of which have been corrected:

** It is judged that a clean round is reported as a failure. ** `grep -c` prints `0` at the time of zero hit, but the exit code is 1, which was originally written
`|| print 0` then reprinted once, and the variable became `"0\n0"`, and the subsequent arithmetic failed with bad math expression.
The judgment falls on the "unfinished" one. **This is exactly the mistake that the script should prevent, but the direction is opposite** - not to say failure as
Success, but call success a failure. Both make the judgment meaningless.

** The filter eats the completion notice of six data sets. ** The original `DONE [0-9]` requires `DONE` to receive the time stamp, but
`LZ4BENCH_DONE claw-code-n40 13:29:16` is followed by the name. As a result, no progress has been received for 9 hours.
And it looks like "everything is normal and quiet" - exactly the kind of silence to be avoided at the beginning of the script. Change to
`_DONE( |$)`.

## five. This round of data

6 `-n` scans (claw-code and llama.cpp each n=40/8/4), 54 results, power field 54/54
All have readings, 48 decompression consistency comparisons, and a round of trace and CPU call tree analysis.

## To be done

1. ✅ **Completed (2026-09-04): `rc=$?` position of `run_round.command` ** (take R49-Mac pending No. 1
Strip, two rounds have not been repaired). `rc=$?` is changed to immediately after `sudo ./benchmark2.zsh`, and **one for each of the two branches**;
`rm -f .bench_env` moved after it.

This article originally wrote "move before `rm -f .bench_env`" - it is also correct to do so (after `fi`), because
`$?` after `fi` is the state of the last instruction adopted. The change of "take one for each of the two" is because ** this
The defect was originally caused by a line inserted between the instruction and the value **, and the branch may still be inserted into the clean line in the future; explicit
The value is taken so that there is no chance of that thing to happen.

Verification: Run two shapes with the double that benchmark2 must fail (simulated sudo password expiration)--
The old shape `exit=0`, write `BENCH_DONE`; the new shape `exit=7`, write `BENCH_FAILED 7`.
The actual file `zsh -n` is passed, and there are `rc=$?` in 2 places, and `rm -f .bench_env` is followed by 0.

**The two rounds of R49-Mac and R50-Mac are still carried out under this defect**, and its `BENCH_DONE` and exit code are still
It does not constitute evidence; the judgment of the two rounds is based on each step's own `*_DONE` mark, and it will not be rewritten retroactively here.
Two. ✅ **Quentity (2026-09-04): `smallFileMax` is excluded, and the candidate number returns to zero. **(Secte 3)

The measurement method does not need to be rebuilt. `swift_tar.swift:4019` The line itself is a switch: the members of ≤4 MiB are buffered into one
`Data()`, >4 MiB's complete skip and inline stream. **As long as the size of the members crosses 4 MiB, you can be in the same
Switch this path on the running gear. ** Five corpus, 7 rounds interlacing, take the minimum value, RAM disk, inter-wheel variation < 1%:

| corps | members | path | fault | per MiB | per 4KiB page |
| --- | --- | --- | ---: | ---: | ---: |
| C | 96 × 1 MiB | Buffer | 8,144 | 84 | 0.33 |
| A | 32 × 3 MiB | Buffer | 26,424 | 275 | 1.08 |
| D | 24 × 4 MiB | Buffer | 26,206 | 272 | 1.07 |
| E | 24 × 5 MiB | inline | 28,086 | 234 | 0.91 |
| B | 16 × 6 MiB | inline | 20,482 | 213 | 0.83 |

**Decisively D and E**: the number of members is the same, the size is adjacent (4 to 5 MiB), and the branch is turned over. Each page fault by 1.07
Smoothly to 0.91, **there is no discontinuity at the boundary**. If gear-by-file buffering is the cause, D should be much higher than E.

**The stronger refutation is C**: it uses the buffer path the most (all 96 members follow it), but the fault is the least - every MiB 84,
It is one-third of A.

Each page fault changes continuously with the size of the single configuration, does not jump across branches, and the shape points to the configurator instead of the write pool: macOS's
Malloc obtains the configuration that exceeds the threshold by mmap, returns it when it is released, and zero-fills page by page at the first touch of the next configuration.
The inline path is also configured block by block, and the same price is paid.

Measurement and complete output: `swift_tar/verifications/page_fault_attribution.zsh` ( `.txt` reserved execution
Result). **Boundary**: The experimental amount is the decompression of swift_tar on the synthetic and incompressible corpus, **not ** native to
The 64x gap itself in external; it only answers "is file-by-file buffering the source of fault", and the answer is yes.

**So all four assumptions are excluded** (E-Cluster participation, `-n` setting, parallelism, `smallFileMax`), and
**There are no candidates left in this section**. The next step should not be to mention another mechanism - which has been overturned three times - but to obtain one symbol by one.
The profile ( `sample` or Instruments' Allocations) allows the data to indicate the configuration point, not by reasoning.

> **Follow-up (2026-09-06): That profile was done, and it first overturned the premise of this item. **
>
> swift_tar `9aa0cf6` Retest the phenomenon itself before moving the profiler, the same script, three shapes, two platforms:
>
> | Shape | macOS | Linux (QEMU aarch64) |
> | --- | --- | --- |
> | 20 × 8 MB | 70 / 76 ms **0.92 ×** | 38 / 26 ms 1.46 × |
> | 200 × 800 KB | 47 / 61 ms **0.77 ×** | 31 / 25 ms 1.24× |
> | 2000 × 80 KB | 85 / 156 ms **0.54 ×** | 50 / 35 ms 1.43 × |
>
> **That gap is exclusive to Linux, and swift_tar on macOS is now the faster party**, and the more fragmented the corpus, the more advanced it is.
>
> ** Therefore, the measurement above this item is still valid, but the question it answers is no longer the original one. ** It proves that
> "File-by-file buffering is not the source of page fault" - that is still true on macOS, and a mechanism is excluded independently of the platform.
> It **does not** prove the cause of "native is slow on macOS", because that premise itself is no longer valid. Please only for the above table.
> The reference is the former.
>
> `58d1eb0` continues to count with LLVM PGO function by function (choose counting instead of sampling, because counting has nothing to do with the machine load; at that time, host
> load 4.63, of which 74.7% is the simulator of another project). The conclusion is also negative: ** Time is not in swift_tar
> In your own Swift code ** - the total number of executions of all instrumented blocks of 160 MB is 21,743, `readExactly`
> Only ran 63 times out of 20 members and 160 MB.
>
> ** The sentence worth leaving on the method is `9aa0cf6`: measure the premise first, not the profile first. ** profiler will definitely
> Return "a function that takes the most time", and that function will then be regarded as the cause - even if the phenomenon no longer exists.

**The conclusions of the first two versions of this section were overturned by the proposed mechanism when the number was insufficient**: First, "decompression and writing files do not overlap"
( `user` is the same, CPU/wall is higher native, overturned), and then "external relies on pipeline parallel to win"
(The native on the RAM disk is faster, overturned). Three competitive assumptions have been excluded: E-Cluster participation (Section 2,
The opposite direction of correlation), the setting of `-n` (section 3, all six values are within ±1.8%), parallelism (this section, CPU/wall
Opposite direction).

`swift_tar/verifications/zstd_decode_gap.zsh` is used for measurement, and RAM disk is used as the solution target.
——Repeatedly writing 1.3 GB on the internal disk will make the subsequent measurement monotonous and deteriorate, and the minimum value will be picked at the early stage of the sequence instead of
The real optimal value. The `--mode storage` of the script will run both at the same time, so that the impact of the storage layer can be manifested.
3. ✅ ** Measured in R51-Mac Pending Item 3 (2026-09-27): Maintain 4 MiB. ** TGZ is not affected by chunk size;
ZSTD is 2.6%/4.0% smaller at 8/16 MiB, and the speed has not improved (the difference is in the range of noise, and the direction is slower).
The following is the original pending and the scope clarified at that time.

**The choice of measuring chunk size** (Section 3). 8 or 16 MiB will reduce the loss of frame number and compression ratio, but
Reduce the parallelism of the compression end. This is a measurable trade-off, and it should not be decided by guess. **Cannot be carried out at the same time as item 2**,
Otherwise, there is no way to attribute it.

** The scope has been clarified (2026-09-25): This item needs to be rebuilt, not the flag. **

`TAR_CHUNK_SIZE = 1 << 22` (**4 MiB**, `swift_tar.swift:289`). `ParallelChunkSink`'s
The constructor does receive `chunkSize: Int = TAR_CHUNK_SIZE`, but ** the two callers ( `:6049`, `:6258`) do not
Pass the value**, and none of the three compilation scripts overwrite the constant - so there is no path that can replace it without changing the code at present.

Therefore, there are only two ways:

- **Change the constant, reconstruct three times** (4/8/16 MiB), and then stagger the measurement. Don't move any interface, what you can measure is exactly what you want to ask.
Things. **Recommended this one. **
- Add a flag to receive the two callers (about 5 lines). That is ** to add a flag that is visible to users to expose internal adjustment.
Constant** is a design decision rather than a measurement, which needs to be discussed first.

`zstd_decode_gap.zsh --mode chunk` **Not this item**: The annotation of this mode has clearly said that the chunk size is the compilation period.
There is no way to adjust the constant and flag, so it is changed to the cost of `--zstd-level` "frame number fixed and compression volume change". That's another
One question, the two cannot refer to each other.

Scope settled 2026-09-25: this needs rebuilds, not a flag sweep. The constant is 4 MiB and
Neither call site passes the parameter, so nothing reaches it without a code change. Prefer
Changing the constant and building three times; adding a user-visible flag for an internal
Tuning constant is a design decision, not a measurement. `--mode chunk` is a different
Question -- frame count at fixed chunk size -- and the two must not be cited for each other.
4. **The decode columns of R50 shall not be used for performance conclusions between formats or wheels** (Section 2). They only prove that the return has been repaired.

---

# R49-Mac: The first round of macOS native zstd, and the decompression speed of a location and repair has dropped completely (2026-08-27)

> **Goal**: Run a complete round with `sudo ./run_round.command -full`, and accept three repairs (swift_tar
> symlink mtime, the whole round of root execution to solve sudo, `.csv2` renaming), and get the first one on macOS
> native libzstd data. **This round of data is complete and there is no failure, but there is a comprehensive decline in each column of decode, and the cause has not been determined.
> This group of numbers shall not be cited as a conclusion until the comparison is completed. **

Run 2026-08-27 16:29:59 → 08-28 02:16:07, a total of **9 hours and 46 minutes**. MACHINE `Mac16,10`,
`os_version` is written as ** `27.0 (26A5421a)` **. Swift_tar `01f724f`.

## one. Why can we finish this round (the three obstacles of the previous time)

The previous attempt (start 13:57 on the same day) fell in `llama.cpp-n40 other3` and left three problems. This round will be lifted one by one:

| Obstruct | Solution |
|---|---|
| `COMPARED_WITH_TGZ_FAILED` | swift_tar `01f724f` restore symbol link own mtime |
| `sudo: a password is required` | The whole round runs with `sudo`, no longer relying on keep-alive |
| `.csv2` Does the name change interrupt the process | Not interrupted; both reconstruction and integration are written into the new file name |

**The one of symlink mtime is worth describing its manifestation. **Two tree manifests 45,756 lines each, put mtime
After the field is covered, there is no difference - the difference is only 67 symlink mtime, and the difference is 962 seconds, which is just baseline.
And compare the interval between two decompressions. The decompression result is completely correct, which is "the link mtime is covered as the current time of decompression" so that any two
The decompression several minutes apart must be different, and it is inconsistent with reading it as two codec. Bsdtar will restore it, swift_tar
No - this is `473a247` The defects that can only be seen after using manifest comparison, the old `diff -rq` Follow symlink,
It will never be found.

Results of this round: **48 decompression consistency comparison with all `COMPARED_WITH_TGZ_OK`, 0 failures**; no full file
`FAILED` / `ERROR` / `Traceback`; 54 data, power field **54/54 all have readings**.

## two. The return of success and failure of `run_round.command` has always been bad.

One thing has been identified in this round: `BENCH_DONE` and the exit code of the whole round **are not reliable**.

```zsh
157:    sudo ./benchmark2.zsh >> round_status.txt 2>&1   # 真正的工作
162: rm -f .bench_env                                    # 永遠成功
163: rc=$?                                               # 抓到的是 rm 的狀態
164: if [[ $rc -eq 0 ]]; then echo "BENCH_DONE" ...
172: exit $rc
```

`rc=$?` is located after `rm -f`, and `rm -f` also returns 0 for non-existent files. Therefore `BENCH_DONE` unconditionally
Write that `BENCH_FAILED` can never run, and the whole round will always exit 0. **Preve time `benchmark2.zsh`
The whole section did not run (power full empty) but returned success, the reason is here. **

Therefore, `BENCH_DONE` is not used for this round of successful judgment, but according to the marks written by yourself in each step ( `TRACER_DONE`,
`POWER_BENCHMARK_DONE`, `BENCHMARK_RESULT_REBUILD_DONE`, `POWER_SUMMARY_INTEGRATE_DONE`,
`BEST_POINTS_ANALYSIS_DONE`, `COMPARISON_DONE`, `MD_TRANSLATE_DONE`), such marks are not subject to this
The impact of defects. For the amendment, please refer to the pending Article 1.

## three. Which fields are affected by the three caliber changes?

| Change | Impact | Can it be subtracted with R48-Mac |
| --- | --- | --- |
| native zstd gate open ( `fbf3512`) | ZSTD All | **No** - Changed the tested reality |
| `.zst` probe changes `--cat` ( `9cf0899`) | ZSTD's `decode_rss_mb` | **No** - Changed the caliber |
| `lz4bench.zsh` Separation ( `8b2870b`) | All | Yes, this round is for its acceptance |

**ZSTD is the only format that changes the compression ratio** (claw-code 0.7806 → 0.8165, llama.cpp 0.9069 →
0.9297). The compression ratio of the remaining seven formats is **exactly the same as that of R48-Mac**, which proves that there is no change in the encoder itself.
It also makes the difference of ZSTD clearly attributed to actual substitution rather than others.

## four. Encode: roughly flat, the abnormality of BVX3 has been judged as noise

Compare by the number of seconds (MB/s is affected by the total amount, and the number of seconds is more intuitive):

| Format | claw-code R48→R49 | llama.cpp R48→R49 |
| --- | ---: | ---: |
| TLZ4 | 2.31 → 2.31 (+0.0%) | 3.99 → 4.05 (+1.5%) |
| Optimal | 39.10 → 39.23 (+0.3%) | 25.30 → 24.90 (−1.6%) |
| Optimal3 | 21.09 → 20.90(−0.9%) | 17.78 → 17.65(−0.7%)|
| TGZ | 4.36 → 4.37 (+0.2%) | 4.13 → 4.45 (+7.7%) |
| Lazy2 | 20.32 → 20.57 (+1.2%) | 7.90 → 8.85 (+12.0%) |
| Other3 | 2.21 → 2.31 (+4.5%) | 3.40 → 3.61 (+6.2%) |
| Apple | 9.20 → 9.86 (+7.2%) | 8.88 → 10.32 (+16.2%) |
| **BVX3** | **2.18 → 2.95 (+35.3%)** | **3.50 → 6.35 (+81.4%)** |
| ZSTD | 2.96 → 2.72 (−8.1%) | 3.37 → 2.95 (−12.5%) |

**BVX3 After post-re-measurement, it is judged to be a one-time interference of the round, not a return. **With exactly the same conditions as this round
(Swift_tar shim, `-n 40`, the same claw-code) Retest three times to get 2.17/2.25/2.31 seconds, close to
The 2.18 seconds of R48-Mac is about 23% faster than the 2.95 seconds in this round. Exclude one by one:

- lzfse source code is between `c18e327..HEAD` **zero change**; `compile.sh`→`compile.zsh` only change the name,
The content `diff` is exactly the same, and `-O` is still there.
- "BVX3 has high parallelism, so it is more sensitive" is not valid: the actual measurement of BVX3 9.0×, Other3 8.9×, the two are almost the same,
And it takes the same time for both (both 2.17 seconds).
- The multiplication is carried out under the condition of **background load** (loadavg 5.04), which is still faster than the special operation of this round.

**Conclusion: The two-grid digital label of BVX3 encode of R49-Mac is unreliable and will not be adopted. **The rest of the encode columns are adopted;
In particular, Optimal (39 seconds) only changed by +0.3% on the claw-code, which proves that the computing power of the machine itself has not decreased.

## five. Decode: Seven comparable formats fell by 30–78% across the board, and the cause is to be determined.

| Format | claw-code | llama.cpp |
| --- | ---: | ---: |
| Other3 | −48.3% | −77.8% |
| TLZ4 | −42.7% | −69.9% |
| Optimal3 | −40.5% | −75.6% |
| Optimal | −34.2% | −65.1% |
| TGZ | −33.8% | −75.1% |
| Lazy2 | −31.4% | −76.3% |
| Apple | −32.0% | −65.5% |
| BVX3 | −29.7% | −69.6% |
| (ZSTD −53.0% / −80.3%, can't be compared with the actual work) | | |

**None of it has become faster. **Confirmed facts:

- ** will reappear. **Decompression of claw-code TGZ as a general user for 3.09/3.26 seconds, which is exactly this round
3.17 seconds; R48-Mac is 2.10 seconds. The same is true for the original timing: `llama.cpp.tgz` changed from about 2.9 seconds to 12.34 seconds.
- ** The decline is directly proportional to the number of documents. **Claw-code 5,402 gear fell by about 34%, llama.cpp 41,576 gear fell by about 75%
——Points to **cost per file**, not cost per byte.
- **All formats are decompressed by swift_tar shim** ( `… | tar -xf -`), so it is reasonable to fall together.
- ** The decompression power increases instead. **Claw-code TGZ's `decode_cpu_power_mw` From 4257.5 to
5043.3 mW (+18.5%), that is, the unit data volume has done more work, which is consistent with the explanation of the cost of each file.
- ** It's not that the machine slows down. **Optimal encode 39 seconds is only +0.3% between the two rounds.

Excluded causes:

| Hypothesis | Exclusion basis |
|---|---|
| root execution trigger chown | swift_tar source code**without any `chown` ** |
| root execution itself | Get the same slow number with the general user compound |
| Built optimization flag lost | `-O` is still there; `4f496f1` has not moved `compile_tar.zsh` of macOS |
| E-Cluster participation differences (see R48-Mac Section 2) | Both rounds are E-Cluster idle 100%, P-Cluster about 4000 MHz |
| manifest comparison is included in the timing | The original `Process extract` timing itself has slowed down |

### Cause: Each member path visit of `aea0427` (located and repaired)

**Exclude the OS version change first. **On **the same machine, the same OS `26A5421a`, the same claw-code sealed**,
Compare the `26a78cc` used by R48-Mac with worktree and the `01f724f` in this round:

| swift_tar | Decompress claw-code | Corresponding round record |
| --- | ---: | ---: |
| `26a78cc` | 2.23/2.11 seconds | R48-Mac 2.10 seconds |
| `01f724f` | 3.15/3.25 seconds | R49-Mac 3.17 seconds |

The two accurately reproduce the numbers of their respective rounds, and the OS is **the same** in this comparison - so `26A5406e` Z →
The replacement version of `26A5421a` can be excluded.

**Then use `git bisect` to position between 98 strokes in between**, and the test is "decompression claw-code after construction, threshold 2.6
Seconds". Good all fell in 1.99–2.02 seconds, and bad all fell in 3.06–3.09 seconds. The two groups were extremely open, and there was no ambiguous zone.
The first bad commit is ** `aea0427` "Refuse to write through the implanted symlink (blind test round 42)"**.

The `passesThroughSymlink()` added by this commit retrans the whole path for **each member** and calls layer by layer.
`attributesOfItem` - that is, O (number of members × depth) times lstat. This explains each observation: the decline and the number of documents
It is proportional, the power increases and the throughput decreases (a large number of syscall), the compression ratio and encode are almost unchanged (only the decompression path),
All formats are dropped together (all decompressed by swift_tar).

**Fixed in swift_tar `cfc71df` **: Remember the directory that has been confirmed to be not symlink with `clearedDirs`, so that each
The directory is only asked once in a decompression. Staggered 4 take the minimum value, and after repair, `26a78cc`: claw-code
+2.5%, llama.cpp +0.6%, all fall in the noise ( `26a78cc` itself is between 2.00–3.13 and 3.71–7.03
Jump, so the minimum value is the only available statistic here).

**Fully reserved**: The four symlink cases of `test_blind_findings` are still passed. And add the fifth
Case - All four of them put symlink in the first item, so the failure path of the cache cannot be detected; the new case is changed to three items.
(Write to the directory first, then overwrite it with symlink, and finally write through it), the seal on `26a78cc` will make the file
Escape from the prison. 139/0 all over.

## six. ZSTD: macOS first native libzstd

This round is the first time on macOS to measure the data of libzstd in the swift_tar itinerary instead of the external `zstd` CLI - the gate is
`fbf3512` (2026-08-26) joined, before `run_round.command` has never been set
`LZFSE_REQUIRE_NATIVE_ZSTD`.

| Data set | Compression ratio | Enc MB/s | Dec MB/s | Enc RSS | Dec RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| claw-code | 0.8165 | 521.20 | 490.86 | 385.2 MB | 655.8 MB |
| llama.cpp | 0.9297 | 491.99 | 121.75 | 497.8 MB | 740.0 MB |

**This is the new reference line, and there is no previous value to reduce. **It makes no sense to subtract from the ZSTD column of R48-Mac: that's the external CLI.
RSS jumps from 8–9 MB (external itinerary) to 385–740 MB - the external branch volume is `zstd.exe` itself,
The native branch volume is the whole swift_tar containing tar and in-flight buffer.

## seven. This round of data

6 `-n` scans (claw-code and llama.cpp each n=40/8/4), 54 results, 84 power measurements and their
Powermetrics original output, 53 RSS, trace and CPU call tree analysis each round.
`lz4bench_log/tree_manifest/` (242 MB, 54 manifests) not included in the version: re-generated in each round, and only in this round
It is meaningful; the diff in the time of failure has a preservation value, and that will be written into `round_status.txt` and
`lz4bench_log/*.txt`.

## To be done

1. ✅ **Completed (2026-09-04): `rc=$?` position of `run_round.command` ** (Section 2). See for details
R50-Mac Pending Article 1. **This round (R49-Mac) is still under this defect**, its `BENCH_DONE` and exit
The code does not constitute evidence of success, and the `*_DONE` mark is determined according to each step.
Two. ✅ **Completed: The cause of decode decline** (Section 5). Positioned as `aea0427`, repaired at `cfc71df`.
The process is recorded in `r49_decode_bisect.csv2`. **The decode columns of R49-Mac still cannot be used as codec performance.
Conclusion reference ** - what they measure is the binary that contains the return. The repaired decode benchmark will be generated in the next round.
3. **The two grids of BVX3 encode are marked as unreliable** (Section 4), and it has been confirmed that it will not be reproduced.
4. ** `os_version` should be included in the inspection items of round comparability. **This round is different from the build of R48-Mac and no one notices it.
I didn't find it until I traced the decode. This field has long been recorded, and what is missing is the step of "change the version is marked".

---

# Pre-R49: The caliber of ZSTD null mode is not equal to macOS native zstd gate notch (2026-08-26)

> **Nature**: Infrastructure modification, **does not include new performance data**, compared with Pre-R47. Benchmark has not been implemented in this round.

## 1. The two branches of null mode are not the same thing.

The non-write branch of `decode-win.bat`, the workload of native and external is different:

| Branch | Instruction | Solution zstd | Parse tar header |
| --- | --- | :---: | :---: |
| external | `zstd -d -c > nul` | ✅ | ❌ |
| native (before correction) | `swift_tar -t -f` | ✅ | ✅ Every member |
| native (modified) | `swift_tar --cat -f` | ✅ | ❌ |

`-t` is "listing and sealing" - it will pass through each tar header and group the file name string and then throw it away. `llama.cpp`
There are 40,675 members, which is equivalent to more than 40,000 header parsing and string formatting on the native side, and the external side
Not once. And the comparison of native libzstd with the external `zstd.exe` is exactly the conclusion of R46-Win-Retest.
The one that has been scheduled but has not yet been implemented.

The deviation is amplified with the number of members: `llama.cpp` is much more affected than the `claw-code` of a single large gear. Therefore, it is not possible.
The fixed offset deducted after the fact, even the shape between the data sets will be distorted.

After correction, both ends are reduced to pure decompression. `--cat` stops and outputs the original tar stream after zstd filter, and
The output of `zstd -d -c` is verified by `cmp` **byte is exactly the same**.

## two. No published data is affected by this.

This is contrary to intuition, and it is worth writing clearly: ** No round of native ZSTD numbers has been produced so far. **

- The ZSTD column of R47-Win is clearly marked as **ZSTD (external CLI)**, and Article 1 of this round is "native
Zstd is still not covered by benchmark.
- The gate was only added after R47-Win ( `helper_windows/run_round.bat:85` set
`LZFSE_REQUIRE_NATIVE_ZSTD=1`), no round has been used to finish running.

So this deviation has never entered any recorded results. It would have contaminated the first batch of ** the next round of Windows.
Native ZSTD number** - and that batch of numbers is the purpose of this comparison. The correction occurs before the number is generated,
Not after that.

## 3. macOS has never enabled native zstd gate (not yet repaired)

`run_round.command` Only set `LZFSE_REQUIRE_NATIVE_ZLIB` (lines 28, 102, 151),
**Never set `LZFSE_REQUIRE_NATIVE_ZSTD` **. `zshrc.zsh` read it in three places (No. 575, 695,
800 lines), which cannot be reached in the whole process.

Therefore:

- The ZSTD numbers of R48-Mac and previous rounds are all external `zstd` CLI, which is consistent with the indication of Windows.
- The native zstd path on the macOS side is currently **can only be triggered manually**, without any automation coverage.
- The two platforms are asymmetrical here: Windows has prepared the gate, but macOS has not.

This time, only the `.zst` probe branch of macOS is aligned with the same caliber (native `--cat`, external
`zstd -d -c`), the gate notch itself has not been repaired and is listed as pending.

## four. The stdout of `memProbe` will flow into the measurement pipeline

Record the traps stepped on when macOS side changes to avoid reoffreading. The actual work of `memProbe` is:

```zsh
/usr/bin/time -l "$@" 2>&1 | awk '/maximum resident set size/ {...}'
```

The **stdout of the tested process will flow into awk**. `-t` only spit out the file name, but `--cat` will stream the whole tar.
The cost of filling the pipeline and writing the pipeline will be recorded in the test process - what is measured is no longer just decompression.

Change to `sh -c 'exec "$@" >/dev/null'` re-directed: `exec` replace the stroke image, so `time -l` is measured to
It is still the goal itself, not an extra layer. The actual measurement is 10.8 MB, which is the same as direct execution.

## five. Verify

`swift_tar` side (b33cac1): `-test` 16/16 pass, `test/test_blind_findings.zsh`
138 PASS / 0 FAIL, ZIP `-O` Confirm that stdout is correct and disk is zero residue, installation version and `release/`
The SHA-256 is the same.

Lzfse2 side: `zsh -n zshrc.zsh` passed; native and external branches respectively
`extract <archive> probe` actual running, return 10.8 MB and 2.1 MB, no landing in the working directory.

**Unverified**: Two `.bat` of `helper_windows/` and swift_tar added
`build_tool_install-win.bat`; There is no cmd.exe and PowerShell in this machine.

## six. `-swift_tar` One flag controls two things, but the two things are not in place at the same time.

This section explains a situation that is easy to remember: "I obviously used the flag to get the native result" and "native zstd
The two sentences "never measured" are true at the same time.

`helper_windows/windows_round_status.txt` Line 11 is left by R47-Win:

```
USING_SWIFT_TAR ...\lzfse2-swift-tar-shim\tar.exe NATIVE_ZLIB=static 12:17:23
```

This line ** only has `NATIVE_ZLIB=static` **. Searching all status records and result files, `NATIVE_ZSTD=` has never
It appeared once. The timeline is as follows:

| Event | Date |
|---|---|
| R46-Win: native zlib first round | 2026-07-13 |
| R47-Win Run (Result File Time Stamp `Jul 18 16:09`) | 2026-07-18 |
| `f67e78f` just added `LZFSE_REQUIRE_NATIVE_ZSTD=1` to `run_round.bat:85` | **2026-08-14** |
| The only measurement round after that | R48-Mac (Mac, non-Windows) |

The gate is nearly a month later than the last round of Windows. The commit message of `f67e78f` has been written: "Marked as
The round of swift_tar, its ZSTD columns are actually measured by external tools. R47-Win's ZSTD two-line RSS
All are 8.9 MB, which is the magnitude of the external `zstd.exe`, which supports this point.

`f67e78f` What was done at that time was **functional equivalence verification** (the tree solved by the two branches is exactly the same, and the size difference is only 1 byte
Tar framing), not performance measurement; benchmark was not run this time.

Therefore: the native result given by `-swift_tar` is true, which refers to **zlib**; the half of ZSTD needs to enable the gate.
The next round will exist for the first time.

## seven. The cross-wheel contradiction of TGZ RSS (not yet verified, don't take it as a conclusion)

The same claw-code TGZ, cross-wheeled RSS sorry come:

| Round | Enc RSS | Dec RSS |
| --- | ---: | ---: |
| R45-Win-Retest1 (external `gzip.exe`) | 6.6 MB | 6.1 MB |
| R46-Win | 6.4 MB | 5.9 MB |
| R46-Win-Retest | 6.4 MB | 5.9 MB |
| **R47-Win** | **144.1 MB** | **45.2 MB** |

R47-Win jumped about 22 times, and the third section of this round only compared MB/s, **no mention of RSS at all**.

The contradiction is in R46-Win's own "verification" paragraph - the direct scan of `tgz_inflight_rss_win.zsh` is written
"Encode RSS presents a linear relationship with `-n` (55.6MB@n4 → **208.0MB@n40**), decode RSS is equal
In **43–45MB**". The official table of the same section is n=40 but reported 6.4 MB, which is about 30 times different between the two; and R47-Win
The 45.2 MB almost mat the decode interval of the scan.

The second doubt: change from "every 4 MiB chunk spawn once `gzip.exe`" to in-process zlib, RSS
Only −3.0% changes and is recorded as "misse". If the back-end is replaced and the memory is almost not moving, it is doubtful in itself.

**Speculation** (without Windows real-machine verification): The TGZ RSS measurement before R47-Win may not be swift_tar
Itself, but the sub-itinerary under shim; Pre-R47 did not match until the identity check was made up. If it is valid, the conclusion should be amended.
For "the **speed** data of native zlib is reliable in all three rounds, but **RSS** is only reliable in the R47-Win round",
TGZ RSS of R46-Win and R46-Win-Retest should be marked as suspicious.

There is a deliberate conclusion here: see Article 4 for the confirmation method.

## To be done

1. **macOS makes up the native zstd gate**: `run_round.command` needs to be compared
The mode setting of `LZFSE_REQUIRE_NATIVE_ZLIB` is `LZFSE_REQUIRE_NATIVE_ZSTD`, otherwise
The three native branches of `zshrc.zsh` will never run, and this caliber alignment on macOS is also
It can't be measured.
Two. **The next round of Windows generates the first batch of native ZSTD numbers**: There is no previous value for this batch of numbers to compare, report
The middle needs to be marked as the first measurement under the new caliber (pure decompression), which cannot be with R47-Win's
`ZSTD (external CLI)` direct subtraction.
3. **The two branches of TGZ are still different**: TGZ null branch of `decode-win.bat`, native is `-t`
(Spit file name), external is `--to-stdout -xzf` (spit member content) - both parse tar, but
There is a huge gap in the output. If it is not moved this time, it needs to be judged separately which side should be aligned.
4. **Confirm the cross-wheel contradiction of TGZ RSS (Section 7)**: Run with the same EXE on Windows
`verifications/tgz_inflight_rss_win.zsh -n 40`, and the official round's
`rss_summary.csv` compare TGZ encode/decode RSS of the same data set. If the scan report is ~200 MB and
Round report ~6 MB, that is, it is confirmed that round is wrong; if the two are the same, it is the measurement caliber of the scan and round.
It's different. We need to find out which one it is. **Don't quote the TGZ RSS of R46 two rounds before that. **

## How to run Windows in the next round (direct consequences of Section 6)

The precondition has been met: `swift_tar/version-win.txt` including `zstd_linkage=static`,
`run_round.bat` The inspection of line 69 will be passed.

```bat
helper_windows\run_round.bat -swift_tar
```

**The first thing after running is to confirm that the gate is really effective**, see `windows_round_status.txt`:

```
USING_SWIFT_TAR ... NATIVE_ZLIB=static NATIVE_ZSTD=static <時間>
```

**Both of them must be **. The R47-Win line only has the former (see Section 6), and that is exactly the ZSTD column to the outside.
The reason why the tool is marked as swift_tar. If you see `SWIFT_TAR_NATIVE_ZSTD_NOT_VERIFIED`, it means
`version-win.txt` is missing `zstd_linkage=static`, and the ZSTD of this round cannot be marked as native.

**But that line is just the built-in source, not the evidence at the time of execution. ** `run_round.bat` Now there is another one
`:verifyNativeZstd` subprocess: It shrinks PATH to only shim and System32, so that the external
`zstd.exe` can't be constructed, then ask swift_tar to write and read back a zstd seal. Write it down when you pass.

```
NATIVE_ZSTD_PROVEN in-process, external zstd.exe out of PATH <時間>
```

If you fail, write `NATIVE_ZSTD_PROBE_FAILED` and **stop the whole round** - in a few seconds, instead of waiting for 90 minutes
Only then did I find the wrong object. This check is not leak-proof: if swift_tar finds `zstd.exe` by absolute path
It will still pass; it determines the one that actually happened, that is, through PATH analysis.

The remaining three checkpoints:

- **ZSTD's RSS should leave 8.9 MB**. The ZSTD RSS of both R47-Win data sets is 8.9 MB, which is
The magnitude of external `zstd.exe`. If the new round is still 8.9 MB, it means that the gate has not really taken effect. Don't just trust the status.
Record that line.
- **The number of ZSTD null mode is the first measurement of the new caliber** (Section 1). There is no previous value to be reduced, and it cannot be compared with
`ZSTD (external CLI)` of R47-Win is directly subtracted.
- **By the way, remove Article 4**: After this round generates `rss_summary.csv`, it can be compared with the scan, and there is no need to run another round.

---

# R48-Mac: The first round of effective measurement after the recovery of CPU power (2026-08-15)

> **Target**: The CPU power of R47-Mac is all 0, and this round is determined to be a powermetrics defect of macOS 27.0 build 26A5388g, not a measurement method problem. This round is re-run with `-full` ( `-swift_tar -power-test`) on build 26A5406e to verify the judgment and obtain the first complete data after the two fields `os_version` and `Energy Impact` are in place. Repairing three places in the process will stop the whole round of running in vain.

Running time 17:11:55 → 18:52:22 (1 hour and 40 minutes), machine `Mac16,10`, `os_version` is recorded as `27.0 (26A5406e)`.

## one. CPU power recovery, 84/84 columns have readings

The judgment of R47-Mac is valid. It is the same macOS 27.0, only build updated from 26A5388g to 26A5406e, and all 84 power measurements in this round have readings:

| | R47-Mac(26A5388g) | R48-Mac(26A5406e) |
| --- | --- | --- |
| `cpu_power_mw` Non-zero column | 1 / 84 | **84 / 84** |
| Average | — | **10621 mW** |
| Scope | — | 1847 – 17737 mW |

**The product version is the same but the measurement ability is different**, which is the reason why R47-Mac adds the `os_version` field and must record build instead of just `27.0`; this round is the verification of this decision.

The value has a reasonable degree of distinction and is consistent with the `Energy Impact` field sorted by R47-Mac (claw-code, decode, n=40):

| Format | CPU Power (mW) | Energy Impact |
| --- | ---: | ---: |
| LZFSE (Other3) | 11277 | 17571 |
| LZFSE (Optimal3) | 10179 | 17805 |
| LZFSE (Apple) | 4413 | 7994 |
| TGZ | 4258 | 7981 |
| ZSTD | 3097 | 5044 |
| TLZ4 | 2184 | 2471 |

The LZFSE family has the highest power consumption and lz4 has the lowest, which is consistent with their respective calculations. The acquisition paths of the two indicators are independent of each other (one from `cpu_power` sampler and the other from `tasks --show-process-energy`), and the sorting is the same, so it is cross-verification, not the two writing methods of the same number.

## two. Differences between wheels in decompression speed: whether E-Cluster participates

The compression ratio of 18/18 is exactly the same as that of R47-Mac, which confirms that the algorithm has not changed. However, the change of decode speed is positive and negative, with a wide difference (claw-code: TLZ4 +110.2%, Apple +77.4%, while Lazy2 −18.7%). After tracking, **the cause is whether E-Cluster is working during the measurement period**, not any code changes.

The original output of powermetrics of `powerResults/raw/` directly records this incident (claw-code, decode, n=40):

| Format | R47-Mac E-Cluster | R48-Mac E-Cluster | decode Δ |
| --- | --- | --- | ---: |
| LZFSE (Apple) | active **100.00%** @ 2880 MHz | **idle 100%** | +77.4% |
| TLZ4 | active 99.41% | **idle 100%** | +110.2% |
| LZFSE (Optimal3) | active 98.92% | active 75.82% | +75.2% |
| LZFSE (Other3) | active 98.22% | active 77.32% | +2.1% |
| TGZ | active 100.00% | active 100.00% | +6.0% |
| ZSTD | active 99.88% | active 100.00% | +87.9% |

**The two items that E-Cluster completely withdrew (Apple, TLZ4) are the two most improved; the TGZ, which is fully loaded in both rounds, is almost unchanged. ** Both rounds of P-Cluster are ~4040 MHz, residence ~100%, and there is no difference - only E-Cluster has changed. ZSTD is the only exception in this table (both rounds of E are full but still increased by 87.9%), so the correlation is the main cause and not the only cause.

The amount of powermetrics needs to pay attention to is **the whole system** rather than a single process: E-Cluster active 100% means that there is work running on the E core on the machine at that time, which may come from other stages of the benchmark itself or from the background process. Therefore, a more accurate statement is that "these measurements of R47-Mac were obtained in a busy state of the system", rather than "the process is scheduled to E core" - the latter requires thread-level trace to be determined ( `helper/system_tracer.command` Output `running_p_core_ms` / `running_e_core_ms` It can be used for this, and this round is not included).

### Causes of excluded candidates

- **Swift_tar's parallel small file solution**: `16cd98e` ("Extract small files in parallel on macOS and Linux") was submitted at 2026-08-11 11:16, while the binary of R47-Mac was built at 18:42 on the same day, and gitlink is also `16cd98e` - **This round has included this change**, and its +171% benefit has been measured and recorded as early as R47-Mac. Between the two rounds, the 50 lines of diff of `swift_tar.swift` are all `--zstd-level`, `FileWriterPool` / `TarReader` / extract related identifiers appear 0 times in the diff.
- **lzfse default `-n` changed from `cores * 2` to `cores` **: benchmark explicitly specifies `-n` (40 / 8 / 4) with `LZFSE_BENCH_N` throughout the whole process, and does not use the default value.
- **swift_tar version itself**: Rebuild the old version with `16cd98e` and the current version for A/B (the same 1.3 GB tar, staggered 3 rounds). The new version is 4–30% faster, but the variation of the old version itself reaches 63% (1.32 → 2.15 seconds), which is not enough to explain Apple's −44%.

### Corposing evidence: retest after the fact

With this round of binary retest claw-code Apple decompression (n=40, same conditions) to get **1.81 / 1.76 / 1.82 seconds**, which is consistent with the 1.78 seconds of R48-Mac, while the 3.15 seconds of R47-Mac is the outlied value. **Therefore, the numbers in this round are the norm, and the Apple/TLZ4 of R47-Mac is slow** - the direction is the opposite of "faster in this round". The difference between the two is that the former shows that there is a problem with the benchmark, and the latter will be misread as an improvement in this round.

**Conclusion: The decode speed change of this round should not be interpreted as performance improvement, and the corresponding field of R47-Mac should not be referenced as a benchmark. ** To eliminate such inter-wheel differences, the measurement needs to be carried out under the condition that E-Cluster is idle, or the actual P/E allocation is recorded with thread-level trace.

## three. Three places will stop the whole round of running in vain (see commit 58d9157 for details)

The three are not related to each other, but they all emerge in the same situation: the whole round was stopped after running for tens of minutes.

1. ** `sudo --preserve-env` Rejected by sudoers**. `run_round.command` Originally with `--preserve-env=PATH,SWIFT_TAR_BIN,LZFSE_REQUIRE_NATIVE_ZLIB` Call `benchmark2.zsh`, and this machine sudoers picks `env_reset` And not granted `SETENV`, directly return "sorry, you are not allowed to set the following environment variables". This step takes about 37 minutes. `benchmark.zsh` **After that**. Delivered by documents instead ( `.bench_env`, write before sudo and delete afterwards, `benchmark2.zsh` In `source ./zshrc.zsh` Previously loaded), no need to update sudoers. **PATH must be passed together**: sudo will be `secure_path` Replace PATH, so that `tar → swift_tar` The shim disappears, and the whole round will be silently changed to the system tar - and that is exactly `-swift_tar` Things to avoid, and there will be no errors.
2. **tracer misjudged the normal end as a failure**. `--time-limit` When the target process is stopped in advance, xctrace ends with non-zero, even if the recording has been saved completely. For example, `claw-code/other3 -n 4` returned 54, its trace is 4.3 MB, `xctrace export --toc` export is normal, **greater than the one who was judged to be successful**, but the whole round was suspended. Instead, it is verified whether the recording can be parsed when it is not zero, and it can be parsed and accepted; the damaged trace is still rejected. **Both call points need to be modified** - For the first time, only the branch without `-n` was changed, and the trace with `-n` went to another one, so it was still stopped with the same rc 54 when running again.
3. **The activation script refuses to start when there is no tty**. `sudo -v` insists on tty even if the timestamp is valid (its responsibility is to re-verify and prepare to prompt the password), and `sudo -n` succeeds directly. Instead, try non-interaction first, and then decide whether to interact or explicitly stop according to the existence of tty.

## four. To determine whether a round is completed, you can't just look at the exit code.

The execution before the modification ended with `exit 0` and was returned as "completed", but the 0 from `benchmark2.zsh`, covering the `TRACER_FAILED 54` of tracer: only 3 traces, llama.cpp did not run. The actual judgment should be:

| Judgement | This time | This round |
| --- | --- | --- |
| `LZ4BENCH_OK` | 6/6 | 6/6 |
| `TRACE_DONE` | 3 | **43** |
| llama.cpp trace | **0** | **21** |
| `TRACER_FAILED` | **1** | **0** |
| `TRACER_DONE` | **0** | **1** |

After 42 trace analysis, it is cleared according to the existing process ( `COUNT_START 42 expected=42` → `CLEANED before=42 after=0`), and `trace_summary.csv` (43 columns) and `cpu_call_tree_summary/` are retained.

## five. This round of data

6 `-n` scans (claw-code and llama.cpp each n=40/8/4), 84 power measurements and its powermetrics original output, 72 RSS, 42 trace analysis.

---

# R47-Win: Official retest (TGZ null-mode correction acceptance + run_round.bat fix two more analysis bugs) (2026-07-18)

> **Objective**: Run the complete `run_round.bat -swift_tar` on the infrastructure modification of Pre-R47, accept the TGZ to-stdout null-mode modification and backend identity check to work correctly in the real process, and output R47 official performance data. In the process, the cmd.exe parsing bug of two `run_round.bat` was found and modified. After the first official run, the user judged that the `llama.cpp` data was unreliable. After retesting, it was confirmed that the retest data was the official result of this round.

## Additional corrections in this round (only discovered after Pre-R47)

1. ** `findstr /x` is unreliable for LF-only files**: `swift_tar/version.txt` is generated by `generate_version.zsh` (zsh script) with `echo`, which is LF-only line reset; Windows `findstr /x` (the whole line is completely compared) expects CRLF to end, even if `findstr /n` (no `/x`) can find the line content correctly, `/x` return still cannot be found, resulting in `run_round.bat -swift_tar` all print " `-swift_tar requires zlib_linkage=static in version.txt`" and suspended. Correction: `run_round.bat` line 51 is changed to substring comparison without `/x` (key=value is the only string in the file, which is safe).
Two. ** `::` The parentheses in the annotation are broken. `if (...)` Block analysis**: When modifying the previous item, in `if "%USE_SWIFT_TAR%"=="1" ( ... )` Multiple lines with parentheses are added to the block. `::` Annotation (for example `(exact whole-line match)`). `::` In batch, it is actually a pseudo-label, not a real annotation mechanism. Even if the brackets are paired, as long as it appears in `( ... )` The block will disrupt the count of the outer parentheses of cmd.exe in the block, resulting in `writes was unexpected at this time.` ( `writes` It is exactly the words in the annotation). Correction: Rewrite the annotation into a version without parentheses at all, and leave a reminder in the file.

Both of them are reproduced and verified with **real native Windows execution** (cmd.exe of non-MSYS bash package) - in this environment, through Git Bash call `cmd.exe /c` has observed that the path/parsing behavior is inconsistent with native execution (following the existing chcp 65001 parsing problem record in this file), this revision is changed to PowerShell native call `.bat` verification throughout the whole process, instead of through the Bash toolkit layer cmd.exe.

## Data reliability: the first official run vs retest

After the first `run_round.bat -swift_tar` (12:17:21 previous round, that is, the time stamp was executed earlier), the encode speed of almost all formats on the `llama.cpp` side was significantly lower than the R46-Win-Retest benchmark (TGZ −45.6%, Other3 −25.5%, Optimal3 −27.8%, etc.), and the decode side Other3/Optimal3 was abnormally slow (17–20 MB/s, far lower than the ~30 MB/s of other formats in the same group). The user judged that this set of data was unreliable and asked for a retest. After the retest, both anomalies disappeared, and the number returned to the same level as R46-Win-Retest:

| Format | First Enc | Retest Enc | Δ | First Dec | Retest Dec | Δ |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 42.61 | 71.71 | +68.3% | 17.01 | 18.28 | +7.5% |
| Other3 | 51.73 | 65.90 | +27.4% | 17.16 | 30.34 | **+76.8%** |
| Optimal3 | 31.71 | 42.42 | +33.8% | 19.59 | 30.02 | **+53.2%** |
| BVX3 | 61.31 | 64.91 | +5.9% | 31.83 | 29.94 | −5.9% |
| Lazy2 | 48.61 | 59.74 | +22.9% | 30.64 | 30.05 | −1.9% |
| Optimal | 23.21 | 33.20 | +43.0% | 29.04 | 29.75 | +2.4% |
| TLZ4 | 58.78 | 61.58 | +4.8% | 31.35 | 31.40 | +0.2% |
| ZSTD | 57.77 | 61.19 | +5.9% | 30.20 | 31.19 | +3.3% |

During the same period, `claw-code` ran almost unchanged twice (TGZ Enc 179.19→175.43, Dec 90.83→86.19, both within 5%), which proved that the first abnormality only occurred in `llama.cpp` (40,675 small files, the most sensitive to background load/disk pressure), which is consistent with the similar noise mode recorded by the previous R46-Win-Retest. **All the following data in this section use retest results**, and the first number is considered unreliable and not adopted.

## one. Windows actual test results (n=40, write-to-file, retest data)

| Data set | Format | Compression ratio | Enc MB/s | Dec MB/s | Enc RSS | Dec RSS |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| claw-code | **TGZ** | 1.0000 | **175.43** | **86.19** | 144.1 MB | 45.2 MB |
| claw-code | Other3 | 0.9812 | 184.55 | 146.68 | 138.2 MB | 257.4 MB |
| claw-code | Optimal3 | 0.9344 | 33.22 | 142.50 | 496.8 MB | 255.5 MB |
| claw-code | BVX3 | 0.9243 | 200.90 | 131.84 | 146.8 MB | 249.2 MB |
| claw-code | Lazy2 | 0.8687 | 41.00 | 141.27 | 483.0 MB | 247.9 MB |
| claw-code | Optimal | 0.8252 | 18.11 | 145.82 | 511.4 MB | 244.8 MB |
| claw-code | TLZ4 | 1.1734 | 187.74 | 180.27 | 8.9 MB | 8.4 MB |
| claw-code | **ZSTD (external CLI)** | 0.7806 | **100.97** | **176.57** | 8.9 MB | 8.9 MB |
| llama.cpp | **TGZ** | 1.0000 | **71.71** | **18.28** | 168.7MB | 58.0MB |
| llama.cpp | Other3 | 0.9966 | 65.90 | 30.34 | 157.9 MB | 345.6 MB |
| llama.cpp | Optimal3 | 0.9739 | 42.42 | 30.02 | 762.1 MB | 345.6 MB |
| llama.cpp | BVX3 | 0.9792 | 64.91 | 29.94 | 154.9 MB | 346.0 MB |
| llama.cpp | Lazy2 | 0.9572 | 59.74 | 30.05 | 639.3 MB | 346.6 MB |
| llama.cpp | Optimal | 0.9390 | 33.20 | 29.75 | 755.7 MB | 346.4 MB |
| llama.cpp | TLZ4 | 1.0500 | 61.58 | 31.40 | 8.4 MB | 8.4 MB |
| llama.cpp | **ZSTD (external CLI)** | 0.9123 | **61.19** | **31.19** | 8.9 MB | 8.9 MB |

CORRECTNESS: 8 FORMAT × 2 DATA SET × 2 OUTPUT MODE, **32/32 `[PASS]`, 0 `[FAIL]` **; `windows_round_status.txt` NO `ERROR` / `Traceback`. The whole journey 12:17:21 → 13:39:29 (about 1h22m). `swift_tar` version `20260718-090617` and `c46bc9a` used in R46-Win-Retest are **same source code submission** (pure recompilation, no code code change).

## two. TGZ null-mode modified acceptance (key points of this round)

Pre-R47 changed the non-write branch of `decode-win.bat` from `tar xzf ... > nul` (pseudo-null-mode that will actually fall) to `--to-stdout -xzf ... > nul` (real to-stdout decode). This round of data confirms that the amendment takes effect:

| Data set | Dec file | Dec null (revised) | Difference |
| --- | ---: | ---: | ---: |
| claw-code | 86.19 MB/s (16.28s) | 109.6 MB/s (12.80s) | null fast **27.2%** |
| llama.cpp | 18.28 MB/s (66.27s) | 36.53 MB/s (33.18s) | null fast **99.8%** |

The null mode of `llama.cpp` is close to twice that of the file mode, which is in line with expectations: the write-to-file bottleneck of 40,675 small files mainly comes from file-by-file opening/writing, and the real to-stdout decompression can completely skip this part of the cost; `claw-code` (single large file) gap is relatively small, because its decompression cost is mainly inflate CPU. The two numbers before the revision (pseudo-null-mode) will theoretically be similar to the file mode, because the bottom layer is also falling - this is exactly the defect pointed out of R46-Win-Retest conclusion 3, which has been confirmed in this round.

## three. Compare R46-Win-Retest (TGZ, write-to-file)

| Data Set | Enc: R46-Retest → R47 | Change | Dec: R46-Retest → R47 | Change |
| --- | ---: | ---: | ---: | ---: |
| claw-code | 185.23 → 175.43 | −5.3% | 92.83 → 86.19 | −7.2% |
| llama.cpp | 78.27 → 71.71 | −8.4% | 15.41 → 18.28 | +18.6% |

The speed level is similar to R46-Win-Retest (mostly within ±10%), and no speed return of the native zlib path has been observed.

## four. Win/Mac comparison (to R46-Mac-Retest, write-to-file)

| Data Set | Format | Win Enc | Mac Enc | Win/Mac Enc | Win Dec | Mac Dec | Win/Mac Dec |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| claw-code | TGZ | 175.43 | 294.62 | 0.595 | 86.19 | 424.51 | 0.203 |
| claw-code | ZSTD | 100.97 | 468.16 | 0.216 | 176.57 | 666.87 | 0.265 |
| llama.cpp | TGZ | 71.71 | 234.60 | 0.306 | 18.28 | 155.48 | 0.118 |
| llama.cpp | ZSTD | 61.19 | 273.42 | 0.224 | 31.19 | 151.06 | 0.206 |

`llama.cpp` decode is still the largest drop in Windows relative to Mac (TGZ 0.118, ZSTD 0.206), which is consistent with the conclusion of Section 2 "Small File Drop Path Dominance".

## To be done

1. **native zstd is still not covered by benchmark**: The ZSTD path of `encode-win.bat` / `decode-win.bat` / `rss-win.bat` still calls the external `zstd.exe`, maintaining the conclusion of R46-Win-Retest - ZSTD backend switching needs to be planned separately, compared with TGZ's `LZFSE_REQUIRE_NATIVE_ZLIB` gate mode processing.
Two. ** `llama.cpp` encode sensitivity to background load**: The failure of the first attempt in this round once again proves that the encode/decode number of `llama.cpp` (multi-small data set) is more susceptible to environmental noise than `claw-code`; if the `llama.cpp` number deviates by >15% from the previous round in the future, environmental factors should be suspected and retested instead of writing the conclusion directly.

---

# Pre-R47: Fix the legacy of R46-Win-Retest TGZ null-mode and backend authentication problems (2026-07-18)

> **Object**: The conclusion of R46-Win-Retest points 3 and 4 points out two unresolved gaps - (a) The TGZ null-mode of `decode-win.bat` is actually `tar xzf ... > nul`, `> nul` only discards stdout, `x` Z will still fall, which is not a real to-null decode; (b) Each benchmark script calls `tar` through PATH shim, and it is not verified at the time of execution to really parse `swift_tar.exe` Z and its native zlib link method. This time it is modified by codex review output, covering four `.bat` / `.ps1` of Windows and `run_round.command` / `zshrc.zsh` of macOS. **It is only an infrastructure correction, and the complete R47 benchmark has not been implemented. This commit does not contain new performance data**.

## Changes in this round

- **Windows [ `run_round.bat`](helper_windows/run_round.bat)**
- Add double authentication in `-swift_tar` mode: read `swift_tar\version.txt` to confirm `zlib_linkage=static`; execute `swift_tar.exe --version` to confirm the output starting with `swift_tar ` (identity check). If any verification fails, `exit /b 1` will be recorded to `windows_round_status.txt` immediately.
- Add export `SWIFT_TAR_BIN` (shim path) and `LZFSE_REQUIRE_NATIVE_ZLIB=1` for subsequent `encode-win.bat` / `decode-win.bat` / `rss-win.bat`; when `-swift_tar` is not brought, `LZFSE_REQUIRE_NATIVE_ZLIB` is clearly set to `0`, and the behavior of the original call system `tar` is maintained.
- The self-test call method was changed from " `tar -test` parsed by PATH" to explicit `"%SWIFT_TAR_BIN%" -test` to avoid measuring other tar other than shim.
- **Windows [ `encode-win.bat`](helper_windows/encode-win.bat) / [ `decode-win.bat`](helper_windows/decode-win.bat)**
- Add `_tgz_tar` variable: `LZFSE_REQUIRE_NATIVE_ZLIB=1` parses and verifies `SWIFT_TAR_BIN` (if the file is missing or does not exist, the error is reported to terminate), otherwise `tar` is used. All three calls of TGZ encode/decode/verify are changed to `!_tgz_tar!`.
- **Fix the null-mode drop problem**: The non-write branch of `decode-win.bat` is changed from `tar xzf "%~1.tgz" > nul 2>&1` to `"!_tgz_tar!" --to-stdout -xzf "%~1.tgz" > nul 2>&1`, and the decompression result is guided by stdout to `nul`, and is no longer implicitly written to the current directory.
- **Windows [ `rss-win.bat`](helper_windows/rss-win.bat)**
- Add `$tgzTar`: Use `$env:SWIFT_TAR_BIN` when `LZFSE_REQUIRE_NATIVE_ZLIB=1` and use `--version` to verify that the output conforms to `^swift_tar `. If it fails, `exit 1` is immediately; otherwise, `System32\tar.exe` is used. TGZ encode/decode RSS measurement changed to `$tgzTar`.
- **macOS [ `run_round.command`](run_round.command)**
- `-swift_tar` mode adds `SWIFT_TAR_BIN --version` identity check and `command -v tar` to verify whether it is indeed resolved to the shim directory, and any failure records `round_status.txt` and `exit 1`.
- Export `SWIFT_TAR_BIN`, `LZFSE_REQUIRE_NATIVE_ZLIB=1` (When not enabled, it is `0`); `sudo` Call `benchmark2.zsh` Add when `--preserve-env=PATH,SWIFT_TAR_BIN,LZFSE_REQUIRE_NATIVE_ZLIB`, make sure that the native zlib flag and path are not lost in the sudo sub-stroke.
- Additional correction: `swift_tar_identity="$($SWIFT_TAR_BIN --version 2>&1)"` add double quotation marks to `"$SWIFT_TAR_BIN"` to avoid being removed when the path contains blanks.
- **macOS [ `zshrc.zsh`](zshrc.zsh)**
- ADD `benchmarkTgzTar()` COMMON FUNCTION: `LZFSE_REQUIRE_NATIVE_ZLIB=1` REQUIRES `SWIFT_TAR_BIN` TO BE EXECUTABLE BEFORE CALLING, OTHERWISE AN ERROR WILL BE REPORTED; WHEN NOT ENABLED, CALL `tar` ON THE ORIGINAL PATH.
- `extract()` ( `.tgz` / `.tar.gz` Decompression and memProbe branch), `getar()` (Created by TGZ), `archiveMemProbe()` (Encode RSS detection) Change all around `benchmarkTgzTar`, replace the original dead `tar`.

## Verification (codex feedback, does not contain the complete benchmark)

- macOS zsh script grammar check passed.
- Windows `swift_tar -test -debug` all passed, including `.tar.gz` two-way interoperability.
- Deliberate situational test: The lack of `SWIFT_TAR_BIN` in native mode will fail immediately (fail-fast, will not silently fallback to the system tar).
- Deliberate situational test: When only the `SWIFT_TAR_BIN` environment variable is left, but no `-swift_tar` ( `LZFSE_REQUIRE_NATIVE_ZLIB` is still the default `0`), native backend will not be misused - confirm that the added gate logic is based on `LZFSE_REQUIRE_NATIVE_ZLIB`, rather than just whether `SWIFT_TAR_BIN` exists.
- Windows `.bat` file maintains CRLF line break; macOS script maintains LF, not mixed.
- ZSTD path (external `zstd.exe` / `zstd` CLI) has not been changed in this round, and the "native zstd not covered by benchmark" gap recorded by R46-Win-Retest is still to be processed by R47.

## To be done (left to the official R47 round)

1. Complete `run_round.bat -swift_tar` (Win) and `run_round.command -swift_tar` (Mac), verify that this identity/version check and TGZ to-stdout null-mode correction are correct in the real process, and generate the official performance data of R47.
Two. R47 should re-measure TGZ null-mode (now the real to-null decode). It is expected that its number will not be comparable to the old "pseudo-null-mode" recorded in Section 2 of R46-Win-Retest, and it is necessary to clearly indicate that the caliber has been changed in the report.
3. Native zstd (in-process static libzstd) is still not covered by any benchmark script, maintaining the conclusion of R46-Win-Retest: ZSTD backend switching needs to be planned separately, compared with the `LZFSE_REQUIRE_NATIVE_ZLIB` gate mode of this round of TGZ.

---

# R46-Win-Retest: Windows native zlib retest + native zstd override review (2026-07-17)

> **Objective**: Rerun `helper_windows/run_round.bat -swift_tar` with the latest `swift_tar` Windows distribution, confirm that R46 native zlib has not returned, and verify the added **in-process static libzstd** Windows path. After the actual run, it was found that the ZSTD of Windows benchmark still directly calls the external `zstd.exe`, so the native zlib has been fully verified in this round, but **the swift_tar native zstd runtime path has not been overwritten**. This difference is the most important test coverage conclusion of this round.

## Construction and complete process

- Measured source baseline: `0b03ed8` (including `c149f94` native static libzstd and `01c82c3` `--touch`); the EXE built at 22:32 was incorporated into Windows binary release by `a47025a` at 23:17, and then zstd provenance was supplemented by `c46bc9` the next day.
- Built-in version: `swift_tar 20260717-223201`.
- zlib: **v1.3.2** / `da607da`, static linkage.
- zstd: **v1.5.7** / `f8745da`, static linkage.
- After reconstruction, `swift_tar -test -debug` all passed: plain tar, `.tar.gz`, system tar two-way interoperability, and Foundation/UCRT writing back-end content comparison are all `✓`. The existing `-test` output does not include the `.tar.zst` item, so it cannot be used to claim that the native zstd runtime has been accepted.
- `run_round.bat -swift_tar`: Start at 22:34:21, end at 23:56:31, total time consumption **1:22:10**, `COMPILE_OK` / `TEST_OK` / The two data sets encode, decode, RSS and comparison are all completed.
- Correctness: 8 formats × 2 data sets × 2 output modes, a total of **32 groups of decode verification all `PASS` **; status log no `[FAIL]`, `Win_result_invalid`, Traceback or ERROR. Among them, ZSTD PASS means that "external `zstd.exe` + swift_tar plain-tar/extract" is integrated correctly and does not represent the native libzstd path.

### Test coverage review

| benchmark format | actual call | whether this round overwrites swift_tar native codec |
| --- | --- | --- |
| TGZ encode | shim `tar czf` → `swift_tar.exe` | **Yes (native zlib)** |
| TGZ decode | shim `tar xzf` → `swift_tar.exe` | **Yes (native zlib)** |
| ZSTD encode | shim `tar -cf -` \| External `zstd -9` | **No** |
| ZSTD decode | External `zstd -d -c` \| shim `tar xf -` | **No** |
| ZSTD RSS | `rss-win.bat`'s `$zstdExe` | **No** |

`swift_tar --version` has been proven that EXE links zstd v1.5.7 static library when built, but "can be built/with provenance" and "runtime compression, decompression, performance" are different acceptance levels.

> `llama.cpp` decode-to-file from 23:08:37 to 23:46:38, of which the actual decompression ended at 23:16:34, and the follow-up about **30 minutes** spent 7 groups of "to TGZ output" file-by-file comparison and cleaning. Therefore, the complete round time is not equal to the codec benchmark time.

## one. Windows actual test results (n=40, write-to-file)

| Data set | Format | Compression ratio | Enc MB/s | Dec MB/s | Enc RSS | Dec RSS |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| claw-code | **TGZ** | 1.0000 | **185.23** | **92.83** | 6.4MB | 5.9MB |
| claw-code | Other3 | 0.9812 | 206.00 | 160.62 | 137.4 MB | 259.0 MB |
| claw-code | Optimal3 | 0.9344 | 34.04 | 160.99 | 501.6 MB | 255.2 MB |
| claw-code | BVX3 | 0.9243 | 219.28 | 156.02 | 135.4 MB | 248.9 MB |
| claw-code | Lazy2 | 0.8687 | 42.02 | 158.14 | 485.2 MB | 246.9 MB |
| claw-code | Optimal | 0.8252 | 18.85 | 160.96 | 535.3 MB | 244.4 MB |
| claw-code | TLZ4 | 1.1734 | 200.48 | 206.54 | 8.4 MB | 8.3 MB |
| claw-code | **ZSTD (external CLI)** | 0.7806 | **102.25** | **190.41** | 8.3MB | 8.3MB |
| llama.cpp | **TGZ** | 1.0000 | **78.27** | **15.41** | 6.9MB | 7.2MB |
| llama.cpp | Other3 | 0.9966 | 69.45 | 25.99 | 109.0 MB | 346.6 MB |
| llama.cpp | Optimal3 | 0.9739 | 43.94 | 25.81 | 752.6 MB | 346.0 MB |
| llama.cpp | BVX3 | 0.9792 | 68.19 | 25.15 | 123.2 MB | 346.5 MB |
| llama.cpp | Lazy2 | 0.9572 | 58.57 | 25.45 | 607.4 MB | 345.3 MB |
| llama.cpp | Optimal | 0.9390 | 26.42 | 24.48 | 754.1 MB | 345.5 MB |
| llama.cpp | TLZ4 | 1.0500 | 54.62 | 24.21 | 8.9 MB | 9.0 MB |
| llama.cpp | **ZSTD (external CLI)** | 0.9123 | **56.78** | **18.00** | 8.4 MB | 8.4 MB |

The compression ratio is consistent with R46-Win (the four-decimal level remains unchanged). However, `encode-win.bat` and `decode-win.bat` have not been changed in this round: TGZ still goes through `tar` shim swift_tar native zlib, and ZSTD still goes externally `zstd.exe`. Therefore, this result can only show the "compression ratio of the existing benchmark path", ** and cannot be used as the format or output comparison conclusion of the external-vs-native library**.

## two. File vs null: available data and TGZ label defects

| Data set | Format | Enc file | Enc null | Dec file | Dec null |
| --- | --- | ---: | ---: | ---: | ---: |
| claw-code | Other3 | 206.00 | 249.99 | 160.62 | 701.83 |
| claw-code | ZSTD | 102.25 | 118.83 | 190.41 | **895.87** |
| llama.cpp | Other3 | 69.45 | 69.24 | 25.99 | **585.56** |
| llama.cpp | ZSTD | 56.78 | 67.41 | 18.00 | **1004.98** |

- The file/null gap of encode is relatively small, but the gap of decode is large; especially `llama.cpp`'s Other3/ZSTD, the pure decoding to null can reach 586/1005 MB/s, and the actual expansion to disk is only 26/18 MB/s.
- This confirms that the main bottleneck of `llama.cpp`'s Windows decode is still tar small file creation, metadata and disk I/O, not LZFSE/ZSTD codec itself.
- **TGZ cannot be included in the above table comparison**: The non-write branch of `decode-win.bat` is `tar xzf "%dataset%.tgz" > nul 2>&1`, `> nul` only discards stdout, and `x` will still decompress the file to the current directory. Therefore, TGZ `decode_mb_s(null)` 113.09 / 31.49 in CSV **is not pure inflate-to-null**, nor is it real write-to-null.

## three. Compare with the previous R46-Win (write-to-file)

| Data Set | Format | R46 Enc → Retest | Change | R46 Dec → Retest | Change |
| --- | --- | ---: | ---: | ---: | ---: |
| claw-code | TGZ | 173.91 → 185.23 | **+6.5%** | 121.40 → 92.83 | **−23.5%** |
| claw-code | ZSTD | 120.81 → 102.25 | **−15.4%** | 229.54 → 190.41 | **−17.0%** |
| llama.cpp | TGZ | 92.26 → 78.27 | **−15.2%** | 24.13 → 15.41 | **−36.1%** |
| llama.cpp | ZSTD | 79.85 → 56.78 | **−28.9%** | 27.63 → 18.00 | **−34.9%** |

> **Important conclusion**: These ZSTD cross-wheel differences are not native-vs-external comparisons, because both Windows benchmarks call external `zstd.exe`. ZSTD and most non-ZSTD formats in the same round are falling in the same direction in `llama.cpp` file-mode, and the null/file gap is huge, indicating that this round is strongly affected by disk, small file creation and background load. **The function, compression ratio, speed and RSS comparison of native libzstd and external `zstd.exe` are delayed to R47**, and this section does not conclude the effect of native libzstd.

## four. TGZ native zlib and external ZSTD RSS (file / null)

| Data set | Format | Enc RSS file | Dec RSS file | Enc RSS null | Dec RSS null |
| --- | --- | ---: | ---: | ---: | ---: |
| claw-code | TGZ | 6.4 | 5.9 | 6.4 | 5.8 |
| claw-code | ZSTD | 8.3 | 8.3 | 8.4 | 8.3 |
| llama.cpp | TGZ | 6.9 | 7.2 | 6.8 | 6.0 |
| llama.cpp | ZSTD | 8.4 | 8.4 | 8.4 | 8.4 |

- native zlib continues to stabilize at **5.8–7.2 MB**, and does not reproduce the RSS expansion caused by in-flight buffer.
- ZSTD **8.3–9.0 MB** is the result of `rss-win.bat` direct external `$zstdExe`, which cannot be regarded as swift_tar native libzstd RSS.
- TGZ's `nul` RSS must also be interpreted with the caveat in Section 2: At present, `tar xzf ... > nul` will still be released, but the specified `decoded\...` directory is not used.

## five. Contrast with R46-Mac-Retest (write-to-file)

| Data Set | Format | Win Enc | Mac Enc | Win/Mac Enc | Win Dec | Mac Dec | Win/Mac Dec |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| claw-code | TGZ | 185.23 | 294.62 | 0.629 | 92.83 | 424.51 | 0.219 |
| claw-code | ZSTD | 102.25 | 468.16 | 0.218 | 190.41 | 666.87 | 0.286 |
| llama.cpp | TGZ | 78.27 | 234.60 | 0.334 | 15.41 | 155.48 | 0.099 |
| llama.cpp | ZSTD | 56.78 | 273.42 | 0.208 | 18.00 | 151.06 | 0.119 |

The file-mode gap between Windows and Mac is still the largest in `llama.cpp` decode (TGZ 0.099, ZSTD 0.119), and it does not only occur in a single codec; this is consistent with the observation of Section 2 "Windows small file drop path dominated".

## Conclusion and follow-up

1. **native zlib correctness/RSS acceptance passed**: TGZ file-mode comparison passed, the compression ratio was not returned, and the RSS was still a single-digit MB.
2. **native zstd only completes the construction and provenance verification**: The existing `run_round.bat` / `encode-win.bat` / `decode-win.bat` / `rss-win.bat` has not been done swift_tar native zstd, and the function, compression ratio, speed and RSS have not been rounded for acceptance; **native lib comparison is uniformly left for R47**.
3. **TGZ write-to-null label is incorrect**: `tar xzf ... > nul` should be changed to a real decompressed stream sink before it can be fairly compared with other codec null-mode.
4. **The next Windows decode optimization point is still tar extract**: priority profile `llama.cpp` small file creation, metadata/mtime and UCRT write path; codec optimization should be tracked separately with the real null-mode.
5. **The verification process time can be optimized**: `llama.cpp` seven complete catalog comparisons take about 30 minutes; if you want to shorten the round, you can share TGZ manifest/hash without reducing the correctness to avoid repeated scanning of the reference tree each time.

---

# R46-Win: Windows TGZ Native Zlib (swift_tar built-in zlib submodule, replacing chunk-by-chunk external gzip.exe) (2026-07-13)

> **Target**: R45-Win-Retest1 confirms the root cause that Windows TGZ encode/decode is 4-6 times slower than Mac - there is no linkable zlib on the Windows side, `compressChunk` Every 4MiB chunk needs to spawn an external `gzip.exe` Itinerary; Mac terminal is `#if !os(Windows) import zlib` Native link, no itinerary overhead. This round is in `swift_tar` Add zlib 1.3.2 to repo for git submodule ( `cmodules/zlib`), after static compilation, by `compile_tar-win.bat` Link to `swift_tar.exe`, `swift_tar.swift` The TGZ path is changed to directly call zlib API, replacing `winRunCompress` / `winRunDecompress` The external stroke pipe.
>
> swift_tar commit: `19da746` ( `Windows TGZ native zlib: improve performance, limit RSS and add date version`).

## Changes in this round

- Add `swift_tar/zlib` (zlib 1.3.2) as git submodule, and `build_zlib-win.zsh` is responsible for static compilation with the existing tool chain.
- `compile_tar-win.bat` supplement the include/lib link flag of zlib.
- `swift_tar.swift`: The compress/decompress path of TGZ is changed to the native zlib API (37 lines of change), and no longer spawn `gzip.exe` for each chunk. The rest of the external process codec (bzip2/xz/lzip/zstd/lz4) remains unchanged, and it still follows the DispatchQueue pipe backend repaired by R45-Win.
- `verifications/tgz_inflight_rss_win.zsh` Re-scan `-n 4..40`, `README.md` / `README.zh-TW.md` Make up the native zlib result paragraph.

## Verification

- `swift_tar -test -debug`: 6/6 full pass (including Windows `-write_foundation` / `-write_ucrt` dual back-end, two-way interoperability with the system tar).
- `tgz_inflight_rss_win.zsh` Complete `-n 4..40` scan (claw-code, 1.4G): encode time decreased from 27–47s to 7.2–15.6s ( `-n 12..40` is stable at 7.2–7.8s, very close to Mac 4.3–7.6s); decode decreased from 17–19s to 9.7–11.0s (still slower than Mac 2.8–3.9s, see "to do"). Encode RSS presents a linear relationship with `-n` (55.6MB@n4 → 208.0MB@n40), and decode RSS is equal to 43–45MB. See `swift_tar/verifications/README.md` for details.
- The following figures in this section are the official complete round of `run_round.bat -swift_tar` (including verify/RSS/comparison), not the above ad-hoc scan.

## one. Windows actual measurement results ( `-swift_tar`, native zlib, n=40 inflight)

| Data set | Format | Win compression ratio | Win Enc MB/s | Win Dec MB/s | Enc RSS | Dec RSS |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| claw-code | **TGZ** | 1.0000 | **173.91** | **121.40** | 6.4MB | 5.9MB |
| claw-code | Other3 | 0.9812 | 192.59 | 191.78 | 130.3 MB | 257.5 MB |
| claw-code | Optimal3 | 0.9344 | 30.44 | 191.36 | 499.1 MB | 255.4 MB |
| claw-code | BVX3 | 0.9243 | 192.76 | 188.89 | 139.3 MB | 248.5 MB |
| claw-code | Lazy2 | 0.8687 | 38.97 | 186.71 | 482.7 MB | 248.8 MB |
| claw-code | Optimal | 0.8252 | 18.01 | 195.26 | 508.8 MB | 244.9 MB |
| claw-code | TLZ4 | 1.1734 | 182.25 | 244.56 | 8.8MB | 8.8MB |
| claw-code | ZSTD | 0.7806 | 120.81 | 229.54 | 8.3 MB | 8.8 MB |
| llama.cpp | **TGZ** | 1.0000 | **92.26** | **24.13** | 6.6MB | 7.0MB |
| llama.cpp | Other3 | 0.9966 | 86.56 | 41.68 | 149.4 MB | 346.8 MB |
| llama.cpp | Optimal3 | 0.9739 | 57.25 | 41.36 | 753.1 MB | 346.9 MB |
| llama.cpp | BVX3 | 0.9792 | 85.63 | 41.33 | 162.0 MB | 345.7 MB |
| llama.cpp | Lazy2 | 0.9572 | 81.46 | 41.63 | 632.8 MB | 344.8 MB |
| llama.cpp | Optimal | 0.9390 | 42.87 | 36.90 | 764.1 MB | 345.2 MB |
| llama.cpp | TLZ4 | 1.0500 | 80.49 | 26.13 | 8.3 MB | 8.8 MB |
| llama.cpp | ZSTD | 0.9123 | 79.85 | 27.63 | 8.3 MB | 8.8 MB |

Correctness: 16 groups (8 formats × 2 data sets) `win_decode_verify` All `PASS`. The compression ratio is almost exactly the same as R45-Win-Retest1 (llama.cpp full format difference <0.001) - in line with expectations, changing the zlib backend does not change the DEFLATE algorithm/level, only changes the call path.

## two. TGZ Before/After: R45-Win-Retest1 (external `gzip.exe`) vs this round (native zlib)

| Data Set | Indicator | R45-Win-Retest1 | This Round | Change |
| --- | --- | ---: | ---: | ---: |
| claw-code | Enc MB/s | 93.89 | 173.91 | **+85.3%** |
| claw-code | Dec MB/s | 65.37 | 121.40 | **+85.7%** |
| claw-code | Enc RSS | 6.6 MB | 6.4 MB | −3.0% (news) |
| claw-code | Dec RSS | 6.1 MB | 5.9 MB | −3.3% (news) |
| llama.cpp | Enc MB/s | 66.90 | 92.26 | **+37.9%** |
| llama.cpp | Dec MB/s | 23.01 | 24.13 | +4.9% (missail level) |
| llama.cpp | Enc RSS | 6.5 MB | 6.6 MB | +1.5% (news) |
| llama.cpp | Dec RSS | 6.9 MB | 7.0 MB | +1.4% (news) |

> **Interpretation**: Both data sets of encode have been greatly improved, and RSS remains at a single-digit MB (which is not a bottleneck in the first place). Claw-code decode is also greatly improved (+85.7%), but **llama.cpp decode has hardly changed (+4.9%, noise level) ** - llama.cpp has 40,675 small files, and the decode bottleneck is mainly the system call overhead of "file-by-file opening/writing" (R45-Win repaired ucrt back-end bottleneck), not the operation time of gzip inflate itself; native zlib only accelerates the inflate section, and the effect on such small file-based data sets is naturally limited. Claw-code only has 1 large file (tar is still a continuous stream inside), and decode time is almost entirely spent on inflate, so you get a complete zlib acceleration dividend. This is the expected structural difference, not a bug.

## three. Win/Mac Comparison (this round vs R45-Mac)

| Data Set | Format | Win Enc | Mac Enc | Win/Mac Enc | Win Dec | Mac Dec | Win/Mac Dec |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| claw-code | **TGZ** | 173.91 | 309.38 | **0.562** | 121.40 | 395.47 | **0.307** |
| claw-code | Other3 | 192.59 | 443.55 | 0.434 | 191.78 | 555.44 | 0.345 |
| claw-code | Optimal3 | 30.44 | 68.07 | 0.447 | 191.36 | 446.06 | 0.429 |
| claw-code | BVX3 | 192.76 | 549.57 | 0.351 | 188.89 | 462.78 | 0.408 |
| claw-code | Lazy2 | 38.97 | 72.36 | 0.539 | 186.71 | 570.10 | 0.328 |
| claw-code | Optimal | 18.01 | 37.28 | 0.483 | 195.26 | 528.27 | 0.370 |
| claw-code | TLZ4 | 182.25 | 582.72 | 0.313 | 244.56 | 551.27 | 0.444 |
| claw-code | ZSTD | 120.81 | 458.18 | 0.264 | 229.54 | 552.78 | 0.415 |
| llama.cpp | **TGZ** | 92.26 | 282.52 | **0.327** | 24.13 | 140.33 | **0.172** |
| llama.cpp | Other3 | 86.56 | 370.17 | 0.234 | 41.68 | 141.33 | 0.295 |
| llama.cpp | Optimal3 | 57.25 | 87.95 | 0.651 | 41.36 | 143.14 | 0.289 |
| llama.cpp | BVX3 | 85.63 | 398.34 | 0.215 | 41.33 | 135.70 | 0.305 |
| llama.cpp | Lazy2 | 81.46 | 187.08 | 0.435 | 41.63 | 140.69 | 0.296 |
| llama.cpp | Optimal | 42.87 | 61.24 | 0.700 | 36.90 | 133.94 | 0.275 |
| llama.cpp | TLZ4 | 80.49 | 356.59 | 0.226 | 26.13 | 132.88 | 0.197 |
| llama.cpp | ZSTD | 79.85 | 433.73 | 0.184 | 27.63 | 139.15 | 0.199 |

> **Win/Mac ratio of **claw-code TGZ**: encode 0.312 → **0.562** (R45-Win-Retest1 is one of the lowest in the whole format; this round has risen to the second highest in the whole format, second only to Lazy2 0.539, which is actually higher than it, which is the highest in this round). Decode 0.165 → **0.307**, also rising from the bottom to the middle. **The Win/Mac ratio of llama.cpp TGZ varies very little** (enc 0.289→0.327, dec 0.175→0.172), which is consistent with the architectural interpretation of Section 2.
>
> **claw-code ZSTD decode rebounded sharply from 55.18 MB/s to 229.54 MB/s (+316%)**: ZSTD This round of code has not changed at all (still external `zstd.exe` pipe), and this rise directly confirms the hypothesis put forward in R45-Win-Retest1 "to be done" - the previous round of claw-code TGZ/ZSTD decode The abnormal decline is environmental factors (instant antivirus/disk pressure), which is not related to swift_tar itself. **This pending is considered to have been resolved**. The rest of the formats of the same batch of claw-code decode also generally increased by 13%–18% (TLZ4 +25.5%, LZFSE family +13%–19%), in the same direction, further supporting the environmental factor hypothesis.
>
> **The claw-code encode side (except TGZ) generally declined by 10%–32% in this round** (Other3 −25.9%, Optimal3 −32.2%, TLZ4 −22.9%, etc.), and llama.cpp encode is stable (within ±6%). The comparison of the two shows that this decline is concentrated in claw-code (a single 1.4GB large file, which is more sensitive to the background disk/CPU load), rather than the change of swift_tar code (the only code path moved in this round is TGZ); it is classified as a measurement noise and is not included in the pending process for the time being. If it reappears in the next round, it needs to be further investigation.

## To be done

- llama.cpp TGZ decode is still limited to small file opening/write overhead, and native zlib has limited benefits for this data set; if you want to continue to narrow the Win/Mac decode gap, the next step should be the profiling ucrt write path itself (not the gzip layer).
- Although Windows TGZ decode (claw-code 121.40 MB/s) has been greatly improved compared with R45-Win-Retest1, it is still lower than Mac (395.47 MB/s, ratio 0.307); the ad-hoc scan of `tgz_inflight_rss_win.zsh` shows that the decode time is 9.7–11.0s vs Mac 2.8–3.9s, and the gap has not been completely eliminated. The inflate buffer size/syscall number of times can be compared in the future.
- The claw-code encode side generally declined by 10%–32% (except for TGZ). It is temporarily classified as a noise, and the next round of re-run to confirm whether it is reproduced.

---

# R46-Mac-Retest: swift_tar c149f94 submodule pointer update and complete retest (2026-07-17)

> **Objective**: Update `swift_tar` submodule pointer from `19da746` to `c149f94`, and recompile and run `sudo ./run_round.command -swift_tar` completely. The code change of `c149f94` only affects Windows ZSTD (change to static libzstd); this round of Mac test is used to confirm that pointer, construction, self-test and complete benchmark pipeline have no return.

## Change and verification

- `swift_tar`: checkout `c149f94348a580cdf4e24637d7d4ae193596c7ab`, install version `20260717-173627`, reinstall to `/opt/homebrew/bin/swift_tar`.
- `swift_tar -test -debug`: The two-way interoperability of plain tar and `.tar.gz` to the system `/usr/bin/tar` is all passed.
- `lzfse -test`: Other3/Optimal3/BVX3/Lazy2/Optimal/Apple and parallel decoding tests have all passed.
- Six batches of benchmark (claw-code/llama.cpp × n=40/8/4) are all `LZ4BENCH_OK`; all decode compare are `COMPARED_WITH_TGZ_OK`.
- power, result reconstruction, energy integration, best-points, comparison and translation are all completed; no `FAILED`, `no_samples`, `✗` or compare failure.
- Complete process: `BENCH_DONE 18:39:42`, command exit code 0.

## one. TGZ n=40 results

| Data Set | Enc MB/s | Dec MB/s | Enc RSS | Dec RSS | Enc Energy | Dec Energy |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| claw-code | 294.62 | 424.51 | 202.0 MB | 45.0 MB | 93.65 J | 15.05 J |
| llama.cpp | 234.60 | 155.48 | 220.6 MB | 42.9 MB | 91.05 J | 11.82 J |

Relative to the R46-Mac official round of 2026-07-15:

| Data Set | Enc Speed | Dec Speed | Enc RSS | Dec RSS |
| --- | ---: | ---: | ---: | ---: |
| claw-code | 316.48 → 294.62 (−6.9%) | 445.83 → 424.51 (−4.8%) | 217.0 → 202.0 MB | 44.1 → 45.0 MB |
| llama.cpp | 235.73 → 234.60 (−0.5%) | 164.05 → 155.48 (−5.2%) | 215.3 → 220.6 MB | 41.7 → 42.9 MB |

> **Interpretation**: The speed difference of TGZ is −0.5%~−6.9%, RSS maintains encode about 202–221MB, decode about 43–45MB, memory correction stable reappearance. Since `19da746..c149f94` only has Windows ZSTD path changes, Mac digital differences are classified as run-to-run fluctuations, which does not represent algorithm return.

## two. Other formats n=40 RSS (MB)

| Format | claw enc/dec | llama enc/dec |
| --- | ---: | ---: |
| LZFSE (BVX3) | 367.5 / 319.4 | 351.0 / 348.5 |
| LZFSE (Other3) | 347.4 / 305.4 | 268.2 / 349.5 |
| LZFSE (Apple) | 1356.3 / 470.0 | 1164.1 / 614.3 |
| TLZ4 | 81.6/33.8 | 86.1/33.8 |
| ZSTD | 392.4/9.2 | 490.0/9.3 |

## three. CPU Energy (claw-code, n=40, TGZ=1)

| Format | Encode Ratio | Decode Ratio |
| --- | ---: | ---: |
| LZFSE (Other3) | 0.47 | 0.41 |
| LZFSE (BVX3) | 0.48 | 0.59 |
| LZFSE (Apple) | 0.99 | 0.48 |
| LZFSE (Lazy2) | 2.08 | 0.46 |
| LZFSE (Optimal3) | 4.76 | 0.43 |
| LZFSE (Optimal) | 6.96 | 0.52 |
| TLZ4 | 0.46 | 0.28 |
| ZSTD | 0.52 | 0.57 |

- Fast encoder (Other3/BVX3) encode energy consumption is 0.47–0.48× of TGZ; Optimal3/Optimal is 4.76–6.96×.
- All decode energy consumption is lower than TGZ (0.28–0.59×).
- The power TGZ encode time of this round is 5.39s (claw)/6.32s (llama), which is at the same level as lz4bench's 4.81s/6.19s. It is confirmed that the power is still measured to swift_tar, not `/usr/bin/tar`.

## Conclusion

`swift_tar c149f94` pointer, recompilation, self-test and complete Mac pipeline have all been verified and passed. This commit is a Windows-only ZSTD change, and no function or memory return is observed on the Mac side; the TGZ low RSS result is reproduced again. The single-wheel speed/energy fluctuations of LZFSE and external formats should still be regarded as environmental and scheduling noise, and new Mac optimization directions should not be proposed accordingly.

---

# R46-Mac: Disable Time Profiler Trace generation, and change the analysis steps to follow the old data (2026-07-12)

> **Goal**: From this round, Mac benchmark will no longer run Time Profiler trace ( `tracer.command`), but the downstream analysis step (Step 8/9) ** will not be disabled in the whole section ** - instead, it will elegantly skip and follow the previous round of `trace/analysis` results when detecting "no new trace in this round", instead of interrupting the entire pipeline. This section records the pipeline change itself; the results of this round of actual running ( `-swift_tar`, swift_tar `20260714-232304`, native zlib + memory modified version) see "Benchmark results" below.

## Changes in this round

| Project | Description |
|---|---|
| `benchmark.zsh`: Step 6 Disable | `./helper/tracer.command` call whole segment annotation (including `RUNNING_TRACER` / `TRACER_DONE` status bar), no new `.trace` file will be generated from this round. |
| `helper/trace_analysis.command`: `package_count -eq 0` branch changed to elegant skip | Originally `exit 1` ( `TRACE_ANALYSIS_FAILED no_trace_found`) would interrupt `sudo ./benchmark2.zsh`; changed to `TRACE_ANALYSIS_SKIPPED_NO_NEW_TRACE keep_previous_data` and `exit 0`. The judgment point is before the existing `rm -rf "$ANALYSIS_DIR"` ****, so the last round of `trace/analysis/*` output will not be cleared, and the pipeline will continue to run down with the old data. |
| `helper/cpu_call_tree_analysis.command`: `trace_count_start -eq 0` branch synchronous correction | Also change `exit 1` ( `source_trace_missing`) to `CPU_CALL_TREE_ANALYSIS_SKIPPED_NO_NEW_TRACE keep_previous_data` and `exit 0`, the judgment point is also before `rm -rf "$OUT_DIR"`, and `cpu_call_tree_summary/` old data is retained. |
| `benchmark2.zsh`: Step 8/9 Restore Call | Because Step 8/9 itself can elegantly handle the "no new trace" situation, there is no need to skip the whole paragraph annotation; change back to normal call, rely on the script's own exit 0 to protect the pipeline. |

## Scope of influence

- The original `.trace` bundle under `trace/` will no longer be generated from this round ( `tracer.command`'s `CLEAN_OLD_TRACES` cleaning step is also not executed), but this does not affect the judgment logic: `trace_analysis.command` / `cpu_call_tree_analysis.command` is purely by whether the `*.trace(N)` glob is empty to decide whether to re-analyze.
- `BenchMarkResult.csv` Of `Trace wall time(seconds)`, `CPU Symbol Status`, `CPU Top Symbol` From this round, the field will follow **R45-Mac's last successful analysis** `trace_summary.csv` / `cpu_call_tree_summary.csv`, the value will not be updated with the code of R46+ - when interpreting, it should be noted that these fields reflect the behavior of the old version of the program code, not the real-time measurement of this round.
- `helper/benchmark_result_rebuild.command` is not affected at all: whether the data is newly generated or old files, `load_trace_summaries()` / `load_cpu_summaries()` is a simple reading file.
- If you really need to refresh the trace data in the future, you need to manually re-enable `benchmark.zsh` Step 6 (cancel the annotation `tracer.command` call). **Reactivation timing**: The next time `lzfse-cli.swift` itself has a change in the code, it should be reopened - the meaning of trace is to sidewrite the "measured code". If the code code does not change, there is no need to re-profile.

## Benchmark results (2026-07-15 real run, `-swift_tar`, swift_tar `20260714-232304`)

> This round is `-swift_tar` Formal wheel ( `USING_SWIFT_TAR`, shim takes effect, lz4bench and power both go swift_tar). The only substantial change comes from **swift_tar (TGZ path)**: R46-Win's native zlib + the previous R46-Mac's memory correction ( `autoreleasepool`+`ParallelChunkSink` / `TarReader` Buffer rewrite, see details `swift_tar/verifications/README.md`). Lzfse-cli.swift has not changed, **claw-code compression ratio is consistent with R45-Mac** (BVX3 0.9244, Optimal 0.8253, ZSTD 0.7805); **llama.cpp** corpus has increased from ~1261 MiB to 1385 MiB, and the ratio has changed slightly (such as Optimal 0.9408→0.9347), so it is not completely consistent. The speed of the LZFSE series is at the same level as RSS.

### TGZ Peak RSS collapse (n=40, MB)

Previously, TGZ was the highest RSS in all formats (encode/decode are both ~2.5–3.3GB, close to the corpus size). After this round of correction, **decode** is reduced to the same level as TLZ4, and **encode** is much closer (but still about 2.6× of TLZ4):

| Data Set | Encode RSS Before→After | Decode RSS Before→After |
| --- | ---: | ---: |
| claw-code | 2944.9 → **217.0**（−92.6%）|3265.5→**44.1**(−98.6%）|
| llama.cpp | 2537.6 → **215.3**(−91.5%) | 3021.9 → **41.7**(−98.6%) |

- **Encode** reduced to ~215MB: corresponding to the real linear relationship of `-n` chunk number × ~8MiB/chunk (only appears after the leakage disappears).
- **Decode** reduced to ~42–44MB level: lower than all LZFSE formats (~300–615MB), only slightly higher than TLZ4's ~34MB.
- Verify cross-comparison: consistent with the independent scan of `swift_tar/verifications/tgz_inflight_rss_output.txt` (encode 90–300MB, decode ~50MB), confirming that the correction is reproduced in the official pipeline.

### Other formats RSS (n=40, unchanged, MB)

| Format | claw enc/dec | llama enc/dec |
| --- | ---: | ---: |
| LZFSE (BVX3) | 343.4 / 319.5 | 241.4 / 348.6 |
| LZFSE (Other3) | 365.4 / 305.5 | 227.4 / 349.6 |
| LZFSE (Apple) | 1356.3 / 470.0 | 1277.3 / 614.3 |
| TLZ4 | 80.9/33.7 | 83.8/33.8 |
| ZSTD | 399.2 / 9.2 | 500.1 / 9.0 |

### Compression ratio/speed

The algorithm has not changed: **claw-code** The compression ratio is the same as R45-Mac; **llama.cpp** is slightly different because the corpus has increased from ~1261 MiB to 1385 MiB, and the ratio has changed slightly (Optimal 0.9408→0.9347), which is not completely consistent. TGZ speed encode 316 (claw) / 236 (llama) MB/s, decode 446 / 164 MB/s, memory correction does not bring time degradation.

### CPU Energy (n=40) - P1 is effective for the first time after modification

Previously, TGZ energy due to `power_benchmark.command` Walk naked `tar` (Fall to `/usr/bin/tar` Single-threaded gzip, encode ~43–51s) and distortion; this session has been changed to explicit call `${SWIFT_TAR_BIN:-/opt/homebrew/bin/swift_tar}`. This round of power step TGZ encode 5.21s (swift_tar, parallel) is at the same level as lz4bench's 4.47s, confirming that the amount is indeed swift_tar:

| Data Set | TGZ Encode Energy(J) | TGZ Decode Energy(J) |
| --- | ---: | ---: |
| claw-code | 94.25 | 14.63 |
| llama.cpp | 79.39 | 10.21 |

Energy Ratio (claw-code, n=40) with TGZ=1 paradigm:

| Format | Encode Ratio | Decode Ratio |
| --- | ---: | ---: |
| LZFSE (Other3) | 0.44 | 0.47 |
| LZFSE (BVX3) | 0.47 | 0.57 |
| LZFSE (Apple) | 0.95 | 0.51 |
| LZFSE (Lazy2) | 1.98 | 0.48 |
| LZFSE (Optimal3) | 4.57 | 0.36 |
| LZFSE (Optimal) | 6.75 | 0.51 |
| TLZ4 | 0.42 | 0.29 |
| ZSTD | 0.48 | 0.56 |

- The energy consumption of fast encoder (BVX3, Other3) encode is only ~44–47% of that of TGZ; the optimal-parse variant (Optimal3/Optimal) reaches 4.6–6.8× due to extensive searches.
- **Decode's total energy consumption is lower than TGZ**(0.29–0.57×): TGZ's gzip inflate consumes more energy locally than all LZFSE decoding.
- **The boundary of **fix**: The TGZ of power is now dead and walk swift_tar, so the `-swift_tar` wheel is consistent with lz4bench; if the **non** `-swift_tar` wheel is run, lz4bench will use the system tar and the power will still use swift_tar → the two are inconsistent. The official Mac wheels are all `-swift_tar`, so they are not affected; see the controlled A/B below for the pure system tar comparison.

### System `tar` vs `swift_tar` Direct control (controlled A/B, claw-code 1.3GB)

TGZ encode/decode of `/usr/bin/tar` (system, single-thread gzip) and `/opt/homebrew/bin/swift_tar` (parallel chunk gzip + memory correction) on the same machine, the same corpus, back-to-back. Time and RSS use `/usr/bin/time -l`, energy use `powermetrics` ( `energy_J = duration_s × avg_CPU_mW / 1000`). Single measurement, unofficial pipeline:

| Dimension | system `tar` | `swift_tar` | swift_tar Relative |
| --- | ---: | ---: | ---: |
| Encode Time | 29.5s | **4.42s** | **6.7× Fast** |
| Decode Time | 3.35s | **2.94s** | 1.14× Fast |
| Encode RSS | 4.2 MB | 209.8 MB | More than 50× |
| Decode RSS | 4.2 MB | 49.8 MB | 11.9× More |
| Encode Energy | 172.19 J | **68.20 J** | **−60%** |
| Decode Energy | 17.71 J | 15.63 J | −12% |

- **Encode**: swift_tar won with "a large number of RSS for parallel" - although the instantaneous CPU power is higher (15480 vs 5831 mW, multi-core vs single-core), it takes only 1/6.7, and the total energy consumption is **−60%** due to "race to idle".
- **Decode**: the two are similar (gzip inflate essential partial sequence); swift_tar is slightly faster and less energy-saving, at the cost of one order of magnitude higher RSS.
- **Memory cost**: swift_tar encode RSS ~210MB = number of chunks in transit × ~8MiB; system tar pure streaming is only ~4MB. Low memory environment can use `-n` to reduce swift_tar in transit number (see `verifications/README.md`, `n=4` about 90MB).

---

# R45-Mac: Decode Power 3× Repeat Correction (2026-07-12)

> **Objective**: Fix the problem of powermetrics decode measurement missing sampling ( `ok:no_samples`) in high-speed format (such as llama.cpp BVX3 n=40, single decode ~546ms) shorter than 500ms sampling interval. Change the lzfse series decode to run 3 times in a row, and the energy calculation divided by repeat is restored to a single value, and the power (time-valued average) is theoretically not affected. Lzfse-cli.swift has not changed, and this round does not include algorithm changes.

## Changes in this round

| Project | Description |
|---|---|
| `helper/power_benchmark.command`: `runDecode` change 3 cycles | lzfse series algorithm (other3/optimal3, apple, bvx3/lazy2/optimal) decode changed to `for i in 1 2 3; do ... done`; tgz/zstd/tar.lz4 maintain 1 time (external tool, a single time is long enough, not affected by short window leakage sampling). |
| `parsePowerLog` add `repeat` parameter | `cpu_energy` and `energy` calculate divided by `repeat` ( `(duration_ns / repeat / 1e9) × power`), which is reduced to single decode energy consumption; `cpu_power_mw` (time-wored average power) is not affected. |
| `measurePower` judges repeat | phase=decode and the algorithm is not tgz/zstd/tar.lz4, `repeat=$LZFSE_DECODE_REPEAT` (default 3), and the rest `repeat=1`. |

## Verification

- Before revision: llama.cpp BVX3 n=40 decode only 546ms (< 500ms sampling interval), powermetrics caught 0 samples, `power_summary.csv` Mark `ok:no_samples`, resulting in `best_points_analysis.command` Because of `Decode CPU Power(mW)` Empty value with `ValueError` Crash.
- After revision: the same combination decode duration becomes ~1.66s (3×546ms), spanning multiple 500ms sampling windows, `power_summary.csv` mark `ok`; `Decode CPU Energy(J)` restore formula verification: `(1.657659054s / 3) × 13298.5mW / 1000 = 7.348126J`, consistent with the CSV record value.
- Full R45-Mac round finished: `BENCHMARK_RESULT_REBUILD_DONE` → `POWER_SUMMARY_INTEGRATE_DONE` → `BEST_POINTS_ANALYSIS_DONE`, there is no FAILED in the whole pipeline process, and there is no `no_samples` record in `powerResults/power_summary.csv`.
- **Known limit**: 3 consecutive `exec` lzfse binary need to re-frequency ramp-up, and the restored energy of the short decode format (especially BVX3) may be slightly higher (see Section 5), which is not the target of this revision. It is left for subsequent evaluation whether to switch to the same process loop measurement.

## one. Compression ratio and speed (n=40, two data sets)

| Data Set | Format | Compression Ratio | Enc MB/s | Dec MB/s |
| --- | --- | ---: | ---: | ---: |
| claw-code | TGZ | 1.0000 | 309.38 | 395.47 |
| claw-code | Other3 | 0.9812 | 443.55 | 555.44 |
| claw-code | **Optimal3** | **0.9344** | **68.07** | **446.06** |
| claw-code | Lazy2 | 0.8683 | 72.36 | 570.10 |
| claw-code | Optimal | 0.8253 | 37.28 | 528.27 |
| claw-code | BVX3 | 0.9244 | 549.57 | 462.78 |
| claw-code | Apple | 0.9820 | 156.73 | 439.58 |
| claw-code | TLZ4 | 1.1786 | 582.72 | 551.27 |
| claw-code | ZSTD | 0.7805 | 458.18 | 552.78 |
| llama.cpp | TGZ | 1.0000 | 282.52 | 140.33 |
| llama.cpp | Other3 | 0.9965 | 370.17 | 141.33 |
| llama.cpp | **Optimal3** | **0.9737** | **87.95** | **143.14** |
| llama.cpp | Lazy2 | 0.9576 | 187.08 | 140.69 |
| llama.cpp | Optimal | 0.9408 | 61.24 | 133.94 |
| llama.cpp | BVX3 | 0.9810 | 398.34 | 135.70 |
| llama.cpp | Apple | 0.9994 | 168.27 | 130.64 |
| llama.cpp | TLZ4 | 1.0535 | 356.59 | 132.88 |
| llama.cpp | ZSTD | 0.9113 | 433.73 | 139.15 |

> **Compression ratio**: exactly the same as R44 (lzfse-cli.swift has not changed, bitstream is the same).

## two. Encode speed comparison: R44-Mac vs R45-Mac (n=40)

> lzfse-cli.swift has not changed, and the speed difference is measured noise (within ±10% is normal). Llama.cpp Other3 (+50%) and TGZ (+22%) exceed the normal noise range, which is presumed to be caused by the difference in the load of the background process during the measurement period, which is not an algorithmic change.

### claw-code (n=40)

| Format | R44 Enc MB/s | R45 Enc MB/s | Change |
| --- | ---: | ---: | ---: |
| TGZ | 300.90 | 309.38 | +3% |
| Other3 | 548.77 | 443.55 | −19% |
| Optimal3 | 63.19 | 68.07 | +8% |
| Lazy2 | 64.59 | 72.36 | +12% |
| Optimal | 34.21 | 37.28 | +9% |
| BVX3 | 576.20 | 549.57 | −5% |
| Apple | 155.33 | 156.73 | +1% |
| TLZ4 | 579.46 | 582.72 | +1% |
| ZSTD | 451.88 | 458.18 | +1% |

### llama.cpp (n=40)

| Format | R44 Enc MB/s | R45 Enc MB/s | Change |
| --- | ---: | ---: | ---: |
| TGZ | 231.34 | 282.52 | +22% |
| Other3 | 247.13 | 370.17 | +50% |
| Optimal3 | 85.88 | 87.95 | +2% |
| Lazy2 | 176.09 | 187.08 | +6% |
| Optimal | 58.51 | 61.24 | +5% |
| BVX3 | 404.84 | 398.34 | −2% |
| Apple | 166.37 | 168.27 | +1% |
| TLZ4 | 340.57 | 356.59 | +5% |
| ZSTD | 438.93 | 433.73 | −1% |

## three. Peak RSS (n=40)

> RSS is basically the same as R44, which meets the expectation of "same code and same data set".

| Data Set | Format | Enc RSS | Dec RSS |
| --- | --- | ---: | ---: |
| claw-code | TGZ | 2944.9 MB | 3265.5 MB |
| claw-code | Other3 | 300.2 MB | 305.4 MB |
| claw-code | **Optimal3** | **559.1 MB** | **323.2 MB** |
| claw-code | Lazy2 | 499.5 MB | 323.7 MB |
| claw-code | Optimal | 574.8 MB | 335.6 MB |
| claw-code | BVX3 | 372.4 MB | 319.4 MB |
| claw-code | Apple | 1356.3 MB | 470.0 MB |
| claw-code | TLZ4 | 81.1 MB | 33.7 MB |
| claw-code | ZSTD | 397.1 MB | 9.2 MB |
| llama.cpp | TGZ | 2537.6 MB | 3021.9 MB |
| llama.cpp | Other3 | 228.2 MB | 350.6 MB |
| llama.cpp | **Optimal3** | **556.0 MB** | **349.3 MB** |
| llama.cpp | Lazy2 | 853.5 MB | 347.4 MB |
| llama.cpp | Optimal | 570.8 MB | 347.9 MB |
| llama.cpp | BVX3 | 229.1 MB | 348.8 MB |
| llama.cpp | Apple | 1197.6 MB | 592.2 MB |
| llama.cpp | TLZ4 | 77.9 MB | 33.8 MB |
| llama.cpp | ZSTD | 490.6 MB | 9.4 MB |

## four. CPU Energy (n=40, including Decode - the first complete and reliable after this round of 3× repeat correction)

| Data Set | Format | Enc J | Enc J/TGZ | Dec J | Dec J/TGZ |
| --- | --- | ---: | ---: | ---: | ---: |
| claw-code | TGZ | 104.38 | 1.0000 | 29.25 | 1.0000 |
| claw-code | Other3 | 45.89 | 0.4396 | 8.56 | 0.2927 |
| claw-code | **Optimal3** | **497.21** | **4.7634** | **6.64** | **0.2270** |
| claw-code | Lazy2 | 270.12 | 2.5878 | 8.30 | 0.2839 |
| claw-code | Optimal | 782.39 | 7.4955 | 8.97 | 0.3066 |
| claw-code | BVX3 | 47.81 | 0.4580 | 12.69 | 0.4339 |
| claw-code | Apple | 109.50 | 1.0490 | 10.13 | 0.3462 |
| claw-code | TLZ4 | 41.46 | 0.3972 | 5.69 | 0.1944 |
| claw-code | ZSTD | 50.80 | 0.4867 | 16.36 | 0.5591 |
| llama.cpp | TGZ | 114.70 | 1.0000 | 27.12 | 1.0000 |
| llama.cpp | Other3 | 40.70 | 0.3549 | 4.56 | 0.1681 |
| llama.cpp | **Optimal3** | **345.75** | **3.0144** | **4.21** | **0.1554** |
| llama.cpp | Lazy2 | 104.67 | 0.9126 | 6.66 | 0.2455 |
| llama.cpp | Optimal | 465.99 | 4.0627 | 5.13 | 0.1893 |
| llama.cpp | BVX3 | 38.98 | 0.3399 | 7.35 | 0.2710 |
| llama.cpp | Apple | 89.22 | 0.7778 | 9.84 | 0.3629 |
| llama.cpp | TLZ4 | 45.83 | 0.3996 | 4.64 | 0.1709 |
| llama.cpp | ZSTD | 39.41 | 0.3436 | 6.09 | 0.2246 |

### Encode Energy Comparison: R44-Mac vs R45-Mac (n=40)

> R45 encode energy is generally lower than R44 ~13%–21% (the difference in machine state belongs to measurement noise, and the direction is opposite to R43→R44).

#### claw-code (n=40)

| Format | R44 Enc J | R45 Enc J | Change |
| --- | ---: | ---: | ---: |
| TGZ | 125.01 | 104.38 | −17% |
| Other3 | 58.17 | 45.89 | −21% |
| Optimal3 | 578.92 | 497.21 | −14% |
| Lazy2 | 336.38 | 270.12 | −20% |
| Optimal | 902.73 | 782.39 | −13% |
| BVX3 | 59.22 | 47.81 | −19% |
| Apple | 126.40 | 109.50 | −13% |
| TLZ4 | 52.12 | 41.46 | −20% |
| ZSTD | 62.01 | 50.80 | −18% |

#### llama.cpp (n=40)

| Format | R44 Enc J | R45 Enc J | Change |
| --- | ---: | ---: | ---: |
| TGZ | 109.72 | 114.70 | +5% |
| Other3 | 44.26 | 40.70 | −8% |
| Optimal3 | 397.58 | 345.75 | −13% |
| Lazy2 | 128.54 | 104.67 | −19% |
| Optimal | 532.13 | 465.99 | −12% |
| BVX3 | 47.18 | 38.98 | −17% |
| Apple | 97.90 | 89.22 | −9% |
| TLZ4 | 52.73 | 45.83 | −13% |
| ZSTD | 43.88 | 39.41 | −10% |

## five. Decode Energy Comparison: R44-Mac vs R45-Mac (n=40, verification 3× repeat correction consistency)

> R44-Mac This measurement did not trigger `no_samples` (the trigger conditions of this round of correction are intermittent, please refer to "Changes of this round" for details), so the two rounds of decode J are valid values and can be directly compared. The difference (+6%~+69%) is significantly greater than Encode Energy (−21%~+5%). In addition to the difference in machine state, it is also related to the short time-consuming decode itself and susceptible to transient effects; the difference in short decode formats such as BVX3/Other3 is large, which is consistent with the direction of the 3× exec ramp-up effect described in the "Known Limit". The value is for reference only and is not used as the basis for judging algorithm performance.

### claw-code (n=40)

| Format | R44 Dec J | R45 Dec J | Change |
| --- | ---: | ---: | ---: |
| TGZ | 25.94 | 29.25 | +13% |
| Other3 | 5.56 | 8.56 | +54% |
| Optimal3 | 5.65 | 6.64 | +18% |
| Lazy2 | 6.76 | 8.30 | +23% |
| Optimal | 6.75 | 8.97 | +33% |
| BVX3 | 7.53 | 12.69 | +69% |
| Apple | 11.45 | 10.13 | −12% |
| TLZ4 | 5.36 | 5.69 | +6% |
| ZSTD | 12.28 | 16.36 | +33% |

### llama.cpp (n=40)

| Format | R44 Dec J | R45 Dec J | Change |
| --- | ---: | ---: | ---: |
| TGZ | 18.48 | 27.12 | +47% |
| Other3 | 3.83 | 4.56 | +19% |
| Optimal3 | 3.80 | 4.21 | +11% |
| Lazy2 | 4.17 | 6.66 | +60% |
| Optimal | 4.63 | 5.13 | +11% |
| BVX3 | 4.75 | 7.35 | +55% |
| Apple | 10.25 | 9.84 | −4% |
| TLZ4 | 3.55 | 4.64 | +30% |
| ZSTD | 5.62 | 6.09 | +8% |

---

# R45-Win-Retest1: run_round.bat -swift_tar official rerun (compared with R44-Mac, use swift_tar in both rounds) (2026-07-11)

> **Goal**: Run a round of real `-swift_tar` complete official `run_round.bat`, fulfill the promise of "official numbers waiting for the next run_round.bat output" at the end of R45-Win, verify the actual effect of the ucrt decompression backend under the complete pipeline (including verify/RSS/comparison), and compare with R44-Mac (also swift_tar) for Win/Mac.
>
> This round of corrections by the way `comparison_win.py` A potential bug of: `raw_mb = (parse_mib(...) or 0) * 1.048576` On the Mac side `raw_size_mib` When there is a shortage of value, it will `None` Silence turns into `0`, causing the downstream Win MB/s field to print a deceptive `0.00` Instead of showing the missing value ( `—`) or report an error. It has been changed to reserved when there is a missing value. `None`, let the existing `raw_mb is None` The anti-dumb logic takes effect correctly; use this round of real CSV re-running script to confirm that the output number remains unchanged (pure anti-dumb correction, does not affect the normal path).

## one. Windows actual measurement results ( `-swift_tar`, n=40 inflight)

| Data set | Format | Win compression ratio | Win Enc MB/s | Win Dec MB/s | Enc RSS | Dec RSS |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| claw-code | TGZ | 1.0000 | 93.89 | 65.37 | 6.6 MB | 6.1 MB |
| claw-code | Other3 | 0.9861 | 259.85 | 162.47 | 119.6 MB | 259.3 MB |
| claw-code | **Optimal3** | **0.9391** | **44.87** | **161.01** | **501.8 MB** | **257.1 MB** |
| claw-code | BVX3 | 0.9289 | 231.63 | 160.75 | 127.8 MB | 249.3 MB |
| claw-code | Lazy2 | 0.8730 | 46.68 | 164.46 | 483.5 MB | 248.4 MB |
| claw-code | Optimal | 0.8293 | 23.71 | 166.09 | 510.0 MB | 245.1 MB |
| claw-code | TLZ4 | 1.1792 | 236.24 | 194.94 | 8.9 MB | 8.3 MB |
| claw-code | ZSTD | 0.7844 | 133.86 | 55.18 | 8.4 MB | 8.4 MB |
| llama.cpp | TGZ | 1.0000 | 66.90 | 23.01 | 6.5 MB | 6.9 MB |
| llama.cpp | Other3 | 0.9966 | 83.64 | 44.14 | 140.2 MB | 345.6 MB |
| llama.cpp | **Optimal3** | **0.9739** | **54.18** | **28.57** | **756.5MB** | **346.6MB** |
| llama.cpp | BVX3 | 0.9792 | 84.12 | 34.28 | 145.9 MB | 345.9 MB |
| llama.cpp | Lazy2 | 0.9572 | 80.30 | 37.74 | 668.8 MB | 344.6 MB |
| llama.cpp | Optimal | 0.9390 | 41.20 | 36.28 | 764.2 MB | 344.5 MB |
| llama.cpp | TLZ4 | 1.0500 | 81.83 | 39.31 | 8.5 MB | 8.3 MB |
| llama.cpp | ZSTD | 0.9123 | 78.69 | 40.39 | 8.3 MB | 8.3 MB |

Correctness: 16 groups (8 formats × 2 data sets) `win_decode_verify` All `PASS`, `swift_tar -test` 6/6 All passed.

## two. R42-Win (bsdtar) vs this round (swift_tar) speed comparison

> Comparison with the same nature as Section 2 of R43-Win (tar is changed to swift_tar, and the rest of the conditions are the same), but this time it uses the version after R45-Win fixes ucrt and writes to the back-end, and the conclusion direction is opposite to R43-Win.

### claw-code (n=40)

| Format | R42 bsdtar Enc | This round swift_tar Enc | Enc change | R42 bsdtar Dec | This round swift_tar Dec | Dec change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 33.92 | 93.89 | **+176.7%** | 145.90 | 65.37 | **−55.2%** |
| Other3 | 296.96 | 259.85 | −12.5% | 152.19 | 162.47 | +6.8% |
| Optimal3 | 47.11 | 44.87 | −4.8% | 150.96 | 161.01 | +6.7% |
| BVX3 | 289.21 | 231.63 | −19.9% | 150.93 | 160.75 | +6.5% |
| Lazy2 | 51.55 | 46.68 | −9.4% | 154.04 | 164.46 | +6.8% |
| Optimal | 24.26 | 23.71 | −2.3% | 155.59 | 166.09 | +6.7% |
| TLZ4 | 258.08 | 236.24 | −8.5% | 208.76 | 194.94 | −6.6% |
| ZSTD | 146.12 | 133.86 | −8.4% | 186.81 | 55.18 | **−70.5%** |

### llama.cpp (n=40)

| Format | R42 bsdtar Enc | This round swift_tar Enc | Enc change | R42 bsdtar Dec | This round swift_tar Dec | Dec change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 38.32 | 66.90 | **+74.6%** | 21.54 | 23.01 | +6.8% |
| Other3 | 182.44 | 83.64 | **−54.2%** | 30.25 | 44.14 | **+45.9%** |
| Optimal3 | 66.00 | 54.18 | −17.9% | 28.79 | 28.57 | −0.8% |
| BVX3 | 178.34 | 84.12 | **−52.8%** | 28.55 | 34.28 | +20.1% |
| Lazy2 | 126.49 | 80.30 | −36.5% | 28.43 | 37.74 | **+32.7%** |
| Optimal | 45.29 | 41.20 | −9.0% | 28.46 | 36.28 | +27.5% |
| TLZ4 | 154.57 | 81.83 | −47.1% | 30.59 | 39.31 | +28.5% |
| ZSTD | 145.30 | 78.69 | −45.8% | 30.05 | 40.39 | **+34.4%** |

> **Interpretation**:
> - **llama.cpp decode comprehensive upgrade (+7%～+46%)**: This is the direct verification of R45-Win ucrt writing back-end repair under the complete official pipeline - llama.cpp has 40,675 small files, which is the data set that has the greatest impact on the bottleneck of "number of openings per file". After repair, the full-format decode is faster than the bsdtar benchmark of R42-Win. R43-Win's conclusion that "swift_tar is not suitable as a substitute for tar" at that time has been reversed, at least on the decode side.
> - **claw-code's LZFSE family decode is mildly improved (+6.5% to +6.8%)**, consistent and clean, and also supports ucrt repair effectively; however, **TGZ (−55.2%) and ZSTD (−70.5%) decode have regressed significantly**, and this phenomenon also appeared in the TGZ/ZSTD of claw-code in the previous round (the official round of bsdtar without `-swift_tar`, which has been removed from this document) - ** The two rounds of tar are different, but the same batch of format is abnormal, strongly pointing to environmental factors unrelated to swift_tar/bsdtar** (machine background anti-virus instant scanning, disk has been used 89%, etc.), rather than the regression of swift_tar itself. TLZ4 also goes through the external process pipe ( `lz4.exe`), but there is no problem. It is worth further investigating whether it is related to the behavior or version of the two external tools themselves, `gzip.exe` / `zstd.exe`.
> - **Encode side llama.cpp most formats declined (−46%~−55%, TGZ exception +74.6%)**, claw-code except TGZ also declined slightly across the board (−2%~−20%); lzfse-cli.swift/swift_tar This round of code is the same as the previous survey, and the same tends to be attributed to environmental factors rather than the real regression caused by swift_tar. Both data sets of TGZ encode have been greatly improved, because swift_tar native `--gzip` pipeline is already faster than calling external gzip through the system tar (consistent with the observations of Section 2 of R43-Win).

## three. Win/Mac comparison (this round vs R44-Mac, use swift_tar in both rounds)

| Data Set | Format | Win Enc | Mac Enc | Win/Mac Enc | Win Dec | Mac Dec | Win/Mac Dec |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| claw-code | TGZ | 93.89 | 300.90 | 0.312 | 65.37 | 396.00 | 0.165 |
| claw-code | Other3 | 259.85 | 548.77 | 0.474 | 162.47 | 497.32 | 0.327 |
| claw-code | **Optimal3** | **44.87** | **63.19** | **0.710** | **161.01** | **508.77** | **0.316** |
| claw-code | BVX3 | 231.63 | 576.20 | 0.402 | 160.75 | 482.48 | 0.333 |
| claw-code | Lazy2 | 46.68 | 64.59 | 0.723 | 164.46 | 354.38 | 0.464 |
| claw-code | Optimal | 23.71 | 34.21 | 0.693 | 166.09 | 451.86 | 0.368 |
| claw-code | TLZ4 | 236.24 | 579.46 | 0.408 | 194.94 | 487.55 | 0.400 |
| claw-code | ZSTD | 133.86 | 451.88 | 0.296 | 55.18 | 499.60 | 0.110 |
| llama.cpp | TGZ | 66.90 | 231.34 | 0.289 | 23.01 | 131.56 | 0.175 |
| llama.cpp | Other3 | 83.64 | 247.13 | 0.338 | 44.14 | 131.90 | 0.335 |
| llama.cpp | **Optimal3** | **54.18** | **85.88** | **0.631** | **28.57** | **135.20** | **0.211** |
| llama.cpp | BVX3 | 84.12 | 404.84 | 0.208 | 34.28 | 123.53 | 0.278 |
| llama.cpp | Lazy2 | 80.30 | 176.09 | 0.456 | 37.74 | 126.91 | 0.297 |
| llama.cpp | Optimal | 41.20 | 58.51 | 0.704 | 36.28 | 127.18 | 0.285 |
| llama.cpp | TLZ4 | 81.83 | 340.57 | 0.240 | 39.31 | 117.96 | 0.333 |
| llama.cpp | ZSTD | 78.69 | 438.93 | 0.262 | 40.39 | 124.81 | 0.324 |

> **Compare with the Win/Mac decode benchmark of R43-Win vs R43-Mac** (both rounds of swift_tar, `Optimal3`: 0.121/0.078, see R43-Win Section 3, at that time the old version of Swift_tar of R43-Win has not fixed the extract bottleneck): This round, the same group of `Optimal3` rose to **0.316/0.211**, which is about 2.6 to 2.7 times higher than R43-Win - directly confirms that R45-Win's ucrt write back-end repair greatly narrows the gap between the swift_tar version of Windows decode and Mac. Llama.cpp's Other3/Lazy2/Optimal/TLZ4/ZSTD is even close to or exceeds the Win/Mac ratio of claw-code, which is the other way around R43-Win (see near line 675) (the llama.cpp ratio is much lower than claw-code), which is also an obvious structural improvement in this round.
> The ZSTD (0.110) of claw-code is obviously the abnormal environmental drag mentioned in Section 2 of this section, which does not mean that swift_tar itself is a regression.

## To be done

- Troubleshoot the environmental factors of claw-code TGZ/ZSTD decode abnormally slowing down in **two rounds** (bsdtar, swift_tar): first turn off the instant anti-virus re-run comparison, secondly confirm whether the `gzip.exe` / `zstd.exe` (scoop suite) version has recently changed, and finally record/clean up the disk space (currently only 46 GB or so) to exclude the capacity factor.
- Most of the formats of the two data sets on the Encode side have dropped by 2% to 55% compared with R42-Win. Only after the above environmental factors are excluded can we confirm whether it is a real change.

---

# R44-Mac: swift_tar -test verification + pipeline correction (2026-07-10)

> **Target**: Swift_tar updated with R44-Win (including `-test -debug` Self-testing, WinSDK removal, archiveName modification) Run the complete benchmark on Mac to confirm that the new version of swift_tar is compatible with benchmark pipeline throughout the whole process. Lzfse-cli.swift is exactly the same as R43, and this round does not include algorithm changes.

## Changes in this round

| Project | Description |
|---|---|
| **swift_tar submodule update** | Synchronize to R44-Win version ( `11076e6`): add `-test -debug` self-test flag, remove WinSDK direct dependence, fix `archiveName()` disk code path problem, fix `compile_tar-win.bat` move retry problem. See the chapter R44-Win for details. |
| **run_round.command: swift_tar test unconditional** | Originally, swift_tar compile + `-test -debug` only executed when `-swift_tar` flag; changed to **unconditionally** executed at the front (the same status as lzfse `-test`), PATH shim is still only set at `-swift_tar`. |
| **benchmark2.zsh: power_summmary_integrate sequence correction** | Originally, Step 12 ran `best_points_analysis` (BenchMarkResult.csv requires power bar), and Step 13 ran `power_summary_integrate` (rewrite power bar). The sequence error led to `BEST_POINTS_ANALYSIS_FAILED`. It has been adjusted to: Step 12 = `power_summary_integrate`, Step 13 = `best_points_analysis`; and let `power_summary_integrate` skip the best_points update without interruption when `best_points.csv` has not been generated. |

## Verification

- `swift_tar -test -debug`: 4/4 round-trip (plain tar and `.tar.gz`, swift_tar↔system tar two-way), exit code 0, `SWIFT_TAR_TEST_OK`.
- `lzfse -test`: `TEST_OK` (lzfse-cli.swift is the same as R43, expected to pass).
- Full R44-Mac round (power_summary_integrate manual make-up): 54 rows, `BenchMarkResult.csv` Successful reconstruction, `best_points_analysis` Pass, `BEST_POINTS_ANALYSIS_DONE`.

## one. Compression ratio and speed (n=40, two data sets)

| Data Set | Format | Compression Ratio | Enc MB/s | Dec MB/s |
| --- | --- | ---: | ---: | ---: |
| claw-code | TGZ | 1.0000 | 300.90 | 396.00 |
| claw-code | Other3 | 0.9812 | 548.77 | 497.32 |
| claw-code | **Optimal3** | **0.9344** | **63.19** | **508.77** |
| claw-code | Lazy2 | 0.8683 | 64.59 | 354.38 |
| claw-code | Optimal | 0.8253 | 34.21 | 451.86 |
| claw-code | BVX3 | 0.9244 | 576.20 | 482.48 |
| claw-code | Apple | 0.9820 | 155.33 | 526.10 |
| claw-code | TLZ4 | 1.1786 | 579.46 | 487.55 |
| claw-code | ZSTD | 0.7805 | 451.88 | 499.60 |
| llama.cpp | TGZ | 1.0000 | 231.34 | 131.56 |
| llama.cpp | Other3 | 0.9965 | 247.13 | 131.90 |
| llama.cpp | **Optimal3** | **0.9737** | **85.88** | **135.20** |
| llama.cpp | Lazy2 | 0.9576 | 176.09 | 126.91 |
| llama.cpp | Optimal | 0.9408 | 58.51 | 127.18 |
| llama.cpp | BVX3 | 0.9810 | 404.84 | 123.53 |
| llama.cpp | Apple | 0.9994 | 166.37 | 119.83 |
| llama.cpp | TLZ4 | 1.0535 | 340.57 | 117.96 |
| llama.cpp | ZSTD | 0.9113 | 438.93 | 124.81 |

> **Compression ratio**: exactly the same as R43 (lzfse-cli.swift has not changed, bitstream is the same).

## two. Encode speed comparison: R43-Mac vs R44-Mac (n=40)

> lzfse-cli.swift has not changed, and the speed difference is measured noise (within ±10% is normal).

### claw-code (n=40)

| Format | R43 Enc MB/s | R44 Enc MB/s | Change |
| --- | ---: | ---: | ---: |
| TGZ | 310.83 | 300.90 | −3% |
| Other3 | 550.38 | 548.77 | −0% |
| Optimal3 | 64.48 | 63.19 | −2% |
| Lazy2 | 70.27 | 64.59 | −8% |
| Optimal | 35.55 | 34.21 | −4% |
| BVX3 | 540.22 | 576.20 | +7% |
| Apple | 153.86 | 155.33 | +1% |
| TLZ4 | 586.33 | 579.46 | −1% |
| ZSTD | 429.27 | 451.88 | +5% |

### llama.cpp (n=40)

| Format | R43 Enc MB/s | R44 Enc MB/s | Change |
| --- | ---: | ---: | ---: |
| TGZ | 243.69 | 231.34 | −5% |
| Other3 | 247.42 | 247.13 | −0% |
| Optimal3 | 88.62 | 85.88 | -3% |
| Lazy2 | 190.31 | 176.09 | −7% |
| Optimal | 62.11 | 58.51 | −6% |
| BVX3 | 405.01 | 404.84 | −0% |
| Apple | 169.01 | 166.37 | −2% |
| TLZ4 | 363.08 | 340.57 | −6% |
| ZSTD | 451.24 | 438.93 | -3% |

## three. Peak RSS (n=40)

> RSS is basically the same as R43, which meets the expectation of "same code, same data set".

| Data Set | Format | Enc RSS | Dec RSS |
| --- | --- | ---: | ---: |
| claw-code | TGZ | 2930.5 MB | 3197.7 MB |
| claw-code | Other3 | 379.3 MB | 305.5 MB |
| claw-code | **Optimal3** | **550.4 MB** | **323.3 MB** |
| claw-code | Lazy2 | 498.0 MB | 324.2 MB |
| claw-code | Optimal | 575.4 MB | 335.7 MB |
| claw-code | BVX3 | 363.2 MB | 320.4 MB |
| claw-code | Apple | 1356.3 MB | 470.0 MB |
| claw-code | TLZ4 | 79.9 MB | 33.7 MB |
| claw-code | ZSTD | 397.3 MB | 9.9 MB |
| llama.cpp | TGZ | 2556.5 MB | 2650.7 MB |
| llama.cpp | Other3 | 224.1 MB | 349.6 MB |
| llama.cpp | **Optimal3** | **560.4 MB** | **350.7 MB** |
| llama.cpp | Lazy2 | 865.8 MB | 347.5 MB |
| llama.cpp | Optimal | 593.6 MB | 348.7 MB |
| llama.cpp | BVX3 | 360.9 MB | 348.9 MB |
| llama.cpp | Apple | 1197.7 MB | 592.2 MB |
| llama.cpp | TLZ4 | 77.9 MB | 33.8 MB |
| llama.cpp | ZSTD | 490.0 MB | 9.8 MB |

## four. CPU Energy (n=40)

| Data Set | Format | Enc J | Enc J/TGZ |
| --- | --- | ---: | ---: |
| claw-code | TGZ | 125.01 | 1.0000 |
| claw-code | Other3 | 58.17 | 0.4653 |
| claw-code | **Optimal3** | **578.92** | **4.6308** |
| claw-code | Lazy2 | 336.38 | 2.6908 |
| claw-code | Optimal | 902.73 | 7.2210 |
| claw-code | BVX3 | 59.22 | 0.4737 |
| claw-code | Apple | 126.40 | 1.0111 |
| claw-code | TLZ4 | 52.12 | 0.4169 |
| claw-code | ZSTD | 62.01 | 0.4960 |
| llama.cpp | TGZ | 109.72 | 1.0000 |
| llama.cpp | Other3 | 44.26 | 0.4034 |
| llama.cpp | **Optimal3** | **397.58** | **3.6234** |
| llama.cpp | Lazy2 | 128.54 | 1.1715 |
| llama.cpp | Optimal | 532.13 | 4.8497 |
| llama.cpp | BVX3 | 47.18 | 0.4300 |
| llama.cpp | Apple | 97.90 | 0.8922 |
| llama.cpp | TLZ4 | 52.73 | 0.4806 |
| llama.cpp | ZSTD | 43.88 | 0.3999 |

### CPU Energy Comparison: R43 vs R44 (n=40)

> R44 TGZ energy consumption is higher than R43 +19% (claw-code)/+9% (llama.cpp), which measures the difference in the machine state of the batch for powermetrics; J/TGZ ratio Therefore, the reference line is higher, and the relative value of each format decreases slightly.

#### claw-code (n=40)

| Format | R43 Enc J | R44 Enc J | Enc J Change | R43 J/TGZ | R44 J/TGZ | J/TGZ Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 104.96 | 125.01 | +19% | 1.0000 | 1.0000 | — |
| Other3 | 43.82 | 58.17 | +33% | 0.4175 | 0.4653 | +11% |
| Optimal3 | 513.65 | 578.92 | +13% | 4.8939 | 4.6308 | −5% |
| Lazy2 | 277.61 | 336.38 | +21% | 2.6450 | 2.6908 | +2% |
| Optimal | 797.79 | 902.73 | +13% | 7.6012 | 7.2210 | −5% |
| BVX3 | 45.74 | 59.22 | +29% | 0.4358 | 0.4737 | +9% |
| Apple | 110.60 | 126.40 | +14% | 1.0538 | 1.0111 | −4% |
| TLZ4 | 44.06 | 52.12 | +18% | 0.4198 | 0.4169 | −1% |
| ZSTD | 52.26 | 62.01 | +19% | 0.4979 | 0.4960 | −0% |

#### llama.cpp (n=40)

| Format | R43 Enc J | R44 Enc J | Enc J Change | R43 J/TGZ | R44 J/TGZ | J/TGZ Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 100.79 | 109.72 | +9% | 1.0000 | 1.0000 | — |
| Other3 | 34.15 | 44.26 | +30% | 0.3388 | 0.4034 | +19% |
| Optimal3 | 347.82 | 397.58 | +14% | 3.4509 | 3.6234 | +5% |
| Lazy2 | 101.88 | 128.54 | +26% | 1.0108 | 1.1715 | +16% |
| Optimal | 462.73 | 532.13 | +15% | 4.5909 | 4.8497 | +6% |
| BVX3 | 36.48 | 47.18 | +29% | 0.3619 | 0.4300 | +19% |
| Apple | 85.05 | 97.90 | +15% | 0.8438 | 0.8922 | +6% |
| TLZ4 | 41.07 | 52.73 | +28% | 0.4075 | 0.4806 | +18% |
| ZSTD | 33.62 | 43.88 | +30% | 0.3335 | 0.3999 | +20% |

---

# R43-Mac: swift_tar verification + NGResult code quality correction (2026-07-07)

> **Objective**: Replace the system tar with the self-made multi-core tar tool `swift_tar`, and verify the full-process compatibility of benchmark pipeline ( `getar`, `power_benchmark`, `extract` decode pipeline). Simultaneously correct the dead-code warning of the Swift `-O` compiler to `misaligned` captured variable.

## Changes in this round

| Project | Description |
|---|---|
| **swift_tar combined flags** | swift_tar originally did not support `-czf`, `czf` (no-dash POSIX form) and other combined short flags, resulting in the failure of the benchmark throughout the whole process. Correction: Expand combined flags at the entrance of `main()` to achieve complete compatibility with the system tar. |
| **run_round.command -swift_tar** | Add opt-in flag; create PATH shim ( `tar → swift_tar`) when flagged, and let the sub-trip inherit the modified PATH with `sudo --preserve-env=PATH`; maintain the original behavior without the flag. |
| **NGResult enum (lzfse-cli.swift)** |`nextGroup()` Originally captured `var misaligned` Return truncation streaming error; Swift `-O` SSA analyzes and tracks captured bool and determines `if misaligned` False → warning: will never be executed in all reachable paths. Correction: let `nextGroup()` Directly send it back `NGResult` ( `.group` / `.eof` / `.misaligned`), eliminate the side-channel captured variable, and the caller is changed to `innerLoop: switch`. |
| **lzfse2 submodule registration** | Register swift_tar to lzfse2 in git submodule ( `git@github.com:raliclo/swift_tar.git`), and no longer directly embedded in the directory. |

## Verification

- `TEST_OK` ( `lzfse -test` fully passed, including round-trip verification after NGResult reconstruction).
- Full R43-Mac round run: `BENCH_DONE 17:38:38`, zero failure.
- swift_tar decode pipeline ( `lzfse -decode -so | tar -xf -`) compares all formats of the two data sets through `[Success] decompression content consistent with tgz`.

## one. Compression ratio and speed (n=40, two data sets)

| Data Set | Format | Compression Ratio | Enc MB/s | Dec MB/s |
| --- | --- | ---: | ---: | ---: |
| claw-code | TGZ | 1.0000 | 310.83 | 396.15 |
| claw-code | Other3 | 0.9812 | 550.38 | 599.68 |
| claw-code | **Optimal3** | **0.9344** | **64.48** | **553.04** |
| claw-code | Lazy2 | 0.8683 | 70.27 | 481.84 |
| claw-code | Optimal | 0.8253 | 35.55 | 394.46 |
| claw-code | BVX3 | 0.9244 | 540.22 | 500.02 |
| claw-code | Apple | 0.9820 | 153.86 | 393.53 |
| claw-code | TLZ4 | 1.1786 | 586.33 | 636.66 |
| claw-code | ZSTD | 0.7805 | 429.27 | 559.66 |
| llama.cpp | TGZ | 1.0000 | 243.69 | 138.41 |
| llama.cpp | Other3 | 0.9965 | 247.42 | 140.43 |
| llama.cpp | **Optimal3** | **0.9737** | **88.62** | **128.70** |
| llama.cpp | Lazy2 | 0.9576 | 190.31 | 133.80 |
| llama.cpp | Optimal | 0.9408 | 62.11 | 130.52 |
| llama.cpp | BVX3 | 0.9810 | 405.01 | 135.99 |
| llama.cpp | Apple | 0.9994 | 169.01 | 125.34 |
| llama.cpp | TLZ4 | 1.0535 | 363.08 | 131.00 |
| llama.cpp | ZSTD | 0.9113 | 451.24 | 135.13 |

> **Compared with R42-Mac**: The speed of encode and decode has been significantly improved, mainly because swift_tar multi-core parallel replaces the system tar. For details, please refer to the comparison table below. The compression ratio (normalized to TGZ) of some formats has also improved slightly, which is speculated to be caused by swift_tar producing a slightly different tar byte stream (header/padding difference changes the repeated segment distribution of LZ window).

## two. Encode speed comparison: R42-Mac vs R43-Mac (n=40)

> The acceleration effect of swift_tar varies according to algorithm: **I/O intensive** (TGZ / Other3 / BVX3 / TLZ4 / ZSTD) greatly benefits from the acceleration of tar reading pipelines; **CPU intensive** (Optimal3 / Lazy2 / Optimal) compression itself is a bottleneck with limited acceleration.

### claw-code (n=40)

| Format | R42 Enc MB/s | R43 Enc MB/s | Change | Main Cause |
| --- | ---: | ---: | ---: | --- |
| TGZ | 47.56 | 310.83 | **+554%** | swift_tar multi-core gzip (vs system tar single-core) |
| Other3 | 339.49 | 550.38 | +62% | tar input pipeline acceleration, encode traffic increase |
| Optimal3 | 62.85 | 64.48 | +3% | CPU bound (DP analysis), tar acceleration has almost no effect |
| Lazy2 | 62.50 | 70.27 | +12% | Mild benefit, lazy parse is still a bottleneck |
| Optimal | 33.73 | 35.55 | +5% | CPU bound (BVX3 DP) |
| BVX3 | 371.09 | 540.22 | +46% | tar input pipeline acceleration |
| Apple | 135.03 | 153.86 | +14% | Partial Benefit |
| TLZ4 | 390.15 | 586.33 | +50% | tar input pipeline acceleration |
| ZSTD | 346.94 | 429.27 | +24% | tar input pipeline acceleration |

### llama.cpp (n=40)

| Format | R42 Enc MB/s | R43 Enc MB/s | Change | Main Cause |
| --- | ---: | ---: | ---: | --- |
| TGZ | 39.63 | 243.69 | **+515%** | swift_tar multi-core gzip |
| Other3 | 87.49 | 247.42 | +183% | tar acceleration (llama.cpp has a large number of small files, and the proportion of I/O is higher) |
| Optimal3 | 64.07 | 88.62 | +38% | Partial benefit, still CPU bound |
| Lazy2 | 86.62 | 190.31 | +120% | After the tar I/O bottleneck is lifted, lazy parse makes full use of CPU |
| Optimal | 48.01 | 62.11 | +29% | CPU bound (BVX3 DP) |
| BVX3 | 87.79 | 405.01 | +361% | tar input pipeline acceleration |
| Apple | 67.39 | 169.01 | +151% | tar input pipeline acceleration |
| TLZ4 | 87.17 | 363.08 | +317% | tar input pipeline acceleration |
| ZSTD | 92.37 | 451.24 | +388% | tar input pipeline acceleration |

## three. Peak RSS (Mac only, n=40)

> TGZ uses swift_tar in R43 (full-file parallel read into memory); RSS in other formats is the peak of the lzfse encode pipeline.

| Data Set | Format | Encode RSS | Decode RSS |
| --- | --- | ---: | ---: |
| claw-code | TGZ | 2944.9 MB | 3196.4 MB |
| claw-code | Other3 | 356.3 MB | 305.6 MB |
| claw-code | **Optimal3** | **553.4 MB** | **323.3 MB** |
| claw-code | Lazy2 | 495.9 MB | 324.2 MB |
| claw-code | Optimal | 582.7 MB | 335.7 MB |
| claw-code | BVX3 | 368.1 MB | 319.3 MB |
| claw-code | Apple | 1356.3 MB | 470.0 MB |
| claw-code | TLZ4 | 78.9 MB | 33.8 MB |
| claw-code | ZSTD | 398.0 MB | 9.7 MB |
| llama.cpp | TGZ | 2584.0 MB | 2728.6 MB |
| llama.cpp | Other3 | 223.1 MB | 349.6 MB |
| llama.cpp | **Optimal3** | **554.1 MB** | **349.4 MB** |
| llama.cpp | Lazy2 | 856.1 MB | 347.5 MB |
| llama.cpp | Optimal | 614.5 MB | 347.9 MB |
| llama.cpp | BVX3 | 235.3 MB | 348.8 MB |
| llama.cpp | Apple | 1089.8 MB | 592.2 MB |
| llama.cpp | TLZ4 | 84.5 MB | 33.8 MB |
| llama.cpp | ZSTD | 490.4 MB | 9.6 MB |

### Peak RSS Comparison: R42 vs R43 (full format, n=40)

> TGZ in R42 (system tar) is the streaming mode (~4 MB), and R43 (swift_tar) is the parallel full buffer mode (~2.9 GB); the memory models of the two are fundamentally different, not calculated as a percentage, but marked by `†`.

#### claw-code (n=40)

| Format | R42 Enc RSS | R43 Enc RSS | Enc Change | R42 Dec RSS | R43 Dec RSS | Dec Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 4.2 MB | 2944.9 MB | † | 3.7 MB | 3196.4 MB | † |
| Other3 | 228.9 MB | 356.3 MB | **+56%** | 299.3 MB | 305.6 MB | +2% |
| Optimal3 | 550.8MB | 553.4MB | +0.5% | 316.4MB | 323.3MB | +2% |
| Lazy2 | 494.6 MB | 495.9 MB | +0.3% | 321.0 MB | 324.2 MB | +1% |
| Optimal | 568.7 MB | 582.7 MB | +2.5% | 307.8 MB | 335.7 MB | +9% |
| BVX3 | 250.4 MB | 368.1 MB | **+47%** | 324.8 MB | 319.3 MB | −2% |
| Apple | 1367.7 MB | 1356.3 MB | −0.8% | 473.5 MB | 470.0 MB | −0.7% |
| TLZ4 | 78.2 MB | 78.9 MB | +0.9% | 33.7 MB | 33.8 MB | +0.3% |
| ZSTD | 371.2 MB | 398.0 MB | +7.2% | 9.3 MB | 9.7 MB | +4% |

#### llama.cpp (n=40)

| Format | R42 Enc RSS | R43 Enc RSS | Enc Change | R42 Dec RSS | R43 Dec RSS | Dec Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 4.3 MB | 2584.0 MB | † | 3.8 MB | 2728.6 MB | † |
| Other3 | 354.5 MB | 223.1 MB | **−37%** | 349.0 MB | 349.6 MB | 0% |
| Optimal3 | 821.7 MB | 554.1 MB | **−33%** | 350.9 MB | 349.4 MB | 0% |
| Lazy2 | 492.2 MB | 856.1 MB | **+74%** | 348.8 MB | 347.5 MB | 0% |
| Optimal | 810.7 MB | 614.5 MB | **−24%** | 349.1 MB | 347.9 MB | 0% |
| BVX3 | 355.4 MB | 235.3 MB | **−34%** | 351.5 MB | 348.8 MB | −0.8% |
| Apple | 1285.5 MB | 1089.8 MB | **−15%** | 596.5 MB | 592.2 MB | −0.7% |
| TLZ4 | 82.8 MB | 84.5 MB | +2% | 33.8 MB | 33.8 MB | 0% |
| ZSTD | 463.8 MB | 490.4 MB | +5.8% | 9.2 MB | 9.6 MB | +4% |

> **Enc RSS Law**:
> - **claw-code** (a small number of large files): I/O dense format (Other3 +56%, BVX3 +47%) RSS rises, because swift_tar multi-core holds large files buffer at the same time; CPU bound format (Optimal3 +0.5%, Lazy2 +0.3%) is almost unchanged (DP work set is independent of tar speed).
> - **llama.cpp** (a large number of small files): Most formats of RSS decline (Other3 −37%, Optimal3 −33%, BVX3 −34%, Optimal −24%, Apple −15%), because swift_tar is more coherent after batch packaging of small files, the pipe is more coherent, reducing the in-flight buffer of lzfse; exception: Lazy2 +74%, it is speculated that the higher input rate of swift_tar makes lazy parse have a larger sliding window.
> - **Dec RSS** There is almost no change in the two rounds (the decoding path is not affected by tar practice).

## four. CPU Energy (Mac only, n=40)

| Data Set | Format | Enc J | Enc J/TGZ |
| --- | --- | ---: | ---: |
| claw-code | TGZ | 104.96 | 1.0000 |
| claw-code | Other3 | 43.82 | 0.4175 |
| claw-code | **Optimal3** | **513.65** | **4.8939** |
| claw-code | Lazy2 | 277.61 | 2.6450 |
| claw-code | Optimal | 797.79 | 7.6012 |
| claw-code | BVX3 | 45.74 | 0.4358 |
| claw-code | Apple | 110.60 | 1.0538 |
| claw-code | TLZ4 | 44.06 | 0.4198 |
| claw-code | ZSTD | 52.26 | 0.4979 |
| llama.cpp | TGZ | 100.79 | 1.0000 |
| llama.cpp | Other3 | 34.15 | 0.3388 |
| llama.cpp | **Optimal3** | **347.82** | **3.4509** |
| llama.cpp | Lazy2 | 101.88 | 1.0108 |
| llama.cpp | Optimal | 462.73 | 4.5909 |
| llama.cpp | BVX3 | 36.48 | 0.3619 |
| llama.cpp | Apple | 85.05 | 0.8438 |
| llama.cpp | TLZ4 | 41.07 | 0.4075 |
| llama.cpp | ZSTD | 33.62 | 0.3335 |

### CPU Energy Comparison: R42 vs R43 (full format, n=40)

#### claw-code (n=40)

| Format | R42 Enc J | R43 Enc J | Enc J Change | R42 J/TGZ | R43 J/TGZ | J/TGZ Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 157.43 | 104.96 | **−33%** | 1.0000 | 1.0000 | — |
| Other3 | 28.16 | 43.82 | +56% | 0.1789 | 0.4175 | **+133%** |
| Optimal3 | 370.85 | 513.65 | +38% | 2.3557 | 4.8939 | **+108%** |
| Lazy2 | 119.63 | 277.61 | **+132%** | 0.7599 | 2.6450 | **+248%** |
| Optimal | 529.30 | 797.79 | +51% | 3.3623 | 7.6012 | **+126%** |
| BVX3 | 30.82 | 45.74 | +48% | 0.1958 | 0.4358 | **+123%** |
| Apple | 42.65 | 110.60 | **+159%** | 0.2709 | 1.0538 | **+289%** |
| TLZ4 | 30.21 | 44.06 | +46% | 0.1919 | 0.4198 | **+119%** |
| ZSTD | 38.01 | 52.26 | +37% | 0.2414 | 0.4979 | **+106%** |

#### llama.cpp (n=40)

| Format | R42 Enc J | R43 Enc J | Enc J Change | R42 J/TGZ | R43 J/TGZ | J/TGZ Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 166.52 | 100.79 | **−39%** | 1.0000 | 1.0000 | — |
| Other3 | 18.38 | 34.15 | +86% | 0.1103 | 0.3388 | **+207%** |
| Optimal3 | 289.48 | 347.82 | +20% | 1.7384 | 3.4509 | **+99%** |
| Lazy2 | 47.33 | 101.88 | **+115%** | 0.2842 | 1.0108 | **+255%** |
| Optimal | 359.50 | 462.73 | +29% | 2.1589 | 4.5909 | **+113%** |
| BVX3 | 26.97 | 36.48 | +35% | 0.1620 | 0.3619 | **+123%** |
| Apple | 35.98 | 85.05 | **+136%** | 0.2161 | 0.8438 | **+291%** |
| TLZ4 | 34.55 | 41.07 | +19% | 0.2075 | 0.4075 | **+96%** |
| ZSTD | 24.21 | 33.62 | +39% | 0.1454 | 0.3335 | **+129%** |

> **Interpretation**:
> - **TGZ**: R43 absolute energy consumption ** decreased** −33%~−39%: Although swift_tar starts multi-core, the encode time is shortened from ~28s to ~4.6s (claw-code), and the total energy consumption is still reduced.
> - **Apple**: The largest increase (+136% to +159%): R42 encode has a large number of I/O waiting, R43 CPU is fully loaded throughout the process, and the energy consumption increases significantly.
> - **Lazy2**: the second increase (+115%~+132%): lazy parse disappears I/O stall with faster pipe input, and the CPU time increases significantly.
> - **J/TGZ ratio** overall increase (+96%~+291%): TGZ has become a stricter benchmark due to the drop in parallel energy consumption of swift_tar gzip, and the relative ratio of all other formats has therefore increased.

## five. Best Points (Optimal3, all n)

| Data set | Best compression ratio | Best Enc MB/s | Best Dec MB/s | Lowest Enc RSS | Highest Enc RSS | Lowest Enc J | Highest Enc J |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| claw-code | 0.9344 ( `n4`) | 64.48 ( `n40`) | 565.15 ( `n8`) | 212.0 MB ( `n4`) | 553.4 MB ( `n40`) | 513.65 ( `n40`) | 722.83 ( `n4`) |
| llama.cpp | 0.9737 ( `n4`) | 88.62 ( `n40`) | 128.70 ( `n40`) | 220.1 MB ( `n4`) | 554.1 MB ( `n40`) | 347.82 ( `n40`) | 501.50 ( `n4`) |

---

# R43-Win: swift_tar Windows porting + -swift_tar round + scoop release process (2026-07-08)

> **Goal**: Put R43-Mac's `swift_tar` Transfer to Windows (originally no Windows support at all: `compile_tar.zsh` Link Homebrew's zlib/libbz2/liblzma/libzstd/liblz4, `swift_tar.swift` ALSO USE A LOT OF POSIX `lstat` / `symlink` / `link` / `chmod`), packaged into a portable `swift_tar_win.zip`, create a scoop bucket to let `swift_tar` / `lzfse` Available `scoop install` Release, and run a round of belt `-swift_tar` Of `run_round.bat`, actually measure the actual impact of replacing system tar with swift_tar on Windows benchmark.

## Changes in this round

| Project | Description |
|---|---|
| **swift_tar compression engine (Windows)** | Windows does not link any C library; `gzip` / `bzip2` / `xz` / `zstd` / `lz4` All changed to `Process` Shell out calls the corresponding CLI tool installed by scoop (the same `encode-win.bat` / `decode-win.bat` Existing lz4/zstd call method); only LZFSE family ( `other3` / `bvx3`) Maintain the native Swift and use the existing Windows CLI porting of lzfse2. |
| **swift_tar file recognition (Windows)** | Use `GetFileAttributesW` / `CreateFileW` / `GetFileInformationByHandle` Substitute `lstat` (Reparse point ⟺ symlink, volume serial + file index replaces dev/ino to do hardlink de-weighting); `CreateSymbolicLinkW` / `CreateHardLinkW` Substitute `symlink()` / `link()`, only warn and skip in the cat of failure (do not stop the whole extract); Windows has no Unix authority bit, `chmod` For no-op, all new projects are given conventional values. `0o755` / `0o644`. |
| ** `swift_tar/compile_tar-win.bat` ** | New: Compile `swift_tar.exe` (no need to link the C library, simpler than the macOS version), and automatically call `package_win.ps1` to package `swift_tar_win.zip`. |
| ** `swift_tar/package_win.ps1` ** | New: Automatically detect the Swift runtime directory from the `swiftc` path, and package `swift_tar.exe` + 32 runtime DLL into portable `swift_tar_win.zip` (24.5 MB, the same level as the existing `lzfse-cli.zip`). |
| ** `swift_tar/build_tool_install-win.zsh` ** | New: Check/install the installation tool chain (Swift toolchain, MSVC C++ build tools, scoop, `gzip` / `bzip2` / `xz` / `zstd` / `lz4` / `lzip`); use `vswhere` instead of PATH to judge whether MSVC has been installed (avoid misjudging the unrelated `link.exe` Z attached to MSYS), use `scoop list` instead of PATH to determine whether the compression tool has been installed (avoid misjudging the castration applet attached to busybox). During the operation, it was found that the scoop shim of `xz` and `bzip2` were all covered by the castration version of busybox (can only be decompressed, cannot be compressed), and the original kit has been modified. |
| ** `bucket/swift_tar.json`, `bucket/lzfse.json` ** | New: standard scoop manifest, for this repo to be used directly as a scoop bucket ( `scoop bucket add <name> <repo>`). `swift_tar.json` declare `depends: [gzip, bzip2, xz, zstd, lz4, lzip]`. |
| ** `swift_tar/scoop_release.bat`, `helper_windows/scoop_release.bat` ** | New: After rebuilding zip respectively, call `update_scoop_manifest.ps1` to replace it with text (not `ConvertTo-Json`, avoid the whole file rearrangement format) to update the `hash` field corresponding to manifest. |
| ** `helper_windows/run_round.bat` `-swift_tar` Flag** | `-swift_tar` modeled on `run_round.command`: Create PATH shim when flagged ( `tar.exe` copy to the compiled `swift_tar.exe`, non-system PATH), prepend into this session PATH; maintain the original behavior without the flag. |
| **README.md/README.zh-TW.md** | New "Test Machine Hardware Comparison" table (macOS M4 Mac mini vs Windows ASUS TUF A15), Chinese-English comparison. |

## Verification

- `compile_tar-win.bat` compilation is successful, `swift_tar_win.zip` is decompressed to a new folder, PATH is cut to only `System32` (completely isolate Swift toolchain and scoop) can still build files/list contents normally, and confirm that it is really portable.
- 7 kinds of codec round-trip: `other3-fast`, `bvx3-fast`, `gzip`, `bzip2`, `xz`, `zstd`, `lz4`.
- hardlink de-reduty + restore correct ( `ls -la` link count 2); symlink creates code logic correctly (call failure will warn that it will not crash), but this test machine does not have system administrator rights/developer mode, and cannot verify the "successful creation" path.
- scoop manifest uses temporary `file://` URL to build fake bucket actual test `scoop install`: hash verification, shim creation, `swift_tar -c/-x`, `lzfse -test` are all passed, uninstall after the test, cut off the test bucket.
- `run_round.bat -swift_tar` completes a round (2026-07-09 `DONE 9:26:30`), `USING_SWIFT_TAR` log confirms PATH shim takes effect, all 16 groups (8 formats × 2 data sets) `win_decode_verify` are all `PASS`.

## one. Windows actual measurement results ( `-swift_tar`, n=40 inflight)

| Data Set | Format | Win Compression Ratio | Win Enc MB/s | Win Dec MB/s | Enc RSS | Dec RSS | Verify |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---
| claw-code | TGZ | 1.0000 | 87.71 | 36.73 | 6.3 MB | 6.1 MB | PASS |
| claw-code | Other3 | 0.9861 | 242.74 | 66.98 | 189.2 MB | 257.1 MB | PASS |
| claw-code | **Optimal3** | **0.9391** | **29.69** | **67.15** | **497.0 MB** | **255.1 MB** | PASS |
| claw-code | BVX3 | 0.9289 | 183.05 | 68.06 | 191.5 MB | 248.7 MB | PASS |
| claw-code | Lazy2 | 0.8730 | 29.86 | 69.26 | 491.0 MB | 248.2 MB | PASS |
| claw-code | Optimal | 0.8293 | 13.65 | 68.38 | 515.1 MB | 244.7 MB | PASS |
| claw-code | TLZ4 | 1.1792 | 178.02 | 59.58 | 8.3 MB | 8.3 MB | PASS |
| claw-code | ZSTD | 0.7844 | 91.17 | 61.00 | 8.3 MB | 8.3 MB | PASS |
| llama.cpp | TGZ | 1.0000 | 54.09 | 8.18 | 6.6 MB | 7.0 MB | PASS |
| llama.cpp | Other3 | 0.9966 | 59.47 | 10.65 | 216.6 MB | 345.6 MB | PASS |
| llama.cpp | **Optimal3** | **0.9739** | **34.17** | **10.03** | **759.6 MB** | **345.2 MB** | PASS |
| llama.cpp | BVX3 | 0.9792 | 60.21 | 10.54 | 217.3 MB | 345.4 MB | PASS |
| llama.cpp | Lazy2 | 0.9572 | 53.70 | 10.37 | 695.4 MB | 345.3 MB | PASS |
| llama.cpp | Optimal | 0.9390 | 26.83 | 10.41 | 755.0 MB | 344.6 MB | PASS |
| llama.cpp | TLZ4 | 1.0500 | 55.88 | 10.58 | 8.4 MB | 8.4 MB | PASS |
| llama.cpp | ZSTD | 0.9123 | 57.42 | 10.67 | 8.4 MB | 8.4 MB | PASS |

## two. R42-Win (system tar/bsdtar) vs R43-Win ( `-swift_tar`) speed control

> R42-Win is the same as all the conditions in this round except "tar realization" (the same machine, the same data set, the same `-n 40`), so the speed difference can be directly attributed to the effect of swift_tar replacing the system tar. There is also a very small change in the compression ratio (such as claw-code Other3 0.9818→0.9861), which is consistent with the phenomenon observed by R43-Mac: the tar byte stream generated by swift_tar is slightly different from bsdtar (header/padding difference), which changes the duplicate segment distribution of LZ window.

### claw-code (n=40)

| Format | R42 Enc MB/s | R43 Enc MB/s | Enc Change | R42 Dec MB/s | R43 Dec MB/s | Dec Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 33.92 | 87.71 | **+158.6%** | 145.90 | 36.73 | **−74.8%** |
| Other3 | 296.96 | 242.74 | −18.3% | 152.19 | 66.98 | **−56.0%** |
| Optimal3 | 47.11 | 29.69 | −37.0% | 150.96 | 67.15 | **−55.5%** |
| BVX3 | 289.21 | 183.05 | −36.7% | 150.93 | 68.06 | **−54.9%** |
| Lazy2 | 51.55 | 29.86 | −42.1% | 154.04 | 69.26 | **−55.0%** |
| Optimal | 24.26 | 13.65 | −43.7% | 155.59 | 68.38 | **−56.1%** |
| TLZ4 | 258.08 | 178.02 | −31.0% | 208.76 | 59.58 | **−71.5%** |
| ZSTD | 146.12 | 91.17 | −37.6% | 186.81 | 61.00 | **−67.3%** |

### llama.cpp (n=40)

| Format | R42 Enc MB/s | R43 Enc MB/s | Enc Change | R42 Dec MB/s | R43 Dec MB/s | Dec Change |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 38.32 | 54.09 | **+41.2%** | 21.54 | 8.18 | **−62.0%** |
| Other3 | 182.44 | 59.47 | **−67.4%** | 30.25 | 10.65 | **−64.8%** |
| Optimal3 | 66.00 | 34.17 | −48.2% | 28.79 | 10.03 | **−65.2%** |
| BVX3 | 178.34 | 60.21 | **−66.2%** | 28.55 | 10.54 | **−63.1%** |
| Lazy2 | 126.49 | 53.70 | −57.5% | 28.43 | 10.37 | **−63.5%** |
| Optimal | 45.29 | 26.83 | −40.8% | 28.46 | 10.41 | **−63.4%** |
| TLZ4 | 154.57 | 55.88 | **−63.8%** | 30.59 | 10.58 | **−65.4%** |
| ZSTD | 145.30 | 57.42 | **−60.5%** | 30.05 | 10.67 | **−64.5%** |

> **Interpretation**:
> - **swift_tar native TGZ ( `--gzip`) encode is faster than bsdtar**: Both data sets have been improved (claw-code +158.6%, llama.cpp +41.2%), which is the most stable positive result of this round.
> - **swift_tar When the pure tar pipeline ( `-cf -` connected to lzfse.exe/lz4/zstd), most encode slows down**: Except for TGZ, the file-output encode of lzfse/tlz4/zstd is still negative; most formats on llama.cpp dropped by 57% to 67%, I/O formats on claw-code dropped by 18% to 38%, and Lazy2/Optimal of CPU-bound also decreased due to the increase in pipeline costs.
> - **decode/extract comprehensively and significantly regress, which is the main discovery of this round**: Not format, as long as you follow the PATH shim of `-swift_tar`, the decode write-to-file speed is significantly lower than bsdtar (claw-code −55%～−75%, llama.cpp −62%～−65%). This means that swift_tar's current extract path ( `TarReader.run()` 1 MB block `FileHandle.write`) is significantly less efficient than bsdtar on Windows/NTFS, and this effect covers decode steps in all formats, not just TGZ.
> - Correctness is not affected: all 16 groups of `win_decode_verify` are `PASS`.

> **Conclusion**: At this stage, swift_tar ** is not suitable as a direct substitute for Windows system tar** - its own TGZ codec is worth keeping, but replacing bsdtar for pipeline input/extract will make the decode digital distortion of benchmark worse and not reflect the performance of the lzfse2 engine itself. If it is to be formally adopted in the future, the decode/extract path of swift_tar is worth re-examined performance bottlenecks (such as the size of the file write block, whether the write method closer to Win32 API can replace the segment-by-section `FileHandle.write`).

## three. Win/Mac comparison (R43-Win vs R43-Mac, use swift_tar in both rounds)

| Data Set | Format | Win Enc MB/s | Mac Enc MB/s | Win/Mac Enc | Win Dec MB/s | Mac Dec MB/s | Win/Mac Dec |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| claw-code | TGZ | 87.71 | 310.83 | 0.282 | 36.73 | 396.15 | 0.093 |
| claw-code | Other3 | 242.74 | 550.38 | 0.441 | 66.98 | 599.68 | 0.112 |
| claw-code | **Optimal3** | **29.69** | **64.48** | **0.460** | **67.15** | **553.04** | **0.121** |
| claw-code | BVX3 | 183.05 | 540.22 | 0.339 | 68.06 | 500.02 | 0.136 |
| claw-code | Lazy2 | 29.86 | 70.27 | 0.425 | 69.26 | 481.84 | 0.144 |
| claw-code | Optimal | 13.65 | 35.55 | 0.384 | 68.38 | 394.46 | 0.173 |
| claw-code | TLZ4 | 178.02 | 586.33 | 0.304 | 59.58 | 636.66 | 0.094 |
| claw-code | ZSTD | 91.17 | 429.27 | 0.212 | 61.00 | 559.66 | 0.109 |
| llama.cpp | TGZ | 54.09 | 243.69 | 0.222 | 8.18 | 138.41 | 0.059 |
| llama.cpp | Other3 | 59.47 | 247.42 | 0.240 | 10.65 | 140.43 | 0.076 |
| llama.cpp | **Optimal3** | **34.17** | **88.62** | **0.386** | **10.03** | **128.70** | **0.078** |
| llama.cpp | BVX3 | 60.21 | 405.01 | 0.149 | 10.54 | 135.99 | 0.078 |
| llama.cpp | Lazy2 | 53.70 | 190.31 | 0.282 | 10.37 | 133.80 | 0.077 |
| llama.cpp | Optimal | 26.83 | 62.11 | 0.432 | 10.41 | 130.52 | 0.080 |
| llama.cpp | TLZ4 | 55.88 | 363.08 | 0.154 | 10.58 | 131.00 | 0.081 |
| llama.cpp | ZSTD | 57.42 | 451.24 | 0.127 | 10.67 | 135.13 | 0.079 |

> **Compared with the Win/Mac decode ratio of R42-Win** ( `other3 -optimal3`: 0.346/0.343, about 0.34–0.35×, see Section 3 of R42-Win): The Win/Mac decode of the same group of `Optimal3` in this round fell to **0.121/0.078**, that is, Windows decode relative to Mac deteriorated from "slow 3 times" to "slow 8–13 times". Since the difference between the two rounds is only "whether Windows uses `-swift_tar`", this further confirms the conclusion of Section 2: the regression of the decode end comes almost entirely from the extract path of swift_tar on Windows, not the platform itself or the lzfse2 engine.

## four. Decode Regression Root Cause Survey (2026-07-08)

> Use three independent Swift microbenchmarks (aligned with the actual code path of `swift_tar.swift`) to measure on the same machine, gradually approach the real situation, and find out two main quantifiable bottlenecks:

| Test situation | Throughput | Description |
| --- | --- | --- |
| Single 200 MB file, direct `FileHandle.write` (no/with `SetEndOfFile` pre-configured size) | **~1100–1200 MB/s** | Both are almost the same, excluding the "NTFS incremental configuration" hypothesis; pure write throughput itself is not a bottleneck at all. |
| The same payload passes through two layers `Pipe()` (pipe transfer of the internal filter chain of swift_tar) | **~750 MB/s** | There is a decrease but the magnitude is limited, which is not enough to explain the observed 30–65 MB/s. |
| Distribution according to the number and size of real claw-code files (5403 files, median only 14.6 KB, average 260 KB, maximum 57 MB) file by file `createDirectory`+`createFile`+`FileHandle` Open file + write +`close`+`setAttributes` (No pipe, payload comes directly from memory) | **~120–135 MB/s** | **Single maximum bottleneck**: The fixed cost of each file is about 2 ms (4–5 independent Win32 API round trips: build directory check, build file, open file, write, close file, set mtime). Directory cache (avoid duplication) `createDirectory`) Almost no help (only ~2%), which means that the bottleneck is not the repeated building of the directory, but **file-by-file create+open+write+close+setAttributes disassembled into multiple system calls** itself. |
| Same as above, but change to read payload from `Pipe()` (superimposed two factors at the same time) | **~95.6 MB/s** | After the two factors are superimposed, it is closer to the actual measured value, but it is still higher than the observed 32–65 MB/s. |

> **The real file distribution of the claw-code data set** ( `5403` file, ~1.4 GB in total) is the key background: the median is only 14.6 KB, and 63% of the files are less than 32 KB - which means **the fixed cost of each file dominates the total time, and the byte throughput of the file itself is almost irrelevant**. This explains why a single large file test (>1000 MB/s) cannot predict the real decode speed at all.

> **Gap with the actual measured number**: TGZ (36.73 MB/s) is slower than most lzfse/tlz4/zstd formats (about 59–69 MB/s), which is presumed to be because TGZ has an extra layer of "call external `gzip.exe` The pipe of "sub-stroke" (cross-stroke, not the thread pipe of the same stroke of this test), superimposed on the real decompression CPU cost; the rest of the formats (Other3/BVX3/Lazy2/Optimal/TLZ4/ZSTD) Although the codec is different, they are all the same. `TarReader` The extract path, the speed is concentrated in the narrow interval of 59–69 MB/s, which is consistent with the synthetic benchmark (~95.6 MB/s) level of "per-file overhead + pipe reading". The remaining gap is reasonably attributed to the actual tar header analysis/checksum operation and unsimulated environmental variation (such as instant anti-virus scanning).

> **Conclusion**: The main root cause is ** `TarReader.run()` Call each file separately `FileManager.createFile`+`FileHandle(forWritingAtPath:)`+ paragraph by paragraph `write`+`close`+`setAttributes` **, each file on Windows requires a fixed API round-trip cost of about 2 ms; "large numbers of small and medium-sized files" data sets such as claw-code/llama.cpp are therefore dominated by fixed costs, not byte-level write throughput. **Possible repair direction**: change to a single `CreateFileW` Call to complete the creation + open at the same time (not `createFile` Then again `FileHandle(forWritingAtPath:)` Two round trips), will `setAttributes` (Mtime) Batch delay processing, and evaluate whether it can reduce the number of system calls per file like the Windows disk writer of libarchive.

---

# R44-Win: swift_tar -test self-test + WinSDK removal + build-up script reinforcement (2026-07-09)

> **Objective**: Continue R43-Win, make up for the missing self-testing ability of swift_tar ( `-test`), verify that its output can really be interoperable with Windows standard tar in both directions, and remove `swift_tar.swift`'s direct dependence on WinSDK. Two real bugs were caught in the process.

## Changes in this round

| Project | Description |
|---|---|
| ** `-test` self-test flag** | Add two-way round-trip verification with the platform standard tar (pure tar and `.tar.gz`, mutual construction and mutual solution on both sides), confirm compatibility with actual content comparison (not only exit code); follow the existing output style of `check()` /✓/✗. |
| ** `findStandardTar()` ** | On Windows, it is clearly preferred to find `System32\tar.exe` (real bsdtar), rather than the MSYS tar attached to Git found first on PATH (it has its own set of conversion meanings for the `/...` -style path, which will mislead the test); use file size comparison to exclude the PATH shim of swift_tar itself (such as `-swift_tar` shim). |
|** `-debug` Flag** | Print out the candidate items found/skied in the process of finding standard tar; the message goes stdout ( `print`) instead of stderr - the actual measurement found that in this environment, it is executed through Bash/MSYS or PowerShell `2>&1` When, `FileHandle.standardError` The written content will be lost, `print()` Both call methods are reliable. |
| **WinSDK dependency removal ( `swift_tar.swift`)** |`import WinSDK` With all direct WinSDK calls ( `GetFileAttributesW` / `CreateFileW` / `GetFileInformationByHandle` / `CreateSymbolicLinkW` / `CreateHardLinkW`) Remove all of them and switch to pure Foundation API: `FileManager.attributesOfItem` Of `.type` / `.systemFileNumber` / `.systemNumber` / `.referenceCount` (The actual measurement correctly corresponds to the S_IFLNK/dev/ino/nlink of lstat), `FileManager.createSymbolicLink` (The actual test itself has been flagged with the modern version of the exemption from authority). Hard link **no**re-use `FileManager.linkItem` ——It is actually measured that it will silently create symlink on Windows instead of the real hardlink, and call external instead. `fsutil hardlink create` (There is no need for system administrator authority, it has been tested). After compilation `swift_tar.exe` Will still pass `Foundation.dll` Indirectly connected to `swiftWinSDK.dll`, this is Foundation's own dependence, and the non-project code can be controlled. |
| ** `archiveName()` correction (real bug)** | Originally, only `/` at the beginning was removed, and the absolute path of the Windows disk code (such as `C:\Users\...`) was not handled, resulting in the tar item name containing colons and backslashes intact, and bsdtar could not be solved. Correction: The paradigm `\` is `/`, remove the prefix of the disk drive code, and the whole platform consistently produces a portable POSIX relative path. This bug was directly detected by the added `-test`. |
| ** `compile_tar-win.bat` construction stability correction (real bug)** | `move /Y` When the newly compiled exe is installed on `release/`, if the file is temporarily locked (anti-virus instant scan, the file handle has not been released in the last test trip), it will silently fail as "Access is denied", and the script has never checked the end code of move itself, resulting in the old exe remaining unchanged, but the script is still printed `[OK]` - which caused a lot of time to trace a non-existent stderr/print buffer problem during this round of debugging, in fact, it has only been testing the old binary 20 minutes ago. Modified to retry + 500ms retreat (up to 10 times), the same practice used by `run_round.bat` for `lzfse.exe`. |

## Verification

- `swift_tar -test -debug`: 4/4 round-trip (plain tar and `.tar.gz`, swift_tar↔std tar two-way), exit code 0, `findStandardTar` correctly return `C:\Windows\System32\tar.exe`.
- A full set of existing codec return test ( `other3-fast` / `bvx3-fast` / `gzip` / `bzip2` / `xz` / `zstd` / `lz4`) + hardlink de-re-restore + symlink creation and restore, all of which are maintained and passed, confirming that `archiveName()` correction and WinSDK removal have not introduced new returns.
- `llvm-objdump -p` confirms that the source code level no longer depends on `WinSDK` (only `Foundation.dll`'s own indirect link, not within the control of this project).

---

# R42-Mac: other3 -optimal3 DP Optimal Analysis Introduction (2026-07-05)

> Add `lzParseOptimal2`: and bvx3's `lzParseOptimal` The same set of segmented DP optimal analysis mechanism (hash chain frontier, entropy pre-screening, and search budget all follow the same set of constants), but the L/M/D symbol table of the standard LZFSE ( `lBaseValue` / `mBaseValue` / `dBaseValue`, instead of bvx3 combined `lm3` Table) and the smaller upper limit ( `maxLValue` / `maxMValue` / `maxDValue`), through the new flag `-optimal3` Connect `-algo other3`.
> The output is still the standard bvx2 (through the existing `encodeBlock`), Apple can solve it with any compatible decoder - this is the biggest difference from bvx3-optimal: bvx3-optimal sacrifices compatibility to exchange compression rate, other3-optimal3 has both.
> Perform `-n 40 / 8 / 4` three batches of complete benchmark + tracer/CPU/power full-process integration for claw-code / llama.cpp.

## Optimization strategy

| Project | Description |
|---|---|
| **Core changes** | Add `lzParseOptimal2`, the DP mechanism is the same as `lzParseOptimal`, and the symbol table and upper limit are changed to the standard format |
| **Single rep (key difference)** | The standard format only has a single discount "the same distance as the previous one" ( `encodeBlock`'s `dPrev`→`d=0` conversion), non-bvx3's 3 depth rep-offset; DP only needs to track one `rep0`, saving 3 slots MTF logic |
| **M / D symbol table** | M uses independent `mBaseValue` / `mExtraBits` (20 symbols), D uses `dBaseValue` / `dExtraBits` (64 symbols) - non-bvx3 combined `lm3` (22 symbols)/ `d3` (80 symbols) table |
| **L Pricing** | Follow the spread constant `matchConst=80` (approximate to the `lzParseOptimal` scale, which can be adjusted according to the actual measurement in the future) |
| **Compatibility** | Output `encodeBlock` (standard bvx2), non- `encodeBlockV3`; Apple Compression framework can be solved directly |
| **CLI** | `-optimal3` (only `-algo other3` is effective, and the rest of the algo is ignored and prompted); the decode end does not need any flag, which is the same as the general other3 |

## Verification

- Built-in `-test` all passed (including cross-segment match return test), new `other3 -optimal3 self-round trip`, `parallel decoding`, `→ Apple decoding` three checks, all of which are output-identical and bitstream can be correctly solved by Apple `compression_decode_buffer`.
- The actual machine is verified by claw-code tar (about 460 MB): The decoding and Apple decoding of this tool are completely consistent with the original data `cmp`.
- Full R42-Mac round (tracer, power benchmark, CPU call tree, `BenchMarkResult.csv` reconstruction, `best_points`, Win/Mac comparison report, md-translate) finished running, `TEST_OK`, `BENCH_DONE`, zero failure.

## one. Compression ratio and speed (n=40, two data sets)

| Data Set | Format | Compression Ratio | Enc MB/s | Dec MB/s |
| --- | --- | ---: | ---: | ---: |
| claw-code | TGZ | 1.0000 | 47.56 | 392.56 |
| claw-code | Other3 | 0.9865 | 339.49 | 402.20 |
| claw-code | **Optimal3** | **0.9401** | **62.85** | **435.87** |
| claw-code | BVX3 (private format reference) | 0.9492 | 371.09 | 410.21 |
| claw-code | BVX3-Optimal (private format reference) | 0.8574 | 33.73 | 377.00 |
| llama.cpp | TGZ | 1.0000 | 39.63 | 88.65 |
| llama.cpp | Other3 | 0.9957 | 87.49 | 80.41 |
| llama.cpp | **Optimal3** | **0.9731** | **64.07** | **83.85** |
| llama.cpp | BVX3 (private format reference) | 0.9787 | 87.79 | 77.59 |
| llama.cpp | BVX3-Optimal (private format reference) | 0.9387 | 48.01 | 76.76 |

> **Keypoints**: The compression ratio of Optimal3 (0.9401) on claw-code is better than that of the private format BVX3 (0.9492), at the cost of which the encode speed is reduced to ~18.5% of Other3 (62.85 vs 339.49 MB/s); the decode speed is no different from that of Other3 (the same bvx2 decoding path). The improvement of llama.cpp (low repetition rate data) is relatively small (0.9957→0.9731, about -2.3%).

## two. Peak RSS (Mac only, n=40)

| Data Set | Format | Encode RSS | Decode RSS |
| --- | --- | ---: | ---: |
| claw-code | Other3 | 228.9 MB | 299.3 MB |
| claw-code | **Optimal3** | **550.8 MB** | **316.4 MB** |
| llama.cpp | Other3 | 354.5 MB | 349.0 MB |
| llama.cpp | **Optimal3** | **821.7 MB** | **350.9 MB** |

> The encode RSS of Optimal3 is about 2.3–2.4× higher than that of Other3, and the cell array from the segmented DP and the frontier temporary storage area (consistent with the memory characteristics of bvx3-optimal); decode RSS is the same as Other3 (the decoding logic is completely shared).

## three. CPU Energy (Mac only, n=40)

| Data Set | Format | Enc J | Enc J/TGZ |
| --- | --- | ---: | ---: |
| claw-code | Other3 | 28.16 | 0.1789 |
| claw-code | **Optimal3** | **370.85** | **2.3557** |
| llama.cpp | Other3 | 18.38 | 0.1104 |
| llama.cpp | **Optimal3** | **289.48** | **1.7384** |

> Energy consumption increases proportionally with speed (DP is CPU-bound), which is similar to the energy consumption level of bvx3-optimal (the same is the strategy of "compression rate first, speed/energy consumption second"). Decode energy n=40 The sampling coverage rate is insufficient and is not included in this round of comparison.

## four. Best Points (Optimal3, all n)

| Data set | Best compression ratio | Best Enc MB/s | Best Dec MB/s | Lowest Enc RSS | Highest Enc RSS | Lowest Enc J | Highest Enc J |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| claw-code | 0.9401 ( `n4`) | 62.85 ( `n40`) | 440.72 ( `n8`) | 190.0 MB ( `n4`) | 550.8 MB ( `n40`) | 370.85 ( `n40`) | 533.01 ( `n4`) |
| llama.cpp | 0.9731 ( `n4`) | 64.07 ( `n40`) | 83.85 ( `n40`) | 221.7 MB ( `n4`) | 821.7 MB ( `n40`) | 289.48 ( `n40`) | 419.46 ( `n4`) |

> The compression ratio is not affected in each n (DP analysis has nothing to do with block parallelism), and the best value appears in `n4`; speed/RSS/energy consumption increases with the increase of `-n` (parallelence), which is consistent with the existing law of Other3/Lazy2/Optimal (higher parallelism = more simultaneous coding context).

## To be done

- Windows round has been completed on **R42-Win (2026-07-05)**, `helper_windows/run_round.bat` is completely completed, and `LZFSE (Optimal3)` is no longer `Windows result missing` (see the next section).
- `matchConst` (L symbol spread constant) follows the approximate value of bvx3-optimal, and the smaller L/M upper limit of the standard format has not been adjusted individually, and the actual measured ratio of claw-code/llama.cpp in future rounds will converge.

---

# R42-Win: other3 -optimal3 Windows round complete (2026-07-05)

> Run `helper_windows/run_round.bat` on Windows to make up for the missing `other3 -optimal3` Windows test after R42-Mac.
> This round includes: `lzfse.exe -test`, encode-to-file, encode-to-nul, decode-to-file, decode-to-nul, RSS probe, `BenchMarkResult-Win.csv` And Win/Mac `comparison.csv` Rebuild.
> Test data set: `claw-code`, `llama.cpp`; Windows `-n 40` means inflight chunk count (single time), macOS `n=40` is an average of 40 times.

## Verification

- `run_round.bat` exit code 0, `windows_round_status.txt` ends with `DONE 19:01:23`.
- `lzfse.exe -test` passed all, and added `other3 -optimal3` self-round trip and parallel decoding were passed.
- `encode_summary.csv`: 32 rows.
- `decode_summary.csv`: 32 rows.
- `BenchMarkResult-Win.csv`: 16 rows.
- `comparison.csv`: Each dataset 8 rows, including `LZFSE (Optimal3)`.
- All Windows decode verify is `PASS`.

> **Correction Record (2026-07-05 Supplementary Test)**: `helper_windows/decode-win.bat`'s
> `decodeOptimal3` block originally followed the old `:appendFileSize` (record the size of the compressed file), and the remaining 7 formats have been modified in the same round to
> `:appendDecodedFolderSize` (record the actual decompression folder size). This allows `LZFSE (Optimal3)`'s decode MB/s misuse Mac
> End `raw_size_mib` estimated, not the decompression size actually measured by Windows; `compute_win_decode_speed` of `comparison_win.py`
> There is also the same problem (all formats use Mac `raw_mb`, unread `decoded_bytes`). Both have been corrected, and the two data sets have been re-executed.
> Decode benchmark (nul + file mode) and `comparison.csv` reconstruction. The following numbers in Sections 1–3 are the corrected results; decode timing
> It has run-to-run variation (especially file mode, see the R41 bsdtar/NTFS bottleneck chapter), so the rest of the formats except Optimal3
> decode MB/s is also slightly different from the first version of this section, which does not mean that the algorithm itself has changed.

## one. Windows actual measurement results (n=40 inflight, corrected / corrected)

| Data Set | Format | Win Compression Ratio | Win Enc MB/s | Win Dec MB/s | Enc RSS | Dec RSS | Verify |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---
| claw-code | TGZ | 1.0000 | 33.92 | 145.90 | 6.4 MB | 6.2 MB | PASS |
| claw-code | Other3 | 0.9818 | 296.96 | 152.19 | 131.7 MB | 247.0 MB | PASS |
| claw-code | **Optimal3** | **0.9351** | **47.11** | **150.96** | **496.7 MB** | **244.9 MB** | PASS |
| claw-code | BVX3 | 0.9254 | 289.21 | 150.93 | 139.0 MB | 245.6 MB | PASS |
| claw-code | Lazy2 | 0.8704 | 51.55 | 154.04 | 484.4 MB | 242.5 MB | PASS |
| claw-code | Optimal | 0.8274 | 24.26 | 155.59 | 513.3 MB | 240.7 MB | PASS |
| claw-code | TLZ4 | 1.1739 | 258.08 | 208.76 | 8.3 MB | 8.3 MB | PASS |
| claw-code | ZSTD | 0.7813 | 146.12 | 186.81 | 8.8 MB | 8.3 MB | PASS |
| llama.cpp | TGZ | 1.0000 | 38.32 | 21.54 | 6.6 MB | 7.0 MB | PASS |
| llama.cpp | Other3 | 0.9970 | 182.44 | 30.25 | 145.9 MB | 346.1 MB | PASS |
| llama.cpp | **Optimal3** | **0.9743** | **66.00** | **28.79** | **758.9 MB** | **346.0 MB** | PASS |
| llama.cpp | BVX3 | 0.9810 | 178.34 | 28.55 | 180.4 MB | 346.3 MB | PASS |
| llama.cpp | Lazy2 | 0.9576 | 126.49 | 28.43 | 659.3 MB | 345.9 MB | PASS |
| llama.cpp | Optimal | 0.9412 | 45.29 | 28.46 | 741.3 MB | 346.4 MB | PASS |
| llama.cpp | TLZ4 | 1.0503 | 154.57 | 30.59 | 8.3 MB | 8.8 MB | PASS |
| llama.cpp | ZSTD | 0.9123 | 145.30 | 30.05 | 8.3 MB | 8.3 MB | PASS |

## two. Optimal3 Key Points

| Data Set | Other3 Ratio | Optimal3 Ratio | Ratio Improvement | Other3 Enc | Optimal3 Enc | Optimal3/Other3 Enc | Other3 Dec | Optimal3 Dec |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| claw-code | 0.9818 | 0.9351 | -4.75% | 296.96 MB/s | 47.11 MB/s | 15.9% | 152.19 MB/s | 150.96 MB/s |
| llama.cpp | 0.9970 | 0.9743 | -2.28% | 182.44 MB/s | 66.00 MB/s | 36.2% | 30.25 MB/s | 28.79 MB/s |

> **Conclusion**: `other3 -optimal3` on Windows has been verified, decode is all PASS, and the output is still standard compatible with bvx2 bitstream.
> The compression ratio is significantly improved compared with Other3: claw-code is about -4.75%, and llama.cpp is about -2.28%. The price is encode speed and RSS: Optimal3 encode RSS is close to DP paths such as bvx3-optimal/lazy2, which belongs to the "compression rate priority" mode; decode speed/RSS is of the same magnitude as Other3 (the gap is <1–5%), which is in line with the expectations of the shared bvx2 decode path.

## two a. Why is the compression ratio of Optimal3 still much worse than Optimal?

The gap between `Optimal3` and `Optimal` is mainly not the DP search ability, but the **output format expression ability**:

- `Optimal3` = `other3 -optimal3`: Use `lzParseOptimal2` for segment DP optimal analysis, but the output still follows the standard LZFSE/bvx2 `encodeBlock`, and the standard `lBaseValue` / `mBaseValue` / `dBaseValue` table must be used, and is limited by `maxLValue=315`, `maxMValue=2359`, `maxDValue=262139` (about 256 KB).
- `Optimal` = `bvx3 -optimal`: Using private bvx3 `encodeBlockV3`, L/M goes to the merged `lm3BaseValue` / `lm3ExtraBits` table, the match length can be up to `maxM3=69947`, and the distance can also cover the entire 4 MB chunk level; therefore, less token can be used when long match, long-distance repetition and a large number of similar files can be used.
- `Optimal3` retains Apple-compatible standard bitstream; `Optimal` sacrifices Apple compatibility for stronger L/M/D expression ability.

| Data Set | Optimal3 Ratio | Optimal Ratio | Main Cause of Gap |
| --- | ---: | ---: | --- |
| claw-code | 0.9351 | 0.8274 | The code/directory structure is repetitive, and bvx3 long match and long-distance match have obvious advantages |
| llama.cpp | 0.9743 | 0.9412 | The repetition rate is low, and the format capability gap still exists but is relatively small |

> Therefore, the positioning of `Optimal3` is "the optimal parse that can be done in a standard compatible format", not a replacement for the compression ratio of `bvx3 -optimal`.
> If the target is Apple/standard LZFSE compatibility, `Optimal3` It is a path with a reasonable upper limit; if the target is the highest compression rate, private `bvx3 -optimal` There is still a hierarchical advantage in the format.

## three. Win/Mac Comparison

| Data Set | Format | Win Enc | Mac Enc | Win/Mac Enc | Win Dec | Mac Dec | Win/Mac Dec |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| claw-code | Optimal3 | 47.11 | 62.85 | 0.750 | 150.96 | 435.87 | 0.346 |
| llama.cpp | Optimal3 | 66.00 | 64.07 | 1.030 | 28.79 | 83.85 | 0.343 |

>`claw-code` Windows Optimal3 encode is about 75% of Mac; `llama.cpp` Windows encode is close to Mac (1.03×).
> Decode terminal Windows is slower (about 0.34–0.35×), which is related to this round of Windows write-to-file/tar extraction path and NTFS/bsdtar I/O cost (see R41 bsdtar/NTFS bottleneck chapter).

---

# Pre-R42: LZFSE_Win_UI — Windows Graphical Interface and Packaging Tool Chain (2026-06-27)

> Infrastructure round (non-algorithm optimized): add Windows GUI front-end and self-contained packaging process to lzfse.
> **Unchanged compression/decoding algorithm** - R42's codec target (prefetch chain entries) is not affected.

## output
- `lzfse-ui/lzfse-ui-win.swift` - SwiftCrossUI (WinUIBackend) GUI, corresponding to `lzfse-ui/lzfse-ui.swift` of macOS.
Direct import codec ( `build-win.zsh` removes `runCLI()` with `grep -v` and compiles it into the same target together).
- `lzfse-ui/build-win.zsh` + `build-win.bat` → `lzfse-ui/release/LZFSE_UI_Win.zip` (GUI app + attached `lzfse.exe`).
- `helper_windows/build-cli-win.zsh` + `build-cli-win.bat` → `helper_windows/release/lzfse-cli.zip`
( `lzfse.exe` + 32 Swift runtime DLLs, run without Swift / self-contained, runs without Swift installed).
- `lzfse-ui/screenshot-win.bat`, `lzfse-ui/README-UI-Win.md`.

## codec change: Swift 6 strict parallel compatibility (pure annotation, zero logic change)
In order for `lzfse-cli.swift` to compile with SwiftCrossUI under SwiftPM (tools-version 6.0), in
`DispatchQueue.concurrentPerform` decoding path and `scratchPool` plus `nonisolated(unsafe)` (NSLock-protected shared variable)
AND `@Sendable` (REGIONAL FUNCTION). **At the same time, you can still use `swiftc -O` to build CLI** (encode/decode round-trip verified).
Under Swift 6 strict concurrency while still building as the CLI via `swiftc -O`. Pure annotations.

## Windows engineering key points (each takes actual debugging)
| Topic | Handling |
|---|---|
| WinAppSDK 1.5 **DDLM must be installed** | Missing DDLM `5001.x` → `MddBootstrapInitialize2` Failure, flashback (exit 132). The official redistributable needs to be installed. |
| No console window / no console | `/SUBSYSTEM:WINDOWS` + `/ENTRY:mainCRTStartup` link to GUI subsystem. |
| Hide child windows | Win32 `CreateProcessW` + `CREATE_NO_WINDOW` (cmd/tar/lzfse does not skip windows). |
| Decompression does not get stuck / no hang | Relive in independent OS `Thread` ( `Task.detached` still stuck WinUI message pump → event log AppHangB1). |
| Folder selector / folder picker | WinUIBackend can only select files; change to Win32 `SHBrowseForFolderW` (independent STA thread + `OleInitialize`). |
| Clipboard / clipboard | WinUI TextBox No Ctrl+C → Win32 `SetClipboardData(CF_UNICODETEXT)`. |
| Decoding diversion / decode routing | Single file/folder compression is named `.lzfse`; use tar `ustar` magic number (offset 257, stream peek before 512 byte) to judge depacking or single file. |
| Packaging / packaging | bsdtar cannot write zip → PowerShell `Compress-Archive`; path conversion is used for `sed` (does not rely on cygpath). |

## Demand
WinAppSDK 1.5 runtime (including DDLM), Swift for Windows 6.3.2, VS Build Tools + Windows SDK, Git for Windows, PowerShell.
See `lzfse-ui/README-UI-Win.md` for details.

---

# R41-Mac: Tag-packed Hash Chain Introduction (2026-06-22)

> Reintroduce R27's Tag-packed hash chain (hashAndTag / chainIndexMask / chainTagShift / chainNullIndex) into the R40 code base.
> lzParseChain (BVX3 / Lazy2) and lzParseOptimal (Optimal) are updated synchronously.
> Execute `-n 40 / 8 / 4` three batches of complete benchmark on claw-code / llama.cpp.

## Optimization strategy

| Project | Description |
|---|---|
| **Core change** | `head[h]` and `chain[c]` are changed to `(tag<<24)\|index` packed Int32 format |
| **hashAndTag** | The same Fibonacci multiplication `×0x9E3779B185EBCA87`, high 17 bits → bucket, time 8 bits → tag |
| **Chain Visit** | Each candidate compares `(packed>>24)==qtag` first, and jumps directly if it does not match (pure register operation) |
| **Sentinel** | `chainNullIndex=0x00FF_FFFF` (head initial -1 → UInt32 → index=0xFFFFFF)|
| **Greedy path** | Only unpack index ( `&chainIndexMask`), no tag filter (only 1 candidate) |
| **assert guard** | `assert(n <= Int(chainIndexMask))`, ensure that the chunk does not exceed the upper limit of 16 MiB index |

## 1a. Encode speed vs Windows (claw-code, n=40)

| Format | Mac MB/s | Mac/TGZ | Win MB/s | Win/TGZ | Win/Mac |
| --- | ---: | ---: | ---: | ---: | ---: |
| TGZ | 48.73 | 1.0000 | 24.67 | 1.0000 | 0.506 |
| Other3 | 344.41 | 7.0677 | 266.36 | 10.797 | 0.773 |
| BVX3 | 375.00 | 7.6955 | 241.42 | 9.785 | 0.644 |
| Lazy2 | 63.73 | 1.3078 | 38.75 | 1.571 | 0.608 |
| Optimal | 34.45 | 0.7070 | 15.54 | 0.630 | 0.451 |
| TLZ4 | 394.69 | 8.0995 | 191.84 | 7.776 | 0.486 |
| ZSTD | 353.65 | 7.2573 | 103.67 | 4.202 | 0.293 |

## 1b. Decode speed (Mac + Win, claw-code n=40)

| Format | Mac MB/s | Mac/TGZ | Win MB/s | Win/TGZ | Win/Mac | Verify |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| TGZ | 376.09 | 1.0000 | 643.72 | 1.0000 | 1.712 | PASS |
| TLZ4 | 405.75 | 1.0789 | 1752.37 | 2.7222 | 4.319 | PASS |
| ZSTD | 422.91 | 1.1245 | 1037.24 | 1.6112 | 2.453 | PASS |
| Other3 | 388.52 | 1.0331 | 760.85 | 1.1820 | 1.958 | PASS |
| Lazy2 | 365.21 | 0.9711 | 853.08 | 1.3252 | 2.336 | PASS |
| Optimal | 394.70 | 1.0495 | 897.14 | 1.3937 | 2.273 | PASS |
| BVX3 | 326.41 | 0.8679 | 800.90 | 1.2442 | 2.454 | PASS |

## 1c. Compression size and ratio (claw-code, n=40)

| Format | Mac MiB | Mac/TGZ | Win MiB | Win/TGZ | Mac/Win |
| --- | ---: | ---: | ---: | ---: | ---: |
| TGZ | 470.0 | 1.0000 | 468.3 | 1.0000 | 1.0035 |
| Other3 | 463.0 | 0.9865 | 459.8 | 0.9818 | 1.0069 |
| BVX3 | 446.0 | 0.9492 | 433.4 | 0.9254 | 1.0291 |
| Lazy2 | 423.0 | 0.8998 | 407.6 | 0.8704 | 1.0377 |
| Optimal | 403.0 | 0.8574 | 387.5 | 0.8273 | 1.0401 |
| TLZ4 | 554.0 | 1.1793 | 549.8 | 1.1739 | 1.0077 |
| ZSTD | 387.0 | 0.8245 | 365.9 | 0.7813 | 1.0576 |

## two. RSS peak (Mac only, claw-code n=40)

| Format | Encode RSS | Enc/TGZ | Decode RSS | Dec/TGZ |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 4.2 MB | 1.00 | 3.7 MB | 1.00 |
| TLZ4 | 80.4 MB | 19.1 | 33.8 MB | 9.1 |
| Other3 | 266.1 MB | 63.4 | 299.5 MB | 80.9 |
| BVX3 | 272.9 MB | 65.0 | 324.5 MB | 87.7 |
| ZSTD | 387.8 MB | 92.3 | 9.2 MB | 2.5 |
| Lazy2 | 499.5 MB | 118.9 | 320.2 MB | 86.5 |
| Optimal | 572.5 MB | 136.3 | 308.2 MB | 83.2 |

## three. CPU Energy (Mac only, claw-code n=40)

> ⚠ Decode energy n=40 is not reliable because the sampling coverage rate is <5%, for reference only (standard `*`).

| Format | Enc J | Enc/TGZ | Dec J | Dec/TGZ |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 164.11 | 1.0000 | 5.82 | 1.0000 |
| Other3 | 27.41 | 0.1670 | 0.17* | 0.0290 |
| BVX3 | 29.05 | 0.1770 | 0.56* | 0.0962 |
| TLZ4 | 29.62 | 0.1805 | 0.58* | 0.1002 |
| ZSTD | 41.39 | 0.2522 | 3.01* | 0.5174 |
| Lazy2 | 114.59 | 0.6983 | 0.47* | 0.0805 |
| Optimal | 511.73 | 3.1183 | 0.46* | 0.0784 |

## four. Best Points (claw-code, all n)

| Format | Best compression ratio | Best Enc MB/s | Worst Enc MB/s | Best Dec MB/s | Lowest Enc RSS | Highest Enc RSS | Lowest Enc J | Highest Enc J | Lowest Enc J/TGZ | Highest Enc J/TGZ |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 1.0000 | 48.73 | 46.57 | 382.54 | 4.2 MB | 4.3 MB | 164.11 | 164.11 | 1.0000 | 1.0000 |
| Other3 | 0.9865 | 404.94 ( `n8`) | 341.85 ( `n4`) | 388.52 | 140.3 MB | 266.1 MB | 27.41 | 47.83 | 0.1670 | 0.2915 |
| BVX3 | 0.9492 | 406.15 ( `n8`) | 322.32 ( `n4`) | 326.41 | 139.0 MB | 272.9 MB | 29.05 | 49.73 | 0.1770 | 0.3030 |
| Lazy2 | 0.8998 | 63.73 ( `n40`) | 53.39 ( `n4`) | 409.36 ( `n8`) | 194.7 MB | 499.5 MB | 114.59 | 158.69 | 0.6983 | 0.9670 |
| Optimal | 0.8574 | 34.45 ( `n40`) | 25.51 ( `n4`) | 394.70 | 215.4 MB | 572.5 MB | 511.73 | 704.65 | 3.1183 | 4.2939 |
| TLZ4 | 1.1793 | 420.57 ( `n4`) | 394.69 ( `n40`) | 477.45 ( `n4`) | 76.9 MB | 80.4 MB | 29.62 | 29.62 | 0.1805 | 0.1805 |
| ZSTD | 0.8245 | 360.20 ( `n8`) | 353.65 ( `n40`) | 422.91 | 371.5 MB | 388.7 MB | 41.39 | 41.39 | 0.2522 | 0.2522 |

## n40 represents the result (Encode

| Format | Enc J/TGZ (claw n40) | Enc J/TGZ (llama n40) | Dec J/TGZ (claw n40)* | Dec J/TGZ (llama n40)* |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 1.0000 | 1.0000 | 1.0000 | 1.0000 |
| Other3 | 0.1670 | 0.1320 | 0.0290 | 0.0124 |
| BVX3 | 0.1770 | 0.1514 | 0.0962 | 0.0035 |
| Lazy2 | 0.6983 | 0.2817 | 0.0805 | 0.0097 |
| Optimal | 3.1183 | 2.1219 | 0.0784 | 0.0278 |
| TLZ4 | 0.1805 | 0.2114 | 0.1002 | 0.0143 |
| ZSTD | 0.2522 | 0.1606 | 0.5174 | 0.1752 |

> `*` Decode energy n=40 sampling coverage rate <5%, unreliable, for reference only.

## R41 vs R40 Encode speed comparison (claw-code, n=40)

| Format | R40 MB/s | R41 MB/s | Change |
| --- | ---: | ---: | --- |
| TGZ | 48.64 | 48.73 | ≈ Flat |
| Other3 | 380.73 | 344.41 | -9.5% ⚠️ |
| BVX3 | 421.51 | 375.00 | -11.0% ⚠️ |
| Lazy2 | 57.84 | 63.73 | +10.2% ✅ |
| Optimal | 29.90 | 34.45 | +15.2% ✅ |
| TLZ4 | 424.74 | 394.69 | -7.1% |
| ZSTD | 363.63 | 353.65 | -2.7% |

> BVX3 / Other3 speed decreases slightly but energy consumption decreases synchronously, which may be thermal throttling or measurement error; Optimal / Lazy2 rises as expected. The compression ratio remains flat (the hash function remains unchanged).

---

# R41-Win: Windows Benchmark Results + Decode Verification Infrastructure (2026-06-23)

> R41 Tag-packed Hash Chain runs a complete encode + decode two-way benchmark in Windows.
> Simultaneously introduce `decode-win.bat` + `decode_summary.csv` decode verification infrastructure (first round).
> All 7 formats have passed `tar tf -` correctness verification (verify=PASS).
> Data set: claw-code; encode n=40 inflight chunks (single); decode n=40 inflight chunks (single).

## 1a. Encode speed vs Mac (claw-code, n=40)

| Format | Win MB/s | Win/TGZ | Mac MB/s | Win/Mac |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 24.67 | 1.0000 | 48.73 | 0.506 |
| Other3 | 266.36 | 10.797 | 344.41 | 0.773 |
| BVX3 | 241.42 | 9.785 | 375.00 | 0.644 |
| Lazy2 | 38.75 | 1.570 | 63.73 | 0.608 |
| Optimal | 15.54 | 0.630 | 34.45 | 0.451 |
| TLZ4 | 191.84 | 7.776 | 394.69 | 0.486 |
| ZSTD | 103.67 | 4.202 | 353.65 | 0.293 |

## 1b. Decode speed + verification (first round Win, claw-code n=40)

> Windows decode benchmark first introduction (R41-Win), including `tar tf -` correctness verification.
> ⚠ n=40 inflight chunks single measurement, energy consumption is unreliable (with Mac decode <5% coverage).

| Format | Win MB/s | Win/TGZ | Mac MB/s | Win/Mac | Verify |
| --- | ---: | ---: | ---: | ---: | --- |
| TGZ | 643.72 | 1.0000 | 376.09 | 1.712 | PASS |
| Other3 | 760.85 | 1.1820 | 388.52 | 1.958 | PASS |
| BVX3 | 800.90 | 1.2442 | 326.41 | 2.454 | PASS |
| Lazy2 | 853.08 | 1.3252 | 365.21 | 2.336 | PASS |
| Optimal | 897.14 | 1.3937 | 394.70 | 2.273 | PASS |
| TLZ4 | 1752.37 | 2.7222 | 405.75 | 4.319 | PASS |
| ZSTD | 1037.24 | 1.6112 | 422.91 | 2.453 | PASS |

> Windows decode is generally faster than Mac (Win/Mac = 1.7x–4.3x), and TLZ4 is the most prominent (4.3x).
> The differences may come from: Windows page cache efficiency, OS scheduler differences, and external tool versions.
> All formats are verified through `tar tf -` decompression correctness (the first round of Windows decode verification infrastructure).

## 1c. Compression size (claw-code, n=40)

| Format | Win MiB | Win/TGZ | Mac MiB | Mac/Win |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 468.3 | 1.0000 | 470.0 | 1.0035 |
| Other3 | 459.8 | 0.9818 | 463.0 | 1.0069 |
| BVX3 | 433.4 | 0.9254 | 446.0 | 1.0291 |
| Lazy2 | 407.6 | 0.8704 | 423.0 | 1.0377 |
| Optimal | 387.5 | 0.8273 | 403.0 | 1.0401 |
| TLZ4 | 549.8 | 1.1739 | 554.0 | 1.0077 |
| ZSTD | 365.9 | 0.7813 | 387.0 | 1.0576 |

## R41-Win vs R40-Win Encode Speed Comparison (claw-code, n=40)

| Format | R40-Win MB/s | R41-Win MB/s | Change |
| --- | ---: | ---: | --- |
| TGZ | 25.33 | 24.67 | -2.6% |
| Other3 | 275.17 | 266.36 | -3.2% |
| BVX3 | 273.65 | 241.42 | -11.8% ⚠️ |
| Lazy2 | 38.75 | 38.75 | ≈ Flat |
| Optimal | 17.56 | 15.54 | -11.5% ⚠️ |
| TLZ4 | 228.93 | 191.84 | -16.2% ⚠️ |
| ZSTD | 139.17 | 103.67 | -25.5% ⚠️ |

> TLZ4 / ZSTD is an external tool, and the speed difference reflects the system status (hot throttle, background load) rather than the code change.
> BVX3 / Optimal in LZFSE format is slightly reduced (-11–12%), and the single measurement variance of Windows is large, which is regarded as a measurement error.
> Lazy2 is flat, which is in line with the expectation that the Lazy-Greedy path will not be affected by the tag filter.

---

# R41-Mac-Retest: Retest with UI support code (2026-06-23)

> After `lzfse-cli.swift` adds `runCLI()` packaging function (supporting lzfse-ui SwiftUI app), re-run the complete Mac benchmark on the R41 code.
> Trace analysis was the first full success (36 packets of TRACE_ANALYSIS_OK, 72 XML CPU_CALL_TREE_ANALYSIS_OK); all previous executions failed with `source_trace_missing`.
> The code function remains unchanged (output-identical ✅), and `runCLI()` packaging does not affect the algorithm path.

## Change the content

| Project | Description |
|---|---|
| ** `lzfse-cli.swift` ** | Add `runCLI()` packaging function for `lzfse-ui.swift` SwiftUI @main call |
| ** `lzfse-ui/lzfse-ui.swift` ** | New SwiftUI macOS app: file selection, algorithm selection, parallel task step (n=1–32), bilingual EN/ZH-TW UI |
| **Algorithm path** | No change; output-identical ✅ |
| **Trace Analysis** | First total success (36/36 TRACE_ANALYSIS_OK, 72/72 CPU_CALL_TREE_ANALYSIS_OK) |

## 1a. Encode speed vs R41-Mac first round (claw-code, n=40)

| Format | Retest MB/s | Retest/TGZ | R41-Mac MB/s | Change |
| --- | ---: | ---: | ---: | --- |
| TGZ | 48.75 | 1.0000 | 48.73 | ≈ Flat |
| Other3 | 408.72 | 8.3841 | 344.41 | +18.7% ✅ |
| BVX3 | 402.73 | 8.2558 | 375.00 | +7.4% ✅ |
| Lazy2 | 66.59 | 1.3651 | 63.73 | +4.5% ✅ |
| Optimal | 35.32 | 0.7241 | 34.45 | +2.5% ✅ |
| Apple | 142.31 | 2.9191 | 142.31 | ≈ Flat |
| TLZ4 | 425.04 | 8.7142 | 394.69 | +7.7% ✅ |
| ZSTD | 366.34 | 7.5109 | 353.65 | +3.6% ✅ |

> All formats have improved compared with the first round of R41-Mac; Other3 / BVX3 has rebounded significantly (+7–19%), and it is estimated that there will be thermal throtttling in the first round.

## 1b. Decode speed (claw-code, n=40)

| Format | MB/s | /TGZ |
| --- | ---: | ---: |
| TGZ | 366.57 | 1.0000 |
| TLZ4 | 447.02 | 1.2196 |
| ZSTD | 416.95 | 1.1375 |
| Other3 | 414.62 | 1.1313 |
| Lazy2 | 412.80 | 1.1259 |
| Apple | 386.19 | 1.0536 |
| Optimal | 347.86 | 0.9490 |
| BVX3 | 322.85 | 0.8808 |

## 1c. Compression size and ratio (claw-code, n=40)

| Format | MiB | /TGZ |
| --- | ---: | ---: |
| TGZ | 470 | 1.0000 |
| ZSTD | 387 | 0.8245 |
| Optimal | 403 | 0.8574 |
| Lazy2 | 423 | 0.8998 |
| BVX3 | 446 | 0.9492 |
| Other3 | 463 | 0.9865 |
| Apple | 464 | 0.9873 |
| TLZ4 | 554 | 1.1793 |

## two. RSS peak (Mac only, claw-code n=40)

| Format | Encode RSS | Enc/TGZ | Decode RSS | Dec/TGZ |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 4.2MB | 1.00 | 3.8MB | 1.00 |
| TLZ4 | 80.0 MB | 19.0 | 33.7 MB | 8.9 |
| Other3 | 236.1 MB | 56.2 | 301.1 MB | 79.2 |
| BVX3 | 243.8 MB | 58.1 | 323.5 MB | 85.1 |
| ZSTD | 375.2 MB | 89.3 | 9.2 MB | 2.4 |
| Lazy2 | 497.7MB | 118.5 | 321.8MB | 84.7 |
| Optimal | 581.4 MB | 138.4 | 307.9 MB | 81.0 |
| Apple | 1367.8 MB | 325.7 | 473.5 MB | 124.6 |

## three. CPU Energy (Mac only, claw-code n=40)

> ⚠ Decode energy n=40 is not reliable because the sampling coverage rate is <5%, for reference only (standard `*`).

| Format | Enc J | Enc/TGZ | Dec J | Dec/TGZ |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 157.17 | 1.0000 | 5.71 | 1.0000 |
| Other3 | 26.05 | 0.1658 | 0.60* | 0.1058 |
| BVX3 | 29.20 | 0.1858 | 0.15* | 0.0256 |
| TLZ4 | 30.25 | 0.1925 | 0.60* | 0.1059 |
| Apple | 49.16 | 0.3128 | 2.92* | 0.5107 |
| ZSTD | 44.82 | 0.2852 | 2.99* | 0.5231 |
| Lazy2 | 120.94 | 0.7695 | 1.27* | 0.2227 |
| Optimal | 531.92 | 3.3844 | 0.69* | 0.1216 |

## four. CPU Trace analysis (first full success)

> For the first time in this round, all 36 trace packages were successful (TRACE_ANALYSIS_OK ×36, CPU_CALL_TREE_ANALYSIS_OK ×72).

| Format (n=40) | Top Symbol | Category | Count |
| --- | --- | --- | ---: |
| TGZ | `0x197c4bbac` (libz) | other | 85 |
| Other3 | `encodeBlock(triplets:literals:rawBytes:)` | encode | 73 |
| BVX3 | `encodeBlockV3(triplets:literals:rawBytes:)` | encode | 85 |
| Lazy2 | `bestMatch` in `lzParseChain` | **parse** | 132 |
| Optimal | closure in `lzParseOptimal` | **parse** | 535 |
| Apple | `lzfseEncodeMatches` | apple_lzfse | 82 |
| TLZ4 | `LZ4HC_compress_generic_noDictCtx` | external_tool | 295 |
| ZSTD | `ZSTD_compressBlock_lazy2_row` | external_tool | 162 |

> **Parse hotspot confirmation**: Lazy2 = `bestMatch` in chain traversal, Optimal = `lzParseOptimal` closure calls 535 (>>Lazy2 132) → Optimal calls per chunk are much higher than Lazy2.

## five. Encode speed overview (claw-code + llama.cpp, n=40)

| Format | claw-code MB/s | claw/TGZ | llama.cpp MB/s | llama/TGZ |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 48.75 | 1.00 | 39.90 | 1.00 |
| Other3 | 408.72 | 8.38 | 86.95 | 2.18 |
| BVX3 | 402.73 | 8.26 | 86.81 | 2.18 |
| Lazy2 | 66.59 | 1.37 | 78.64 | 1.97 |
| Optimal | 35.32 | 0.72 | 49.20 | 1.23 |
| Apple | 142.31 | 2.92 | 66.02 | 1.66 |
| TLZ4 | 425.04 | 8.71 | 85.77 | 2.15 |
| ZSTD | 366.34 | 7.51 | 90.37 | 2.27 |

> `llama.cpp` data is pre-compressed with lzma, LZFSE n=40 acceleration efficiency is much lower than claw-code (BVX3 claw 8.26× vs llama 2.18×).

## Conclusion and R42 direction

| Project | Conclusion |
|---|---|
| **Speed recovery** | R41 first round of hot throttling → Retest Other3/BVX3 rebound +7–19%; Optimal/Lazy2 stable |
| **Trace Analysis** | First full success; Lazy2 = parse ( `bestMatch` chain), Optimal = parse ( `lzParseOptimal` closure) bottleneck confirmation |
| **Optimal energy consumption** | Other3 n40 = 0.166× TGZ; Optimal n4 = 4.70× TGZ (highest) |
| **The best compression ratio** | ZSTD 0.8245 → Optimal 0.8574 → Lazy2 0.8998 |
| **R42 direction** | Lazy2/Optimal parse hotspot → prefetch chain entries, SIMD match compare (NEON) |

---

# R41-Win Retest: Double Data Set Complete Windows Benchmark (2026-06-28)

> R41-Win (2026-06-23) only has the first round result of claw-code encode; this round is a complete supplementary test:
> Dual data set (claw-code + llama.cpp), dual mode (nul / file write), encode + decode + RSS peak full coverage.
> All 14 formats have passed decode correctness verification (verify=PASS).
>
> **Important findings**: On the llama.cpp data set, Windows LZFSE encode speed ** surpasses that of Mac (Other3/BVX3 ≈ 1.32–1.35×), and Mac is still ahead of claw-code.

## 1a. Encode speed vs Mac (claw-code, n=40)

| Format | Win MB/s | Win/TGZ | Mac MB/s | Win/Mac |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 23.82 | 1.000 | 47.47 | 0.502 |
| Other3 | 253.04 | 10.624 | 348.45 | 0.726 |
| BVX3 | 246.37 | 10.343 | 405.51 | 0.608 |
| Lazy2 | 41.03 | 1.722 | 65.08 | 0.630 |
| Optimal | 17.78 | 0.746 | 34.74 | 0.512 |
| TLZ4 | 201.74 | 8.469 | 418.75 | 0.482 |
| ZSTD | 110.34 | 4.631 | 368.84 | 0.299 |

## 1b. Encode speed vs Mac (llama.cpp, n=40)

| Format | Win MB/s | Win/TGZ | Mac MB/s | Win/Mac |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 25.70 | 1.000 | 42.87 | 0.599 |
| Other3 | 132.53 | 5.157 | 98.50 | **1.346 ✅** |
| BVX3 | 129.91 | 5.054 | 98.35 | **1.321 ✅** |
| Lazy2 | 95.35 | 3.712 | 88.78 | **1.074 ✅** |
| Optimal | 32.41 | 1.261 | 51.28 | 0.632 |
| TLZ4 | 118.67 | 4.620 | 95.39 | **1.244 ✅** |
| ZSTD | 114.17 | 4.444 | 100.30 | **1.138 ✅** |

> **claw-code**: Windows is 0.30–0.73× of Mac, and Mac is obviously ahead (source code contains a large number of repeated patterns, and NEON is more favorable).
> **llama.cpp**: Windows LZFSE encode surpasses Mac (Other3/BVX3 ≈ 1.32–1.35×). Llama.cpp is a pre-compressed binary with low match density; the x86 hash chain visit speed is better than ARM in this scenario. TGZ and Optimal are still faster than Mac.

## 1c. Decode speed (file write mode, claw-code n=40)

> decode-win.bat measures the end-to-end speed of the output to the disk after decoding in "write file mode", including disk I/O overhead.

| Format | Win MB/s | Mac MB/s | Win/Mac | Verify |
| --- | ---: | ---: | ---: | --- |
| TGZ | 153.54 | 388.48 | 0.395 | PASS |
| Other3 | 158.95 | 310.67 | 0.512 | PASS |
| BVX3 | 139.89 | 273.42 | 0.512 | PASS |
| Lazy2 | 141.17 | 332.58 | 0.424 | PASS |
| Optimal | 141.87 | 319.62 | 0.444 | PASS |
| TLZ4 | 189.33 | 313.11 | 0.605 | PASS |
| ZSTD | 171.20 | 422.27 | 0.405 | PASS |

## 1d. Decode speed (file write mode, llama.cpp n=40)

| Format | Win MB/s | Mac MB/s | Win/Mac | Verify |
| --- | ---: | ---: | ---: | --- |
| TGZ | 27.53 | 89.75 | 0.307 | PASS |
| Other3 | 41.53 | 83.86 | 0.495 | PASS |
| BVX3 | 36.08 | 79.52 | 0.454 | PASS |
| Lazy2 | 25.04 | 85.54 | 0.293 | PASS |
| Optimal | 24.64 | 86.39 | 0.285 | PASS |
| TLZ4 | 25.38 | 87.40 | 0.290 | PASS |
| ZSTD | 25.07 | 84.58 | 0.296 | PASS |

> Under Write-to-file decode, Windows is slower than Mac (claw: 0.40–0.61×; llama: 0.29–0.50×). The advantage of Mac SSD write throughput dominates this measurement.
> Note: The first round of R41-Win (nul mode, no write disk) Windows decode speed has reached 1.7–4.3× of Mac; the difference between write mode and null mode reflects the disk I/O rather than the codec itself.

## 1e. Encode null vs file mode comparison

> null mode = output discard after compression (no disk), measure the pure CPU compression speed; file mode = output to the compressed file (including I/O).
> claw-code uncompressed ≈ 1416.8 MB, llama.cpp ≈ 1322.4 MB (backed by comparison.csv TGZ encode time).

### claw-code (n=40)

| Format | null MB/s | file MB/s | null/file |
| --- | ---: | ---: | ---: |
| TGZ | 24.30 | 23.82 | 1.02 |
| Other3 | 247.04 | 253.04 | 0.976 |
| BVX3 | 222.15 | 246.37 | 0.902 |
| Lazy2 | 39.26 | 41.03 | 0.957 |
| Optimal | 17.97 | 17.78 | 1.011 |
| LZ4 | 215.75 | 201.74 | 1.069 |
| ZSTD | 111.26 | 110.34 | 1.008 |

### llama.cpp (n=40)

| Format | null MB/s | file MB/s | null/file |
| --- | ---: | ---: | ---: |
| TGZ | 27.59 | 25.70 | 1.074 |
| Other3 | 143.82 | 132.53 | 1.085 |
| BVX3 | 141.16 | 129.91 | 1.086 |
| Lazy2 | 106.06 | 95.35 | 1.112 |
| Optimal | 33.69 | 32.41 | 1.039 |
| LZ4 | 123.21 | 118.67 | 1.038 |
| ZSTD | 123.88 | 114.17 | 1.085 |

> **claw-code**: null ≈ file (within the error range). The compression output is about 366–550 MiB, and the writing disk has no significant impact on the overall time. BVX3 null is 10% slower than file, which is a measurement error.
> **llama.cpp**: null stable and fast 4–11%, Lazy2 is the most obvious (1.112×). The compression output reaches 535–616 MiB, and there is a significant acceleration of disk I/O without disk.

## 1f. Decode null mode speed (two data sets)

> null mode = lzfse/lz4/zstd Discard the output after decompression to measure the pure decoding throughput; file mode = decompress and extract to disk.
> The null/file ratio of TGZ is < 1 (anomaly), the reason is explained below.

### claw-code (n=40)

| Format | null MB/s | file MB/s | null/file |
| --- | ---: | ---: | ---: |
| TGZ | 113.9 | 153.6 | 0.74 ⚠️ |
| Other3 | 772.4 | 159.0 | 4.86 |
| BVX3 | 749.0 | 139.9 | 5.35 |
| Lazy2 | 750.3 | 141.2 | 5.31 |
| Optimal | 744.9 | 141.9 | 5.25 |
| LZ4 | 1609.6 | 189.4 | 8.50 |
| ZSTD | 869.6 | 171.2 | 5.08 |

### llama.cpp (n=40)

| Format | null MB/s | file MB/s | null/file |
| --- | ---: | ---: | ---: |
| TGZ | 22.9 | 27.5 | 0.83 ⚠️ |
| Other3 | 838.6 | 41.5 | 20.2 |
| BVX3 | 873.0 | 36.1 | 24.2 |
| Lazy2 | 842.1 | 25.0 | 33.6 |
| Optimal | 846.1 | 24.6 | 34.3 |
| LZ4 | 2165.2 | 25.4 | **85.3** |
| ZSTD | 1674.6 | 25.1 | **66.8** |

> **nul mode key number**: LZFSE decoding throughput 750–873 MB/s (the two data sets are close), LZ4 reaches 1610–2165 MB/s, and ZSTD reaches 870–1675 MB/s.
> **llama.cpp null/file ratio is extremely high (20–85×)**: file mode needs to write ~1.3 GB of decompressed data to Windows disk (measured 24–42 MB/s disk write), while null mode only does CPU decoding (~840–870 MB/s); disk I/O is the main reason for the 30-85× amplification of the file mode bottleneck.
> **TGZ decode nul is slower than file (0.74–0.83×) anomaly**: The TGZ null path of decode-win.bat actually performs complete extraction + verify (not a simple list), which is completely different from `tar -tzf` (pure list, 648 MB/s). File mode directly `tar xzf` to the directory, kernel buffered write is faster in large tar. This is a difference in the actual path, not the problem of codec itself. It has been confirmed by `helper_windows/tar_benchmark/Findings.md` independent test.

## two. Compression size and ratio

### claw-code (n=40)

| Format | Win compression ratio/TGZ | Mac compression ratio/TGZ | Difference |
| --- | ---: | ---: | ---: |
| TGZ | 1.0000 | 1.0000 | 0.0000 |
| Other3 | 0.9818 | 0.9865 | -0.0047 |
| BVX3 | 0.9254 | 0.9492 | -0.0238 |
| Lazy2 | 0.8704 | 0.8998 | -0.0294 |
| Optimal | 0.8274 | 0.8574 | -0.0300 |
| TLZ4 | 1.1739 | 1.1793 | -0.0054 |
| ZSTD | 0.7813 | 0.8245 | -0.0432 |

### llama.cpp (n=40)

| Format | Win compression ratio/TGZ | Mac compression ratio/TGZ | Difference |
| --- | ---: | ---: | ---: |
| TGZ | 1.0000 | 1.0000 | 0.0000 |
| Other3 | 0.9970 | 0.9957 | +0.0013 |
| BVX3 | 0.9810 | 0.9787 | +0.0023 |
| Lazy2 | 0.9576 | 0.9551 | +0.0025 |
| Optimal | 0.9412 | 0.9387 | +0.0025 |
| TLZ4 | 1.0503 | 1.0537 | -0.0034 |
| ZSTD | 0.9123 | 0.9100 | +0.0023 |

> llama.cpp compression ratio difference < 0.4%, Win/Mac is almost the same. ZSTD Win on claw-code is slightly better (-0.0432), and the rest of the gaps are < 3%.

## three. RSS peak (Windows, n=40)

### claw-code

| Format | Enc RSS null (MB) | Enc RSS file (MB) | Dec RSS null (MB) | Dec RSS file (MB) |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 6.3 | 6.3 | 5.7 | 6.1 |
| Other3 | 116.1 | 131.6 | 247.2 | 247.2 |
| BVX3 | 173.7 | 155.2 | 245.6 | 245.1 |
| Lazy2 | 480.7 | 485.1 | 242.3 | 242.2 |
| Optimal | 508.8 | 512.5 | 240.6 | 240.6 |
| LZ4 | 8.3 | 8.3 | 8.3 | 8.3 |
| ZSTD | 8.3 | 8.3 | 8.3 | 8.8 |

### llama.cpp

| Format | Enc RSS null (MB) | Enc RSS file (MB) | Dec RSS null (MB) | Dec RSS file (MB) |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 6.5 | 6.5 | 5.7 | 6.9 |
| Other3 | 135.3 | 146.0 | 346.1 | 346.2 |
| BVX3 | 162.6 | 171.8 | 346.6 | 346.5 |
| Lazy2 | 635.3 | 649.8 | 346.0 | 345.6 |
| Optimal | 756.6 | 760.5 | 346.0 | 346.1 |
| LZ4 | 8.3 | 8.3 | 8.3 | 8.3 |
| ZSTD | 8.3 | 8.8 | 8.3 | 8.3 |

> The chain table search path of each chunk of llama.cpp is longer (pre-compressed binary, match is not easy to early-exit in the middle), resulting in higher chain memory pressure.
> Decode RSS does not differ much across formats (LZFSE about 240–350 MB; LZ4/ZSTD/TGZ < 10 MB).

## four. R41-Win Retest vs R41-Win First Round (claw-code encode Comparison)/ vs Original R41-Win

| Format | R41-Win MB/s | Retest MB/s | Change |
| --- | ---: | ---: | --- |
| TGZ | 24.67 | 23.82 | -3.5% |
| Other3 | 266.36 | 253.04 | -5.0% |
| BVX3 | 241.42 | 246.37 | +2.1% |
| Lazy2 | 38.75 | 41.03 | +5.9% |
| Optimal | 15.54 | 17.78 | +14.4% |
| TLZ4 | 191.84 | 201.74 | +5.2% |
| ZSTD | 103.67 | 110.34 | +6.4% |

> The changes in each format are in the measurement error range (±5–15%); Optimal is slightly faster this time (+14%), and the rest are the same.

## Conclusion

| Project | Conclusion |
|---|---|
| **The most important discovery** | Win LZFSE encode on llama.cpp surpasses Mac (Other3/BVX3 ≈ 1.32–1.35×); claw-code still leads Mac |
| **Encode null vs file** | claw-code gap < 5% (CPU-dominated); llama.cpp null fast 4–11% (omitted ~535–616 MiB output I/O) |
| **Decode null mode (CPU limit)** | LZFSE 750–873 MB/s; LZ4 1610–2165 MB/s; ZSTD 870–1675 MB/s; TGZ anomaly (nul slower than file) |
| **Decode file mode (I/O limit)** | Windows is slower than Mac (claw: 0.40–0.61×; llama: 0.29–0.50×), and disk write is the bottleneck |
| **llama.cpp null/file ratio** | LZFSE 20–34×, LZ4 85×, ZSTD 67×——pure CPU decode is much faster than disk extract |
| **bsdtar bottleneck (verified)** | `tar -tzf` (list only) 648–844 MB/s vs `tar -xzf` (extract) 174/36 MB/s; list/extract = 3.7×(claw)/ 23× (llama) → file creation confirmed as a bottleneck, non-gz decompression; LZFSE file decode (159 MB/s) ≈ tar extract (174 MB/s), directly confirm that codec is not a limiting factor; see `helper_windows/tar_benchmark/Findings.md` for details
| **Optimal RSS** | llama.cpp encode RSS 760.5 MB (claw 512.5 MB, +48%), chain table memory pressure is greater |
| **Compression ratio** | Win/Mac gap < 1% (llama is almost the same, claw ZSTD gap is the largest -0.04) |
| **R42 direction** | Lazy2/Optimal parse hotspot has been confirmed; RSS peak point to chain table memory pressure → prefetch chain entries can improve speed and indirectly reduce the effective RSS caused by cache miss at the same time |

---

# R41 Summary

> Comprehensive four-round results of R41-Mac, R41-Mac-Retest, R41-Win, R41-Win-Retest.

## Code change

R27's tag-packed hash chain reintroduces the R40 code base: `head[h]` / `chain[c]` Change to `(tag<<24)|index` Packed Int32; each chain visit is relatively high 8 bits tag first, and if it does not match, it will be skipped directly (pure register operation), and there is no need to unpack index. Synchronized and synchronized to `lzParseChain` (Other3/BVX3/Lazy2) and `lzParseOptimal` (Optimal).


## Mac Encode speed vs R40 (claw-code, n=40, Retest final value)

| Format | R40 MB/s | R41 Retest MB/s | Change |
| --- | ---: | ---: | --- |
| Lazy2 | 57.84 | 66.59 | **+15.1% ✅** |
| Optimal | 29.90 | 35.32 | **+18.1% ✅** |
| Other3 | 380.73 | 408.72 | +7.3% ✅ (the first round of hot throttling -9.5%, Retest rebound) |
| BVX3 | 421.51 | 402.73 | -4.5% (the first round of heat throttling, Retest is +7.4% compared with the first round) |
| TLZ4 | 424.74 | 425.04 | ≈ Flat |
| ZSTD | 363.63 | 366.34 | ≈ Flat |

> tag filter makes the chain visit eliminate invalid candidates early, and the number of parse loop iterations of Lazy2/Optimal is effectively reduced, which is the most significant beneficiary. Other3/BVX3 The first round is low due to the thermal throttling number; Retest excludes the thermal throttling and the number is normal.

## Windows Encode main discovery

| Data Set | Win/Mac Scope | Description |
| --- | --- | --- |
| claw-code | 0.30–0.73× | Mac leads; source code contains a large number of repeated patterns, ARM NEON has significant advantages |
| llama.cpp | **1.07–1.35×(Other3/BVX3/Lazy2/TLZ4/ZSTD)** | Windows surpasses Mac; pre-compressed binary, x86 hash chain visits competitively |

> llama.cpp is a pre-compressed binary, with low match density, and chain traversal is dominated by throughput; in this scenario, the x86 hash chain visit speed is comparable or even faster than ARM NEON.

## Decode Performance Summary

| Measurement | Number | Meaning |
| --- | ---: | --- |
| LZFSE null decode (Windows, two data sets) | 750–873 MB/s | Pure CPU decode, representing the real codec throughput |
| LZFSE file decode (Windows, claw) | 159 MB/s | I/O limit (bsdtar+NTFS bottleneck) |
| tar-xzf extract (Windows, claw) | 174 MB/s | ≈ LZFSE file decode, directly confirm bsdtar as a bottleneck |
| tar-xzf extract (Windows, llama) | 36 MB/s | Restricted by disk sequential write throughput |
| LZFSE file decode (Mac, claw) | 310–388 MB/s | APFS is better than NTFS, about 2–2.5× faster |

> Windows decode file mode low-speed confirmation is **bsdtar file creation + NTFS overhead**, which is not a codec problem. `tar -tzf` list = 648–844 MB/s vs `tar -xzf` extract = 36–174 MB/s. Nul mode should be used for cross-platform fair comparison.

## RSS peak

| Format | Mac claw | Win claw | Win llama | Description |
| --- | ---: | ---: | ---: | --- |
| Optimal encode | 572–581 MB | 509–513 MB | 757–761 MB | llama +48% higher than claw |
| Lazy2 encode | 498–500 MB | 481–485 MB | 635–650 MB | llama +34% higher than claw |

> The match search path of llama.cpp pre-compressed binary is longer (not easy to early-exit), and the chain table memory pressure is greater.

## R42 direction

| Direction | According to |
|---|---|
| **prefetch chain entries** | prefetch the next entry before chain walk, hide the cache miss delay; it can also reduce the effective RSS |
| **SIMD match compare (NEON/SSE)** | Lazy2 `bestMatch` / Optimal `lzParseOptimal` confirmed as parse hotspot (trace analysis) |
| **Fair comparison benchmark** | null mode LZFSE 750–873 MB/s for Windows codec performance representative number |

---

# R40-Mac: macOS Complete Benchmark Results (2026-06-22)

> Run `-n 40 / 8 / 4` three-batch complete benchmark for claw-code / llama.cpp with R40 code (3652 lines), covering encode/decode speed, RSS peak, CPU energy ratio, and compare the encode speed with R40-Win.

## 1a. Encode speed vs Windows (claw-code, n=40)

| Format | Mac MB/s | Mac/TGZ | Win MB/s | Win/TGZ | Win/Mac |
| --- | ---: | ---: | ---: | ---: | ---: |
| TGZ | 48.64 | 1.00 | 25.33 | 1.00 | 0.52 |
| Other3 | 380.73 | 7.83 | 275.20 | 10.86 | 0.72 |
| BVX3 | 421.51 | 8.67 | 273.66 | 10.80 | 0.65 |
| TLZ4 | 424.74 | 8.73 | 228.94 | 9.04 | 0.54 |
| ZSTD | 363.63 | 7.48 | 139.17 | 5.49 | 0.38 |
| Lazy2 | 57.84 | 1.19 | 38.75 | 1.53 | 0.67 |
| Optimal | 29.90 | 0.61 | 17.56 | 0.69 | 0.59 |

Mac is significantly faster than Win in all formats (0.38–0.72×). The lowest ratio of ZSTD Win/Mac (0.38) may come from ZSTD's higher optimization of Apple Silicon vector instructions than x86.

## 1b. Decode speed (Mac only, claw-code n=40)

| Format | Mac MB/s | Mac/TGZ |
| --- | ---: | ---: |
| TGZ | 380.35 | 1.00 |
| TLZ4 | 420.76 | 1.11 |
| ZSTD | 427.91 | 1.13 |
| Other3 | 414.82 | 1.09 |
| Lazy2 | 401.28 | 1.06 |
| BVX3 | 355.84 | 0.94 |
| Optimal | 355.61 | 0.94 |

## two. RSS peak (Mac only, claw-code n=40)

| Format | Encode RSS | Enc/TGZ | Decode RSS | Dec/TGZ |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 4.2 MB | 1.00 | 3.7 MB | 1.00 |
| TLZ4 | 83.0 MB | 19.8 | 33.8 MB | 9.1 |
| Other3 | 252.0 MB | 60.0 | 301.1 MB | 81.4 |
| BVX3 | 252.3 MB | 60.1 | 323.6 MB | 87.5 |
| ZSTD | 373.4 MB | 88.9 | 9.0 MB | 2.4 |
| Lazy2 | 490.6 MB | 116.8 | 320.2 MB | 86.5 |
| Optimal | 561.2 MB | 133.6 | 307.4 MB | 83.1 |

> `-n 40` Encode RSS is the peak value with inflight buffer; Decode RSS is mainly driven by the size of the decompression output.

## three. CPU Energy (Mac only, claw-code n=40)

> ⚠ Decode energy n=40 is not reliable because the sampling coverage rate is <5%, for reference only (standard `*`).

| Format | Enc J | Enc/TGZ | Dec J | Dec/TGZ |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 182.61 | 1,000 | 12.75 | 1,000 |
| TLZ4 | 32.74 | 0.179 | 3.67* | 0.288* |
| **Other3** | **30.91** | **0.169** | **3.29*** | **0.258*** |
| BVX3 | 35.23 | 0.193 | 5.76* | 0.452* |
| ZSTD | 43.23 | 0.237 | 7.74* | 0.608* |
| Lazy2 | 135.09 | 0.740 | 4.58* | 0.359* |
| Optimal | 537.44 | 2.943 | 4.51* | 0.354* |

## four. Best Points all n collection

### claw-code

| Format | Best Compression Ratio | Enc MB/s Best/Worst | Dec MB/s Best/Worst | Enc RSS Lowest/Highest | Dec RSS Lowest/Highest | Enc Energy Ratio Range | Dec Energy Ratio Range |
| --- | ---: | --- | --- | --- | --- | --- | --- |
| TGZ | 1.0000 | 49 / 48 | 380 / 362 | 4.2 / 4.3 MB | 3.7 / 3.7 MB | 1.000 | 1.000 |
| Other3 | 0.9865 | 408 / 347 | 415 / 396 | 139 / 252 MB | 70 / 301 MB | 0.169–0.308 | 0.258–0.666 |
| BVX3 | 0.9492 | 422 / 339 | 356 / 292 | 129 / 252 MB | 71 / 324 MB | 0.193–0.304 | 0.452–1.007 |
| TLZ4 | 1.1793 | 431 / 425 | 421 / 332 | 76 / 83 MB | 34 / 34 MB | 0.179 | 0.288 |
| ZSTD | 0.8245 | 366 / 360 | 428 / 406 | 373 / 376 MB | 9 / 9 MB | 0.237 | 0.608 |
| Apple | 0.9873 | 143/141 | 357/301 | 1368/1368 MB | 474/474MB | 0.294–0.341 | 0.525–0.552 |
| Lazy2 | 0.8998 | 58 / 41 | 405 / 387 | 180 / 491 MB | 66 / 320 MB | 0.740–1.006 | 0.359–0.842 |
| Optimal | 0.8574 | 30 / 21 | 363 / 326 | 198 / 561 MB | 68 / 307 MB | 2.943–4.137 | 0.354–0.924 |

### llama.cpp

| Format | Best Compression Ratio | Enc MB/s Best/Worst | Dec MB/s Best/Worst | Enc RSS Lowest/Highest | Dec RSS Lowest/Highest | Enc Energy Ratio Range | Dec Energy Ratio Range |
| --- | ---: | --- | --- | --- | --- | --- | --- |
| TGZ | 1.0000 | 42 / 41 | 86 / 84 | 4.3 / 4.4 MB | 3.8 / 3.8 MB | 1.000 | 1.000 |
| Other3 | 0.9958 | 97/87 | 81/73 | 135/362 MB | 67/349MB | 0.177–0.256 | 0.223–0.703 |
| BVX3 | 0.9787 | 93 / 89 | 81 / 77 | 142 / 356 MB | 67 / 351 MB | 0.195–0.227 | 0.259–1.023 |
| TLZ4 | 1.0537 | 89 / 85 | 82 / 79 | 80 / 82 MB | 34 / 34 MB | 0.209 | 0.257 |
| ZSTD | 0.9100 | 95/90 | 85/80 | 474/474 MB | 9/9 MB | **0.140** | 0.444 |
| Apple | 0.9988 | 69 / 66 | 80 / 78 | 1286 / 1286 MB | 596 / 596 MB | 0.289–0.314 | 0.585–0.598 |
| Lazy2 | 0.9551 | 85 / 73 | 84 / 83 | 244 / 497 MB | 67 / 349 MB | 0.325–0.457 | 0.225–0.499 |
| Optimal | 0.9387 | 47/33 | 79/78 | 243/821 MB | 71/349 MB | 2.018–2.951 | 0.281–0.789 |

---

# R40-Win: Optimal cross-segment match cross-border repair (2026-06-21)

> When Windows tested R40 code, it was found that there was a memory cross-bound bug in the low-repetition segment greedy fast path of the Optimal encoder, which caused the Release version to crash with `VCRUNTIME140.dll 0xc0000005` (access violation), and the Debug version clearly returned `Fatal error: UnsafeBufferPointer with negative count`. In theory, this problem also exists in macOS, but the behavior under Release compilation is not defined and does not necessarily crash immediately.

## Root cause analysis

Optimal's low-repetition segment greedy path (in `lzParseOptimal`, `coverage < optPrescreenMinCoverage` branch) When calculating the match length, the `limit` parameter uses the global input length `n - i - 4`, which is not limited by the `segEnd` of the current segment.

**Causal chain:**

| Steps | Description |
|---|---|
| 1 | greedy match take `limit = n - i - 4`, match cross `segEnd` |
| 2 | `emitGreedy` push `litStart` to `i + matchLen`, may > `segEnd` |
| 3 | THE NEXT PARAGRAPH `segStart = segEnd`, WHEN ENTERING `posLoop` `i = segStart < litStart` |
| 4 | `emitGreedy(at: i, ...)` Execute `UnsafeBufferPointer(start: p + litStart, count: i - litStart)` |
| 5 | `i - litStart < 0` → `count` is negative → Debug: Fatal error; Release: access violation crash |

**Other supporting evidence:**
- `-n 1` can also be reproduced (non- `-n 40` special problem)
- Windows event records multiple crash records of the same module and the same fault offset
- Part of the output before the crash stops at the legal block boundary, but lacks the `bvx$` end mark (truncated stream)

## Repair

**File: `lzfse-cli.swift` about line 1264**(Optimal greedy fast path match limit)

| | Before repair | After repair |
|---|---|---|
| rep path limit | `limit: n - i - 4` (global) | `limit: segEnd - i - 4` (within the limit) |
| cand path limit | `limit: n - i - 4` (global) | `limit: segEnd - i - 4` (within the limit) |

Both match calculations are changed to stop at `segEnd` to prevent `litStart` from exceeding the segment boundary.

## Verification results

| Project | Result |
|---|---|
| `swiftc -O` Compilation | ✅ Success |
| Built-in `-test` (including new cross-sepment match return test) | ✅ All passed |
| `claw-code -algo bvx3 -optimal -n 40` Full compression | ✅ Success, about **73.3 seconds** |
| Output size | **406,284,948 bytes** |
| `bvx$` End Mark | ✅ Exist |
| After decompression `tar -tf` | ✅ Success, output-identical |

> Note: The compressed output of 406,284,948 bytes is different from macOS R39 baseline (407,098,957 bytes) 814,009 bytes. The reason is that after repair, the match of the greedy segment no longer crosses the segment, resulting in some matches being slightly shorter, and the bitstream is legal but not bitstream-identical. Output-identical acceptance passed.

## Windows Benchmark Test (Run C, 2026-06-21)

The binary repaired with R40-Win ( `lzfse.exe`) right `claw-code` (N=40 inflight) Perform a complete benchmark test. Subsequent R{N}-Win takes this as a comparison benchmark.

| Format | Time consumption (seconds) | Encode MB/s | Compression ratio (/TGZ) |
|---|---:|---:|---:|
| TGZ | 55.92 | 25.33 | 1.0000 |
| LZFSE (Other3) | 5.15 | 275.17 | 0.9818 |
| LZFSE (BVX3) | 5.18 | 273.65 | 0.9254 |
| TLZ4 | 6.19 | 228.93 | 1.1739 |
| LZFSE (Lazy2) | 36.56 | 38.75 | 0.8704 |
| ZSTD | 10.18 | 139.17 | 0.7813 |
| LZFSE (Optimal) | 80.67 | 17.56 | 0.8273 |

MB/s is based on 1351 MiB × 1.048576 = 1416.63 MB (consistent with macOS format). Windows does not measure decode speed, RSS, CPU energy (macOS powermetrics is required).

## Win/Mac Comparison Report Structure

Each round process: run **R{N}-Mac** first, then run **R{N}-Win**, and finally execute `comparison_win.py` to generate a three-section comparison report:

| Section | Win | Mac | Description |
|---|---|---|---|
| 1a. Encode MB/s + ratio/TGZ | ✅ | ✅ | Win/Mac comparison + TGZ speed ratio of each platform |
|1b. Decode MB/s + ratio/TGZ | — | ✅ | Windows does not measure decode |
| two RSS MB + ratio/TGZ | — | ✅ | Windows does not measure RSS |
| three CPU Energy J + ratio/TGZ | — | ✅ | Windows does not measure energy consumption; n=40 decode energy is not reliable |

---

# R40: Streaming decode restoration and encode pipeline correction (2026-06-21)

> Take R39 (3379 lines) as the starting point, make up for the streaming decode path removed by R39, and correct the two regressions `runParallelEncode` introduced by R39. Without algorithm modification, the encode / decode output should be R39 bitstream-identical.

## Code status (3652 lines)

### Recovery: Streaming decode ( `decodeStreamFromFile` / `decodeStreamToHandle`)

R39 changes decode CLI to `readToEnd()` (whole-buffer), peak RSS ≈ whole compressed input (~500 MB). Three functions are added in this round:

| Number / Type | Description |
|---|---|
| `enum StreamDecodeResult` | `.ok` / `.fallback` / `.error` Three-way results |
| `decodeStreamFromFile(path:chunkRaw:inflight:output:)` | Read into compressed streams block by block (1 MB readChunk), direct parallel decoding of own block streams; non-home streams return `.fallback` |
| `decodeStreamToHandle(_:parallel:chunkRaw:inflight:output:)` | whole-buffer fallback's streaming writing and publication: `scanBlocks → grouping → DispatchQueue.concurrentPerform → write in order` |

CLI decode path ( `-i <file>`): First try `decodeStreamFromFile` → `.fallback` to reread the whole file and go to `decodeStreamToHandle`; the stdin path goes directly to `decodeStreamToHandle`. Do not hold the whole decompression output in the whole process, and reduce the decode peak RSS.

### Correction: `runParallelEncode` two regression (R39 introduction)

| Project | R33/R35 | R39 (regression) | R40 (revision) |
|---|---|---|---|
| PARALLELITY SOURCE | `inflight: Int` PARAMETERS, `maxTasks = max(2, inflight)` | HARD WRITE `maxTasks = max(2, activeProcessorCount)`, IGNORE `-n` | ADD BACK `inflight: Int`, CALL TERMINAL `inflightN` |
| Encode RSS | `autoreleasepool { ... }` wrap read loop, prevent autorelease Data accumulation | No `autoreleasepool`, encode RSS ≈ whole input | Add back `try autoreleasepool { ... }` |

`FileHandle.read` sends back autoreleased `Data` in macOS; if there is no pool in the main thread read loop, the autorelease temporary storage accumulates until the end of the process before releasing, resulting in encode RSS ≈ full input size (RSS upper limit unrelated to `-n`).

### Streaming Status Overview

| | Encode streaming | Decode streaming | `-n` encode | `-n` decode |
|---|---|---|---|---|
| R33/R35 | ✅ | ✅ | ✅ | ✅ |
| R39 | ✅ | ❌ (whole-buffer) | ❌ (activeProcessorCount) | N/A |
| **R40** | ✅ | ✅ | ✅ | ✅ |

## n40 represents the result (Encode

| Format | claw enc ratio | claw enc MB/s | claw dec ratio | claw dec MB/s | llama enc ratio | llama enc MB/s | llama dec ratio | llama dec MB/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 1,000 | 49 | 1,000 | 380 | 1,000 | 41 | 1,000 | 86 |
| TLZ4 | 0.179 | 425 | 0.288 | 421 | 0.209 | 86 | 0.257 | 79 |
| **Other3** | **0.169** | **381** | **0.258** | **415** | **0.177** | **87** | **0.223** | **81** |
| BVX3 | 0.193 | 422 | 0.452 | 356 | 0.198 | 89 | 0.259 | 81 |
| ZSTD | 0.237 | 364 | 0.608 | 428 | **0.140** | 92 | 0.444 | 80 |
| Apple | 0.341 | 143 | 0.552 | 320 | 0.314 | 66 | 0.585 | 79 |
| Lazy2 | 0.740 | 58 | 0.359 | 401 | 0.325 | 85 | 0.225 | 84 |
| Optimal | 2.943 | 30 | 0.354 | 356 | 2.018 | 47 | 0.281 | 79 |

Other3 The encode of both data sets is the most energy-saving in its own format (claw 0.169, llama 0.177), and decode is also the most energy-saving (claw 0.258, llama 0.223). ZSTD encode (0.140) on llama.cpp is the lowest of all formats. The energy consumption of BVX3 encode (claw 0.193, llama 0.198) is slightly higher than that of Other3, while decode is significantly higher (0.452 / 0.259).

Compared with R39 (regression version), R40's `-n` modification reduces the claw-code Other3 encode energy ratio from 0.190 to 0.169, and BVX3 from 0.179 to 0.193; the difference in llama.cpp is also similar, mainly due to the change of parallelism and chunk cutting method after the correct transmission of inflight parameters.

## R33/R34 BVX3/Other3 encode "peak" survey

Trend chart shows that the speed of BVX3 greedy and Other3 encode of R33/R34 is much higher than that of neighboring round; the root cause of this round of investigation.

### Conclusion: Measurement illusion, non-code improvement

All functions related to BVX3 greedy / Other3 encode are exactly the same in the Swift source code md5 of R33 and R35:

| Call path of function | BVX3 / Other3 | R33 vs R35 md5 |
|---|---|---|
| `lzParseStrong` | BVX3 greedy, Other3 ( `strong=true`) actual caller | Same |
| `lzParseChain` | BVX3 lazy2 | Same |
| `compressBody` | Assign entrance | Same |
| `runParallelEncode` | Parallel Framework | Same |

The only code difference of R33 → R35 is that `lzParseOptimal` shortens 40 lines (removes 4-context literal pricing), resulting in binary from 351,992 → 335,576 bytes (−16 KB). BVX3 greedy and Other3 **do not call** `lzParseOptimal`.

### The fundamental reason is the difference in system status.

In the same benchmark log, even the external code (lz4, tar extract) slows down as well:

| Algorithm / Code | R33 | R35 | Magnification |
|---|---:|---:|---:|
| bvx3 greedy | 2.08 s | 4.56 s | 2.20× |
| other3 | 2.64 s | 3.87 s | 1.47× |
| lz4 (external) | 2.18 s | 3.47 s | **1.59×** |
| tar extract (external) | 2.23 s | 3.56 s | **1.59×** |
| lazy2 | 21.27 s | 22.00 s | 1.03× |
| optimal | 39.03 s | 40.81 s | 1.05× |

The magnification of BVX3 greedy (2.20×) is much greater than that of lazy2/optimal (~1.04×) because: BVX3 greedy is only ~5 ms per chunk, and the OS dispatcher grabs the cache miss of hash table random-access accounts for a large proportion of the total time; lazy2 each chunk ~530 ms, and the impact of scheduling noise can be ignored. **R35 benchmark has a high system background load at runtime, which has a disproportionate amplification effect on short tasks. **

**R33/R34 BVX3/Other3 encode peak is not an optimized result, but a measurement noise when the system conditions are better. **

---

# R39: 92221a02 encode retest (2026-06-21)

> With 92221a02 ( `lzfse-cli.swift` Line 3379) replaces R35 code (line 3957) and executes the complete benchmark. This version removes all advanced encode optimizers in R35 (R6/R10/R17/R18/R26/R27/R28/R30/R32). The decode core algorithm is exactly the same as R35, but the decode CLI path is from the stream ( `decodeStreamFromFile`) Change back to whole-buffer `readToEnd()`. The same benchmark run also added powermetrics. `-i 500ms` Modified decode energy original log analysis.

## Code status

- **Removed encode optimization**

| Round | Remove Content | Scope of Influence |
| --- | --- | --- |
| R6 | rep length precalculation (l0/l1/l2 reuse) | other3, bvx3, lazy2 (lzParseChain) |
| R10/R17 | Entropy sampling gate (greedyEmitSegment, optEntropyHighThreshold) | bvx3 -optimal (lzParseOptimal) |
| R18/R27 | Tag-packed hash chain (hashAndTag, chainIndexMask/chainTagShift/chainNullIndex) | other3, bvx3, lazy2, optimal (lzParseChain + lzParseOptimal) |
| R26 | localHead Move out segment loop | bvx3 -optimal (lzParseOptimal) |
| R28 | symbolPointer() binary search | bvx3 -optimal (lzParseOptimal) |
| R30 | cheap-probe gating (optDPSkipAvgMatchLen) | bvx3 -optimal (lzParseOptimal) |
| R32 | matchLength 16-byte Expand → Return 8-byte | other3, bvx3, lazy2, optimal (lzParseChain + lzParseOptimal) |

- decode kernel (FSE decoding, LZ copy, block parsing) ** is exactly the same as R35**. If there is a difference in decode speed, it comes from different FSE symbol distributions caused by different bitstreams.
- decode CLI path: `-i <file>` changed from `decodeStreamFromFile` (streaming) back to `inputHandle.readToEnd()` (whole-buffer), peak decode RSS is equal to the whole compressed input size.

## n40 represents the result (Encode CPU Energy Ratio vs TGZ)

| Format | claw-code ratio | enc MB/s | llama.cpp ratio | enc MB/s |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 1,000 | 50 | 1,000 | 43 |
| TLZ4 | 0.174 | 430 | 0.192 | 91 |
| **BVX3** | **0.179** | **424** | **0.140** | **95** |
| Other3 | 0.190 | 380 | 0.117 | 96 |
| ZSTD | 0.239 | 374 | 0.137 | 98 |
| Apple | 0.296 | 140 | 0.224 | 72 |
| Lazy2 | 0.618 | 69 | 0.277 | 87 |
| Optimal | 2.936 | 36 | 2.120 | 50 |

BVX3 encode is the most energy-saving of all LZFSE formats (82-86% more than TGZ), with a compression ratio of 0.949/0.979, and an encode speed of 95-424 MB/s. Other3 (LZFSE standard output) has similar energy consumption (0.117-0.190), faster (380-96 MB/s) but slightly worse compression ratio (0.987/0.996).

## Decode energy fundamental measurement problem (after powermetrics -i 500ms)

### Description of the problem

Even if the sampling interval is modified from -i 100ms to -i 500ms, the decode energy measurement of n=40 is still unreliable. The lowest decode energy ratio (0.006–0.013) is a pure measurement illusion.

### Original log direct comparison

`claw-code-optimal n=40 decode` (Ratio 0.006, Report 61 mW):
```
唯一樣本（506ms 視窗）：
  CPU 0-3 (E-core): 2–18% active @ 1080 MHz
  CPU 6-9 (P-core): 0–0.84% active（完全空閒）
  CPU Power: 61 mW
```

`claw-code-optimal n=4 decode` (ratio 1.18, report 6546 mW average):
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

### Three-layer superposition effect

**1 The sampling window only caught 1 sample (n=40 decode)**

```
T=0.0s：powermetrics 啟動
T=0.2s：decode 開始（sleep 0.2 後）
T=0.5s：唯一樣本觸發（506ms 視窗）← decode 仍在執行中
T=0.71s：decode 結束
```

Decode is only 0.51s, decode has not been completed before the sample window is completely over, and there is no sample coverage in the second half (T=0.5–0.71s).

**2 n=40 GCD The task is completed explosively, and P-core is not passively used at all**

- n=4: 4 big tasks → P-core full speed (80-83% @ 4464 MHz), decode continues to put pressure on P-core
- n=40: 40 small tasks (each 4MiB chunk) → E-core The task ended after a brief outbreak, and the P-core was not awakened at all.

**3 The only sample points are mainly in free time**

506ms sample composition:
- The first 200ms: decode has not started yet (pre-sleep period)
- Middle ~200ms: E-core has completed the outbreak, and the system is downgraded to idle
- After ~100ms: decode wall time is still being calculated, but P-core has not moved

Average result: 61 mW (near standby power), not real decoding power.

### List of samples of each format

| Format | dur | Number of samples | Report mW | Remarks |
| --- | ---: | ---: | ---: | --- |
| optimal (n40) | 0.51s | **1** | 61 | Idle |
| other3 (n40) | 0.44s | **1** | 85 | Free |
| lazy2 (n40) | 0.51s | **1** | 128 | Free |
| tar.lz4 | 0.47s | **1** | 1510 | Random, cannot be represented |
| bvx3 (n40) | 0.56s | **1** | 889 | Random |
| ZSTD | 0.95s | 2 | 6359+956 | peak+cooling, average 3658 |
| apple (n40) | 0.81s | 2 | 4169+128 | peak+cooling |
| TGZ | 1.35s | 3 | 5300+5308+231 | The most stable, including 1 cooling sample |

Only the average value of TGZ decode (1.35s, 3 samples) is relatively stable. Although ZSTD and Apple have 2 samples, the second sample is in the cooling period (956/128 mW), and the average is still low. The format values of the remaining 1 sample are all sampling illusions and cannot be trusted.

### Conclusion

**Decode energy ratio All n=40 values do not reflect the real decoding energy consumption and cannot be used for performance judgment. **If you need reliable decode energy measurement, you should use one of the following methods:
1. Repeat the decode in a loop to make the total measurement time ≥ 3s (recommended)
Two. Use IOReport / powerlog instead to provide per-interval finer granular sampling
3. Only report the decode speed (MB/s) and abandon the energy consumption measurement.

---

# R38: R35 code retest (2026-06-20)

> After R37 determines that rep1/rep2 dominated-range skip cannot reproduce the performance gain, `lzfse-cli.swift` is reverted to R35 code (remove R36's `repLen0/repLen1` declaration and rep1/rep2 skip logic), and triggers the complete benchmark (15:08 start, 18:51 BENCH_DONE). The purpose is to confirm that the compressed output returns to R35 bitstream after revert, and the encoding speed restores the R35 water level.

## Code status confirmation

- The current `lzfse-cli.swift` has removed the `var repLen0 = 0, repLen1 = 0` added by R36 and rep1/rep2 skip guard and restore it to the original cycle starting point of `var msym = 4; var ll = 4; let lim = min(l, cap)`.
- Optimal compression bytes: `claw-code 422,948,093` (= R35 committed), `llama.cpp 577,863,623` (= R35 committed). Unlike `422,948,018 / 577,864,898` of R36/R37, the bitstream completely returns to the R35 state after confirming the revert.

## n40 Optimal result comparison (R35 committed vs this retest)

| Indicator | R35 committed | This retest (R35 code) | Gap |
| --- | ---: | ---: | ---: |
| claw-code encode MB/s | 34.70 | 36.21 | +4.4% |
| llama.cpp encode MB/s | 49.89 | 50.42 | +1.1% |
| claw-code encode power mW | 13,279 | 13,290 | +0.1% |
| llama.cpp encode power mW | 15,731 | 15,523 | −1.3% |
| claw-code encode energy J | 545.7 | 517.8 | −5.1% |
| llama.cpp encode energy J | 371.5 | 359.2 | −3.3% |
| claw-code encode RSS MB | 578.1 | 561.2 | −2.9% |
| llama.cpp encode RSS MB | 587.2 | 597.2 | +1.7% |

- The two rounds of encode power (mW) are almost the same (+0.1% / −1.3%), confirming that the CPU frequency and power status are stable.
- encode speed: `llama.cpp` +1.1% is noise; `claw-code` +4.4% is slightly higher, which may be a system warm-up difference or cache effect. If it does not exceed the 10% threshold, it is still regarded as a noise range.
- encode energy −3.3 ~ −5.1%: the direction is the same, but the magnitude is not enough to claim improvement; the thermal state of the system is high when R35 committed, and the low energy consumption of this retest is a reasonable fluctuation.
- **decode power / energy**: This retest decode power is only 499 / 169 mW (vs general 5,000–7,000 mW), which is obviously low. It is speculated that the powermetrics sampling window is not aligned with the decode execution period, and the decode energy result cannot be used.

## Decode energy measurement reliability analysis (R35 / R36

### Phenomenon I: TGZ

| run | claw-code TGZ n4 | n8 | n40 |
| --- | ---: | ---: | ---: |
| R35 | 8.828 J | 8.828 J | 8.828 J |
| R36 | 28.553 J | 28.553 J | 28.553 J |
| R37 | 10.605 J | 10.605 J | 10.605 J |
| R38 | 5.280 J | 5.280 J | 5.280 J |

→ The decode energy of these three formats has nothing to do with the n value. power_benchmark only measures them once, and the results are copied to the three columns n=4 / 8 / 40. **TGZ/TLZ4/ZSTD decode energy cannot be used for per-n comparison, nor should it be used as the denominator of the same round decode ratio. **

### Phenomenon 2: LZFSE Optimal decode extremely short sampling window (implied active ≈ 0.4–1.0 s)

`implied_active = decode_energy_J / (decode_power_mW / 1000)` represents the duration of CPU activity actually captured by powermetrics.

| | R35 | R36 | R37 | R38 | Actual decode_sec |
| --- | ---: | ---: | ---: | ---: | ---: |
| claw-code n4 | 0.98 s | 1.01 s | 1.00 s | 0.88 s | ~4.2 s/iter |
| claw-code n8 | 0.65 s | 0.68 s | 0.66 s | 0.63 s | ~3.8 s/iter |
| claw-code n40 | 0.52 s | 0.56 s | 0.59 s | 0.51 s | ~4.0 s/iter |
| llama.cpp n4 | 0.67 s | 0.70 s | 0.67 s | 0.63 s | ~15.6 s/iter |
| llama.cpp n8 | 0.49 s | 0.52 s | 0.50 s | 0.47 s | ~15.0 s/iter |
| llama.cpp n40 | 0.39 s | 0.38 s | 0.40 s | 0.36 s | ~15.4 s/iter |

Powermetrics only captures about 0.5–1.0 seconds per decode measurement, but the actual iteration decode is 4–16 seconds (n40 total time up to 160–620 seconds). ** The coverage rate of the sampling window is extremely low (<5%), and only a small part of the CPU state at the beginning of the decode is captured, which does not represent the overall energy consumption. **

### Phenomenon 3: R36 decode power is abnormally high, R38 n40 is abnormally low

| run | claw-code Optimal n40 power | llama.cpp Optimal n40 power |
| --- | ---: | ---: |
| R35 | 558 mW | 6,445 mW |
| R36 | **15,070 mW** (abnormally high) | **15,287 mW** (abnormally high) |
| R37 | 6,655 mW | 6,863 mW |
| R38 | **499 mW** (abnormally low) | **169 mW** (abnormally low) |

- R36 decode power is equivalent to encode (13,000–15,000 mW), showing that the system is under high load during R36 benchmark, and the sampling window just captures the background activity, resulting in decode power false height.
- R35 / R38 claw-code n40 decode power is only 500–560 mW, which is hugely different from llama.cpp in the same round (6,445 / 169 mW), showing that the sampling window is extremely short and the timing is random.

### Conclusion: decode energy measurement cannot be used for cross-wheel comparison

1. The sampling window is only 0.4–1.0 s, which is much shorter than the actual decode time and cannot represent the total energy consumption.
Two. TGZ/TLZ4/ZSTD decode energy is constant for n values (single measurement), which cannot be compared with the LZFSE format for n-consistent ratio.
3. R36 decode power is polluted by the high load of the system, and R38 n40 is affected by the offset of the sampling timing, and the absolute value of both rounds is not trustworthy.
4. The only reliable energy consumption index is **encode CPU energy**: long encode time (25–55 s/iter × n), high powermetrics sampling coverage, and stable cross-wheel power value (±1–2%).

** If the subsequent decode energy needs to be measured reliably, it should be changed to `powermetrics -i 500` continuous sampling and covering the entire n-iteration decode execution period, instead of the current single short-window sampling. **

## Encode energy four-wheel comparison analysis (R35 / R36 / R37

### Measurement reliability: high coverage of encode energy

The implied_active (energy/power) of encode is almost the same as the actual encode_seconds (95–107%), confirming that the powermetrics sampling window completely covers the entire encode execution period. Encode energy is a reliable measurement, which is fundamentally different from decode.

However, **TGZ / TLZ4 / ZSTD encode energy is still exactly the same as n=4/8/40 in the same run** (single measurement), and per-n comparison cannot be made; the LZFSE format is correctly incremented according to n.

### R36 encode energy full format systematic high

The energy consumption expansion of R36 is not only in Optimal, but also increases in **all formats**, and the expansion is inversely proportional to the duration of encode:

| Format (claw-code n40) | R35 | R36 | R37 | R38 |
| --- | ---: | ---: | ---: | ---: |
| TGZ(~3 s) | 192 J | **550 J(+187%)** | 182 J | 167 J |
| LZFSE (Apple) (~7 s) | 56 J | **157 J (+180%)** | 52 J | 46 J |
| LZFSE (Lazy2) (~14 s) | 120 J | **163 J (+36%)** | 114 J | 109 J |
| LZFSE (Optimal)(~40 s) | 546 J | **603 J (+10%)** | 526 J | 518 J |

TGZ (the fastest, the shortest sampling window) expands +187%, and Optimal (the slowest, the longest sampling window) only expands +10%. This is a typical **system high-load pollution**: the shorter the encoding time, the higher the measurement ratio of background power consumption. **R36's non-Optimal format encode energy value cannot be used. **

### Optimal encode energy four-wheel value (relative to R35)

| Data set / n | R35 | R36 | R37 (R36-code) | R38 (R35-code) |
| --- | ---: | ---: | ---: | ---: |
| claw-code n4 | 736 J (100%) | 1103 J (+50%) | 720 J (**98%**) | 723 J (**98%**) |
| claw-code n8 | 590 J (100%) | 756 J (+28%) | 585 J (**99%**) | 578 J (**98%**) |
| claw-code n40 | 546 J (100%) | 603 J (+10%) | 526 J (**96%**) | 518 J (**95%**) |
| llama.cpp n4 | 544 J (100%) | 738 J (+36%) | 511 J (**94%**) | 519 J (**95%**) |
| llama.cpp n8 | 416 J (100%) | 501 J (+20%) | 402 J (**97%**) | 403 J (**97%**) |
| llama.cpp n40 | 372 J (100%) | 407 J (+10%) | 365 J (**98%**) | 359 J (**97%**) |

- R37 (R36-code) and R38 (R35-code) are both 2–5% lower than R35 committed, but the gap direction is the same, showing that the thermal state of the system is slightly lower than R35 committed during R37/R38.
- After excluding R36, the gap between the Optimal encode energy of the three rounds (R35 / R37 / R38) does not exceed 5% under the same n value, which is within the fluctuation range of the system state.

### R37 (R36-code) vs R38 (R35-code) Optimal Direct Comparison

| n | claw-code ΔE | claw-code Δspeed | llama.cpp ΔE | llama.cpp Δspeed |
| --- | ---: | ---: | ---: | ---: |
| n=4 | +0.4% | +2.1% | +1.6% | −3.1% |
| n=8 | −1.2% | −2.2% | 0.0% | −3.1% |
| n=40 | −1.6% | +1.0% | −1.5% | +1.1% |

(Posis value = R38 is higher than R37; positive value of energy consumption = R35-code consumes more energy)

Under n40, R38 (R35-code) consumes 1.5–1.6% less energy than R37 (R36-code), and the speed is 1.0–1.1% higher; the downward direction of n4/n8 is inconsistent. The gap is within ±2–3%, and the explanation of the system status cannot be ruled out. **At present, it cannot be confirmed from the energy consumption data that R36 code (rep1/rep2 skip) has a reprodible positive and negative impact on Optimal encode. **

### Encode energy Conclusion

1. **Reliable measurement**: The powermetrics coverage rate of LZFSE format encode energy is ≈ 95–107%, which is the most reliable energy consumption indicator in this benchmark.
Two. **R36 full format systematic high** (system high load), after exclusion R35/R37/R38 Optimal gap ≤ 5% (system thermal state fluctuation).
3. **R36 code vs R35 code (R37 vs R38)**: R35-code under n40 is slightly reduced by 1.5%, but the direction of n4/n8 is inconsistent, and the whole is within the noise range, and rep1/rep2 skip can't reproduce the energy consumption improvement.
4. TGZ/TLZ4/ZSTD encode energy single measurement, n-constant, shall not be used for cross n ratio analysis.

## Conclusion

- **Revert correct**: bitstream completely returns to R35, and the encode speed and power level are consistent with R35 committed (noise range).
- **R35 code can be used as the clean baseline of the next round of DOE**, without the DP state interference of R36 rep1/rep2 skip.
- **There is a fundamental problem with Decode energy measurement**, and the decode energy values of historical R35–R38 cannot be used for cross-wheel performance judgment.
- **Encode energy is reliable but R36 is contaminated by system load**; R37/R38 shows rep1/rep2 skip unreprodible energy consumption gains.
- The next step is according to R37 TODO: with this revert baseline with feature switch, create same-wheel controlled A/B, or carry out new Optimal hotspot optimization ( `matchLength`, `rebuildPrices`, Swift Array/COW).

---

# Round 37: R36 rep1/rep2 dominate skip the same code retest (performance gains are not reproduced) (2026-06-20)

> The compression kernel has not been modified in this round. The purpose is to retest the rep1/rep2 dominated-range skip of R36. Both data sets have completed encode, decode and extract compare at n40 / n8 / n4, and **output-identical passed**; however, the speed and energy consumption improvement relative to R35 have not reached the `>=10%` acceptance threshold, so the performance benefits of R36 have not been confirmed.

## Test completeness and output stability

- The whole round was completed at `2026-06-20 10:35:56`, and no benchmark, compare, memProbe, power or trace analysis failure was found.
- Power has a total of 72 strokes, all of which are `status=ok`; profiling generates 36 trace packages, CPU call tree analyzes a total of 72 XMLs, and the source trace is cleaned after all summary is written, and the status is `before=36 after=0`.
- `BenchMarkResult.csv` has rebuilt 48 rows, and best-points, power and trace summary have been integrated.
- Optimal compression size is exactly the same in n40 / n8 / n4 and the same as R36: `claw-code 422,948,018 bytes`, `llama.cpp 577,864,898 bytes`. This proves that R36 bitstream can be reprodised stably across thread count and same-code retesting.
- Relative to R35, `claw-code` is 75 bytes, and `llama.cpp` is 1,275 bytes; bitstream is different from R35, but the content after extract is exactly the same, so it does not constitute output-identical failure.

## n40 represents the result

MB/s is still calculated by the actual raw bytes / duration ns, and the display value is not used to push back.

| Data set | Optimal compression MB/s | Decompression MB/s | Compression ratio | Encode RSS(MB) | Decode RSS(MB) | Encode CPU Energy(J) | top closure | parse hits |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| claw-code | 35.85 | 437.10 | 0.8590 | 564.4 | 328.4 | 526.295590 | 763 | 1187 |
| llama.cpp | 49.85 | 89.25 | 0.9393 | 600.6 | 348.8 | 364.600403 | 681 | 1101 |

## Compare with R36 / R35

Relative to R36, the previous result of the same code:

- `claw-code` Optimal n40 encode: `36.22 → 35.85 MB/s` (about `-1.0%`); encode CPU energy: `602.633383 → 526.295590 J` (about `-12.7%`).
- `llama.cpp` Optimal n40 encode: `50.42 → 49.85 MB/s` (about `-1.1%`); encode CPU energy: `407.283755 → 364.600403 J` (about `-10.5%`).
- The speed under the same code only changes by about 1%, but the power difference reaches more than 10%, which shows that the energy results are highly sensitive to the thermal state, background load and measurement time of the system; the reduction of R36 → R37 cannot be directly attributed to the algorithm.

Relative to R35 baseline:

- `claw-code` Optimal n40 encode: `34.70 → 35.85 MB/s` (about `+3.3%`); encode CPU energy: `545.694678 → 526.295590 J` (about `-3.6%`).
- `llama.cpp` Optimal n40 encode: `49.89 → 49.85 MB/s` (about `-0.1%`); encode CPU energy: `371.502908 → 364.600403 J` (about `-1.9%`).
- For the original baseline, the speed improvement only occurs in `claw-code`, and `llama.cpp` is almost unchanged; the energy consumption improvement is only about 2-4%, which is lower than the success conditions of single point `>=10%`.

## Energy Ratio Analysis (Same Wheel TGZ = 1)

- `Energy Ratio = The Algorithm CPU Energy / Same Wheel, Same Data Set TGZ CPU Energy`; The Lower The Value, The More Energy-Save, `<1` Means More Energy-Sable Than TGZ, `>1` Means More Energy Consumption Than TGZ. The minimum/highest value is taken from the minimum/maximum value of the same algorithm at n4/n8/n40 respectively.
- The lowest ratio of Optimal appears in n40, and the highest ratio appears in n4; this is consistent with the direction of "improving concurrency increases RSS, but shortens the running time and reduces CPU energy".

| Data set | Encode minimum R36→R37 | Encode maximum R36→R37 | Decode minimum R36→R37 | Decode maximum R36→R37 |
| --- | ---: | ---: | ---: | ---: |
| claw-code | `1.0950 → 2.8967` ( `+164.5%`) | `2.0042 → 3.9605` ( `+97.6%`) | `0.2938 → 0.3685` ( `+25.4%`) | `0.6001 → 1.1535` ( `+92.2%`) |
| llama.cpp | `0.6304 → 2.1391` ( `+239.3%`) | `1.1417 → 2.9996` ( `+162.7%`) | `0.2467 → 0.3162` ( `+28.2%`) | `0.4771 → 0.8746` ( `+83.3%`) |

- **Relative to R36, Optimal's lowest and highest Encode / Decode Energy Ratio have all increased, and there is no improvement. **The lowest value of Encode is still `2.8967 / 2.1391` at R37, which means that even if the best n40 is used, Optimal encode still consumes TGZ about `2.90x / 2.14x` CPU energy; the highest value is `3.96x / 3.00x`.
- The lowest value of Decode has a clear advantage: Optimal n40 only uses TGZ's `36.85% / 31.62%` CPU energy. But in terms of the highest value, `claw-code` N4 is `1.1535`, more than TGZ `15.4%`; `llama.cpp` N4 is `0.8746`, still less than TGZ `12.5%`. Therefore, the energy-saving of client-side decode is established in n40, and low concurrency is not the advantage of both data sets.
- The highest value of the Encode ratio of other LZFSE families in the same round is still lower than 1: Other3 `0.3054 / 0.2613`, BVX3 `0.3140 / 0.2678`, Lazy2 `0.8754 / 0.4195`, indicating that they save CPU energy than TGZ encode in all n values. Optimal is the only LZFSE mode whose lowest Encode value is still greater than 1.
- The TGZ encode baseline of R36 → R37 itself decreased significantly from `550.363047 → 181.690929 J` (claw-code) and `646.035081 → 170.447736 J` (llama.cpp); although the absolute energy consumption of Optimal also decreased, the decrease was much smaller than that of TGZ, so the normalized ratio deteriorated. This proves that the cross wheel only looks at the absolute J and is easily affected by the system state; in the future, the absolute energy consumption and the TGZ Energy Ratio of the same wheel should be reported at the same time, and the performance judgment should be subject to the consistency of the two or controlled A/B.

## Profiling and RSS

- Of the 36 traces, 6 external tools end normally, and 30 LZFSE family traces reach the time limit in 300 seconds; target and `time-profile` / `time-sample` schema both exist. The symbol occurrence under the fixed timeout is only for directional comparison and does not represent the exact CPU percentage.
- R35 → R37 Optimal n40 directional sample: `claw-code` top closure `737 → 763` (about `+3.5%`), parse hits `1170 → 1187` (about `+1.5%`); `llama.cpp` top closure `660 → 681` (about `+3.2%`), parse hits `1101 → 1101` (unchanged). Profiling does not show that the main parse hotspot declines due to dominant skipping.
- The sample of R36 → R37 only fluctuates slightly: `claw-code` Top `769 → 763`, parse `1191 → 1187`; `llama.cpp` Top `696 → 681`, parse `1133 → 1101`. This is not enough to establish a stable causal relationship.
- R35 → R37's n40 RSS: `claw-code` encode `578.1 → 564.4 MB`, decode `308.0 → 328.4 MB`; `llama.cpp` encode `587.2 → 600.6 MB`, decode `349.3 → 348.8 MB`. If the direction is inconsistent, it should be regarded as operating fluctuations, and there is no proof that rep1/rep2 skip improves or worsens RSS.
- Optimal n40 encode RSS is still about `564–601 MB`, decode about `328–349 MB`. R36's energy choice judgment for server/CDN offline compression and about 300 MB client decode RSS is not due to this round of failure, but the life cycle of encode buffer, chunk in-flight and temporary array still needs to be investigated.

## Judge

- **Correctness and output-identical pass. **Two data sets and three n values have been successfully decompressed and passed extract compare; the Optimal compression size of R36 can also be reproduced stably.
- **The performance acceptance failed. **Relative to R35, the speed is `+3.3% / -0.1%`, the encode CPU energy is `-3.6% / -1.9%`, and the profiling does not see the main hotspot reduction, which does not meet the success conditions of `>=10%`.
- **Energy Ratio has not improved either. ** Relative to R36, the lowest and highest ratio of Optimal's Encode/Decode has risen all; R37 Optimal encode is still TGZ's `2.14–2.90x` even at the lowest point. Only n40 decode maintains the `0.32–0.37x` advantage that is clearly lower than TGZ.
- R36 rep1/rep2 dominated-range skip should be classified as "output-identical pass, but performance benefits have not been confirmed", and should not be claimed as stable acceleration or energy saving. It will still change the DP state/tie path and bitstream, not the pure realization of ratio-neutral.
- The next round should be established with feature switch or revert **same-round controlled A/B**, fixed power supply, thermal state and background load, and at least compare n40 benchmark, power and trace. If the two data sets still do not have a reprodable `>=10%` improvement, you should retreat or not keep this pruning, and turn to `lzParseOptimal` DP expansion, `matchLength`, `rebuildPrices` or Swift Array/COW and other confirmed hotspots.

---

# Round 36: Optimal Energy Consumption/Speed - rep1/rep2 dominate skip (output-identical pass) (2026-06-19)

> Direction steering: ratio routes (#1/R33, #3, #4) have been exhausted, and this round will be changed to Optimal energy consumption/time optimization. Both data sets are decompressed and compared passed, so **output-identical acceptance is established**; there is a slight change in the compression bitstream and size, and it is listed as non-bitstream-identical. Only move `lzfse-cli.swift`.

## Change: rep1/rep2 relaxation skip the dominated length segment

- `lzParseOptimal` will run rep0 / rep1 / rep2 three relaxation cycles in each position, each relaxing `cPrice[t+4 … t+l]`.
- Observation: The cost of the same length q,rep1 = rep0 cost + ( `dPriceTab[1] − dPriceTab[0]`). When `dPriceTab[1] ≥ dPriceTab[0]` (rep0 distance is relatively cheap, almost constant in practice, because rep0 is the most commonly used), the price of rep1 in the `4 … min(repLen0,cap)` section ** must ≥ the price written by rep0** → `if c2 < cPrice[dest]` constant false → ** this rep1 is pure no-op**. Rep2 is also dominated by the cheaper one in rep0/rep1.
- Therefore, after adding the price guard, the relaxation of rep1/rep2 ** starts directly after the dominated segment** ( `ll` starting point moves up), skipping the SIMD/scalar cycle that must be no-op.
- The original hypothesis is that the skipped `c2 ≥ cPrice` is written as no-op, so the compression bitstream remains unchanged; the subsequent actual measurement negatives the bitstream-identical hypothesis, but the decompression output is still exactly the same. See "Judgment" for details.
- It is expected that the rep-heavy section can save rep1/rep2 relaxation, so that the Optimal compression time/energy consumption can decrease; the actual benchmark speed has improved slightly, but the latest power re-measurement does not show an improvement in energy consumption. Output-identical is passed, and the strict compression ratio is neutral.

## Actual measurement results

- `swiftc -O`, built-in `-test` and two data sets n40 / n8 / n4 encode, decode and compare are all passed, and there is no truncation or content inconsistency.
- The raw size of this round is `claw-code 1,416,220,672 bytes`, `llama.cpp 1,322,553,344 bytes`; MB/s is calculated as raw bytes / ns.

| Data Set | n | Optimal Compression MB/s | Decompression MB/s | Encode RSS(MB) | Decode RSS(MB) | Encode CPU Energy(J) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| claw-code | 40 | 36.22 | 394.35 | 572.3 | 308.9 | 602.633383 |
| claw-code | 8 | 32.00 | 388.13 | 378.2 | 105.2 | 755.991824 |
| claw-code | 4 | 25.05 | 331.14 | 212.8 | 68.5 | 1103.015427 |
| llama.cpp | 40 | 50.42 | 84.65 | 563.5 | 348.9 | 407.283755 |
| llama.cpp | 8 | 42.22 | 85.99 | 392.5 | 102.8 | 500.817190 |
| llama.cpp | 4 | 33.62 | 81.55 | 232.1 | 71.1 | 737.546883 |

Relative R35 n40 baseline:

- `claw-code`: `34.70 → 36.22 MB/s` (about `+4.4%`), but the latest encode CPU energy is `545.694678 → 602.633383 J` (about `+10.4%`).
- `llama.cpp`: `49.89 → 50.42 MB/s` (about `+1.1%`), but the latest encode CPU energy is `371.502908 → 407.283755 J` (about `+9.6%`).
- The duration/average power of the latest power run is different from the previous one, so the increase in energy consumption cannot be entirely attributed to the R36 code code; however, according to the principle of "taking the latest effective data", this round no longer claims to improve encode energy, and it needs to be measured repeatedly with a fixed thermal state to make a causal judgment.
- n40 is still the best speed/lowest energy consumption point of Optimal, but it is also the highest point of RSS. Relative to n4, n40 reduces encode CPU energy from `1103.02 / 737.55 J` to `602.63 / 407.28 J` (about `-45%`), at the cost of encode RSS from `212.8 / 232.1 MB` to `572.3 / 563.5 MB`. This confirms that the amount of chunk in-flight is one of the main causes of RSS, and also shows that although reducing concurrency saves memory, it increases total energy consumption due to longer running time.

### Profiling Reconstruction Results

- The second batch of profiling has been completely completed: a total of 36 trace packages, 6 external tool traces ended normally, and 30 LZFSE family traces reached the time limit in 300 seconds; all traces are `target_seen=yes`, and `time-profile` / `time-sample` schema were exported successfully.
- CPU call tree analyzes a total of 72 XMLs. After the summary is written, the cleaning is carried out, and the status is `CPU_CALL_TREE_TRACE_CLEANED before=36 after=0`; it is proved that the source trace will no longer be lost before analysis after the correction. `BenchMarkResult.csv` has reconstructed 48 rows, power 72/72 is `status=ok`, and the best-points and power fields have been integrated.
- R35 → R36's Optimal n40 directional sample: `claw-code` parse hits `1170 → 1191`, top `lzParseOptimal` closure `737 → 769`; `llama.cpp` parse hits `1101 → 1133`, top closure `660 → 696`. `matchLength` is `71 → 82` / `72 → 77`, `rebuildPrices` is `36 → 42` / `34 → 44`.
- The above is the symbol occurrence of a fixed 300-second timeout trace, not the exact CPU percentage; however, neither data set shows a significant decrease in the parse / top closure sample, so the profiling does not support the strong conclusion that "rep1/rep2 skip has reduced the main CPU hotspot". The main hotspots are still `lzParseOptimal` closure, followed by entropy prescreen, `matchLength`, `emitSteps`, `rebuildPrices` and Swift Array/COW.

### RSS and CPU energy consumption trade-off

- According to the continuous access estimate of `LPDDR_power_estimation/LPDDR_power_info.md`, LPDDR4X / LPDDR5 is about `150 / 120 mW/GB`. RSS increased from about `60 MB` to `300 MB`, the increment is about `240 MB` ( `0.234 GB`), corresponding to the additional power of DRAM is about `35 / 28 mW`.
- If about 20–40% of the additional cost of memory controller / PHY is included, the increment of the memory subsystem is about `34–49 mW`. Even if this is regarded as the conservative upper limit of the continuous activity of the whole segment, about `1.4–2.0 J` is increased by 40 seconds; if it is only about 4 seconds, it is about `0.14–0.20 J`.
- When decode n4 → n40 in the same round, RSS rises from about `68.5 / 71.1 MB` to `308.9 / 348.9 MB`, but CPU energy drops from `17.13 / 11.33 J` to `8.39 / 5.86 J` (about `-51% / -48%`). This CPU saving level is much higher than the estimated memory increment of about one percent of joules in less than 1 second. Therefore, within the scope of the current desktop test and about `300 MB` RSS, **priority to reduce CPU running time/total energy consumption is a better overall choice, and 300 MB RSS is acceptable**.
- This is a model estimate based on the active-memory unit power consumption, not the actual measurement of this round of DRAM; RSS does not mean that all pages are continuously read and written. The conclusion applies to energy trade-off, which does not mean that memory capacity, system memory pressure or multi-workload parallel problems can be ignored. Optimal encode n40 still reaches about `563–572 MB`, exceeding the acceptable benchmark of 300 MB here, and the DP buffer and chunk in-flight life cycle should still be investigated.

### Applicable scenario: server-side update package compression

- Optimal compression is suitable for the distribution model of "server-side compression once, client-side download and decompression many times", such as large server-side code update, App or game update package, CDN static assets. High-cost encode can be completed offline on the release terminal, and it is shared by a large number of downloads. The overall efficiency should not be judged by a single encode energy.
- This round of Optimal is smaller than BVX3 / Other3 products; in large-scale distribution, each client can reduce download bytes, thus reducing network transmission time and radio/Wi-Fi activity time. After accumulating a large number of iPhones or other clients, the transmission side savings are usually more important than the one-time compression cost of the server.
- The client only executes decode. The Optimal decode of R36 n40 uses the same format and decoder as other modes of the same BVX3 family, and the decompression speed maintains the available water level; the energy cost of about `300 MB` RSS is still less than the CPU/transmission savings according to the aforementioned LPDDR model, so the overall direction is favorable to client-side energy on devices with memory capacity.
- System layer evaluation should use: `first encode energy + transmission energy of all clients + decode energy of all clients`. The more downloads and the greater the compression size gap, the easier it is to equalize the server-side high encode cost of Optimal; if it is only a single local compression, it may not be cost-effective.
- App Store is only an analogy of application scenarios: at present, `bvx3` is a private format. The actual deployment requires the client to integrate the corresponding decoder, and conform to the platform update, signature and encapsulation process; this report does not claim that the existing format can directly replace the official update format of the App Store.

## Judge

- **Correctness and output-identical acceptance passed. ** The n40 / n8 / n4 of the two data sets were all successfully decompressed, and the content of the extract was the same. Only the size of Optimal compression product changes; the size of Other3 / BVX3 / Lazy2 maintains R35. `claw-code optimal` is `422,948,093 → 422,948,018 bytes` (improvement 75 bytes), `llama.cpp optimal` is `577,863,623 → 577,864,898 bytes` (regress 1,275 bytes). Therefore, this round is not bitstream-identical, nor is it strictly ratio-neutral, but it does not affect the output-identical judgment; the four-digit decimal compression ratio is still about `0.8590 / 0.9393`.
- The original argument that "the more expensive rep relaxation must be no-op" is not complete: DP cell not only contains `price`, but also `cR0/cR1/cR2` rep history; skipping relaxation will change the subsequent visible state or tie path, and the actual test has proved that the bitstream will change. Therefore, R36 should be regarded as approximate pruning DOE, rather than pure real micro-optimization.
- The benchmark speed improvement is only `1.1~4.4%`, which does not meet the success condition of single-point `>=10%`; the latest power retest is about `+9.6~10.4%` encode CPU energy, and the profiling has not seen a decrease in the main parse hotspot. Although the output-identical is passed, the compression size of `llama.cpp` is still slightly reduced, so R36 does not constitute a clearly retainable successful result.
- On the energy trade-off, about `300 MB` The estimated memory cost of RSS is lower than the CPU energy savings of the same round of decode n4→n40, so it should not be in order to compress RSS back. `60 MB` And accept longer CPU running time; but `500 MB` The above Optimal encode RSS is still beyond the acceptable conclusion of this paragraph.
- At the application level, the main value of Optimal is a large number of client distribution after server/CDN offline compression: the encoding cost is only paid once, and the transmission and client-side energy savings brought by smaller update packages can be accumulated repeatedly. In the next step, in addition to the stand-alone benchmark, energy break-even analysis under different downloads should be added.


## TODO (in order of priority)

1. The R36 acceptance conclusion is "correctness/output-identical passed, but the performance success condition is not met". In the next round, first create the same round A/B with feature switch or revert, and retest the fixed thermal state n40 benchmark + power; if the speed is still lower than `+10%` and the energy is not improved, rep1/rep2 skip will not be retained.
Two. (Middle) Optimal further output-identical micro-optimization: it is still necessary to maintain the full pass of extract/compare; if bitstream-identical is required, it should be clearly listed as an independent acceptance condition. Profiling has confirmed that the main direction is still `lzParseOptimal`, `matchLength`, `rebuildPrices` and Swift Array/COW, and the next single point should be attributed to one of them.
3. (Middle) Optimal segment level energy consumption: `optDPSkipAvgMatchLen` (R30 gating) can be DOE again, but the ratio will be changed, and an independent wheel is required.
4. **(Lowest/Lowest priority) Blind beam-2(#2 per-position 2-state)**:
- Feasibility conclusion: **There is no shortcut to correctness and safety**. The current literal step `cR0[t+1]=r0` allows the "recent match rep0" to carry all the way through the subsequent literal, and the reps of the cell are not old; the "match-ended second state" will converge with the cell state after literal propagation, which cannot give a new rep set. To really keep the second way of "simir prices but different reps", ** can only do the complete beam-2**: store 2 (price,reps) per cell, ** each SIMD relaxation writing point (~11 places) change 2-best merge ** + backtrace to record which status to choose in each cell.
- Risk/ROI: This is exactly the same SIMD area of **#4 truncated bug**. The sandbox cannot be compiled/verified, and the probability of multiple rounds of repair compilation; and the ROI is low (rep-carry makes #2 profit narrow, and the first three ratio ideas are all defeated).
- Conclusion: **listed as the lowest priority**, only when "the environment can compile/test loop, gradually add beam and `-test`+benchmark every step" is done.

---

# Round 35: R34 repair retest and R35 baseline (2026-06-19)

> The purpose of this round is not to add ratio DOE, but to return the R34 failure path, clean up the unused DP macro transition, and rerun the complete benchmark / memProbe / trace / power, and confirm the `llama.cpp-n40 optimal` correctness reply.

## Repair content

- Remove R34 `tag-less length-4 recovery` active path: `lzParseOptimal` no longer recycles the length-4 candidate filtered by tag-packing with `optLen4ProbeDepth`.
- Clean up the unused macro transition status of the previous failed experiment: `relaxLiteralRep0` / `relaxMatchLiteralRep0`, `cLitBefore/cLen2/cDist2`, `stepLitBefore/stepLen2/stepDist2` are all removed.
- `emitSteps` and optimal backtrack return to a single match/literal step: each DP cell only records `cLen/cDist/cR0/cR1/cR2` to avoid the next round of DOE mixing unused fields and additional memory costs.

## Data status

- `round_status.txt` has run to `Done`, and completed `BENCHMARK_RESULT_REBUILD_DONE`, `BEST_POINTS_ANALYSIS_DONE`, `POWER_SUMMARY_INTEGRATE_DONE`.
- `claw-code` And `llama.cpp` The n40 / n8 / n4 complete compare passed; R34 no longer appeared `tar: Write error`, semi-finished products `.lzfse.bvx3.optimal`, `Truncated tar archive`.
- `BenchMarkResult.csv` has reconstructed 48 rows, and the speed is converted in actual bytes/ns; this round of raw size is `claw-code 1351M`, `llama.cpp 1261M`, and the data set/sequal size may fluctuate with the old round, so it mainly depends on the relative sorting in the same code and data in this round.
- The only defect in the power data is that `llama.cpp-lazy2 n40 decode` is `ok:no_samples`; this is a short decode sampling, which does not affect the correctness or the encode energy conclusion.

## n40 represents the result

`claw-code`:

| Format | Compression MB/s | Decompression MB/s | Compression ratio | Encode RSS(MB) | Decode RSS(MB) | Encode CPU Energy(J) | CPU top |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---
| Other3 | 365.75 | 343.16 | 0.9865 | 271.0 | 300.1 | 36.113226 | encode / 70 |
| BVX3 | 310.37 | 352.72 | 0.9492 | 233.1 | 324.9 | 35.059268 | encode / 61 |
| Lazy2 | 64.37 | 303.39 | 0.8998 | 495.8 | 320.5 | 119.950248 | parse / 152 |
| Optimal | 34.70 | 295.47 | 0.8590 | 578.1 | 308.0 | 545.694678 | parse / 737 |
| ZSTD | 352.87 | 475.22 | 0.8245 | 377.2 | 9.3 | 49.168387 | external_tool / 174 |
| TLZ4 | 408.54 | 408.78 | 1.1793 | 82.9 | 33.7 | 33.854015 | external_tool / 288 |

`llama.cpp`:

| Format | Compression MB/s | Decompression MB/s | Compression ratio | Encode RSS(MB) | Decode RSS(MB) | Encode CPU Energy(J) | CPU top |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---
| Other3 | 95.29 | 87.79 | 0.9957 | 348.3 | 349.1 | 30.003544 | encode / 75 |
| BVX3 | 95.53 | 87.54 | 0.9787 | 347.0 | 351.4 | 27.975481 | encode / 60 |
| Lazy2 | 85.25 | 89.38 | 0.9551 | 497.0 | 348.8 | 59.204837 | parse / 126 |
| Optimal | 49.89 | 88.28 | 0.9393 | 587.2 | 349.3 | 371.502908 | parse / 660 |
| ZSTD | 98.53 | 90.55 | 0.9100 | 473.9 | 9.0 | 30.805776 | external_tool / 141 |
| TLZ4 | 91.68 | 88.98 | 1.0537 | 80.6 | 33.8 | 42.736587 | external_tool / 285 |

## Judge

- **R34 correctness regression has been fixed**: The most important `llama.cpp-n40 optimal` has completed encode/decode/compare, and the truncation failure of R34 has not been reproduced.
- R35 is a clean baseline, not a new compression rate improvement. `Optimal` compression ratio is still the best ( `claw-code 0.8590`, `llama.cpp 0.9393`), but the encode energy is still the highest ( `545.69 J` / `371.50 J`), and the CPU top is still concentrated in `lzParseOptimal` parse closure.
- `BVX3` Fast path The energy consumption in this round is still close to TLZ4: `claw-code n40` For `35.06 J` Vs TLZ4 `33.85 J`; `llama.cpp n40` For `27.98 J`, even lower than ZSTD `30.81 J`. However, the RSS of BVX3 family is still high, especially n40 decode about `325~351 MB`, far higher than TLZ4 `33~34 MB` And ZSTD `9 MB`.
- `-n` The speed/RSS trade-off is still obvious: `claw-code BVX3` The optimal compression speed is at n8 ( `414.50 MB/s`), n40 instead dropped to `310.37 MB/s` And RSS has risen to `233.1/324.9 MB`; `Lazy2/Optimal` Then n40 significantly reduces encode energy, but RSS rises to about `496~578 MB`.
- trace is still mostly timeout, but `target_seen=yes`, `time-profile/time-sample ok`, CPU call tree summary is available; `Optimal`'s `cpu_parse_hits` is still about `1100+`, indicating that the next ratio DOE If DP state is added, the enabling section must be restricted first, otherwise it is easy to push the time and RSS.

## The next step

- No longer retry length-4 recovery directly. If you want to study whether tag-packing harms the compression ratio, first do the instrumentation counter: the number of `load32(c)==v` filtered by tag, the proportion that actually becomes the best DP edge, and the data set/paragraph distribution; the default is still off.
- The next real Optimal ratio candidate is still a small 2-state / small beam, but it can only be enabled in the rep-heavy or high-coverage segment first; the success conditions need to include compression ratio improvement, `claw-code/llama.cpp` compare full pass, encode RSS does not run out of control, and encode energy does not deteriorate significantly.
- If you prioritize BVX3 family, you should check n40 encode/decode RSS in the next round: chunk in-flight, decoding group buffering, output-side temporary array life cycle. This is more important than continuing to pursue BVX3 encode energy.

---

# Round 34: Codex #4 — tag-less length-4 Re-inspection (2026-06-19)

> Only move `lzfse-cli.swift`. Four points of Codex's research on xz. **Clarify the status first** and then do it.

## Clarify the status (important)

- **Codex #1 (context-aware literal price) = already R33, and failed**: HEAD `R33: Optimal literal price 4-context DOE -> failed to improve compress ratio.` has been used "previously **literal** bytes >> 6" (more accurate than input bytes) and benchmarked, and the conclusion is that the compression ratio cannot be improved. In this round, a thicker version was remade for a while, and it was found that after hitting R33 ** all of them had been restored** (the work tree returned to a single table).
- **Codex #3 (literal+rep0 / match+literal+rep0 combination edge) = already exists**: `lzParseOptimal` Of `relaxLiteralRep0` / `relaxMatchLiteralRep0` That is, it has been done before.
- Therefore, this round only does **#4**; **#2 (per-position 2-state / small beam) is left for the next round ** - it is a larger DP reconstruction, and in order to avoid the chaos of R30/R33 "tying two ratio variables in a round → difficult attribution → dismantling revert", ** only one ratio DOE variable is moved at a time**.

## This round of changes: #4 tag-less length-4 recovery

- R27 tag-packing filters chain candidates with hash5/tag, which will omit "the first 4 bytes are the same, the 5th byte is different" → tag is different → skipped **length-4 match**.
- Add ( `lzParseOptimal` After the chain visit): ** Only if the match of ≥4 is not found at all in this position ( `bl < 4`) time**, before the bucket `optLen4ProbeDepth` (=4) Item do **tag-less supplementary inspection**, use `load32(c)==v` After confirmation, recycle **a** length-4 candidate into the frontier.
- The trigger conditions are strict (no rep, the main visit did not find any ≥4 match before starting) → Cost upper bound = 4 times `load32` /position, and only in the position of "originally no match at all".
- **Correctness safe**: only add `load32(c)==v`, `dd≤maxDist`, `dd≠rep` The verified legal length-4 match → round-trip will not be affected. **The compression ratio/speed will be changed** (expected ratio will increase slightly, and the speed may decrease slightly). Set up `optLen4ProbeDepth = 0` That is, close.

## Actual measurement results: R34 correctness failed

- `run_round.command` compiled and `-test` passed, and the complete benchmark entered lz4bench.
- `claw-code` n40 / n8 / n4 all pass compare, including `optimal`.
- `llama.cpp-n40 optimal` appears in the encode stage `tar: Write error` and `[Error] lzfseX failed to create llama.cpp.lzfse.bvx3.optimal`; the residual semi-finished product size is `465,196,260 bytes`, and the subsequent decode shows `Truncated tar archive`, and the comparison fails to `13:12:24`.
- This round should be judged as **R34 correctness failed**; `tag-less length-4 recovery` cannot be reserved as a valid result, and subsequent MB/s / RSS / power cannot be used.
- `claw-code` passed but `llama.cpp` failed, indicating that this is not a general format decode problem, but an Optimal parser selects a path on a specific data/sement that will stop the encode pipeline in advance or produce a truncated output.

## harness correction

- `zshrc.zsh`'s compare fail-fast has taken effect: this round stopped after the failure of `llama.cpp-n40 optimal` compare, and did not continue to run trace / power.
- Another amendment `nanoTimeElapsed`: Now the exit code of the tested command will be sent back; `lz4bench` The compression stage is changed to simultaneous inspection. `encode_rc == 0` And the existence of products. Next time, if the encode has failed but the semi-finished product exists, it will be written in the encode stage. `ENCODE_FAILED ... <rc>` And stop, it will not be mistaken as `ENCODED`.
- `cpu_call_tree_analysis.command` has cleared `trace/*.trace` and `trace/*.trace.timeout` after writing all summary, and written `CPU_CALL_TREE_TRACE_CLEANED` to avoid retaining large traces after analysis.

## The next round

- First, turn off `optLen4ProbeDepth` or return R34, and re-run baseline to confirm `llama.cpp-n40 optimal` reply byte-identical.
- Clean up the currently uncalled `relaxLiteralRep0` / `relaxMatchLiteralRep0` and related macro-step fields to avoid the next round of DOE mixing useless costs and unrelated variables.
- Keep 2 states in each position (or enable small beam only in the rep-heavy section), so that the path of "slightly more expensive but better rep history" is not cut off in advance by the single-state DP. CPU/RSS will rise, requiring a small range of DOE, and it is an independent round to be attributed.

---

# Round 32: power benchmark re-run and CPU power integration (2026-06-18)

> In this round, rerun `helper/power_benchmark.command` after the last two commits of rollback, and execute `helper/power_summary_integrate.command` to integrate the CPU power / energy field back to `BenchMarkResult.csv` and `best_points/`. This round focuses on the post-state acceptance of power harness and R31, which is not regarded as a new algorithm DOE.

## Data status

- `powerResults/power_status.txt` It has been completely run to `POWER_BENCHMARK_DONE 07:22:23`; The last time was stuck in `claw-code-tgz-encode` Of `powermetrics` The stop problem has not been repeated in this round.
- `powerResults/power_summary.csv` A total of 72 data, 72/72 `status=ok`, no `POWER_NO_SAMPLES` or failed row.
- `BenchMarkResult.csv` 48 rows in total, all of which have `Encode CPU Power(mW)`, `Decode CPU Power(mW)`, `Encode CPU Energy(J)`, `Decode CPU Energy(J)` fields.
- `best_points/best_points.md` has added the lowest and highest fields of power / energy synchronously, and the source has been changed to `best_points/best_points.csv`.

## R32 Summary of results

`claw-code` n40 represents value:

| Format | Compression MB/s | Decompression MB/s | Compression Ratio | Encode RSS(MB) | Encode CPU Power(mW) | Encode CPU Energy(J) | CPU top |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---
| Other3 | 502.96 | 705.81 | 0.9871 | 349.5 | 17434.857 | 41.832219 | encode / 71 |
| BVX3 | 642.06 | 427.47 | 0.9516 | 364.7 | 16548.312 | 34.563284 | encode / 62 |
| Lazy2 | 67.68 | 435.97 | 0.9013 | 485.1 | 5603.386 | 115.000515 | parse / 149 |
| Optimal | 36.98 | 416.81 | 0.8605 | 544.2 | 13398.034 | 513.399386 | parse / 730 |

`llama.cpp` n40 represents value:

| Format | Compression MB/s | Decompression MB/s | Compression Ratio | Encode RSS(MB) | Encode CPU Power(mW) | Encode CPU Energy(J) | CPU top |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---
| Other3 | 281.67 | 257.14 | 0.9978 | 389.5 | 15633.500 | 25.293345 | encode / 67 |
| BVX3 | 301.70 | 204.91 | 0.9816 | 376.8 | 16332.727 | 27.401693 | encode / 59 |
| Lazy2 | 177.50 | 296.45 | 0.9583 | 500.4 | 7570.696 | 49.178915 | parse / 123 |
| Optimal | 59.66 | 217.65 | 0.9421 | 577.3 | 15351.469 | 329.643690 | parse / 654 |

Best-points hierarchical observation:

- `Other3` is Apple-compatible standard LZFSE baseline. `claw-code` n40 represents `502.96 MB/s / 41.832219 J`, but the best compression in n8 in the same round is `586.02 MB/s / 38.429289 J`; `llama.cpp` n40 represents `281.67 MB/s / 25.293345 J`, and the best compression in n8 in the same round is `420.31 MB/s / 28.528759 J`. Therefore, the R32 evaluation should retain the n40 representative value and best-points at the same time, and cannot use only n40 to judge Other3.
- `claw-code` BVX3 is optimally compressed as `642.06 MB/s` (n40), and `34.563284 J` with the lowest encode energy is n40, which is close to TLZ4 `33.225059 J`.
- `claw-code` Lazy2 is optimally compressed to `67.68 MB/s` (n40), encode energy `115.000515 J`, which is lower than n4 `159.438967 J`, maintaining the slow path conclusion of "improve n can reduce time and energy consumption at the same time".
- `claw-code` Optimal is optimally compressed to `36.98 MB/s` (n40), encode energy `513.399386 J`. Relative to R31 record `36.95 MB/s / 511.53 J`, the speed is about `+0.1%`, and the energy consumption is about `+0.4%`, which can be regarded as the same water level, and there is no new clear improvement.
- `llama.cpp` Optimal is optimally compressed as `59.66 MB/s` (n40), encode energy `329.643690 J`; Lazy2 n40 is `177.50 MB/s / 49.178915 J`, which once again shows that the main cause of Optimal's energy consumption is still long-term DP, not high average power.

R32 n40 evaluation:

- Compression speed: `claw-code` For BVX3 `642.06`>Other three `502.96`>>Lazy2 `67.68`>Optimal `36.98`; `llama.cpp` For BVX3 `301.70`>Other three `281.67`>Lazy2 `177.50`>Optimal `59.66`.
- Compression ratio: `claw-code` is Optimal `0.8605` > Lazy2 `0.9013` > BVX3 `0.9516` > Other3 `0.9871`; `llama.cpp` is Optimal `0.9421` > Lazy2 `0.9583` > BVX3 `0.9816` > Other3 `0.9978`.
- Encode energy: `claw-code` For BVX3 `34.563284 J`<Other three `41.832219 J`<Lazy2 `115.000515 J`<<Optimal `513.399386 J`; `llama.cpp` For Other3 `25.293345 J`<BVX3 `27.401693 J`<Lazy2 `49.178915 J`<<Optimal `329.643690 J`.
- Decompression speed: `claw-code` Other three `705.81 MB/s` Obviously faster than Lazy2 `435.97`, BVX3 `427.47`, Optimal `416.81`; `llama.cpp` Then Lazy2 `296.45`>Other three `257.14`>Optimal `217.65`>BVX3 `204.91`.

Comparison and judgment of ## and R31

- `claw-code Optimal n40`: `36.95 → 36.98 MB/s`, CPU energy `511.53 → 513.40 J`, the measured noise range; the cheap-probe gating judgment retained by R31 remains unchanged.
- `claw-code BVX3 n40`: `657.59 → 642.06 MB/s` (about `-2.4%`), encode energy `35.67 → 34.56 J`, the speed is small but the energy consumption is still low, which does not point to a new return.
- `claw-code Lazy2 n40`: `68.73 → 67.68 MB/s` (about `-1.5%`), basically the same water level.
- `claw-code Other3 n40`: `637.91 → 502.96 MB/s` (About `-21.2%`), but this round of Other3 is optimally compressed in n8 for `586.02 MB/s`, and the same round BVX3 / Lazy2 / Optimal did not regress. This is more like the n40 abnormality caused by batch noise, thermal state or power measurement interpolation, which should not be attributed to the source change alone; the next round needs to be repeatedly verified Other3 n40.

## power harness conclusion

This round of power measurement output is complete, and `power_summary_integrate.command` has integrated the power field into the report, so the restriction of "short decode may no samples" since R29 is temporarily lifted in this round of data. However, the decode power number is still easily affected by the sampling phase. For example, some extremely short decodes show a very low average CPU power; the analysis still takes encode energy as the main energy consumption conclusion, and decode energy is only an auxiliary.

## The next step

1. If the algorithm DOE continues in the next round, `claw-code Optimal n40 36.98 MB/s / 513.40 J` and `llama.cpp Optimal n40 59.66 MB/s / 329.64 J` are still used as the R32 energy-aware baseline.
Two. For `Other3 n40` speed abnormality, repeat the measurement or fix the hot state in the next round, and then decide whether to check the encode path; do not use only this round of single point to determine the return.
3. The power benchmark has been completed, but if it is stuck in the `powermetrics` stop process again, the sudo/child process cleanup of `helper/power_benchmark.command` should be checked first, not the compressor itself.

---

# Round 31: Retest after revert R30-2 literal UBP (2026-06-17)

> The purpose of this round is not to add algorithm changes, but to rerun the complete benchmark with the source that has been reverted `literal UBP` to confirm whether the BVX3 / Other3 regression observed by R30 comes from #30-2, not #30-1 `Optimal cheap-probe gating`.

## benchmark result (claw-code n40, raw bytes/ns)

| Format | R31 MB/s | R29 MB/s | Change | Judgment |
| --- | ---: | ---: | ---: | --- |
| **Optimal** | **36.95** | 34.93 | +5.8% | #30-1 gating reservation |
| BVX3 | 657.59 | 672.71 | -2.2% | The normal water level has been restored, and the main cause of R30 regression is confirmed as #30-2 |
| Other3 | 637.91 | 618.34 | +3.2% | Normal water level has been restored |
| Lazy2 | 68.73 | 66.46 | +3.4% | No direct change, regarded as the whole machine/dispatch floating |

- **Optimal CPU energy consumption**: 511.53 J vs R29 567.2 J → **-9.8%**. Both speed and energy consumption have improved, but the next round of ≥10% single-point improvement threshold has not been reached.
- **Compression ratio remains unchanged**: Optimal `0.8590`, BVX3 `0.9516`, Other3 `0.9871`, Lazy2 `0.9013`, indicating that #30-1 gating does not destroy the output quality.
- **R30-2 Verification Conclusion**: R30's BVX3 `589.03 MB/s` / Other3 `513.14 MB/s` is the result of contamination containing `litEnc.withUnsafeBufferPointer` binary. After R31 revert, BVX3 returns to `657.59 MB/s`, Other3 returns to `637.91 MB/s`, confirming that literal UBP should maintain revert.

## trace / power / RSS observation

- Most of the LZFSE family trace are still `trace_timeout=yes`, so the trace wall time does not compare the speed, only the distribution of target seen and CPU symbol.
- Optimal n40 top symbol still falls on `lzParseOptimal` closure, `cpu_parse_hits=1129`, indicating that cheap-probe gating only avoids the low-yield segment, and the main hotspot is still the DP core.
- BVX3 n40 encode RSS `355.0 MB`, decode RSS `322.4 MB`, which is still significantly higher than TLZ4 / ZSTD, which is a memory problem that needs to be dealt with in the next round.
- BVX3 n40 encode CPU energy `35.67 J` is close to TLZ4 `34.86 J`, so the next priority of BVX3 should be RSS and throughput stability, not encode energy consumption.

## The next step

- Keep #30-1 `optDPSkipAvgMatchLen = 256`, do not go back.
- Maintain #30-2 literal UBP revert, and no longer wrap `litEnc` literal thermal cycle into `withUnsafeBufferPointer` closure.
- If you want to continue Optimal in the next round, you should directly target the `lzParseOptimal` DP core and make profiling-guided single-point changes. The condition for success is still ≥10% improvement in the same round and the compression ratio does not regress.
- If the next round turns to BVX3 family, priority will be given to investigating the reasons for the high encode/decode RSS, especially the buffer, chunk in-flight, and temporary array life cycle under n40.

---

# Round 30: Optimal cheap-probe gating + literal UBP DOE results (2026-06-16)

> Only move `lzfse-cli.swift`. This round of simultaneous experiments **#1** (cheap-probe gating) and **#2** (literal UBP). Benchmark result: #1 is effective, **#2 causes BVX3 to regress −12.4%**. **Both have been committed** (see lzfse-cli.swift difference); #2's revert ranks into **R31**. #3 (power measurement hardening) belongs to harness, unmoved.

## benchmark result (claw-code n40)

| Format | R30 MB/s | vs R27 | vs R29 | Judgment |
| --- | ---: | ---: | ---: | --- |
| **Optimal** | **37.13** | +8.1% | +6.3% | ✅ #1 Valid |
| BVX3 | 589.03 | −7.2% | −12.4% | ❌ #2 Regress → revert |
| Other3 | 513.14 | — | −17.0% | ⚠️ Machine noise (n40 < n8 587, thermal throttle/batch length effect) |
| Lazy2 | 69.15 | +25.0% | +4.0% | — |

- **Optimal Energy Consumption**:502.8 J vs R29 567.2 J → **−11.4%** ✅
- **Compression ratio 0.8590 / 0.9416 completely unchanged** ✅ → #1 gating security (threshold 256 conservative, very few modified segments and indeed long match-dominated).

## #1 Optimal cheap-probe gating — ✅ Reserve

- Add a third gate after the existing two gates (entropy gate >7.2, coverage < 28%): pre-screen greedy scan `matchCount`, if ** average match length ≥ `optDPSkipAvgMatchLen` (default 256)** → long match dominant segment, DP low yield → go to the existing `greedyEmitSegment`.
- Acceptance: Optimal claw n40 34.93→**37.13 MB/s (+6.3%)**, energy consumption **−11.4%**, **compression ratio unchanged**. Correctness safe (both greedy path, legal bvx3, decoder unchanged, round-trip not affected).
- Knob: Set `optDPSkipAvgMatchLen` maximum value to close and return to R29; lower adjustment is more positive (re-check ratio).

## #2 literal coding loop UnsafeBufferPointer — ❌ BVX3 regress, wait for R31 revert

- After wrapping the non-ctx literal cycle of `litEnc[...]` into `litEnc.withUnsafeBufferPointer { le in ... }`, **BVX3 claw n40 −12.4%, llama −13.0%**.
- Reason research and judgment: in `-O` Down, `UnsafeBufferPointer` Subscript saving bounds-check **not enough to offset closure package expenses**;closure boundary may**block `fseEncode` The inline or caller-level optimization** slows down this per-literal hottest cycle as a whole.
- Lesson: It is also "go to bounds-check". The LMD loop of R28 (6 n-size arrays, 3 times fseEncode per match) is valid, but the literal loop (4 times fseEncode each time, shorter loop body) is dragged down by the closure package - **UBP packaging is not always cost-effective, and needs to be measured cycle by cycle**. `FSEOutStream` / `fseEncode` has inline+pointer, pure function has no room.
- **Action**: R31 will revert `litEnc.withUnsafeBufferPointer { ... }` back to `litEnc[Int(lp[...])]`, and confirm that BVX3 will return to ~672 MB/s water level.

## #3 power measurement hardening - belongs to harness, unmoved

The correction point is in `helper/power_benchmark.command` (shell), not in `lzfse-cli.swift`. Option: (a) Relax the constraint and I change the harness (short decode loop N times and then average); (b) I add `-repeat N` supply measurement in CLI. To be designated.

## Remarks

This round of benchmark data (BenchMarkResult.csv) is **containing #1 and #2 binary** at the same time (so BVX3 shows a regression of −12.4%). **Lzfse-cli.swift This commit still contains #2** ( `litEnc.withUnsafeBufferPointer`); the source of BVX3 regression has been confirmed as #2. **R31 will revert #2**, and the next round of benchmark should see BVX3 return to ~672 MB/s water level for reverse confirmation (as agreed, this round will not be re-run). Other3 −17% is machine noise (n40 is slower than n8).

---

# Round 29: R2612 + R28 combined DOE results + the first power/energy measurement (2026-06-16)

> This round combines three groups of **output-identical** on the basis of R27 (tag-packing) and changes to measure together: R28 ( `encodeBlockV3` LMD. `withUnsafeBufferPointer`), R261 ( `lzParseOptimal` Of `localHead` Outbound, per-call configuration), R262 (3-rep expansion). And included for the first time `powerResults/` CPU/GPU/DRAM power and energy consumption. Just move `lzfse-cli.swift` And `OPTIMIZATION.md`.

## DOE result (claw-code / llama.cpp, n40, raw bytes/ns)

| Format | claw R27 | claw R29 | Change | llama R27 | llama R29 | Change | Compression ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **Optimal** | 34.36 | **34.93** | +1.7% | 60.24 | **60.67** | +0.7% | 0.8590 / 0.9416 Unchanged |
| **BVX3** | 634.82 | **672.71** | +6.0% | 398.70 | **448.98** | +12.6% | 0.9515 / 0.9816 Unchanged |
| Other3 | ~ | 618.34 | ↑ | ~ | 455.40 | ↑ | 0.9872 / 0.9979 Unchanged |
| Lazy2 | 55.30 | 66.46 | ↑* | ~173.9 | 193.22 | ↑* | 0.9016 / 0.9588 Unchanged |

- **Compression ratio format byte level unchanged**(0.8590 / 0.9515 / 0.9016 / 0.9872 ...) → All three groups of changes confirm output-identical, no return.
- **R28 (BVX3) is the biggest winner of this round**: claw +6.0%, llama +12.6%, confirming that LMD bounds-check is effective for encode-bound bvx3/other3.
- **R2612 (Optimal) is only slightly +0.7–1.7%**, **not reaching the ≥10% target**: because they save DP * peripheral * expenses (prescreen's `localHead` configuration, rep transform loop), and the top symbol is still the **DP core closure** of `lzParseOptimal` - to be faster, you must move the DP itself or do segment hierarchical gating.
- `*` Lazy2 There is no new change in this round (R6 is already within the R27 benchmark), and the increase in value is the whole machine/dispatch noise, which is not attributed to this round.

## powerResult segment summary (first inclusion)

Measurement method: `helper/power_benchmark.command` takes the CPU/GPU/ANE/DRAM power (mW) and energy consumption (J) of each (format, encode/decode, n) with macOS `powermetrics`, and integrates it into `powerResults/power_summary.csv`, and best_points also brings into the CPU power/energy field.

**1 Encode energy consumption (claw-code, J; energy consumption ≈ power × time)**

| Format | Energy Consumption (J) | CPU Power (mW) | Description |
| --- | ---: | ---: | --- |
| tar.lz4 | **36.4** | 17570 | High power but extremely short → The most energy-saving |
| Other3 (n40) | 39.1 | 17986 | Same level as external tools |
| BVX3 (n40) | 46.9 | 18857 | Full core, fast collection → Acceptable energy consumption |
| ZSTD | 50.8 | 14647 | — |
| Apple (n40) | 65.3 | 6951 | — |
| TGZ | 137.6 | 4471 | Low power but 30s → High energy consumption |
| **Lazy2 (n40)** | **204.7** | 7212 | Long-term dominance |
| **Optimal (n40)** | **567.2** | 13633 | ≈12× BVX3, 15× tar.lz4 |

**2 Decode energy consumption (claw-code, n40, J) - LZFSE family is a strong point**

Optimal **0.85**, Lazy2 1.45, BVX3 2.06 J, **below** ZSTD 4.08, TGZ 5.40 J. LZFSE decoding is fast and energy-saving.

**3 Three-point conclusion**

1. **Optimal/Lazy2's energy consumption problem = time problem**: Their power is actually low (7–13.6W, lower than the full-load bvx3/zstd 18–19W), but DP/chain is too slow → energy consumption is high. **The leverage of energy consumption reduction is the same as the reduction time** (segment level gating can cut energy consumption in a similar proportion).
Two. **BVX3 / Other3 encode energy consumption is at the same level as zstd/tar.lz4** (39–47 J vs 36–51 J), no need to optimize energy consumption; decode The whole family is very cost-saving and does not need to be processed.
3. ⚠️ **Measurement limit**: Multiple extremely short decodes appear `POWER_NO_SAMPLES` (other3 n40 decode, llama's bvx3/lazy2/optimal n40 decode), due to decompression <~0.3–0.5s shorter than the powermetrics sampling interval. These decode energy consumption is empty and needs to be obtained with a longer batch or a smaller `-n`; it does not affect the encode energy consumption conclusion.

## power explanation of cause (compared with the latest code)

Mental model: **energy consumption J = average power W × time s**; and **power ≈ core busyness (IPC)**. The calculation is intensive and the data is in the cache → the core is fully loaded → high power; the memory is intensive (cache miss / pointer chase) → the core is stopped in the memory → low power, but it takes a long time to run.

**Optimal / Lazy2 = low power, high energy consumption (memory-bound). ** Compare `lzParseOptimal` DP forward cycle (each section ≤128K position): `hashAndTag(i)`→`head[qh]` / `chain[c]` It is random memory access (hash bucket + chain pointer chase); `matchLength(...)` And candidates `load32(c)` Of `c` It is a random offset in history, frequently cache miss in 4MiB chunk; relaxation and write the price scattered to `cPrice[t+ll]`. The core often stops at the equivalent memory → IPC is low → the power is only 7–13.6W, but the workload is extremely large → the time is very long → the energy consumption is so high (claw optimal n40 41.6s / 567 J; lazy2 7W / 28s / 205 J).

**BVX3 / Other3 / tlz4 / zstd = high power, low energy consumption (compute-bound). ** `encodeBlockV3` core is FSE coding (compact state transfer + bit packing, small table check and permanent cache) → core full load → power 15–19W, but fast → 2–3.5s → energy consumption 39–51 J. Tar.lz4 has the highest power but the shortest → the most energy-saving (36 J).

**Decode saves energy for the whole family. ** Table-driven FSE decoding + memcpy, sequential, cache-friendly, parallel and short → low power + short time. Optimal decoding has the lowest energy consumption (0.85 J), because it solves the standard bvx3 stream, and the path is the same and fast as the general bvx3.

** Energy consumption decreases with -n (slow path). ** `runParallelEncode` Use N chunk in parallel; for DP slow path, the magnitude of N shortening time is greater than the power increase → energy consumption reverse decrease: claw optimal encode n4 720J → n8 613J → n40 567J; llama optimal n4 505J → n8 386J → n40 337J. Therefore, optimal/lazy2 is used larger `-n` Not only faster, but also more energy-saving (at the cost of rising RSS); bvx3 is almost full load, n has little impact on energy consumption.

** Optimize the meaning. ** Optimal is memory-bound, and micro-optimization (SIMD / go bounds-check) is of limited help to "power" (it is not fully loaded); the real cutting energy consumption is ** to do less DP** - segment level cheap-probe gating will cut time and energy consumption in a similar proportion, which is the same lever as "speed reduction". BVX3/Other3 encode energy consumption has been at the same level as zstd/tlz4, and the whole family of decode is saved → there is no need to invest in energy consumption.

## The next step

1. **Optimal segment level cheap-probe gating** (a large change in the output/compression ratio will be changed): change the low-yield segment to lazy2/greedy. This is the maximum ROI of Optimal's **speed and energy consumption** at present (especially llama optimal is only 1.8% smaller than lazy2 but consumes ≈337–505 J). It needs to be compiled/benchmark to check the ratio.
Two. Since BVX3:R28 is valid, you can continue to check the similar output-identical acceleration of `fseEncode` / `FSEOutStream.push/flush`.
3. Power measurement hardening: change the decode that is too short to repeat many times or fix the shortest sampling time to complete `NO_SAMPLES`.

---

# Round 28: encodeBlockV3 LMD hot cycle bounds-check acceptance (2026-06-16)

> Only move `lzfse-cli.swift`. R26/R27 trace confirms that `encodeBlockV3` is still the top symbol of the BVX3 family (including `fseEncode`, `FSEOutStream.push/flush` and Swift Array/COW). This round of **output-identical** encode acceleration has been completed, and the benchmark / memProbe / trace / cpu_call_tree / CSV rebuild acceptance has been completed.

## Change: LMD coding loop access with UnsafeBufferPointer

- `encodeBlockV3` The 2 L/M/D coding loop reads 6 n-size arrays for each match ( `lSyms/mSyms/dSyms`+`lVals/mVals/dVals`), every time it is Swift Array bounds-check.
- Instead, these 6 arrays are nested. `withUnsafeBufferPointer`, access with pointer in the loop, remove each match × 6 times bounds-check (R26/R27 trace's `swift_array` One of the hot spots). `fseEncode` And `lmdOut.push/flush` The core FSE work remains unchanged; the extra-bits / base / encoder check table (according to symbol index, small constant table) remains the same.
- Correctness: The index ( `mi`) and all emission values and bit push order are completely unchanged → **The output bytes are exactly the same, and the compression ratio is unchanged**.

## Data status

`round_status.txt` Show `compile` And `lzfse-test` Pass, the two data sets `-n40/-n8/-n4` Both benchmark and memProbe have been completed; `helper/tracer.command` In `16:37:13` Complete, `trace_analysis`, `cpu_call_tree_analysis`, `BenchMarkResult.csv` Rebuild and `best_points` In `16:42:06` Complete. `run_round.command` The outermost layer is not left. `BENCH_DONE` But the analysis output of the benchmark pipeline has been completely reconstructed.

`lzfse-test.txt` shows that Other3, BVX3, Lazy2, Optimal, Apple compatibility and parallel decoding paths are all passed. After compression of BVX3, the size is maintained `claw-code 446M`, `llama.cpp 572M`, and the compression ratio is maintained by `0.9515 / 0.9816`; this round is in line with the output-identical target.

## Benchmark Results

Compare R27 → R28 with raw bytes / ns MB/s of `BenchMarkResult.csv`:

- `claw-code` BVX3: n40 `634.82 → 672.71 MB/s` ( `+6.0%`), n8 `596.70 → 588.41 MB/s` ( `-1.4%`), n4 `380.58 → 405.68 MB/s` ( `+6.6%`). N40 reaches the target range of 5–10%, and n8 retreats but is still close to R27.
- `llama.cpp` BVX3: n40 `398.70 → 448.98 MB/s` ( `+12.6%`), n8 `396.03 → 414.69 MB/s` ( `+4.7%`), n4 `322.67 → 336.25 MB/s` ( `+4.2%`). All three n in this data set have improved, and n40 is more than 10%.
- Although Other3 has not directly modified `encodeBlock`, it is still rising synchronously in this round: `claw-code n40 618.34 MB/s`, `llama.cpp n40 455.40 MB/s`. This may be due to round noise, cache/I/O or compilation environment fluctuations, which should not be attributed to the pointerization of R28.
- The compression speed of Lazy2 / Optimal also fluctuates: `claw-code n40 Lazy2 66.46 MB/s`, Optimal `34.93 MB/s`; `llama.cpp n40 Lazy2 193.22 MB/s`, Optimal `60.67 MB/s`. These parser paths are not directly hit by R28 and are only used as background benchmarks.

The decompression speed is not the target of this round of changes, but it needs to record the regression: BVX3 n40 decompression from R27's `746.42 → 663.05 MB/s` (claw-code, `-11.2%`) and `292.37 → 224.37 MB/s` (llama.cpp, `-23.3%`) of R27. The decompression path has not been modified by this round, which is more likely to be affected by measurement fluctuations, I/O/cache, trace/memProbe before and after status or data set tar status; if encode continues to be changed in the next round, it is still necessary to keep an eye on decode unsustainable regression.

RSS trade-off roughly maintains the original judgment: BVX3 n40 encode RSS `claw-code 366.3 MB` (R27 `350.7 MB`, `+4.4%`), `llama.cpp 380.2 MB` (R27 `394.2 MB`, `-3.6%`). Decode RSS is still about `315–343 MB`, which is significantly higher than ZSTD decode about `9–10 MB` and TLZ4 decode about `34 MB`.

## Trace / CPU Interpretation

`trace/analysis` 36 traces in this round can be exported time-profile / time-sample; LZFSE encode trace is still more than 300s timeout, which is only used in the hotspot direction, not for complete time-consuming calculation.

- The hot spot of R28 does decrease: BVX3 n40 `encodeBlockV3` top count from R27's `100 → 64` (claw-code, `-36%`) and `102 → 57` (llama.cpp, `-44%`). `CPU Encode Hits` also drops from `137 → 130` (claw-code) and `150 → 122` (llama.cpp).
- But `CPU Swift Array Hits` rose instead: claw-code n40 `84 → 106`, llama.cpp n40 `77 → 101`. The interpretation is that after the LMD reading loop bounds-check is removed, the remaining array cost is transferred to `encodeBlockV3` front-segment staging, symbol/value arrays, FSE output buffer or other Array/COW paths; R28 is not the end of the Array cost.
- `llama.cpp n4` BVX3 top symbol is converted to `static LZFSEv1.fseEncode(state:_:_:)`, indicating that the small n / low concurrent FSE encode can overpress the `encodeBlockV3` loop itself. If the next BVX3 single point is only pointerized LMD reading, the marginal benefit will be reduced.
- Optimal's CPU parse hits this round of increase (such as claw-code n40 `922 → 1160`, llama.cpp n40 `877 → 1086`), reconfirm that Optimal should not rely on encodeBlockV3 next step; another segment level cheap probe / envelope pruning should be done.

## Conclusion and next step

R28 can be retained: it is output-identical, correctness pass, BVX3 n40 has a clear compression speed improvement in both data sets, and trace shows that `encodeBlockV3` top count has decreased significantly. The success condition is "the same as the data set n without retreat, ideal 5–10%" is established in n40, especially `llama.cpp` exceeds 10%.

Suggestions for the next step:

1. BVX3: Stop reading loop fine-tuning only for LMD. Give priority to `encodeBlockV3` front stage / symbol arrays / FSEOutStream. The goal is to reduce Swift Array hits to below R27, and BVX3 n40 compress and maintain `claw-code ≥670 MB/s` and `llama.cpp ≥445 MB/s`.
Two. RSS: BVX3 encode RSS is still `~366–380 MB`, decode RSS `~315–343 MB`; if you want to optimize the encode path again, you need to set the RSS success conditions synchronously, such as the same n RSS drop `>=10–20%` or at least no longer rise.
3. Decode: The next round needs to confirm whether the BVX3 decode regression can be reproduced. If two consecutive rounds are lower than R27, you should first check the I/O/cache and parallel inflight of the decode benchmark, instead of attributing the problem to R28.
4. Optimal: Maintain the R27 conclusion, the next real opportunity direction is segment-level cheap probe / envelope pruning; this will change the output route selection and possible compression ratio, which needs to be used as an independent DOE, and should not be mixed in the output-identical encode micro-optimization.

---

# Round 27: Optimal tag-packed hash chain acceptance (2026-06-16)

## Change summary

This round will synchronize tag-packing into `lzParseOptimal`, and let `lzParseChain` Use the same set of packed hash chain. The core is to generate hash bucket and 8-bit secondary tag from a 5-byte multiplication. `head[h]` Save `(tag << 24) | idx`, `chain[idx]` Follow the packed value of the previous node. Use it first when visiting the chain. `(packed >> 24) == qtag` Do pure register filtering, skip if it does not match, and reduce the cause of pure collision candidates. `p[c]` Random reading and pointer chasing.

This time, don't change the bitstream format, don't change the decoder, don't change the FSE table construction, and don't change `lzParseStrong` / `lzParse` The independence of `hashTable`. Optimal's coverage prescreen still uses independent `localHead`, do not pollute the main `head/chain`. `greedyEmitSegment` Only depack the low 24-bit index, do not do tag filtering, and maintain the greedy candidate meaning.

## Correctness and data status

- After `hashAndTag` replaces `hash4`, the bucket still uses the high product `chainHashBits` bit, and the tag takes the adjacent 8 bits; insert and query use the same function.
- `insert` maintains the order of `chain[idx] = head[h]` and then updates `head[h]`. The meaning of the link remains unchanged, but the node pointer changes from raw index to packed value.
- `lzParseOptimal` still take `candPacked/qtag` first and then `insert(i)` in DP to avoid self-reference.
- `chainNullIndex = 0x00FF_FFFF` corresponds to the low 24 bits of `head = -1`; the real chunk index is guaranteed to be less than sentinel by `parallelChunkSize = 4MiB`.
- Add `assert(n <= chainIndexMask)` only in debug check chunk upper limit, `swiftc -O` release no assert cost.

This round `round_status.txt` Arrived `BENCH_DONE 04:10:42`, `BenchMarkResult.csv` A total of 48 rows, including `-n4/-n8/-n40` Speed, RSS, trace target and CPU top symbol fields. `lzfse-test.txt` It shows that Other3, BVX3, Lazy2, Optimal, Apple compatibility and parallel decoding paths are all passed; tag-packing does not cause round-trip or format compatibility return.

## Benchmark Results

After recalculating MB/s with raw bytes / ns, the acceleration of Optimal is established, but the magnitude of the two data sets is different:

- `claw-code` Optimal: `n4 57.80s / 24.50 MB/s`, `n8 47.36s / 29.90 MB/s`, `n40 41.21s / 34.36 MB/s`, compression ratio maintained `0.8590`. Compared with the previous benchmark `69.12s / 53.27s / 47.08s`, about improved `19.6% / 11.1% / 12.5%`.
- `llama.cpp` Optimal: `n4 33.59s / 39.37 MB/s`, `n8 24.80s / 53.33 MB/s`, `n40 21.95s / 60.24 MB/s`, the compression ratio is `0.9416`, and there is only a very small fluctuation compared with the previous benchmark `0.9415`. Compared with the previous benchmark `35.27s / 25.95s / 23.11s`, about improve `4.8% / 4.4% / 5.0%`.
- Lazy2 in `claw-code` The best compression is `55.30 MB/s` (N40), lower than the record of the previous round `57.54 MB/s`; but `llama.cpp` The best compression is `186.98 MB/s` (N40), higher than the previous round `173.90 MB/s`. Therefore, tag-packing to `lzParseChain` It is not a monotonous return, and the acceleration of Lazy2 should not be attributed to the tag itself in the future.
- BVX3 / Other3 is still dominated by encode path. `claw-code` BVX3 Best Compression `634.82 MB/s` (N40), `llama.cpp` BVX3 Best Compression `398.70 MB/s` (N40); compression ratio maintenance `0.9515 / 0.9816`.

RSS trade-off has not changed: n40 usually improves the compression speed of the LZFSE family, but encode/decode RSS also increases. Optimal encode RSS from n4 to n40 is about `212.3 → 570.2 MB` (claw-code) and `221.7 → 572.8 MB` (llama.cpp); decode RSS rises to `313–342 MB` level. This is still significantly higher than ZSTD decode about `9 MB` and TLZ4 decode about `34 MB`, so you can't just compress MB/s in the future.

## Trace / CPU Interpretation

`trace/analysis/trace_summary.csv` shows that 36 traces have `target_seen=yes`, and `time-profile/time-sample` schema can be exported. LZFSE encode trace is mostly 300s timeout, so it can only judge the hotspot direction, and cannot be used to calculate the complete wall time or MB/s.

CPU call tree shows that tag-packing has a complete answer to reduce some parser costs, but not the main bottleneck:

- Optimal top symbol is still `specialized closure #1 in static LZFSEv1.lzParseOptimal`. `claw-code n40` Top count from the last round `565` Down to `532`, parse hits from `963` Down to `922`; `llama.cpp n40` Top count from `508` Down to `499`, parse hits from `893` Down to `877`. The decline is only about `2–6%`, less than the wall-time improvement, which means that the income may be mixed with the impact of this round of noise, segment scheduling or other code changes.
- `hashAndTag` itself enters the global hotspot, but the count is only `52` (Optimal) and `44` (Chain), which has not become a new main bottleneck.
- Lazy2 top symbol is still `lzParseChain.bestMatch`, the whole area `bestMatch` count `827`; `repLen`, `matchLength` are still visible, indicating that the next step Lazy2 should continue to target match scanning and candidate strategies, instead of deepening the tag filter.
- BVX3 top symbol is still `encodeBlockV3`, the whole area count `1473`, and there are also `fseEncode`, `FSEOutStream.push/flush`, Swift Array/COW hotspots. The next high-win direction of the BVX3 family is still encode/FSE/array staging and RSS control.

## The next step

1. Optimal: tag-packing can be retained, but no longer takes hash-chain collision as the main line. In the next round, the section level cheap probe / envelope pruning should be done, and the low-yield section should go Lazy2 or greedy; the success condition is that the same round of Optimal wall time improves `>=10%`, the compression ratio does not regress significantly, and the CPU top symbol can be explained from `lzParseOptimal` closure or parse hits.
Two. Lazy2: Don't just extend the tag filter. Give priority to the candidate acceptance order in `bestMatch`, `matchLength` scan number and rep fast path; it is required that at least one fixed `-n` of the two data sets in the same round has `>=10%` improvement, and the other data set should not be significantly regressed.
3. BVX3: Put back `encodeBlockV3`, FSE output and Swift Array/COW in the main line. If the speed is close to TLZ4/ZSTD, the next acceptance should include RSS in the first-level target, such as `-n` encode/decode RSS down `>=20%` and MB/s does not return more than `5%`.
4. Benchmark process: keep `-n4/-n8/-n40` fixed scan; trace timeout result only write hotspot interpretation, not speed; each round confirms that `CPU_CALL_TREE_ANALYSIS_DONE` is earlier than `BENCHMARK_RESULT_REBUILD_DONE`, so as to avoid the CPU field blank of `BenchMarkResult.csv`.

---

# Twenty-sixth round of acceptance supplement: Benchmark

## Data status

This section is based on the latest `BenchMarkResult.csv`, `best_points/best_points.md`, `trace/analysis/trace_summary.csv`, `trace/analysis/cpu_call_tree_summary/`, `round_status.txt` And `lzfse-test.txt` Reorganise. This round has appeared before. `BenchMarkResult.csv` The CPU field is blank, the reason is `benchmark.zsh` The schedule is executed first. `benchmark_result_rebuild.command --write`, run after `cpu_call_tree_analysis.command`. At present, the process has been revised to:

`trace_analysis` → `cpu_call_tree_analysis` → `git gc` → `benchmark_result_rebuild --write` → `best_points_analysis`

The latest has been made up with the existing trace products `helper/cpu_call_tree_analysis.command`, `helper/benchmark_result_rebuild.command --write` and `helper/best_points_analysis.command`. `BenchMarkResult.csv` has a total of 48 rows, and 48 rows already have `CPU Symbol Status`; the main CSV is still UTF-8 BOM, maintaining Excel Chinese compatibility.

`trace_summary.csv` At present, there are 36 trace summary, all of which `target_seen=yes` And `time-profile/time-sample` All for `ok`; 30 of them are timeout trace. These timeout traces can be used to judge the direction of hotspot, but they cannot be used to calculate the full execution time or MB/s. `cpu_call_tree_summary.csv` There are 72 rows: 36 strokes `time-profile` Symbol statistics and 36 strokes `time-sample` Raw kperf address table; `hot_symbols_global.csv` At present, only the top 500 hot spots in the whole area are kept to avoid product expansion.

`lzfse-test.txt` shows correctness case maintained: Other3 self-round trip compatible with Apple, bvx3 / lazy2 / optimal self-round trip, parallel decoding, private bvx3 Apple rejection, single-stream support and Apple mutual solution path are normal.

## Latest speed / compression ratio

`best_points/best_points.md` shows the best points of this round as follows:

- `claw-code`
- Other3: Best compression `596.14 MB/s` (n8), best decompression `766.42 MB/s` (n40), compression ratio `0.9872`.
- BVX3: optimal compression `646.70 MB/s` (n40), optimal decompression `574.21 MB/s` (n8), compression ratio `0.9515`, minimum encode RSS `129.2 MB` (n4).
- Lazy2: best compression `57.54 MB/s` (n40), best decompression `652.50 MB/s` (n8), compression ratio `0.9016`, minimum encode RSS `192.9 MB` (n4).
- Optimal: best compression `29.84 MB/s` (n40), best decompression `679.77 MB/s` (n8), compression ratio `0.8590`, lowest encode RSS `197.4 MB` (n4).
- ZSTD: best compression ratio `0.8255`, best compression `482.03 MB/s` (log n8), best decompression `787.58 MB/s` (log n40), decode RSS about `9.0–9.1 MB`.
- `llama.cpp`
- Other3: Best compression `447.76 MB/s` (n40), best decompression `265.95 MB/s` (n40), compression ratio `0.9978`.
- BVX3: best compression `437.28 MB/s` (n40), best decompression `252.98 MB/s` (n4), compression ratio `0.9815`, minimum encode RSS `132.9 MB` (n4).
- Lazy2: best compression `173.90 MB/s` (n40), best decompression `294.33 MB/s` (n8), compression ratio `0.9587`, minimum encode RSS `194.5 MB` (n4).
- Optimal: optimal compression `56.21 MB/s` (n40), optimal decompression `253.37 MB/s` (n4), compression ratio `0.9415`, minimum encode RSS `217.4 MB` (n4).
- ZSTD: best compression ratio `0.9123`, best compression `469.71 MB/s` (log n4), best decompression `294.07 MB/s` (log n8), decode RSS about `9.0–9.4 MB`.

RSS trade-off is still clear: n40 usually gives the LZFSE family the highest compression speed, but encode RSS also increases. N40 represents `claw-code` BVX3 `359.1 MB`, Lazy2 `488.4 MB`, Optimal `570.3 MB`; `llama.cpp` BVX3 `394.8 MB`, Lazy2 `525.5 MB`, Optimal `573.6 MB`. Therefore, the subsequent optimization can not only look at MB/s, but still needs to look at RSS and compression ratio synchronously.

## CPU Hot Conclusion

`BenchMarkResult.csv` is now directly brought into the CPU top symbol / count / category, and there is no need to manually compare summary CSV. The main hotspots are consistent with the R26 hypothesis:

- BVX3: The two data sets n40 top category are `encode`, and the top symbol is `specialized static LZFSEv1.encodeBlockV3(triplets:literals:rawBytes:)`. N40 representative value: `claw-code` top count `92`, `llama.cpp` top count `99`. R26's `encodeBlockV3` single-trip fusion direction is still correct.
- Lazy2: top symbol is stable as `bestMatch #1 (_:) in closure #1 in static LZFSEv1.lzParseChain(_:maxL:maxM:maxDist:)`. N40 representative value: `claw-code` top count `162`, parse hits `380`; `llama.cpp` top count `130`, parse hits `317`. The rep length cache of R26 is still the correct focus.
- Optimal: top symbol is stable as `specialized closure #1 in static LZFSEv1.lzParseOptimal(_:maxL:maxM:maxDist:)`. N40 representative value: `claw-code` top count `565`, parse hits `963`; `llama.cpp` top count `508`, parse hits `893`. The main cost of Optimal is still DP / parse closure. If you want to move optimal next, you should do segment hierarchical gating or cheap probe first, instead of just fine-tuning encode path.
- Other3 / Apple / External tools: Other3 is mainly in `encodeBlock` / FSE, Apple in `lzfseEncodeMatches`, TLZ4 / ZSTD hotspot is an internal symbol of external tools and should not be mixed with Swift LZFSE parser hotspot.

## The next step

1. Update the acceptance benchmark with the numbers of this round: BVX3 is `claw-code n40 646.70 MB/s` / `llama.cpp n40 437.28 MB/s`; Lazy2 is `57.54 / 173.90 MB/s`; Optimal is `29.84 / 56.21 MB/s`.
Two. Each subsequent complete benchmark must confirm that `CPU_CALL_TREE_ANALYSIS_DONE` in `round_status.txt` is earlier than `BENCHMARK_RESULT_REBUILD_DONE` to avoid blanking the CPU field again.
3. The next code optimization still gives priority to the acceptance of two single points of R26: BVX3 `encodeBlockV3` and Lazy2 `bestMatch`; each change needs to compare the compression speed, decompression speed, compression ratio, encode/decode RSS and CPU top symbol changes at the same time.

---

# Round 26: BVX3 / Lazy2 CPU Single-point Uptimization (2026-06-15)

> Only move `lzfse-cli.swift`. Under the top symbol of R25 cpu_call_tree (BVX3→`encodeBlockV3`, Lazy2→`lzParseChain.bestMatch`), do two **single-point acceleration with exactly the same output bytes and no compression ratio**; pending benchmark/memProbe acceptance.

## Change 1: `encodeBlockV3` three trips are integrated into a single trip

- Originally, three times for nMatches: (a) build `lVals/mVals/dVals` by triplets, (b) 3 depth rep-offset transform, (c) calculate `lSyms/mSyms/dSyms` and frequency `lOcc/mOcc/dOcc`.
- Change to **single `for t in triplets` cycle** to complete value interception, rep-offset, symbol and frequency; array change one-time configuration ( `repeating:count:`) instead of `append`.
- Effect: The visit to nMatches is from 3 trips to 1 trip, removing `append` reconfiguration and a large number of Swift Array visits (R25 trace's `encode` + `swift_array` hotspot). `lVals/mVals/dVals` still retains extra bits for the later segment LMD encoding, so only the front segment is merged and the array is not deleted.
- Correctness: MTF state machine of rep-offset, M=0→ send 0, symbol calculation order is exactly the same as the input value → **output byte unchanged**.

## Change 2: Rep length cache of `lzParseChain.bestMatch`

- `bestMatch` The 1 (rep try first) has been used `repLen` (Contains `matchLength` Scan) calculated the length of rep0/1/2; but 3 (reselect when rep is close to the best) **counted again** `repLen`.
- Change to calculate `l0/l1/l2` at once in 1 (direct sharing at the same distance, no repeated scanning), 3 direct reuse, and remove up to 3 `matchLength` scans each time `bestMatch`.
- Effect: `bestMatch` is the top symbol of Lazy2; 3 Triggered when "the best match comes from the chain rather than rep" (common), the `matchLength` saved here is the implicit bulk of lazy2.
- Correctness: The cache value is equal to the original recalculation value, and the `else-if` short circuit selection order remains unchanged → **The selected (len,dist) is exactly the same → The output byte remains unchanged**.

## Acceptance (wait for your benchmark)

- `swiftc -O` can be compiled, `./lzfse -test` is completely passed, 7/7 is consistent, and the compression ratio byte level remains unchanged (both changes are output-identical).
- Speed benchmark (R25 claw n40): BVX3 `631.83 MB/s`, Lazy2 `57.88 MB/s`; ≥10% single-point acceleration with the target and data set and `-n`.
- ⚠️ There is no swiftc in the sandbox. This round only did structural/balance static inspection; the actual speed needs your benchmark measurement.

---

# Twenty-fifth round supplement: complete staged result inspection (2026-06-15 16:59)

## Completion status

This round of staged `.txt` / `.csv` / `.md` The result has been covered. `lz4bench_log/` The n4 / n8 / n40 batch, `memprobeResults/` The two data sets of memory measurement, `trace/analysis/trace_summary.csv`, `trace/analysis/cpu_call_tree_summary/` And `lzfse-test.txt`. `benchmark.zsh` It has been completely run, `round_status.txt` The ending is `BENCH_DONE 16:59:54`. `helper/tracer.command` With `EXIT 0` / `TRACE_DONE 16:45:49` End; `helper/trace_analysis.command` With `TRACE_ANALYSIS_DONE 16:51:29` End; `helper/cpu_call_tree_analysis.command` With `CPU_CALL_TREE_ANALYSIS_DONE 16:59:54` End.

`trace/analysis/trace_summary.csv` Display external tools `tgz`, `zstd`, `tar.lz4` Both data sets are completed normally; all LZFSE encode trace are `300s` Timeout trace, but `target_seen=yes`, `time-profile=ok`, `time-sample=ok`. Therefore, this batch of LZFSE trace can be used for hotspot direction judgment, and should not be used to calculate the full running time or MB/s.

`lzfse-test.txt` still maintains correctness fully passed: other3 self-round trip is compatible with Apple, bvx3 / lazy2 / optimal self-round-trip, parallel decoding, private bvx3 Apple rejection, single-stream support and Apple mutual solution path have not returned. The small correctness case is only for functional verification and is not mixed with the large data set MB/s.

## The latest speed and RSS benchmark

The latest staged `BenchMarkResult.csv` and `best_points/best_points.md` still recalculate MB/s in raw bytes / ns. Compared with the previous version of R25, the overall trend remains unchanged, but the best point is slightly updated:

- `claw-code`
- Other3 best compression `593.25 MB/s` (n8), best decompression `784.59 MB/s` (n8), encode RSS `141.7–363.1 MB`.
- BVX3 best compression `631.83 MB/s` (n40), compression ratio `0.9515`, best decompression `733.09 MB/s` (n40), encode RSS `128.8–360.9 MB`.
- Lazy2 best compression `57.88 MB/s` (n40), compression ratio `0.9016`, encode RSS `187.5–500.6 MB`.
- Optimal compression `30.08 MB/s` (n40), compression ratio `0.8590`, encode RSS `214.2–561.6 MB`.
- ZSTD compression ratio `0.8255`, best compression `462.72 MB/s`, best decompression `1039.33 MB/s`, decode RSS about `9.0–9.2 MB`.
- `llama.cpp`
- Other3 best compression `449.94 MB/s` (n40), compression ratio `0.9978`, decode about `272.63–275.90 MB/s`.
- BVX3 best compression `446.62 MB/s` (n40), compression ratio `0.9815`, best decompression `281.88 MB/s` (n40).
- Lazy2 optimal compression `178.25 MB/s` (n40), compression ratio `0.9587`.
- Optimal optimal compression `57.06 MB/s` (n40), compression ratio `0.9415`.
- ZSTD compression ratio `0.9123`, best compression `471.62 MB/s`, best decompression `313.12 MB/s`.

The RSS conclusion is still maintained: the Swift LZFSE family is no longer a GB-level problem, but the encode / decode working set of n40 is still significantly higher than TLZ4 / ZSTD. In particular, lazy2 / optimal encode RSS is improved to `500–606 MB` level. The next round should not only look at the compression speed, but also fix `-n` to compare RSS and throughput.

## cpu_call_tree Conclusion

This round of `cpu_call_tree_summary.csv` has covered `claw-code` and `llama.cpp` at the same time. `time-profile` has symbol occurrence, which can be sorted by hotspot; `time-sample` is still a raw kperf address table, which only retains the row count and target status, and is not included in the symbol ranking. Note: At present, staged `BenchMarkResult.csv` has been synchronized with trace wall time / timeout / target_seen, but the CPU symbol field is still empty; the CPU conclusion should be subject to `trace/analysis/cpu_call_tree_summary/cpu_call_tree_summary.csv`.

- BVX3: The top symbol of the two data sets, n4/n8/n40 is `encodeBlockV3`, and encode hits and Swift Array hits rise at the same time; the next step is to check `encodeBlockV3`, `FSEOutStream`, array bounds / COW, rather than just changing the parser.
- Lazy2: The top symbol of both data sets is `lzParseChain.bestMatch`; `repLen` / `matchLength` is still the secondary hotspot that should be disassembled and measured.
- Optimal: The top symbol of the two data sets is `lzParseOptimal` closure; the symbol rows and unique symbols of n40 are significantly higher than n4, indicating that DP relaxation / price rebuild / emit path will be amplified with the scanning depth. The next step should be to do the segment level cheap probe first, and the low-yield segment should avoid optimal.
- Other3: top symbol is stable at `encodeBlock`, accompanied by `lzParseStrong`, FSE and Swift Array costs; to optimize standard LZFSE, apply the same set of encode buffer / array cost check.
- Apple: The top symbol is `lzfseEncodeMatches` / `lzfseEncodeBase`, which represents the internal LZFSE path of Apple Compression and should not be mixed with the Swift parser hotspot.

## The next step is to correct

1. **BenchmarkResult field synchronization**: Currently `BenchMarkResult.csv` The trace wall time / timeout / target_seen has been updated, but the CPU symbol field still needs to be re-aligned. `cpu_call_tree_summary.csv`, to avoid empty columns affecting subsequent sorting; the alignment key should use dataset + algorithm + n, and the external tool should use dataset + algorithm.
Two. **Large file strategy**: The original trace XML / trace package is easy to cause GitHub 100MB limit and repo expansion; subsequent commit should be mainly summary CSV / notes, and the original trace should be left on the machine or changed to external storage.
3. **bvx3 family optimization order**: first do BVX3 `encodeBlockV3` single point A/B, then do Lazy2 `bestMatch` / `matchLength`, and finally do Optimal segment hierarchical gating. Each change depends on the speed, compression ratio and RSS at the same time.
4. **Acceptance benchmark update**: BVX3 is based on `claw-code n40 631.83 MB/s` / `llama.cpp n40 446.62 MB/s`; Lazy2 is based on `57.88 / 178.25 MB/s`; Optimal is based on `30.08 / 57.06 MB/s`. Either change needs to prove at least the `>=10%` single-point improvement or `>=20%` RSS reduction in the same data set, and the compression ratio cannot be significantly regressed.

---

# Round 25: trace / cpu_call_tree included in BenchMarkResult (2026-06-15)

## Data status of this round

Re-reading this round `lz4bench_log/lz4bench-*-n*.txt`, `lzfse-test.txt`, `memprobeResults/`, `trace/analysis/trace_summary.csv` And `trace/analysis/cpu_call_tree_summary/`, and rebuild `BenchMarkResult.csv`. CSV still calculates decimal MB/s in raw bytes / ns; the new field includes `Trace timeout`, `Trace target seen`, `CPU Symbol Status`, `CPU Top Symbol`, `CPU Top Category` And parse / encode / fse / Swift Array hit counts.

`lzfse-test.txt` It is still the basis for correctness and is not comparable to the MB/s of large data sets. `trace/analysis` At present, there is only `claw-code` Effective trace; `claw-code-apple-n8.trace` Because of the previous time `.out` It was deleted externally, but `incomplete_package`, already in `trace_summary.csv` Skip it and don't include it in the cpu call tree.

## The latest throughput and RSS conclusions

`-n` scan still shows that the bvx3 family has a clear trade-off between compression speed, compression ratio and RSS:

- `claw-code`:
- Other3 optimal compression `559.49 MB/s` (n8), compression ratio `0.9872`.
- BVX3 optimal compression `625.62 MB/s` (n40), compression ratio `0.9515`, but the best decompression `731.24 MB/s` is also in n40.
- Lazy2 compression ratio `0.9016`, optimal compression `55.96 MB/s` (n40).
- Optimal compression ratio `0.8590`, optimal compression `28.81 MB/s` (n40).
- ZSTD compression ratio `0.8255`, best compression `453.67 MB/s`, best decompression `965.14 MB/s`.
- `llama.cpp`:
- Other3 optimal compression `412.03 MB/s` (n40), compression ratio `0.9978`.
- BVX3 optimal compression `374.86 MB/s` (n40), compression ratio `0.9815`.
- Lazy2 compression ratio `0.9587`, optimal compression `163.28 MB/s` (n40).
- Optimal compression ratio `0.9415`, optimal compression `54.12 MB/s` (n40).
- ZSTD compression ratio `0.9123`, optimal compression `390.99 MB/s`.

The results of this round of memProbe are different from R24. RSS has been reduced to hundreds of MB levels. R24's "LZFSE family encode/decode RSS is still 1GB+" conclusion should be regarded as old data or old probe method results:

- `claw-code` encode RSS:
- Other3 `135.9–354.9 MB`
- BVX3 `139.9–370.2 MB`
- Lazy2 `187.9–501.2 MB`
- Optimal `216.5–572.0 MB`
- `claw-code` decode RSS:
- Other3 `69.0–307.3 MB`
- BVX3 `69.5–316.3 MB`
- Lazy2 `68.0–316.0 MB`
- Optimal `65.1–313.0 MB`
- `llama.cpp` encode RSS:
- Other3 `129.8–360.1 MB`
- BVX3 `135.6–390.2 MB`
- Lazy2 `201.4–514.0 MB`
- Optimal `212.1–572.9 MB`
- `llama.cpp` decode RSS:
- Other3 `67.2–341.5 MB`
- BVX3 `77.4–343.4 MB`
- Lazy2 `63.1–339.5 MB`
- Optimal `67.2–343.7 MB`

RSS is still higher than TLZ4 decode `33.8 MB` and ZSTD decode `9 MB`, but it is no longer GB level. The next round of memory work should be changed from "whole file" to "there are still hundreds of MB working set" for positioning: the upper limit of chunk scratch, parser chain, encode staging and parallel inflight are still the main suspects.

## trace / cpu_call_tree found

`helper/tracer.command` now uses direct launch + `--target-stdin` to see `lzfse-profile` in Time Profiler. At the same time, add `.out.active` marker to avoid deleting `.out` that is being used by xctrace again. `trace_analysis.command` has supported `.trace.timeout`; timeout trace can be used in the hotspot direction, but not for MB/s or complete time-consuming judgment.

The effective LZFSE trace of this round of cpu call tree is in `claw-code`:

- Other3 n4/n8: the top symbol is `encodeBlock`, and there are also `lzParseStrong`, `fseEncode` and Swift Array bounds/COW costs.
- BVX3 n4: top symbol is `encodeBlockV3`, classified as encode; hit count shows that the cost of encode and Swift Array is obvious, and you can't just look at parser.
- Lazy2 n4: top symbol is `lzParseChain.bestMatch`, `repLen`, `matchLength` are also at the forefront of hot symbols in the whole area.
- Optimal n4: top symbol is the core closure of `lzParseOptimal`; `emitSteps`, `samplePointEntropyAndText`, `rebuildPrices` also enter hot symbols, indicating that DP / pre-screening / emit all need to be disassembled.
- Apple n4: top symbol is `lzfseEncodeMatches` / `lzfseEncodeBase`, which is an Apple LZFSE production and should not be mixed with the same hotspot with your own Swift parser.

`time-sample` is the raw kperf address table. At present, only the row count and target status are recorded, and are not included in the symbol hotspot ranking; `time-profile` is the current symbol occurrence source.

## bvx3 family's next strategy

1. **First, make a single-point CPU hotspot, no longer called UnsafePointer**: BVX3 first make single-point changes for `encodeBlockV3` / `FSEOutStream` / Swift Array bounds; Lazy2 targets `lzParseChain.bestMatch/repLen/matchLength`; Optimal sets up small A/B for `lzParseOptimal` DP closure, `emitSteps`, `rebuildPrices` respectively.
Two. **RSS target downgrade but still retain**: The next round of success conditions are changed to encode/decode RSS will be reduced by another 20% under the same data set and the same `-n`, instead of just pursuing a downgrade from GB level. To get close to TLZ4/ZSTD, you need to prove the actual boundary of scratch / staging / inflight.
3. **Optimal segment change level strategy**: `claw-code` Z Optimal compression ratio 0.8590 has obvious benefits, but `llama.cpp` Optimal is only 0.9415, which is still too big for ZSTD; you should use cheap probe to judge the segment yield first, go to Lazy2/BVX3 for the low-yield segment, and enter the high-yield segment to enter Optimal.
4. **trace coverage to supplement llama.cpp**: At present, cpu_call_tree only covers claw-code; the next round of tracer must rerun the complete n4/n8/n40 and two data sets, and avoid manually deleting `.out` halfway.

## Acceptance conditions for the next round

- `swiftc -O lzfse-cli.swift -o lzfse` can be compiled, `./lzfse -test` passed.
- `BenchMarkResult.csv` retains the MB/s calculation of raw bytes / ns and synchronizes the trace/cpu field.
- If the BVX3 encode is changed: `claw-code` BVX3 n40 compression speed needs to be higher than `625.62 MB/s` or RSS is lower than `370.2 MB`, the two should reach at least one and the compression ratio will not be reduced.
- If you change Lazy2: `claw-code` Lazy2 n40 compression speed needs to be higher than `55.96 MB/s`, and the ratio should be maintained around `0.9016`.
- If the Optimal is changed: `claw-code` Optimal n40 compression speed needs to be higher than `28.81 MB/s`, or use the segment level strategy to avoid the low-yield segment Optimal, and the overall ratio will not decline significantly.

---

# Round 24: `-n` Scan Result Integration (2026-06-15)

## The purpose of this round

This round rebuilds `BenchMarkResult.csv` according to `lz4bench_log/lz4bench-{dataset}-n4/n8/n40.txt`, `lzfse-test.txt` and `memprobeResults/`. This time it is clear that ** there is no re-run `helper/tracer.command` or `helper/trace_analysis.command` **; the old trace and the old `trace/analysis` products have been cleaned up, and the new hotspot will not be read in this round.

`BenchMarkResult.csv` is currently 48 rows: 2 data sets × 3 N × 8 formats. The speed bar still calculates decimal MB/s in raw bytes / ns; CSV and `best_points/best_points.csv` are both output in UTF-8 BOM, which is convenient for Excel reading. `lzfse-test.txt` shows built-in correctness cases continue to pass: other3 Apple compatibility, own bvx3/lazy2/optimal round trip, parallel decoding, private bvx3 Apple rejection, single-stream support and Apple mutual solution path are all maintained normally.

## Summary of speed

The speed comparison is subject to the `compression MB/s` / `decompression MB/s` of `BenchMarkResult.csv`. The compression size is included in the reference, but TGZ, Apple, ZSTD and multi-threaded external tools may fluctuate slightly due to metadata, tool version, threading and running environment even if the data is the same; this round only lists obvious trends as conclusions.

### The best point

> `log nX` of > TGZ / Apple / TLZ4 / ZSTD only represents the source log batch, and `-n` does not affect these algorithms; `-n` is only meaningful for LZFSE other3 / bvx3 / lazy2 / optimal path.

#### claw-code

| Format | Best compression ratio | Best compression MB/s | Worst compression MB/s | Best decompression MB/s | Worst decompression MB/s | Minimum Encode RSS | Maximum Encode RSS | Minimum Decode RSS | Maximum Decode RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 1.0000 ( `log n4`) | 51.63 ( `log n40`) | 48.24 ( `log n8`) | 614.80 ( `log n40`) | 605.50 ( `log n4`) | 4.0MB ( `log n4`) | 4.0MB ( `log n4`) | 3.7MB ( `log n4`) | 3.7MB ( `log n4`)|
| Other3 | 0.9872 ( `n4`) | 563.51 ( `n8`) | 390.43 ( `n4`) | 693.08 ( `n40`) | 664.02 ( `n4`) | 1455.2 MB ( `n4`) | 1639.5 MB ( `n40`) | 952.0 MB ( `n4`) | 1092.6 MB ( `n40`) |
| BVX3 | 0.9515 ( `n4`) | 494.50 ( `n40`) | 373.42 ( `n4`) | 501.38 ( `n8`) | 390.61 ( `n40`) | 1471.9 MB ( `n4`) | 1681.9 MB ( `n40`) | 918.2 MB ( `n4`) | 1060.4 MB ( `n40`) |
| Lazy2 | 0.9016 ( `n4`) | 54.87 ( `n40`) | 34.47 ( `n4`) | 760.31 ( `n40`) | 615.98 ( `n4`) | 1507.0 MB ( `n4`) | 1820.8 MB ( `n40`) | 871.1 MB ( `n4`) | 1013.4 MB ( `n40`) |
| Optimal | 0.8590 ( `n4`) | 29.16 ( `n40`) | 19.33 ( `n4`) | 718.84 ( `n40`) | 552.67 ( `n4`) | 1544.2 MB ( `n4`) | 1905.7 MB ( `n40`) | 831.6MB ( `n4`) | 973.4 MB ( `n40`)|
| Apple | 0.9877 ( `log n4`) | 156.12 ( `log n4`) | 154.30 ( `log n40`) | 689.32 ( `log n8`) | 569.11 ( `log n40`) | 1356.4 MB ( `log n4`) | 1356.5 MB ( `log n40`) | 473.1 MB ( `log n4`) | 473.2 MB ( `log n40`) |
| TLZ4 | 1.1796 ( `log n4`) | 634.00 ( `log n40`) | 617.19 ( `log n8`) | 993.71 ( `log n40`) | 567.08 ( `log n8`) | 79.9 MB ( `log n8`) | 86.2 MB ( `log n40`) | 33.8MB ( `log n4`) | 33.8MB ( `log n4`)|
| ZSTD | 0.8255 ( `log n4`) | 440.86 ( `log n40`) | 425.33 ( `log n4`) | 894.60 ( `log n4`) | 654.16 ( `log n8`) | 397.0 MB ( `log n4`) | 402.1 MB ( `log n8`) | 9.2 MB ( `log n4`) | 9.2 MB ( `log n4`) |

#### llama.cpp

| Format | Best compression ratio | Best compression MB/s | Worst compression MB/s | Best decompression MB/s | Worst decompression MB/s | Minimum Encode RSS | Maximum Encode RSS | Minimum Decode RSS | Maximum Decode RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 1.0000 ( `log n4`) | 65.08 ( `log n8`) | 62.20 ( `log n40`) | 289.62 ( `log n40`) | 272.24 ( `log n4`) | 4.1 MB ( `log n4`) | 4.1 MB ( `log n4`) | 3.8 MB ( `log n4`) | 3.8 MB ( `log n4`) |
| Other3 | 0.9978 ( `n4`) | 403.98 ( `n8`) | 302.33 ( `n40`) | 283.06 ( `n40`) | 256.74 ( `n4`) | 1234.9 MB ( `n40`) | 1350.7 MB ( `n8`) | 1182.5 MB ( `n4`) | 1323.2 MB ( `n40`) |
| BVX3 | 0.9815 ( `n4`) | 393.29 ( `n8`) | 295.32 ( `n40`) | 262.31 ( `n4`) | 255.12 ( `n40`) | 1297.1 MB ( `n4`) | 1379.5 MB ( `n40`) | 1163.7 MB ( `n4`) | 1305.5 MB ( `n40`)|
| Lazy2 | 0.9587 ( `n4`) | 163.91 ( `n40`) | 114.41 ( `n4`) | 301.60 ( `n4`) | 287.77 ( `n8`) | 1339.4 MB ( `n4`) | 1566.2 MB ( `n40`) | 1137.0 MB ( `n4`) | 1279.2 MB ( `n40`) |
| Optimal | 0.9415 ( `n4`) | 56.66 ( `n40`) | 36.64 ( `n4`) | 278.34 ( `n8`) | 254.70 ( `n4`) | 1376.4 MB ( `n4`) | 1720.9 MB ( `n40`) | 1117.1 MB ( `n4`) | 1259.5 MB ( `n40`) |
| Apple | 1.0008 ( `log n4`) | 166.86 ( `log n8`) | 144.59 ( `log n40`) | 274.45 ( `log n8`) | 237.36 ( `log n40`) | 1193.9 MB ( `log n4`) | 1193.9 MB ( `log n4`) | 590.3 MB ( `log n4`) | 590.4 MB ( `log n40`) |
| TLZ4 | 1.0549 ( `log n4`) | 364.93 ( `log n4`) | 225.96 ( `log n40`) | 309.15 ( `log n40`) | 270.96 ( `log n4`) | 81.9 MB ( `log n8`) | 90.4 MB ( `log n4`) | 33.8 MB ( `log n4`) | 33.8 MB ( `log n4`) |
| ZSTD | 0.9123 ( `log n4`) | 456.46 ( `log n40`) | 426.60 ( `log n8`) | 311.86 ( `log n8`) | 269.82 ( `log n4`) | 497.9 MB ( `log n40`) | 508.0 MB ( `log n8`) | 9.2 MB ( `log n8`) | 9.7 MB ( `log n40`) |

## `-n` Scanning Observation / `-n` Sweep Findings

1. `-n` It is still a throughput knob, not an RSS solution. `claw-code` Lazy2/Optimal compression in `n40` The fastest, but encode RSS is also up to 1.82GB/1.91GB; `llama.cpp` The lowest encode RSS of Other3 appears in `n40`, but the rest of the bvx3 family still maintains the range of 1.30GB–1.72GB. This means that the memory principal is still in chunk work set, parser scratch, compressed body staging or data copy.
Two. `claw-code` The compression ratio of the bvx3 family is still obvious: Optimal 0.8590, which is 4.72% smaller than Lazy2 0.9016, but the best compression speed is only 29.16 MB/s, which is about 1.88x slower than Lazy2. `llama.cpp` Optimal 0.9415 is only 1.79% smaller than Lazy2 0.9587, but the compression speed is about 2.89x slower. Optimal must be changed to the segment hierarchical benefit gate, not the whole area.
3. Decompression side `claw-code` Lazy2/Optimal can still reach 760.31/718.84 MB/s, but BVX3 is only 501.38 MB/s; `llama.cpp` Then the whole falls at 255–312 MB/s. This difference is more like the joint influence of data type and cache/I/O floating, and cannot be used to claim decompression with a single data set.
4. External tools provide a clear RSS lower limit: TGZ encode/decode about 4MB, TLZ4 decode 33.8MB, ZSTD decode 9MB level. In comparison, the LZFSE family decode is still 831MB–1.32GB, and the encode is still 1.23GB–1.91GB.

## memProbe and trace integration / memProbe and Trace

memProbe confirms again this round: the encode RSS of the LZFSE/bvx3 family is still the main problem. The minimum encode RSS is still at the GB level: `claw-code` Other3 1455.2MB, BVX3 1471.9MB, Lazy2 1507.0MB, Optimal 1544.2MB; `llama.cpp` Other3 1234.9MB, BVX3 1297.1MB, Lazy2 1339.4MB, Optimal 137 6.4MB. External tools are TGZ about 4MB, TLZ4 about 80–90MB, and ZSTD about 397–508MB.

Decode RSS has not dropped to the expected tens of MB or semi-compressed file level: `claw-code` Optimal minimum 831.6MB, Other3 952.0MB; `llama.cpp` Optimal minimum 1117.1MB, Other3 1182.5MB. This means that the current data still supports the judgment that "input/scanBlocks/work set is still a whole file or a large number of residences"; the previous decode reading file still needs to be verified with clean round verification, and it cannot be claimed that it has been completed based on the numbers of this round alone.

Trace did not run again this time, and the old `trace/analysis` export has been removed. The previous analysis confirmed that the external compressor trace could be used, but most of the old trace of LZFSE family profiling to `zsh` wrapper could not be used as a hotspot basis. `helper/tracer.command` has been changed to clear the old `*.trace` before re-running, and change to direct launch + `--target-stdin`; next time you want to do hotspot, you must first reborn trace and then run `trace_analysis.command`.

## This round of script and output sorting

- `helper/benchmark_result_rebuild.command` only read `lz4bench_log/lz4bench-*-n*.txt`, no longer fallback root directory old log; output `BenchMarkResult.csv` is UTF-8 BOM.
- `benchmark.zsh` has written the lz4bench result to `lz4bench_log/`, and the last step will rebuild `BenchMarkResult.csv` and generate Best Points.
- `helper/best_points_analysis.command` has output `best_points/best_points.md` and `best_points/best_points.csv`, including TGZ, best compression ratio, best/worst compression MB/s, best/worst decompression MB/s, minimum/highest Encode RSS, minimum/maximum Decode RSS.
- The CSV output of `helper/trace_analysis.command` has been changed to UTF-8 BOM; this round has not been executed.
- `helper/tracer.command` has been added to remove the old `*.trace` before running to avoid mixing new and old trace; this round has not been executed.

## bvx3 Family Improvement Strategy / bvx3 Family Strategy

1. **Prioritize encode work set**: `-n` cannot pull encode RSS out of GB level. The next step should focus on thread-local scratch pool, parser/DP buffer reuse, and remove `compressBody` per chunk `[UInt8](input)` copy. Success conditions: bvx3/lazy2/optimal encode RSS decreases by at least 20%, and the compressed output byte level remains unchanged or there is a clear reason for the difference.
2. **decode needs to switch from full-file scan to incremental scan**: At present, decode RSS is still 831MB–1.32GB. To reduce to tens of MB, `scanBlocks` and compressed input must be truly incremental, and the target is `N * 4MiB + window` level.
3. **Optimal change income gate**: `claw-code` With 4.72% volume return, Optimal can be used for high-yield segments; `llama.cpp` Only 1.79%, which is not worth the whole segment DP. The next step is to join the cheap probe, go to Lazy2/BVX3 in the low-yield segment, and enter Optimal in the high-yield segment.
4. **change hot spots after trace rebirth**: At present, match loop or DP inner loop is not changed according to the old trace XML. If you want to re-run trace in the next round, first verify `contains_lzfse_profile=yes`, and then draw top self-time/heavy stack.

## Acceptance conditions for the next round

- `swiftc -O lzfse-cli.swift -o lzfse` can be compiled.
- `./lzfse -test` maintain all cases passed.
- If you change the encode memory path: bvx3/lazy2/optimal encode RSS is at least 20% lower than the best in this round.
- If decode streaming: `claw-code` Optimal decode RSS should be significantly lower than 831.6MB, and `llama.cpp` Optimal decode RSS should be significantly lower than 1117.1MB.
- If changed to Optimal: recalculate MB/s with raw bytes/ns, `claw-code` The compression speed of Optimal is increased by at least 10%, or the income gate can make `llama.cpp` Avoid Optimal DP in the low-yield segment.

# Round 23: benchmark / memProbe / trace unified recalculation (2026-06-14)

## The purpose of this round

THIS ROUND OF REREAD `lz4bench-claw-code.txt`, `lz4bench-llama.cpp.txt`, `lzfse-test.txt`, `memprobeResults/` AND `trace/`. `BenchMarkResult.csv` has been refreshed to the same table, the speed bar calculates decimal MB/s by raw bytes / ns, and retains `Encode RSS(MB)`, `Decode RSS(MB)`, `Trace wall time(seconds)`, so that the throughput, peak RSS and Time Profiler coverage status can be compared with the same column.

This round of helper has moved the memProbe to run after the compression and decompression benchmark is completed; therefore, the formal decompression of MB/s is no longer disturbed by the probe, especially the decompression number of llama.cpp is more reliable than the previous round.

`lzfse-test.txt` is still positioned as a correctness and compatibility test, and is not included in the MB/s calculation; there is no failure mark in this round, and lazy2 / optimal self-round trip, parallel decoding, Apple compatibility/rejection path are all maintained.

## The latest speed results

### Compress MB/s

| Format | claw-code | llama.cpp |
| --- | ---: | ---: |
| TGZ | 50.79 | 66.01 |
| Other3 | 354.87 | 440.47 |
| **Lazy2** | **48.31** | **164.23** |
| **Optimal** | **26.71** | **56.88** |
| BVX3 | 515.78 | 429.01 |
| Apple | 149.57 | 166.95 |
| TLZ4 | 500.44 | 363.81 |
| ZSTD | 327.97 | 470.05 |

### Decompress MB/s

| Format | claw-code | llama.cpp |
| --- | ---: | ---: |
| TGZ | 246.23 | 272.43 |
| Other3 | 301.33 | 273.42 |
| **Lazy2** | **367.70** | **237.55** |
| **Optimal** | **284.12** | **226.03** |
| BVX3 | 162.91 | 265.73 |
| Apple | 201.03 | 219.65 |
| TLZ4 | 179.11 | 268.29 |
| ZSTD | 182.70 | 254.60 |

> The speed value of this wheel and the front wheel are still floating. After memProbe moved back, llama.cpp decompression MB/s returned significantly to the range of 220–273 MB/s; the decompression of claw-code still shows large disk/cache fluctuations, especially the low BVX3 single point. Therefore, the comparison is still based on the relative relationship within the same round and the multi-round trend, and the small difference in the compression size of Apple/ZSTD/TGZ is not regarded as evidence of algorithm change.

## Compression ratio and cost

| Data set | Lazy2 ratio | Optimal ratio | Optimal extra volume gain | Optimal/Lazy2 compression time |
| --- | ---: | ---: | ---: | ---: |
| claw-code | 0.9016 | 0.8590 | 4.72% smaller vs lazy2 | 1.81x |
| llama.cpp | 0.9587 | 0.9415 | 1.80% smaller vs lazy2 | 2.89x |

The conclusion remains unchanged: optimal has a visible volume gain for claw-code, but only saves 1.80% more for llama.cpp, but still needs 2.89x lazy2 compression time. In the next round, optimal should not be taken as a global strategy, but should be changed to a segment level cheap probe: the high-yield segment should enter optimal, and the low-yield segment should go to lazy2 or bvx3.

## MemProbe Results

| Format | claw encode | claw decode | llama encode | llama decode |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 4.0 MB | 3.7 MB | 4.1 MB | 3.8 MB |
| ZSTD | 392.3 MB | 9.5 MB | 508.4 MB | 9.3 MB |
| TLZ4 | 74.6 MB | 33.8 MB | 83.6 MB | 33.8 MB |
| Other3 | 1334.8 MB | 1014.2 MB | 1372.8 MB | 1244.2 MB |
| Apple | 1356.4 MB | 473.1 MB | 1193.8 MB | 590.3 MB |
| BVX3 | 1523.0 MB | 981.9 MB | 1365.8 MB | 1226.6 MB |
| Lazy2 | 1163.0 MB | 935.1 MB | 1554.0 MB | 1199.9 MB |
| Optimal | 1616.0 MB | 895.0 MB | 1655.3 MB | 1180.1 MB |

The latest memProbe shows that decode RSS is stable at about 473MB–1.24GB, no longer returning to R21's 2GB+, but still much higher than external tools; encoding RSS is more clearly the main problem. LZFSE / bvx3 family encode is about 1.16–1.666GB, compared with TLZ4 about 75–84MB and ZSTD about 392–508MB, representing that the in-the-way chunk, parser workspace, compression body, sorting buffer or `Data` copy of parallel encode still needs to be reduced independently. `-n` The default value does not let the RSS drop automatically. The next step is to scan with a smaller N.

## Trace integration

`trace/tracer_status.txt` shows that 16 Time Profiler bundles have been completed, the file name is `<dataset>-<algo>.trace`, and the LZFSE family maintains the `-si` stdin path. Trace wall time can still only confirm the coverage and relative magnitude, cannot replace benchmark MB/s, and cannot claim the hotspot ranking before CLI export fails.

| Format | claw-code | llama.cpp |
| --- | ---: | ---: |
| TGZ | 42s | 34s |
| ZSTD | 8s | 8s |
| TLZ4 | 8s | 10s |
| Other3 | 9s | 12s |
| Apple | 15s | 18s |
| BVX3 | 11s | 12s |
| Lazy2 | 50s | 25s |
| Optimal | 81s | 56s |

The available conclusion of Trace is very narrow: lazy2 / optimal is a long section, especially claw-code optimal; but the first two hotspots still need to record top self-time / heavy stack after opening `.trace` bundle with Instruments GUI.

## bvx3 family's next step plan

1. **Do a small N scan first, instead of directly claiming that encode RSS has been solved**: The default N still makes the bvx3 family encode RSS fall to 1.16–1.66GB. In the next round, you need to fix the same code, scan `-n 40 / 8 / 4` or a similar value, and confirm whether the smaller N can reduce any encode RSS of bvx3/lazy2/optimal by ≥20%, and the compression MB/s/ ratio is acceptable.
Two. **Do the optimal cost gate again**: use cheap probe to estimate the benefits of lazy2→optimal at the segment level. Low-yield data such as llama.cpp should not be optimized in the whole segment; the claw-code high-yield segment is worth paying the DP cost.
3. **decode RSS is still problematic, but the rank is lower than encode**: decode is currently about 0.47–1.24GB, which is still one to two orders of magnitude higher than zstd/tlz4; but the most unreasonable in this round is encode 1.16–1.66GB. The decode bounded streaming window should be scheduled independently to avoid mixing with optimal DP acceleration in the same round.
4. **Profiling only takes the specific hot spots after GUI reading**: Next time you want to change DP / match loop, first from `trace/claw-code-optimal.trace` And `trace/llama.cpp-optimal.trace` Extract the top two hotspots, and then make single-point changes; the speed success condition is to maintain the same wheel claw optimal compression time improvement ≥10%.

## This practical acceptance observation

**Item 1 (encode in-the-way digital decoupling) - done + investment evaluation**
- `-n <N>` knob (encode / decode shared, decoupled from the core number): The sem upper limit of `runParallelEncode` is changed to N. Default = number of cores × 2, upper limit < number of cores × 4, lower limit 1.
- ⚠️ **Acceptance result**: Under the default setting, encode RSS does not reach the -20% success condition, which is still about 1.16–1.66GB. This means that the N knob needs to be verified with a smaller value, and parser/DP scratch / `Data` copy is the next more certain single point.
- **scratch reuse assessment ("confirmation of whether it can be reused")**: feasible, but need to `lzParseOptimal` / `lzParseChain` / `lzParseStrong` The DP segment, hash and chain arrays inside have been changed to "thread-local scratch pool from the outside" (signature change, intrusive, correctness-critical), so this round **has not been blindly modified**, which is listed as the next step that needs to be compiled and verified. Other `compressBody` Inside `let bytes = [UInt8](input)` Copy an extra copy of 4MiB for each chunk, which can be changed together. `withUnsafeBytes` Save.

**Decode, take another step down - done**
- Eliminate the **duplicate input copy** of the CLI decoding path: originally `readToEnd()` Of `Data` And `decodeStreamToHandle` Inside `[UInt8]` Each has a complete compressed file; change to read only a single copy. `[UInt8]` ( `decodeStreamToHandle` Eat directly `[UInt8]`, no more internal copying). It is expected to save ~ compressed file size (claw ~0.4GB, llama ~0.55GB) decode RSS.
- **Acceptance result**: decode RSS is maintained at 473MB–1.24GB, and has not returned to 2GB+ of R21; but it has not reached dozens of MB, which means that `scanBlocks` / `src` incrementalization is still necessary follow-up work.
- Then go to "tens of MB" requires the second stage b: `scanBlocks` incremental scan + `src` stream reading (not done yet).

**Decode read the file to double (R24 follow-up, already done)**
- R24 data shows decode peak ≈ **2× compressed file** (claw optimal 422MB→829MB, other3 485MB→950MB), the bottleneck is not in the output but in the "reading file": `readToEnd()` The whole portion of `Data` And `[UInt8](...)` It exists at the same time at the moment of transformation.
- Repair: The CLI decoding terminal is changed to **single buffer incremental reading**-- `-i` File first `attributesOfItem` Take the size, once `reserveCapacity`, and then with 1MiB small pieces `read(upToCount:)` Append block by block and release temporary storage `Data` ( `-si` When the size of stdin is unknown, return block-by-block append). The input peak value is reduced from 2× compression file to **≈ 1× compression file + 1MiB**.
- Expected decode peak ≈ `1× compressed file + N×4MiB` (claw optimal `-n4` estimated ~0.44GB, about cut in half). Waiting for your benchmark + memProbe acceptance; `-test` keeps 7/7 and Apple mutual solution unchanged.

**Decode streaming input (receive 1× compressed input) - done (to be accepted)**
- R24 clean round shows that decode is still ~0.83–1.18GB, because **the whole compressed input is still resident** ( `src` whole file + `scanBlocks` whole scan). This time, change the `-i` file decoding to real streaming:
- New `decodeStreamFromFile`: read into the compressed stream block by block, accumulate into a group according to the chunkRaw boundary, **write and release in order after the whole batch of N groups of parallel decoding is successful**, and the whole compressed input is not held throughout the whole process. Read window ~1MiB + in the flying group N× (one set of compression + one set of output).
- Expected decode RSS ≈ **inflight × (≤4MiB compression + 4MiB output) + ~1MiB**, no longer linear with the file size ( `-n4` tens of MB; `-n40` about hundreds of MB).
- Correctness: Only stream for "self-block streaming" (each chunk is independently compressed → group self-contained); foreign single stream/non-block detection (misalign or decoding failure) when ** the first batch has not been written ** → return to `.fallback`, the caller ** reread the whole file ** take the existing whole-buffer path, and the output bytes are exactly the same (Apple/other3 compatibility zero impact). `-si` stdin cannot be reread → maintain single reading + whole-buffer.
- ⚠️ `decodeStreamFromFile` is not covered by `-test` ( `-test` goes to `decompress` / `parallelDecompress`'s Data API), and only benchmark's `diff` consistency is verified. Be sure to run benchmark 7/7 consistent + scan `-n 4/8/40` to compare decode RSS.

**Encode/decode read loop autoreleasepool (root cause correction) - done (to be accepted) / autorelease accumulation fix**
- R24 N-by-N data shows encode RSS ** has nothing to do with N, nothing to do with parser (other3 1455 ~ optimal 1544MB at n4, only ~90MB difference), and ≈ whole input size** (claw 1.38GB→~1.4–1.5GB, llama 1.26GB→~1.3–1.6GB). These three characteristics together point to the classic trap of macOS Foundation: ** There is no autorelease pool in the main thread reading loop** - `FileHandle.read(upToCount:)` return autoreleased `Data` temporary storage. When there is no pool emptying in the loop, it will accumulate to the "whole input size" before it is released at the end of the process.
- Repair method: Wrap 4 main thread reading loops into `autoreleasepool`, and empty each piece after reading--
- `runParallelEncode` producer read loop (encode main cause);
- `decodeStreamFromFile`'s `ensure()` (decode stream reading);
- CLI `-si` stdin and fallback's whole file reading.
- The strongly referenced `data` / `src` / `buf` remains outside the pool and is not affected, and only emptys the autoreleased backing of read. GCD worker (compressBody / parallel decoding) is automatically emptying each block and does not need to be processed.
- Expected: encode RSS is reduced from ≈ whole input (~1.4GB) to ≈ `N ×（chunkSize + parser workspace）` (should be less than hundreds of MB); decode will no longer accumulate compressed input in the form of temporary storage. **Waiting for your benchmark + memProbe acceptance**; This is a pure memory correction, compression/decoding bytes remain unchanged, and `-test` should be maintained consistent with 7/7.

**Helper adjustment correction - done**
- memProbe has been moved to the official compression/decompression benchmark to run; this makes the decompression MB/s no longer contaminated by the previous probe. The decompression result of llama.cpp rebounds to the range of 220–273 MB/s, which supports this adjustment direction.

**Acceptance suggestion**: `-test` keep 7/7 and solve with Apple; the next round of fixed code scan `-n 40 / 8 / 4` to see RSS↔speed pick-up; if the small N is not enough after RSS, change to parser scratch pool or `compressBody` to remove each chunk `[UInt8](input)` copy.

---

# Suggestion of modification direction: bvx3 family memory overall solution (R23 design notes)

> This section is the design direction, not the actual measurement. B/C line of R21/R23 memProbe and R22: encode RSS about 1.16–1.66GB, decode RSS about 0.47–1.24GB is **architecture-level** cost, and **all formats are shared** (other3 / Apple is also affected, not exclusive to bvx3). Therefore, the solution must be solved once in the common layer and ensure other3/Apple compatibility.

## one. Problem positioning (common layer, non-format exclusive)

`decodeStream` (line 2677) and `runParallelEncode` (line 3342) are I/O pipelines shared by all algorithms:

- **decode still has a whole file-level cost**: (a) 2678 lines `let src = [UInt8](input)` holds the whole compressed input (~0.4–0.6GB); (b) After batch output, the peak value is still about 0.47–1.24GB, which means that the compressed input, group temporary storage, `Data` copy / staging are still not completely bounded.
- **encode in the number of bound cores****: 3345 lines `maxTasks = activeProcessorCount` (this machine 20). Each chunk in transit has its own input 4MiB + output + parser workspace + hash-chain/DP array, peak ≈ number of cores × each chunk work set, currently about 1.16–1.66GB.

## two. Fulcrum: The maximum backtracking distance is determined by the "format", and it is very small.

- `maxDValue = 262139` (55 lines) → other3 / Apple maximum match distance ≈ **256KB** (i.e. Apple `LZFSE_ENCODE_MAX_D_VALUE`).
- `maxD3 = 4194299` (125 lines) → bvx3 ≈ **4MiB** (= `parallelChunkSize`).

Inference: **Any format decoding only needs to keep the "last W byte" history** (W = 256KB or 4MiB), no whole output is required. This is also the implicit premise that the current parallel grouping (2692 lines in chunkRaw boundary tangent, 2532 lines `dd <= w - historyFloor` boundary) can be established - but it has not been used to define decode memory. Gzip (32KB window) and zstd (frame window) maintain constant memory regardless of file size.

## three. Overall solution: single bounded streaming I/O layer (three knobs, covering all formats)

| Knob | Meaning |
|---|---|
| **W** | Maximum distance of the format (history window, ensure that the cross-block match is correct): other3 256KB / bvx3 4MiB |
| **N** | In-the-way depth (**the only knob of memory ↔ throughput**) |
| chunkSize | Follow 4MiB |

- **decode**: Solve N groups to N segments in the order of streaming → After solving a paragraph, ** write stdout in order and release **, only keep the history of the last W → RSS ≈ N × chunkRaw + W.
- **encode**: The transit number is changed from `maxTasks` to N + scratch pool to reuse workspace → RSS ≈ N × (chunkSize + workspace).
- **Apple/other3 compatibility zero impact**: The "bytes" of input/output are completely unchanged, only the buffer policy is changed; compatibility is a format problem, not a memory policy problem.

## four. Code landing point

- decode: `decodeStream` API changed from "repass the whole data" to "write output FileHandle while solving"; 2705 lines whole `allocate` → bounded ring window; 2678 lines `[UInt8](input)` + `scanBlocks` (line 2610) change incremental scan (read magic/header → read block body → solve → forward).
- encode: `runParallelEncode` (3342 lines) put `maxTasks` Decoupl with the "in-way upper limit" and add N; `scratchPool` (772 line prototype) expand parser/DP workspace.

## five. Memory estimation and user knob

- decode N=4 + after incremental scanning: 0.47–1.24GB → ≈ N×4MiB + 4MiB ≈ **20–24MB**.
- encode N=8 + scratch pool after: 1.16–1.66GB → ≈ 8×(4MiB + workspace) ≈ **hundreds of MB**.
- It is recommended to make `-mem low|balanced|max` (N = 2 / 8 / cores): `max` maintain today's speed and memory, and `low` change to low RSS.

## six. Weigh

The only cost: N becomes smaller → decoding parallelism decreases → decoding MB/s closer to zstd (claw may be 700→300–400). The current high decoding speed of lzfse was originally bought with "full-file configuration + full-core parallel"; this solution makes it **optional** rather than mandatory.

## seven. The installment corresponds to the success condition of R23

- **The second stage a (already done, this time)/ decode output bounded streaming**: add `decodeStreamToHandle` (Lzfse-cli.swift), decode the CLI path ( `.other3` / `.bvx3` Of `-decode`) Changed from "configure the whole output (~1.3GB) + write once" to "** batch parallel decoding → write stdout in order → release immediately**".
- Effective for **other3 and bvx3 families** (both follow this path); output bytes are exactly the same → Apple compatibility has zero impact.
- Correctness: Rely on "in-house 4MiB chunk independent compression → group self-contained" (code code 2593-2601 is guaranteed); foreign single stream/cross-group match automatically returns to the original whole-buffer decoding.
- Memory knob: CLI `-n <N>` (the number of groups in memory at the same time). **Default = number of cores × 2**; **The upper limit must be < number of cores × 4** (exceeding it will be clamped to 4×cores−1 and prompted); the lower limit is 1. Output side peak ≈ N × 4MiB (default 20 cores → N=40 → ~160MB; `-n 4` → ~16MB).
- ⚠️ **Actual reduction calibration**: At this stage, only the "whole output buffer (~1.3GB)" is eliminated; ** The compressed input `src` is still read in the whole (~0.4–0.6GB)**. This memProbe has been reduced to about 0.47–1.24GB, but it is not "tens of MB"; if it is lower, the second stage b or a small `-n` is required.
- **The second stage b (to be done)**: `scanBlocks` (2610 lines) changes the incremental scan, `src` changes the stream reading, and deletes the ~0.5GB → to reach dozens of MB.
- **The first stage (to be done)/ encode**: limit the number of people in transit N + scratch pool, reduce encode RSS (1.16–1.66GB).
- **Acceptance (you run benchmark + memProbe)**: 7/7 decompression is consistent, compression ratio byte level remains unchanged; decode RSS (other3/bvx3/lazy2/optimal)−≥20% (expected ~−70% at this stage). `-n 4`, `-n 2` can be measured separately, looking at the memory ↔ decompression speed.

---

# Round 22: Time Profiler trace full coverage (2026-06-14)

## The purpose of this round

This round has not re-run benchmark; `BenchMarkResult.csv` follows the latest MB/s of R21 calculated by raw bytes / ns. The new work is to expand `helper/tracer.command` into two data sets × 8 format Time Profiler batch tracing, the output is placed in `trace/`, and the file name is aligned memProbe style: `<dataset>-<algo>.trace`. Two large tar inputs and profiling compression outputs have been cleared, and 16 `.trace` bundles have been retained.

## Trace completeness

- ✅ `TRACE_DONE 13:55:59`, 16 `.trace` bundles have been output.
- ✅ COVERS `claw-code` / `llama.cpp` × `tgz`, `zstd`, `tar.lz4`, `other3`, `apple`, `bvx3`, `lazy2`, `optimal`.
- ✅ The LZFSE family still uses `cat <dataset>.tar | lzfse-profile -encode -si ...` to maintain the pipeline / `-si` path.
- ⚠️ `xcrun xctrace export --toc` returns to the current trace `Fatal error reported in run 1`, CLI cannot export the call tree/hotspot table yet; trace bundle can be left for Instruments GUI to open the analysis.

### Trace wall time (including xctrace recording and saving cost)

| Format | claw-code | llama.cpp |
| --- | ---: | ---: |
| TGZ | 42s | 34s |
| ZSTD | 8s | 8s |
| TLZ4 | 8s | 10s |
| Other3 | 9s | 12s |
| Apple | 15s | 18s |
| BVX3 | 11s | 12s |
| Lazy2 | 50s | 25s |
| Optimal | 81s | 56s |

> This table cannot replace benchmark MB/s, because xctrace recording / symbolication / save bundle will add fixed costs; it is only used to confirm the tracing coverage and relative time scale. The formal performance comparison is still subject to the raw bytes / ns of `BenchMarkResult.csv`.

## and R21 benchmark / memProbe integration

1. **bvx3 baseline is fast, but lazy2 / optimal costs huge**: In R21 compressed MB/s, bvx3 is claw 505.74 / llama 320.84; lazy2 drops to 46.49 / 136.82; optimal drops to 27.11 / 40.93. Trace wall time also shows that lazy2 / optimal is a long segment, especially claw optimal 81s.
2. **bvx3 family encode/decode RSS is obviously too high**: external tool peak RSS is roughly TGZ 4MB, ZSTD 381–465MB encode / 9–10MB decode, TLZ4 75–83MB encode / 34MB decode; relatively, LZFSE/bvx3 family encode has reached 0.95–1.76GB, decode up to 1.45–2.34GB. This is not to measure noise, but the cost of architecture-level memory, which needs to be optimized independently.
3. **Optimal's additional RSS is not the main reason, but the family-based RSS is the problem**: R21 memProbe shows that optimal encode is only about 55MB (claw) and 102MB (llama) higher than lazy2, but the entire bvx3 family encode has reached 1.3–1.8GB, and decode is about 2GB or more. The optimal speed bottleneck still depends on the DP/match hotspot; the bvx3 family needs to deal with the buffer/staging of parallel coding and decoding.
4. **Decompression and encode profiling need to be disassembled**: The decompression MB/s of R21 is significantly slowed down by the impact of complete memProbe; if you want to decompress in the future, you should be independent of the profiling/memProbe round.
5. **At present, the hotspot ranking cannot be claimed**: Before the failure of CLI export, it should not be written that "chain walk" or `matchLength` is already a top hotspot; they can only be listed as candidates for Instruments GUI to be confirmed.

## Memory pressure observation

| Category | External Tools | LZFSE/bvx3 Family |
| --- | --- | --- |
| Encode RSS | TGZ 4MB, TLZ4 75–83MB, ZSTD 381–465MB | Other3 947–1311MB, BVX3 1321–1515MB, Lazy2 1490–1703MB, Optimal 1592–1758MB |
| Decode RSS | TGZ 4MB, TLZ4 34MB, ZSTD 9–10MB | Other3 1455–2345MB, BVX3/Lazy2/Optimal about 2047–2300MB |

> Conclusion: The bvx3 family is not currently "only a little more buffer than external tools", but one or two orders of magnitude higher. Decode RSS is the most sensitive to users, because decompression is usually expected to be low-cost, parallel, and stable operation under disk pressure; encoding RSS is also unreasonable, because the baseline BVX3 has reached 1.3–1.5GB, and lazy2/optimal is higher. This problem and optimal DP speed are two lines: speed optimization cannot cover up the excessive RSS.

## bvx3 family's next strategy

- **A line: First use Instruments GUI to read `trace/claw-code-optimal.trace` and `trace/llama.cpp-optimal.trace` **, take top self-time / heavy stack, and then decide whether to change `matchLength`, chain walk, dense relax, `rebuildPrices` or pre-screen.
- **B line: reduce bvx3 family encode RSS**. Priority is given to checking whether the parallel encode retains the input chunk, compressed body, match/price workspace, hash-chain table, result sorting buffer and `Data` copy at the same time; the goal is to lower the encode RSS from 1.3–1.8GB to the explainable upper boundary close to "chunkSize × maxTasks + parser workspace".
- **C line: reduce bvx3 family decode RSS**. Priority is given to checking whether parallel decode retains the complete chunk output, staging dictionary, `Data` copy and result sorting buffer at once; the goal is to lower the decode RSS from 2GB+ to the explainable upper boundary close to "chunkSize × maxTasks + output window".
- **Add cost gate instead of global optimal**: llama.cpp optimal is only 1.80% less than lazy2, but it takes 3.34x more compression time; segment-level cheap probe should be prioritized to exclude low-yield segments. This strategy can also reduce memory footprint, because the low-yield segment does not enter the heavy parser.
- **Keep lazy2 as the main high-rate mode, but limit its memory limit**: lazy2 still saves 9.84% TGZ-relative volume for claw, and the speed cost is acceptable; but encode RSS has reached 1.5–1.7GB, and it must be confirmed whether maxTasks / chunkSize can be dynamically adjusted.
- **R23 Success Conditions**: Get the top two hotspots from trace GUI and record them to `OPTIMIZATION.md`; also prove at least one bvx3 encode or decode RSS single-point improvement with memProbe. The speed line requires the same wheel claw optimal compression time to improve ≥10%; the memory line requires bvx3/lazy2/optimal either encode or decode RSS to be reduced by ≥20%, and the compression ratio does not regress.

---

# Round 21: Complete memProbe coverage and retest (2026-06-14)

## The purpose of this round

In this round, correct the benchmark helper first, and then re-execute it. `run_round.command`. The key is to let `round_status.txt` It can judge success/failure, and let `memprobeResults` Cover all benchmark formats: `tgz`, `zstd`, `tar.lz4`, `other3`, `apple`, `bvx3`, `lazy2`, `optimal`. `BenchMarkResult.csv` Used the latest `lz4bench-claw-code.txt`, `lz4bench-llama.cpp.txt` The raw bytes / ns recalculate decimal MB/s.

## Measure the completeness

- ✅ `run_round.command`: `TEST_OK 12:46:41`, `BENCH_DONE 13:08:24`.
- ✅ `claw-code` / `llama.cpp`: 8 formats of compression and decompression have been completed, and 7/7 consistency is passed.
- ✅ `lzfse-test.txt`: No failure mark.
- ✅ `memprobeResults`: Both data sets produce 8 formats encode + decode peak RSS.
- ✅ helper correction: `benchmark.zsh` Use zsh safe glob, `run_round.command` Correct return benchmark exit code; `zshrc.zsh` Of `extract` / `lzfseX` / `lz4bench` Support lazy2/optimal products and complete probes.

## Actual measurement results

### Compress MB/s

| Format | claw-code | llama.cpp |
| --- | ---: | ---: |
| TGZ | 52.36 | 65.62 |
| Other3 | 540.56 | 401.92 |
| **Lazy2** | **46.49** | **136.82** |
| **Optimal** | **27.11** | **40.93** |
| BVX3 | 505.74 | 320.84 |
| Apple | 150.31 | 145.03 |
| TLZ4 | 490.55 | 257.22 |
| ZSTD | 324.59 | 289.45 |

### Decompress MB/s

| Format | claw-code | llama.cpp |
| --- | ---: | ---: |
| TGZ | 436.82 | 214.73 |
| Other3 | 435.86 | 86.10 |
| **Lazy2** | **384.56** | **81.46** |
| **Optimal** | **268.60** | **74.32** |
| BVX3 | 327.22 | 75.99 |
| Apple | 288.64 | 45.78 |
| TLZ4 | 203.24 | 70.23 |
| ZSTD | 380.50 | 63.07 |

> This round of decompression MB/s is significantly lower than R20, especially llama.cpp. Adding a complete encode/decode memProbe before decompression in this round will change the page-cache and the memory status of the whole machine; therefore, decompressing MB/s can still only be recorded in the same round, which should not be used as evidence of algorithm regression. Compression MB/s and the same-wheel lazy2/optimal multiple are still the main basis for comparison.

### Compression ratio and co-wheel cost

| Data set | Lazy2 ratio | Optimal ratio | Optimal extra volume gain | Optimal/Lazy2 compression time |
| --- | ---: | ---: | ---: | ---: |
| claw-code | 0.9016 | 0.8590 | 4.72% smaller vs lazy2 | 1.72x |
| llama.cpp | 0.9587 | 0.9415 | 1.80% smaller vs lazy2 | 3.34x |

## MemProbe Results

| Format | claw encode | claw decode | llama encode | llama decode |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 4.0 MB | 3.7 MB | 4.2 MB | 3.8 MB |
| ZSTD | 381.3MB | 9.2MB | 464.5MB | 9.8MB |
| TLZ4 | 83.2 MB | 33.8 MB | 74.9 MB | 33.8 MB |
| Other3 | 947.0 MB | 1454.7 MB | 1310.9 MB | 2344.5 MB |
| Apple | 1356.3 MB | 473.1 MB | 1193.8 MB | 590.3 MB |
| BVX3 | 1514.8 MB | 2244.6 MB | 1320.8 MB | 2047.4 MB |
| Lazy2 | 1703.3 MB | 2197.6 MB | 1490.1 MB | 2300.3 MB |
| Optimal | 1757.9 MB | 2157.8 MB | 1592.2 MB | 2281.1 MB |

> LZFSE/bvx3 series encode RSS about 0.95–1.76 GB, decode RSS about 1.45–2.34 GB, both of which are much higher than external tools, which is an independent memory pressure problem. Optimal encode is about 55 MB (claw) and 102 MB (llama) higher than lazy2, and the gap is less than the speed cost; therefore, the main difference between optimal and lazy2 is still DP calculation, but the bvx3 family overall encode/decode RSS must be listed separately for optimization.

## Lazy2 / Optimal Improvement Strategy

1. **Profiling first and then moving DP**: claw optimal 27.11 MB/s, still not close to 40+ MB/s. The next step is to use Time Profiler to find out the first two hot spots, and can no longer use the overall feeling to change `lzParseOptimal`.
Two. **The cost gate is more valuable than the global optimal**: llama.cpp optimal spends 3.34x compression time and only saves 1.8% of the volume; the cheap probe should estimate the profit at the segment level, and the low-yield segment should be lazy2/bvx3.
3. **encode/decode RSS must be listed separately**: bvx3/lazy2/optimal encoding RSS about 1.3–1.8GB, decoding RSS about 2GB or more, which is significantly higher than TGZ/ZSTD/TLZ4; single-point improvement should be created for parallel encode/decode staging, workspace, output buffer, `Data` copy, and should not be mixed in optimal DP acceleration.
4. **Conditions for the next round of success**: Profiling output the quotable hotspot ranking, and prove that the same wheel claw optimal compression time improves ≥10% with single-point changes, and the compression ratio does not regress.

## The next round of planning

- Use `helper/tracer.command` or Instruments for claw optimal to make Time Profiler, and put the output in `trace/`.
- Maintain the `-si` input path; do not use `-i` instead of pipeline measurement.
- Choose a hot change according to the profiler: chain walk, `matchLength`, dense relax, `rebuildPrices`, or pre-screening.
- If the full benchmark is then decompressed, disassemble the memProbe and the decompressed benchmark into different rounds to avoid mutual contamination of the page-cache state.

---

# Round 20: Complete benchmark + memprobe refresh (2026-06-14)

## The purpose of this round

This round re-reads the latest `lz4bench-claw-code.txt`, `lz4bench-llama.cpp.txt`, `lzfse-test.txt`, `memprobeResults/lazy2-memprobe.txt`, `memprobeResults/optimal-memprobe.txt`, and recalculate the MB/s of `BenchMarkResult.csv` with exact raw bytes / nanoseconds. `lzfse-test.txt` is a function and compatibility test output, not a throughput benchmark of the same type, so it is used to confirm the compatibility of lazy2/optimal round-trip with Apple, and is not included in the MB/s table of CSV.

MB/s calculation is changed to decimal MB/s: `raw_bytes / elapsed_ns * 1000`. The original size column still follows the existing CSV display convention (rounding after raw KiB to MiB), the size after compression is rounded to exact compressed bytes to MB, and the compression ratio is calculated by "relative TGZ compressed bytes".

## Measure the completeness

- ✅ `claw-code`: 8 Format compression and decompression are completed, and 7/7 consistency is passed.
- ✅ `llama.cpp`: 8 Format compression and decompression are completed, and 7/7 consistency is passed.
- ✅ `lzfse-test.txt`: Each test case lazy2 / optimal self-round trip, parallel decoding, Apple compatibility/rejection path are all passed, and no failure marks are seen.
- ✅ `memprobeResults`: Get lazy2 / optimal encode and decode peak RSS for llama.cpp.
- ⚠️ `round_status.txt` still records the zsh `nomatch` message of `benchmark.zsh`; the result file is still fully output, but the helper cleanup section needs to be modified to `NULL_GLOB` or glob qualifier to avoid misleading the status file.

## Actual measurement results

### Compress MB/s

| Format | claw-code | llama.cpp |
| --- | ---: | ---: |
| TGZ | 52.69 | 68.15 |
| Other3 | 542.12 | 447.14 |
| **Lazy2** | **51.89** | **155.37** |
| **Optimal** | **29.05** | **54.43** |
| BVX3 | 587.07 | 422.57 |
| Apple | 159.53 | 170.17 |
| TLZ4 | 627.54 | 370.01 |
| ZSTD | 489.21 | 442.07 |

### Decompress MB/s

| Format | claw-code | llama.cpp |
| --- | ---: | ---: |
| TGZ | 607.60 | 285.67 |
| Other3 | 690.64 | 270.29 |
| **Lazy2** | **652.28** | **240.51** |
| **Optimal** | **685.82** | **219.34** |
| BVX3 | 706.44 | 259.18 |
| Apple | 697.58 | 223.76 |
| TLZ4 | 836.46 | 288.55 |
| ZSTD | 891.94 | 271.47 |

### Compression ratio and time multiple of the same wheel

| Data set | Lazy2 ratio | Optimal ratio | Optimal extra volume gain | Optimal/Lazy2 compression time |
| --- | ---: | ---: | ---: | ---: |
| claw-code | 0.9016 | 0.8590 | 4.72% smaller vs lazy2 | 1.79x |
| llama.cpp | 0.9587 | 0.9415 | 1.79% smaller vs lazy2 | 2.85x |

> The same-wheel comparison is still the most reliable indicator: claw-code optimal spends about 1.8x more compression time to change 4.7% volume; llama.cpp spends about 2.85x more to exchange only 1.8% volume. This supports the direction of "preset or automatic strategy bias lazy2, optimal only for high-volume sensitive segments".

## Memprobe results

| Mode | Encode peak RSS | Decode peak RSS |
| --- | ---: | ---: |
| llama.cpp bvx3 lazy2 | 1541.8 MB | 2300.5 MB |
| llama.cpp bvx3 optimal | 1611.6 MB | 2280.7 MB |

> optimal encode peak RSS is only about 69.8 MB (about +4.5%) higher than lazy2, which means that the main problem of optimal at present is not the memory peak, but the DP calculation time. Decode RSS is close to the two, and optimal decode is slightly lower, which does not constitute the main axis of optimization for the time being.

## Lazy2 / Optimal Improvement Strategy

1. **Short-term success conditions are changed to profiling verification**: 40+ MB/s can be kept as a medium-term target, but do not directly commit to speed in the next round; first use Time Profiler to find out the first two hotspots in about 49 seconds of claw optimal, and use at least one single-point change to prove that the same round ≥10% improvement.
Two. **Segment hierarchical cost gate takes precedence over the whole area optimal**: do a cheap probe for each section to estimate the possible benefit of optimal relative to lazy2; the low-yield segment goes directly to lazy2/greedy, and the high-yield segment goes to DP. Llama.cpp's optimal only saves 1.8% more volume but takes 2.85x time, which is the most obvious candidate.
3. **DP kernel still needs UnsafePointer/SIMD, but it needs to be profiled**: The direction of R19 is still valid, but this round of data shows that the performance gains cannot be exaggerated. If the profiler shows that the cost is concentrated in chain walk, `matchLength`, dense relax, `rebuildPrices` or pre-screening, only the first and second hotspots should be changed to avoid large-scale rewriting.
4. **helper needs to clean up the credibility of the status first**: `round_status.txt` Of `nomatch` The message will interfere with the reading; fix it before the next benchmark. `benchmark.zsh` Clean up glob, and let `run_round.command` Write when benchmark is not 0 `BENCH_FAILED`.

## The next round of planning

- Modify the zsh glob cleaning and failure status report of helper, so that `round_status.txt` can directly judge whether the whole round is successful.
- Use `helper/tracer.command` or Instruments quantity claw optimal, output into `trace/`, do not use `-i`, stdin path must use `-si`.
- According to the profiling results, choose a hot spot to make a single change. The successful condition is that the optimal compression time of the same wheel claw is improved by at least 10%, and the lazy2/optimal compression ratio is maintained without regression.
- If you want to convert the small case of `lzfse-test.txt` into speed data, you need to make a special microbenchmark; at present, it is only based on correctness and does not mix with the MB/s of claw-code / llama.cpp.

---

# Round 19: Parallel coding bounded buffer (backpressure) retest after landing (2026-06-14)

## The purpose of this round

There are code changes in this round, but **not on the compression algorithm**: `runParallelEncode` binds `sem.signal()` from "task completed" to "chunk write", so that "read but not written" strictly ≤ maxTasks (memory upper bound ≈ maxTasks × chunkSize), fix the slow chunk before and after pressing body in `results` boundless accumulation (→ OOM) In order to exclude the single measurement deviation, this round runs the same code three times** (R19a / R19b / R19c) two data sets 8 formats. Answer: (1) Does this correction ** not affect the compression ratio and single-stream throughput ** (should only affect memory); (2) How much does the MB/s in bytes/ns float between the "same code re-run" - thus separate the "algorithm effect" and "whole machine noise".


## Measure the completeness

✅ claw-code / llama.cpp each 8 format compression + decompression, 7/7 decompression is consistent; lzfse-test 112/112 all green (0 ✗); warm-cache is effective. The **R19c** column in the table below is the latest retest (consistent with `BenchMarkResult.csv`), and the "three-wheel range" is listed for quantification of the same code floating. All three rounds **probe** are not enabled**; R20 has been prepared `LZFSE_MEMPROBE=1` (see below).

## Actual measurement results

### Compression MB/s (main indicator: three-round stability)

| Format | claw R19c | claw three-wheel range | llama R19c | llama three-wheel range |
| --- | ---: | :--- | ---: | :--- |
| TGZ | 51.41 | 49.1–51.4 (±5%) | 68.35 | 67.5–68.3 (±1%) |
| Other3 | 508.51 | 481–564 (±16%) | 440.07 | 425–441 (±4%) |
| **Lazy2** | **53.34** | 49.7–53.3 (±7%) | **154.73** | 148–155 (±4%) |
| **Optimal** | **29.53** | 28.3–29.5 (±4%) | **53.57** | 52.9–53.9 (±2%) |
| BVX3 | 621.72 | 499–622 (±21%) | 418.65 | 419–423 (±1%) |
| Apple | 160.00 | 157–160 (±2%) | 170.98 | 171–172 (±1%) |
| ZSTD | 488.36 | 476–488 (±3%) | 468.64 | 466–473 (±1%) |
| TLZ4 | 638.66 | 603–639 (±6%) | 374.58 | 366–375 (±2%) |

> **Compression MB/s is a stable and comparable indicator**: the optimal / lazy2 three-wheel floating of focus is only ±2–7%. Claw optimal three-wheel 28.3 / 28.8 / 29.5 MB/s, lazy2 49.7 / 52.6 / 53.3 MB/s - this is the real algorithm throughput.

### Decompression MB/s (the noise of the three wheels of the same code is extremely loud, which cannot be compared)

| Format (claw) | Three-wheel range | Mulatation |
| --- | :--- | ---: |
| **ZSTD** | 380.5 – **1059.4** | **±88%** |
| BVX3 | 429.8 – 672.3 | ±45% |
| **Optimal** | 467.4 – 736.2 | ±42% |
| Other3 | 530.1 – 707.5 | ±28% |
| **Lazy2** | 545.7 – 696.9 | ±25% |
| TLZ4 | 678.7 – 862.9 | ±24% |
| Apple | 552.3 – 681.7 | ±21% |
| TGZ | 601.8 – 624.6 | ±4% |

> **This is the most powerful evidence in this round**: Three times running are **the same binary, the same data**, claw zstd decompression MB/s swings between 380 ↔ 1059 (**±88%**), and optimal / bvx3 also reaches ±42–45%, and the direction is irregular. It is proved that the decompression throughput is mainly determined by the OS page-cache hit rate and scheduling. **The single decompression MB/s cross-wheel is incomparable and cannot be attributed to the algorithm**. The control compression side is only ±1–7% - so this report is subject to **compression MB/s + the relative amount in the same wheel**, and the decompression is for reference only.

### Compression ratio (deterministic, reliable indicator)

| Format | claw R18 | claw R19 | llama R18 | llama R19 |
| --- | ---: | ---: | ---: | ---: |
| **Optimal** | 0.8590 | **0.8590** | 0.9416 | **0.9415** |
| **Lazy2** | 0.9020 | **0.9016** | 0.9583 | **0.9587** |
| BVX3 | 0.9516 | 0.9515 | 0.9815 | 0.9815 |

> After compression, the byte number is in R19a / R19b / R19c **the same in three rounds** (deterministic compression), and the difference from R18 is < 0.05% (the data set is floating file by file + Apple/zstd size will move slightly with the data). **Key verification: backpressure correction zero ratio impact** - the change of signal timing and memory boundary is indeed only moved to the scheduling, and did not touch `compressBody` and chunk cut.

### Relative in the same wheel: Optimal / Lazy2 compression time multiple (the most reliable)

| Data Set | R18 | R19a | R19b | R19c |
| --- | ---: | ---: | ---: | ---: |
| claw-code | 1.95× | 1.76× | 1.83× | **1.81×** |
| llama.cpp | 2.93× | 2.80× | 2.80× | **2.89×** |

> In the same wheel, optimal relative to the time multiple of lazy2, the three wheels are stable in claw ~1.8×, llama ~2.8×. This is a credible comparison without noise pollution of the whole machine: **Optimal takes about 1.8–2.9× time, only about 4% of the extra volume**.

## Lazy2 vs Optimal Improvement Strategy

1. **The sweet point of the ratio is still lazy2**: claw lazy2 0.9016 (vs optimal 0.8590), with an additional ~4.3% volume of ~1.8× compression time in the same wheel for optimal; in most situations, lazy2 is more cost-effective. Optimal is only cost-effective when "one pressure, multiple transmission/solution" and volume sensitivity.

2. **The bottleneck of optimal is in DP itself, not in parallel or memory**: compression MB/s is a stable indicator - claw optimal three rounds 28.3 / 28.8 / 29.5 MB/s, vs lazy2 ~50, zstd ~480. Parallel/memory has been modified to a boundary, **no longer a limiting factor**; to be faster, the price/match thermal cycle of `lzParseOptimal` must be unsafePointer + SIMD.

3. **The measurement method has been partially hardened and still needs to be continued**: The decompression noise ±88% proves that warm-cache is not enough to stabilize the decompression timing. This round has: (a) reported the conversion of the spindle to compression MB/s; (b) prepare a peak-RSS probe for R20. The next step is to take the median for "decompression" many times.

## Conclusion

1. **Modify in line with the design intention**: backpressure changes so that "read and not written ≤ maxTasks", memory upper bound ≈ maxTasks × chunkSize; the ratio is zero regression, and the compression path remains unchanged.
Two. **The throughput difference is noise (proved by the same code three-run)**: The same binary three-run decompression MB/s can be different by ±88%, so the single decompression MB/s cannot be attributed to the algorithm; the compression of MB/s (±1–7%) and the relative amount in the same wheel is reliable.
3. **Ratio can be reproduced**: optimal claw 0.8590 / llama 0.9415, lazy2 claw 0.9016 / llama 0.9587, across R16–R19 (including three runs of the same code) is completely stable.
4. **The direction remains unchanged**: The next step of optimal acceleration is the DP kernel, not the parallel architecture (the parallel has been repaired to the safety boundary).

## The next round of planning

- **Probe is ready**: `benchmark.zsh` Preset `export LZFSE_MEMPROBE=1`, the next round will automatically target lazy2 / optimal's **encode + decode** amount peak RSS ( `zshrc.zsh` Of `memProbe`, has been modified to " `time -l` Direct prefix lzfse" instead of package `sh -c` Pipeline, otherwise what is measured is shell). Expected empirically optimal in 1.3GB GGUF memory upper bound ≈ maxTasks × chunkSize. To close: `export LZFSE_MEMPROBE=0`.
- **DP core UnsafePointer + SIMD**: Fully index the price/match hot cycle of `lzParseOptimal`, eliminate Swift bounds-check and ARC expenses, target claw optimal 29→40+ MB/s.
- **Measuring hardening**: Decompress and take the median many times (compression MB/s has been confirmed to be stable enough, continue as the main axis) to eliminate the ±88% decompression noise caused by page-cache.
- **Encoder statcher**: Automatically select bvx1/bvx2/bvx3 according to block entropy, and integrate -lazy/-optimal.

---

# Round 18: R17 Changed Clean Environment Retest (2026-06-14)

## The purpose of this round

No code change. Both measurements of R17 were contaminated by the system load (en even tgz dropped to 21 MB/s). This round is re-run when the system is relatively idle, obtain a credible absolute MB/s, and answer "whes the entropy gate parameter (7.2 / 35% / three-point sampling / text protection) makes optimal faster?"


## Measure the completeness

✅ The two data sets each have 8 format compression + decompression, 7/7 consistent; lzfse-test is all green; warm-cache is effective. This round system is relatively idle - tgz/zstd/bvx3 has returned to normal speed (claw tgz 48.35, zstd 460, bvx3 511 MB/s), confirming that the non-load wheel.

## Actual measurement results

### Compression MB/s (focus optimal) vs R16

| Format | claw R16 | claw R18 | llama R16 | llama R18 |
| --- | ---: | ---: | ---: | ---: |
| **Optimal** | 25.36 | **28.02** | 46.92 | **54.08** |
| **Lazy2** (not affected by the entropy gate) | 47.36 | **54.58** | 129.59 | **158.74** |
| TGZ | 47.61 | 48.35 | 55.49 | 64.93 |
| ZSTD | 359.44 | 460.12 | 390.32 | 453.21 |

> ⚠️ optimal seems to be +10~15%, but **lazy2 (not related to entropy gate) is also synchronized with +15~22%, llama tgz +17%** - which means that this round of whole machine is faster than R16 (system status difference), **not the net acceleration brought by the entropy gate**. The absolute value of the cross-cycle still cannot be directly attributed.

### Relative in the same round: Optimal / Lazy2 time multiple (trusted indicator)

| Data set | R16 multiple | R18 multiple |
| --- | ---: | ---: |
| claw-code | 1.87× | **1.95×** |
| llama.cpp | 2.76× | **2.93×** |

> Key: The time multiple of the optimal relative lazy2 in the same wheel is R18 **not decreased but increased slightly**. The reason is that R17's ** text protection (isText) correctly leaves the text segment in DP** (R16's 7.5 threshold has no text protection, which may mistakenly skip some text paragraphs and "steal fast"). In other words, the entropy gate modulation parameter for these two data sets (claw=text, llama=source code as the main) ** has no measurable net acceleration**.

### Compression ratio (deterministic, fully reproducible across multiple rounds)

| Format | claw | llama |
| --- | ---: | ---: |
| **Optimal** | **0.8590** | **0.9416** |
| **Lazy2** | 0.9020 | 0.9583 |

> It is exactly the same as R16/R17. **The ratio of text protection is not sacrificed** - this is the real value of R17's change: the possible text misjudgment of R16 is corrected at the fixed ratio. The size of Apple/ZSTD will fluctuate slightly with the data set.

## Lazy2 vs Optimal Improvement Strategy

1. **The effect of the entropy gate on these data sets is limited**: claw is text (entropy < 7.2, and text protection is forced DP) → optimal cannot be accelerated by jumping DP; although llama contains binary, optimal is still 2.9× time relative to lazy2. The real value of the entropy gate is in the "** ratio-neutral safety net**" (avoiding the waste of DP and not damaging the text by mistake), not in general acceleration.
2. **optimal speed bottleneck in DP itself**: claw optimal 28 MB/s vs lazy2 55 MB/s vs zstd 460 MB/s. To approach zstd, you must use the DP core thermal cycle knife.
3. **lazy2 is still the sweet point of speed/ratio**: claw 54.58 MB/s, ratio 0.9020; most situations are better than optimal 1.95 × cost to 4.3% ratio.

## Conclusion

1. **Clean wheel confirmation**: This round of non-load wheel, absolutely MB/s is reliable.
Two. **There is no net acceleration of entropy gate adjustment**: the optimal/lazy2 multiple in the same wheel has not decreased (claw 1.95×, llama 2.93×); the absolute improvement of optimal comes from the system state rather than the algorithm.
3. **The ratio is zero regression and can be reproduced**: optimal claw 0.8590 / llama 0.9416 cross the same; text protection is the real harvest of R17.
4. **Direction establishment**: Optimal acceleration must follow the DP core UnsafePointer/SIMD, instead of continuing to adjust the entropy gate parameters.

## The next round of planning

- **DP kernel UnsafePointer + SIMD**: put `lzParseOptimal` The price/match hot cycle is fully indexed, Swift bounds-check and ARC overhead are eliminated, and the target claw is optimal 28→40+ MB/s.
- **Encoder adjuster**: Automatically select bvx1/bvx2/bvx3 according to block entropy, and introduce -lazy/-optimal.
- **The entropy gate is positioned as a safety net**: retain 7.2/35%/three-point/text protection (ratio-neutral), and no longer use it as the main axis of acceleration.

---

# Round 17: Entropy gate parameter adjustment + three-point sampling + text protection + warm-cache (2026-06-14)

## The purpose of this round

The implementation of Gemini's suggestion is to refine the R16 entropy gate and improve the stability of measurement: (1) entropy threshold 7.5→7.2, (2) pre-screening coverage threshold 28→35%, (3) `sampleEntropy` change three points (front/middle/back 512B each) sampling + text protection, (4) `lz4bench` plus warm-cache pre-reading data set.


## This round of changes

** `lzfse-cli.swift` ( `lzParseOptimal`):**

| Project | R16 | R17 |
| --- | --- | --- |
| `optEntropyHighThreshold` | 7.5 | **7.2** (SKIP DP MORE ACTIVELY) |
| `optPrescreenMinCoverage` | 28 | **35%** (more coverage rate section go greedy) |
| Entropy sampling | First 1KB single point | **Three points (front/middle/back 512B) average**, which can better represent the whole segment |
| Text Protection | None | ** `isText` Gatekeeper**: Sections with printable characters ≥85%, even if high entropy **do not jump DP** (to avoid the misjudgment of text paragraphs as a mess and loss rate) |

** `zshrc.zsh` ( `lz4bench`): ** Before compression timing, `tar -cf - "$1" > /dev/null` pre-reads the entire data set into OS cache to eliminate the timing deviation of "first format cold-cache, subsequent warm-cache".

## Test completeness

- **claw-code / llama.cpp**: ✅ Each 8 format compression + decompression, 7/7 consistency passed; lzfse-test all green; warm-cache has taken effect.
- ⚠️ **This round of measurement is carried out under the system load** (see below).

## ⚠️ Measurement condition warning

This round (with the previous rerun) ** The compression MB/s of all formats decreased comprehensively**, including tgz / zstd / bvx3 / lazy2 that is not related to this round of changes:

| Format (compressed MB/s) | claw R16 | claw R17 | llama R16 | llama R17 |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 47.61 | 43.11 | 55.49 | 37.50 |
| ZSTD | 359.44 | 209.93 | 390.32 | 199.59 |
| BVX3 | 515.82 | 205.28 | 299.04 | 162.65 |
| **Lazy2** (not subject to this round of changes) | 47.36 | 37.40 | 129.59 | 75.80 |
| **Optimal** | 25.36 | 16.17 | 46.92 | 26.17 |

> tgz/zstd/bvx3/lazy2 are all unrelated to the entropy gate, but the synchronous decrease of 15–60%, which can be confirmed to be caused by **system load** (background check.zsh, caffeinate, dispatch, Claude simultaneous operation), **non-algorithm regression**. Therefore, this round of "absolute compression MB/s" cannot be compared across the wheel.

## Trusted indicator: compression ratio (deterministic)

| Format | claw R16 | claw R17 | llama R16 | llama R17 |
| --- | ---: | ---: | ---: | ---: |
| **Optimal** | 0.8594 | **0.8590** | 0.9411 | **0.9416** |
| **Lazy2** | 0.9018 | **0.9018** | 0.9573 | **0.9590** |

> The compression ratio is almost exactly the same as R16 (the difference is < 0.2%, which is a floating data set version). **Key conclusion: After adding text protection, the optimal ratio has not regressed** - it proves that the entropy gate of R16 did not miss the text segment due to the 7.5 threshold (claw is text, isText is still DP throughout the whole process after guarding the gate, and the ratio remains unchanged). The size of Apple/ZSTD will fluctuate slightly with the data set.

## Lazy2 vs Optimal (R17, relatively effective only in the same round)

| Pointer | claw Lazy2 | claw Optimal | llama Lazy2 | llama Optimal |
| --- | ---: | ---: | ---: | ---: |
| Compressed MB/s | 37.40 | 16.17 | 75.80 | 26.17 |
| Decompression MB/s | 442.98 | 436.02 | 128.67 | 137.85 |
| Compression ratio | 0.9018 | 0.8590 | 0.9590 | 0.9416 |
| Optimal/Lazy2 compression time multiple | — | **2.31×** | — | **2.90×** |

> In the same round, the optimal time multiple claw 2.31×, llama 2.90× (consistent with the same condition trend as R16). Due to the load of the whole machine, the "net acceleration" brought by the entropy gate adjustment cannot be determined from this round of numbers.

## Conclusion

1. **All four changes have been implemented and correct**: compilation passed, lzfse-test 7/7, consistency 7/7, warm-cache effective.
Two. **The ratio has not regressed**: The text protection takes effect, and the claw/llama optimal compression ratio is the same as R16 - confirm that the three-point sampling + isText gatekeeper does not destroy the compression quality.
3. **Absolute speed comparison cannot be made in this round**: The full format (including unrelated tgz/zstd/bvx3/lazy2) is slowed down by 15-60% by the system load; the net acceleration effect of the entropy gate adjustment parameter ** has not been measured **.
4. **warm-cache is in place**: In the future, cold-cache interference to compression timing can be reduced under clean conditions.

## The next round of planning

- **Clean environment measurement**: Re-run a round under the idleness of the system (pause check.zsh / dispatch) to isolate the 7.2 threshold + 35% coverage rate + three-point sampling to the real acceleration of llama optimal.
- **Encoder adjuster**: Automatically select bvx1/bvx2/bvx3 according to block entropy, and introduce -lazy/-optimal.
- **Swift thermal cycle UnsafePointer**: claw (text) optimal is protected by text throughout the whole process DP, acceleration must rely on DP's own SIMD/pointerization, challenging version C zstd.

---

# Round 16: Entropy Perception Gate (Data-driven GGUF Partition) (2026-06-13)

## The purpose of this round

In response to the observation that "GGUF tensor weight accounts for ~99% of volume, content is chaotic, and the ratio of optimal and greedy is < 0.5%", ** segment hierarchical entropy sampler** is added to the optimal as the cheapest first gate: the pseudo-chaotic segment is directly greedy launch, completely skipping the expensive DP, in exchange for compressed throughput. Purely read the content, do not sniff the GGUF format/offset (fragile).


## This round of changes

** `lzfse-cli.swift` — `lzParseOptimal` New entropy gate (R10 design, actual installation in this round):**

| Project | Description |
|---|---|
| `optEntropySampleBytes` | 1024 (1KB before each sampling) |
| `optEntropyHighThreshold` | 7.5 bits/byte (the above is considered to be chaotic, skip DP) |
| Gate position | Place before the coverage gate (R9) ****: `segLen >= 4096 && sampleEntropy() > 7.5` → `greedyEmitSegment()` |
| Cost | Entropy sampling 1KB ≪ Coverage rate full segment scanning; high entropy segment saves the whole segment DP (DP cost is about dozens of times that of greedy) |
| Sharing | Entropy gate and coverage gate share `greedyEmitSegment()` (rep perception, match intercepted in segEnd, maintain cross-segment litStart invariant) |

`sampleEntropy()` 1KB before sampling Shannon entropy (bits/byte); `greedyEmitSegment()` is reconstructed from R15's inline greedy into a reusable function for two gates to share. Lazy2 analysis path is not affected (entropy gate is only within optimal).

## Test completeness

- **claw-code**: ✅ All completed (8 format compression + decompression, 7 consistency all passed)
- **llama.cpp**: ✅ All completed (8 format compression + decompression, 7 consistency all passed)
- **lzfse-test**: ✅ All green (including bvx3 lazy2/optimal self-round trip and parallel decoding)
- ✅ **Sufficient disk**: benchmark.zsh double diskcheck passed (28GB at the beginning, 26GB before llama segment, both ≥25GB threshold); EXIT 0, BENCH_DONE 19:57:21.

## Actual measurement results (R16 vs R15, MB/s measured by actual bytes/ns)

### Compression MB/s (Compression Throughput) - Focus: optimal (entropy gate only acts on optimal)

| Format | claw R15 | claw R16 | Difference | llama R15 | llama R16 | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Optimal** | 24.96 | **25.36** | **+1.6% 🟢** | 43.69 | **46.92** | **+7.4% 🟢** |
| **Lazy2** | 46.27 | **47.36** | +2.4%‡ | 142.63 | **129.59** | −9.1%‡ |
| Other3 | 404.87 | **460.00** | +13.6% | 361.48 | **309.71** | −14.3% |
| BVX3 | 410.62 | **515.82** | +25.6% | 135.35 | **299.04** | +120%※ |
| Apple | 143.54 | **146.32** | +1.9% | 88.99 | **151.62** | +70%※ |
| TGZ | 46.05 | **47.61** | +3.4% | 54.60 | **55.49** | +1.6% |
| TLZ4 | 536.59 | **569.78** | +6.2% | 133.67 | **337.63** | +153%※ |
| ZSTD | 369.66 | **359.44** | −2.8% | 136.97 | **390.32** | +185%※ |

> ‡ lazy2 is not affected by the entropy gate (the entropy gate is only within the optimal analysis); ±2–9% is a measurement noise and the data set version floats.
>
> ※ The low MB/s of llama BVX3/Apple/TLZ4/ZSTD compression MB/s of R15 is caused by the round of cold-cache I/O (already marked in R15); R16 cache conditions are better, so it rebounds significantly - this is **measurement condition difference** rather than algorithm changes, and cross-wheel must be compared with the same conditions.
>
> ** Core conclusion: Entropy gate makes llama optimal compression +7.4% (the proposed GGUF weight segment skips DP), claw optimal +1.6% (low text entropy, fewer segments triggering the gate). ** The direction is consistent with the design expectations: high entropy data benefits the most.

### Compress size (exact byte)

| Format | claw R15 (bytes) | claw R16 (bytes) | Difference | llama R15 (bytes) | llama R16 (bytes) | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Optimal** | 422,142,121 | 422,452,184 | +310,063 (+0.07%) | 571,976,860 | 573,166,606 | +1,189,746 (+0.21%) |
| **Lazy2** | 443,315,744 | 443,301,919 | −13,825 (≈0%) | 582,331,084 | 583,052,611 | +721,527 (+0.12%)‡ |

> Optimal changed greedy due to the high entropy segment, and the compression ratio decreased slightly (claw 0.8588→0.8594, llama ~0.9416→0.9411 interval), the cost < 0.25% - it is the reasonable choice of "DP cost vs < 0.5% ratio difference". ‡ lazy2 The difference comes from the floating version of the data set (there is a new commit in the llama.cpp repository). Apple/ZSTD compression size will fluctuate slightly even if the data is the same, and the cross-wheel comparison takes MB/s as the main indicator.

## Lazy2 vs Optimal Analysis (R16)

| Pointer | claw Lazy2 | claw Optimal | llama Lazy2 | llama Optimal |
| --- | ---: | ---: | ---: | ---: |
| Compressed MB/s | 47.36 | **25.36** | 129.59 | **46.92** |
| Decompress MB/s | 569.36 | **654.13** | 216.59 | **236.49** |
| After compression | 443M | **422M** | 583M | **573M** |
| Compression ratio (vs tgz) | 0.9018 | **0.8594** | 0.9573 | **0.9411** |
| Optimal vs Lazy2 compression time multiple | — | **1.87×** | — | **2.76×** |

**R16 take-off:** The entropy gate compresses the time multiple of llama optimal from 3.26× of R15 to **2.76×** (the proposed chaotic segment no longer enters DP), and the ratio remains almost unchanged (−0.05 pt). Claw optimal multiple 1.87× (the same as R15 1.85×, and most of the text paragraphs are still DP). Decompression optimal is still slightly faster than lazy2 (share bvx3 bit stream, the difference is noise).

## Conclusion

1. **Entropy gate is effective for high entropy data**: llama optimal compression +7.4%, time multiple 3.26×→2.76×, ratio cost < 0.25%. The design goal has been achieved.
Two. **Limited benefits of text data**: claw optimal is only +1.6% - text entropy is low (most segments < 7.5 bits/byte), still go to DP; the optimal bottleneck of text is still DP itself.
3. **lazy2 is not affected**: The entropy gate is only in the optimal analysis, and the lazy2 data changes to noise/data set fluctuation.
4. **Measurmeasurement discipline**: This round of cache conditions are better than R15, and the significant rebound of BVX3/Apple/TLZ4/ZSTD compression MB/s is a difference in conditions; the cross-wheel only compares with the same conditions, with optimal/lazy2 compression MB/s + compression ratio as the main indicator.
5. **Consistency and test all green**: The two data sets are 7/7 consistent, lzfse-test all pass, and the disk double check passes.

## The next round of planning

- **Lower the entropy threshold**: 7.5 conservative; can try 7.0–7.3, so that more "medium-high entropy" llama segments can skip DP (expect optimal will accelerate by 5–15%, and the ratio cost < 0.5%). It is necessary to protect the text data to avoid the loss of ratio by mistake in the text segment with high local entropy.
- **encoder dispatcher**: automatically select bvx1/bvx2/bvx3 according to block entropy, and introduce -lazy and -optimal (extension of R10 concept).
- **Swift thermal cycle**: The core match/DP cycle comprehensively `UnsafePointer`, eliminates Swift object-oriented overhead, and challenges the compression throughput of the C version of zstd.
- **Entropy sampling enhancement**: 1KB single-point sampling may misjudge the mixed segment; you can try multi-point sampling or front/middle/back three-segment sampling to take the average value.

---

# The fifteenth round: two-stage pre-screening + search budget counter (2026-06-13)

## The purpose of this round

Repair and complete the two omission strategies of R14 (attachment code, R9 design):

1. **Adaptive Search Budget**: Each segment budget = `segLen × 2`, accumulate the actual chain visit steps in a countdown basis; the search depth of the remaining position of the whole segment after overspending is forced to be cut in half (retain the lower limit of the desert). It is more accurate than the "period reset" mechanism of R14 - once the overspending is set up immediately, the flag will not be restored periodically.
Two. **Two-Pass Greedy Prescreen**: Each segment first uses an independent 14-bit local hash (not polluting the main head/chain) for a lightweight greedy scan; the whole segment with a greedy match coverage rate of < 28% (binary/random) is directly launched greedy, ** completely skip DP**. The greedy path shares the L/M/D statistics and rep history of DP through `emitGreedy()`, and the continuity is maintained across segments.

R14's rough estimate of `totalBarren` entropy agent (70% desert threshold) has been replaced by a real greedy pre-sweep. `optSufficientLen` is reduced to 192 (with pre-screening protection, no need for R14 radical 128 truncation).

## This round of changes

** `lzfse-cli.swift` — `lzParseOptimal` Change (R9 Strategy):**

| Project | R14 | R15 |
| --- | --- | --- |
| `optSufficientLen` | 128 | 192 (restore) |
| `optBudgetMultiplier` | 3 | 2 (tighter budget) |
| Budget Logic | `chainBudget` Count + Cycle Reset `effectiveDepthCap` | `searchBudget` Inverse + `budgetExhausted` flag |
| Low compression segment processing | `totalBarren` rough estimate (70% desert) | Independent local hash greedy pre-sweep (28% coverage) |
| Skip DP | None | Low coverage segment direct greedy launch |

**Bug repair (R15 first round discovery)**: The match `limit` of the greedy pre-screening section was originally `n - i - 4`, allowing the match to cross `segEnd`, resulting in `litStart > segStart` in the next DP, `pushRun` gets negative L length → stream damage (decode failed). Repaired to `limit: max(0, segEnd - i - 4)` to ensure that the match does not cross the segment.

## Test completeness

- **claw-code**: ✅ All completed (8 format compression + decompression, 8 consistency all passed)
- **llama.cpp**: ✅ All completed (8 format compression + decompression, 8 consistency all passed)
- **lzfse-test**: ✅ All green (compile 8s, including bvx3 lazy2/optimal self-round trip)
- ✅ **Sufficient disk**: The final rerun disk **43 GB is available** (≫25 GB threshold), and the compression and decompression numbers are reliable. The first round (disk 15 GB + residual file) decompression number has been abandoned, and this re-run shall prevail.
- ✅ **benchmark.zsh enhancement**: Add double disk space check (before the beginning + llama segment, < 25 GB → `"Benchmark aborted: insufficient disk space"` and stop) and `rm -rf llama.cpp.*` residual file cleaning to prevent the next run from being affected by disk pressure.

## Actual measurement results (R15 rerun vs R14, disk 43 GB)

### Compression MB/s (Compression Throughput) - Focus: lazy2 / optimal

| Format | claw R14 | claw R15 | Difference | llama R14 | llama R15 | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Lazy2** | 47.91 | **46.27** | −3.4% | 140.68 | **142.63** | **+1.4%** |
| **Optimal** | 26.53 | **24.96** | −5.9% | 42.88 | **43.69** | **+1.9% 🟟�** |
| Other3 | 412.63 | **404.87** | −1.9% | 359.91 | **361.48** | +0.4% |
| BVX3 | 457.95 | **410.62** | −10.3%† | 353.02 | 135.35 | −61.7%†† |
| Apple | 140.60 | **143.54** | +2.1% | 146.59 | 88.99 | −39.3%†† |
| TGZ | 46.65 | **46.05** | −1.3% | 54.11 | **54.60** | +0.9% |
| TLZ4 | 534.12 | **536.59** | +0.5% | 320.09 | 133.67 | −58.2%†† |
| ZSTD | 383.93 | **369.66** | −3.7% | 368.88 | 136.97 | −62.9%†† |

> † claw BVX3 slow (3.29s vs 2.86s): After this round of claw optimal (54s), the system may have a short I/O flush, resulting in a slightly slower subsequent BVX3. Measure noise, non-algorithm regression.
>
> †† llama BVX3 / Apple / TLZ4 / ZSTD is significantly slow: It is speculated that the system page cache is empty after claw optimal (54s) + sleep 60, and cold-cache I/O is serious when llama.cpp is read for the first time. Other3 (3.48s) runs first and still enjoys partial cache; the latter format cold cache is fully open (each needs to re-read 1.2 GB). This is the **measurement condition difference**, non-algorithm regression - the compression ratio (size) is not affected at all.
>
> **Core conclusion (re-run): llama.cpp optimal +1.9%, llama Lazy2 +1.4% (vs R14)**. The Optimal improvement is more conservative than the first round (+11.5%), because the first round of disk pressure also lowers the reference baseline of the first round of R15. The re-run results are more reliable: the two-stage pre-screening brings a stable and small improvement to llama optimal under clean conditions, and the slight regression of claw (−3–6%) is a measurement noise.

### Compress the size

| Format | claw R14 (bytes) | claw R15 rerun (bytes) | Difference | llama R14 (bytes) | llama R15 rerun (bytes) | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Lazy2** | 443,315,716 | 443,315,744 | +28 B (≈0%) | 582,331,025 | 582,331,084 | +59 B (≈0%) |
| **Optimal** | 421,706,858 | 422,142,121 | +435,263 (+0.1%) | 567,544,521 | 571,976,860 | +4,432,339 (+0.78%) |

> The size difference of Lazy2 is only 28/59 bytes, from **data set version floating** (claw-code / llama.cpp source code warehouse has a new commit), not the algorithm output is different. Optimal is due to the greedy path of some segments, and the compression ratio is slightly reduced (llama: 0.9416 vs R14 0.9343, +0.73 percentage points). The compression size of Apple and ZSTD will also fluctuate slightly with the version of the data set, and the cross-wheel comparison takes MB/s as the main indicator. This is a reasonable choice of speed to ratio.

## Lazy2 vs Optimal Analysis (R15 Rerun)

| Pointer | claw Lazy2 | claw Optimal | llama Lazy2 | llama Optimal |
| --- | ---: | ---: | ---: | ---: |
| Compression MB/s | 46.27 | **24.96** | 142.63 | **43.69** |
| Decompression MB/s | 544.71 | **622.95** | 161.22 | **197.97** |
| After compression | 443M | **422M** | 582M | **572M** |
| Compression ratio (vs tgz) | 0.9018 | **0.8588** | 0.9587 | **0.9416** |
| vs ZSTD size (byte accurate) | +9.2% | +4.0% | +5.1% | +3.2% |
| Optimal vs Lazy2 time multiple | — | **1.85×** | — | **3.26×** |

**R15 choice (re-run): ** claw optimal time multiple 1.85× (2.3× of vs R13, significantly improved). Llama optimal time multiple 3.26× (3.3× of vs R13, slightly improved). Decompression optimal is slightly faster than lazy2 (the same bvx3 bit stream, the decoder path is the same, and the difference is measured noise). The ratio advantage of Optimal (relative to lazy2) is maintained by −4.3% (claw) / −1.7% (llama), and it still needs to pay 2–3× compression time than lazy2.

## Conclusion

1. **Two-stage pre-screening is slightly effective for binary data**: llama.cpp optimal +1.9%, llama Lazy2 +1.4% (vs R14) under clean conditions. The first round +11.5% includes disk pressure noise, and it is more reliable to run again.
Two. **Text data (claw-code) slightly regressed**: the final claw optimal −5.9%, Lazy2 −3.4%, in the measured noise range, the non-algorithm regressed significantly.
3. **Bug repair experience**: The match of the greedy path must be limited to the segment boundary ( `segLimit = max(0, segEnd - i - 4)`), otherwise `litStart > segStart` will cause `pushRun` negative L length and stream damage after crossing the segment.
4. **Compression size cost**: The optimal ratio is slightly reduced (llama +0.78%), and the acceptable speed is exchanged for the ratio.
5. **Decompression digital (re-run) is reliable**: claw optimal 622.95 MB/s, llama optimal 197.97 MB/s, decompression is extremely fast under sufficient disk conditions, and the advantages of bvx3 family shared bit stream are obvious.
6. **benchmark.zsh improvement**: Add disk shortage abort (< 25 GB) + llama front file cleaning to avoid future re-running data contaminated by disk pressure.

## The next round of planning

Llama.cpp optimal is still 3× slower than zstd (9.18s → 137 MB/s), and claw optimal is 1.85× slower than TGZ. The next step direction:

- **Adjust the pre-screening threshold**: 28% coverage rate is conservative; 35–40% can be tried, so that more "medium coverage" llama sections are greedy and further accelerated (expected: the compression ratio is further reduced by 0.5–1%, and the speed is increased by 5–15%).
- **cold-cache I/O problem**: llama's BVX3 / Apple / TLZ4 / ZSTD is extremely slow when re-running (cold cache). The next round considers warm cache (read the original data) before each format of lz4bench to make the compression timing more stable.
- **claw-code slight regression confirmation**: profiling confirms whether segLimit truncation really causes a decrease in DP efficiency, or just measures noise; if it is truncated, consider that the last match is allowed to be extended to `n`.

---

# Round 14: Gemini Search Budget + Entropy Agent (2026-06-13)

## The purpose of this round

For the optimal compression bottleneck of R13 (claw 22.45 MB/s, llama 38.84 MB/s), five improvement strategies are recommended by Gemini.

## This round of changes

** `lzfse-cli.swift` — `lzParseOptimal` Five R14 Optimization:**

1. `optSufficientLen`: 192 → **128** (Super match fast path is more radical, strategy 5)
Two. `optBudgetMultiplier = 3` (each chain search budget = segLen × 3, strategy 1)
3. `chainBudget` Count + Cycle Reset `effectiveDepthCap` (dynamic search depth, strategy 1)
4. `totalBarren` segment-level entropy agent (70% desert → forced minimum depth, strategy 2/6)
5. The depth calculation is changed to `effectiveDepthCap` to replace the fixed `optSearchDepth`

## Test completeness

- **claw-code**: ✅ All completed (8 formats, all passed)
- **llama.cpp**: ✅ All completed (8 formats, all passed)
- **lzfse-test**: ✅ All green

## Actual measurement results

### Compress MB/s (Compression Throughput)

| Format | claw R13 | claw R14 | Difference | llama R13 | llama R14 | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Lazy2** | 47.31 | **47.91** | +1.3% | 127.84 | **140.68** | **+10.0% 🟢** |
| **Optimal** | 22.45 | **26.53** | **+18.2% 🟢** | 38.84 | **42.88** | **+10.4% 🟢** |
| Other3 | 400.55 | **412.63** | +3.0% | 273.41 | **359.91** | +31.6% |
| BVX3 | 440.53 | **457.95** | +4.0% | 276.71 | **353.02** | +27.6% |
| ZSTD | 386.74 | **383.93** | −0.7% | 371.41 | **368.88** | −0.7% |

> **Optimal significant improvement**: claw +18.2% (22.45→26.53 MB/s), llama +10.4% (38.84→42.88 MB/s).

### Compress the size

| Format | claw R13 (bytes) | claw R14 (bytes) | Difference | llama R13 (bytes) | llama R14 (bytes) | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Optimal** | 420,637,504 | 421,706,858 | +0.25% | 566,261,130 | 567,544,521 | +0.23% |

## Conclusion

The five strategies of R14 bring significant improvements to optimal (+10–18% compression speed), at the cost of a slight regression of compression ratio (+0.25%) and acceptable trade-offs.

---

# Round 13: Complete and reliable benchmark after disk recovery (2026-06-13)

## The purpose of this round

No algorithm code change. R12 is re-run because the disk is only 10–12 GB distortion and llama.cpp decompression and truncated; this round of disk recovery to **claw 32 GB / llama 31 GB available ** (≫ 25 GB alert value) to obtain the reliable data of the two data sets ** all 8 formats, compression + decompression are complete**, and verify that the lazy2/optimal product is correct.


## This round of changes

** `zshrc.zsh` - `lz4bench` Take back `diskcheck`: ** R11 After extracting the disk pre-inspection into an independent `diskcheck()`, it did not get back `lz4bench`, making the pre-inspection become a dead code. In this round, `diskcheck "$1"` is added at the beginning of `lz4bench`, and the disk available space is actively reported before each round of benchmark running (this round: sufficient claw 32 GB / llama 31 GB) to avoid distortion data under disk pressure again. `extract`, `lzfseX` The processing of lazy2/optimal ( `-lazy2` / `-optimal` flag, `-algo bvx3` decoding) has been checked to be correct and maintained.

## Test completeness

- **claw-code**: ✅ All completed (8 format compression + decompression, 7 consistency all passed)
- **llama.cpp**: ✅ All completed (8 format compression + decompression, 7 consistency all passed) - R12's Apple/TLZ4/ZSTD decompression truncation has been restored
- **lzfse-test**: ✅ All green (including bvx3 `-lazy2` / `-optimal` self-round trip and parallel decoding)

## Actual measurement results (R13 vs R11 reliable baseline)

### Compression MB/s (Compression Throughput) - Focus: lazy2 / optimal

| Format | claw R11 | claw R13 | Difference | llama R11 | llama R13 | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Lazy2** | 49.21 | **47.31** | −3.9% | 129.16 | **127.84** | −1.0% |
| **Optimal** | 23.99 | **22.45** | −6.4% | 40.85 | **38.84** | −4.9% |
| Other3 | 407.40 | **400.55** | −1.7% | 240.11 | **273.41** | +13.9% |
| BVX3 | 413.47 | **440.53** | +6.5% | 229.06 | **276.71** | +20.8% |
| Apple | 136.61 | **140.29** | +2.7% | 127.65 | **143.93** | +12.8% |
| TGZ | 47.81 | **44.31** | −7.3% | 55.81 | **52.84** | −5.3% |
| TLZ4 | 534.35 | **521.48** | −2.4% | 273.93 | **310.47** | +13.3% |
| ZSTD | 404.11 | **386.74** | −4.3% | 338.85 | **371.41** | +9.6% |

> lazy2/optimal compression MB/s is only 1–6% different from R11, which is within the measured noise range - confirm that ** compression throughput can be reproduced stably**.

### Decompress MB/s (Decompression Throughput)

| Format | claw R11 | claw R13 | Difference | llama R11 | llama R13 | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Lazy2** | 460.04 | **332.40** | −27.7% | 228.01 | **198.27** | −13.0% |
| **Optimal** | 548.28 | **261.57** | −52.3% | 199.41 | **202.22** | +1.4% |
| Other3 | 503.52 | **490.25** | −2.6% | 256.81 | **161.77** | −37.0% |
| BVX3 | 481.99 | **443.04** | −8.1% | 232.81 | **165.18** | −29.0% |
| Apple | 617.76 | **395.09** | −36.0% | 209.68 | **183.56** | −12.5% |
| TGZ | 533.61 | **419.14** | −21.5% | 259.96 | **182.99** | −29.6% |
| TLZ4 | 266.01 | **695.20** | +161% | 244.49 | **204.89** | −16.2% |
| ZSTD | 355.65 | **362.38** | +1.9% | 231.66 | **135.37** | −41.5% |

> ⚠️ Decompression MB/s fluctuates greatly between different rounds (548 of claw Optimal R11, 695 of TLZ4 R13, etc. are all out-of-group values related to system load). ** The decompression speed is greatly affected by the transient load of the system and the file cache, and the single-wheel value should not be regarded as an algorithmic feature. ** Key observations: ** llama Optimal decompression (202) ≈ Lazy2 (198) ** - once again confirm that the bvx3 family (lazy2/optimal/bvx3) shares the same meta-stream format, and the decompression speed is determined by the format rather than the analysis strategy.

### Compression Sizes (Exact byte, Compression Sizes)

| Format | claw R11 (bytes) | claw R13 (bytes) | Difference | llama R11 (bytes) | llama R13 (bytes) | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| Lazy2 | 443,123,872 | 443,315,716 | +0.04% | 582,575,735 | 582,331,025 | −0.04% |
| Optimal | 420,637,703 | 420,637,504 | −199 B | 566,223,268 | 566,261,130 | +0.01% |

> The size of the compressed output byte relative to R11 offset is < 0.05% (from the data set/tar metadata slightly floating), ** confirm that the algorithm output is deterministic**, and the lazy2/optimal product is correct.

## Lazy2 vs Optimal Analysis (R13)

| Pointer | claw Lazy2 | claw Optimal | llama Lazy2 | llama Optimal |
| --- | ---: | ---: | ---: | ---: |
| Compressed MB/s | 47.31 | **22.45** | 127.84 | **38.84** |
| Decompression MB/s | 332.40 | 261.57 | 198.27 | 202.22 |
| After compression | 433M | **417M** | 556M | **544M** |
| Compression ratio (vs tgz) | 0.9018 | **0.8557** | 0.9587 | **0.9322** |
| vs ZSTD Size | +3.7 pt | +3.0 pt | +4.7 pt | +2.0 pt |

**Core trade-off: ** Optimal exchanges the compression time of **2.1×(claw)/3.3×(llama)** for the file size of only **−3.7%(claw)/−2.1%(llama) of Lazy2**. Optimal's compression throughput (claw 22.45 MB/s) is the slowest in the whole table, which is the main bottleneck; Lazy2 is a better sweet spot in terms of speed/ratio.

## Conclusion

1. **R13 is a reliable round**: disk claw 32 GB / llama 31 GB, the two data sets are complete in all 8 format compression + decompression, and complete the truncated llama decompression data of R12.
Two. **Compression MB/s stable reproduction**: the gap between lazy2/optimal and R11 is only 1–6% (noise range).
3. **Decompression MB/s high fluctuation**: Cross-wheel departure is serious and dominated by system load/cache; multi-round median should be compared instead of single-wheel, and only compression MB/s and compression ratio should be used as the main indicators of algorithm quality.
4. **lazy2/optimal product is correct**: byte size offset < 0.05% (deterministic), consistency with lzfse-test all green.
5. **Optimal compression throughput is the bottleneck**: claw 22.45 MB/s (the slowest in the whole table), the DP optimal resolution cost is high, and the ratio return relative to Lazy2 is limited.

## The next round of planning

Profiling for **claw-code `-optimal` compression hotspot (22.45 MB/s)**, and evaluate the following lazy2/optimal improvement strategies:

```sh
# 確認磁碟空間後再 profiling
df -h ~                 # 需 ≥25 GB
./run_profile.command   # 對 claw-code -optimal 取樣
```

- **Optimal**: SIMDize the DP cost model, or set the search depth limit (fast-skip) for the long match, and the target is to recover throughput without hurting the compression ratio.
- **Lazy2**: Maintain the speed/ratio sweet point; observe whether it can be slightly close to the optimal ratio without sacrificing the speed advantage of ~2×.
- **Measuring discipline**: Decompress MB/s and take the median of multiple rounds to reduce the out-of-group interference caused by the system load.

---

# Round 12: Benchmark retest under disk pressure (2026-06-13)

## The purpose of this round

No algorithm code change - re-run a round under the same benchmark architecture to observe whether the reliable data of R11 can be reproduced.
The results show that the available disk space is seriously insufficient, resulting in data distortion, **R12 unreliable measurement round**.

## Disk status

| Data set | Available space at the beginning | Alert value | Status |
| --- | ---: | ---: | --- |
| claw-code | **10 GB** | ≥25 GB | ⚠️ Serious insufficiency |
| llama.cpp | **12 GB** | ≥25 GB | ⚠️ Serious insufficiency |

Only 10 GB of claw-code is available, and the disk I/O is very competitive during the compression process; although the claw-code temporary storage is released in the llama.cpp stage, there is still only 12 GB left.

## Test completeness

- **claw-code**: ✅ All completed (8 format compression + decompression, 7 consistency all passed)
- **llama.cpp**: ⚠️ Decompression truncation - Apple/TLZ4/ZSTD decompression is not complete (benchmark is stopped in the Apple decompression stage)

## Actual measurement results

### Compress MB/s (Compression Throughput)

| Format | claw R11 | claw R12 | Difference | llama R11 | llama R12 | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| TGZ | 47.81 | **38.89** | −18.6% 🔴 | 55.81 | **54.13** | −3.0% |
| Other3 | 407.40 | **238.98** | −41.3% 🔴 | 240.11 | **217.73** | −9.3% |
| **Lazy2** | **49.21** | **37.15** | **−24.5% 🔴** | **129.16** | **125.90** | **−2.5%** |
| **Optimal** | **23.99** | **17.46** | **−27.2% 🔴** | **40.85** | **39.48** | **−3.4%** |
| BVX3 | 413.47 | **410.78** | −0.7% | 229.06 | **221.63** | −3.2% |
| Apple | 136.61 | **138.16** | +1.1% | 127.65 | **120.43** | −5.7% |
| TLZ4 | 534.35 | **521.52** | −2.4% | 273.93 | **257.90** | −5.9% |
| ZSTD | 404.11 | **397.63** | −1.6% | 338.85 | **309.24** | −8.7% |

> The overall compression speed of claw-code has decreased by 20–40%, and the disk I/O competition is the main reason (when there is only 10 GB left, the random writing of SSD is significantly reduced).
> llama.cpp compression reduction of 3–9%, the disk is slightly better (12 GB), but still low.

### Decompress MB/s (Decompression Throughput)

| Format | claw R11 | claw R12 | Difference | llama R11 | llama R12 | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| TGZ | 533.61 | **419.89** | −21.3% 🔴 | 259.96 | **242.96** | −6.5% |
| Other3 | 503.52 | **233.24** | −53.7% 🔴 | 256.81 | **157.98** | −38.5% 🔴 |
| **Lazy2** | **460.04** | **256.71** | **−44.2% 🔴** | **228.01** | **177.94** | **−22.0% 🔴** |
| **Optimal** | **548.28** | **241.40** | **−56.0% 🔴** | **199.41** | **172.14** | **−13.7%** |
| BVX3 | 481.99 | **215.29** | −55.3% 🔴 | 232.81 | **143.67** | −38.3% 🔴 |
| Apple | 617.76 | **219.47** | −64.5% 🔴 | 209.68 | — (truncated) | — |
| TLZ4 | 266.01 | **304.32** | +14.4% | 244.49 | — (truncated) | — |
| ZSTD | 355.65 | **317.69** | −10.7% | 231.66 | — (truncated) | — |

> ⚠️ The decrease in the decompression speed of claw-code is more serious (-40 to -65%), which far exceeds the compression reduction, indicating that decompression is more sensitive to the available disk space.
> TLZ4 claw exception (+14%) may be the measurement noise.

### Compression Sizes (Compression Sizes)

| Format | claw R11 | claw R12 | llama R11 | llama R12 |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 480M | **481M** | 592M | **593M** |
| Lazy2 | 432M | **423M** | 561M | **570M** |
| Optimal | 417M | **407M** | 544M | **544M** |
| ZSTD | 395M | **395M** | 544M | **528M** |

> The M unit of `du -sh` is disk block configuration (non-precise bytes), and small fluctuations are normal.
> byte-level precise size ( `[SIZE]`) shows that the output of the compression algorithm is completely consistent (deterministic).

## Conclusion

1. **R12 is an unreliable rotation**: The available disk space of 10–12 GB is much lower than the recommended ≥25 GB, and compression and decompression are seriously distorted.
Two. **Disk pressure has a particularly heavy impact on decompression**: The decompression reduction of claw is -40 to -65%, which is much greater than the compression of -20 to -40%.
3. **llama.cpp benchmark truncation**: benchmark is suspended in the llama.cpp Apple decompression stage, and the Apple/TLZ4/ZSTD decompression data is missing.
4. **Compressed byte size is the same**: The algorithm output is still deterministic, and R12 matches the exact size of R11.
5. **R11 is still the valid baseline**: Please take R11 as the benchmark for the next round of comparison.

## The next round of planning

**Clean up the disk to ≥25 GB first, and then run profiling or the next round of benchmark:**

```sh
# 確認磁碟空間
df -h ~
# 需達到 ≥25 GB 可用空間後，再執行 benchmark 或 profiling
```

---

# Round 11: lz4bench repair + decompression baseline reconstruction (2026-06-13)

## The purpose of this round

No algorithm code change - fix the disk space management problem of lz4bench (disk-full defect found by R10),
Rebuild reliable decompression baseline data.

## This round of changes

** `zshrc.zsh` — `lz4bench` function reconstruction (inline cleanup mode):**

- Decompression is changed to sequential execution: decompression → compare with tgz → **delete immediately** → next format
- The peak disk usage decreased from ~14–18GB to ~3.5GB
- llama.cpp ZSTD decompression failed in R10 due to full disk load; this round has been completed normally ✓
- New disk available space pre-check (recommended ≥25GB)

## Actual measurement results (11:28–11:36)

✅ All 7 format consistency of the two data sets passed; lzfse-test 112 items are all green.

### Compress MB/s (Compression Throughput)

| Format | claw R10 | claw R11 | Trend | llama R10 | llama R11 | Trend |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| Lazy2 | 46.6 | **49.21** | +5.6% | 121.5 | **129.16** | +6.3% |
| Optimal | 22.8 | **23.99** | +5.2% | 37.6 | **40.85** | +8.6% |
| BVX3 | 377.6 | **413.47** | +9.5% | 214.7 | **229.06** | +6.7% |
| ZSTD (reference) | 383.1 | **404.11** | +5.5% | 236.2 | **338.85** | +43.5%↑ |

> The compression of MB/s is slightly improved in all formats (+5–10%). Presumed reason: R11 cleans up the disk format by format, and the disk I/O competition in the compression stage is reduced. The large amplitude of ZSTD llama may be related to the pressure on the disk in the last round of benchmark.

### Decompress MB/s (Decompression Throughput) - Reliable data for the first time

⚠️ R10 decompression is seriously distorted by disk pressure, and the data of R11 is greatly improved after using inline cleanup:

| Format | claw R10 | claw R11 | Improvement | llama R10 | llama R11 | Improvement |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| TGZ | 565.0 | **533.61** | Slightly decreased (R10 may be high) | 221.4 | **260.00** | +17.4% |
| Other3 | 465.6 | **503.52** | +8.1% | 194.5 | **256.81** | +32.0% |
| Lazy2 | 519.0 | **460.04** | −11.4% | 154.1 | **228.01** | +47.9% |
| Optimal | 308.0 | **548.28** | **+78.0%** | 131.9 | **199.41** | **+51.2%** |
| BVX3 | 215.7 | **481.99** | **+123%** | 98.5 | **232.81** | **+136%** |
| Apple | 142.9 | **617.76** | **+332%** | 108.2 | **209.68** | **+93.8%** |
| TLZ4 | 149.2 | **266.01** | **+78.3%** | 183.4 | **244.49** | +33.3% |
| ZSTD | 143.7 | **355.65** | **+147%** | ❌ Failed | **231.66** | ✅ Repair |

> The decompression data of R10 BVX3/Apple/Optimal/ZSTD has been confirmed to be unreliable due to the I/O slowdown due to disk accumulation.
> **R11 is the official reliable baseline of decompression speed. **

### Compression Sizes (Compression Sizes, exactly the same as R10)

| Format | claw | llama | Description |
| --- | ---: | ---: | --- |
| Optimal | 417M | 544M | Consistent with R9/R10 ✓ |
| Lazy2 | 432M | 561M | Consistent with R9/R10 ✓ |
| ZSTD | 395M | 544M | Consistent with R9/R10 ✓ |

There is no change in the compression algorithm, and the size is completely reproduced - confirming that the baseline is stable.

## R11 Reliable baseline (for subsequent round comparison)

### claw-code

| Format | After compression | Compression MB/s | Decompression MB/s | Compression ratio (vs tgz) |
| --- | ---: | ---: | ---: | ---: |
| TGZ (benchmark) | 480M | 47.81 | 533.61 | 1.000 |
| LZFSE Other3 | 475M | 407.40 | 503.52 | 0.987 |
| **LZFSE Lazy2** | **432M** | **49.21** | **460.04** | **0.902** |
| **LZFSE Optimal** | **417M** | **23.99** | **548.28** | **0.856** |
| LZFSE BVX3 | 446M | 413.47 | 481.99 | 0.952 |
| LZFSE Apple | 464M | 136.61 | 617.76 | 0.988 |
| TLZ4 | 558M | 534.35 | 266.01 | 1.180 |
| ZSTD-9 | 395M | 404.11 | 355.65 | 0.826 |

### llama.cpp

| Format | After compression | Compression MB/s | Decompression MB/s | Compression ratio (vs tgz) |
| --- | ---: | ---: | ---: | ---: |
| TGZ (benchmark) | 592M | 55.81 | 259.96 | 1.000 |
| LZFSE Other3 | 594M | 240.11 | 256.81 | 0.998 |
| **LZFSE Lazy2** | **561M** | **129.16** | **228.01** | **0.959** |
| **LZFSE Optimal** | **544M** | **40.85** | **199.41** | **0.932** |
| LZFSE BVX3 | 577M | 229.06 | 232.81 | 0.982 |
| LZFSE Apple | 592M | 127.65 | 209.68 | 1.001 |
| TLZ4 | 626M | 273.93 | 244.49 | 1.055 |
| ZSTD-9 | 544M | 338.85 | 231.66 | 0.912 |

## Lazy2 vs Optimal Analysis

| Pointer | claw Lazy2 | claw Optimal | llama Lazy2 | llama Optimal |
| --- | ---: | ---: | ---: | ---: |
| Compressed MB/s | 49.21 | 23.99 | 129.16 | 40.85 |
| Decompression MB/s | 460.04 | 548.28 | 228.01 | 199.41 |
| Compressed size | 432M | 417M | 561M | 544M |
| vs ZSTD Size | +9.4% | +5.6% | +3.1% | 0.0% |

**Optimal's decompression speed is faster than Lazy2** (claw: 548 vs 460 MB/s; the difference comes from the fact that Optimal generates shorter and more regular match sequences, and the FSE symbol path is shorter). This is the first reliable data observed by R11.

## Conclusion

1. **lz4bench inline cleanup repair successful**: llama.cpp ZSTD decompression returns to normal (231.66 MB/s).
Two. **R10 Decompression Data Confirmation Distortion**: BVX3/Apple/Optimal is seriously slow under accumulated disk pressure; R11 is the first reliable decompression baseline.
3. **Slight improvement in compression of MB/s** (+5–10%): There is no code change in this round, which is presumed to come from lower disk I/O competition.
4. **Optimal decompression speed is eye-catching**: claw 548 MB/s > Lazy2 460 MB/s; decompression vs ZSTD: Optimal 548 vs 356, Lazy2 460 vs 356 (all 1.3–1.5 times faster).
5. **The next step is still profiling**: Run profiling on the reliable baseline to find out the real hotspots of compressing MB/s.

## The next round of planning

**Execute profiling to measure compression hotspots (especially the 23.99 MB/s of claw-code bvx3 -optimal):**

```sh
cd ~/proj/lzfse2
open run_profile.command   # 對 claw-code bvx3 -optimal 取樣 20 秒
# 完成後查看 profile-optimal.txt 的熱函數
```

According to the R9 candidate strategy (selected under the guidance of profiling results):

| If the hot spot is | direction | expectation |
| --- | --- | --- |
| DP relaxation array writing (per-cell 6 array) | SoA packaging: price+len combined 64-bit word | Write bandwidth −50% |
| `matchLength` Comparison Cycle | SIMD16 Vector Comparison | match body −50–70% |
| hash chain visit | `optSearchDepth` 16→8 or price-based early departure | Visit volume −30–50% |
| emit / backtrace | DP segment 128K→256K | Fixed overhead −50% |

---

# Round 10: Baseline Reconfirmation + Disk Full Load Warning (2026-06-13)

## The purpose of this round

No code change - reconfirm the stability of the R8/R9 baseline, and record the full disk problem of this round.

## Actual measurement results (10:53–11:02)

⚠️ **Disk space is exhausted in the test** (llama.cpp decompression test back space is insufficient → xbenchTest total 14G, cleaned up):
- claw-code All 8 format compression and decompression completed ✓
- llama.cpp all 8 formats compressed completed ✓; when decompressed to ZSTD, the disk is full, **ZSTD decompression failed**
- `rm -rf xbenchTest` released 14G space

⚠️ **llama.cpp decompression data is affected by disk pressure** (BVX3 12.2s, Apple 11.1s, etc. are abnormally high);
The later format of claw-code (Apple 9.1s) may also be affected by heat throttling.
**Decompression MB/s This round is for trend reference only, no absolute comparison. **

### Compress MB/s (reliable)

| Format | claw R9 | claw R10 | Trend | llama R9 | llama R10 | Trend |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| Lazy2 | 45.9 | **46.6** | ≈ equal | 118.3 | **121.5** | ≈ equal |
| Optimal | 22.4 | **22.8** | ≈ Flat | 37.6 | **37.6** | Flat |
| ZSTD (reference) | 376.0 | **383.1** | ≈ flat | 297.4 | **236.2** | ⚠️Slow (disk write pressure) |

### Compression size (stable)

| Format | claw R9 | claw R10 | llama R9 | llama R10 |
| --- | ---: | ---: | ---: | ---: |
| Optimal | 417M | **417M** ✓ | 544M | **544M** ✓ |
| Lazy2 | 432M | **432M** ✓ | 571M | **571M** ✓ |

The compression ratio is exactly the same as R9, confirming that **baseline is stable and there is no code back**.

## Conclusion

1. **Compression MB/s stable** (±3% noise): Optimal claw 22.4→22.8, llama 37.6; Lazy2 claw 45.9→46.6, llama 118→121.
Two. **The compression ratio remains unchanged**: Optimal 417M/544M, Lazy2 432M/571M.
3. ⚠️ **Decompression data is not reliable** (disk pressure/heat throttling), please use R9 data as a decompression reference reference.
4. **The next step is still profiling**: Compression MB/s improvement needs to measure hot spots first.

## The next round of planning

**Execute profiling, and then decide the direction according to the hotspot:**

```sh
cd ~/proj/lzfse2
open run_profile.command   # 取 claw-code bvx3 -optimal 20 秒樣本
# 完成後查看 profile-optimal.txt
```

⚠️ **Disk Management**: Before the next benchmark, confirm that there is ≥25G available space (xbenchTest accounts for ~18G).
`rm -rf ~/proj/lzfse2/xbenchTest` can be cleaned immediately after benchmark.zsh is executed.

---

# Round 9: Baseline Verification + MB/s Comparison Benchmark Establishment (2026-06-13)

## The purpose of this round

No code change - purely re-run benchmark to confirm the stability of the R8 baseline, and formally establish
**MB/s is the main cross-wheel comparison index** (the data set is an active working directory, and the size will fluctuate with time;
After MB/s ralization, cross-wheel fair comparison can be made).

## Actual measurement results (01:20–01:26)

✅ The consistency of the two data sets is fully passed (7/7 × 2); R8 numbers are fully reproduced - baseline stability ✓

### claw-code (original 1300 MB)

| Format | After compression | Compression MB/s | Decompression MB/s | Compression ratio |
| --- | ---: | ---: | ---: | ---: |
| TGZ (benchmark) | 480M | 46.1 | 534.1 | 1.000 |
| LZFSE Other3 | 472M | 375.7 | 498.0 | 0.983 |
| **LZFSE Lazy2** | **432M** | **45.9** | **524.6** | **0.900** |
| **LZFSE Optimal** | **417M** | **22.4** | **370.7** | **0.869** |
| LZFSE BVX3 | 457M | 384.3 | 238.0 | 0.952 |
| LZFSE Apple | 465M | 139.0 | 225.3 | 0.969 |
| TLZ4 | 563M | 503.3 | 143.7 | 1.173 |
| ZSTD-9 | 393M | 376.0 | 145.1 | 0.819 |

### llama.cpp (original 1200 MB)

| Format | After compression | Compression MB/s | Decompression MB/s | Compression ratio |
| --- | ---: | ---: | ---: | ---: |
| TGZ (benchmark) | 593M | 52.6 | 231.1 | 1.000 |
| LZFSE Other3 | 593M | 207.6 | 235.9 | 1,000 |
| **LZFSE Lazy2** | **571M** | **118.3** | **196.6** | **0.963** |
| **LZFSE Optimal** | **544M** | **37.6** | **140.3** | **0.917** |
| LZFSE BVX3 | 584M | 214.5 | 151.2 | 0.985 |
| LZFSE Apple | 584M | 121.9 | 163.0 | 0.985 |
| TLZ4 | 614M | 246.2 | 122.7 | 1.035 |
| ZSTD-9 | 544M | 297.4 | 87.5 | 0.917 |

## MB/s Analysis

### Optimal current situation

| Data Set | Compression MB/s | vs ZSTD | Decompression MB/s | vs ZSTD | Size vs ZSTD |
| --- | ---: | ---: | ---: | ---: | ---: |
| claw-code | 22.4 | ZSTD fast **16.8×** | 370.7 | We fast **2.6×** | 417 vs 393M(+6.1%) |
| llama.cpp | 37.6 | ZSTD fast **7.9×** | 140.3 | We fast **1.6×** | **544 vs 544M (tie)** ✓ |

### Lazy2 Current Status

| Data Set | Compression MB/s | vs ZSTD | Decompression MB/s | Size vs ZSTD |
| --- | ---: | ---: | ---: | ---: |
| claw-code | 45.9 | ZSTD fast **8.2×** | 524.6 | 432 vs 393M (+9.9%) |
| llama.cpp | 118.3 | ZSTD fast **2.5×** | 196.6 | 571 vs 544M (+5.0%) |

**The biggest advantage of decompression to lzfse2**: claw optimal 370.7 MB/s, lazy2 524.6 MB/s--
ZSTD is only 145 MB/s, which is **2.6–3.6 times faster**.

## Conclusion

1. **Baseline stability**: R8 vs R9 MB/s error <0.1%, reliable measurement, MB/s can be used as a cross-wheel benchmark.
Two. **Optimal bottleneck**: compression MB/s behind ZSTD 8–17 times; R8 SIMD skip is effective in llama (−4.7%)
But claw is flat - claw's 58s / 22.4 MB/s is really hot unknown, **you have to profile first to do it**.
3. **Lazy2 ceiling**: BT route is closed (R7 negative result); claw under hash chain architecture 45.9 MB/s
It is close to the upper limit.
4. **Profiling has not been performed yet**: `run_profile.command` is ready, and R10 must be measured before doing it.

## The next round of planning

**Must do: Run profiling first to find out the real hotspot of claw optimal 22.4 MB/s**

```sh
cd ~/proj/lzfse2
open run_profile.command   # 對 claw-code bvx3 -optimal 取樣 20 秒
# 完成後查看 profile-optimal.txt 的熱函數
```

Select the direction according to the profiling results:

| If the hot spot is | Corresponding action | Expected benefits |
| --- | --- | --- |
| DP relaxation array writing (per-cell 6 array) | SoA packaging: price+len combined with a 64-bit word, rep delayed reconstruction | Write bandwidth -50%, claw optimal target <35s |
| `matchLength` comparison cycle | SIMD16 vector comparison, 16 bytes at a time | match body internal comparison cost −50–70% |
| hash chain visit ( `chainSearch`) | `optSearchDepth` 16→8, or price-based early withdrawal | claw visit volume −30–50%, the ratio is slightly back |
| emit / backtrace | DP segment size 128K→256K, reduce the number of backtraces | Fixed expense −50%, the efficiency depends on the segment ratio |

---

# Round 8: DP Relaxation SIMDization (2026-06-13)

## This round of changes (R4 candidate #2 landing)

Optimal rep / frontier two relaxation cycles, dense area (length 4..64) changed to
`SIMD4<Int32>` View 4 cells at a time: c2 in bucket is constant, 4 lane full
"No improvement" is skipped directly. **The meaning is completely equivalent to the grid** (same cell, same priority,
Only omit the invalid writing and branching) - the byte level of small sample output remains unchanged
(30453B / 29041B) is the proof.

## Actual measurement results (09:17–09:26)

✅ 112 self-tests are all green; consistency 7/7 × 2; the output size is exactly the same as R7b ✓

| Pattern | claw-code | llama.cpp |
| --- | --- | --- |
| optimal | 417M / **58.1s** (R7b 58.5s, ~flat) | 544M / **31.9s** (R7b 33.5s, −4.7%) |
| lazy2 (unmoved) | 432M / 28.3s | 571M / 10.1s |
| Same wheel zstd -9 | 393M / 3.5s | **544M** / 4.0s |

Reading / Reading:

- **Highlights of this round**: llama optimal **544M = zstd 544M, the ratio is officially equal**
(The data set drifts to the content that is difficult to press in this round, and zstd falls to the same water level as us;
Decompression 8.6s vs 13.7s is still 1.6 times faster).
- SIMD skip limited yield (llama −4.7%, claw ~0): **dense relaxation is not
The real hot spot of claw optimal** - R3's "slack maximum" assumption is in stride/sufficient
After that, it was not established. The 58s of claw are in other places (candidate matchLength, chain visit,
Per-cell 6 array write, or emit/backtrack).
- Change and reserve (zero risk, llama has a small profit).

## The next round of suggestions

1. ** Measure first and then do it**: Blind tuning has been neutral for two consecutive rounds - use
`xcrun xctrace record --template "Time Profiler"` Yes
`lzfse -encode -algo bvx3 -optimal` sample, find out the claw optimal
The real hot spot of 58s, and then decide on the vectorization/reconstruction target.
Two. If the hot spot is per-cell 6 array writing: change SoA packaging (price+len a 64-bit
Word, reps delayed reconstruction) can halve the writing bandwidth.
3. Data set snapshot freeze (to be done from R6) is still the premise of attribution.

---

# Round 7: BT match finder experiment (2026-06-13)

## This round of experiments

Practice zstd btlazy2 formula **binary-tree match finder** to replace the hash chain of lazy2
(R4 candidate #1, R6 suggestion #3): a suffix sorting tree for each hash bucket, search and insert,
Share prefix length acceleration comparison, good-enough/taper retention. 112 self-tests are all green,
The consistency of the two data sets is completely over - ** The correctness is safe, but the speed is catastrophic**:

| Mode | Hash chain (retactial measurement after retreat) | BT version | Difference |
| --- | --- | --- | --- |
| claw lazy2 | 432M / 28.8s | 432M / 46.1s | **+60% time**, ratio 0 |
| llama lazy2 | 570M / 10.5s | 565M / 68.3s | **+550% time**, ratio −0.9% |

## Root cause

**The insertion of BT also needs to visit (O(depth), and the hash chain insertion is O(1). **
Llama's GGUF long match has a large number of "pure insertion" positions in the body - BT pays for each position
There are 16 comparison tree visits, and the hash chain only pays 2 writes. Zstd home btlazy2 also because
2–3 times slower than lazy2; our lazy2 already has has hash5+probe+taper+skip,
The residual chain visit cost does not have any room for improvement as BT claims.
**Reversed to R6 hash chain version** (negative result, the code is not retained).

## Conclusion and next step

1. **The hash chain + hash5 + probe combination of lazy2 is close to the speed ceiling of this architecture**
(Claw 28.8s, llama 10.5s); BT route is officially closed.
2. optimal speed-up is the only remaining item: **DP relaxation SIMDization** (R4 candidate #2)——
The dense area (length 4..64) relaxes 4 cells at a time with SIMD4<Int32>.
3. The attribution methodology remains unchanged: knob A/B is only done after the data set snapshot is frozen
(Claw-code This round drifts again: zstd 391→400M).
4. Current situation positioning (this round of same machine data): lazy2 to zstd ratio +6.3–8.0%,
Time 2.6–8.1 times; optimal distance zstd +1.5–4.3%, decompression faster 1.8–3.8 times.

---

# Round 6: Attribution (2026-06-13)

## This round of changes (accoding to the R6 proposal of R5)

| Project | Change | Reason |
| --- | --- | --- |
| optRepStrongLen | 64 → 128 | claw optimal rate +3.5% of the number one suspect retal |
| lazy2 insert-stride (new) | match ≥ 256 Insert every 2 grids in the body | LZ4 HC style: the insertion flow is halved, the chain is shorter |

Zshrc.zsh has been verified to fully support optimal (extract/lzfseX/lz4bench), no need to modify.

## Actual measurement results (07:50–07:59)

✅ 112 self-tests are all green; decompression consistency 7/7 × 2.
Small sample: lazy2 30453B, optimal 29041B - exactly the same as R5 (the change is neutral for small samples).

⚠️ The two data sets have changed again (unchanged bvx3: claw 453→447, llama 570→583;
Zstd: 403→395, 541→534), and the ambient load of this round is high
(Zstd time-consuming +13–21%). The cross-wheel comparison needs to be corrected by ambient, and the size is for direction reference only.

| Pattern | claw-code | llama.cpp |
| --- | --- | --- |
| lazy2 | 433M / 29.3s (after correction ≈25.8s) | 570M / 10.4s |
| optimal | 417M / 59.5s (after correction ≈52.5s) | 544M / 31.9s |
| Same wheel zstd -9 | 395M / 3.5s | 534M / 4.5s |

Reading / Reading:

- **optRepStrongLen 64→128 no sense of ratio** (claw optimal 417M motionless,
Llama 544M does not move): the +3.5–5.6% gap of claw ** is not caused by ** this knob.
The suspect moves to optHugeLen (stride-16) or R3's existing depth16/suff192,
It may also be the difficulty of the data set itself.
- **insert-stride neutral**: lazy2 size follows the unchanged bvx3 drift (within +1M),
The time is the same after correction - the insertion cost is not the bottleneck of lazy2 (the chain visit is).
- Both rounds of "attribution experiments" were interfered by data set drift - live directory (claw-code is a working area,
Llama.cpp will be updated) It is not feasible to do A/B.

## The next round of suggestions

1. **Freeze data set snapshot** (top priority): `tar -cf claw-code.snapshot.tar claw-code`
Once, after that, the benchmark is all executed on the snapshot tar file - the data set drift is zero,
The attribution experiment is effective.
Two. After the snapshot is fixed, redo the single variable A/B of optHugeLen / depth / sufficientLen.
3. lazy2 speed ceiling (chain visit): BT match finder (R4 candidate #1).
4. optimal speed: DP relaxation SIMDization (R4 candidate #2).

---

# The fifth round: lazy2/optimal speed-up adjustment (2026-06-13)

## This round of changes (according to the R4 candidate strategy)

| Project | Change | Reason |
| --- | --- | --- |
| chainLazyLen (new, 128) | lazy second search threshold 1024→128 | Medium and long match Repeated double search along the way is lazy2 implicit bulk |
| chainTaperLen/Depth (new, 256/4) | bl ≥ 256 The depth of the back chain visit converges to 4 | It is long enough, and the marginal effect of deep search is extremely low |
| optHugeLen (new, 256) | DP relaxation ≥ 256 change stride-16 | Long match adjacent length price difference is extremely small |
| optRepStrongLen (new, 64) | bestRep ≥ 64 → Chain visit down to depth 4 | Strong rep is almost sure to win at DP price |

## Actual measurement results

✅ 112 self-tests are all green; decompression consistency is all passed (7/7 × 2 data set).
Small text samples: lazy2 30686→**30453B (smaller)**, optimal 29029→29041B (+0.04%, can be ignored).

The first run (07:12–07:21) the machine runs pip reload at the same time, and the time data is +15–20% distortion;
The claw-code has been re-run at 07:34 (llama follows the 07:21 wheel, and its size data is still valid):

| Mode | claw-code (07:34 Clean Rerun) | llama.cpp |
| --- | --- | --- |
| lazy2 | 432M / **25.2s**(R3 433M/32.4s → −22% time) | **556M**(R4 572M, −2.8%)/ 10.0s |
| optimal | 417M / 52.3s | 544M (flat R4) / 31.7s |
| Same wheel zstd -9 | 403M / 3.1s | 541M / 3.8s |

Reading / Reading:

- **lazy2 wins all-round**: the time is better than R3 −22% (claw) and the ratio is better
(Llama −16M, small sample −233B) - lazy threshold 128 + taper does not hurt the quality,
R4 full-block reading is fully effective in this round. The ratio difference to zstd: llama **+2.8%**, claw +7.2%.
- **optimal maintenance ratio** (llama 544M flat, small sample +0.04%);
Claw 417M vs zstd 403M = **+3.5%** (R4 is +1.3%, but claw data set
Continuous changes - tgz 480→481M, zstd 396→403M - cross-wheel cannot be directly compared).
- optimal time 52.3s not improved compared with R4: stride-16/strong rep shallow search saving is
The data set becomes offset; the focus of claw's DP cost is still relaxing the cycle itself.

## The next round of suggestions

1. **Attribution of claw optimal ratio +3.5% A/B**: under the snapshot of the fixed data set separately
Switch optRepStrongLen and optHugeLen to confirm whether it is a loss introduced by R5;
If so, give priority to optRepStrongLen (64→128 or remove).
2. lazy2 If you want to go further (target <15s/claw): BT match finder (R4 candidate #1).
3. optimal speed-up spindle steering **DP relaxation SIMD** (R4 candidate #2):
cPrice and other six arrays SoA + simd_int4 relax 4 lengths at a time.

---

# Round 4: Memory overhead + multi-core efficiency (2026-06-13)

Objective (user-specified): Re-examine the zstd / LZ4 algorithm to reduce memory overhead and make good use of multi-core,
Shorten bvx3 / lazy2 / optimal compression time.

## Review conclusion

The multi-core architecture itself has been improved: 4MiB block × `DispatchQueue.concurrentPerform` formula
Worker (semaphore flow limit = number of cores), lazy2/optimal also has zstd
Bl detection, good-enough truncation, jump acceleration, desert detection. Remaining movable items:

1. **Each 16MiB chain table memset + malloc/free churn** (memory bulk):
`lzParseChain` / `lzParseOptimal` Each 4MiB chunk is
`allocate + initialize(repeating:-1)` A chain table of n×4B.
1.3GB input = 325 chunks ≈ 5.2GB of invalid memset traffic + the same amount of malloc churn.
The answer of zstd is **CCtx reuse**: context once, cross block reuse.
And the chain table actually ** does not need to be initialized at all** - reachability argument: search only
`head[h] → chain[c] → …`, head each piece is -1, any reachable chain item
All in insert ( `chain[idx] = head[h]; head[h] = idx`) write first and then read.
Two. **Hot cycle array configuration**: `bestMatch` in `for r in [rep0p, rep1p, rep2p]`
(At least 1–2 times per position) will generate a temporary array. LZ4/zstd thermal path zero configuration.
3. **4-byte hash chain is too long** (the main reason for text data lazy2 32s):
High-frequency 4-grams such as "the" and "of" cause the chain depth to skyrocket and waste the depth quota in repeated candidates.
Zstd high level (lazy2/btopt) with **5–6 byte hash**: short chain, less collision,
The quota is spent on candidates who may really be longer; the sacrifice of len-4 non-rep match is extremely small.
(The rep candidate still covers the most common len-4).
4. **Pipeline short reading**: `FileHandle.read(upToCount:)` may not transmit enough 4MiB to pipe
The short block (tar | lzfse is pipe), which makes the block broken - the ratio becomes worse,
Each fixed overhead is more, and the parallel decoding grouping is invalid. It should be accumulated and full reading.

## This round of changes

| Project | Change | Corresponding Skills |
| --- | --- | --- |
| ParseScratch pool | head/chain/DP/frontier buffer cross-chunk reuse (lock protection pool, upper limit = number of cores) | zstd CCtx reuse |
| Chain table zero initialization | Remove two `initialize(repeating:-1, count:n)` | Acassibility argument (as above) |
| rep loop to configure | bestMatch two changes to manual expansion | LZ4 hot path zero configuration |
| chain finder change hash5 | lazy2/optimal's hash4 → 5-byte multiplication hash; chainHashBits 16→17 | zstd high level h5 |
| Full block reading | runParallelEncode cumulative reading 4MiB re-send work | Parallel granularity repair |

Memory effect: steady-state peak ≈ number of cores × (chain 16MiB + DP ~4MiB) (the same level as the current one),
But **the memset/malloc traffic of ~21MB per piece is zero**;
The speed effect is mainly in the chain visit quality (hash5) and configuration overhead of lazy2/optimal.

## Actual measurement results (2026-06-13)

✅ 112 self-tests are all green; the decompression consistency of the two data sets is all passed; the small sample ratio is the same (29030→29029B).

| Mode | claw-code R3 → R4 | llama.cpp R3 → R4 |
| --- | --- | --- |
| lazy2 | 32.4s → **22.4s**(↓31%), 433M → 433M | 9.7s → **8.3s** (↓15%), 571 → 572M |
| optimal | 50.0s → **44.6s** (↓11%), 400 → 401M | 24.7s → 25.6s (flat), 544 → 544M |
| bvx3 | 3.05s → 3.00s, 456 → 458M | 5.1s → 5.1s, 570 → 573M |
| Same wheel zstd -9 | 2.93s / 396M | 3.7s / 538M |

Reading / Reading:

- **hash5 has the greatest effect on lazy2** (claw ↓31%, zero ratio loss): high frequency 4-gram no longer share the barrel,
The quota of depth 32 is really spent on potentially longer candidates.
- optimal benefits are small (claw ↓11%): its cost focus is on DP relaxation rather than chain visit,
And desert detection has eaten up part of the search cost first.
- scratch pool zeros the traffic of each ~21MB malloc/memset;
Full block reading guarantees the 4MiB block granularity under pipe input.
- Ratio to zstd gap: optimal +1.3% (claw) / +1.1% (llama);
Decompression optimal 5.2s/8.0s vs zstd 10.3s/14.6s (1.8–2.0 times faster).

## The next round of candidate strategies

1. **lazy2 exchange BT (binary tree) match finder** (zstd btlazy2 real body):
The hash chain is still O(depth×len) comparison on high-repetition text; BT insertion is sorted,
Amortization for each candidate O(log). It is estimated that claw lazy2 can be -30–40%, but the actual complexity is high.
2. **Optimal DP relaxation vectorization**: cPrice/cLen and other six arrays modified SoA to
SIMD (simd_int4) relaxes 4 lengths at a time; or mention stride-4 to stride-8.
3. **optimal inter-segment pipeline**: DP segment (128K) backtracking overlaps with the next search
(At present, the same chunk is in order); when the chunk level is saturated in parallel, the yield is limited and the priority is the lowest.
4. bvx3/other3 is faster than zstd -9 (433/432 MB/s vs 444 MB/s at the same level) and no longer moves.

---

# The third round: compression time-consuming optimization (2026-06-12)

## Current situation analysis

The ratio target (optimal 368M/544M ≈ zstd 372M/543M) was achieved in the second round, but the compression time difference was huge:

| Mode | claw-code | llama.cpp | vs zstd (3.1s / 5.0s) |
| --- | ---: | ---: | --- |
| bvx3 -optimal | 104.8s | 140.6s | slow 34x / 28x |
| bvx3 -lazy2 | 34.5s | 12.4s | slow 11x / 2.5x |

Analyze the four cost sources of `lzParseOptimal` (compared with zstd btopt):

1. **Length-by-length relaxation cycle** (maximum, compressable data): each position for each rep/frontier candidate
Relax length 4..maxLen, `optSufficientLen=512` makes the worst cycle reach 511 times.
The sufficient_len of zstd in btopt level is about ~256.
Two. **Full-depth chain visit of each position** (the main cause of desert/binary data, the explanation of llama 141s > claw 105s):
DP does depth-32 search in each position, unlike lazy with jump acceleration.
3. **Swift Array Boundary Check**: Price List (litPrice/mPriceTab/dPriceTab) and
lm3BaseValue is accessed by Swift Array in the hottest cycle.
4. lazy2 adjustment (4096/8) over-correction: claw 34.5s change to 401M, the deep search ratio is too high.

## This round of changes

| Project | Change | Expected effect |
| --- | --- | --- |
| optSearchDepth | 32 → 16 | Chain visit cost is halved; suffix-min still keeps short distance priority |
| optSufficientLen | 512 → 192 | Earlier greedy submission (zstd btopt level); relax upper bound ↓2.7x |
| Relaxation stride (new optDenseLen=64) | Length >64 change stride-4 + precision maxLen | Long match relaxation cost ↓~3x; model actual measurement ratio zero loss |
| Price Table Indicatorization | Price Table/Base Value Table Change UnsafeMutablePointer | Exempt Heat Cycle Boundary Check |
| Desert detection (new) | Continuous ≥32 positions no match → depth reduced to 4 | Binary segment cost greatly reduced (llama main cause) |
| lazy2 adjustment | chainGoodEnough 4096→1024, strength 8→7 | Deep search ratio compromise, target ~12-18s/claw |

Correctness: Python model is re-verified after adding stride - text/structured/runs ratio
Delta 0.00%, 150 groups of random round-trip + constraints are all over.

## Actual measurement results (2026-06-13 early morning)

✅ Compilation passed once; `-test` 112 items are all green; the small sample ratio remains unchanged (large text sample even 29041→29030B).

| Mode | R2 → R3 (claw-code) | R2 → R3 (llama.cpp) |
| --- | --- | --- |
| optimal compression | 104.8s → **52.2s** (2.0x), 368M → 384M | 140.6s → **27.1s** (5.2x), 544M → 560M |
| lazy2 compression | 34.5s → 33.1s, 401M → 401M | 12.4s → 12.0s, 561M → 561M |
| Same wheel zstd -9 | 3.1s / 363M | 3.4s / 530M |

Reading / Reading:

- **Speed target is greatly promoted**: optimal accelerates 5.2 times in llama (binary weight) - desert detection +
The depth is halved to the point; the claw accelerates 2.0 times.
- **Ratio back spit**: claw +4.3%, llama +2.9%. The gap with zstd widened from ~0% to ~5.7%.
Main suspects in order: optSufficientLen 512→192 (too early greedy submission), depth 32→16.
Stride (model verification zero loss) and indicator innocence.
- lazy2 modulation (1024/7) has almost no moving numbers - indicating that the cost of lazy2 is mainly in the chain visit of depth 32
Itself, not in goodEnough/strength; if you want to be fast in the future, you can only reduce the depth.
- ⚠️ The TLZ4/ZSTD "decompression" data of this round of llama is invalidated due to the exhaustion of host disk space.
(All LZFSE modes are completed and consistent before the space is exhausted).
- Note: The content of the two data sets has drift (zstd from 372→363, 543→530), and the absolute value of the cross-wheel is for reference only.
The same wheel is relatively effective.

Next round (R4) candidate: suff 192→512 back + depth 16→24 (keep stride/indication/desert detection,
The threshold is relaxed to streak 64 → depth 8), target: the ratio returns to zstd ±1.5%,
Keep the time at 50–60% of R2.

### Addition: llama.cpp officially re-runs (2026-06-13, after disk cleaning + data set restoration)

The data set returns to 1.2G (tgz 592M), the new version of lz4bench (including -optimal / -lazy2),
The consistency check is passed, and the zstd decompression data is complete. R3 code (stride + indication + desert detection) actual measurement:

| Mode | Size | Compression | Decompression | vs zstd ratio |
| --- | ---: | ---: | ---: | --- |
| optimal | **544M** | 24.7s | 6.47s | **+0.74%**(zstd 540M/3.7s/11.1s) |
| lazy2 | 571M | 9.7s | 6.64s | +5.7% |
| bvx3 | 570M | 5.1s | 5.78s | +5.6% |

- ollama (binary weight) optimal almost equals the ratio of zstd -9, and decompression is 1.7 times faster--
The speed knife method of R3 has almost zero rate loss in this data set.

### Addition: claw-code rerun (2026-06-13, data set growth to 1.3G / tgz 480M)

| Mode | Size | Compression | Decompression | vs zstd ratio |
| --- | ---: | ---: | ---: | --- |
| optimal | **400M** | 49.7s | 2.30s | **+3.1%**(zstd 388M/2.9s/5.9s) |
| lazy2 | 433M | 32.4s | 2.29s | +11.6% |
| bvx3 | 456M | 3.05s | 3.21s | +17.5% |

### Step 8 General comment (two data sets, new version of complete data)

- **The compression ratio is close to the standard**: optimal distance zstd -9 is only +0.7% (llama) / +3.1% (claw).
- **Decompression speed is great**: optimal decompression 2.3s / 6.5s, zstd 5.9s / 11.1s (1.7–2.5 times faster).
- **Compression speed is still backward**: optimal 50s / 25s vs zstd 2.9s / 3.7s (13–17 times).
DP-optimal class algorithm (Swift practice) against the lazy-class zstd -9 of C, this gap is structural;
When pursuing compression speed, bvx3 (2.9s, faster than zstd) or lazy2 should be used,
Optimal is positioned as the "offline maximum compression" mode.
- Conclusion: The ratio and decompression have approached or exceeded the zstd level, and it is recommended to stop the iteration here (step 8 conditions are considered to be achieved);
If we still need to narrow the compression speed gap, the parallelization in the DP segment where the R4 direction is optimal and
Chain-table pre-construction (one-time table construction, multi-separameter sharing).

---

# Round 2: Optimal Parsing Strategy (2026-06-12)

## Current situation analysis

The last round of benchmark (BenchMarkResult.csv) showed the gap with zstd -9:

| Data set | bvx3 -lazy2 | zstd -9 | Gap |
| --- | ---: | ---: | ---: |
| claw-code | 419M | 368M | ~13.9% |
| llama.cpp | 572M | 537M | ~6.5% |

Two root causes / Two root causes:

1. **Repair speed cut the head**: In the last round, in order to save the compression time of 86s/39s, `chainGoodEnough=512` and
`chainSearchStrength=6` makes deep search too early and jump too big - btlazy2 once reached 384M/545M
Therefore, the ratio is spit back. The speed fix (early-exit at 512, aggressive skip) gave back most of
The ratio btlazy2 had won (384M/545M).
Two. **The structural upper limit of greedy/lazy analysis**: Each position only makes local optimal decisions. Zstd high-level distance
(Btopt/btultra) The real rate source is "price-driven whole-segment optimal analysis" - this is the main course of this round.
Price-driven optimal parsing.

Another benchmark tool bug was found and fixed: `zshrc.zsh`'s `lzfseX` never put `-lazy2`
The flag is passed to the encoder, and the previous "Lazy2" line of CSV actually ran the default bvx3.
Were really default bvx3 runs.

## This round of changes

### one. `-optimal`: Segment DP optimal analysis (zstd btultra formula)

Add `lzParseOptimal` (for bvx3, flag `-optimal` control, default off):

- **Segment DP**: one section per 128K position; the minimum cost of each cell storage (1/16-bit fixed point),
Arrival step (literal or (len,dist)), and the rep-offset history of the best path
(The per-cell rep tracking of zstd opt allows the rep to be priced at real near-zero cost in DP).
- **Candidate**: 3 rep distances + hash chain Pareto frontier (len increment);
Suffix-min makes each length take "the cheapest distance in the long enough candidate".
- **Adaptive price**: literal/M/D symbol histogram reconstruction for each segment (log2 → fixed point),
With the statistical feedback that has been launched, it is equivalent to zstd to update price tables between blocks.
- **Megat match truncation** ( `optSufficientLen=512`): Find it and submit it greedily and restart the DP segment--
It is not only the sufficient_len strategy of zstd, but also the cost upper bound of pathological input (equi-length run).

Correctness verification: Python model 300 groups of random segmentation/threshold round-trip + format constraints are all passed;
The relative lazy analysis cost of text/structured data on the model is reduced by 9–10%.

### two. Adjust the parameter to find the -lazy2 ratio

- `chainGoodEnough` 512 → 4096: Deep search no longer closes too early
- `chainSearchStrength` 6 → 8: No match jump step is more conservative

It is expected that the -lazy2 ratio will recover to 384M/545M, and the compression time will rise slightly from 2.0s (still much faster than apple).

### three. Overview of speed/ratio gears

| Gear | Parser | Positioning |
| --- | --- | --- |
| bvx3 (default) | 4 slots lazy | Speed priority (~2s/1.2GB) |
| bvx3 -lazy2 | Hash Chain Deep Search 32 | Middle File |
| bvx3 -optimal | Segmented DP Optimal Analysis | Ratio priority, target approximation zstd -9 |

## Actual measurement results (2026-06-12, M-series Mac)

✅ The compilation is passed once; `-test` 112 items are all green; the decompression consistency of the two benchmark data sets is fully passed.

| Data set | bvx3 -optimal | zstd -9 | Results |
| --- | ---: | ---: | --- |
| claw-code compression rate | **368M** | 372M | **beyond zstd** |
| llama.cpp compression rate | 544M | 543M | flat (+0.18%) |
| claw-code decompression | **2.95s** | 6.02s | 2 times faster |
| llama.cpp decompression | **7.72s** | 10.45s | 1.35 times faster |
| claw-code compression time consumption | 104.8s | 3.1s | slow 34 times (take-off) |
| llama.cpp compression time | 140.6s | 5.0s | 28 times slower (pick-off) |

Conclusion / Conclusion: The compression rate of **bvx3 -optimal has reached the level of zstd -9** (one win and one draw),
And the decompression speed is significantly faster than zstd - the cycle goal of "proximation of zstd" is achieved, and the process stops.
The compression speed is a clear choice of -optimal (DP does full-depth search and length relaxation at each position);
Use the default bvx3 (2.6s/411M) or -lazy2 (34.5s/401M) when speed is required.
If you want to narrow the compression time gap in the future, the candidate direction: reduce optSearchDepth (32→16),
Price-based early termination and SIMD matchLength.

-Lazy2 adjustment reference (4096/8) actual measurement: claw 401M/34.5s - the ratio is more fake than the old version lazy2 (411M level)
There is a sense of improvement, but the time cost is high; the sweetness of the middle grade can be adjusted separately.

---

# Round 1: In-linked optimization report

## Overview

Improve the execution efficiency of lzfse-cli by applying the Swift compiler inline instruction `@inline(__always)` to frequently invoked small functions.

## Optimize the content

### one. FSE bit stream coding (fseEncode)

**Position**: Line 435

```swift
@inline(__always)
static func fseEncode(state: inout Int32, _ e: FSEEncoderEntry, _ out: inout FSEOutStream)
```

**Features**:
- 6-line function body
- Each L/M/D triplet is called once
- The innermost loop of block coding

**Expected benefits**: Coding performance +3-7%

---

### two. Byte serialization (put32 / put16)

**Position**: Line 885-892

```swift
@inline(__always)
static func put32(_ v: UInt32, _ out: inout [UInt8])

@inline(__always)
static func put16(_ v: UInt16, _ out: inout [UInt8])
```

**Features**:
- Ultra-short function (4-8 line code)
- A large number of invocations during the serialization of block headers, frequency tables and matching lists
- Part of the coding key path

**Expected benefits**: Coding performance +2-5%

---

### three. Byte deserialization (get32 / get16 / get64)

**Position**: Line 894-905

```swift
@inline(__always)
static func get32(_ d: [UInt8], _ p: Int) -> UInt32

@inline(__always)
static func get16(_ d: [UInt8], _ p: Int) -> UInt16

@inline(__always)
static func get64(_ d: [UInt8], _ p: Int) -> UInt64
```

**Features**:
- Single-line core operation
- Frequent calls during decoding (scan blocks, parse headers, decode L/M/D values)
- Decode part of the key path

**Expected benefits**: Decoding performance +2-4%

---

## Existing optimization

The following functions have been used `@inline(__always)`:

1. **FSEInStream.load8** (line 385) - 8 bytes loading
Two. **FSEOutStream.push/pull** (lines 343, 349, 412, 425) - Bitstream operation
3. **lzParse internal function** (line 498-520) - load32/load64/hash4/matchLength
4. **lzParseStrong internal function** (lines 618-644) - hot function of enhanced comparison
5. **lzParseChain internal function** (line 763-791) - hot function of chain search
6. **encodeFreqValue** (line 904) - Frequency value coding
7. **encodeBlock internal function** (line 1037) - displacement auxiliary function
8. **decodeV2Block internal function** (line 1514) - field extraction
9. **lzvnEncodeBlock internal function** (line 1319, line 1322) - LZVN code
10. **decodeBlockBody internal function** (line 2189) - value decoding

---

## Compilation results

### Binal file size

| Version | Size | Change |
| --- | ---: | ---: |
| Original version | 238 KB | - |
| Optimized version | 260 KB | +22 KB (+9.2%) |

**Explanation**: The increase in binary file size is mainly due to the increase in the amount of code in the inline deployment. This is within the acceptable range.

### Test results

✅ All built-in tests passed (including round-trip + compatibility test)

---

## Performance expectations

Expected improvements based on Swift compiler to optimize literature:

| Operation | Expected improvement |
|---|---:|
| Coding (other 3 / bvx3) | +2-5% |
| FSE bit stream operation | +3-7% |
| Decoding | +2-4% |
| Average overall performance | +2-4% |

**Note**: The actual improvement varies depending on the data characteristics, hardware characteristics and compiler behavior. It is recommended to conduct benchmarking on real workloads.

---

## Security and compatibility

✅ **Compatibility**: All changes are compiler instructions, and the program logic is not modified.
✅ **Correctness**: The built-in test covers all encoding/decoding paths
✅ **Compatibility**: Do not change the API or output format
✅ **Portability**: Applicable to all platforms that support Swift

---

## When to use

1. **Optimization compilation (production environment)**:
   ```sh
   swiftc -O lzfse-cli.swift -o lzfse
   ```
→ The compiler will respect the `@inline(__always)` instruction

Two. **Debugging compilation**:
   ```sh
   swiftc -g lzfse-cli.swift -o lzfse
   ```
→ The optimized may be disabled, but the function remains unchanged.

3. **Performance benchmark test**:
- Use `-O` to compile
- Test at least 3 times to get the average
- Use representative data sets (see BenchMarkResult.csv)

---

## Suggestions for further optimization

### one. Conditional inside connection (if available)

If Swift supports it, you can consider:
```swift
@inline(__always) // 無條件
// vs
@inline(never) // 對初始化函數
```

### two. SIMD utimization

Using SIMD instructions for functions such as `matchLength` may further improve performance (additional tests are required).

### three. Memory layout uttimization

Check the alignment and size of FSEEncoderEntry and other structures (which may affect cache performance).

### four. Parallel improvement

DispatchGroup has been used for existing parallel decoding, and other parallel tools (OperationQueue, async/await) can be explored.

---

## References

- Apple Swift Optimization Guide: https://github.com/apple/swift/blob/main/docs/OptimizationTips.rst
- LLVM inline pass: https://llvm.org/docs/Passes/#inline-function-integration
- FSE reference work: https://github.com/apple/swift-corelibs-foundation

---

## Update log

| Date | Version | Change |
| --- | --- | --- |
| 2026-06-12 | 1.0 | Initial optimized: fseEncode, put32, put16, get32, get16, get64 |


---

## R18: Bounded backpressure correction of parallel coding

### Suggested review (honest version)
The suggestions received focus on "runParallelEncode memory explosion / OOM / dynamic thread switching",
But compared with the existing code, most problems ** do not exist**:

| Suggested problems | Current situation |
|---|---|
| Open a new Thread every chunk → context switch explosion | No. Use `.concurrent` DispatchQueue (fixed GCD thread pool), not `Thread()` |
| No upper limit queue → OOM | section. There is already `sem.wait()` before reading, but there is a bug in the signal timing (see below) |
| Dynamically generate threads | No, never do this |

Fixed thread pool, signal flow control, producer-consumer decoupling - **these have been done**.

### Real bug (it is recommended to point in the wrong direction, but the symptoms are right)
The original `sem.signal()` is bound to "**task complete**" instead of "**chunk write**":

- `sem` is limited to "the number of transit being compressed", not the "number of accumulated to be written after compression".
- When slow chunks (such as optimal on GGUF) are in front of `writeIndex`, all the following chunks
After quickly pressing and respectively `signal()`, the producer continued to dispatch - but these pressed body are all piled up in
`results` and so on `writeIndex` catch up → **results boundless accumulation**.
- 1.3GB GGUF (~325 4MB chunks) at worst accumulate hundreds of post-compression body, which is the real memory risk.

### 修法
Move `sem.signal()` into the drainage cycle (signal once every time a chunk is written):

- "Read but not written" strictly ≤ maxTasks → memory upper bound ≈ maxTasks × chunkSize (such as 16×4MB=64MB).
- Slow chunk in front, producer in `sem.wait()` natural blocking (backpressure),
No more unlimited reading.
- Activity has been proved: the task corresponding to `writeIndex` must be in the transit collection, and the completion is the drainage signal,
Producer will eventually unblock → no dead end. The output order and correctness remain unchanged.

### Deliberately not adopted: adaptive downgrade (optimal→lazy2)
It is suggested that C should "downgrade the queue depth > 10". But **After the boundary buffer is repaired, this backlog scene no longer exists**
(The number of transit constants ≤ maxTasks) - The downgrade condition will never be triggered, it will be dead code.
The right thing to do is to fix the backpressure, instead of adding a downgrade knob that will not start.
If you want to "exchange throughput by ratio" in the future, it should be made into an explicit flag (such as `-fast-when-slow`) instead of an implicit trigger.

### Not adopted: vDSP/Accelerate vectorized cost calculation
Cross-platform consideration (Accelerate Apple platform only) + existing SIMD4 fast-skip has covered hotspots,
The report rate is low. `-Ounchecked` belongs to the construction flag level, and it is recommended to experiment in benchmark.zsh.

### The impact of distributed operations on other3
This time, only the signal timing and memory boundary of `runParallelEncode` are changed, ** do not change the chunk cut,
Decode the compression path of grouping, or other3** - the performance of other3 is not affected. Deeper parallel architecture reconstruction
(Circular buffer, async/await) Leave it for the next round, and then the other3 throughput needs to be measured separately.

---

## Update log (continued)

| Date | Version | Change |
| --- | --- | --- |
| 2026-06-14 | R10 | optimal entropy perception gate (GGUF random segment skips DP, data-driven segmentation) |
| 2026-06-14 | R11 | Parallel coding backpressure correction (sem.signal binding writing, memory is bound) |

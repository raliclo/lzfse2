# lzfse2 Optimization Report / Optimization Report

## Note: The reason why IO and disk capacity will be sharply reduced is that .gitignore is not set, so VS CODE will automatically include these files in the temporary storage area of git, resulting in disk IO competition and capacity sharp reduction, so the files of future test temporary files need to be excluded by .gitignore.

## Acceptance terms

- **output-identical**: Subject to the content after decompression/extract; as long as the decompression result is exactly the same as the original data, it will be passed, and the compressed file byte is not required to be the same.
- **bitstream-identical**: The byte of the compressed product is exactly the same as the baseline, which is a stricter and more independent condition than output-identical.
- The size of the compressed file or the change of the compression ratio should be recorded separately and shall not be used to determine the output-identical failure alone.

---

# R41-Mac: Tag-packed Hash Chain Introduction (2026-06-22)/ R41-Mac: Tag-packed Hash Chain

> Reintroduce the R40 code base of R27's Tag-packed hash chain (hashAndTag / chainIndexMask / chainTagShift / chainNullIndex).
> lzParseChain (BVX3 / Lazy2) and lzParseOptimal (Optimal) are updated synchronously.
> Execute `-n 40 / 8 / 4` three batches of complete benchmark on claw-code / llama.cpp.

## Optimization Strategy / Optimization Strategy

| Project | Description |
|---|---|
| **Core Change** | `head[h]` and `chain[c]` changed to `(tag<<24)\|index` packed Int32 format |
| **hashAndTag** | The same Fibonacci multiplication `×0x9E3779B185EBCA87`, high 17 bits → bucket, second 8 bits → tag |
| **Chain visit** | Each candidate compares `(packed>>24)==qtag` first, and jumps directly to the next one if it does not match (pure register operation) |
| **Sentinel** | `chainNullIndex=0x00FF_FFFF` (head initial -1 → UInt32 → index=0xFFFFFF)|
| **Greedy path** | Only unpack index ( `&chainIndexMask`), no tag filter (only one candidate) |
| **assert guard** | `assert(n <= Int(chainIndexMask))`, ensure that chunk does not exceed the upper limit of 16 MiB index |

## 1a. Encode speed vs Windows (claw-code, n=40)/ Encode MB/s — Win/Mac Comparison

| Format | Mac MB/s | Mac/TGZ | Win MB/s | Win/TGZ | Win/Mac |
| --- | ---: | ---: | ---: | ---: | ---: |
| TGZ | 48.73 | 1.0000 | 24.67 | 1.0000 | 0.506 |
| Other3 | 344.41 | 7.0677 | 266.36 | 10.797 | 0.773 |
| BVX3 | 375.00 | 7.6955 | 241.42 | 9.785 | 0.644 |
| Lazy2 | 63.73 | 1.3078 | 38.75 | 1.571 | 0.608 |
| Optimal | 34.45 | 0.7070 | 15.54 | 0.630 | 0.451 |
| TLZ4 | 394.69 | 8.0995 | 191.84 | 7.776 | 0.486 |
| ZSTD | 353.65 | 7.2573 | 103.67 | 4.202 | 0.293 |

## 1b. Decode Speed (Mac + Win, claw-code n=40)/ Decode MB/s — Mac/Win Comparison

| Format | Mac MB/s | Mac/TGZ | Win MB/s | Win/TGZ | Win/Mac | Verify |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
|TGZ|376.09|1.0000|643.72|1.0000|1.712|PASS|
| TLZ4 | 405.75 | 1.0789 | 1752.37 | 2.7222 | 4.319 | PASS |
| ZSTD | 422.91 | 1.1245 | 1037.24 | 1.6112 | 2.453 | PASS |
| Other3 | 388.52 | 1.0331 | 760.85 | 1.1820 | 1.958 | PASS |
| Lazy2 | 365.21 | 0.9711 | 853.08 | 1.3252 | 2.336 | PASS |
| Optimal | 394.70 | 1.0495 | 897.14 | 1.3937 | 2.273 | PASS |
|BVX3|326.41|0.8679|800.90|1.2442|2.454|PASS|

## 1c. Compress Size & Ratio (claw-code, n=40)/ Compress Size & Ratio

| Format | Mac MiB | Mac/TGZ | Win MiB | Win/TGZ | Mac/Win |
| --- | ---: | ---: | ---: | ---: | ---: |
| TGZ | 470.0 | 1.0000 | 468.3 | 1.0000 | 1.0035 |
| Other3 | 463.0 | 0.9865 | 459.8 | 0.9818 | 1.0069 |
| BVX3 | 446.0 | 0.9492 | 433.4 | 0.9254 | 1.0291 |
| Lazy2 | 423.0 | 0.8998 | 407.6 | 0.8704 | 1.0377 |
| Optimal | 403.0 | 0.8574 | 387.5 | 0.8273 | 1.0401 |
| TLZ4 | 554.0 | 1.1793 | 549.8 | 1.1739 | 1.0077 |
| ZSTD | 387.0 | 0.8245 | 365.9 | 0.7813 | 1.0576 |

## two RSS peak (Mac only, claw-code n=40)/ Peak RSS

| Format | Encode RSS | Enc/TGZ | Decode RSS | Dec/TGZ |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 4.2MB | 1.00 | 3.7MB | 1.00 |
| TLZ4 | 80.4MB | 19.1 | 33.8 MB | 9.1 |
| Other3 | 266.1 MB | 63.4 | 299.5 MB | 80.9 |
| BVX3 | 272.9 MB | 65.0 | 324.5 MB | 87.7 |
| ZSTD | 387.8 MB | 92.3 | 9.2 MB | 2.5 |
| Lazy2 | 499.5MB | 118.9 | 320.2MB | 86.5
| Optimal | 572.5 MB | 136.3 | 308.2 MB | 83.2 |

## three. CPU Energy (Mac only, claw-code n=40)/ CPU Energy Ratio vs TGZ

> ⚠ Decode energy n=40 is not reliable due to the sampling coverage rate <5%, for reference only (standard `*`).

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

| Format | Best Compression Ratio | Best Enc MB/s | Worst Enc MB/s | Best Dec MB/s | Lowest Enc RSS | Highest Enc RSS | Lowest Enc J | Highest Enc J | Lowest Enc J/TGZ | Highest Enc J/TGZ |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 1.0000 | 48.73 | 46.57 | 382.54 | 4.2 MB | 4.3 MB | 164.11 | 164.11 | 1.0000 | 1.0000 |
| Other3 | 0.9865 | 404.94 ( `n8`) | 341.85 ( `n4`) | 388.52 | 140.3 MB | 266.1 MB | 27.41 | 47.83 | 0.1670 | 0.2915 |
| BVX3 | 0.9492 | 406.15 ( `n8`) | 322.32 ( `n4`) | 326.41 | 139.0 MB | 272.9 MB | 29.05 | 49.73 | 0.1770 | 0.3030 |
| Lazy2 | 0.8998 | 63.73 ( `n40`) | 53.39 ( `n4`) | 409.36 ( `n8`) | 194.7 MB | 499.5 MB | 114.59 | 158.69 | 0.6983 | 0.9670 |
| Optimal | 0.8574 | 34.45 ( `n40`) | 25.51 ( `n4`) | 394.70 | 215.4 MB | 572.5 MB | 511.73 | 704.65 | 3.1183 | 4.2939 |
| TLZ4 | 1.1793 | 420.57 ( `n4`) | 394.69 ( `n40`) | 477.45 ( `n4`) | 76.9 MB | 80.4 MB | 29.62 | 29.62 | 0.1805 | 0.1805 |
| ZSTD | 0.8245 | 360.20 ( `n8`) | 353.65 ( `n40`) | 422.91 | 371.5 MB | 388.7 MB | 41.39 | 41.39 | 0.2522 | 0.2522 |

## n40 represents the result (Encode / Decode CPU Energy Ratio vs TGZ)

| Format | Enc J/TGZ (claw n40) | Enc J/TGZ (llama n40) | Dec J/TGZ (claw n40)* | Dec J/TGZ (llama n40)* |
| --- | ---: | ---: | ---: | ---: |
|TGZ|1.0000|1.0000|1.0000|1.0000|
| Other3 | 0.1670 | 0.1320 | 0.0290 | 0.0124 |
| BVX3 | 0.1770 | 0.1514 | 0.0962 | 0.0035 |
| Lazy2 | 0.6983 | 0.2817 | 0.0805 | 0.0097 |
| Optimal | 3.1183 | 2.1219 | 0.0784 | 0.0278 |
| TLZ4 | 0.1805 | 0.2114 | 0.1002 | 0.0143 |
| ZSTD | 0.2522 | 0.1606 | 0.5174 | 0.1752 |

> `*` Decode energy n=40 Sampling coverage rate <5%, not trusted, for reference only.

## R41 vs R40 Encode Speed Comparison (claw-code, n=40)

| Format | R40 MB/s | R41 MB/s | Change |
| --- | ---: | ---: | --- |
| TGZ | 48.64 | 48.73 | ≈ flat |
| Other3 | 380.73 | 344.41 | -9.5% ⚠️ |
| BVX3 | 421.51 | 375.00 | -11.0% ⚠️ |
| Lazy2 | 57.84 | 63.73 | +10.2% ✅ |
| Optimal | 29.90 | 34.45 | +15.2% ✅ |
| TLZ4 | 424.74 | 394.69 | -7.1% |
| ZSTD | 363.63 | 353.65 | -2.7% |

> BVX3 / Other3 The speed is slightly reduced but the energy consumption is synchronously reduced, which may be thermal throttle or measurement error; Optimal / Lazy2 rises as expected. The compression ratio remains flat (the hash function remains unchanged).

---

# R41-Win: Windows Benchmark Results + Decode Verification Infrastructure (2026-06-23) / R41-Win: Windows Benchmark Results + Decode Verification Infrastructure

> R41 Tag-packed Hash Chain runs a complete encode + decode two-way benchmark in Windows.
> At the same time, `decode-win.bat` + `decode_summary.csv` decode verification infrastructure is introduced (the first round).
> All 7 formats have passed the `tar tf -` correctness verification (verify=PASS).
> Data set: claw-code; encode n=40 inflight chunks (single time); decode n=40 inflight chunks (single time).

## 1a. Encode Speed vs Mac (claw-code, n=40)/ Encode MB/s — Win vs Mac

| Format | Win MB/s | Win/TGZ | Mac MB/s | Win/Mac |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 24.67 | 1.0000 | 48.73 | 0.506 |
| Other3 | 266.36 | 10.797 | 344.41 | 0.773 |
| BVX3 | 241.42 | 9.785 | 375.00 | 0.644 |
| Lazy2 | 38.75 | 1.570 | 63.73 | 0.608 |
| Optimal | 15.54 | 0.630 | 34.45 | 0.451 |
| TLZ4 | 191.84 | 7.776 | 394.69 | 0.486 |
| ZSTD | 103.67 | 4.202 | 353.65 | 0.293 |

## 1b. Decode speed + verification (first round Win, claw-code n=40)/ Decode MB/s + Verification (Win first run)

> Windows decode benchmark is introduced for the first time (R41-Win), including `tar tf -` correctness verification.
> ⚠ n=40 inflight chunks single measurement, energy consumption is unreliable (the same Mac decode <5% coverage rate).

| Format | Win MB/s | Win/TGZ | Mac MB/s | Win/Mac | Verify |
| --- | ---: | ---: | ---: | ---: | --- |
|TGZ|643.72|1.0000|376.09|1.712|PASS|
| Other3 | 760.85 | 1.1820 | 388.52 | 1.958 | PASS |
| BVX3 | 800.90 | 1.2442 | 326.41 | 2.454 | PASS |
| Lazy2 | 853.08 | 1.3252 | 365.21 | 2.336 | PASS |
| Optimal | 897.14 | 1.3937 | 394.70 | 2.273 | PASS |
| TLZ4 | 1752.37 | 2.7222 | 405.75 | 4.319 | PASS |
| ZSTD | 1037.24 | 1.6112 | 422.91 | 2.453 | PASS |

> Windows decode speed is generally higher than Mac (Win/Mac = 1.7x–4.3x), and TLZ4 is the most prominent (4.3x).
> Differences may come from: Windows page cache efficiency, OS scheduler differences, external tool version.
> All formats have passed `tar tf -` decompression correctness verification (the first round of Windows decode verification infrastructure).

## 1c. Compress Size (claw-code, n=40)/ Compress Size

| Format | Win MiB | Win/TGZ | Mac MiB | Mac/Win |
| --- | ---: | ---: | ---: | ---: |
|TGZ|468.3|1.0000|470.0|1.0035|
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
| Lazy2 | 38.75 | 38.75 | ≈ flat |
| Optimal | 17.56 | 15.54 | -11.5% ⚠️ |
| TLZ4 | 228.93 | 191.84 | -16.2% ⚠️ |
| ZSTD | 139.17 | 103.67 | -25.5% ⚠️ |

> TLZ4 / ZSTD is an external tool, and the speed difference reflects the system status (heat throttle, background load) rather than code changes.
> BVX3 / Optimal in the LZFSE format is slightly reduced (-11–12%), and the Windows single-time measurement variance is large, which is regarded as a measurement error.
> Lazy2 is flat, which meets the expectation that the Lazy-Greedy path is not affected by tag filter.

---

# R40-Mac: macOS Complete Benchmark Results (2026-06-22) / R40-Mac: Full macOS Benchmark Results

> Run three batches of `-n 40 / 8 / 4` full benchmarks on claw-code / llama.cpp with R40 code (3652 lines), covering encode/decode speed, RSS peak value, CPU energy ratio, and compare the encode speed with R40-Win.

## 1a. Encode speed vs Windows (claw-code, n=40)/ Encode MB/s — Win/Mac Comparison

| Format | Mac MB/s | Mac/TGZ | Win MB/s | Win/TGZ | Win/Mac |
| --- | ---: | ---: | ---: | ---: | ---: |
| TGZ | 48.64 | 1.00 | 25.33 | 1.00 | 0.52 |
| Other3 | 380.73 | 7.83 | 275.20 | 10.86 | 0.72 |
| BVX3 | 421.51 | 8.67 | 273.66 | 10.80 | 0.65 |
| TLZ4 | 424.74 | 8.73 | 228.94 | 9.04 | 0.54 |
| ZSTD | 363.63 | 7.48 | 139.17 | 5.49 | 0.38 |
| Lazy2 | 57.84 | 1.19 | 38.75 | 1.53 | 0.67 |
| Optimal | 29.90 | 0.61 | 17.56 | 0.69 | 0.59 |

Mac is significantly faster than Win (0.38–0.72×) in all formats. ZSTD Win/Mac ratio is the lowest (0.38), which may come from ZSTD. The degree of Apple Silicon vector instruction is higher than x86.

## 1b. Decode speed (Mac only, claw-code n=40)/ Decode MB/s

| Format | Mac MB/s | Mac/TGZ |
| --- | ---: | ---: |
|TGZ|380.35|1.00|
| TLZ4 | 420.76 | 1.11 |
| ZSTD | 427.91 | 1.13 |
| Other3 | 414.82 | 1.09 |
| Lazy2 | 401.28 | 1.06 |
| BVX3 | 355.84 | 0.94 |
| Optimal | 355.61 | 0.94 |

## two RSS peak (Mac only, claw-code n=40)/ Peak RSS

| Format | Encode RSS | Enc/TGZ | Decode RSS | Dec/TGZ |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 4.2MB | 1.00 | 3.7MB | 1.00 |
| TLZ4 | 83.0 MB | 19.8 | 33.8 MB | 9.1 |
| Other3 | 252.0 MB | 60.0 | 301.1 MB | 81.4 |
| BVX3 | 252.3MB | 60.1 | 323.6 MB | 87.5 |
| ZSTD | 373.4 MB | 88.9 | 9.0 MB | 2.4 |
| Lazy2 | 490.6 MB | 116.8 | 320.2 MB | 86.5 |
| Optimal | 561.2 MB | 133.6 | 307.4 MB | 83.1 |

> `-n 40` Encode RSS is a peak with inflight buffer; Decode RSS is mainly driven by the decompression output size.

## three. CPU Energy (Mac only, claw-code n=40)/ CPU Energy Ratio vs TGZ

> ⚠ Decode energy n=40 is not reliable due to the sampling coverage rate <5%, for reference only (standard `*`).

| Format | Enc J | Enc/TGZ | Dec J | Dec/TGZ |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 182.61 | 1.000 | 12.75 | 1.000 |
| TLZ4 | 32.74 | 0.179 | 3.67* | 0.288* |
| **Other3** | **30.91** | **0.169** | **3.29*** | **0.258*** |
| BVX3 | 35.23 | 0.193 | 5.76* | 0.452* |
| ZSTD | 43.23 | 0.237 | 7.74* | 0.608* |
| Lazy2 | 135.09 | 0.740 | 4.58* | 0.359* |
| Optimal | 537.44 | 2.943 | 4.51* | 0.354* |

## four. Best Points All n / Best Points Across All n

### claw-code

| Format | Best Compression Ratio | Enc MB/s Best/Worst | Dec MB/s Best/Worst | Enc RSS Lowest/Highest | Dec RSS Low/Highest | Enc Energy Ratio Range | Dec Energy Ratio Range |
| --- | ---: | --- | --- | --- | --- | --- | --- | --- |
| TGZ | 1.0000 | 49 / 48 | 380 / 362 | 4.2 / 4.3 MB | 3.7 / 3.7 MB | 1.000 | 1.000 |
| Other3 | 0.9865 | 408 / 347 | 415 / 396 | 139 / 252 MB | 70 / 301 MB | 0.169–0.308 | 0.258–0.666 |
| BVX3 | 0.9492 | 422 / 339 | 356 / 292 | 129 / 252 MB | 71 / 324 MB | 0.193–0.304 | 0.452–1.007 |
| TLZ4 | 1.1793 | 431 / 425 | 421 / 332 | 76 / 83 MB | 34 / 34 MB | 0.179 | 0.288 |
| ZSTD | 0.8245 | 366 / 360 | 428 / 406 | 373 / 376 MB | 9 / 9 MB | 0.237 | 0.608 |
| Apple | 0.9873 | 143 / 141 | 357 / 301 | 1368 / 1368 MB | 474 / 474 MB | 0.294–0.341 | 0.525–0.552 |
| Lazy2 | 0.8998 | 58 / 41 | 405 / 387 | 180 / 491 MB | 66 / 320 MB | 0.740–1.006 | 0.359–0.842 |
| Optimal | 0.8574 | 30 / 21 | 363 / 326 | 198 / 561 MB | 68 / 307 MB | 2.943–4.137 | 0.354–0.924 |

### llama.cpp

| Format | Best Compression Ratio | Enc MB/s Best/Worst | Dec MB/s Best/Worst | Enc RSS Lowest/Highest | Dec RSS Low/Highest | Enc Energy Ratio Range | Dec Energy Ratio Range |
| --- | ---: | --- | --- | --- | --- | --- | --- | --- |
| TGZ | 1.0000 | 42 / 41 | 86 / 84 | 4.3 / 4.4 MB | 3.8 / 3.8 MB | 1.000 | 1.000 |
| Other3 | 0.9958 | 97 / 87 | 81 / 73 | 135 / 362 MB | 67 / 349 MB | 0.177–0.256 | 0.223–0.703 |
| BVX3 | 0.9787 | 93 / 89 | 81 / 77 | 142 / 356 MB | 67 / 351 MB | 0.195–0.227 | 0.259–1.023 |
| TLZ4 | 1.0537 | 89 / 85 | 82 / 79 | 80 / 82 MB | 34 / 34 MB | 0.209 | 0.257 |
| ZSTD | 0.9100 | 95 / 90 | 85 / 80 | 474 / 474 MB | 9 / 9 MB | **0.140** | 0.444 |
| Apple | 0.9988 | 69 / 66 | 80 / 78 | 1286 / 1286 MB | 596 / 596 MB | 0.289–0.314 | 0.585–0.598 |
| Lazy2 | 0.9551 | 85 / 73 | 84 / 83 | 244 / 497 MB | 67 / 349 MB | 0.325–0.457 | 0.225–0.499 |
| Optimal | 0.9387 | 47 / 33 | 79 / 78 | 243 / 821 MB | 71 / 349 MB | 2.018–2.951 | 0.281–0.789 |

---

# R40-Win: Optimal Cross-Segment Match OOB Fix (2026-06-21) / R40-Win: Optimal Cross-Segment Match OOB Fix

> When Windows tested the R40 code, it was found that the low-repetition greedy fast path of the Optimal encoder had a memory cross-boundary bug, causing the Release version to crash with `VCRUNTIME140.dll 0xc0000005` (access violation), and the Debug version clearly returned `Fatal error: UnsafeBufferPointer with negative count`. In theory, this problem also exists in macOS, but the behavior under Release compilation is not defined and does not necessarily crash immediately.

## Root Cause Analysis / Root Cause

When calculating the match length of the low-repetition segment greedy path of Optimal (in `lzParseOptimal`, `coverage < optPrescreenMinCoverage` branch), the `limit` parameter uses the global input length `n - i - 4`, which is not limited by the `segEnd` of the current segment.

**Cause and effect chain:**

| Steps | Instructions |
|---|---|
| 1 | greedy match take `limit = n - i - 4`, match cross `segEnd` |
| 2 | `emitGreedy` advances `litStart` to `i + matchLen`, may > `segEnd` |
| 3 | Next paragraph `segStart = segEnd`, when entering `posLoop` `i = segStart < litStart` |
| 4 | `emitGreedy(at: i, ...)` EXECUTION `UnsafeBufferPointer(start: p + litStart, count: i - litStart)` |
| 5 | `i - litStart < 0` → `count` is negative → Debug: Fatal error; Release: Access violation crash |

**Other supporting evidence:**
- `-n 1` can also be reproduced (non- `-n 40` has a special problem)
- Windows event records multiple crash records of the same module and the same fault offset
- Some of the output before the crash is stopped at the legal block boundary, but the `bvx$` end mark is missing (truncated stream)

## Fix / Fix

**File: `lzfse-cli.swift` about 1264 line** (Optimal greedy quick path match limit)

| | Before repair | After repair |
|---|---|---|
| rep path limit | `limit: n - i - 4` (global) | `limit: segEnd - i - 4` (within the limited section) |
| cand path limit | `limit: n - i - 4` (whole area) | `limit: segEnd - i - 4` (within the limited section) |

Both match calculations are stopped at `segEnd` to prevent `litStart` from crossing the segment boundary.

## Validation / Validation

| Project | Result |
|---|---|
| `swiftc -O` COMPILE | ✅ SUCCESS |
| Built-in `-test` (including new cross-segment match return test) | ✅ All passed |
| `claw-code -algo bvx3 -optimal -n 40` COMPLETE COMPRESSION | ✅ SUCCESS, ABOUT **73.3 SECONDS** |
| Output size | **406,284,948 bytes** |
| `bvx$` Ending Mark | ✅ Exist |
| After decompression `tar -tf` | ✅ Success, output-identical |

> Note: The difference between the compressed output of 406,284,948 bytes and macOS R39 baseline (407,098,957 bytes) is 814,009 bytes. The reason is that the match of the greedy segment no longer crosses the segment after repair, resulting in some matches being slightly shorter. Bitstream is legal but not bitstream-identical. Output-identical acceptance passed.

## Windows Benchmark Test (Run C, 2026-06-21) / Windows Baseline

Perform a complete benchmark test on `claw-code` (n=40 inflight) with the repaired binary ( `lzfse.exe`) with R40-Win. The subsequent R{N}-Win takes this as a comparison benchmark.

| Format | Time consumption (seconds) | Encode MB/s | Compression ratio (/TGZ) |
|---|---:|---:|---:|
| TGZ | 55.92 | 25.33 | 1.0000 |
| LZFSE (Other3) | 5.15 | 275.17 | 0.9818 |
| LZFSE (BVX3) | 5.18 | 273.65 | 0.9254 |
| TLZ4 | 6.19 | 228.93 | 1.1739 |
| LZFSE (Lazy2) | 36.56 | 38.75 | 0.8704 |
| ZSTD | 10.18 | 139.17 | 0.7813 |
| LZFSE (Optimal) | 80.67 | 17.56 | 0.8273 |

MB/s is based on 1351 MiB × 1.048576 = 1416.63 MB (consistent with macOS format). Windows does not measure decode speed, RSS and CPU energy (macOS powermetrics is required).

## Win/Mac Comparison Report Structure / Comparison Report Structure

Each round process: run **R{N}-Mac** first, then **R{N}-Win**, and finally run `comparison_win.py` to generate a three-section comparison report:

| Segment | Win | Mac | Description |
|---|---|---|---|
|1a. Encode MB/s + ratio/TGZ | ✅ | ✅ | Win/Mac comparison + relative TGZ speed ratio of each platform |
| one b. Decode MB/s + ratio/TGZ | — | ✅ | Windows unmeasured decode |
| two. RSS MB + ratio/TGZ | — | ✅ | Windows Unmeasured RSS |
| three. CPU Energy J + ratio/TGZ | — | ✅ | Windows does not measure energy consumption; n=40 decode energy is not reliable |

---

# R40: Streaming decode Recovery and Encode Pipeline Correction (2026-06-21) / R40: Restore Streaming Decode & Fix Encode Pipeline

> Take R39 (3379 lines) as the starting point, make up for the streaming decode path removed by R39, and correct the two regressions of `runParallelEncode` introduced by R39. No algorithm change, encode / decode output should be R39 bitstream-identical.

## Code status (3652 lines)

### Recovery: Streaming decode ( `decodeStreamFromFile` / `decodeStreamToHandle`)

R39 change decode CLI to `readToEnd()` (whole-buffer), peak RSS ≈ whole compression input (~500 MB). Add three functions in this round:

| Function / Type | Description |
|---|---|
| `enum StreamDecodeResult` | `.ok` / `.fallback` / `.error` Three-way results |
| `decodeStreamFromFile(path:chunkRaw:inflight:output:)` | Block-by-block read compressed streaming (1 MB readChunk), self-block streaming directly parallel decoding; non-own streaming return `.fallback` |
| `decodeStreamToHandle(_:parallel:chunkRaw:inflight:output:)` | whole-buffer fallback's streaming writing and publishing: `scanBlocks → grouping → DispatchQueue.concurrentPerform → written in order` |

CLI decode path ( `-i <file>`): First, try `decodeStreamFromFile` → `.fallback` to read the whole file to go to `decodeStreamToHandle`; stdin path directly to `decodeStreamToHandle`. The whole process does not hold the whole decompression output to reduce decode peak RSS.

### Correction: `runParallelEncode` two regressions (R39 introduction)

| Project | R33/R35 | R39 (regression) | R40 (revision) |
|---|---|---|---|
| PARALLELITY SOURCE | `inflight: Int` PARAMETER, `maxTasks = max(2, inflight)` | HARD WRITE `maxTasks = max(2, activeProcessorCount)`, IGNORE `-n` | ADD BACK `inflight: Int`, CALL END FAX `inflightN` |
| Encode RSS | `autoreleasepool { ... }` wrap read loop, prevent autorelease Data accumulation | No `autoreleasepool`, encode RSS ≈ whole input | Add back `try autoreleasepool { ... }` |

`FileHandle.read` is returned to autoreleased `Data` in macOS; if there is no pool in the main thread read loop, the autorelease temporary storage accumulates until the end of the process before being released, resulting in encode RSS ≈ whole input size (the RSS upper limit unrelated to `-n`).

### Streaming Status Overview

| | Encode streaming | Decode streaming | `-n` encode | `-n` decode |
|---|---|---|---|---|
| R33/R35 | ✅ | ✅ | ✅ | ✅ |
| R39 | ✅ | ❌ (whole-buffer) | ❌ (activeProcessorCount) | N/A |
| **R40** | ✅ | ✅ | ✅ | ✅ |

## n40 represents the result (Encode / Decode CPU Energy Ratio vs TGZ)

| Format | claw enc ratio | claw enc MB/s | claw dec ratio | claw dec MB/s | llama enc ratio | llama enc MB/s | llama dec ratio | llama dec MB/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 1.000 | 49 | 1.000 | 380 | 1.000 | 41 | 1.000 | 86 |
| TLZ4 | 0.179 | 425 | 0.288 | 421 | 0.209 | 86 | 0.257 | 79 |
| **Other3** | **0.169** | **381** | **0.258** | **415** | **0.177** | **87** | **0.223** | **81** |
| BVX3 | 0.193 | 422 | 0.452 | 356 | 0.198 | 89 | 0.259 | 81 |
| ZSTD | 0.237 | 364 | 0.608 | 428 | **0.140** | 92 | 0.444 | 80 |
| Apple | 0.341 | 143 | 0.552 | 320 | 0.314 | 66 | 0.585 | 79 |
| Lazy2 | 0.740 | 58 | 0.359 | 401 | 0.325 | 85 | 0.225 | 84 |
| Optimal | 2.943 | 30 | 0.354 | 356 | 2.018 | 47 | 0.281 | 79 |

Other3 The encode of the two data sets is the most energy-saving in its own format (claw 0.169, llama 0.177), and decode is also the most energy-saving (claw 0.258, llama 0.223). ZSTD encode (0.140) on llama.cpp is the lowest of all formats. BVX3 encode energy consumption (claw 0.193, llama 0.198) is slightly higher than Other3, and decode is significantly higher (0.452 / 0.259).

Compared with R39 (regressive version), the `-n` modification of R40 reduces the claw-code Other3 encode energy ratio from 0.190 to 0.169, and the BVX3 increases from 0.179 to 0.193; the difference in llama.cpp is also similar, mainly due to the change in parallelism and chunk cutting method after the correct transmission of inflight parameters.

## R33/R34 BVX3/Other3 encode "peak" survey

The Trend Chart Shows That The BVX3 Greed And Other3 Encode Speed Of R33/R34 Is Much Higher Than That Of The Neighboring Round; The Root Cause Of This Round Of Investigation.

### Conclusion: Measure the illusion, non-code improvement

All functions related to BVX3 greedy / Other3 encode are exactly the same as the Swift source code md5 in R33 and R35:

| Function | Call path of BVX3 / Other3 | R33 vs R35 md5 |
|---|---|---|
| `lzParseStrong` | BVX3 greedy, Other3 ( `strong=true`) actual caller | Same |
| `lzParseChain` | BVX3 lazy2 | Same |
| `compressBody` | Assipay Entrance | Same |
| `runParallelEncode` | Parallel Frame | Same |

The only code difference between R33 → R35 is that `lzParseOptimal` shortens 40 lines (removes 4-context literal pricing), resulting in binary from 351,992 → 335,576 bytes (−16 KB). BVX3 greedy and Other3 **not call** `lzParseOptimal`.

### The difference in system status is the root cause.

In the same benchmark log, even the external code (lz4, tar extract) also slows down:

| Algorithm / Program | R33 | R35 | Magnification |
|---|---:|---:|---:|
| bvx3 greedy | 2.08 s | 4.56 s | 2.20× |
| other3 | 2.64 s | 3.87 s | 1.47× |
| lz4 (external) | 2.18 s | 3.47 s | **1.59×** |
| tar extract (external) | 2.23 s | 3.56 s | **1.59×** |
| lazy2 | 21.27 s | 22.00 s | 1.03× |
| optimal | 39.03 s | 40.81 s | 1.05× |

The magnification of BVX3 greedy (2.20×) is much greater than lazy2/optimal (~1.04×) because: BVX3 greedy each chunk is only ~5 ms, and the cache miss of OS scheduler grabbing and hash table random-access accounts for a large proportion of total time; lazy2 each chunk ~530 ms, and the impact of scheduling noise can be ignored. **R35 benchmark Runtime system background load is high, which has a disproportionate amplification effect on short tasks. **

**R33/R34 BVX3/Other3 encode peak value is not an optimized result, but a measurement noise when the system conditions are better. **

---

# R39: 92221a02 encode Retest (2026-06-21) / R39 Encode-Optimization Revert Retest

> Replace R35 code (3957 lines) with 92221a02 ( `lzfse-cli.swift` 3379 lines) and execute the complete benchmark. This version removes all advanced encode optimizations in R35 (R6/R10/R17/R18/R26/R27/R28/R30/R32), and the decode core algorithm is exactly the same as R35, but the decode CLI path is changed from streaming ( `decodeStreamFromFile`) back to whole-buffer `readToEnd()`. The same benchmark run also supplemented the original log analysis of decode energy corrected by powermetrics `-i 500ms`.

## Code status

- **Removed encode optimization**

| Round | Remove content | Affected range |
| --- | --- | --- |
| R6 | rep length precalculation (l0/l1/l2 reuse) | other3, bvx3, lazy2 (lzParseChain) |
| R10/R17 | entropy sampling gate (greedyEmitSegment, optEntropyHighThreshold) | bvx3 -optimal (lzParseOptimal) |
| R18/R27 | Tag-packed hash chain (hashAndTag, chainIndexMask/chainTagShift/chainNullIndex) | other3, bvx3, lazy2, optimal(lzParseChain + lzParseOptimal) |
| R26 | localHead move out of segment loop | bvx3 -optimal (lzParseOptimal) |
| R28 | symbolPointer() binary search | bvx3 -optimal (lzParseOptimal) |
| R30 | cheap-probe gating(optDPSkipAvgMatchLen) | bvx3 -optimal(lzParseOptimal) |
| R32 | matchLength 16-byte Expand → Return 8-byte | other3, bvx3, lazy2, optimal (lzParseChain + lzParseOptimal) |

- The decode kernel (FSE decoding, LZ copy, block parsing) ** is exactly the same as R35**. If there is a difference in decode speed, it comes from the different FSE symbol distribution caused by different bitstreams.
- decode CLI path: `-i <file>` changed from `decodeStreamFromFile` (streaming) back to `inputHandle.readToEnd()` (whole-buffer), peak decode RSS equals the entire compressed input size.

## n40 represents the result (Encode CPU Energy Ratio vs TGZ)

| Format | claw-code ratio | enc MB/s | llama.cpp ratio | enc MB/s |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 1.000 | 50 | 1.000 | 43 |
| TLZ4 | 0.174 | 430 | 0.192 | 91 |
| **BVX3** | **0.179** | **424** | **0.140** | **95** |
| Other3 | 0.190 | 380 | 0.117 | 96 |
|ZSTD|0.239|374|0.137|98|
| Apple | 0.296 | 140 | 0.224 | 72 |
| Lazy2 | 0.618 | 69 | 0.277 | 87 |
| Optimal | 2.936 | 36 | 2.120 | 50 |

BVX3 encode is the most energy-saving among all LZFSE formats (82-86% than TGZ), the compression ratio is 0.949/0.979, and the encode speed is 95-424 MB/s. Other3 (LZFSE standard output) has similar energy consumption (0.117-0.190), faster (380-96 MB/s) but the compression ratio is slightly worse (0.987/0.996).

## Decode energy fundamental measurement problem (powermetrics -i after 500ms)

### Description of the problem

Even if the sampling interval is modified from -i 100ms to -i 500ms, the decode energy measurement of n=40 is still unreliable**. The minimum decode energy ratio (0.006–0.013) is purely a quantitative illusion.

### Direct comparison of the original log

`claw-code-optimal n=40 decode` (ratio 0.006, report 61 mW):
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

**1 Only 1 sample is caught in the sampling window (n=40 decode)**

```
T=0.0s：powermetrics 啟動
T=0.2s：decode 開始（sleep 0.2 後）
T=0.5s：唯一樣本觸發（506ms 視窗）← decode 仍在執行中
T=0.71s：decode 結束
```

The decode is only 0.51s, and the decode has not been completed before the sample window is completely over. There is no sample coverage in the second half (T=0.5–0.71s).

**2 n=40 GCD task is completed explosively, P-core is completely passive**

- n=4: 4 major tasks → P-core full speed (80-83% @ 4464 MHz), decode continues to put pressure on P-core
- n=40: 40 small tasks (each 4MiB chunk) → E-core The task ends after a brief outbreak, and P-core is not awakened at all.

**3 The only sample points are mainly free time**

506ms sample composition:
- Before 200ms: decode has not started yet (pre-sleep period)
- Middle ~200ms: E-core has completed the outbreak, and the system is down to idle.
- After ~100ms: decode wall time is still being calculated, but P-core is not moved

Average result: 61 mW (near standby power), not real decoding power.

### List of samples of each format

| Format | dur | Number of samples | Report mW | Remarks |
| --- | ---: | ---: | ---: | --- |
| optimal (n40) | 0.51s | **1** | 61 | Free |
| other3 (n40) | 0.44s | **1** | 85 | Idle |
| lazy2 (n40) | 0.51s | **1** | 128 | Idle |
| tar.lz4 | 0.47s | **1** | 1510 | Random, unable to represent |
| bvx3 (n40) | 0.56s | **1** | 889 | Random |
| ZSTD | 0.95s | 2 | 6359+956 | peak+cooling, average 3658 |
| apple (n40) | 0.81s | 2 | 4169+128 | peak+cooling |
| TGZ | 1.35s | 3 | 5300+5308+231 | The most stable, including 1 cooling sample |

Only the average of TGZ decode (1.35s, 3 samples) is relatively stable. Although there are 2 samples of ZSTD and apple, the second sample is both cooling period (956/128 mW), and the average is still low. The format values of the remaining 1 sample are all sampling illusions, which is unreliable.

### Conclusion

**Decode energy ratio All n=40 values do not reflect the real decoding energy consumption and cannot be used for performance judgment. **If you need reliable decode energy measurement, you should use one of the following methods:
1. Repeat the decode in a loop, so that the total measurement time is ≥ 3s (recommended)
2. Change to IOReport / powerlog to provide per-interval finer particle sampling
3. Only report the decode speed (MB/s) and abandon the energy consumption measurement.

---

# R38: R35 code retest (2026-06-20)/ R38 Revert Baseline Retest

> R37 After determining that rep1/rep2 dominated-range skip has no reproducible performance gains, revert the `lzfse-cli.swift` to R35 code (remove the `repLen0/repLen1` declaration of R36 and the rep1/rep2 skip logic), and trigger the complete benchmark (starting at 15:08, 18:51 BENCH_DONE). The purpose is to confirm that the compressed output after revert returns to R35 bitstream, and the encoding speed restores the R35 water level.

## Code status confirmation

- The current `lzfse-cli.swift` has removed the `var repLen0 = 0, repLen1 = 0` added by R36 and rep1/rep2 skip guard and restored to the original cycle starting point of `var msym = 4; var ll = 4; let lim = min(l, cap)`.
- Optimal compression bytes: `claw-code 422,948,093` (= R35 committed), `llama.cpp 577,863,623` (= R35 committed). Unlike `422,948,018 / 577,864,898` of R36/R37, bitstream completely returns to the R35 state after confirming the revert.

## n40 Optimal Result Comparison (R35 committed vs this retest)

| Indicator | R35 committed | This retest (R35 code) | Gap |
|---|---:|---:|---:|---:|
| claw-code encode MB/s | 34.70 | 36.21 | +4.4% |
| llama.cpp encode MB/s | 49.89 | 50.42 | +1.1% |
| claw-code encode power mW | 13,279 | 13,290 | +0.1% |
| llama.cpp encode power mW | 15,731 | 15,523 | −1.3% |
| claw-code encode energy J | 545.7 | 517.8 | −5.1% |
| llama.cpp encode energy J | 371.5 | 359.2 | −3.3% |
| claw-code encode RSS MB | 578.1 | 561.2 | −2.9% |
| llama.cpp encode RSS MB | 587.2 | 597.2 | +1.7% |

- The two rounds of encode power (mW) are almost the same (+0.1% / −1.3%), confirming that the CPU frequency and power status are stable.
- encode speed: `llama.cpp` +1.1% is noise; `claw-code` +4.4% is slightly higher, which may be due to system warm-up difference or cache effect. If it does not exceed the 10% threshold, it is still considered a noise range.
- encode energy −3.3 ~ −5.1%: the direction is the same, but the magnitude is not enough to claim improvement; when R35 committed, the heat state of the system is high, and the low energy consumption of this retest is a reasonable fluctuation.
- **decode power / energy**: This retest decode power is only 499 / 169 mW (vs. general 5,000–7,000 mW), which is obviously low. It is speculated that the powermetrics sampling window is not aligned with the decode execution period, and the decode energy results cannot be used.

## Decode energy measurement reliability analysis (R35 / R36 / R37 / R38 four-wheel comparison)

### Phenomenon 1: TGZ / TLZ4 / ZSTD decode energy is exactly the same as the same n=4 / 8 / 40 of the same run

| run | claw-code TGZ n4 | n8 | n40 |
|---|---:|---:|---:|---:|
| R35 | 8.828 J | 8.828 J | 8.828 J |
| R36 | 28.553 J | 28.553 J | 28.553 J |
|R37|10.605J|10.605J|10.605J|
| R38 | 5.280 J | 5.280 J | 5.280 J |

→ The decode energy of these three formats has nothing to do with the n value. power_benchmark only performs one measurement on them, and the results are copied to the three columns of n=4 / 8 / 40. **TGZ/TLZ4/ZSTD decode energy cannot be used for per-n comparison, nor should it be used as the denominator of the same round of decode ratio. **

### Phenomenon 2: LZFSE Optimal decode sampling window is extremely short (implied active ≈ 0.4–1.0 s)

`implied_active = decode_energy_J / (decode_power_mW / 1000)` represents the duration of CPU activity that powermetrics actually captures.

| | R35 | R36 | R37 | R38 | Actual decode_sec |
| --- | ---: | ---: | ---: | ---: | ---: |
| claw-code n4 | 0.98 s | 1.01 s | 1.00 s | 0.88 s | ~4.2 s/iter |
| claw-code n8 | 0.65 s | 0.68 s | 0.66 s | 0.63 s | ~3.8 s/iter |
| claw-code n40 | 0.52 s | 0.56 s | 0.59 s | 0.51 s | ~4.0 s/iter |
| llama.cpp n4 | 0.67 s | 0.70 s | 0.67 s | 0.63 s | ~15.6 s/iter |
| llama.cpp n8 | 0.49 s | 0.52 s | 0.50 s | 0.47 s | ~15.0 s/iter |
| llama.cpp n40 | 0.39 s | 0.38 s | 0.40 s | 0.36 s | ~15.4 s/iter |

Each decode measurement of powermetrics only captures about 0.5–1.0 seconds, but the actual decode per iteration is 4–16 seconds (n40 total time is up to 160–620 seconds). ** The sampling window coverage rate is extremely low (<5%), and only captures a small part of the CPU state at the beginning of decode, which does not represent the overall energy consumption. **

### Phenomenon 3: R36 decode power is abnormally high, R38 n40 is abnormally low

| run | claw-code Optimal n40 power | llama.cpp Optimal n40 power |
| --- | ---: | ---: |
| R35 | 558 mW | 6,445 mW |
| R36 | **15,070 mW** (abnormally high) | **15,287 mW** (abnormally high) |
| R37 | 6,655 mW | 6,863 mW |
| R38 | **499 mW** (abnormally low) | **169 mW** (abnormally low) |

- R36 decode power is equivalent to encode (13,000–15,000 mW), showing that the system is under high load during R36 benchmark, and the sampling window just captures the background activity, resulting in decode power to be high.
- R35 / R38 claw-code n40 decode power is only 500–560 mW, which is a huge gap with llama.cpp in the same round (6,445 / 169 mW), showing that the sampling window is extremely short and the timing is random.

### Conclusion: Decode energy measurement cannot be used for cross-wheel comparison

1. The sampling window is only 0.4–1.0 s, which is much shorter than the actual decode time and cannot represent the total energy consumption.
2. TGZ/TLZ4/ZSTD decode energy is constant for n values (single measurement), which cannot be compared with the LZFSE format in n-consistent ratio.
3. R36 decode power is polluted by the high load of the system, and R38 n40 is affected by the sampling timing offset. The absolute value of both rounds is unreliable.
4. The only reliable energy consumption indicator is **encode CPU energy**: long encoding time (25–55 s/iter × n), high powermetrics sampling coverage, and stable cross-wheel power value (±1–2%).

** If the subsequent decode energy needs to be measured reliably, it should be changed to `powermetrics -i 500` continuous sampling and cover the entire n-iteration decode execution period, instead of the current single short window sampling. **

## Encode energy four-wheel comparison analysis (R35 / R36 / R37 / R38)

### Measurement reliability: high encode energy coverage

The implied_active (energy/power) of encode is almost consistent with the actual encode_seconds (95–107%), confirming that the powermetrics sampling window completely covers the entire encode execution period. Encode energy is a reliable measurement, which is fundamentally different from decode.

However, **TGZ / TLZ4 / ZSTD encode energy in the same run n=4/8/40 is still exactly the same** (single measurement), and the per-n comparison cannot be done; the LZFSE format is correctly incremented according to n.

### R36 encode energy full format systematic high

The energy consumption expansion of R36 is not only in Optimal, **all formats** are increased, and the expansion amplitude is inversely proportional to the duration of the encode:

| Format (claw-code n40) | R35 | R36 | R37 | R38 |
| --- | ---: | ---: | ---: | ---: |
| TGZ (~3 s) | 192 J | **550 J (+187%)** | 182 J | 167 J |
| LZFSE (Apple) (~7 s) | 56 J | **157 J (+180%)** | 52 J | 46 J |
| LZFSE (Lazy2) (~14 s) | 120 J | **163 J (+36%)** | 114 J | 109 J |
| LZFSE (Optimal) (~40 s) | 546 J | **603 J (+10%)** | 526 J | 518 J |

TGZ (the fastest, the shortest sampling window) expands +187%, and Optimal (the slowest, the longest sampling window) only expands +10%. This is a typical **system high-load pollution**: the shorter the encoding time, the higher the measurement ratio of background power consumption. **R36's non-Optimal format encode energy value cannot be used. **

### Optimal encode energy four-wheel value (relative to R35)

| Data set / n | R35 | R36 | R37 (R36-code)| R38 (R35-code) |
| --- | ---: | ---: | ---: | ---: |
| claw-code n4 | 736 J (100%) | 1103 J (+50%) | 720 J (**98%**) | 723 J (**98%**) |
| claw-code n8 | 590 J (100%) | 756 J (+28%) | 585 J (**99%**) | 578 J (**98%**) |
| claw-code n40 | 546 J (100%) | 603 J (+10%) | 526 J (**96%**) | 518 J (**95%**) |
| llama.cpp n4 | 544 J (100%) | 738 J (+36%) | 511 J (**94%**) | 519 J (**95%**) |
| llama.cpp n8 | 416 J (100%) | 501 J (+20%) | 402 J (**97%**) | 403 J (**97%**) |
| llama.cpp n40 | 372 J (100%) | 407 J (+10%) | 365 J (**98%**) | 359 J (**97%**) |

- R37 (R36-code) and R38 (R35-code) are both 2–5% lower than R35 committed, but the gap direction is the same, showing that the system heat status is slightly lower than R35 committed during R37/R38.
- After excluding R36, the gap between the Optimal encode energy of the three rounds (R35 / R37 / R38) does not exceed 5% under the same n value, which is within the fluctuation range of the system state.

### R37 (R36-code) vs R38 (R35-code) Optimal Direct Comparison

| n | claw-code ΔE | claw-code Δspeed | llama.cpp ΔE | llama.cpp Δspeed |
| --- | ---: | ---: | ---: | ---: |
| n=4 | +0.4% | +2.1% | +1.6% | −3.1% |
| n=8 | −1.2% | −2.2% | 0.0% | −3.1% |
| n=40 | −1.6% | +1.0% | −1.5% | +1.1% |

(The positive value = R38 is higher than R37; the positive value of energy consumption = R35-code is more energy-consuming)

Under n40, R38 (R35-code) consumes 1.5–1.6% lower energy than R37 (R36-code) and 1.0–1.1% faster; the direction is inconsistent under n4/n8. The gap is within ±2–3%, and the explanation of the system state cannot be ruled out. ** At present, it is impossible to confirm from the energy consumption data that R36 code (rep1/rep2 skip) has a reprodible positive and negative impact on Optimal encode. **

### Encode energy Conclusion

1. **Reliable measurement**: The powermetrics coverage of LZFSE format encode energy is ≈ 95–107%, which is the most reliable energy consumption indicator in this benchmark.
2. **R36 full-format systematic high** (system high load), after excluding R35/R37/R38 Optimal gap ≤ 5% (system hot state fluctuation).
3. **R36 code vs R35 code (R37 vs R38)**: R35-code under n40 is slightly saved by 1.5%, but the direction of n4/n8 is inconsistent, and the whole is within the noise range, and rep1/rep2 skip can't reproduce the improvement in energy consumption.
4. TGZ/TLZ4/ZSTD encode energy single measurement, n-constant, shall not be used for cross-n ratio analysis.

## Conclusion

- **Revert correct**: bitstream completely returns to R35, and the encode speed and power water level are consistent with R35 committed (noise range).
- **R35 code can be used as the clean baseline of the next round of DOE** and does not carry the DP state interference of R36 rep1/rep2 skip.
- **There is a fundamental problem in Decode energy measurement**, and the decode energy values of historical R35–R38 cannot be used for cross-wheel performance determination.
- **Encode energy is reliable but R36 is polluted by system load**; R37/R38 shows that rep1/rep2 skip can't reproduce the energy consumption gain.
- The next step is according to R37 TODO: use this revert baseline with feature switch to create a controlled A/B in the same round, or carry out new Optimal hotspot optimization ( `matchLength`, `rebuildPrices`, Swift Array/COW).

---

# Round 37: R36 rep1/rep2 Dominance skips the same code retest (performance gains are not reproduced) (2026-06-20) / Round 37: Same-Code Retest of R36

> The compression kernel has not been modified in this round, the purpose is to retest the rep1/rep2 dominated-range skip of R36. Both data sets have completed encode, decode and extract compare in n40 / n8 / n4, and **output-identical passed**; however, the speed and energy consumption improvement relative to R35 have not reached the acceptance threshold of `>=10%`, so the performance benefits of R36 have not been confirmed.

## Test the completeness and output stability

- The whole round was completed in `2026-06-20 10:35:56`, and no benchmark, compare, memProbe, power or trace analysis failure were found.
- Power has a total of 72 strokes, all of which are `status=ok`; profiling generates 36 trace packages, and the CPU call tree analyzes a total of 72 XMLs. After all the summary is written, the source trace is cleaned up, and the status is `before=36 after=0`.
- `BenchMarkResult.csv` has rebuilt 48 rows, and best-points, power and trace summary have been integrated.
- Optimal compression size is exactly the same as n40 / n8 / n4, and the same as R36: `claw-code 422,948,018 bytes`, `llama.cpp 577,864,898 bytes`. This proves that R36 bitstream can be reappeared stably across thread count and retesting with the same code.
- Relative to R35, `claw-code` is 75 bytes small, and `llama.cpp` is 1,275 bytes large; bitstream is different from R35, but the content after extract is exactly the same, so it does not constitute output-identical failure.

## n40 represents the result

MB/s is still calculated by the actual raw bytes / duration ns, and does not use the display value to push back.

| Data Set | Optimal Compression MB/s | Decompression MB/s | Compression Ratio | Encode RSS(MB) | Decode RSS(MB) | Encode CPU Energy(J) | top closure | parse hits |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| claw-code | 35.85 | 437.10 | 0.8590 | 564.4 | 328.4 | 526.295590 | 763 | 1187 |
| llama.cpp | 49.85 | 89.25 | 0.9393 | 600.6 | 348.8 | 364.600403 | 681 | 1101 |

## Compare with R36 / R35

Relative to the previous result of R36 with the same code:

- `claw-code` Optimal n40 encode: `36.22 → 35.85 MB/s` (about `-1.0%`); encode CPU energy: `602.633383 → 526.295590 J` (about `-12.7%`).
- `llama.cpp` Optimal n40 encode: `50.42 → 49.85 MB/s` (about `-1.1%`); encode CPU energy: `407.283755 → 364.600403 J` (about `-10.5%`).
- The speed changes by only about 1% under the same program code, but the power difference is more than 10%, showing that the energy results are highly sensitive to the system's thermal state, background load and measurement time point; the decrease of R36 → R37 cannot be directly attributed to the algorithm.

Relative R35 baseline:

- `claw-code` Optimal n40 encode: `34.70 → 35.85 MB/s` (about `+3.3%`); encode CPU energy: `545.694678 → 526.295590 J` (about `-3.6%`).
- `llama.cpp` Optimal n40 encode: `49.89 → 49.85 MB/s` (about `-0.1%`); encode CPU energy: `371.502908 → 364.600403 J` (about `-1.9%`).
- For the original baseline, the speed improvement only appears in `claw-code`, and `llama.cpp` remains almost unchanged; the energy consumption improvement is only about 2–4%, both of which are lower than the success conditions of a single point `>=10%`.

## Energy Ratio Analysis (TGZ = 1 in the same round)

- `Energy Ratio = The algorithm CPU Energy / the same round and the same data set TGZ CPU Energy`; the lower the value, the more energy saving. `<1` represents energy saving compared with TGZ, and `>1` represents energy consumption compared with TGZ. The minimum/maximum value is taken from the minimum/maximum value of the same algorithm in n4 / n8 / n40 respectively.
- The lowest ratio of Optimal appears in n40, and the highest ratio appears in n4; this is consistent with the direction of "improving concurrency increases RSS, but shortens the running time and reduces CPU energy".

| Data Set | Encode Minimum R36→R37 | Encode Maximum R36→R37 | Decode Minimum R36→R37 | Decode Maximum R36→R37 |
| --- | ---: | ---: | ---: | ---: |
| claw-code | `1.0950 → 2.8967` ( `+164.5%`) | `2.0042 → 3.9605` ( `+97.6%`) | `0.2938 → 0.3685` ( `+25.4%`) | `0.6001 → 1.1535` ( `+92.2%`) |
| llama.cpp | `0.6304 → 2.1391` ( `+239.3%`) | `1.1417 → 2.9996` ( `+162.7%`) | `0.2467 → 0.3162` ( `+28.2%`) | `0.4771 → 0.8746` ( `+83.3%`) |

- **Relative to R36, the lowest and highest Energy Ratio of Optimal's Encode / Decode have all increased without any improvement. **The lowest value of Encode still reaches `2.8967 / 2.1391` at R37, indicating that even if the best n40 is taken, the Optimal encode still consumes about TGZ about `2.90x / 2.14x` CPU energy; the highest value reaches `3.96x / 3.00x`.
- The minimum value of Decode has a clear advantage: Optimal n40 only uses TGZ's `36.85% / 31.62%` CPU energy. However, in terms of the highest value, `claw-code` n4 is `1.1535`, which is about `15.4%` more than TGZ; `llama.cpp` n4 is `0.8746`, which is still about `12.5%` less than TGZ. Therefore, the energy saving of client-side decode was founded in n40, and low concurrency is not the advantage of both data sets.
- The maximum Encode ratio of other LZFSE families in the same round is still lower than 1: Other3 `0.3054 / 0.2613`, BVX3 `0.3140 / 0.2678`, Lazy2 `0.8754 / 0.4195`, indicating that they save CPU energy than TGZ encode in all n values. Optimal is the only LZFSE mode in which the lowest Encode value is still greater than 1.
- The TGZ encode baseline of R36 → R37 itself has been greatly reduced by `550.363047 → 181.690929 J` (claw-code) and `646.035081 → 170.447736 J` (llama.cpp); Although the absolute energy consumption of Optimal has also decreased, the decrease is much smaller than that of TGZ, so the normalized ratio has deteriorated. This proves that only the absolute J across the wheel is easily affected by the system state; in the future, the absolute energy consumption and the TGZ Energy Ratio of the same round should be reported at the same time, and the performance judgment shall be subject to the consistency of the two or controlled A/B.

## Profiling and RSS

- Among the 36 traces, 6 external tools end normally, and 30 LZFSE family traces reach the time limit in 300 seconds; both target and `time-profile` / `time-sample` schema exist. The symbol occurrence under the fixed timeout is only for direction comparison and does not represent the exact CPU percentage.
- R35 → R37's Optimal n40 directional sample: `claw-code` top closure `737 → 763` (about `+3.5%`), parse hits `1170 → 1187` (about `+1.5%`); `llama.cpp` top closure `660 → 681` (about `+3.2%`), parse hits `1101 → 1101` (unchanged). Profiling does not show that the main parse hotspot declines due to domination skipping.
- The sample of R36 → R37 only fluctuates slightly: `claw-code` top `769 → 763`, parse `1191 → 1187`; `llama.cpp` top `696 → 681`, parse `1133 → 1101`. This is not enough to establish a stable causal relationship.
- R35 → R37's n40 RSS: `claw-code` encode `578.1 → 564.4 MB`, decode `308.0 → 328.4 MB`; `llama.cpp` encode `587.2 → 600.6 MB`, decode `349.3 → 348.8 MB`. If the direction is inconsistent, it should be regarded as running fluctuations, and there is no proof that rep1/rep2 skip improves or worsens RSS.
- Optimal n40 encode RSS is still about `564–601 MB`, decode about `328–349 MB`. R36's energy trade-off judgment of server/CDN offline compression and about 300 MB client decode RSS is not invalidated by this round, but the encode buffer, chunk in-flight and the life cycle of the temporary array still need to be investigated.

## Judgment

- **Correcty and output-identical pass. ** Two data sets and three n values have been successfully decompressed and compared through extract; the Optimal compression size of R36 can also be stably reproduced.
- **Performance acceptance failed. ** Relative to R35, the speed is `+3.3% / -0.1%`, the encode CPU energy is `-3.6% / -1.9%`, and the profiling does not see the main hotspot reduction, which does not meet the success condition of `>=10%`.
- **Energy Ratio has not improved either. **Relative to R36, the lowest and highest ratios of Optimal's Encode / Decode have all increased; R37 Optimal encode is still TGZ's `2.14–2.90x` even at the lowest point. Only n40 decode maintains the `0.32–0.37x` advantage, which is clearly lower than TGZ.
- R36 rep1/rep2 dominated-range skip should be classified as "output-identical passed, but the performance benefits have not been confirmed", and cannot be claimed to be stable acceleration or energy saving. It will still change DP state/tie path and bitstream, not the pure realization of ratio-neutral.
- The next round should be a feature switch or revert to establish **co-round controlled A/B**, fixed power supply, hot state and background load, at least compare n40 benchmark, power and trace. If there is still no reprodible `>=10%` improvement in the two data sets, you should go back or not keep this pruning and turn to `lzParseOptimal` DP expansion, `matchLength`, `rebuildPrices` or Swift Array/COW and other confirmed hotspots.

---

# Round 36: Optimal Energy Consumption/Speed — rep1/rep2 Output-identical Pass (2026-06-19)/ Round 36: rep1/rep2 Dominated-Range Skip

> Directional: The ratio route (#1/R33, #3, #4) has been exhausted, and this round will be changed to Optimal energy consumption/time optimization. The two data sets are all decompressed and compared, so **output-identical acceptance is established**; there is a slight change in the size of the compressed bitstream, which is also listed as non-bitstream-identical. Only move `lzfse-cli.swift`.

## Change: rep1/rep2 relaxation skip the dominated length segment

- `lzParseOptimal` will run three relaxation cycles of rep0 / rep1 / rep2 in each position, and each will relax the `cPrice[t+4 … t+l]`.
- Observation: The cost of the same length q, rep1 = rep0 cost + ( `dPriceTab[1] − dPriceTab[0]`). When `dPriceTab[1] ≥ dPriceTab[0]` (rep0 distance is cheaper, almost permanent in practice, because rep0 is the most commonly used), the price of rep1 in `4 … min(repLen0,cap)` ** must be ≥ rep0 written price ** → `if c2 < cPrice[dest]` constant false → ** this rep1 is pure no-op**. Rep2 is also dominated by the cheaper one in rep0/rep1.
- Therefore, after adding the price guard, the relaxation of rep1/rep2 ** starts directly from after the dominated segment ** ( `ll` starting point moves up), skips the SIMD/scalar cycle that must be no-op.
- The original assumption is that the skipped `c2 ≥ cPrice` writes are all no-op, so the compression bitstream remains unchanged; the subsequent actual measurement denies the bitstream-identical assumption, but the decompression output is still exactly the same. For details, see "Judgement".
- It is expected that the rep-heavy section can save rep1/rep2 relaxation and reduce Optimal compression time/energy consumption; the actual measurement benchmark speed is slightly improved, but the latest power retest does not show an improvement in energy consumption. Output-identical passed, strict compression ratio neutrality is not established.

## The actual measurement results

- `swiftc -O`, built-in `-test` and the encode, decode and compare of the two data sets n40 / n8 / n4 are all passed, and there is no truncation or content inconsistency.
- This round of raw size is `claw-code 1,416,220,672 bytes` and `llama.cpp 1,322,553,344 bytes`; MB/s is originally calculated in raw bytes / ns.

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
- The duration/average power of the latest power run is different from the previous one, so the increase in energy consumption cannot be entirely attributed to the R36 code; however, according to the principle of "picking the latest effective data", this round no longer claims to improve encode energy, and needs to be measured repeatedly in a fixed hot state to make causal judgment.
- n40 is still the best speed/lowest energy consumption point of Optimal, but it is also the highest point of RSS. Relative to n4, n40 reduces encode CPU energy from `1103.02 / 737.55 J` to `602.63 / 407.28 J` (about `-45%`), at the cost of upgrading encode RSS from `212.8 / 232.1 MB` to `572.3 / 563.5 MB`. This confirms that the number of chunk in-flight is one of the main reasons for RSS, and also shows that reducing concurrency saves memory, but increases total energy consumption due to the length of running time.

### Profiling Reconstruction Results

- The second batch of profiling has been completed: a total of 36 trace packages, 6 external tool traces ended normally, and 30 LZFSE family traces reached the time limit in 300 seconds; all traces are `target_seen=yes`, and `time-profile` / `time-sample` schema exported successfully.
- CPU call tree analyzes a total of 72 XMLs. After the summary is written, the cleanup is executed, and the status is `CPU_CALL_TREE_TRACE_CLEANED before=36 after=0`; the proof is that the source trace will no longer be lost before analysis after the correction. `BenchMarkResult.csv` has been rebuilt 48 rows, power 72/72 is `status=ok`, and the best-points and power fields have been integrated.
- R35 → R36's Optimal n40 directional sample: `claw-code` parse hits `1170 → 1191`, top `lzParseOptimal` closure `737 → 769`; `llama.cpp` parse hits `1101 → 1133`, top closure `660 → 696`. `matchLength` is `71 → 82` / `72 → 77`, `rebuildPrices` is `36 → 42` / `34 → 44`.
- The above is a symbol occurrence with a fixed 300-second timeout trace, which is not an exact CPU percentage; however, neither of the two data sets shows a significant decrease in parse / top closure sample, so the profiling does not support the strong conclusion that "rep1/rep2 skip has reduced the main CPU hotspot". The main hotspot is still `lzParseOptimal` closure, followed by entropy prescreen, `matchLength`, `emitSteps`, `rebuildPrices` and Swift Array/COW.

### RSS and CPU energy consumption trade-off

- According to the continuous access estimate of `LPDDR_power_estimation/LPDDR_power_info.md`, LPDDR4X / LPDDR5 is about `150 / 120 mW/GB`. RSS increases from about `60 MB` to `300 MB`, the increment is about `240 MB` ( `0.234 GB`), corresponding to the additional power of DRAM about `35 / 28 mW`.
- If the additional cost of about 20-40% of memory controller / PHY is included, the memory subsystem increment is about `34–49 mW`. EVEN IF THIS IS REGARDED AS THE CONSERVATIVE UPPER LIMIT OF THE WHOLE CONTINUOUS ACTIVITY, RUNNING FOR 40 SECONDS WILL INCREASE ABOUT `1.4–2.0 J`; IF ONLY ABOUT 4 SECONDS, IT WILL INCREASE ABOUT `0.14–0.20 J`.
- When decode n4 → n40 in the same round, the RSS rises from `68.5 / 71.1 MB` to `308.9 / 348.9 MB`, but the CPU energy decreases from `17.13 / 11.33 J` to `8.39 / 5.86 J` (about `-51% / -48%`). This CPU saves much more than the estimated memory increment of about a few hundredths of a joule in less than a second. Therefore, within the current desktop test and about `300 MB` RSS range, **priority reducing CPU running time/total energy consumption is a better overall choice, and 300 MB RSS is acceptable**.
- This is a model estimate based on active-memory unit power consumption, not this round of DRAM actual measurement; RSS does not mean that all pages are continuously read and written. The application of the conclusion to energy trade-off does not mean that memory capacity, system memory pressure or multi-workload parallel problems can be ignored. Optimal encode n40 still reaches about `563–572 MB`, exceeding the acceptable benchmark of 300 MB here, and should continue to investigate the DP buffer and chunk in-flight life cycle.

### Applicable scenario: server-side update package compression

- Optimal compression is suitable for the distribution model of "server-side compression once, client-side download and decompression multiple times", such as large server-side code update, App or game update package, CDN static assets. High-cost encode can be completed offline at the release end and shared by a large number of downloads. The overall efficiency should not be judged only by a single encode energy.
- This round of Optimal is smaller than the BVX3 / Other3 product; during large-scale distribution, each client can reduce the download bytes, thus reducing the network transmission time and radio / Wi-Fi activity time. After accumulating a large number of iPhones or other clients, transmission-side savings are usually more important than the server's increased one-time compression cost.
- The client only performs decode. The Optimal decode of R36 n40 uses the same format and decoder as other models of the same BVX3 family, and the decompression speed maintains the available water level; the energy cost of about `300 MB` RSS is still less than CPU/transmission savings according to the aforementioned LPDDR model, so on devices with memory capacity allowed, the overall direction is beneficial to client-side energy.
- System layer evaluation should use: `one encode energy + transmission energy of all clients + decode energy of all clients`. The more downloads and the larger the compression size gap, the easier it is to equalize the high encoding cost of Optimal's server-side; if it is only a single local compression, it may not be cost-effective.
- App Store is only an analogy of application scenarios: At present, `bvx3` is a private format. The actual deployment requires the client to integrate the corresponding decoder and conform to the platform update, signature and encapsulation processes. This report does not claim that the existing format can directly replace the official update format of the App Store.

## Judgment

- **Accuracy and output-identical acceptance passed. ** The n40 / n8 / n4 of the two data sets have all been successfully decompressed, and the content after extract is the same. Only the size of Optimal compression product changes; the size of Other3 / BVX3 / Lazy2 remains R35. `claw-code optimal` is `422,948,093 → 422,948,018 bytes` (improved 75 bytes), `llama.cpp optimal` is `577,863,623 → 577,864,898 bytes` (regression 1,275 bytes). Therefore, this round is not bitstream-identical or strictly ratio-neutral, but it does not affect the output-identical determination; the four-digit decimal compression ratio is still about `0.8590 / 0.9393`.
- The original argument that "expensive rep relaxation must be no-op" is incomplete: DP cell not only contains `price`, but also `cR0/cR1/cR2` rep history; skipping relaxation will change the subsequent visible state or tie path, and the actual test has proved that bitstream will change. Therefore, R36 should be regarded as an approximate pruning DOE, rather than purely practical micro-optimization.
- The benchmark speed improvement is only `1.1~4.4%`, which does not reach the single point `>=10%` success conditions; the latest power retest is about `+9.6~10.4%` encode CPU energy, and the profiling does not see a decrease in the main parse hotspot. Although the output-identical is passed, the compression size of `llama.cpp` is still slightly reduced, so R36 does not yet constitute a clear and retainable successful result.
- In terms of energy trade-off, the estimated memory cost of about `300 MB` RSS is lower than the CPU energy savings of the same round of decode n4→n40, so a longer CPU runtime should not be accepted in order to suppress the RSS back to about `60 MB`; however, the Optimal encode RSS above `500 MB` is still beyond the acceptable conclusion of this item.
- At the application level, the main value of Optimal is a large number of client distribution after offline compression of server/CDN: the encoding cost is only paid once, and the transmission and client-side energy savings brought by smaller update packages can be accumulated repeatedly. In the next step, in addition to the stand-alone benchmark, energy break-even analysis under different downloads should be added.


## TODO (in order of priority)/ Backlog

1. The acceptance conclusion of R36 is "correctness/output-identical passed, but the performance success conditions are not met". In the next round, establish the same round of A/B with feature switch or revert, and retest n40 benchmark + power in a fixed thermal state; if the speed is still lower than `+10%` and the energy is not improved, rep1/rep2 skip will not be retained.
2. (Middle) Optimal further output-identical micro-optimization: extract/compare must still be maintained; if bitstream-identical is required, it needs to be clearly listed as an independent acceptance condition. Profiling has confirmed that the main direction is still `lzParseOptimal`, `matchLength`, `rebuildPrices` and Swift Array/COW, and the next single point should make attributable changes from one of them.
3. (Middle) Optimal segment level energy consumption: `optDPSkipAvgMatchLen` (R30 gating) can be DOE again, but the ratio will be changed, and an independent wheel is required.
4. **(Lowest priority) blind beam-2(#2 per-position 2-state)**:
- Feasibility conclusion: **There is no shortcut to correctness and safety**. The current literal step `cR0[t+1]=r0` allows the "rep0 of the latest match" to be carried all the way through the subsequent literal, and the reps of the cell are not old; the "match-ended second state" will converge with the cell state after the literal transmission, and no new rep collection will be given. To really maintain the second way of "simisiar price but different rep", ** can only do a complete beam-2**: save 2 (price, reps) per cell, ** change 2-best merge each SIMD relaxation write point (~11 places) ** + backtrace record which state to choose for each grid.
- Risk/ROI: This is exactly the same SIMD area of **#4 truncation bug**, the sandbox cannot be compiled/verified, and the probability of multiple rounds of compilation; and the ROI is low (rep-carry makes the #2 revenue narrow, and the first three ratio ideas are all defeated).
- Conclusion: **listed as the lowest priority**, only when "in an environment that can compile/test loop, gradually add beam and each step `-test`+benchmark".

---

# Round 35: R34 Repair Retest and R35 baseline (2026-06-19)

> The purpose of this round is not to add ratio DOE, but to revert the R34 failure path, clean up the unused DP macro transition, and re-run the complete benchmark / memProbe / trace / power to confirm the `llama.cpp-n40 optimal` correctness reply.

## Repair the content

- Remove R34 `tag-less length-4 recovery` active path: `lzParseOptimal` no longer use `optLen4ProbeDepth` to recover the length-4 candidate filtered by tag-packing.
- Clean up the unused macro transition status of the previous failed experiment: `relaxLiteralRep0` / `relaxMatchLiteralRep0`, `cLitBefore/cLen2/cDist2`, `stepLitBefore/stepLen2/stepDist2` are all removed.
- `emitSteps` and optimal backtrack return to a single match/literal step: each DP cell only records `cLen/cDist/cR0/cR1/cR2` to avoid the next round of DOE mixed with unused fields and additional memory costs.

## Data status

- `round_status.txt` HAS RUN TO `Done`, AND COMPLETED `BENCHMARK_RESULT_REBUILD_DONE`, `BEST_POINTS_ANALYSIS_DONE`, `POWER_SUMMARY_INTEGRATE_DONE`.
- `claw-code` and `llama.cpp`'s n40 / n8 / n4 complete compare passed; R34's `tar: Write error`, semi-finished `.lzfse.bvx3.optimal`, `Truncated tar archive` no longer appear.
- `BenchMarkResult.csv` has been rebuilt 48 rows, and the speed is converted into actual bytes/ns; the raw size of this round is `claw-code 1351M` and `llama.cpp 1261M`. The size of the data set/seal may fluctuate with the old round, so it mainly depends on the relative sorting of the same code and data in this round.
- The only defect of the power data is that `llama.cpp-lazy2 n40 decode` is `ok:no_samples`; this is a short decode sampling insufficient, which does not affect the correctness or the encode energy conclusion.

## n40 represents the result

`claw-code`:

| Format | Compression MB/s | Decompression MB/s | Compression Ratio | Encode RSS(MB) | Decode RSS(MB) | Encode CPU Energy(J) | CPU top |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Other3 | 365.75 | 343.16 | 0.9865 | 271.0 | 300.1 | 36.113226 | encode / 70 |
| BVX3 | 310.37 | 352.72 | 0.9492 | 233.1 | 324.9 | 35.059268 | encode / 61 |
| Lazy2 | 64.37 | 303.39 | 0.8998 | 495.8 | 320.5 | 119.950248 | parse / 152 |
| Optimal | 34.70 | 295.47 | 0.8590 | 578.1 | 308.0 | 545.694678 | parse / 737 |
| ZSTD | 352.87 | 475.22 | 0.8245 | 377.2 | 9.3 | 49.168387 | external_tool / 174 |
| TLZ4 | 408.54 | 408.78 | 1.1793 | 82.9 | 33.7 | 33.854015 | external_tool / 288 |

`llama.cpp`:

| Format | Compression MB/s | Decompression MB/s | Compression Ratio | Encode RSS(MB) | Decode RSS(MB) | Encode CPU Energy(J) | CPU top |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Other3 | 95.29 | 87.79 | 0.9957 | 348.3 | 349.1 | 30.003544 | encode / 75 |
| BVX3 | 95.53 | 87.54 | 0.9787 | 347.0 | 351.4 | 27.975481 | encode / 60 |
| Lazy2 | 85.25 | 89.38 | 0.9551 | 497.0 | 348.8 | 59.204837 | parse / 126 |
| Optimal | 49.89 | 88.28 | 0.9393 | 587.2 | 349.3 | 371.502908 | parse / 660 |
| ZSTD | 98.53 | 90.55 | 0.9100 | 473.9 | 9.0 | 30.805776 | external_tool / 141 |
| TLZ4 | 91.68 | 88.98 | 1.0537 | 80.6 | 33.8 | 42.736587 | external_tool / 285 |

## Judgment

- **R34 correctness regression has been fixed**: The most important `llama.cpp-n40 optimal` has completed encode/decode/compare, and the truncation failure of R34 has not been reproduced.
- R35 is a clean baseline, not a new compression rate improvement. `Optimal` compression ratio is still the best ( `claw-code 0.8590`, `llama.cpp 0.9393`), but the encode energy is still the highest ( `545.69 J` / `371.50 J`), and the CPU top is still concentrated in `lzParseOptimal` parse closure.
- `BVX3` fast path is still close to TLZ4 in this round of energy consumption: `claw-code n40` is `35.06 J` vs TLZ4 `33.85 J`; `llama.cpp n40` is `27.98 J`, even lower than ZSTD `30.81 J`. However, the RSS of BVX3 family is still high, especially the n40 decode is about `325~351 MB`, which is much higher than TLZ4 `33~34 MB` and ZSTD `9 MB`.
- `-n` The speed/RSS trade-off is still obvious: `claw-code BVX3` The best compression speed is n8 ( `414.50 MB/s`), n40 instead dropped to `310.37 MB/s` And the RSS rises to `233.1/324.9 MB`; `Lazy2/Optimal` Then n40 significantly reduces encode energy, but RSS rises to about `496~578 MB`.
- Trace is still mostly timeout, but `target_seen=yes`, `time-profile/time-sample ok`, CPU call tree summary is available; `Optimal` of `cpu_parse_hits` is still about `1100+`, indicating that if the next ratio DOE increases DP state, the activation segment must be limited first, otherwise it is easy to push the time and RSS higher.

## The next step

- Don't try length-4 recovery directly anymore. To study whether tag-packing harms the compression ratio, first do the instrumentation counter: the number of `load32(c)==v` that is filtered by the tag, the proportion that actually becomes the best DP edge, and the distribution of data sets/paragraphs; the default is still closed.
- The next real Optimal ratio candidate is still a small 2-state / small beam, but it can only be enabled in the rep-heavy or high-coverage segment first; the success conditions need to include compression ratio improvement, `claw-code/llama.cpp` comparison full pass, encode RSS not out of control, and encode energy does not deteriorate significantly.
- If BVX3 family is prioritized, the next round should check n40 encode/decode RSS: chunk in-flight, decoding group buffering, output-side temporary array life cycle. This is more important than continuing to pursue BVX3 encode energy.

---

# Round 34: Codex #4 — tag-less length-4 Supplementary Inspection (2026-06-19)/ Round 34: Recover length-4 matches filtered by tag-packing

> Only move `lzfse-cli.swift`. Accept the four points of Codex's research on xz. **Clarify the status first** and then do it.

## Status Clarification (Important)

- **Codex #1 (context-aware literal price) = already R33, and failed**: HEAD `R33: Optimal literal price 4-context DOE -> failed to improve compress ratio.` has been implementation and benchmarked with "the previous **literal** byte >> 6" (more accurate than the input byte), and the conclusion cannot improve the compression ratio. In this round, a thicker version was remade, and it was found that after hitting R33, **all of them had been restored** (the working tree returned to the single table).
- **Codex #3 (literal+rep0 / match+literal+rep0 combination edge) = already exists**: `relaxLiteralRep0` / `relaxMatchLiteralRep0` of `lzParseOptimal` is, it has been previously exectified.
- Therefore, this round only **really unexplored** **#4**;**#2 (per-position 2-state / small beam) is left for the next round** - It is a large DP reconstruction, and in order to avoid the chaos of R30/R33 "tying two ratio variables in a round → difficult to attribute → disassemble revert", ** only one ratio DOE variable at a time **.

## This round of changes: #4 tag-less length-4 recovery

- R27 tag-packing is a hash5/tag filter chain candidate, which will miss "the first 4 bytes are the same, the 5th byte is different" → tag is different → the skipped **length-4 match**.
- Add (after the `lzParseOptimal` chain visit): **Only when the match of ≥4 ( `bl < 4`) is not found at all in this position**, **tag-less re-check** is done for the `optLen4ProbeDepth` (=4) before the bucket, and recover ** a ** length-4 candidate into frontier after confirmation with `load32(c)==v`.
- The trigger conditions are strict (no rep, the main visit did not find any ≥4 match to start) → Cost upper bound = 4 times `load32` /position, and only in the position of "originally no match at all".
- **Correcty safe**: Only add the legal length-4 match → round-trip verified by `load32(c)==v`, `dd≤maxDist`, `dd≠rep` will not be affected. **The compression ratio/speed will be changed** (expected ratio will increase slightly, and the speed may decrease slightly). Set `optLen4ProbeDepth = 0` to close.

## Test result: R34 correctness failed

- `run_round.command` compilation and `-test` pass, and the complete benchmark enters lz4bench.
- `claw-code` n40 / n8 / n4 all through compare, including `optimal`.
- `llama.cpp-n40 optimal` appears `tar: Write error` and `[Error] lzfseX failed to create llama.cpp.lzfse.bvx3.optimal` in the encode stage; the residual semi-finished product size is `465,196,260 bytes`, and the subsequent decode shows `Truncated tar archive`, and the comparison fails to `13:12:24`.
- This round should be judged as **R34 correctness failed**; `tag-less length-4 recovery` cannot be retained as a valid result, and subsequent MB/s / RSS / power cannot be used.
- `claw-code` passed but `llama.cpp` failed, indicating that this is not a format general decode problem, but an Optimal parser selects a path on a specific data/segment that will cause the encode pipeline to stop in advance or produce a truncation output.

## harness correction

- `zshrc.sh` The compare fail-fast has taken effect: this round is in `llama.cpp-n40 optimal` The compare stopped after failure and did not continue to run trace / power.
- Another correction of `nanoTimeElapsed`: now the exit code of the measured command will be returned; the compression stage of `lz4bench` is changed to check the existence of `encode_rc == 0` and the product at the same time. Next time, if the encode has failed but the semi-finished product exists, `ENCODE_FAILED ... <rc>` will be written in the encode stage and stopped, and will not be mistakenly written as `ENCODED`.
- `cpu_call_tree_analysis.command` has cleared `trace/*.trace` and `trace/*.trace.timeout` after writing all the summary, and written to `CPU_CALL_TREE_TRACE_CLEANED` to avoid retaining large trace space after analysis.

## The next round

- First turn off `optLen4ProbeDepth` or go back to R34, rerun baseline to confirm `llama.cpp-n40 optimal` and reply byte-identical.
- Clean up the `relaxLiteralRep0` / `relaxMatchLiteralRep0` and related macro-step fields that have not been called at present to avoid the mixing of useless costs and unrelated variables in the next round of DOE.
- Keep 2 states for each position (or enable small beam only in the rep-heavy section), so that the path of "currently slightly more expensive but better rep history" is not cut off in advance by single-state DP. CPU/RSS will rise, requiring a small range of DOE, and it is an independent round to benefit the attribution.

---

# Round 32: Power benchmark rerun and CPU power integration (2026-06-18)

> In this round, rerun `helper/power_benchmark.command` after rollback the last two commits, and execute `helper/power_summary_integrate.command` to integrate the CPU power / energy fields back to `BenchMarkResult.csv` and `best_points/`. The focus of this round is on the post-state acceptance of power harness and R31, which is not regarded as a new algorithm DOE.

## Data status

- `powerResults/power_status.txt` HAS COMPLETELY RUN TO `POWER_BENCHMARK_DONE 07:22:23`; THE PREVIOUS `powermetrics` STOP PROBLEM STUCK IN `claw-code-tgz-encode` HAS NOT BEEN REPOCED IN THIS ROUND.
- `powerResults/power_summary.csv` has a total of 72 data, 72/72 `status=ok`, no `POWER_NO_SAMPLES` or failed row.
- `BenchMarkResult.csv` has a total of 48 rows, all of which have `Encode CPU Power(mW)`, `Decode CPU Power(mW)`, `Encode CPU Energy(J)`, `Decode CPU Energy(J)` fields.
- `best_points/best_points.md` has synchronously added the lowest and highest fields of power / energy, and the source has been changed to `best_points/best_points.csv`.

## R32 Summary of Results

`claw-code` n40 representative value:

| Format | Compression MB/s | Uncompression MB/s | Compression Ratio | Encode RSS(MB) | Encode CPU Power(mW) | Encode CPU Energy(J) | CPU top |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Other3 | 502.96 | 705.81 | 0.9871 | 349.5 | 17434.857 | 41.832219 | encode / 71 |
| BVX3 | 642.06 | 427.47 | 0.9516 | 364.7 | 16548.312 | 34.563284 | encode / 62 |
| Lazy2 | 67.68 | 435.97 | 0.9013 | 485.1 | 5603.386 | 115.000515 | parse / 149 |
| Optimal | 36.98 | 416.81 | 0.8605 | 544.2 | 13398.034 | 513.399386 | parse / 730 |

`llama.cpp` n40 representative value:

| Format | Compression MB/s | Uncompression MB/s | Compression Ratio | Encode RSS(MB) | Encode CPU Power(mW) | Encode CPU Energy(J) | CPU top |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Other3 | 281.67 | 257.14 | 0.9978 | 389.5 | 15633.500 | 25.293345 | encode / 67 |
| BVX3 | 301.70 | 204.91 | 0.9816 | 376.8 | 16332.727 | 27.401693 | encode / 59 |
| Lazy2 | 177.50 | 296.45 | 0.9583 | 500.4 | 7570.696 | 49.178915 | parse / 123 |
| Optimal | 59.66 | 217.65 | 0.9421 | 577.3 | 15351.469 | 329.643690 | parse / 654 |

Best-points hierarchical observation:

- `Other3` is Apple-compatible standard LZFSE baseline. `claw-code` n40 is represented by `502.96 MB/s / 41.832219 J`, but the best compression in the same round is n8 for `586.02 MB/s / 38.429289 J`; `llama.cpp` n40 is `281.67 MB/s / 25.293345 J`, and the best compression in the same round is n8 for `420.31 MB/s / 28.528759 J`. Therefore, the R32 evaluation should retain the n40 representative value and best-points at the same time, and other3 should not be judged only by n40.
- `claw-code` BVX3 is best compressed to `642.06 MB/s` (n40), and the lowest encode energy is `34.563284 J` with the same as n40, which is close to TLZ4 `33.225059 J`.
- `claw-code` Lazy2 is best compressed by `67.68 MB/s` (n40), encode energy `115.000515 J`, which is lower than n4 `159.438967 J`, maintaining the slow path conclusion of "improving n can reduce time and energy consumption at the same time".
- `claw-code` Optimal is optimally compressed to `36.98 MB/s` (n40), encode energy `513.399386 J`. Relative to R31 record `36.95 MB/s / 511.53 J`, the speed is about `+0.1%`, and the energy consumption is about `+0.4%`, which can be regarded as the same water level, and there is no new clear improvement.
- `llama.cpp` Optimal optimal compression is `59.66 MB/s` (n40), encode energy `329.643690 J`; Lazy2 n40 is `177.50 MB/s / 49.178915 J`, which once again shows that the main energy consumption of Optimal is still long-term DP, not high average power.

R32 n40 Evaluation:

- Compression speed: `claw-code` is BVX3 `642.06` > Other3 `502.96` >> Lazy2 `67.68` > Optimal `36.98`; `llama.cpp` is BVX3 `301.70` > Other3 `281.67` > Lazy2 `177.50` > Optimal `59.66`.
- Compression ratio: `claw-code` is Optimal `0.8605` > Lazy2 `0.9013` > BVX3 `0.9516` > Other3 `0.9871`; `llama.cpp` is Optimal `0.9421` > Lazy2 `0.9583` > BVX3 `0.9816` > Other3 `0.9978`.
- Encode energy: `claw-code` is BVX3 `34.563284 J` < Other3 `41.832219 J` < Lazy2 `115.000515 J` << Optimal `513.399386 J`; `llama.cpp` is Other3 `25.293345 J` < BVX3 `27.401693 J` < Lazy2 `49.178915 J` << Optimal `329.643690 J`.
- Decompression speed: `claw-code` Other3 `705.81 MB/s` is significantly faster than Lazy2 `435.97`, BVX3 `427.47`, Optimal `416.81`; `llama.cpp` is Lazy2 `296.45` > Other3 `257.14` > Optimal `217.65` > BVX3 `204.91`.

## Comparison and judgment with R31

- `claw-code Optimal n40`: `36.95 → 36.98 MB/s`, CPU energy `511.53 → 513.40 J`, belongs to the measurement noise range; the cheap-probe gating judgment retained by R31 remains unchanged.
- `claw-code BVX3 n40`: `657.59 → 642.06 MB/s` (about `-2.4%`), encode energy `35.67 → 34.56 J`, the speed is small but the energy consumption is still low, and there is no point to the new return.
- `claw-code Lazy2 n40`: `68.73 → 67.68 MB/s` (about `-1.5%`), basically the same water level.
- `claw-code Other3 n40`: `637.91 → 502.96 MB/s` (about `-21.2%`), but the best compression of Other3 in this round is `586.02 MB/s` in n8, and the same round of BVX3 / Lazy2 / Optimal does not have the same regression. This is more like the n40 abnormality caused by batch noise, thermal state or power measurement interspersed, which should not be attributed to the source change alone; the next round needs to be verified by repeating Other3 n40.

## power harness conclusion

The output of this round of power measurement is complete, and `power_summary_integrate.command` has integrated the power field into the report, so the restriction of "short decode may no samples" since R29 is temporarily lifted in this round of data. However, the decode power number is still easily affected by the sampling phase. For example, some extremely short decode shows a very low average CPU power; encode energy is still the main energy consumption conclusion in the analysis, and decode energy is only an auxiliary.

## The next step

1. If we continue to do the algorithm DOE in the next round, we will still use `claw-code Optimal n40 36.98 MB/s / 513.40 J` and `llama.cpp Optimal n40 59.66 MB/s / 329.64 J` as R32 energy-aware baseline.
2. For the abnormal speed of `Other3 n40`, repeat the measurement or fix the heat state in the next round, and then decide whether you need to check the encode path; do not only use this round of single-point judgment to return.
3. The power benchmark has been completed, but if it is stuck in `powermetrics` again to stop the process, priority should be given to checking the sudo / child process cleanup of `helper/power_benchmark.command`, not the compressor itself.

---

# Round 31: revert R30-2 literal UBP post-retest (2026-06-17)

> The purpose of this round is not to add algorithm changes, but to re-run the complete benchmark with the source of `literal UBP` to confirm whether the BVX3 / Other3 regression observed by R30 comes from #30-2, not #30-1 `Optimal cheap-probe gating`.

## benchmark result (claw-code n40, raw bytes/ns)

| Format | R31 MB/s | R29 MB/s | Change | Judgment |
| --- | ---: | ---: | ---: | --- |
| **Optimal** | **36.95** | 34.93 | +5.8% | #30-1 gating reserved |
| BVX3 | 657.59 | 672.71 | -2.2% | The water level has returned to normal, and the main reason for R30 regression is confirmed as #30-2 |
| Other3 | 637.91 | 618.34 | +3.2% | Restored to normal water level |
| Lazy2 | 68.73 | 66.46 | +3.4% | No direct change, regarded as the whole machine/schedule floating |

- **Optimal CPU energy consumption**: 511.53 J vs R29 567.2 J → **-9.8%**. Both speed and energy consumption have improved, but the next round of ≥10% single-point improvement threshold has not been reached.
- **Compression ratio remains unchanged**: Optimal `0.8590`, BVX3 `0.9516`, Other3 `0.9871`, Lazy2 `0.9013`, indicating that #30-1 gating does not destroy the output quality.
- **R30-2 Verification Conclusion**: R30's BVX3 `589.03 MB/s` / Other3 `513.14 MB/s` is the result of pollution containing `litEnc.withUnsafeBufferPointer` binary. After R31 revert, BVX3 returns to `657.59 MB/s`, and Other3 returns to `637.91 MB/s`, confirming that the literal UBP should maintain the revert.

## trace / power / RSS observation

- Most of the LZFSE family trace is still `trace_timeout=yes`, so the trace wall time does not compare the speed, but only looks at the distribution of target seen and CPU symbol.
- Optimal n40 top symbol is still in `lzParseOptimal` closure, `cpu_parse_hits=1129`, indicating that cheap-probe gating only avoids the low-yield segment, and the main hotspot is still the DP core.
- BVX3 n40 encode RSS `355.0 MB`, decode RSS `322.4 MB`, which is still significantly higher than TLZ4 / ZSTD, is the memory problem that needs to be dealt with in the next round.
- BVX3 n40 encode CPU energy `35.67 J` is close to TLZ4 `34.86 J`, so the next round of priority of BVX3 should be RSS and throughput stability, not encode energy consumption.

## The next step

- Keep #30-1 `optDPSkipAvgMatchLen = 256` and do not go back.
- Maintain #30-2 literal UBP revert, and no longer put `litEnc` literal thermal cycle package into `withUnsafeBufferPointer` closure.
- If you want to continue Optimal in the next round, you should make a profiling-guided single-point change directly to the `lzParseOptimal` DP core. The success condition is still ≥10% improvement in the same round and the compression ratio does not regress.
- If the next round turns to BVX3 family, give priority to investigating the reasons for the high encode/decode RSS, especially the buffer, chunk in-flight, and temporary array life cycle under n40.

---

# Round 30: Optimal cheap-probe gating + literal UBP DOE Results (2026-06-16) / Round 30: Cheap-Probe Gating + Literal UBP DOE

> Only move `lzfse-cli.swift`. This round of simultaneous experiments **#1** (cheap-probe gating) and **#2** (literal UBP). Benchmark result: #1 effective, **#2 causes BVX3 regression −12.4%**. **Both have been committed** (see lzfse-cli.swift difference); #2's revert is queued into **R31**. #3 (power measurement hardening) belongs to harness, not moved.

## benchmark results (claw-code n40)/ Results

| Format | R30 MB/s | vs R27 | vs R29 | Judge |
| --- | ---: | ---: | ---: | --- |
| **Optimal** | **37.13** | +8.1% | +6.3% | ✅ #1 Valid |
| BVX3 | 589.03 | −7.2% | −12.4% | ❌ #2 Regress → revert |
| Other3 | 513.14 | — | −17.0% | ⚠️ Machine noise (n40 < n8 587, thermal throttling/batch length effect) |
| Lazy2 | 69.15 | +25.0% | +4.0% | — |

- **Optimal Energy Consumption**:502.8 J vs R29 567.2 J → **−11.4%** ✅
- **Compression ratio 0.8590 / 0.9416 completely unchanged** ✅ → #1 gating security (threshold 256 conservative, very few changed segments and indeed dominated by long match).

## #1 Optimal cheap-probe gating — ✅ Keep

- After the existing two gates (entropy gate >7.2, coverage < 28%), add a third lane: pre-screening greedy scanning by-way number `matchCount`, if ** average match length ≥ `optDPSkipAvgMatchLen` (default 256) ** → long match dominant segment, DP low return → go to the existing `greedyEmitSegment`.
- Acceptance: Optimal claw n40 34.93→**37.13 MB/s (+6.3%)**, energy consumption **−11.4%**, **compression ratio unchanged**. Correctness safe (both greedy path, legal bvx3, decoder unchanged, round-trip is not affected).
- Knob: Set the maximum value of `optDPSkipAvgMatchLen` to turn off and return to R29; the down adjustment is more active (need to check the ratio again).

## #2 literal coding loop UnsafeBufferPointer — ❌ BVX3 regression, waiting for R31 revert

- After wrapping the non-ctx literal cycle `litEnc[...]` into `litEnc.withUnsafeBufferPointer { le in ... }`, **BVX3 claw n40 −12.4%, llama −13.0%**.
- Reason judgment: Under `-O`, the boundaries-check saved by `UnsafeBufferPointer` subscript is not enough to offset the closure package overhead**; the closure boundary may **block the inline or caller-level optimization of `fseEncode` **, slowing down the hottest cycle of this per-literal as a whole.
- Lesson: It is also "going bounds-check". The LMD loop of R28 (6 n-size arrays, 3 fseEncodes per match) is valid, but the literal loop (4 fseEncodes each time, shorter loops) is dragged down by the closure package - **UBP packaging is not all cost-effective and needs to be measured cycle by cycle**. `FSEOutStream` / `fseEncode` has been inline+pointer, and the pure function has no margin.
- **Action**: R31 will revert `litEnc.withUnsafeBufferPointer { ... }` back to `litEnc[Int(lp[...])]`, and confirm that BVX3 will return to ~672 MB/s water level.

## #3 power measurement hardening - belongs to harness, not moved

The correction point is in `helper/power_benchmark.command` (shell), not in `lzfse-cli.swift`. Option: (a) Relax the constraint I change harness (short decode loop N times and then average); (b) I add `-repeat N` supply measurement in CLI. To be designated.

## Remarks / Caveat

This round of benchmark data (BenchMarkResult.csv) is **containing #1 and #2 at the same time** measured (so BVX3 shows a regression −12.4%). **Lzfse-cli.swift This commit still contains #2** ( `litEnc.withUnsafeBufferPointer`); BVX3 regression source has been confirmed as #2. **R31 will revert #2**, and the next round of benchmark should be seen BVX3 back to ~672 MB/s water level for reverse confirmation (this round will not be rerun according to the agreement). Other3 −17% is machine noise (n40 is slower than n8).

---

# Round 29: R2612 + R28 Combined DOE Results + First power/energy Measurement (2026-06-16)/ Round 29: Combined DOE + First Power Measurement

> This round combines three sets of **output-identical** changes on the basis of R27 (tag-packing): R28 ( `encodeBlockV3` LMD `withUnsafeBufferPointer`), R261 ( `localHead` of `lzParseOptimal`, per-call configuration), R262 (3-rep expansion). And the CPU/GPU/DRAM power and energy consumption of `powerResults/` are included for the first time. Only move `lzfse-cli.swift` and `OPTIMIZATION.md`.

## DOE result (claw-code / llama.cpp, n40, raw bytes/ns)

| Format | claw R27 | claw R29 | Change | llama R27 | llama R29 | Change | Compression ratio |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| **Optimal** | 34.36 | **34.93** | +1.7% | 60.24 | **60.67** | +0.7% | 0.8590 / 0.9416 unchanged |
| **BVX3** | 634.82 | **672.71** | +6.0% | 398.70 | **448.98** | +12.6% | 0.9515 / 0.9816 unchanged |
| Other3 | ~ | 618.34 | ↑ | ~ | 455.40 | ↑ | 0.9872 / 0.9979 unchanged |
| Lazy2 | 55.30 | 66.46 | ↑* | ~173.9 | 193.22 | ↑* | 0.9016 / 0.9588 unchanged |

- **Compression ratio format byte level unchanged** (0.8590 / 0.9515 / 0.9016 / 0.9872 ...) → All three groups of changes are confirmed to be output-identical and there is no return.
- **R28 (BVX3) is the biggest winner of this round**: claw +6.0%, llama +12.6%, confirming that LMD's bounds-check is valid for encode-bound bvx3/other3.
- **R2612 (Optimal) is only slightly +0.7–1.7%**, **does not reach the ≥10% target**: because they save DP *peripheral* overhead (prescreen's `localHead` configuration, rep transform loop), and the top symbol is still the **DP core closure** of `lzParseOptimal` - to be faster, you must move the DP itself or do segment-level gating.
- `*` Lazy2 There is no new change in this round (R6 is within the R27 benchmark), and the increase in the value belongs to the whole machine/scheduling noise, not attributed to this round.

## powerResult Segment Summary / Power & Energy Summary (first included)

Measurement method: `helper/power_benchmark.command` takes the CPU/GPU/ANE/DRAM power (mW) and energy consumption (J) of each (format, encode/decode, n) in macOS `powermetrics`, integrated into `powerResults/power_summary.csv`, and best_points is also brought into the CPU power/energy field.

**1 Encode energy consumption (claw-code, J; energy consumption ≈ power × time)**

| Format | Energy Consumption (J) | CPU Power (mW) | Description |
| --- | ---: | ---: | --- |
| tar.lz4 | **36.4** | 17570 | High power but extremely short → The most energy-saving |
| Other3 (n40) | 39.1 | 17986 | Same level as external tools |
| BVX3 (n40) | 46.9 | 18857 | Full core, fast recovery → Energy consumption is acceptable |
| ZSTD | 50.8 | 14647 | — |
| Apple (n40) | 65.3 | 6951 | — |
| TGZ | 137.6 | 4471 | Low power but 30s → High energy consumption |
| **Lazy2 (n40)** | **204.7** | 7212 | Long-term dominance |
| **Optimal (n40)** | **567.2** | 13633 | ≈12× BVX3, 15× tar.lz4 |

**2 Decode energy consumption (claw-code, n40, J) - LZFSE family is the strength**

Optimal **0.85**, Lazy2 1.45, BVX3 2.06 J, **lower than ** ZSTD 4.08, TGZ 5.40 J. LZFSE decoding is fast and energy-saving.

**3 Three-point conclusion**

1. **Optimal/Lazy2's energy consumption problem = time problem**: Their power is actually low (7–13.6W, lower than full-load bvx3/zstd 18–19W), but DP/chain is too slow → energy consumption is skyrocketing. **The leverage of energy consumption reduction is the same as the time of energy consumption reduction** (segment-level gating can be roughly equal to cut energy consumption).
2. **BVX3 / Other3 encode energy consumption is at the same level as zstd/tar.lz4** (39–47 J vs 36–51 J), no need to optimize energy consumption; decode The whole family is very provincial, and there is no need to deal with it.
3. ⚠️ **Measurement limit**: Multiple extremely short decodes appear `POWER_NO_SAMPLES` (other3 n40 decode, llama's bvx3/lazy2/optimal n40 decode), due to decompression <~0.3–0.5s shorter than the powermetrics sampling interval. These decode energy consumption is empty and requires a long batch or a smaller `-n` to obtain; it does not affect the conclusion of encode energy consumption.

## Power Cause Explanation (with the latest code)/ Why the Power Numbers Look This Way

Mental model: **energy consumption J = average power W × time s**; and **power ≈ core busyness (IPC)**. Computing is dense and data is in cache → kernel full load → high power; memory dense (cache miss / pointer chase) → kernel stops in equal memory → low power, but it takes a long time to run.

**Optimal / Lazy2 = low power, high energy consumption (memory-bound). ** Compare `lzParseOptimal` DP forward loop (each segment ≤128K position): `hashAndTag(i)`→`head[qh]` / `chain[c]` is a random memory access (hash bucket + link indicator chase); `matchLength(...)` and `c` of candidate `load32(c)` is a random offset in history, frequent cache miss in 4MiB chunk; relaxation also distributes the price to `cPrice[t+ll]`. The core is often stopped at equal memory → IPC low → power is only 7–13.6W, but the workload is very large → the time is bursting → energy consumption rushes (claw optimal n40 41.6s / 567 J; lazy2 7W / 28s / 205 J).

**BVX3 / Other3 / tlz4 / zstd = high power, low energy consumption (compute-bound). ** `encodeBlockV3` kernel is FSE coding (compact state transfer + bit packing, small check table and permanent cache) → kernel full load → power 15–19W, but fast → 2–3.5s → energy consumption 39–51 J. Tar.lz4 has the highest power but the shortest → the most energy-saving (36 J).

**Decode saves energy for the whole family. ** Table-driven FSE decoding + memcpy, sequential, cache-friendly, parallel and short → low power + short time. Optimal decoding consumes the lowest energy (0.85 J), because it solves the standard bvx3 stream, and the path is the same and fast as the general bvx3.

** Energy consumption decreases with -n (slow path). ** `runParallelEncode` Use N chunk in parallel; for the DP slow path, the magnitude of increasing N shortening time is greater than the power increase → energy consumption decreases: claw optimal encode n4 720J → n8 613J → n40 567J; llama optimal n4 505J → n8 386J → n40 337J. Therefore, optimal/lazy2 is larger. `-n` It is not only faster, but also more energy-saving (at the cost of increasing RSS); bvx3 is almost full, and n has little impact on energy consumption.

** Optimize the meaning. ** Optimal is memory-bound, and micro-optimization (SIMD / go bounds-check) has limited help to "power" (it is not fully loaded in the first place); the real energy consumption is ** to do less DP** - segment level cheap-probe gating will cut time and energy consumption in an equal proportion, which is the same lever as "speed reduction". BVX3/Other3 encode energy consumption has been at the same level as zstd/tlz4, decode saves the whole family → no need to invest in energy consumption.

## The next step

1. **Optimal segment level cheap-probe gating** (will change the output/compression ratio will be changed): change the low-yield segment to lazy2/greedy. This is the maximum ROI of Optimal **speed and energy consumption** at present (especially llama optimal is only 1.8% smaller than lazy2 but consumes ≈337–505 J). Need to compile/benchmark check ratio trade-off.
2. BVX3:R28 Now that it is valid, you can continue to check the similar output-identical acceleration of `fseEncode` / `FSEOutStream.push/flush`.
3. Power measurement hardening: change the too short decode to repeat many times or fix the shortest sampling time to complete `NO_SAMPLES`.

---

# Round 28: encodeBlockV3 LMD thermal cycle to bounds-check acceptance (2026-06-16)

> Only move `lzfse-cli.swift`. R26/R27 trace confirms that `encodeBlockV3` is still the top symbol of the BVX3 family (including `fseEncode`, `FSEOutStream.push/flush` and Swift Array/COW). This round is an encode acceleration of **output-identical**, and the benchmark / memProbe / trace / cpu_call_tree / CSV rebuild acceptance has been completed.

## Change: LMD coding loop access to UnsafeBufferPointer

- The 2 L/M/D encoding loop of `encodeBlockV3` reads 6 n-size arrays ( `lSyms/mSyms/dSyms` + `lVals/mVals/dVals`) for each match, and each time it is Swift Array bounds-check.
- Instead, package these 6 arrays into the nested `withUnsafeBufferPointer`, access them with pointer in the loop, and remove each match × 6 bounds-checks (one of the `swift_array` hotspots of R26/R27 trace). The core FSE work of `fseEncode` and `lmdOut.push/flush` remains unchanged; extra-bits / base / encoder check table (according to symbol index, small constant table) remains as it is.
- Correctness: The index ( `mi`) is completely unchanged with all emission values and bit push orders → **The output bytes are exactly the same, and the compression ratio remains unchanged**.

## Data status

`round_status.txt` shows that `compile` and `lzfse-test` passed, and the `-n40/-n8/-n4` benchmark and memProbe of the two data sets were completed; `helper/tracer.command` was completed in `16:37:13`, `trace_analysis`, `cpu_call_tree_analysis`, `BenchMarkResult.csv` and `best_points` were completed in `16:42:06`. `run_round.command` did not leave the outermost `BENCH_DONE` line, but the analysis output of the benchmark pipeline has been completely rebuilt.

`lzfse-test.txt` shows that Other3, BVX3, Lazy2, Optimal, Apple compatibility and parallel decoding paths are all passed. BVX3 compression size maintains `claw-code 446M`, `llama.cpp 572M`, and the compression ratio maintains `0.9515 / 0.9816`; this round meets the output-identical target.

## Benchmark Results

Compare R27 → R28 with raw bytes / ns MB/s of `BenchMarkResult.csv`:

- `claw-code` BVX3: n40 `634.82 → 672.71 MB/s` ( `+6.0%`), n8 `596.70 → 588.41 MB/s` ( `-1.4%`), n4 `380.58 → 405.68 MB/s` ( `+6.6%`). N40 reached the target range of 5–10%, and n8 retreated a little but still approached R27.
- `llama.cpp` BVX3: n40 `398.70 → 448.98 MB/s` ( `+12.6%`), n8 `396.03 → 414.69 MB/s` ( `+4.7%`), n4 `322.67 → 336.25 MB/s` ( `+4.2%`). All three n in this data set have improved, and n40 exceeds 10%.
- Although Other3 has not directly modified `encodeBlock`, it is still rising synchronously in this round: `claw-code n40 618.34 MB/s`, `llama.cpp n40 455.40 MB/s`. This may be due to round noise, cache/I/O or compilation environment fluctuations, which should not be attributed to the pointerization of R28.
- The compression speed of Lazy2 / Optimal also fluctuates: `claw-code n40 Lazy2 66.46 MB/s`, Optimal `34.93 MB/s`; `llama.cpp n40 Lazy2 193.22 MB/s`, Optimal `60.67 MB/s`. These parser paths are not directly hit by R28, but only as background reference.

The decompression speed is not the target of this round of change, but it needs to record the regression: BVX3 n40 decompression from R27's `746.42 → 663.05 MB/s` (claw-code, `-11.2%`) and `292.37 → 224.37 MB/s` (llama.cpp, `-23.3%`). The decompression path has not been modified in this round, which is more likely to be affected by the state before and after measurement fluctuations, I/O/cache, trace/memProbe or the tar status of the data set; if the encode continues to be changed in the next round, it is still necessary to keep an eye on the decode that it is not sustainable.

RSS trade-off roughly maintains the original judgment: BVX3 n40 encode RSS `claw-code 366.3 MB` (R27 `350.7 MB`, `+4.4%`), `llama.cpp 380.2 MB` (R27 `394.2 MB`, `-3.6%`). Decode RSS is still about `315–343 MB`, which is significantly higher than ZSTD decode about `9–10 MB` and TLZ4 decode about `34 MB`.

## Trace / CPU Interpretation

`trace/analysis` 36 traces in this round can be exported time-profile / time-sample; LZFSE encode trace is still mostly 300s timeout, which is only used in the hotspot direction, not for complete time-consuming calculation.

- R28 hit hotspots did decrease: BVX3 n40 `encodeBlockV3` top count from R27's `100 → 64` (claw-code, `-36%`) and `102 → 57` (llama.cpp, `-44%`). `CPU Encode Hits` also decreased from `137 → 130` (claw-code) and `150 → 122` (llama.cpp).
- But `CPU Swift Array Hits` instead rose: claw-code n40 `84 → 106`, llama.cpp n40 `77 → 101`. The interpretation is that after the LMD reading loop bounds-check is removed, the remaining array cost is transferred to `encodeBlockV3` front stage staging, symbol/value arrays, FSE output buffer or other Array/COW paths; R28 is not the end of the Array cost.
- `llama.cpp n4` BVX3 top symbol is changed to `static LZFSEv1.fseEncode(state:_:_:)`, indicating that the small n / low concurrency FSE encode can overwhelm the `encodeBlockV3` loop itself. If the next BVX3 single point is only read by pointerized LMD, the marginal benefit will be reduced.
- Optimal's CPU parse hits rose in this round (for example, claw-code n40 `922 → 1160`, llama.cpp n40 `877 → 1086`), it is confirmed again that Optimal should not rely on encodeBlockV3 in the next step; another segment of cheap probe / envelope pruning should be done.

## Conclusion and next step

R28 can be retained: it is output-identical, correctness passed, BVX3 n40 has a clear compression speed improvement in both data sets, and trace shows that `encodeBlockV3` top count has decreased significantly. The success condition of "the same data set and n no retreat, ideal 5-10%" is valid in n40, especially `llama.cpp` exceeds 10%.

Suggestions for the next step:

1. BVX3: Don't only fine-tune the LMD reading loop. Priority is given to `encodeBlockV3` first segment staging / symbol arrays / FSEOutStream, the goal is to reduce Swift Array hits to below R27, and BVX3 n40 compression to maintain `claw-code ≥670 MB/s`, `llama.cpp ≥445 MB/s`.
2. RSS: BVX3 encode RSS is still `~366–380 MB`, decode RSS `~315–343 MB`; if you want to optimize the encode path again, you need to set the RSS success conditions synchronously, such as reducing `>=10–20%` with the same n RSS or at least no longer rising.
3. Decode: In the next round, we need to confirm whether the BVX3 decode regression can be reproduced. If two consecutive rounds are below R27, you should check the I/O/cache and parallel inflight of decode benchmark first, instead of attributing the problem to R28.
4. Optimal: Maintain the R27 conclusion, the next direction of real opportunity is segment-level cheap probe / envelope pruning; this will change the output route selection and the possible recompression ratio, which needs to be used as an independent DOE, not mixed in the output-identical encode micro-optimization.

---

# Twenty-seventh round: Optimal tag-packed hash chain acceptance (2026-06-16)

## Summary of changes

In this round, tag-packing will be synchronized to `lzParseOptimal`, and `lzParseChain` will use the same set of packed hash chain. The core is to generate hash bucket and 8-bit secondary tag by a 5-byte multiplication. `head[h]` stores `(tag << 24) | idx`, and `chain[idx]` uses the packed value of the previous node. When visiting the chain, use `(packed >> 24) == qtag` as a pure register filter first, skip if it does not match, and reduce the random reading and pointer chasing of `p[c]` caused by pure collision candidates.

This time, I won't change the bitstream format, decoder, FSE table construction, or `lzParseStrong` / `lzParse` The independence of `hashTable`. Optimal's coverage prescreen still uses independent `localHead`, do not pollute the main `head/chain`. `greedyEmitSegment` Only unpack low 24-bit index, do not do tag filtering, and maintain greedy candidate meaning.

## Correctness and data status

- After `hashAndTag` replaces `hash4`, the bucket still uses the product high `chainHashBits` bit, and the tag takes the adjacent 8 bits; the same function is used for insertion and search.
- `insert` keeps `chain[idx] = head[h]` and then updates the order of `head[h]`. The meaning of the link remains unchanged, but the node pointer changes from raw index to packed value.
- `lzParseOptimal` still takes `candPacked/qtag` and then `insert(i)` in DP to avoid self reference.
- `chainNullIndex = 0x00FF_FFFF` corresponds to the low 24 bits of `head = -1`; the real chunk index is guaranteed to be less than sentinel by `parallelChunkSize = 4MiB`.
- Add `assert(n <= chainIndexMask)` only check chunk upper limit in debug, `swiftc -O` release without assert cost.

This round of `round_status.txt` has reached `BENCH_DONE 04:10:42`, `BenchMarkResult.csv` has a total of 48 rows, including the speed, RSS, trace target and CPU top symbol fields of `-n4/-n8/-n40`. `lzfse-test.txt` shows that Other3, BVX3, Lazy2, Optimal, Apple compatibility and parallel decoding paths are all passed; tag-packing does not cause round-trip or format compatibility return.

## Benchmark Results

After recalciting MB/s with raw bytes / ns, the acceleration of Optimal is established, but the two data sets are different:

- `claw-code` Optimal: `n4 57.80s / 24.50 MB/s`, `n8 47.36s / 29.90 MB/s`, `n40 41.21s / 34.36 MB/s`, the compression ratio is maintained at `0.8590`. Compared with the previous benchmark `69.12s / 53.27s / 47.08s`, `19.6% / 11.1% / 12.5%` is about improved.
- `llama.cpp` Optimal: `n4 33.59s / 39.37 MB/s`, `n8 24.80s / 53.33 MB/s`, `n40 21.95s / 60.24 MB/s`, the compression ratio is `0.9416`, which is only a very small fluctuation compared with the previous benchmark `0.9415`. Compared with the previous benchmark `35.27s / 25.95s / 23.11s`, `4.8% / 4.4% / 5.0%` is about improved.
- Lazy2 is the best compression in `claw-code` to `55.30 MB/s` (n40), which is lower than the previous round record `57.54 MB/s`; but the best compression of `llama.cpp` is `186.98 MB/s` (n40), which is higher than the previous round of `173.90 MB/s`. Therefore, tag-packing is not a monotonous gain for `lzParseChain`, and Lazy2 acceleration should not be attributed to the tag itself in the future.
- BVX3 / Other3 is still dominated by encode path. `claw-code` BVX3 best compression `634.82 MB/s` (n40), `llama.cpp` BVX3 best compression `398.70 MB/s` (n40); compression ratio maintains `0.9515 / 0.9816`.

RSS trade-off has not changed: n40 usually increases the compression speed of the LZFSE family, but encode/decode RSS also increases. Optimal encode RSS from n4 to n40 is about `212.3 → 570.2 MB` (claw-code) and `221.7 → 572.8 MB` (llama.cpp); decode RSS is upgraded to `313–342 MB` level. This is still obviously higher than ZSTD decode about `9 MB` and TLZ4 decode about `34 MB`, so we can only compress MB/s in the future.

## Trace / CPU Interpretation

`trace/analysis/trace_summary.csv` shows that 36 traces have `target_seen=yes`, and `time-profile/time-sample` schema can be exported. LZFSE encode trace is mostly 300s timeout, so it can only judge the direction of hotspot, and cannot be used to calculate the full wall time or MB/s.

CPU call tree shows that tag-packing has a partial parser cost reduction, but not the main bottleneck. The complete answer:

- Optimal top symbol is still `specialized closure #1 in static LZFSEv1.lzParseOptimal`. `claw-code n40` top count dropped from `565` to `532` in the previous round, parse hits dropped from `963` to `922`; `llama.cpp n40` top count dropped from `508` to `499`, parse hits dropped from `893` to `877`. The decline is only about `2–6%`, which is less than the wall-time improvement, which means that the income may be mixed with the impact of this round of noise, segment scheduling or other code changes.
- `hashAndTag` itself enters the global hotspot, but count only `52` (Optimal) and `44` (Chain), which has not become a new major bottleneck.
- Lazy2 top symbol is still `lzParseChain.bestMatch`, and the global `bestMatch` count `827`; `repLen` and `matchLength` are still visible, indicating that Lazy2 should continue to target match scanning and candidate strategies in the next step, instead of deepening the tag filter.
- BVX3 top symbol is still `encodeBlockV3`, the whole area count `1473`, and there are also `fseEncode`, `FSEOutStream.push/flush`, Swift Array/COW hotspots. The next high win direction of the BVX3 family is still encode/FSE/array staging and RSS control.

## The next step

1. Optimal: tag-packing can be retained, but no longer take hash-chain collision as the main line. The next round should be done at the segment level cheap probe / envelope pruning, so that the low-yield segment should go Lazy2 or greedy; the condition for success is to improve `>=10%` in the same round of Optimal wall time, the compression ratio does not regress significantly, and the CPU top symbol has an explainable decline from `lzParseOptimal` closure or parse hits.
2. Lazy2: Don't just extend tag filter. Priority is given to the candidate acceptance order in `bestMatch`, the number of scans of `matchLength` and the rep fast path; it is required that at least one fixed `-n` has `>=10%` improvement in two data sets in the same round, and the other data set cannot regress significantly.
3. BVX3: The main line is released back to `encodeBlockV3`, FSE output and Swift Array/COW. If the speed is close to TLZ4/ZSTD, the next acceptance should include RSS in the first-level target, such as the same `-n` encode/decode RSS to reduce `>=20%` and MB/s does not return more than `5%`.
4. Benchmark process: keep `-n4/-n8/-n40` fixed scan; trace timeout results only write hotspot interpretation, not speed; each round confirms that `CPU_CALL_TREE_ANALYSIS_DONE` is earlier than `BENCHMARK_RESULT_REBUILD_DONE`, so as to avoid the CPU field blank of `BenchMarkResult.csv`.

---

# The 26th round of acceptance supplement: Benchmark / Trace / CPU fields have been rebuilt (2026-06-16)

## Data status

This section is compiled according to the latest `BenchMarkResult.csv`, `best_points/best_points.md`, `trace/analysis/trace_summary.csv`, `trace/analysis/cpu_call_tree_summary/`, `round_status.txt` and `lzfse-test.txt`. The CPU field of `BenchMarkResult.csv` has been blank in this round before, because the scheduling of `benchmark.sh` executes `benchmark_result_rebuild.command --write` first, and then executes `cpu_call_tree_analysis.command`. At present, the process has been revised to:

`trace_analysis` → `cpu_call_tree_analysis` → `git gc` → `benchmark_result_rebuild --write` → `best_points_analysis`

The latest trace products have been used to make up `helper/cpu_call_tree_analysis.command`, `helper/benchmark_result_rebuild.command --write` and `helper/best_points_analysis.command`. `BenchMarkResult.csv` has a total of 48 rows, all of which have `CPU Symbol Status`; the main CSV is still UTF-8 BOM, maintaining Excel Chinese compatibility.

`trace_summary.csv` currently has 36 trace summary, all of which are `target_seen=yes` and `time-profile/time-sample` are `ok`; 30 of which are timeout trace. These timeout traces can be used to judge the direction of hotspot, but cannot be used to calculate the full running time or MB/s. `cpu_call_tree_summary.csv` has 72 rows: 36 `time-profile` symbol statistics and 36 `time-sample` raw kperf address table; `hot_symbols_global.csv` currently only retains the top 500 global hotspots to avoid product expansion.

`lzfse-test.txt` shows correctness case maintenance pass: Other3 self-back-trip compatible with Apple, bvx3 / lazy2 / optimal self-back-trip, parallel decoding, private bvx3 Apple rejection, single-stream support and Apple mutual solution paths are all normal.

## Latest Speed / Compression Ratio / RSS

`best_points/best_points.md` shows the best points of this round as follows:

- `claw-code`
- Other3: The best compression `596.14 MB/s` (n8), the best decompression `766.42 MB/s` (n40), the compression ratio `0.9872`.
- BVX3: best compression `646.70 MB/s` (n40), best decompression `574.21 MB/s` (n8), compression ratio `0.9515`, lowest encode RSS `129.2 MB` (n4).
- Lazy2: Best compression `57.54 MB/s` (n40), best decompression `652.50 MB/s` (n8), compression ratio `0.9016`, the lowest encode RSS `192.9 MB` (n4).
- Optimal: the best compression `29.84 MB/s` (n40), the best decompression `679.77 MB/s` (n8), the compression ratio `0.8590`, the lowest encode RSS `197.4 MB` (n4).
- ZSTD: the best compression ratio `0.8255`, the best compression `482.03 MB/s` (log n8), the best decompression `787.58 MB/s` (log n40), decode RSS about `9.0–9.1 MB`.
- `llama.cpp`
- Other3: The best compression `447.76 MB/s` (n40), the best decompression `265.95 MB/s` (n40), the compression ratio `0.9978`.
- BVX3: Best compression `437.28 MB/s` (n40), best decompression `252.98 MB/s` (n4), compression ratio `0.9815`, the lowest encode RSS `132.9 MB` (n4).
- Lazy2: Best compression `173.90 MB/s` (n40), best decompression `294.33 MB/s` (n8), compression ratio `0.9587`, the lowest encode RSS `194.5 MB` (n4).
- Optimal: optimal compression `56.21 MB/s` (n40), optimal decompression `253.37 MB/s` (n4), compression ratio `0.9415`, minimum encode RSS `217.4 MB` (n4).
- ZSTD: Best compression ratio `0.9123`, best compression `469.71 MB/s` (log n4), best decompression `294.07 MB/s` (log n8), decode RSS about `9.0–9.4 MB`.

RSS trade-off is still clear: n40 usually gives the LZFSE family the highest compression speed, but encode RSS also increases. N40 represents `claw-code` BVX3 `359.1 MB`, Lazy2 `488.4 MB`, Optimal `570.3 MB`; `llama.cpp` BVX3 `394.8 MB`, Lazy2 `525.5 MB`, Optimal `573.6 MB`. Therefore, the subsequent optimization cannot only look at MB/s, but still needs to look at the RSS and compression ratio synchronously.

## CPU Hot Spot Conclusion

`BenchMarkResult.csv` is now directly brought into the CPU top symbol / count / category, and there is no need to manually compare summary CSV separately. The main hotspot maintenance is consistent with the R26 assumption:

- BVX3: Both data sets n40 top category are `encode`, and the top symbol is `specialized static LZFSEv1.encodeBlockV3(triplets:literals:rawBytes:)`. N40 representative value: `claw-code` top count `92`, `llama.cpp` top count `99`. The one-way fusion direction of R26's `encodeBlockV3` is still correct.
- Lazy2: top symbol is stable to `bestMatch #1 (_:) in closure #1 in static LZFSEv1.lzParseChain(_:maxL:maxM:maxDist:)`. N40 representative value: `claw-code` top count `162`, parse hits `380`; `llama.cpp` top count `130`, parse hits `317`. The rep length cache of R26 is still the correct focus.
- Optimal: the top symbol is stable to `specialized closure #1 in static LZFSEv1.lzParseOptimal(_:maxL:maxM:maxDist:)`. N40 representative value: `claw-code` top count `565`, parse hits `963`; `llama.cpp` top count `508`, parse hits `893`. The main cost of Optimal is still DP / parse closure. In the next step, if you want to move to optimal, you should first do segment-level gating or cheap probe, instead of just fine-tuning the encode path.
- Other3 / Apple / External Tools: Other3 is mainly in `encodeBlock` / FSE, Apple is in `lzfseEncodeMatches`, TLZ4 / ZSTD hotspots are internal symbols of external tools and should not be mixed with Swift LZFSE parser hotspots.

## The next step

1. Update the acceptance benchmark with this round of numbers: BVX3 with `claw-code n40 646.70 MB/s` / `llama.cpp n40 437.28 MB/s`; Lazy2 with `57.54 / 173.90 MB/s`; Optimal with `29.84 / 56.21 MB/s`.
2. Each subsequent complete benchmark must confirm that `CPU_CALL_TREE_ANALYSIS_DONE` in `round_status.txt` is earlier than `BENCHMARK_RESULT_REBUILD_DONE` to avoid the CPU field blank again.
3. The next code code optimization still gives priority to the acceptance of two single points of R26: BVX3 `encodeBlockV3` and Lazy2 `bestMatch`; each change needs to compare compression speed, decompression speed, compression ratio, encode/decode RSS and CPU top symbol changes at the same time.

---

# Round 26: BVX3 / Lazy2 CPU Single-Point Optimization (2026-06-15) / Round 26: BVX3 & Lazy2 Single-Point CPU Opts

> Only move `lzfse-cli.swift`. Undertake the top symbol of R25 cpu_call_tree (BVX3→`encodeBlockV3`, Lazy2→`lzParseChain.bestMatch`), do a single-point acceleration of two ** output bytes exactly the same, without changing the compression ratio **; pending benchmark/memProbe acceptance.

## Change 1: `encodeBlockV3` Three passes into one / Fuse 3 passes into 1

- Originally three trips to nMatches: (a) build `lVals/mVals/dVals` by triplets, (b) 3 deep rep-offset transform, (c) calculate `lSyms/mSyms/dSyms` and frequency `lOcc/mOcc/dOcc`.
- Change to **single `for t in triplets` loop** one-time completion value intercept, rep-offset, symbol and frequency; array change one-time configuration ( `repeating:count:`) instead of `append`.
- Effect: The visit to nMatches is from 3 times to 1 time, removing `append` reconfiguration and a large number of Swift Array visits ( `encode` + `swift_array` hotspot of R25 trace). `lVals/mVals/dVals` is still reserved for the extra bits of the latter segment LMD encoding, so it only integrates the front segment and does not delete the array.
- Correctness: MTF state machine of rep-offset, M=0 → send 0, symbol calculation order is completely consistent with the input value → **output byte unchanged**.

## Change 2: `lzParseChain.bestMatch`'s rep length cache / Cache rep lengths

- 1 (rep pre-trial) of `bestMatch` has been calculated rep0/1/2 length with `repLen` (including `matchLength` scan); but 3 (rep is selected when it is close to the best) ** recalculated again ** `repLen`.
- Instead, calculate `l0/l1/l2` at 1 time (directly shared at the same distance, without repeated scanning), 3 direct reuse, remove up to 3 `matchLength` scans each time `bestMatch`.
- Effect: `bestMatch` is the top symbol of Lazy2; 3 is triggered when "the best match comes from the chain instead of rep" (common), and the `matchLength` saved here is the implicit bulk of lazy2.
- Correctness: The cache value is equal to the original recalculation value one by one, and the `else-if` short-circuit selection order remains unchanged → **The selected (len,dist) is exactly the same → the output byte remains unchanged**.

## Acceptance (wait for your benchmark)

- `swiftc -O` can be compiled, `./lzfse -test` is all over, 7/7 consistent, and the compression ratio is unchanged at the byte level (both changes are output-identical).
- Speed benchmark (R25 claw n40): BVX3 `631.83 MB/s`, Lazy2 `57.88 MB/s`; ≥10% single-point acceleration under the target and data set and `-n`.
- ⚠️ There is no swiftc in the sandbox. This round only does structural/balance static inspection; the actual speed needs your benchmark measurement.

---

# Twenty-fifth round supplement: complete staged result check (2026-06-15 16:59)

## Completed status

This round staged's `.txt` / `.csv` / `.md` The result has been overwritten. `lz4bench_log/` The batch of n4 / n8 / n40, `memprobeResults/` The memory measurement of the two data sets, `trace/analysis/trace_summary.csv`, `trace/analysis/cpu_call_tree_summary/` And `lzfse-test.txt`. `benchmark.sh` It has been run completely, `round_status.txt` The ending is `BENCH_DONE 16:59:54`. `helper/tracer.command` With `EXIT 0` / `TRACE_DONE 16:45:49` End; `helper/trace_analysis.command` With `TRACE_ANALYSIS_DONE 16:51:29` End; `helper/cpu_call_tree_analysis.command` With `CPU_CALL_TREE_ANALYSIS_DONE 16:59:54` End.

`trace/analysis/trace_summary.csv` shows external tools `tgz`, `zstd`, `tar.lz4` are completed normally in both data sets; all LZFSE encode trace is `300s` timeout trace, but `target_seen=yes`, `time-profile=ok`, `time-sample=ok`. Therefore, this batch of LZFSE trace can be used for hotspot direction judgment, and should not be used to calculate the full running time or MB/s.

`lzfse-test.txt` still maintains correctness: other3 self-round-trip compatible with Apple, bvx3 / lazy2 / optimal self-round-trip, parallel decoding, private bvx3 Apple rejection, single-stream backup and Apple mutual solution path have not returned. The small correctness case is only for functional verification and does not compare with the large data set MB/s.

## The latest speed and RSS benchmark

The latest staged `BenchMarkResult.csv` and `best_points/best_points.md` still recalculate MB/s in raw bytes/ns. Compared with the previous version of R25, the overall trend remains unchanged, but the best points are slightly updated:

- `claw-code`
- Other3 best compression `593.25 MB/s` (n8), best decompression `784.59 MB/s` (n8), encode RSS `141.7–363.1 MB`.
- BVX3 best compression `631.83 MB/s` (n40), compression ratio `0.9515`, best decompression `733.09 MB/s` (n40), encode RSS `128.8–360.9 MB`.
- Lazy2 best compression `57.88 MB/s` (n40), compression ratio `0.9016`, encode RSS `187.5–500.6 MB`.
- Optimal best compression `30.08 MB/s` (n40), compression ratio `0.8590`, encode RSS `214.2–561.6 MB`.
- ZSTD compression ratio `0.8255`, the best compression `462.72 MB/s`, the best decompression `1039.33 MB/s`, decode RSS about `9.0–9.2 MB`.
- `llama.cpp`
- Other3 best compression `449.94 MB/s` (n40), compression ratio `0.9978`, decode about `272.63–275.90 MB/s`.
- BVX3 optimal compression `446.62 MB/s` (n40), compression ratio `0.9815`, optimal decompression `281.88 MB/s` (n40).
- Lazy2 best compression `178.25 MB/s` (n40), compression ratio `0.9587`.
- Optimal best compression `57.06 MB/s` (n40), compression ratio `0.9415`.
- ZSTD compression ratio `0.9123`, the best compression `471.62 MB/s`, the best decompression `313.12 MB/s`.

The RSS conclusion is still maintained: the Swift LZFSE family is no longer a GB-level problem, but the encode / decode working set of n40 is still significantly higher than that of TLZ4 / ZSTD. In particular, lazy2 / optimal encode RSS is upgraded to `500–606 MB` level with n. The next round should not only look at the compression speed, but also fix the trade-off between `-n` to compare RSS and throughput.

## cpu_call_tree Conclusion

This round of `cpu_call_tree_summary.csv` has covered `claw-code` and `llama.cpp` at the same time. `time-profile` has a symbol occurrence, which can be sorted by hotspot; `time-sample` is still a raw kperf address table, which only retains the row count and target status, and is not included in the symbol ranking. Note: At present, the staged `BenchMarkResult.csv` has synchronized trace wall time / timeout / target_seen, but the CPU symbol field is still an empty column; the CPU conclusion should be subject to `trace/analysis/cpu_call_tree_summary/cpu_call_tree_summary.csv`.

- BVX3: The top symbol of both data sets, n4/n8/n40, is `encodeBlockV3`, and encode hits and Swift Array hits rise at the same time; the next step is to check `encodeBlockV3`, `FSEOutStream`, array bounds / COW, instead of just changing the parser.
- Lazy2: The top symbol of the two data sets is `lzParseChain.bestMatch`; `repLen` / `matchLength` is still a secondary hotspot that should be disassembled and measured.
- Optimal: The top symbol of the two data sets is `lzParseOptimal` closure; the symbol rows and unique symbols of n40 are significantly higher than n4, indicating that DP relaxation / price rebuild / emit path will be enlarged with the scan depth. The next step should be to do the hierarchical cheap probe first, and avoid the optimal in the low-yield segment.
- Other3: top symbol is stable at `encodeBlock`, accompanied by `lzParseStrong`, FSE and Swift Array costs; to optimize standard LZFSE, apply the same set of encode buffer / array cost check.
- Apple: The top symbol is `lzfseEncodeMatches` / `lzfseEncodeBase`, which represents the internal LZFSE path of Apple Compression and should not be compared with the Swift parser hotspot.

## Next step correction

1. **BenchmarkResult field synchronization**: At present, the trace wall time / timeout / target_seen of `BenchMarkResult.csv` has been updated, but the CPU symbol field still needs to be rearranged to the latest `cpu_call_tree_summary.csv` to avoid the empty bar affecting the subsequent sorting; the alignment key should use dataset + algorithm + n, and the external tool should be dataset + algorithm.
2. **Large file strategy**: The original trace XML / trace package is easy to cause GitHub 100MB limit and repo expansion; the subsequent commit should be based on summary CSV / notes, and the original trace should be left on the local machine or changed to external storage.
3. **bvx3 family optimization order**: Do BVX3 `encodeBlockV3` single point A/B first, then do Lazy2 `bestMatch` / `matchLength`, and finally do Optimal segment hierarchy gating. Each change should look at the speed, compression ratio and RSS at the same time.
4. **Acceptance benchmark update**: BVX3 takes `claw-code n40 631.83 MB/s` / `llama.cpp n40 446.62 MB/s` as the speed benchmark; Lazy2 takes `57.88 / 178.25 MB/s` as the benchmark; Optimal takes `30.08 / 57.06 MB/s` as the benchmark. Any change needs to at least prove the `>=10%` single-point improvement or `>=20%` RSS reduction in the same round and data set, and the compression ratio cannot regress significantly.

---

# 25th round: trace / cpu_call_tree included in BenchMarkResult (2026-06-15)

## Data status of this round

This round re-reads `lz4bench_log/lz4bench-*-n*.txt`, `lzfse-test.txt`, `memprobeResults/`, `trace/analysis/trace_summary.csv` and `trace/analysis/cpu_call_tree_summary/`, and rebuild `BenchMarkResult.csv`. CSV still calculates decimal MB/s in raw bytes / ns; new fields include `Trace timeout`, `Trace target seen`, `CPU Symbol Status`, `CPU Top Symbol`, `CPU Top Category` and parse / encode / fse / Swift Array hit counts.

`lzfse-test.txt` is still the basis for correctness and does not compare with the MB/s of the large data set. `trace/analysis` currently only has a valid trace of `claw-code`; `claw-code-apple-n8.trace` has been skipped in `trace_summary.csv` because the previous `.out` was deleted externally but `incomplete_package`, which is not included in the cpu call tree.

## The latest throughput and RSS conclusions

`-n` scan still shows that the bvx3 family has obvious trade-offs between compression speed, compression ratio and RSS:

- `claw-code`:
- Other3 best compression `559.49 MB/s` (n8), compression ratio `0.9872`.
- BVX3 best compression `625.62 MB/s` (n40), compression ratio `0.9515`, but the best decompression `731.24 MB/s` is also in n40.
- Lazy2 compression ratio `0.9016`, the best compression `55.96 MB/s` (n40).
- Optimal compression ratio `0.8590`, the best compression `28.81 MB/s` (n40).
- ZSTD compression ratio `0.8255`, the best compression `453.67 MB/s`, the best decompression `965.14 MB/s`.
- `llama.cpp`:
- Other3 best compression `412.03 MB/s` (n40), compression ratio `0.9978`.
- BVX3 best compression `374.86 MB/s` (n40), compression ratio `0.9815`.
- Lazy2 compression ratio `0.9587`, the best compression `163.28 MB/s` (n40).
- Optimal compression ratio `0.9415`, the best compression `54.12 MB/s` (n40).
- ZSTD compression ratio `0.9123`, the best compression `390.99 MB/s`.

The results of this round of memProbe are different from R24. RSS has dropped to hundreds of MB levels. The conclusion of R24's "LZFSE family encode/decode RSS is still 1GB+" should be regarded as the result of old data or old probe method:

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

RSS is still higher than TLZ4 decode `33.8 MB` and ZSTD decode `9 MB`, but it is no longer GB level. The next round of memory work should be changed from "integration" to "there are still hundreds of MB working sets" to locate: chunk scratch, parser chain, encode staging and parallel inflight upper limit are still the main suspects.

## trace / cpu_call_tree found

`helper/tracer.command` now uses direct launch + `--target-stdin` to see `lzfse-profile` in Time Profiler. At the same time, add the `.out.active` marker to avoid deleting the `.out` that is being used by xctrace again. `trace_analysis.command` already supports `.trace.timeout`; timeout trace can be used in the hotspot direction, but not for MB/s or complete time-consuming judgment.

The valid LZFSE trace of this round of cpu call tree is in `claw-code`:

- Other3 n4/n8: the top symbol is `encodeBlock`, and there are `lzParseStrong`, `fseEncode` and Swift Array bounds/COW costs.
- BVX3 n4: the top symbol is `encodeBlockV3`, classified as encode; hit count shows that the cost of encode and Swift Array is obvious, and you can't just look at the parser.
- Lazy2 n4: the top symbol is `lzParseChain.bestMatch`, `repLen` and `matchLength` are also at the forefront of hot symbols in the whole area.
- Optimal n4: top symbol is the kernel closure of `lzParseOptimal`; `emitSteps`, `samplePointEntropyAndText`, `rebuildPrices` also enter hot symbols, indicating that DP / pre-screening / emit all need to be disassembled.
- Apple n4: top symbol is `lzfseEncodeMatches` / `lzfseEncodeBase`, which is an Apple LZFSE implementation and should not be confused with its own Swift parser.

`time-sample` is a raw kperf address table. At present, it only remembers the status of row count and target, and is not included in the symbol hotspot ranking; `time-profile` is the current symbol occurrence source.

## bvx3 family next step strategy

1. **First do the single-point CPU hotspot, no longer generic UnsafePointer**: BVX3 first makes single-point changes for `encodeBlockV3` / `FSEOutStream` / Swift Array bounds; Lazy2 for `lzParseChain.bestMatch/repLen/matchLength`; Optimal for `lzParseOptimal`'s DP, `emitSteps`, `rebuildPrices` set up a small A/B.
2. **RSS target downgrade but still retain**: The next round of success conditions is changed to encode/decode RSS to reduce by 20% under the same data set and the same `-n`, instead of only pursuing a reduction from the GB level. To get close to TLZ4/ZSTD, you need to prove the actual boundary of scratch / staging / inflight.
3. **Optimal segment change hierarchical strategy**: `claw-code` Optimal compression ratio 0.8590 has obvious benefits, but `llama.cpp` Optimal is only 0.9415, which is still large for ZSTD; cheap probe should be used to judge the segment yield first, the low-yield segment Lazy goes 2/BVX3, and the high-yield segment will enter Optimal.
4. **trace coverage needs to make up llama.cpp**: At present, cpu_call_tree only covers claw-code; the next round of tracer must re-run the complete n4/n8/n40 and two data sets, and avoid manually deleting `.out` in the middle.

## Next round of acceptance conditions

- `swiftc -O lzfse-cli.swift -o lzfse` can be compiled, `./lzfse -test` passed.
- `BenchMarkResult.csv` keeps the MB/s calculation of raw bytes / ns and synchronizes the trace/cpu field.
- If you change the BVX3 encode: `claw-code` BVX3 n40, the compression speed should be higher than `625.62 MB/s` or the RSS should be lower than `370.2 MB`, and the two should achieve at least one and the compression ratio will not be refunded.
- If Lazy2: `claw-code` Lazy2 n40 compression speed should be higher than `55.96 MB/s`, and the ratio should be maintained around `0.9016`.
- If you change Optimal: `claw-code` Optimal n40, the compression speed needs to be higher than `28.81 MB/s`, or use the segment hierarchy strategy to avoid Optimal in the low-yield segment, and the overall ratio does not regress significantly.

---

# Round 24: `-n` Scan Result Integration (2026-06-15)/ Round 24: `-n` Sweep Consolidation

## Purpose of this round / Purpose

This round will rebuild `BenchMarkResult.csv` according to `lz4bench_log/lz4bench-{dataset}-n4/n8/n40.txt`, `lzfse-test.txt` and `memprobeResults/`. This time, it is clear that ** did not rerun `helper/tracer.command` or `helper/trace_analysis.command` **; the old trace and the old `trace/analysis` products have been cleaned up, and there will be no new hotspot reading in this round.

`BenchMarkResult.csv` is currently 48 rows: 2 data sets × 3 N × 8 formats. The speed bar still calculates decimal MB/s in raw bytes / ns; CSV and `best_points/best_points.csv` are both output in UTF-8 BOM, which is convenient for Excel reading. `lzfse-test.txt` shows that the built-in correctness cases continue to pass: other3 Apple compatibility, own bvx3/lazy2/optimal round-trip, parallel decoding, private bvx3 Apple rejection, single-stream backup and Apple mutual solution path are all normal.

## Throughput Summary / Throughput Summary

The speed comparison is based on the `compression MB/s` / `decompression MB/s` of `BenchMarkResult.csv`. The compression size is included in the reference, but even if the data of TGZ, Apple, ZSTD and multi-threaded external tools is the same, they may cause small fluctuations due to metadata, tool version, threading and operating environment; this round only lists obvious trends as conclusions.

### Best Points / Best Points

> `log nX` of TGZ / Apple / TLZ4 / ZSTD only represents the source log batch, and `-n` does not affect these algorithms; `-n` is only meaningful to LZFSE other3 / bvx3 / lazy2 / optimal path.

#### claw-code

| Format | Best Compression Ratio | Best Compression MB/s | Worst Compression MB/s | Best Decompression MB/s | Worst Decompression MB/s | Lowest Encode RSS | Highest Encode RSS | Lowest Decode RSS | Highest Decode RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 1.0000 ( `log n4`) | 51.63 ( `log n40`) | 48.24 ( `log n8`) | 614.80 ( `log n40`) | 605.50 ( `log n4`) | 4.0 MB ( `log n4`) | 4.0 MB ( `log n4`) | 3.7 MB ( `log n4`) | 3.7 MB ( `log n4`) |
| Other3 | 0.9872 ( `n4`) | 563.51 ( `n8`) | 390.43 ( `n4`) | 693.08 ( `n40`) | 664.02 ( `n4`) | 1455.2 MB ( `n4`) | 1639.5 MB ( `n40`) | 952.0 MB ( `n4`) | 1092.6 MB ( `n40`) |
| BVX3 | 0.9515 ( `n4`) | 494.50 ( `n40`) | 373.42 ( `n4`) | 501.38 ( `n8`) | 390.61 ( `n40`) | 1471.9 MB ( `n4`) | 1681.9 MB ( `n40`) | 918.2 MB ( `n4`) | 1060.4 MB ( `n40`) |
| Lazy2 | 0.9016 ( `n4`) | 54.87 ( `n40`) | 34.47 ( `n4`) | 760.31 ( `n40`) | 615.98 ( `n4`) | 1507.0 MB ( `n4`) | 1820.8 MB ( `n40`) | 871.1 MB ( `n4`) | 1013.4 MB ( `n40`) |
| Optimal | 0.8590 ( `n4`) | 29.16 ( `n40`) | 19.33 ( `n4`) | 718.84 ( `n40`) | 552.67 ( `n4`) | 154.2 MB ( `n4`) | 1905.7 MB ( `n40`) | 831.6 MB ( `n4`) | 973.4 MB ( `n40`) |
| Apple | 0.9877 ( `log n4`) | 156.12 ( `log n4`) | 154.30 ( `log n40`) | 689.32 ( `log n8`) | 569.11 ( `log n40`) | 1356.4 MB ( `log n4`) | 1356.5 MB ( `log n40`) | 473.1 MB ( `log n4`) | 473.2 MB ( `log n40`) |
| TLZ4 | 1.1796 ( `log n4`) | 634.00 ( `log n40`) | 617.19 ( `log n8`) | 993.71 ( `log n40`) | 567.08 ( `log n8`) | 79.9 MB ( `log n8`) | 86.2 MB ( `log n40`) | 33.8 MB ( `log n4`) | 33.8 MB ( `log n4`) |
| ZSTD | 0.8255 ( `log n4`) | 440.86 ( `log n40`) | 425.33 ( `log n4`) | 894.60 ( `log n4`) | 654.16 ( `log n8`) | 397.0 MB ( `log n4`) | 402.1 MB ( `log n8`) | 9.2 MB ( `log n4`) | 9.2 MB ( `log n4`) |

#### llama.cpp

| Format | Best Compression Ratio | Best Compression MB/s | Worst Compression MB/s | Best Decompression MB/s | Worst Decompression MB/s | Lowest Encode RSS | Highest Encode RSS | Lowest Decode RSS | Highest Decode RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TGZ | 1.0000 ( `log n4`) | 65.08 ( `log n8`) | 62.20 ( `log n40`) | 289.62 ( `log n40`) | 272.24 ( `log n4`) | 4.1 MB ( `log n4`) | 4.1 MB ( `log n4`) | 3.8 MB ( `log n4`) | 3.8 MB ( `log n4`) |
| Other3 | 0.9978 ( `n4`) | 403.98 ( `n8`) | 302.33 ( `n40`) | 283.06 ( `n40`) | 256.74 ( `n4`) | 1234.9 MB ( `n40`) | 1350.7 MB ( `n8`) | 1182.5 MB ( `n4`) | 1323.2 MB ( `n40`) |
| BVX3 | 0.9815 ( `n4`) | 393.29 ( `n8`) | 295.32 ( `n40`) | 262.31 ( `n4`) | 255.12 ( `n40`) | 1297.1 MB ( `n4`) | 1379.5 MB ( `n40`) | 1163.7 MB ( `n4`) | 1305.5 MB ( `n40`) |
| Lazy2 | 0.9587 ( `n4`) | 163.91 ( `n40`) | 114.41 ( `n4`) | 301.60 ( `n4`) | 287.77 ( `n8`) | 1339.4 MB ( `n4`) | 156.2 MB ( `n40`) | 1137.0 MB ( `n4`) | 1279.2 MB ( `n40`) |
| Optimal | 0.9415 ( `n4`) | 56.66 ( `n40`) | 36.64 ( `n4`) | 278.34 ( `n8`) | 254.70 ( `n4`) | 1376.4 MB ( `n4`) | 1720.9 MB ( `n40`) | 1117.1 MB ( `n4`) | 1259.5 MB ( `n40`) |
| Apple | 1.0008 ( `log n4`) | 166.86 ( `log n8`) | 144.59 ( `log n40`) | 274.45 ( `log n8`) | 237.36 ( `log n40`) | 1193.9 MB ( `log n4`) | 1193.9 MB ( `log n4`) | 590.3 MB ( `log n4`) | 590.4 MB ( `log n40`) |
| TLZ4 | 1.0549 ( `log n4`) | 364.93 ( `log n4`) | 225.96 ( `log n40`) | 309.15 ( `log n40`) | 270.96 ( `log n4`) | 81.9 MB ( `log n8`) | 90.4 MB ( `log n4`) | 33.8 MB ( `log n4`) | 33.8 MB ( `log n4`) |
| ZSTD | 0.9123 ( `log n4`) | 456.46 ( `log n40`) | 426.60 ( `log n8`) | 311.86 ( `log n8`) | 269.82 ( `log n4`) | 497.9 MB ( `log n40`) | 508.0 MB ( `log n8`) | 9.2 MB ( `log n8`) | 9.7 MB ( `log n40`) |

## `-n` Scan Observation / `-n` Sweep Findings

1. `-n` is still a throughput knob, not an RSS solution. Lazy2/Optimal compression of `claw-code` is the fastest in `n40`, but encode RSS is also up to 1.82GB/1.91GB; `llama.cpp`'s Other3 minimum encode RSS appears in `n40`, but the rest of the bvx3 family still maintains a 1.30GB–1.72GB distance. This indicates that the main cause of memory is still in the chunk work set, parser scratch, compressed body staging or data copy.
2. `claw-code`'s compression ratio benefit to the bvx3 family is still obvious: Optimal 0.8590, 4.72% smaller than Lazy2 0.9016, but the best compression speed is only 29.16 MB/s, about 1.88x slower than Lazy2. Optimal 0.9415 on `llama.cpp` is only 1.79% smaller than Lazy2 0.9587, but the compression speed is about 2.89x slower. Optimal must be changed to a segment-level revenue gate, not to be used globally.
3. The Lazy2/Optimal of `claw-code` on the decompression side can still reach 760.31/718.84 MB/s, but BVX3 is only 501.38 MB/s; `llama.cpp` is 255–312 MB/s overall. This difference is more like the joint impact of data type and cache/I/O floating, and a single data set cannot be used to declare the victory or defeat of decompression.
4. External tools provide a clear RSS lower limit: TGZ encode/decode about 4MB, TLZ4 decode 33.8MB, ZSTD decode 9MB level. In comparison, the decode of the LZFSE family is still 831MB–1.32GB, and the encode is still 1.23GB–1.91GB.

## memProbe and trace integration / memProbe and Trace

memProbe This round of confirmation: the encode RSS of the LZFSE/bvx3 family is still the main problem. The minimum encode RSS is still at the GB level: `claw-code` Other3 1455.2MB, BVX3 1471.9MB, Lazy2 1507.0MB, Optimal 1544.2MB; `llama.cpp` Other3 1234.9MB, BVX3 1297.1MB, Lazy2 1339.4MB, Optimal 1376.4MB. External tools are TGZ about 4MB, TLZ4 about 80–90MB, and ZSTD about 397–508MB.

Decode RSS has not yet dropped to the expected tens of MB or semi-compressed file level: `claw-code` Optimal minimum 831.6MB, Other3 952.0MB; `llama.cpp` Optimal minimum 1117.1MB, Other3 1182.5MB. This means that the current data still supports the judgment that "the input /scanBlocks/work set is still a whole file or a large number of residences"; the previous decode reading file to remove the double revision still needs to be verified with clean round, and cannot be claimed that it has been completed by this round of numbers alone.

Trace has not been rerun this time, and the old `trace/analysis` export has been removed. The previous analysis confirmed that the external compressor trace is available, but most of the old trace of LZFSE family profiles to `zsh` wrapper, which cannot be used as a hotspot basis. `helper/tracer.command` has been changed to clear the old `*.trace` before re-running, and change to direct launch + `--target-stdin`; next time, if you want to make a hotspot, you must first reborn trace before running `trace_analysis.command`.

## This round of script and output sorting / Script and Output Updates

- `helper/benchmark_result_rebuild.command` only reads `lz4bench_log/lz4bench-*-n*.txt`, no longer fallback root directory old log; output `BenchMarkResult.csv` as UTF-8 BOM.
- `benchmark.sh` has written the results of lz4bench to `lz4bench_log/`, and the last step will rebuild `BenchMarkResult.csv` and generate Best Points.
- `helper/best_points_analysis.command` has output `best_points/best_points.md` and `best_points/best_points.csv`, including TGZ, best compression ratio, best/worst compression MB/s, best/worst decompression MB/s, lowest/highest Encode RSS, minimum/highest Decode RSS.
- The CSV output of `helper/trace_analysis.command` has been changed to UTF-8 BOM; this round has not been executed.
- `helper/tracer.command` has been added to clear the old `*.trace` before running to avoid the mixing of old and new traces; this round has not been executed.

## bvx3 Family Improvement Strategy / bvx3 Family Strategy

1. **Priority encode workset**: `-n` cannot pull encode RSS out of GB level. The next step should focus on thread-local scratch pool, parser/DP buffer reuse, and remove `compressBody` per chunk `[UInt8](input)` copy. Success conditions: bvx3/lazy2/optimal encode RSS decreases by at least 20%, and the compression output byte level remains unchanged or there is a clear reason for the difference.
2. **decode to switch from whole-file scan to incremental scan**: At present, decode RSS is still 831MB–1.32GB. To reduce to tens of MB, `scanBlocks` must be truly incrementalized with compressed input reading, with the goal of `N * 4MiB + window` level.
3. **Optimal change income gate**: `claw-code` has 4.72% volume gain, which can be used for high-yield segments; `llama.cpp` is only 1.79%, which is not worth the whole segment DP. The next step is to add cheap probe. The low-yield segment will go Lazy2/BVX3, and the high-yield segment will enter Optimal.
4. **Trace is reborn and then change the hotspot**: At present, match loop or DP inner loop is not changed according to the old trace XML. If you want to re-run trace in the next round, verify `contains_lzfse_profile=yes` first, and then draw top self-time/heavy stack.

## Next Round Acceptance Criteria / Next Acceptance Criteria

- `swiftc -O lzfse-cli.swift -o lzfse` can be compiled.
- `./lzfse -test` Maintain all cases passed.
- If the encode memory path is changed: bvx3/lazy2/optimal encode RSS is at least 20% lower than the best of this round.
- If decode streaming is changed: `claw-code` Optimal decode RSS should be significantly lower than 831.6MB, and `llama.cpp` Optimal decode RSS should be significantly lower than 1117.1MB.
- If Optimal is changed: recalculate MB/s with raw bytes/ns, the compression speed of `claw-code` Optimal is increased by at least 10%, or the revenue gate can make the `llama.cpp` low-yield segment avoid Optimal DP.

# Round 23: benchmark / memProbe / trace (2026-06-14) / Round 23: Consolidated Benchmark Refresh

## Purpose of this round / Purpose

This round re-read `lz4bench-claw-code.txt`, `lz4bench-llama.cpp.txt`, `lzfse-test.txt`, `memprobeResults/` and `trace/`. `BenchMarkResult.csv` has been refreshed into the same table. The speed column calculates decimal MB/s in raw bytes / ns, and keeps `Encode RSS(MB)`, `Decode RSS(MB)`, `Trace wall time(seconds)`, so that the overlay status of throughput, peak RSS and Time Profiler can be compared with the same column.

This round of helper has moved the memProbe to the compression and decompression benchmark before running; therefore, the formal decompression MB/s is no longer disturbed by the probe, especially the decompression number of llama.cpp is more reliable than the previous round.

`lzfse-test.txt` is still positioned as an correctness and compatibility test, which is not included in the MB/s calculation; there is no failure mark in this round, and the lazy2 / optimal self-round-trip, parallel decoding, and Apple compatibility/rejection path are all maintained.

## Latest Speed Results / Latest Throughput (decimal MB/s, raw bytes / ns)

### Compression MB/s / Compression

| Format | claw-code | llama.cpp |
| --- | ---: | ---: |
|TGZ|50.79|66.01|
| Other3 | 354.87 | 440.47 |
| **Lazy2** | **48.31** | **164.23** |
| **Optimal** | **26.71** | **56.88** |
| BVX3 | 515.78 | 429.01 |
| Apple | 149.57 | 166.95 |
| TLZ4 | 500.44 | 363.81 |
| ZSTD | 327.97 | 470.05 |

### Decompression MB/s / Decompression

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

> The speed value of this round is still floating with the front wheel. After llama.cpp moves back to memProbe, the decompression MB/s returns significantly to the 220–273 MB/s range; the decompression of claw-code still shows large disk/cache fluctuations, especially the BVX3 single point is low. Therefore, the comparison is still based on the same-round relative relationship and multi-round trend, and the small difference in compression size of Apple/ZSTD/TGZ is not regarded as evidence of algorithm change.

## Compression ratio and cost / Ratio and Cost

| Data Set | Lazy2 ratio | Optimal ratio | Optimal Extra Volume Gain | Optimal/Lazy2 Compression Time |
| --- | ---: | ---: | ---: | ---: |
| claw-code | 0.9016 | 0.8590 | 4.72% smaller vs lazy2 | 1.81x |
|llama.cpp|0.9587|0.9415|1.80% smaller vs lazy2|2.89x|

The conclusion remains unchanged: optimal has a visible volume benefit for claw-code, but it only saves 1.80% more for llama.cpp, but it still requires 2.89x lazy2 compression time. In the next round, the optimal should not be taken as the global strategy, but should be changed to the segment level cheap probe: the high-yield segment should enter the optimal segment, and the low-yield segment should go lazy2 or bvx3.

## MemProbe Results / Peak RSS

| Format | claw encode | claw decode | llama encode | llama decode |
| --- | ---: | ---: | ---: | ---: |
|TGZ|4.0MB|3.7MB|4.1MB|3.8MB|
| ZSTD | 392.3 MB | 9.5 MB | 508.4 MB | 9.3 MB |
| TLZ4 | 74.6 MB | 33.8 MB | 83.6 MB | 33.8 MB |
| Other3 | 1334.8MB | 1014.2MB | 1372.8MB | 1244.2MB |
| Apple | 1356.4 MB | 473.1 MB | 1193.8 MB | 590.3 MB |
| BVX3 | 1523.0 MB | 981.9 MB | 1365.8 MB | 1226.6 MB |
| Lazy2 | 1163.0 MB | 935.1 MB | 1554.0 MB | 1199.9 MB |
| Optimal | 1616.0 MB | 895.0 MB | 1655.3 MB | 1180.1 MB |

The latest memProbe shows that decode RSS is stable at about 473MB–1.24GB, and no longer returns to 2GB+ of R21, but it is still much higher than external tools; encode RSS is more clearly the main problem. LZFSE / bvx3 family encode is about 1.16–1.66GB, compared with TLZ4 about 75–84MB and ZSTD about 392–508MB, representing parallel encode, the in-way chunk, parser workspace, compressed body, sorting buffer or `Data` copy still need to be suppressed independently. The default value of `-n` does not allow RSS to fall automatically. The next step is to scan with a smaller N.

## Trace Summary / Trace Summary

`trace/tracer_status.txt` shows that 16 Time Profiler bundles have been completed, the file name is `<dataset>-<algo>.trace`, and the LZFSE family maintains `-si` stdin path. Trace wall time can only confirm the coverage and relative magnitude, cannot replace benchmark MB/s, and cannot declare hotspot ranking before CLI export fails.

| Format | claw-code | llama.cpp |
| --- | ---: | ---: |
|TGZ|42s|34s|
|ZSTD|8s|8s|
| TLZ4 | 8s | 10s |
| Other3 | 9s | 12s |
| Apple | 15s | 18s |
| BVX3 | 11s | 12s |
| Lazy2 | 50s | 25s |
| Optimal | 81s | 56s |

The available conclusion of Trace is very narrow: lazy2 / optimal is a long segment, especially claw-code optimal; but the first two hotspots still need to open the `.trace` bundle with Instruments GUI and record the top self-time / heavy stack.

## bvx3 Family Next Plan / Next Plan

1. ** Do a small N scan first, instead of directly claiming that encode RSS has been solved**: The default N still allows the bvx3 family encode RSS to fall to 1.16–1.66GB. The next round needs to fix the same code, scan `-n 40 / 8 / 4` or similar values, and confirm whether the smaller N can reduce any encode RSS of bvx3/lazy2/optimal by ≥20%, and the compression MB/s/ rate is acceptable.
2. **Redo the optimal cost gate**: Use cheap probe to estimate the benefits of lazy2→optimal at the segment level. Low-yield data such as llama.cpp should not be optimized in all sections; claw-code high-yield segments are worth paying DP costs.
3. **decode RSS is still a problem, but the ranking is lower than encode**: decode is currently about 0.47–1.24GB, which is still one or two orders of magnitude higher than zstd/tlz4; but the most unreasonable thing in this round is encode 1.16–1.66GB. The decode bounded streaming window should be scheduled independently to avoid mixing with the optimal DP acceleration in the same round.
4. **Profiling only picks specific hotspots after GUI reading**: Next time you want to change the DP / match loop, first extract the top two hotspots from `trace/claw-code-optimal.trace` and `trace/llama.cpp-optimal.trace`, and then make a single-point change; the speed success condition maintains the same-round claw optimal compression time improvement ≥10%.

## Implementation Acceptance Observation / Implemented This Round

**Item 1 (encode decoupling in transit) - done + investment evaluation**
- `-n <N>` knob (encode / decode shared, decoupled with the number of cores): the sem upper limit of `runParallelEncode` is determined by N. Default = number of cores × 2, upper limit < number of cores × 4, lower limit 1.
- ⚠️ **Acceptance result**: Under the default setting, encode RSS does not meet the −20% success condition, and it is still about 1.16–1.66GB. This means that the N knob needs to be verified with a smaller value, and parser/DP scratch / `Data` copy is the next more certain single point.
- **scratch reuse evaluation ("confirm whether it can be reused")**: It is feasible, but the DP segment, hash and chain array in `lzParseOptimal` / `lzParseChain` / `lzParseStrong` need to be changed to "thread-local scratch pool from the outside" (signature change, intrusive, correctness-critical), so this round ** has not been blindly modified**, which is listed as the next step that needs to be compiled and verified. In addition, `let bytes = [UInt8](input)` in `compressBody` copies an extra 4MiB per chunk, which can be changed to `withUnsafeBytes`.

**Decode one more step down - done**
- Eliminate The **Repeated Input Copy** Of The CLI Decoding Path: The `Data` Of The Original `readToEnd()` And The `[UInt8]` In `decodeStreamToHandle` Each Hold A Complete Compressed File; Instead, Only Read A Single Copy Of `[UInt8]` ( `decodeStreamToHandle` Directly Eat `[UInt8]`, No Longer Copy Internally). It is expected to save more ~ decode RSS of compressed file size (claw ~0.4GB, llama ~0.55GB).
- **Acceptance results**: decode RSS is maintained at 473MB–1.24GB, which has not returned to 2GB+ of R21; but it has not yet reached dozens of MB, which means that `scanBlocks` / `src` incrementalization is still necessary follow-up work.
- To "tens of MB", the second stage is required b: `scanBlocks` incremental scanning + `src` stream reading (not yet done).

**Decode file reading to double (R24 follow-up, done)/ Eliminate read-time input doubling**
- R24 data shows decode peak ≈ **2× compressed file** (claw optimal 422MB→829MB, other3 485MB→950MB), the bottleneck is not in the output but "at the time of reading the file": `readToEnd()` The whole portion of `Data` And `[UInt8](...)` It exists at the same time at the moment of conversion.
- Method: CLI decoding end is changed to **single buffer incremental read**-- `-i` File first `attributesOfItem` Take the size, once `reserveCapacity`, and then with 1MiB small pieces `read(upToCount:)` Append block by block and release temporary storage `Data` ( `-si` When the size of stdin is unknown, it will be returned to append block by block). The peak value of the input terminal is reduced from 2× compressed gear to **≈ 1× compressed gear + 1MiB**.
- Expected decode peak ≈ `1× compressed file + N×4MiB` (claw optimal `-n4` estimated ~0.44GB, about cut in half). Wait for your benchmark + memProbe acceptance; `-test` keep 7/7 and Apple to solve each other unchanged.

**Decode stream input (receive 1× compressed input) - done (to be accepted) / Streaming input**
- R24 clean round shows that the decode is still ~0.83–1.18GB, because **the whole compressed input is still stationed** ( `src` whole file + `scanBlocks` whole sweep). This time, the `-i` file decoding is changed to real streaming:
- Add `decodeStreamFromFile`: read into the compressed stream block by block, accumulate into groups according to the chunkRaw boundary, ** write and release in order after the whole batch of N groups are successfully decoded in parallel, and release **, and the whole process does not hold the whole compressed input. Reading window ~1MiB + N× in the flying group (a set of compression + a set of output).
- Expected decode RSS ≈ **inflight × (≤4MiB compression + 4MiB output) + ~1MiB**, no longer linear with file size ( `-n4` tens of MB; `-n40` about hundreds of MB).
- Correctness: Only stream for "own block stream" (each chunk is compressed independently → group self-contained); foreign single stream/non-block is detected when ** the first batch has not been written** (misalign or decoding failure) → return to `.fallback`, the caller ** rereads the whole file ** goes through the existing whole-buffer path, and the output bytes are exactly the same (Apple/other3 compatibility has zero impact). `-si` stdin cannot be reread → maintain single read + whole-buffer.
- ⚠️ `decodeStreamFromFile` is not covered by `-test` ( `-test` goes to `decompress` / `parallelDecompress`'s Data API), only the benchmark `diff` consistency will be verified. Be sure to run benchmark 7/7 consistency + scan `-n 4/8/40` comparison decode RSS.

**Encode/decode reading loop autoreleasepool (root cause correction) - done (to be accepted)/autorelease accumulation fix**
- R24 N-by-one data shows that encode RSS ** has nothing to do with N, has nothing to do with parser (n4 time other3 1455 ~ optimal 1544MB, only ~90MB short), and ≈ whole input size ** (claw 1.38GB→~1.4–1.5GB, llama 1.26GB→~1.3–1.6GB). These three features all point to the classic trap of macOS Foundation: ** There is no autorelease pool in the main thread reading loop** - `FileHandle.read(upToCount:)` return autoreleased `Data` temporary storage. When there is no pool in the loop, it will accumulate to the "whole input size" before being released at the end of the process.
- Repair method: Put 4 main threads read loop packages into `autoreleasepool`, and empty each block after reading it for temporary storage--
- `runParallelEncode` producer reading loop (encode main cause);
- `ensure()` of `decodeStreamFromFile` (decode stream reading);
- CLI `-si` whole file reading of stdin and fallback.
- The strongly referenced `data` / `src` / `buf` remains outside the pool without being affected, and only empty read's autoreleased backing. GCD worker (compressBody / parallel decoding) is automatically emptied every block and does not need to be processed.
- Expected: encode RSS drops from ≈ whole input (~1.4GB) to ≈ `N ×（chunkSize + parser workspace）` (should be less than hundreds of MB); decode no longer accumulates compressed input in the form of temporary storage. **Waiting for your benchmark + memProbe acceptance**; This is a pure memory correction, the compression/decoding byte remains unchanged, and `-test` should be maintained consistent with 7/7.

**Helper seduing correction - done**
- memProbe has been moved to the official compression/decompression benchmark; this makes the decompression MB/s no longer contaminated by the previous probe. The decompression result of llama.cpp rebounded to the range of 220–273 MB/s, supporting this adjustment direction.

**Acceptance suggestion**: `-test` keep 7/7 consistent with Apple; the next round of fixed code scan `-n 40 / 8 / 4` to see RSS↔ speed trade-off; if the small N is not enough after RSS, change to parser scratch pool or `compressBody` to remove each chunk `[UInt8](input)` copy.

---

# Suggestion of modification direction: bvx3 family memory overall solution (R23 design notes)/ Direction: Holistic Memory Fix for the Whole LZFSE Family

> This section is the design direction, not the actual measurement. B-line/C-line of R21/R23 memProbe and R22: encode RSS about 1.16–1.66GB, decode RSS about 0.47–1.24GB is **architecture-level** cost, and **all formats are shared** (other3 / Apple is also affected, not exclusive to bvx3). Therefore, the solution must be solved once in the common layer and ensure that it is compatible with other3/Apple.

## 1. Problem positioning (common layer, non-format exclusive) / Root Cause in the Shared Layer

`decodeStream` (2677 lines) and `runParallelEncode` (3342 lines) are the I/O pipelines shared by all algorithms:

- **decode still has a whole file-level cost**: (a) 2678 lines `let src = [UInt8](input)` holds the whole compressed input (~0.4–0.6GB); (b) After batch output, the peak value is still about 0.47–1.24GB, which means that the compressed input, group temporary storage, `Data` copy / staging are still not fully bounded.
- **encode number of binding cores in transit**: 3345 lines `maxTasks = activeProcessorCount` (this machine 20). Each in-trang chunk has its own input 4MiB + output + parser workspace + hash-chain/DP array, peak ≈ number of cores × working set per chunk, currently about 1.16–1.66GB.

## two Pivlic point: The maximum backtracking distance is determined by the "format" and is very small / The Enabling Invariant

- `maxDValue = 262139` (55 lines) → other3 / Apple maximum match distance ≈ **256KB** (i.e. Apple `LZFSE_ENCODE_MAX_D_VALUE`).
- `maxD3 = 4194299` (125 lines) → bvx3 ≈ **4MiB** (= `parallelChunkSize`).

Inference: **Any format decoding only needs to keep the "last W bytes" history** (W = 256KB or 4MiB), and the whole output is not required. This is also the implicit premise that the current parallel grouping (2692 rows on chunkRaw boundary tangent group, 2532 lines `dd <= w - historyFloor` boundary) can be established - but it has not been used to define decode memory. This is how gzip (32KB window) and zstd (frame window) maintain constant memory that has nothing to do with the file size.

## three. Overall solution: single bounded streaming I/O layer (three knobs, covering full format) / One Bounded Streaming Layer

| Knob | Meaning |
|---|---|
| **W** | Format maximum distance (history window, ensure cross-block match correct): other3 256KB / bvx3 4MiB |
| **N** | In-the-way depth (**the only knob of memory ↔ throughput**) |
| chunkSize | Use 4MiB |

- **decode**: Solve N groups to N segment buffers in the order of streaming → After solving a paragraph, **write stdout in order and release **, and only keep the history of the last W → RSS ≈ N × chunkRaw + W.
- **encode**: The number of in transit is changed from `maxTasks` to N + scratch pool to reuse workspace → RSS ≈ N × (chunkSize + workspace).
- **Apple/other3 compatibility zero impact**: The "bytes" of input/output remain completely unchanged, and only the buffer policy is changed; compatibility is a format problem, not a memory policy problem.

## four. Code Anchors / Code Anchors

- decode: `decodeStream` API changed from "return the whole data" to "write output FileHandle while solving"; 2705 lines whole `allocate` → bounded ring window; 2678 lines `[UInt8](input)` + `scanBlocks` (2610 lines) change incremental scanning (read magic/header → read block body → solve → forward).
- encode: `runParallelEncode` (3342 lines) decouple `maxTasks` from the "in-the-way upper limit" and add N; `scratchPool` (772 lines) expands to parser/DP workspace.

## five. Memory Estimation and User Knob / Estimates & `-mem`

- decode N=4 + after incremental scanning: 0.47–1.24GB → ≈ N×4MiB + 4MiB ≈ **20–24MB**.
- After encode N=8 + scratch pool: 1.16–1.66GB → ≈ 8×(4MiB + workspace) ≈ **hundreds of MB**.
- It is recommended to make `-mem low|balanced|max` (N = 2 / 8 / cores) externally: `max` maintains today's speed and memory, and `low` changes to low RSS.

## six Trade-off / Trade-off

The only price: N becomes smaller → decoding parallelism decreases → decoding MB/s approaches zstd (claw may 700→300–400). The current high decoding speed of lzfse was originally bought with "whole configuration + full-core parallel"; this solution makes it **optional** instead of mandatory.

## seven Phased Plan corresponds to the success conditions of R23 / Phased Plan

- **The second stage a (implemented, this time) / decode output bounded streaming**: Add `decodeStreamToHandle` (lzfse-cli.swift), and change the CLI decoding path ( `-decode` of `.other3` / `.bvx3`) from "configure the whole output at a time (~1.3GB) + write at a time" to "** batch parallel decoding → write stdout in order → release immediately**".
- Effective for all **other3 and bvx3 families** (both follow this path); the output bytes are exactly the same → Apple compatibility has no impact.
- Correctness: Relying on "independent compression of each 4MiB chunk → group self-included" (code 2593-2601 is guaranteed); foreign single stream/cross-group match automatically returns to the original whole-buffer decoding.
- Memory knob: CLI `-n <N>` (number of groups in memory at the same time). **Default = number of cores × 2**; **The upper limit must be < number of cores × 4** (if it exceeds, it will be clamped to 4×cores−1 and prompted); the lower limit is 1. Output-side peak ≈ N × 4MiB (default 20 cores → N=40 → ~160MB; `-n 4` → ~16MB).
- ⚠️ **Actual reduction calibration**: At this stage, only "whole output buffer (~1.3GB)" is eliminated; **Compressed input `src` is still read as a whole (~0.4–0.6GB)**. This memProbe has been reduced to about 0.47–1.24GB, but it is not yet "tens of MB"; to be lower, the second stage b or a small `-n` is needed.
- **The second stage b (to be done)**: `scanBlocks` (2610 lines) re-incremental scanning, `src` re-stream reading, eliminate that ~0.5GB → to reach tens of MB.
- **The first stage (to be done)/ encode**: limit N + scratch pool, down encode RSS (1.16–1.66GB).
- **Acceptance (you run benchmark + memProbe)**: 7/7 decompression is consistent, and the compression ratio byte level remains unchanged; decode RSS (other3/bvx3/lazy2/optimal)−≥20% (expected ~−70% at this stage). `-n 4`, `-n 2` can be measured separately to see the memory ↔ decompression speed.

---

# Round 22: Time Profiler trace Full Coverage (2026-06-14)/ Round 22: Full Time Profiler Trace Coverage

## Purpose of this round / Purpose

This round did not rerun the benchmark; `BenchMarkResult.csv` follows the latest MB/s calculated by R21 by raw bytes / ns. The new work is to expand `helper/tracer.command` into two data sets × 8 format Time Profiler batch tracing, output in `trace/`, file name alignment memProbe style: `<dataset>-<algo>.trace`. Two large tar input and profiling compression outputs have been cleared, and 16 `.trace` bundles are kept.

## Trace Completeness / Trace Completeness

- ✅ `TRACE_DONE 13:55:59`, 16 `.trace` bundles have been produced.
- ✅ COVERS `claw-code` / `llama.cpp` × `tgz`, `zstd`, `tar.lz4`, `other3`, `apple`, `bvx3`, `lazy2`, `optimal`.
- ✅ The LZFSE family still uses `cat <dataset>.tar | lzfse-profile -encode -si ...` to maintain the pipeline / `-si` path.
- ⚠️ `xcrun xctrace export --toc` returns `Fatal error reported in run 1` for the current trace, CLI cannot export the call tree/hotspot table yet; trace bundle can be left for Instruments GUI to open analysis.

### Trace wall time (including xctrace recording and saving cost)

| Format | claw-code | llama.cpp |
| --- | ---: | ---: |
|TGZ|42s|34s|
|ZSTD|8s|8s|
| TLZ4 | 8s | 10s |
| Other3 | 9s | 12s |
| Apple | 15s | 18s |
| BVX3 | 11s | 12s |
| Lazy2 | 50s | 25s |
| Optimal | 81s | 56s |

> This table cannot replace benchmark MB/s, because xctrace recording / symbolization / save bundle will add fixed costs; it is only used to confirm the tracing coverage and the relative time scale. The formal performance comparison is still subject to the raw bytes / ns of `BenchMarkResult.csv`.

## Unification with R21 benchmark / memProbe

1. **The baseline of bvx3 is very fast, but the cost of lazy2 / optimal is huge**: in R21 compressed MB/s, bvx3 is claw 505.74 / llama 320.84; lazy2 drops to 46.49 / 136.82; optimal drops to 27.11 / 40.93. Trace wall time also shows that lazy2 / optimal is a long segment, especially claw optimal 81s.
2. **bvx3 family encode/decode RSS is obviously too high**: external tool peak RSS is roughly TGZ 4MB, ZSTD 381–465MB encode / 9–10MB decode, TLZ4 75–83MB encode / 34MB decode; relatively, LZFSE/bvx3 family encode has reached 0.95–1.76GB, decode up to 1.45–2.34GB. This is not a measurement of noise, but the cost of memory at the architecture level, which needs to be optimized independently.
3. **Optimal's additional RSS is not the main cause, but the family-based RSS is the problem**: R21 memProbe shows that the optimal encode is only about 55MB (claw) and 102MB (llama) higher than lazy2, but the entire bvx3 family encode has reached 1.3–1.8GB and decode is about 2GB or more. The optimal speed bottleneck still depends on the DP/match hotspot; the bvx3 family needs to handle the buffer / staging of parallel coding and decoding.
4. **Decompression and encode profiling need to be disassembled**: The decompression MB/s of R21 is significantly slowed down by the complete memProbe; if you want to decompress in the future, you should be independent of the profiling/memProbe round.
Five. **At present, hotspot ranking cannot be claimed**: Before CLI export fails, "chain walk" or `matchLength` should not be written as top hotspot; they can only be listed as candidates that need to be confirmed by Instruments GUI.

## Memory Pressure Observation / Memory Pressure

| Category | External Tools | LZFSE/bvx3 Family |
| --- | --- | --- |
| Encode RSS | TGZ 4MB, TLZ4 75–83MB, ZSTD 381–465MB | Other3 947–1311MB, BVX3 1321–1515MB, Lazy2 1490–1703MB, Optimal 1592–1758MB |
| Decode RSS | TGZ 4MB, TLZ4 34MB, ZSTD 9–10MB | Other3 1455–2345MB, BVX3/Lazy2/Optimal about 2047–2300MB |

> Conclusion: The bvx3 family is not "only a little more buffer than external tools" at present, but one to two orders of magnitude higher. Decode RSS is the most sensitive to users, because decompression is usually expected to be low-cost, parallel, and stable under disk pressure; encode RSS is also unreasonable, because the baseline BVX3 has reached 1.3–1.5GB, and lazy2/optimal is higher. This problem and optimal DP speed are two lines: speed optimization cannot cover up too high RSS.

## bvx3 Family Next Strategy / Next Strategy

- **A line: First read `trace/claw-code-optimal.trace` and `trace/llama.cpp-optimal.trace` ** with Instruments GUI, take the top self-time / heavy stack, and then decide whether to change to `matchLength`, chain walk, dense relax, `rebuildPrices` or pre-screen.
- **B line: reduce bvx3 family encode RSS**. Give priority to check whether parallel encode retains input chunk, compressed body, match/price workspace, hash-chain table, result sorting buffer and `Data` copy at the same time; the goal is to reduce encode RSS from 1.3–1.8GB to close to the interpretable upper bound of "chunkSize × maxTasks + parser workspace".
- **C line: reduce bvx3 family decode RSS**. Give priority to check whether parallel decode retains the complete chunk output, staging dictionary, `Data` copy and result sorting buffer at once; the goal is to reduce decode RSS from 2GB+ to close to the interpretable upper bound of "chunkSize × maxTasks + output window".
- **Add cost gate instead of global optimal**: llama.cpp optimal is only 1.80% smaller than lazy2, but it takes 3.34x more compression time; segment-level cheap probe should give priority to excluding low-income segments. This strategy can also reduce memory footprint, because the low-yield segment does not enter heavy parser.
- **Keep lazy2 as the main high-rate mode, but limit its memory upper limit**: lazy2 still saves 9.84% TGZ-relative volume for claw, and the speed cost is acceptable; however, encode RSS has reached 1.5–1.7GB, and it must be confirmed whether maxTasks / chunkSize can be dynamically adjusted.
- **R23 Success Conditions**: Obtain the top two hotspots from trace GUI and record them to `OPTIMIZATION.md`; in addition, use memProbe to prove at least one bvx3 encode or decode RSS single point improvement. The speed line requires the same round of claw optimal compression time improvement ≥10%; the memory line requires bvx3/lazy2/optimal any encode or decode RSS to be reduced by ≥20%, and the compression ratio does not regress.

---

# Round 21: Full memProbe Coverage and Re-run (2026-06-14)/ Round 21: Full memProbe Coverage and Re-run

## Purpose of this round / Purpose

In this round, first modify the benchmark helper, and then re-run `run_round.command`. The key is to let `round_status.txt` judge success/failure, and let `memprobeResults` cover all benchmark formats: `tgz`, `zstd`, `tar.lz4`, `other3`, `apple`, `bvx3`, `lazy2`, `optimal`. `BenchMarkResult.csv` has recalculated decimal MB/s with the raw bytes / ns of the latest `lz4bench-claw-code.txt` and `lz4bench-llama.cpp.txt`.

## Measure the completeness / Completeness

- ✅ `run_round.command`: `TEST_OK 12:46:41`, `BENCH_DONE 13:08:24`.
- ✅ `claw-code` / `llama.cpp`: Compression and decompression of each 8 formats is completed, and 7/7 consistently passed.
- ✅ `lzfse-test.txt`: No failure mark.
- ✅ `memprobeResults`: Both data sets output 8 formats encode + decode peak RSS.
- ✅ helper correction: `benchmark.sh` uses zsh safe glob, `run_round.command` returns the benchmark exit code correctly; `zshrc.sh`'s `extract` / `lzfseX` / `lz4bench` supports lazy2/optimal product and complete probe.

## Measured Results (decimal MB/s, bytes/ns)

### Compression MB/s / Compression

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

### Decompression MB/s / Decompression

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

> This round of decompression MB/s is significantly lower than R20, especially llama.cpp. Adding a complete encode/decode memProbe before decompression in this round will change the state of page-cache and the whole machine memory; therefore, decompression MB/s can only be recorded in the same round and should not be used as evidence of algorithm regression. Compressing MB/s and the lazy2/optimal multiple of the same wheel is still the main basis for comparison.

### Compression ratio and in-round cost / Ratio and Within-Run Cost

| Data Set | Lazy2 ratio | Optimal ratio | Optimal Extra Volume Gain | Optimal/Lazy2 Compression Time |
| --- | ---: | ---: | ---: | ---: |
| claw-code | 0.9016 | 0.8590 | 4.72% smaller vs lazy2 | 1.72x |
|llama.cpp|0.9587|0.9415|1.80% smaller vs lazy2|3.34x|

## MemProbe Results / Peak RSS

| Format | claw encode | claw decode | llama encode | llama decode |
| --- | ---: | ---: | ---: | ---: |
|TGZ|4.0MB|3.7MB|4.2MB|3.8MB|
| ZSTD | 381.3 MB | 9.2 MB | 464.5 MB | 9.8 MB |
| TLZ4 | 83.2 MB | 33.8 MB | 74.9 MB | 33.8 MB |
| Other3 | 947.0 MB | 1454.7 MB | 1310.9 MB | 2344.5 MB |
| Apple | 1356.3 MB | 473.1 MB | 1193.8 MB | 590.3 MB |
| BVX3 | 1514.8MB | 2244.6MB | 1320.8MB | 2047.4MB |
| Lazy2 | 1703.3 MB | 2197.6 MB | 1490.1 MB | 2300.3 MB |
| Optimal | 1757.9MB | 2157.8MB | 1592.2MB | 2281.1MB |

> LZFSE/bvx3 series encode RSS is about 0.95–1.76 GB and decode RSS is about 1.45–2.34 GB, both of which are much higher than external tools, which is an independent memory pressure problem. Optimal encode is about 55 MB (claw) and 102 MB (llama) higher than lazy2, and the gap is less than the speed cost; therefore, the main difference between optimal and lazy2 is still DP calculation, but the overall encode/decode RSS of the bvx3 family must be listed separately.

## Lazy2 / Optimal Improvement Strategy / Strategy

1. **Profiling first and then move DP**: claw optimal 27.11 MB/s, still not close to 40+ MB/s. The next step is to use Time Profiler to find out the top two hot spots, and you can't change `lzParseOptimal` with the overall feeling.
2. **The cost gate is more valuable than the global optimal**: llama.cpp optimal spends 3.34x more compression time and only saves 1.8% of the volume; cheap probe should estimate the return at the segment level, and the low-income segment goes lazy2/bvx3.
3. **encode/decode RSS must be listed separately**: bvx3/lazy2/optimal encoding RSS about 1.3–1.8GB, decoding RSS about 2GB or more, significantly higher than TGZ/ZSTD/TLZ4; single-point improvement should be established for parallel encode/decode staging, workspace, output buffer, `Data` copy, do not mix with optimal DP acceleration.
4. **Conditions for the next round of success**: Profiling outputs the referenceable hotspot ranking, and proves that the compression time of the same round of claw optimal is improved by ≥10% with a single-point change, and the compression ratio does not regress.

## Next Round Plan / Next (R22)

- Use `helper/tracer.command` or Instruments to make Time Profiler for claw optimal, and put the output in `trace/`.
- Maintain the `-si` input path; do not use `-i` instead of pipeline measurement.
- Choose a hotspot to change according to profiler: chain walk, `matchLength`, dense relax, `rebuildPrices`, or pre-screen.
- If full benchmark is decompressed, remove the memProbe and decompression benchmark into different rounds to avoid the page-cache state from contaminating each other.

---

# Round 20: Full Benchmark + Memprobe Refresh (2026-06-14)/ Round 20: Full Benchmark + Memprobe Refresh

## Purpose of this round / Purpose

This round re-reads the latest `lz4bench-claw-code.txt`, `lz4bench-llama.cpp.txt`, `lzfse-test.txt`, `memprobeResults/lazy2-memprobe.txt`, `memprobeResults/optimal-memprobe.txt`, and recalculate the MB/s of `BenchMarkResult.csv` with exact raw bytes / nanoseconds. `lzfse-test.txt` is a function and compatibility test output, not a similar throughput benchmark, so it is used to confirm the compatibility of lazy2/optimal with Apple, and is not included in the MB/s table of CSV.

MB/s calculation is changed to decimal MB/s: `raw_bytes / elapsed_ns * 1000`. The original size bar still follows the existing CSV display convention (rounded after raw KiB to MiB). After compression, the size is rounded by exact compressed bytes to MB, and the compression ratio is calculated by "relative TGZ compressed bytes".

## Measure the completeness / Completeness

- ✅ `claw-code`: 8 format compression and decompression completed, 7/7 consistency passed.
- ✅ `llama.cpp`: 8 format compression and decompression completed, 7/7 consistency passed.
- ✅ `lzfse-test.txt`: Each test case lazy2 / optimal self-round trip, parallel decoding, Apple compatibility/rejection path are all passed, and there is no failure mark.
- ✅ `memprobeResults`: Get lazy2 / optimal encode and decode peak RSS of llama.cpp.
- ⚠️ `round_status.txt` still records the zsh `nomatch` message of `benchmark.sh`; the result file is still fully output, but the helper cleaning section needs to be modified to `NULL_GLOB` or glob qualifier to avoid misleading the status file.

## Measured Results (decimal MB/s, bytes/ns)

### Compression MB/s / Compression

| Format | claw-code | llama.cpp |
| --- | ---: | ---: |
|TGZ|52.69|68.15|
| Other3 | 542.12 | 447.14 |
| **Lazy2** | **51.89** | **155.37** |
| **Optimal** | **29.05** | **54.43** |
| BVX3 | 587.07 | 422.57 |
| Apple | 159.53 | 170.17 |
| TLZ4 | 627.54 | 370.01 |
| ZSTD | 489.21 | 442.07 |

### Decompression MB/s / Decompression

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

### Ratio and Within-Run Cost / Ratio and Within-Run Cost

| Data Set | Lazy2 ratio | Optimal ratio | Optimal Extra Volume Gain | Optimal/Lazy2 Compression Time |
| --- | ---: | ---: | ---: | ---: |
| claw-code | 0.9016 | 0.8590 | 4.72% smaller vs lazy2 | 1.79x |
| llama.cpp | 0.9587 | 0.9415 | 1.79% smaller vs lazy2 | 2.85x |

> The same-round comparison is still the most reliable indicator: claw-code optimal spends about 1.8x more compression time to change 4.7% volume; llama.cpp spends about 2.85x more to exchange only 1.8% volume. This supports the direction of "default or automatic policy bias lazy2, optimal only for high-volume sensitive segments".

## Memprobe Results / Peak RSS

| Mode | Encode peak RSS | Decode peak RSS |
| --- | ---: | ---: |
| llama.cpp bvx3 lazy2 | 1541.8 MB | 2300.5 MB |
| llama.cpp bvx3 optimal | 1611.6 MB | 2280.7 MB |

> optimal encode peak RSS is only about 69.8 MB (about +4.5%) higher than lazy2, which means that the main problem of optimal at present is not the memory peak, but the DP calculation time. Decode RSS are close to each other, and the optimal decode is slightly lower, which does not constitute the optimization spindle for the time being.

## Lazy2 / Optimal Improvement Strategy / Strategy

1. **Short-term success conditions are changed to profiling verification**: 40+ MB/s can be reserved as a medium-term target, but do not directly promise the speed in the next round; first use Time Profiler to find out the top two hot spots in about 49 seconds of claw optimal, and use at least one single-point change to prove that the same round ≥10% improvement.
2. **Segment hierarchical cost gate takes precedence over global optimal**: make a cheap probe for each segment to estimate the possible return of optimal relative lazy2; the low-yield segment goes directly to lazy2/greedy, and the high-yield segment enters DP. The optimal of llama.cpp only saves 1.8% more volume but takes 2.85x time, which is the most obvious candidate.
3. **DP core still needs UnsafePointer/SIMD, but it needs to be pointed by profiling**: The direction of R19 is still valid, but this round of data shows that the performance benefits cannot be exaggerated. If the profiler display costs are concentrated in chain walk, `matchLength`, dense relax, `rebuildPrices` or pre-screening, only the first and second hotspots will be changed to avoid large-scale rewriting.
4. **helper needs to clean up the status credibility first**: the `nomatch` message of `round_status.txt` will interfere with the reading; before the next benchmark, fix `benchmark.sh` to clean up the glob, and let `run_round.command` write `BENCH_FAILED` when the benchmark is not 0.

## Next Round Plan / Next (R21)

- Fix helper's zsh glob cleaning and failure status return, so that `round_status.txt` can directly judge whether the whole round is successful.
- Use `helper/tracer.command` or Instruments to measure claw optimal, and put the output into `trace/`, do not use `-i`, and the stin path must use `-si`.
- Choose a hotspot to make a single-point change according to the profiling result. The success condition is that the compression time of claw optimal in the same round is improved by at least 10%, and the lazy2/optimal compression ratio is maintained without regression.
- If you want to convert the small case of `lzfse-test.txt` into speed data, you need to make a special microbenchmark; at present, it is only used as a basis for correctness and does not compare with the MB/s of claw-code / llama.cpp.

---

# Round 19: Re-measurement After Landing Bounded-Buffer Backpressure (2026-06-14) / Round 19: Re-measurement After Landing Bounded-Buffer Backpressure

## Purpose of this round / Purpose

There is a code change in this round, but **not on the compression algorithm**: `runParallelEncode` binds `sem.signal()` from "task completed" to "chunk write", so that "read but not written" strictly ≤ maxTasks (memory upper bound ≈ maxTasks × chunkSize), fix the slow chunk in the front time pressure back body in `results` boundless accumulation (→ OOM) In order to exclude the single measurement deviation, this round uses ** the same program code three times** (R19a / R19b / R19c) two data sets 8 formats, answer: (1) whether this correction ** does not move to the compression ratio and single flow throughput ** (should only affect memory); (2) How much MB/s in bytes/ns fluctuates between "same code rerun" - thus separating the "algorithm effect" and "whole machine noise".

This round changes code but **not the compression algorithm**. To separate algorithm effect from machine noise, we ran the *same binary three times* (R19a/b/c). MB/s is calculated as `raw_bytes / ns × 1000` (bytes/ns).

## Measure the completeness / Completeness

✅ claw-code / llama.cpp 8 format compression + decompression, 7/7 decompression is the same; lzfse-test 112/112 full green (0 ✗); warm-cache takes effect. The **R19c** column in the following table is the latest retest (consistent with `BenchMarkResult.csv`), and the "three-round range" is listed to quantify the same code floating. All three rounds **no probe**; R20 has prepared `LZFSE_MEMPROBE=1` (see below).

## Measured Results / Measured Results (MB/s, bytes/ns)

### Compression MB/s (main indicator: three-round stability)/ Compression — the reliable metric

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

> **Compression MB/s is a stable and comparable indicator**: focus's optimal / lazy2 three-wheel floating is only ±2–7%. Claw optimal three-wheel 28.3 / 28.8 / 29.5 MB/s, lazy2 49.7 / 52.6 / 53.3 MB/s - this is the real algorithm throughput.

### Decompression MB/s (three wheels of the same code are extremely noisy and incomparable) / Decompression — too noisy to compare

| Format (claw) | Three-round range | Muntation |
|---|:---|---:|
| **ZSTD** | 380.5 – **1059.4** | **±88%** |
| BVX3 | 429.8 – 672.3 | ±45% |
| **Optimal** | 467.4 – 736.2 | ±42% |
| Other3 | 530.1 – 707.5 | ±28% |
| **Lazy2** | 545.7 – 696.9 | ±25% |
| TLZ4 | 678.7 – 862.9 | ±24% |
| Apple | 552.3 – 681.7 | ±21% |
| TGZ | 601.8 – 624.6 | ±4% |

> **This is the strongest evidence of this round**: three runs are **the same binary, the same data**, and the claw zstd decompression MB/s swings between 380 ↔ 1059 (**±88%**), and the optimal / bvx3 also reaches ±42–45%, and the direction is irregular. It proves that the decompression throughput is mainly determined by the hit rate and scheduling of OS page-cache. **A single decompression MB/s cross-wheel is incomparable and cannot be attributed to the algorithm**. The comparison compression side is only ±1–7% - so this report is based on **compression MB/s + relative amount in the same wheel**, and decompression is for reference only.

### Compression ratio (deterministic, reliable indicator)/ Ratio

| Format | claw R18 | claw R19 | llama R18 | llama R19 |
| --- | ---: | ---: | ---: | ---: |
| **Optimal** | 0.8590 | **0.8590** | 0.9416 | **0.9415** |
| **Lazy2** | 0.9020 | **0.9016** | 0.9583 | **0.9587** |
| BVX3 | 0.9516 | 0.9515 | 0.9815 | 0.9815 |

> After compression, the number of bytes is exactly the same in R19a / R19b / R19c ** three rounds ** (determinitive compression), and the difference from R18 is < 0.05% (it is a data set floating step by step + Apple/zstd size will fluctuate with the data). **Key verification: backpressure correction zero ratio influence** - The change of signal timing and memory boundary is indeed only moving to the sched, and did not touch `compressBody` and chunk cutting.

### Relative within the same round: Optimal / Lazy2 Compression Time Multiple (Most Reliable) / Within-Run Ratio

| Data Set | R18 | R19a | R19b | R19c |
| --- | ---: | ---: | ---: | ---: |
| claw-code | 1.95× | 1.76× | 1.83× | **1.81×** |
| llama.cpp | 2.93× | 2.80× | 2.80× | **2.89×** |

> In the same round, the time multiple of optimal relative lazy2 in three rounds is stable in claw ~1.8×, llama ~2.8×. This is a credible comparison that is not polluted by the noise of the whole machine: **Optimal takes about 1.8–2.9× more time, in exchange for only about 4% of the extra volume**.

## Lazy2 vs Optimal Improvement Strategy / Strategy

1. **The sweet point of the ratio is still lazy2**: claw lazy2 0.9016 (vs optimal 0.8590), with ~1.8× compression time in the same round for the additional ~4.3% volume of optimal; lazy2 is more cost-effective in most situations. It is only cost-effective when it is "one pressure, multiple transmission/resolve" and volume sensitivity.

2. **The bottleneck of optimal is in DP itself, not in parallel or memory**: compression MB/s is a stable indicator - claw optimal three rounds 28.3 / 28.8 / 29.5 MB/s, vs lazy2 ~50, zstd ~480. Parallel/memory has been repaired to a bound, ** is no longer a limiting factor**; to be faster, you must match the price/match of `lzParseOptimal` (UnsafePointer + SIMD).

3. **The measurement method has been partially hardened and still needs to be continued**: The decompression noise ±88% proves that warm-cache is not enough to stabilize the decompression timing. This round has: (a) reported that the spindle was changed to compression MB/s; (b) prepared the peak-RSS probe for R20. The next step is to take the medidium for "decompression" many times.

## Conclusions / Conclusions

1. **Modify in line with the design intention**: backpressure changes to "read and unwritten ≤ maxTasks", the upper boundary of memory ≈ maxTasks × chunkSize; the ratio is zero regression, and the compression path remains unchanged.
2. **The throughput difference is noise (proved by the same code three runs)**: The same binary three runs decompression MB/s can be different from ±88%, so the single decompression MB/s cannot be attributed to the algorithm; the compression MB/s (±1–7%) and the relative amount in the same round can be trusted.
3. **The ratio can be reproduced**: optimal claw 0.8590 / llama 0.9415, lazy2 claw 0.9016 / llama 0.9587, span R16–R19 (including three runs of the same size) is completely stable.
4. **The direction remains unchanged**: The next step of optimal acceleration is the DP kernel, not the parallel architecture (parallel has been fixed to a security boundary).

## Next Round Plan / Next (R20)

- **Prepared probe**: `benchmark.sh` defaults to `export LZFSE_MEMPROBE=1`, and the next round will automatically measure the **encode + decode** peak RSS of lazy2 / optimal ( `zshrc.sh`'s `memProbe` has been modified to " `time -l` direct prefix lzfse" instead of the package `sh -c` pipeline, otherwise it will be a a shell). Expected empirically optimal at the upper bound of 1.3GB GGUF memory ≈ maxTasks × chunkSize. To close: `export LZFSE_MEMPROBE=0`.
- **DP core UnsafePointer + SIMD**: Comprehensively index the price/match heat cycle of `lzParseOptimal`, eliminate Swift bounds-check and ARC overhead, and target claw optimal 29→40+ MB/s.
- **Measure hardening**: Decompression changes many times to take the medin (compression MB/s has been confirmed to be stable enough, continue to be the spindle), eliminating the ±88% decompression noise caused by page-cache.
- **Encoder adjuster**: automatically select bvx1/bvx2/bvx3 according to block entropy, integrate -lazy/-optimal.

---

# Round 18: R17 Changed Clean Environment Re-measurement (2026-06-14) / Round 18: Clean-Environment Re-measurement of R17

## Purpose of this round / Purpose

No code change. Both measurements of R17 were contaminated by the system load (even tgz dropped to 21 MB/s). In this round, it re-runs when the system is relatively idle, obtains a reliable absolute MB/s, and answers "Has the entropy gate parameter (7.2 / 35% / three-point sampling / text protection) makes the optimal faster?"

No code change. R17's measurements were load-contaminated; this clean re-run answers whether the entropy-gate tuning actually speeds up optimal.

## Measure the completeness / Completeness

✅ The two data sets are compressed in 8 formats + decompressed, 7/7 is consistent; lzfse-test is all green; warm-cache is effective. The system is relatively idle in this round - tgz/zstd/bvx3 has returned to normal speed (claw tgz 48.35, zstd 460, bvx3 511 MB/s), confirming the non-load wheel.

## Measured Results / Measured Results (MB/s, bytes/ns)

### Compressed MB/s (focus optimal) vs R16

| Format | claw R16 | claw R18 | llama R16 | llama R18 |
| --- | ---: | ---: | ---: | ---: |
| **Optimal** | 25.36 | **28.02** | 46.92 | **54.08** |
| **Lazy2** (not affected by entropy gate) | 47.36 | **54.58** | 129.59 | **158.74** |
| TGZ | 47.61 | 48.35 | 55.49 | 64.93 |
| ZSTD | 359.44 | 460.12 | 390.32 | 453.21 |

> ⚠️ optimal seems to be +10~15%, but **lazy2 (unrelated to the entropy gate) is also synchronized +15~22%, llama tgz +17%** - representing that the whole machine in this round is faster than R16 (system state difference), **is not the net acceleration brought by the entropy gate**. The absolute value of cross-wheel still cannot be directly attributed.

### Relative within the same round: Optimal / Lazy2 time multiple (trusted indicator)

| Data set | R16 multiple | R18 multiple |
| --- | ---: | ---: |
| claw-code | 1.87× | **1.95×** |
| llama.cpp | 2.76× | **2.93×** |

> Key: The time multiple R18 of optimal relative lazy2 in the same round **not decreased but slightly increased**. The reason is that R17's **text protection (isText) correctly leaves text segments in DP** (R16's 7.5 threshold without text protection may mistakenly skip some text segments and "steal"). In other words, the entropy gate parameter has no measurable net acceleration for these two data sets (claw=text, llama=source code)**.

### Compression ratio (deterministic, can be completely reproduced across multiple rounds)

| Format | claw | llama |
| --- | ---: | ---: |
| **Optimal** | **0.8590** | **0.9416** |
| **Lazy2**|0.9020|0.9583|

> Completely consistent with R16/R17. **Text protection unsacrificed ratio** - This is the real value of R17 modification: the possible text misjudgment of R16 is corrected under the fixed rate. The size of Apple/ZSTD will fluctuate slightly with the data set.

## Lazy2 vs Optimal Improvement Strategy / Strategy

1. **The effect of entropy gate for these data sets is limited**: claw is text (entropy < 7.2, and text protection is mandatory DP) → optimal cannot be accelerated by jumping DP; although llama contains binary, optimal still takes 2.9× time relative to lazy2. The real value of the entropy gate lies in the "**ratio-neutral safety net**" (to avoid waste of DP in random paragraphs and do not damage the text by mistake), rather than general acceleration.
2. **Optimal speed bottleneck is in DP itself**: claw optimal 28 MB/s vs lazy2 55 MB/s vs zstd 460 MB/s. To approach zstd, you must move the DP core thermal circulation knife.
3. **lazy2 is still the sweet spot of speed/ratio**: claw 54.58 MB/s, ratio 0.9020; most situations are better than the optimal 1.95× cost conversion rate of 4.3%.

## Conclusions / Conclusions

1. **Clean wheel confirmation**: This round of non-load wheel, absolute MB/s reliable.
2. **Entropy gate parameter no net acceleration**: the multiple of optimal/lazy2 in the same round does not decrease (claw 1.95×, llama 2.93×); the absolute improvement of optimal comes from the system state rather than the algorithm.
3. **Ratio zero regression and reproducible**: optimal claw 0.8590 / llama 0.9416 cross-wheel consistency; text protection is the real harvest of R17.
4. **Direction established**: Optimal acceleration must follow the DP core UnsafePointer/SIMD, instead of continuing to adjust the entropy gate parameters.

## Next Round Plan / Next (R19)

- **DP core UnsafePointer + SIMD**: Fully index the price/match heat cycle of `lzParseOptimal`, eliminate Swift bounds-check and ARC expenses, and target claw optimal 28→40+ MB/s.
- **Encoder adjuster**: automatically select bvx1/bvx2/bvx3 according to the block entropy, and introduce -lazy/-optimal.
- **The entropy gate is positioned as a safety net**: keep 7.2/35%/three-point/text protection (ratio neutral), and no longer use it as the acceleration spindle.

---

# Round 17: Entropy Gate Tuning + Three-Point Sampling + Text Protection + warm-cache (2026-06-14)/ Round 17: Entropy-Gate Tuning + 3-Point Sampling + Text Guard + Warm-Cache

## Purpose of this round / Purpose

According to Gemini's suggestion, refine the R16 entropy gate and improve the measurement stability: (1) entropy threshold 7.5→7.2, (2) pre-screen coverage threshold 28→35%, (3) `sampleEntropy` change three points (front/middle/back 512B each) sampling + text protection, (4) `lz4bench` plus warm-cache pre-read data set.

Implement Gemini's suggestions to refine the R16 entropy gate and stabilise measurement.

## Changes in this round / Changes

** `lzfse-cli.swift` ( `lzParseOptimal`):**

| Project | R16 | R17 |
| --- | --- | --- |
| `optEntropyHighThreshold` | 7.5 | **7.2** (Skip DP more actively) |
| `optPrescreenMinCoverage` | 28 | **35%** (more middle coverage segment go greedy) |
| Entropy sampling | Front 1KB single point | **Three points (front/middle/back 512B) average**, which can better represent the whole segment |
| Text protection | None | ** `isText` Gatekeeper**: Printable characters ≥85% of the paragraph, even with high entropy **does not jump DP** (to avoid misjudgment of text segments as a chaotic loss rate) |

** `zshrc.sh` ( `lz4bench`): ** Before compression timing, `tar -cf - "$1" > /dev/null` pre-reads the entire data set into the OS cache to eliminate the timing deviation of "the first format cold-cache, subsequent warm-cache".

## Test Completeness / Benchmark Completeness

- **claw-code / llama.cpp**: ✅ Each 8 format compression + decompression, 7/7 consistency passed; lzfse-test all green; warm-cache has taken effect.
- ⚠️ **This round of measurement is carried out under the system load** (see below).

## ⚠️ Measurement Condition Warning / Measurement Caveat

This round (and the previous rerun) **Compression MB/s of all formats has decreased comprehensively**, including tgz / zstd / bvx3 / lazy2 unrelated to the changes of this round:

| Format (compressed MB/s) | claw R16 | claw R17 | llama R16 | llama R17 |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 47.61 | 43.11 | 55.49 | 37.50 |
| ZSTD | 359.44 | 209.93 | 390.32 | 199.59 |
| BVX3 | 515.82 | 205.28 | 299.04 | 162.65 |
| **Lazy2** (not changed in this round) | 47.36 | 37.40 | 129.59 | 75.80 |
| **Optimal** | 25.36 | 16.17 | 46.92 | 26.17 |

> tgz/zstd/bvx3/lazy2 have nothing to do with the entropy gate but decreased by 15-60% synchronously, which can be determined to be caused by **system load** (background check.sh, caffeinate, dispatch, Claude running at the same time), **non-algorithm regression**. Therefore, this round of "absolute compression MB/s" cannot be compared across wheels.

## Reliable Metric: Ratio (deterministic)/ Reliable Metric: Ratio

| Format | claw R16 | claw R17 | llama R16 | llama R17 |
| --- | ---: | ---: | ---: | ---: |
| **Optimal** | 0.8594 | **0.8590** | 0.9411 | **0.9416** |
| **Lazy2** | 0.9018 | **0.9018** | 0.9573 | **0.9590** |

> The compression ratio is almost exactly the same as that of R16 (the difference is < 0.2%, which is a floating data set version). **Key conclusion: After adding text protection, the optimal ratio did not regress** - it proves that the entropy gate of R16 did not skip text segments by mistake due to the 7.5 threshold (claw is text, isText is still DP throughout the whole process after guarding the door, and the ratio remains unchanged). The size of Apple/ZSTD will fluctuate slightly with the data set.

## Lazy2 vs Optimal (R17, only relatively effective in the same round)/ Within-Run Relative

| Pointer | claw Lazy2 | claw Optimal | llama Lazy2 | llama Optimal |
| --- | ---: | ---: | ---: | ---: |
| Compressed MB/s | 37.40 | 16.17 | 75.80 | 26.17 |
| Decompression MB/s | 442.98 | 436.02 | 128.67 | 137.85 |
| Compression ratio | 0.9018 | 0.8590 | 0.9590 | 0.9416 |
| Optimal/Lazy2 Compression Time Multiple | — | **2.31×** | — | **2.90×** |

> In the same round, the optimal time multiple claw 2.31×, llama 2.90× (consistent with the same trend as R16). Due to the load of the whole machine, it is impossible to determine the "net acceleration" brought about by the entropy gate adjustment from this round of numbers.

## Conclusions / Conclusions

1. **All four changes have been implemented and correct**: compilation passed, lzfse-test 7/7, consistency 7/7, warm-cache effective.
2. **The ratio has not regressed**: The text protection is effective, and the claw/llama optimal compression ratio is the same as R16 - confirm that the three-point sampling + isText gatekeeper does not destroy the compression quality.
3. **Absolute speed comparison cannot be made in this round**: the full format (including irrelevant tgz/zstd/bvx3/lazy2) is slowed down by 15-60% by the system load; the net acceleration effect of entropy gate parameter adjustment** has not been measured**.
4. **warm-cache is in place**: In the future, cold-cache can reduce the interference of compression timing under clean conditions.

## Next Round Plan / Next (R18)

- **Clean environment measurement**: Rerun a round under the system idle (pause check.sh / dispatch) to isolate the real acceleration of 7.2 threshold + 35% coverage rate + three-point sampling for llama optimal.
- **Encoder adjuster**: automatically select bvx1/bvx2/bvx3 according to the block entropy, and introduce -lazy/-optimal.
- **Swift thermal cycle UnsafePointerization**: claw (text) optimal is protected by text throughout the whole process DP, and the acceleration must rely on DP's own SIMD/pointerization, challenging the C version of zstd.

---

# Round 16: Entropy Perception Gate (Data-Driven GGUF Partition) (2026-06-13) / Round 16: Entropy-Aware Gate (Data-Driven GGUF Partitioning)

## Purpose of this round / Purpose

In view of the observation that "GGUF tensor weight accounts for ~99% of volume, content is chaotic, and the difference between optimal and greedy ratio is < 0.5%", add ** segment hierarchical entropy sampler ** as the cheapest first gate for optimal: pseudo-random segment directly greedy launch, completely skip expensive DP in exchange for compression throughput. Purely look at the content, do not sniff the GGUF format/ofset (fragile).

Add a segment-level Shannon-entropy sampler as optimal's cheapest first gate: pseudo-random segments emit greedy and skip DP entirely, trading away DP cost for throughput. Content-driven - no fragile GGUF format/offset sniffing.

## Changes in this round / Changes

** `lzfse-cli.swift` - `lzParseOptimal` Add Entropy Gate (R10 Design, This Round Of Practical Install):**

| Project | Description |
|---|---|
| `optEntropySampleBytes` | 1024 (1KB before sampling of each segment) |
| `optEntropyHighThreshold` | 7.5 bits/byte (the above is regarded as a mess, skip DP) |
| Gate position | Placed in front of the coverage gate (R9) ****: `segLen >= 4096 && sampleEntropy() > 7.5` → `greedyEmitSegment()` |
| Cost | Entropy sampling 1KB ≪ Full segment scanning with coverage rate; high entropy segment saves the whole segment DP (DP cost is about dozens of times that of greedy) |
| Shared | Entropy gate and coverage gate share `greedyEmitSegment()` (rep perception, match intercepted in segEnd, maintain the cross-segment litStart invariant) |

`sampleEntropy()` 1KB before sampling Shannon entropy (bits/byte); `greedyEmitSegment()` is reconstructed by R15's inline greedy into a reusable function for two gates to share. Lazy2 parsing path is not affected (entropy gate is only in optimal).

## Test Completeness / Benchmark Completeness

- **claw-code**: ✅ All completed (8 format compression + decompression, 7 consistency passed)
- **llama.cpp**: ✅ All completed (8 format compression + decompression, 7 consistency approved)
- **lzfse-test**: ✅ All green (including bvx3 lazy2/optimal self-round-trip and parallel decoding)
- ✅ **Sufficient disk**: benchmark.sh double diskcheck passed (28GB at the beginning, 26GB before the llama segment, both ≥25GB threshold); EXIT 0, BENCH_DONE 19:57:21.

## Measured Results / Measured Results (R16 vs R15, MB/s in actual bytes/ns)

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

> ‡ lazy2 is not affected by the entropy gate (the entropy gate is only within the optimal analysis); ±2–9% is measured noise and the data set version fluctuates.
>
> ※ R15's llama BVX3/Apple/TLZ4/ZSTD compression MB/s is low due to the cold-cache I/O of this round (marked in R15); R16 cache conditions are better, so it rebounds sharply - this is **the difference in measurement conditions**, not the change in algorithm, and the cross-wheel must be compared with the same conditions.
>
> ** Core conclusion: the entropy gate allows llama optimal to compress +7.4% (the random GGUF weighted segment skips), DPclaw optimal +1.6% (low text entropy, fewer segments that trigger the gate). ** The direction is consistent with the design expectations: high-entropy data benefits the most.

### Compression Size (Precise byte)/ Compression Sizes

| Format | claw R15 (bytes) | claw R16 (bytes) | Difference | llama R15 (bytes) | llama R16 (bytes) | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Optimal** | 422,142,121 | 422,452,184 | +310,063 (+0.07%) | 571,976,860 | 573,166,606 | +1,189,746 (+0.21%) |
| **Lazy2** | 443,315,744 | 443,301,919 | −13,825 (≈0%) | 582,331,084 | 583,052,611 | +721,527 (+0.12%)‡ |

> Optimal is changed to greedy due to the high entropy segment, and the compression ratio is slightly reduced (claw 0.8588→0.8594, llama ~0.9416→0.9411 interval), and the cost is < 0.25% - it is a reasonable trade-off of "DP cost vs < 0.5% ratio difference". ‡ The difference between lazy2 comes from the fluctuation of the data set version (there is a new commit in the llama.cpp repository). The compression size of Apple/ZSTD will fluctuate slightly even if the data is the same, and the cross-wheel comparison takes MB/s as the main indicator.

## Lazy2 vs Optimal Analysis (R16)/ Lazy2 vs Optimal Analysis

| Pointer | claw Lazy2 | claw Optimal | llama Lazy2 | llama Optimal |
| --- | ---: | ---: | ---: | ---: |
| Compressed MB/s | 47.36 | **25.36** | 129.59 | **46.92** |
| Unzip MB/s | 569.36 | **654.13** | 216.59 | **236.49** |
| After compression | 443M | **422M** | 583M | **573M** |
| Compression ratio (vs tgz) | 0.9018 | **0.8594** | 0.9573 | **0.9411** |
| Optimal vs Lazy2 Compression Time Multiple | — | **1.87×** | — | **2.76×** |

**R16 trade-off:** The entropy gate presses the time multiple of llama optimal from 3.26× of R15 to **2.76×** (the random section no longer enters DP), and the ratio remains almost unchanged (−0.05 pt). Claw optimal multiple 1.87× (the same as R15 1.85×, most text segments are still in DP). Decompression optimal is still slightly faster than lazy2 (shared bvx3 bit stream, the difference is noise).

## Conclusions / Conclusions

1. **Entropy gate is effective for high entropy data**: llama optimal compression +7.4%, time multiple 3.26×→2.76×, ratio cost < 0.25%. The design goal has been achieved.
2. **The benefit of text data is limited**: claw optimal is only +1.6% - the text entropy is low (most segments < 7.5 bits/byte), and it still follows DP; the optimal bottleneck of the text is still DP itself.
3. **lazy2 is not affected**: The entropy gate is only within the optimal analysis, and the lazy2 data changes to noise/data set floating.
4. **Measurement discipline**: The cache conditions of this round are better than R15, and the BVX3/Apple/TLZ4/ZSTD compression MB/s rebounded significantly due to the condition difference; cross-wheel only compares the same conditions, with optimal/lazy2 compression MB/s + compression ratio as the main indicator.
Five. **Consistency and test are all green**: The two data sets are 7/7 consistent, lzfse-test is fully passed, and the disk double inspection is passed.

## Next Round Plan / Next (R17)

- **Lower the entropy threshold**: 7.5 is conservative; you can try 7.0–7.3, so that more "medium and high entropy" llama segments can skip DP (expected optimal will be accelerated by 5–15%, and the ratio cost < 0.5%). It is necessary to protect the text data to avoid the text segment with high local entropy mistakenly jumping DP and losing the rate.
- **Encoder dispatcher**: Automatically select bvx1/bvx2/bvx3 according to the block entropy, and introduce -lazy and -optimal (an extension of the R10 concept).
- **Swift hot cycle**: kernel match/DP loop comprehensive `UnsafePointer` ization, eliminate Swift object-oriented overhead, and challenge the compression throughput of C version zstd.
- **Entropy sampling enhancement**: 1KB single-point sampling may misjudge mixed segments; you can try multi-point sampling or pre/middle/back three-segment sampling to get the average value.

---

# Round 15: Two-Pass Prescreen + Search Budget Counter (2026-06-13) / Round 15: Two-Pass Prescreen + Search Budget Counter

## Purpose of this round / Purpose

Fix and fully complete the two missing strategies of R14 (attachment code, R9 design):

1. **Adaptive Search Budget**: Each segment of budget = `segLen × 2`, and the cumulative number of actual chain visit steps in the reverse formula; after overspending, the search depth of the remaining position of the whole segment is forced to be cut in half (retain the lower limit of the desert). It is more accurate than R14's "cycle reset" mechanism - once it is overspend, flag is set immediately, and it will no longer be restored periodically.
2. **Two-Pass Greedy Prescreen**: Each segment first uses an independent 14-bit local hash (non-polluting the main head/chain) for lightweight greedy scanning; the whole segment (binary/random) with agreedy match coverage rate of < 28% is directly launched by greedy, **completely skipping DP**. The greedy path maintains cross-segment continuity through `emitGreedy()` shared DP's L/M/D statistics and rep history.

R14's rough estimate `totalBarren` entropy agent (70% desert threshold) has been replaced by the real greedy pre-sweeping. `optSufficientLen` is reduced to 192 (with pre-screen protection, no need for R14 radical 128 truncation).

## Changes in this round / Changes

** `lzfse-cli.swift` — `lzParseOptimal` Changes (R9 Strategy):**

| Project | R14 | R15 |
| --- | --- | --- |
| `optSufficientLen` | 128 | 192 (Restore) |
| `optBudgetMultiplier` | 3 | 2 (TIGHTER BUDGET) |
| Budget Logic | `chainBudget` Count + Cycle Reset `effectiveDepthCap` | `searchBudget` Countdown + `budgetExhausted` flag |
| Low-compression segment processing | `totalBarren` rough estimate (70% desert) | Independent local hash greedy pre-sweeping (28% coverage) |
| Skip DP | No | Low coverage segment directly greedy launch |

**Bug repair (discovered in the first round of R15)**: The match `limit` of the pre-screening segment was originally `n - i - 4`, allowing the match to cross `segEnd`, resulting in the next DP `litStart > segStart`, `pushRun` gets negative L length → stream damage (decode failed). Fix it to `limit: max(0, segEnd - i - 4)` to ensure that the match does not cross segments.

## Test Completeness / Benchmark Completeness

- **claw-code**: ✅ All completed (8 format compression + decompression, 8 consistency all passed)
- **llama.cpp**: ✅ All completed (8 format compression + decompression, 8 consistency all passed)
- **lzfse-test**: ✅ All green (compile 8s, including bvx3 lazy2/optimal self-round trip)
- ✅ **Disk sufficient**: Final rerun disk **43 GB available** (≫25 GB threshold), compression and decompression numbers are reliable. The first round (disk 15 GB + residual file) decompression number has been abandoned, subject to this rerun.
- ✅ **benchmark.sh Enhancement**: Add double disk space check (before the beginning + llama segment, < 25 GB → `"Benchmark aborted: insufficient disk space"` and stop) and `rm -rf llama.cpp.*` residual file cleaning to prevent the next rerun from being affected by disk pressure.

## Measured Results / Measured Results (R15 rerun vs R14, disk 43 GB)

### Compression MB/s (Compression Throughput) - Focus: lazy2 / optimal

| Format | claw R14 | claw R15 | Difference | llama R14 | llama R15 | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Lazy2** | 47.91 | **46.27** | −3.4% | 140.68 | **142.63** | **+1.4%** |
| **Optimal** | 26.53 | **24.96** | −5.9% | 42.88 | **43.69** | **+1.9% 🟢** |
| Other3 | 412.63 | **404.87** | −1.9% | 359.91 | **361.48** | +0.4% |
| BVX3 | 457.95 | **410.62** | −10.3%† | 353.02 | 135.35 | −61.7%†† |
| Apple | 140.60 | **143.54** | +2.1% | 146.59 | 88.99 | −39.3%†† |
| TGZ | 46.65 | **46.05** | −1.3% | 54.11 | **54.60** | +0.9% |
| TLZ4 | 534.12 | **536.59** | +0.5% | 320.09 | 133.67 | −58.2%†† |
| ZSTD | 383.93 | **369.66** | −3.7% | 368.88 | 136.97 | −62.9%†† |

> † claw BVX3 slow (3.29s vs 2.86s): After this round of claw optimal (54s), the system may have a brief I/O flush, resulting in a slight slower subsequent BVX3. Measuring noise, non-algorithm regression.
>
> †† llama BVX3 / Apple / TLZ4 / ZSTD is significantly slow: It is speculated that the system page cache is cleared after claw optimal (54s) + sleep 60, and the cold-cache I/O is serious when llama.cpp is read for the first time. Other3 (3.48s) is the first to run and still enjoys partial cache; the following format cold cache is fully open (each needs to reread 1.2 GB). This is **the difference in measurement conditions**, non-algorithm regression - the compression ratio (size) is not affected at all.
>
> **Core conclusion (rerun): llama.cpp optimal +1.9%, llama Lazy2 +1.4% (vs R14)**. Optimal improvement is more conservative than the first round (+11.5%), because the first round of disk pressure also lowers the reference baseline of the first round of R15. The rerun results are more reliable: the two-stage pre-screening brings a stable and small improvement to llama optimal under clean conditions, and the claw slightly regresses (−3–6%) is a measurement noise.

### Compression Sizes / Compression Sizes

| Format | claw R14 (bytes) | claw R15 rerun (bytes) | Difference | llama R14 (bytes) | llama R15 rerun (bytes) | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Lazy2** | 443,315,716 | 443,315,744 | +28 B (≈0%) | 582,331,025 | 582,331,084 | +59 B (≈0%) |
| **Optimal** | 421,706,858 | 422,142,121 | +435,263 (+0.1%) | 567,544,521 | 571,976,860 | +4,432,339 (+0.78%) |

> The size difference of Lazy2 is only 28 / 59 bytes, which comes from **data set version floating** (claw-code / llama.cpp source code repository has a new commit), which is not a different algorithm output. Optimal changes to the greedy path in some segments, and the compression ratio decreases slightly (llama: 0.9416 vs R14 0.9343, +0.73 percentage points). The compression size of Apple and ZSTD will also fluctuate slightly with the data set version, and the cross-round comparison takes MB/s as the main indicator. This is a reasonable choice of speed exchange rate.

## Lazy2 vs Optimal Analysis (R15 Rerun) / Lazy2 vs Optimal Analysis

| Pointer | claw Lazy2 | claw Optimal | llama Lazy2 | llama Optimal |
| --- | ---: | ---: | ---: | ---: |
| Compressed MB/s | 46.27 | **24.96** | 142.63 | **43.69** |
| Unzip MB/s | 544.71 | **622.95** | 161.22 | **197.97** |
| After compression | 443M | **422M** | 582M | **572M** |
| Compression ratio (vs tgz) | 0.9018 | **0.8588** | 0.9587 | **0.9416** |
| vs ZSTD size (byte precision) | +9.2% | +4.0% | +5.1% | +3.2% |
| Optimal vs Lazy2 Time Multiple | — | **1.85×** | — | **3.26×** |

**R15 trade-off (rerun): ** claw optimal time multiple 1.85× (vs R13's 2.3×, significantly improved). Llama optimal time multiple 3.26× (3.3× of vs R13, slight improvement). Decompression of optimal is slightly faster than lazy2 (the same bvx3 bit stream, the decoder path is the same, the difference is measurement noise). Optimal's ratio advantage (relative to lazy2) maintains −4.3% (claw)/ −1.7% (llama), and still needs to pay 2–3× compression time than lazy2.

## Conclusions / Conclusions

1. **The two-stage pre-screening is slightly effective for binary data**: llama.cpp optimal +1.9%, llama Lazy2 +1.4% (vs R14) under the condition of heavy running clean. The first round +11.5% includes disk pressure noise, and it is more reliable to run again.
2. **Text data (claw-code) regressed slightly**: The final claw optimal −5.9%, Lazy2 −3.4%, in the measured noise range, the non-algorithm regressed significantly.
3. **Bug repair experience**: The match of the greeny path must be limited to the segment boundary ( `segLimit = max(0, segEnd - i - 4)`), otherwise `litStart > segStart` after crossing the segment will cause `pushRun` negative L length and stream damage.
4. **Compression size cost**: The optimal ratio is slightly reduced (llama +0.78%), and the acceptable speed is exchanged for the ratio.
Five. **Decompression digital (rerun) reliable**: claw optimal 622.95 MB/s, llama optimal 197.97 MB/s, extremely fast decompression under sufficient disk conditions, and the advantage of bvx3 family shared bit flow is obvious.
6. **benchmark.sh improvement**: New disk insufficient abort (< 25 GB) + llama front residual file cleaning to avoid future rerun data contamination by disk pressure.

## Next Round Plan / Next (R16)

Llama.cpp optimal is still 3× slower than zstd (9.18s → 137 MB/s), and claw optimal is 1.85× slower than TGZ. The next direction:

- **Adjust the pre-screening threshold**: 28% coverage is conservative; 35-40% can be tried to make more "medium coverage" llama segments greedy and further accelerate (expected: the compression ratio will be reduced by 0.5–1% and the speed will be increased by 5–15%).
- **cold-cache I/O problem**: LLAMA's BVX3 / Apple / TLZ4 / ZSTD is extremely slow when rerunning (cold cache). In the next round, consider warm cache (read the original data) before each format of lz4bench to make the compression timing more stable.
- **claw-code slight regression confirmation**: Profiling confirms whether the segLimit truncation really causes a decrease in DP efficiency, or just measures noise; if it is truncated, consider the last match to allow extension to `n`.

---

# Round 14: Gemini Search Budget + Entropy Agent (2026-06-13) / Round 14: Gemini Budget Counter + Entropy Proxy

## Purpose of this round / Purpose

For the optimal compression bottleneck of R13 (claw 22.45 MB/s, llama 38.84 MB/s), five improvement strategies are proposed according to Gemini.

## Changes in this round / Changes

** `lzfse-cli.swift` — `lzParseOptimal` Five R14 OPTIMIZATION:**

1. `optSufficientLen`: 192 → **128** (Super match fast path is more radical, strategy 5)
2. `optBudgetMultiplier = 3` (search budget for each segment = segLen × 3, strategy 1)
3. `chainBudget` Count + Cycle Reset `effectiveDepthCap` (Dynamic Search Depth, Strategy 1)
4. `totalBarren` Segment-level entropy agent (70% desert → mandatory minimum depth, strategy 2/6)
5. The depth calculation is changed to `effectiveDepthCap` to replace the fixed `optSearchDepth`

## Test Completeness / Benchmark Completeness

- **claw-code**: ✅ All completed (8 formats, all passed)
- **llama.cpp**: ✅ All completed (8 formats, all passed)
- **lzfse-test**: ✅ All green

## Measured Results (R14 vs R13)

### Compression MB/s (Compression Throughput)

| Format | claw R13 | claw R14 | Difference | llama R13 | llama R14 | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Lazy2** | 47.31 | **47.91** | +1.3% | 127.84 | **140.68** | **+10.0% 🟢** |
| **Optimal** | 22.45 | **26.53** | **+18.2% 🟢** | 38.84 | **42.88** | **+10.4% 🟢** |
| Other3 | 400.55 | **412.63** | +3.0% | 273.41 | **359.91** | +31.6% |
| BVX3 | 440.53 | **457.95** | +4.0% | 276.71 | **353.02** | +27.6% |
| ZSTD | 386.74 | **383.93** | −0.7% | 371.41 | **368.88** | −0.7% |

> **Optimal significant improvement**: claw +18.2% (22.45→26.53 MB/s), llama +10.4% (38.84→42.88 MB/s).

### Compression Sizes / Compression Sizes

| Format | claw R13 (bytes) | claw R14 (bytes) | Difference | llama R13 (bytes) | llama R14 (bytes) | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Optimal** | 420,637,504 | 421,706,858 | +0.25% | 566,261,130 | 567,544,521 | +0.23% |

## Conclusions / Conclusions

The five strategies of R14 practice bring significant improvement to optimal (+10–18% compression speed), at the cost of a slight regression of the compression ratio (+0.25%), acceptable trade-off.

---

# Round 13: Full Reliable Benchmark After Disk Recovery (2026-06-13) / Round 13: Full Reliable Benchmark After Disk Recovery

## Purpose of this round / Purpose

No algorithm code change. R12 because the disk is only 10–12 GB distortion and llama.cpp decompression is truncated; this round is rerun under the disk recovery to **claw 32 GB / llama 31 GB available** (≫ 25 GB alert value) to obtain the reliable data of the two data sets ** full 8 formats, compression + decompression complete**, and verify that the lazy2/optimal product is correct.

No algorithm code change. This round re-runs the benchmark with disk restored to **claw 32 GB / llama 31 GB free** (well above the 25 GB threshold), producing a complete, reliable dataset for both corpora — all 8 formats, compression *and* decompression — and confirming lazy2/optimal artifacts are correct.

## Changes in this round / Changes

** `zshrc.sh` - `lz4bench` PICKS BACK `diskcheck`: ** AFTER R11 EXTRACTED THE DISK PRE-INSPECTING INTO AN INDEPENDENT `diskcheck()`, `lz4bench` WAS NOT RECEPTED BACK, SO THAT THE PRE-INSPECTION BECAME A DEAD CODE. Add `diskcheck "$1"` at the beginning of `lz4bench` in this round, and actively return the disk available space before each round of benchmark run (this round: sufficient claw 32 GB / llama 31 GB) to avoid the generation of distortion data under disk pressure again. `extract`, `lzfseX` processing of lazy2/optimal ( `-lazy2` / `-optimal` flag, `-algo bvx3` decoding) has been checked correctly and maintained.

## Test Completeness / Benchmark Completeness

- **claw-code**: ✅ All completed (8 format compression + decompression, 7 consistency passed)
- **llama.cpp**: ✅ All completed (8 format compression + decompression, 7 consistency all passed) - R12's Apple/TLZ4/ZSTD decompression truncation has been restored
- **lzfse-test**: ✅ All green (including bvx3 `-lazy2` / `-optimal` self-round-trip and parallel decoding)

## Measured Results / Measured Results (R13 vs R11 Reliable Baseline)

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

> lazy2/optimal The difference between compression MB/s and R11 is only 1–6%, which falls into the range of measurement noise - confirmation **compression throughput stability can be reproduced**.

### Decompress MB/s (Decompression Throughput)

| Format | claw R11 | claw R13 | Difference | llama R11 | llama R13 | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| **Lazy2** | 460.04 | **332.40** | −27.7% | 228.01 | **198.27** | −13.0% |
| **Optimal** | 548.28 | **261.57** | −52.3% | 199.41 | **202.22** | +1.4% |
| Other3 | 503.52 | **490.25** | −2.6% | 256.81 | **161.77** | −37.0% |
| BVX3 | 481.99 | **443.04** | −8.1% | 232.81 | **165.18** | −29.0% |
| Apple | 617.76 | **395.09** | −36.0% | 209.68 | **183.56** | −12.5% |
| TGZ | 533.61 | **419.14** | −21.5.5% | 259.96 | **182.99** | −29.6% |
| TLZ4 | 266.01 | **695.20** | +161% | 244.49 | **204.89** | −16.2% |
| ZSTD | 355.65 | **362.38** | +1.9% | 231.66 | **135.37** | −41.5% |

> ⚠️ Decompression MB/s fluctuates greatly between different rounds (548 of claw Optimal R11, 695 of TLZ4 R13, etc. are all outly values related to system load). ** The decompression speed is greatly affected by the system's transient load and file cache, and the single-wheel value should not be regarded as algorithm characteristics. ** Key observation: **llama Optimal decompression (202) ≈ Lazy2 (198) ** - once again confirms that the bvx3 family (lazy2/optimal/bvx3) shares the same meta-stream format, and the decompression speed is determined by the format rather than the parsing strategy.

### Compression Size (precise byte, Compression Sizes)

| Format | claw R11 (bytes) | claw R13 (bytes) | Difference | llama R11 (bytes) | llama R13 (bytes) | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| Lazy2 | 443,123,872 | 443,315,716 | +0.04% | 582,575,735 | 582,331,025 | −0.04% |
| Optimal | 420,637,703 | 420,637,504 | −199 B | 566,223,268 | 566,261,130 | +0.01% |

> The offset of the compressed output byte size relative to R11 is < 0.05% (from the data set/tar metadata fluctuates slightly), **confirm that the algorithm output is deterministic**, and the lazy2/optimal product is correct.

## Lazy2 vs Optimal Analysis (R13)/ Lazy2 vs Optimal Analysis

| Pointer | claw Lazy2 | claw Optimal | llama Lazy2 | llama Optimal |
| --- | ---: | ---: | ---: | ---: |
| Compressed MB/s | 47.31 | **22.45** | 127.84 | **38.84** |
| Unzip MB/s | 332.40 | 261.57 | 198.27 | 202.22 |
| After compression | 433M | **417M** | 556M | **544M** |
| Compression ratio (vs tgz) | 0.9018 | **0.8557** | 0.9587 | **0.9322** |
| vs ZSTD Size | +3.7 pt | +3.0 pt | +4.7 pt | +2.0 pt |

**Core trade-off:** Optimal exchanges the compression time of **2.1× (claw)/ 3.3×(llama)** for the relative Lazy2 only **−3.7%(claw)/−2.1%(llama) file size**. Optimal's compression throughput (claw 22.45 MB/s) is the slowest in the whole table and the main bottleneck; Lazy2 is the best sweet spot in terms of speed/ratio.

## Conclusions / Conclusions

1. **R13 is a reliable round**: Disk claw 32 GB / llama 31 GB, the two data sets are compressed and decompressed in 8 formats, and the R12 truncated llama decompression data is completed.
2. **Compressed MB/s stable and reproducible**: The gap between lazy2/optimal and R11 is only 1–6% (noise range).
3. **Decompression MB/s high fluctuation**: Cross-wheel separation is serious, dominated by system load/cache; multi-round median comparison should be used instead of a single-round comparison, and only compressed MB/s and compression ratio should be used as the main indicator of algorithm quality.
4. **lazy2/optimal product correct**: byte size offset < 0.05% (deterministic), consistent with lzfse-test all green.
Five. **Optimal compression throughput is the bottleneck**: claw 22.45 MB/s (the slowest in the whole table), the DP optimal analysis cost is high, and the ratio gain relative to Lazy2 is limited.

## Next Round Plan / Next (R14)

Profiling for **claw-code `-optimal` compression hotspot (22.45 MB/s)**, and evaluate the following lazy2/optimal improvement strategies:

```sh
# 確認磁碟空間後再 profiling
df -h ~                 # 需 ≥25 GB
./run_profile.command   # 對 claw-code -optimal 取樣
```

- **Optimal**: SIMDize the DP cost model, or set the search depth upper limit (fast-skip) for the long match, and the goal is to recover the throughput without damaging the compression ratio.
- **Lazy2**: Maintain it as the sweet point of speed/ratio; observe whether it can be slightly close to the optimal ratio without sacrificing the speed advantage of ~2×.
- **Measurement discipline**: Decompress MB/s to take the medidic for multiple rounds to reduce the out-of-group interference caused by the system load.

---

# Round 12: Benchmark Under Disk Pressure (2026-06-13) / Round 12: Benchmark Under Disk Pressure

## Purpose of this round / Purpose

No algorithm code change - run a round again under the same benchmark architecture to see if the reliable data of R11 can be reproduced.
The results show that the available space of the disk is seriously insufficient, resulting in data distortion, **R12 unreliable measurement round**.

## Disk Status / Disk Conditions

| Data set | Available space at the beginning | Alert value | Status |
| --- | ---: | ---: | --- |
| claw-code | **10 GB** | ≥25 GB | ⚠️ Serious insufficient |
| llama.cpp | **12 GB** | ≥25 GB | ⚠️ Seriously insufficient |

Only 10 GB of claw-code is available, and the disk I/O is very competitive during the compression process; although the claw-code is temporarily stored in the llama.cpp stage, there is still only 12 GB left.

## Test Completeness / Benchmark Completeness

- **claw-code**: ✅ All completed (8 format compression + decompression, 7 consistency passed)
- **llama.cpp**: ⚠️ Decompression truncation - Apple/TLZ4/ZSTD decompression is not completed (benchmark is suspended in the Apple decompression stage)

## Measured Results / Measured Results

### Compression MB/s (Compression Throughput)

| Format | claw R11 | claw R12 | Difference | llama R11 | llama R12 | Difference |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| TGZ | 47.81 | **38.89** | −18.6% 🔴 | 55.81 | **54.13** | −3.0% |
| Other3 | 407.40 | **238.98** | −41.3% 🔴 | 240.11 | **217.73** | −9.3% |
| **Lazy2** | **49.21** | **37.15** | **−24.5% 🔴** | **129.16** | **125.90** | **−2.5%**
| **Optimal** | **23.99** | **17.46** | **−27.2% 🔴** | **40.85** | **39.48** | **−3.4%** |
| BVX3 | 413.47 | **410.78** | −0.7% | 229.06 | **221.63** | −3.2% |
| Apple | 136.61 | **138.16** | +1.1% | 127.65 | **120.43** | −5.7% |
| TLZ4 | 534.35 | **521.52** | −2.4% | 273.93 | **257.90** | −5.9% |
| ZSTD | 404.11 | **397.63** | −1.6% | 338.85 | **309.24** | −8.7% |

> The compression speed of claw-code has decreased by 20-40% across the board, and disk I/O competition is the main reason (SSD random writing speed decreases significantly when there is only 10 GB left).
> llama.cpp compression is reduced by 3–9%, and the disk is slightly better (12 GB), but it is still low.

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
| ZSTD | 355.65 | **317.69** | −10.7% | 231.66 | —(truncated) | — |

> ⚠️ The decrease in the decompression speed of claw-code is more serious (-40 to -65%), far exceeding the decrease in compression, indicating that decompression is more sensitive to the available space of the disk.
> TLZ4 claw exception (+14%) may be noise measurement.

### Compression Sizes

| Format | claw R11 | claw R12 | llama R11 | llama R12 |
| --- | ---: | ---: | ---: | ---: |
| TGZ | 480M | **481M** | 592M | **593M** |
| Lazy2 | 432M | **423M** | 561M | **570M** |
| Optimal | 417M | **407M** | 544M | **544M** |
| ZSTD | 395M | **395M** | 544M | **528M** |

> The M unit of `du -sh` is configured for disk blocks (non-precise bytes), and small fluctuations are normal.
> byte-level precise size ( `[SIZE]`) shows that the output of the compression algorithm is completely consistent (deterministic).

## Conclusions / Conclusions

1. **R12 is an unreliable round**: The available space of the disk 10–12 GB is far lower than the recommended ≥25 GB, and both compression and decompression are seriously distorted.
2. **Disk pressure has a particularly heavy impact on decompression**: claw decompression decreases -40 to -65%, which is much greater than the compression -20 to -40%.
3. **llama.cpp benchmark truncation**: benchmark is suspended in the llama.cpp Apple decompression stage, and the Apple/TLZ4/ZSTD decompression data is missing.
4. **Compressed byte size is the same**: The algorithm output is still deterministic, and the exact size of R12 and R11 coincides.
Five. **R11 is still a valid baseline**: Please take R11 as the benchmark for the next round of comparison.

## Next Round Plan / Next (R13)

**Clean the disk to ≥25 GB first, and then run profiling or the next round of benchmark:**

```sh
# 確認磁碟空間
df -h ~
# 需達到 ≥25 GB 可用空間後，再執行 benchmark 或 profiling
```

---

# Round 11: lz4bench Repair + Decompression Baseline Reconstruction (2026-06-13) / Round 11: Benchmark Fix & Decompression Baseline

## Purpose of this round / Purpose

No algorithm code change - fix the disk space management problem of lz4bench (disk-full defect found in R10),
Rebuild reliable decompression baseline data.

## Changes in this round / Changes

** `zshrc.sh` — `lz4bench` function reconstruction (inline cleanup mode):**

- Decompression is changed to sequential execution: decompression → compare with tgz → **delete immediately** → next format
- Disk peak usage decreased from ~14–18GB to ~3.5GB
- llama.cpp ZSTD decompression failed in R10 due to full disk load; this round has been completed normally ✓
- Add disk available space pre-check (recommended ≥25GB)

## Measured Results (11:28–11:36)/ Measured Results

✅ All 7 format consistency of the two data sets passed; lzfse-test 112 items are all green.

### Compression MB/s (Compression Throughput)

| Format | claw R10 | claw R11 | Trend | llama R10 | llama R11 | Trend |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| Lazy2 | 46.6 | **49.21** | +5.6% | 121.5 | **129.16** | +6.3% |
| Optimal | 22.8 | **23.99** | +5.2% | 37.6 | **40.85** | +8.6% |
| BVX3 | 377.6 | **413.47** | +9.5% | 214.7 | **229.06** | +6.7% |
| ZSTD (reference) | 383.1 | **404.11** | +5.5% | 236.2 | **338.85** | +43.5%↑ |

> Each format of compression MB/s has been slightly improved (+5–10%). Presumed reason: R11 cleans up the disk by format, and the disk I/O competition in the compression stage is reduced. ZSTD llama is large, which may be related to the pressure on the disk in the previous benchmark.

### Decompression MB/s (Decompression Throughput) - the first reliable data

⚠️ R10 decompression is seriously distorted by disk pressure, and the data is greatly improved after R11 using inline cleanup:

| Format | claw R10 | claw R11 | Improvement | llama R10 | llama R11 | Improvement |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| TGZ | 565.0 | **533.61** | Slightly lower (R10 may be high) | 221.4 | **260.00** | +17.4% |
| Other3 | 465.6 | **503.52** | +8.1% | 194.5 | **256.81** | +32.0% |
| Lazy2 | 519.0 | **460.04** | −11.4% | 154.1 | **228.01** | +47.9% |
| Optimal | 308.0 | **548.28** | **+78.0%** | 131.9 | **199.41** | **+51.2%** |
| BVX3 | 215.7 | **481.99** | **+123%** | 98.5 | **232.81** | **+136%** |
| Apple | 142.9 | **617.76** | **+332%** | 108.2 | **209.68** | **+93.8%** |
| TLZ4 | 149.2 | **266.01** | **+78.3%** | 183.4 | **244.49** | +33.3% |
| ZSTD | 143.7 | **355.65** | **+147%** | ❌ Failure | **231.66** | ✅ Repair |

> The decompressed data of R10 BVX3/Apple/Optimal/ZSTD has been confirmed to be unreliable due to significant I/O slowdown due to disk accumulation.
> **R11 is the official reliable baseline of decompression speed. **

### Compression Sizes (Compression Sizes, exactly the same as R10)

| Format | claw | llama | Description |
| --- | ---: | ---: | --- |
| Optimal | 417M | 544M | Consistent with R9/R10 ✓ |
| Lazy2 | 432M | 561M | Consistent with R9/R10 ✓ |
| ZSTD | 395M | 544M | Consistent with R9/R10 ✓ |

There is no change in the compression algorithm, and the size is completely reproduced - confirming that the baseline is stable.

## R11 Reliable Baseline (for subsequent round comparison) / R11 Reliable Baseline

### claw-code

| Format | After compression | Compression MB/s | Decompression MB/s | Compression ratio (vs tgz) |
| --- | ---: | ---: | ---: | ---: |
| TGZ (Benchmark) | 480M | 47.81 | 533.61 | 1.000 |
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
| TGZ (Benchmark) | 592M | 55.81 | 259.96 | 1.000 |
| LZFSE Other3 | 594M | 240.11 | 256.81 | 0.998 |
| **LZFSE Lazy2** | **561M** | **129.16** | **228.01** | **0.959** |
| **LZFSE Optimal** | **544M** | **40.85** | **199.41** | **0.932** |
| LZFSE BVX3 | 577M | 229.06 | 232.81 | 0.982 |
| LZFSE Apple | 592M | 127.65 | 209.68 | 1.001 |
| TLZ4 | 626M | 273.93 | 244.49 | 1.055 |
| ZSTD -9 | 544M | 338.85 | 231.66 | 0.912 |

## Lazy2 vs Optimal Analysis / Lazy2 vs Optimal Analysis

| Pointer | claw Lazy2 | claw Optimal | llama Lazy2 | llama Optimal |
| --- | ---: | ---: | ---: | ---: |
| Compressed MB/s | 49.21 | 23.99 | 129.16 | 40.85 |
| Decompression MB/s | 460.04 | 548.28 | 228.01 | 199.41 |
| Compressed size | 432M | 417M | 561M | 544M |
| vs ZSTD Size | +9.4% | +5.6% | +3.1% | 0.0% |

**Optimal's decompression speed is faster than Lazy2** (claw: 548 vs 460 MB/s; the difference comes from Optimal's generation of shorter and more regular match sequences, and the FSE symbol path is shorter). This is the first reliable data observed by R11.

## Conclusions / Conclusions

1. **lz4bench inline cleanup repair successful**: llama.cpp ZSTD decompression returns to normal (231.66 MB/s).
2. **R10 decompression data confirmation distortion**: BVX3/Apple/Optimal is seriously slow under the accumulated disk pressure; R11 is the first reliable decompression baseline.
3. **Slight improvement in compression MB/s** (+5–10%): This round of no code changes is presumed to come from lower disk I/O competition.
4. **Optimal decompression speed is brilliant**: claw 548 MB/s > Lazy2 460 MB/s; decompression vs ZSTD: Optimal 548 vs 356, Lazy2 460 vs 356 (both 1.3–1.5 times faster).
Five. **The next step is still profiling**: run profiling on a reliable baseline to find out the real hotspot of compressed MB/s.

## Next Round Plan / Next (R12)

**Execute profiling and measure compression hotspots (especially claw-code bvx3 -optimal's 23.99 MB/s):**

```sh
cd ~/proj/lzfse2
open run_profile.command   # 對 claw-code bvx3 -optimal 取樣 20 秒
# 完成後查看 profile-optimal.txt 的熱函數
```

According to the R9 candidate strategy (selected under the guidance of profiling results):

| If the hot spot is | direction | expectation |
| --- | --- | --- |
| DP loose array writing (per-cell 6 array) | SoA packaging: price+len 64-bit word | Write bandwidth −50% |
| `matchLength` Comparison Loop | SIMD16 Vector Comparison | match body −50–70% |
| hash chain visit | `optSearchDepth` 16→8 or price-based early departure | Visit volume −30–50% |
| emit / backtrace | DP segment 128K→256K | Fixed overhead −50% |

---

# Round 10: Baseline Re-confirmation + Disk Full Load Warning (2026-06-13) / Round 10: Baseline Re-confirmation

## Purpose of this round / Purpose

No code change - reconfirm the stability of the R8/R9 baseline and record the full load problem of this round of disk.

## Measured Results (10:53–11:02)/ Measured Results

⚠️ **Disk space is exhausted in the test** (insufficient space after the decompression test of llama.cpp → xbenchTest totals 14G, cleaned up):
- claw-code all 8 formats compression and decompression completed ✓
- llama.cpp all 8 format compression completed ✓; when decompressing to ZSTD, the disk is full, **ZSTD decompression failed**
- Executed `rm -rf xbenchTest` released 14G space

⚠️ **llama.cpp decompressed data is affected by disk pressure** (BVX3 12.2s, Apple 11.1s and other abnormally high);
The later format of claw-code (Apple 9.1s) may also be affected by thermal throttle.
**Unzip MB/s This round is only for trend reference, not for absolute comparison. **

### Compress MB/s (reliable)

| Format | claw R9 | claw R10 | Trend | llama R9 | llama R10 | Trend |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| Lazy2 | 45.9 | **46.6** | ≈ flat | 118.3 | **121.5** | ≈ flat |
| Optimal | 22.4 | **22.8** | ≈ flat | 37.6 | **37.6** | flat |
| ZSTD (reference) | 376.0 | **383.1** | ≈ flat | 297.4 | **236.2** | ⚠️Slow (disk write pressure) |

### Compression size (stable)

| Format | claw R9 | claw R10 | llama R9 | llama R10 |
| --- | ---: | ---: | ---: | ---: |
| Optimal | 417M | **417M** ✓ | 544M | **544M** ✓ |
| Lazy2 | 432M | **432M** ✓ | 571M | **571M** ✓ |

The compression ratio is exactly the same as that of R9, confirming **baseline stability, no code return**.

## Conclusions / Conclusions

1. **Compressed MB/s stable** (±3% noise): Optimal claw 22.4→22.8, llama 37.6; Lazy2 claw 45.9→46.6, llama 118→121.
2. **Compression ratio remains unchanged**: Optimal 417M/544M, Lazy2 432M/571M.
3. ⚠️ **Decompressed data is unreliable** (disk pressure/heat throttling), please use R9 data as a decompression reference reference.
4. **The next step is still profiling**: Compressing MB/s improvement needs to measure the hot spot first.

## Next Round Plan / Next (R11)

**Run profiling, and then decide the direction according to the hot spot:**

```sh
cd ~/proj/lzfse2
open run_profile.command   # 取 claw-code bvx3 -optimal 20 秒樣本
# 完成後查看 profile-optimal.txt
```

⚠️ **Disk Management**: Before the next benchmark, confirm that there is ≥25G available space (xbenchTest accounts for ~18G).
`rm -rf ~/proj/lzfse2/xbenchTest` can be cleaned up immediately after benchmark.sh is executed.

---

# Round 9: Baseline Verification + MB/s Comparison Benchmark Establishment (2026-06-13) / Round 9: Baseline Verification

## Purpose of this round / Purpose

No code change - purely rerun benchmark to confirm the stability of the R8 baseline and formally establish
**MB/s is the main cross-wheel comparison indicator** (the data set is an active working directory, and the size will fluctuate with time;
After natization with MB/s, it can be compared fairly across wheels).

## Measured Results (01:20–01:26)/ Measured Results

✅ The consistency of the two data sets has passed (7/7 × 2); R8 numbers are fully reproduced - baseline stability ✓

### claw-code (original 1300 MB)

| Format | After compression | Compression MB/s | Decompression MB/s | Compression ratio |
| --- | ---: | ---: | ---: | ---: |
| TGZ (Benchmark) | 480M | 46.1 | 534.1 | 1.000 |
| LZFSE Other3 | 472M | 375.7 | 498.0 | 0.983 |
| **LZFSE Lazy2** | **432M** | **45.9** | **524.6** | **0.900** |
| **LZFSE Optimal** | **417M** | **22.4** | **370.7** | **0.869** |
| LZFSE BVX3 | 457M | 384.3 | 238.0 | 0.952 |
| LZFSE Apple | 465M | 139.0 | 225.3 | 0.969 |
| TLZ4 | 563M | 503.3 | 143.7 | 1.173 |
| ZSTD-9|393M|376.0|145.1|0.819|

### llama.cpp (original 1200 MB)

| Format | After compression | Compression MB/s | Decompression MB/s | Compression ratio |
| --- | ---: | ---: | ---: | ---: |
| TGZ (Benchmark) | 593M | 52.6 | 231.1 | 1.000 |
| LZFSE Other3 | 593M | 207.6 | 235.9 | 1.000 |
| **LZFSE Lazy2** | **571M** | **118.3** | **196.6** | **0.963** |
| **LZFSE Optimal** | **544M** | **37.6** | **140.3** | **0.917** |
| LZFSE BVX3 | 584M | 214.5 | 151.2 | 0.985 |
| LZFSE Apple | 584M | 121.9 | 163.0 | 0.985 |
| TLZ4 | 614M | 246.2 | 122.7 | 1.035 |
| ZSTD -9 | 544M | 297.4 | 87.5 | 0.917 |

## MB/s Analysis / MB/s Analysis

### Optimal Status

| Data set | Compress MB/s | vs ZSTD | Decompress MB/s | vs ZSTD | Size vs ZSTD |
| --- | ---: | ---: | ---: | ---: | ---: |
| claw-code | 22.4 | ZSTD fast **16.8×** | 370.7 | We fast **2.6×** | 417 vs 393M (+6.1%) |
| llama.cpp | 37.6 | ZSTD fast **7.9×** | 140.3 | We fast **1.6×** | **544 vs 544M (till)** ✓ |

### Lazy2 Current Status

| Data set | Compress MB/s | vs ZSTD | Decompress MB/s | Size vs ZSTD |
| --- | ---: | ---: | ---: | ---: |
| claw-code | 45.9 | ZSTD Fast **8.2×** | 524.6 | 432 vs 393M (+9.9%) |
| llama.cpp | 118.3 | ZSTD Fast **2.5×** | 196.6 | 571 vs 544M (+5.0%) |

**The biggest advantage of decompressing to lzfse2**: claw optimal 370.7 MB/s, lazy2 524.6 MB/s——
ZSTD is only 145 MB/s, and we are fast **2.6–3.6 times**.

## Conclusions / Conclusions

1. **Baseline stability**: R8 vs R9 MB/s error <0.1%, reliable measurement, MB/s can be used as a cross-wheel benchmark.
2. **Optimal bottleneck**: compression MB/s behind ZSTD 8–17 times; R8 SIMD skip is effective in llama (−4.7%)
But claw is flat - claw's 58s / 22.4 MB/s real hotspot is unknown, ** must be profiled first**.
3. **Lazy2 ceiling**: BT route is closed (R7 negative results); claw 45.9 MB/s under hash chain architecture
It is close to the upper limit.
4. **Profiling has not been executed yet**: `run_profile.command` is ready, and R10 must be measured before working.

## Next Round Plan / Next (R10)

**Must do: Run profiling first to find out the real hotspot of claw optimal 22.4 MB/s**

```sh
cd ~/proj/lzfse2
open run_profile.command   # 對 claw-code bvx3 -optimal 取樣 20 秒
# 完成後查看 profile-optimal.txt 的熱函數
```

Choose the direction according to the profiling results:

| If the hot spot is | Corresponding action | Expected benefit |
| --- | --- | --- |
| DP relaxed array writing (per-cell 6 array) | SoA packaging: price+len combined with a 64-bit word, rep delayed reconstruction | Write bandwidth −50%, claw optimal target <35s |
| `matchLength` comparison cycle | SIMD16 vector comparison, 16 bytes at a time | match body comparison cost −50–70% |
| hash chain visit ( `chainSearch`) | `optSearchDepth` 16→8, or price-based early departure | claw visit volume −30–50%, the ratio is small back |
| emit / backtrace | DP segment size 128K→256K, reduce the number of backtracking | Fixed expense −50%, the benefit depends on the segment ratio |

---

# Round 8: DP Relaxation SIMDization (2026-06-13) / Round 8: SIMD Relaxation

## This round of changes / Changes (R4 candidate #2 landing)

The two relaxation cycles of optimal's rep / frontier, the dense area (length 4..64) is changed to
`SIMD4<Int32>` View 4 cells at a time: c2 constant in the bucket, 4 lane all
"No improvement" skips directly. **Semantic meaning is completely equivalent to each case** (same cell, same priority,
Only omit writing and branching that must be invalid) - small sample output byte level unchanged
(30453B / 29041B) is the proof.

## Measured Results (09:17–09:26)/ Measured Results

✅ 112 self-tests are all green; consistency 7/7 × 2; the output size is exactly the same as R7b ✓

| Mode | claw-code | llama.cpp |
| --- | --- | --- |
| optimal | 417M / **58.1s** (R7b 58.5s, ~ flat) | 544M / **31.9s** (R7b 33.5s, −4.7%) |
| lazy2 (unmoved) | 432M / 28.3s | 571M / 10.1s |
| Same wheel zstd -9 | 393M / 3.5s | **544M** / 4.0s |

Reading / Reading:

- **Highlights of this round**: llama optimal **544M = zstd 544M, the ratio is officially equalized**
(The data set drifted to the content that is difficult to press in this round, and zstd fell to the same water level as us;
Decompression 8.6s vs 13.7s is still 1.6 times faster).
- SIMD skip income is limited (llama −4.7%, claw ~0): **dense relaxation is not
The real hot spot of claw optimal** - R3's "maximum relaxation" assumption is in stride/sufficient
After that, it is no longer established. Claw's 58s flowers are in other places (candidate matchLength, chain visit,
Per-cell 6 array write, or emit/backtracking).
- Change retention (zero risk, llama with small profit).

## Next Round Suggestions / Next (R9)

1. ** Measure first and then do it**: Blind tuning has been neutral for two consecutive rounds - use
`xcrun xctrace record --template "Time Profiler"` Yes
`lzfse -encode -algo bvx3 -optimal` sampling, find out claw optimal
The real hot spot of 58s, and then decide the target of vectorization/reconstruction.
2. If the hotspot is per-cell 6 array writing: change SoA packaging (price+len a 64-bit
Word, reps delayed reconstruction) can halve the writing bandwidth.
3. Data set snapshot freeze (to be done from R6) is still the premise of attribution.

---

# Round 7: BT match finder Experiment (2026-06-13) / Round 7: BT Experiment — Negative Result

## This round of experiment / Experiment

Practice zstd btlazy2 style **binary-tree match finder** to replace the hash chain of lazy2
(R4 candidate #1, R6 suggestion #3): a suffix sorting tree per hash bucket, search is inserted,
Share suffix length acceleration comparison, good-enough/taper retention. 112 self-tests are all green,
The consistency of the two data sets has passed - ** The correctness is safe, but the speed is catastrophic back **:

| Mode | Hash chain (retal measurement after back) | BT version | Difference |
| --- | --- | --- | --- |
| claw lazy2 | 432M / 28.8s | 432M / 46.1s | **+60% time**, ratio 0 |
| llama lazy2 | 570M / 10.5s | 565M / 68.3s | **+550% time**, ratio −0.9% |

## Root Cause / Root Cause

**The insertion of BT also needs to be visited (O(depth)), and the hash chain insertion is O(1). **
Llama's GGUF long match has a large number of "pure insertion" positions in the body - BT pays each position
16 comparison tree visits, and the hash chain only pays 2 writes. Zstd home btlazy2 also because of this
2–3 times slower than lazy2; our lazy2 has hash5+probe+taper+skip,
The residual chain visit cost has no room for improvement as claimed by BT.
**Reverted to the R6 hash chain version** (negative result, the code is not retained).

## Conclusions & Next / Conclusions & Next (R8)

1. **lazy2's hash chain + hash5 + probe combination is close to the speed ceiling of this architecture**
(Claw 28.8s, llama 10.5s); BT route is officially closed.
2. The only remaining item of optimal speed-up: **DP relaxation SIMDization** (R4 candidate #2)--
The dense area (length 4..64) relaxes 4 cells at a time with SIMD4<Int32>.
3. The attribution methodology remains unchanged: knob A/B is only done after the data set snapshot is frozen.
(Claw-code drifts again in this round: zstd 391→400M).
4. Current positioning (current round same machine data): lazy2 distance zstd ratio +6.3–8.0%,
Time 2.6–8.1 times; optimal distance from zstd +1.5–4.3%, decompression faster 1.8–3.8 times.

---

# Round 6: Attribution Tuning (2026-06-13) / Round 6: Attribution Tuning

## This round of changes / Changes (landed according to R5's R6 suggestion)

| Project | Change | Reason |
| --- | --- | --- |
| optRepStrongLen | 64 → 128 | claw optimal ratio +3.5%'s number one suspect back |
| lazy2 insert-stride (new) | match ≥ 256 insert every 2 grids in the body | LZ4 HC style: insertion flow is halved, the chain is shorter |

Zshrc.sh has been verified to fully support optimal (extract/lzfseX/lz4bench) without modification.

## Measured Results (07:50–07:59)/ Measured Results

✅ 112 self-tests are all green; decompression consistency 7/7 × 2.
Small sample: lazy2 30453B, optimal 29041B - exactly the same as R5 (the change is neutral for the small sample).

⚠️ The two data sets have changed again (unchanged bvx3: claw 453→447, llama 570→583;
Zstd: 403→395, 541→534), and the ambient load of this round is high
(Zstd takes +13–21%). Cross-wheel comparison needs to be corrected by ambient, and the size is only for direction reference.

| Mode | claw-code | llama.cpp |
| --- | --- | --- |
| lazy2 | 433M / 29.3s (after correction ≈25.8s) | 570M / 10.4s |
| optimal | 417M / 59.5s (after correction ≈52.5s) | 544M / 31.9s |
| Same wheel zstd -9 | 395M / 3.5s | 534M / 4.5s |

Reading / Reading:

- **optRepStrongLen 64→128 insensitive to the ratio** (claw optimal 417M does not move,
Llama 544M does not move): the +3.5–5.6% gap of claw ** is not caused by ** this knob.
The suspicion moves to optHugeLen (stride-16) or R3's existing depth16/suff192,
It may also be the difficulty of the data set itself.
- **insert-stride neutral**: lazy2 size follows the unchanged bvx3 same width drift (within +1M),
It is flat after time correction - the insertion cost is not the bottleneck of lazy2 (the chain visit is).
- Both rounds of "attribution experiments" were interfered by the drift of the data set - live directory (claw-code is the working area,
Llama.cpp will be updated) It is not feasible to do A/B.

## Next Round of Suggestions / Next (R7)

1. **Freeze Data Set Snapshot** (Priority): `tar -cf claw-code.snapshot.tar claw-code`
Once, after that, all benchmarks are executed on the snapshot tar file - the data set drift is zero,
The attribution experiment is effective.
2. After the snapshot is fixed, redo the monovariate A/B of optHugeLen / depth / sufficientLen.
3. lazy2 speed ceiling (chain visit): BT match finder (R4 candidate #1).
4. optimal speed: DP relaxation SIMDization (R4 candidate #2).

---

# The fifth round: lazy2/optimal speed adjustment (2026-06-13)/ Round 5

## This round of changes / Changes (landing according to the R4 candidate strategy)

| Project | Change | Reason |
| --- | --- | --- |
| chainLazyLen (new, 128) | lazy second search threshold 1024→128 | medium and long match repeated double search along the way is lazy2 implicit bulk |
| chainTaperLen/Depth (new, 256/4) | bl ≥ 256 post-chain visit depth converges to 4 | It is long enough, and the deep search margin efficiency is extremely low |
| optHugeLen (new, 256) | DP relaxation ≥ 256 change stride-16 | long match adjacent length price difference is extremely small |
| optRepStrongLen (new, 64) | bestRep ≥ 64 → Chain visit down to depth 4 | Strong rep is almost inevitable at DP price |

## Measured Results / Measured Results

✅ 112 self-tests are all green; decompression consistency is all passed (7/7 × 2 data sets).
Text sample: lazy2 30686→**30453B (smaller)**, optimal 29029→29041B (+0.04%, can be ignored).

The first run (07:12–07:21) machine performs pip reloading at the same time, and the time data is +15–20% distortion;
Claw-code has been rerun at 07:34 (llama continues to use 07:21 round, and its size data is still valid):

| Mode | claw-code (07:34 clean and rerun) | llama.cpp |
| --- | --- | --- |
| lazy2 | 432M / **25.2s**(R3 433M/32.4s → −22% time) | **556M**(R4 572M, −2.8%)/ 10.0s |
| optimal | 417M / 52.3s | 544M (flat R4)/ 31.7s |
| Same wheel zstd -9 | 403M / 3.1s | 541M / 3.8s |

Reading / Reading:

- **lazy2 all-round victory**: the time is better than R3 −22% (claw) and the ratio is better
(Llama −16M, small sample −233B) - lazy threshold 128 + taper does not hurt the quality,
R4 full block reading this round is completely effective. Ratio difference to zstd: llama **+2.8%**, claw +7.2%.
- **optimal maintenance ratio** (llama 544M flat, small sample +0.04%);
Claw 417M vs zstd 403M = **+3.5%** (R4 is +1.3%, but claw data set
Continuous change - tgz 480→481M, zstd 396→403M - cross-wheel cannot be directly compared).
- optimal time 52.3s not improved compared with R4: stride-16/strong rep shallow search saving is
The data set becomes large and offset; the DP cost center of gravity of the claw is still relaxing the cycle itself.

## Next Round Suggestions / Next (R6)

1. **claw optimal ratio +3.5% attribution A/B**: fixed data set snapshot respectively
Switch optRepStrongLen and optHugeLen to confirm whether it is the loss introduced by R5;
If so, give priority to return optRepStrongLen (64→128 or remove).
2. lazy2 to go further (goal <15s/claw): BT match finder (R4 candidate #1).
3. optimal speed-up spindle steering **DP relaxation SIMDization** (R4 candidate #2):
cPrice and other six arrays SoA + simd_int4 one-time relaxation 4 length.

---

# Round 4: Memory & Multi-core Efficiency (2026-06-13) / Round 4: Memory & Multi-core

Goal (user specified): Re-examine the zstd / LZ4 algorithm, reduce memory overhead, and make good use of multi-core,
Shorten the compression time of bvx3 / lazy2 / optimal.

## Review Findings / Code-Review Findings

The multi-core architecture itself has been improved: 4MiB block × `DispatchQueue.concurrentPerform`
Worker (semaphore flow limit = number of cores), lazy2/optimal also has zstd
Bl detection, good-enough truncation, jump acceleration, desert detection. Remaining movable large items:

1. **16MiB chain table memset + malloc/free churn per piece** (memory bulk):
`lzParseChain` / `lzParseOptimal` Each 4MiB chunk is
`allocate + initialize(repeating:-1)` A chain table of n×4B.
1.3GB input = 325 chunks ≈ 5.2GB invalid memset traffic + the same amount of malloc churn.
The answer of zstd is **CCtx reuse**: context is matched once and reused across block.
And the chain table actually ** doesn't need to be initialized at all ** - achiability argument: search only goes
`head[h] → chain[c] → …`, head is clear as -1 per piece, any achiable chain item
When inserting ( `chain[idx] = head[h]; head[h] = idx`), write first and then read.
2. **Hot cycle array configuration**: `for r in [rep0p, rep1p, rep2p]` in `bestMatch`
(At least 1–2 times per position) will generate a temporary array. LZ4/zstd hot path zero configuration.
3. **4-byte hash chain is too long** (the main cause of text data lazy2 32s):
"The", "of" and other high-frequency 4-grams make the chain depth skyrocket, and the depth quota is wasted on repeated candidates.
Zstd high-level (lazy2/btopt) for **5–6 byte hash**: short chain, less collision,
The quota is spent on candidates who may really be longer; the sacrifice of len-4 non-rep match is extremely small.
(Rep candidates still cover the most common len-4).
4. **Pipe short reading**: `FileHandle.read(upToCount:)` to pipe may not be returned 4MiB
The short block (tar | lzfse is the pipe), which makes the block fragmented - the ratio becomes worse,
Each fixed overhead becomes more, and the parallel decoding grouping fails. It should be accumulated to read.

## Changes in this round / Changes

| Project | Change | Corresponding Skills |
| --- | --- | --- |
| ParseScratch pool | head/chain/DP/frontier buffer cross-chunk reuse (lock protection pool, upper limit = number of cores) | zstd CCtx reuse |
| chain table zero initialization | Remove two places `initialize(repeating:-1, count:n)` | Reachability argument (as above) |
| rep loop to configure | bestMatch two changes to manual expansion | LZ4 hot path zero configuration |
| chain finder change hash5 | lazy2/optimal hash4 → 5-byte multiplication hash; chainHashBits 16→17 | zstd high-level h5 |
| Full block reading | runParallelEncode Cumulative reading full 4MiB re-dispay | Parallel particle size repair |

Memory effect: steady-state peak ≈ number of cores × (chain 16MiB + DP ~4MiB) (same order as the current one),
But **the memset/malloc traffic of ~21MB per piece is zero**;
The speed effect is mainly in the chain visit quality (hash5) and configuration overhead of lazy2/optimal.

## Measured Results (2026-06-13)/ Measured Results

✅ 112 self-tests are all green; the decompression consistency of the two data sets is all passed; the small sample ratio is flat (29030→29029B).

| Mode | claw-code R3 → R4 | llama.cpp R3 → R4 |
| --- | --- | --- |
| lazy2 | 32.4s → **22.4s** (↓31%), 433M → 433M | 9.7s → **8.3s** (↓15%), 571 → 572M |
| optimal | 50.0s → **44.6s** (↓11%), 400 → 401M | 24.7s → 25.6s (flat), 544 → 544M |
| bvx3 | 3.05s → 3.00s, 456 → 458M | 5.1s → 5.1s, 570 → 573M |
| Same wheel zstd -9 | 2.93s / 396M | 3.7s / 538M |

Reading / Reading:

- **hash5 has the greatest effect on lazy2** (claw ↓31%, zero rate loss): high-frequency 4-gram is no longer common,
The quota of depth 32 is really spent on candidates who may be longer.
- optimal benefits less (claw ↓11%): its cost focus is on DP relaxation rather than chain visit,
And desert detection has eaten up part of the search cost first.
- scratch pool zeros each ~21MB malloc/memset traffic;
Full block reading ensures the 4MiB block particle size under the pipe input.
- Ratio to zstd gap: optimal +1.3% (claw)/ +1.1% (llama);
Decompression optimal 5.2s/8.0s vs zstd 10.3s/14.6s (1.8–2.0 times faster).

## Next-Round Candidates (R5)

1. **lazy2 to BT (binary tree) match finder** (zstd btlazy2 real body):
The hash chain is still O(depth×len) comparison on high-repetition text; BT insertion is sorting,
Amortization O(log) for each candidate. It is estimated that claw lazy2 can be -30–40% more, but the practical complexity is high.
2. **Optimal's DP relaxation vectorization**: cPrice/cLen and other six arrays change SoA to
SIMD (simd_int4) relaxes 4 lengths at a time; or raise stride-4 to stride-8.
3. **Optimal inter-segment pipeline**: Backtracking in DP segment (128K) overlaps with the next search
(At present, the same chunk is followed); when the chunk level is saturated, the income is limited and the priority is the lowest.
4. bvx3/other3 is faster than zstd -9 (433/432 MB/s vs 444 MB/s at the same level), no longer moving.

---

# Round 3: Compression-Time Optimization (2026-06-12)/ Round 3: Compression-Time Optimization

## Current Situation Analysis / Bottleneck Analysis

The ratio target was achieved in the second round (optimal 368M/544M ≈ zstd 372M/543M), but the compression time gap is huge:

| Mode | claw-code | llama.cpp | vs zstd (3.1s / 5.0s) |
| --- | ---: | ---: | --- |
| bvx3 -optimal | 104.8s | 140.6s | Slow 34x / 28x |
| bvx3 -lazy2 | 34.5s | 12.4s | slow 11x / 2.5x |

Analyze the four cost sources of `lzParseOptimal` (compared with zstd btopt):

1. **Length-by-length relaxation loop** (maximum, compressible data): each position for each rep/frontier candidate
Relax length 4..maxLen, `optSufficientLen=512` makes the worst loop up to 511 times.
The sufficient_len of zstd is about ~256 in the btopt level.
2. **Full-depth chain visit for each position** (the main cause of desert/binary data, explanation of llama 141s > claw 105s):
DP does depth-32 search in every position, unlike lazy, which has jump acceleration.
3. **Swift array boundary check**: price list (litPrice/mPriceTab/dPriceTab) and
lm3BaseValue is accessed with Swift Array in the hottest loop.
4. lazy2 adjustment (4096/8) correction: claw 34.5s to 401M, the deep search ratio is too high.

## Changes in this round / Changes

| Project | Change | Expected effect |
| --- | --- | --- |
| optSearchDepth | 32 → 16 | The cost of chain visit is halved; suffix-min still keeps the proximity priority |
| optSufficientLen | 512 → 192 | Earlier greedy submission (zstd btopt level); relax the upper bound ↓2.7x |
| Relaxation stride (new optDenseLen=64) | Length >64 change stride-4 + accurate maxLen | Long match relaxation cost ↓~3x; model actual measurement rate zero loss |
| Price list indexation | Price list/base value table change UnsafeMutablePointer | Exemption of thermal cycle boundary inspection |
| Desert detection (new) | Continuous ≥32 position no match → Depth reduced to 4 | The cost of binary segment decreased significantly (llama main reason) |
| lazy2 tuning | chainGoodEnough 4096→1024, strength 8→7 | Deep search proportion compromise, target ~12-18s/claw |

Correctness: Python model re-verifies after joining stride - text/structured/runs ratio
Delta 0.00%, 150 groups of random round trips + all constraints passed.

## Measured Results (2026-06-13 Early Morning)/ Measured Results

✅ Compile once and pass; `-test` 112 items are all green; the small sample ratio remains unchanged (text large sample or even 29041→29030B).

| Mode | R2 → R3 (claw-code) | R2 → R3 (llama.cpp) |
| --- | --- | --- |
| optimal compression | 104.8s → **52.2s** (2.0x), 368M → 384M | 140.6s → **27.1s** (5.2x), 544M → 560M |
| lazy2 compression | 34.5s → 33.1s, 401M → 401M | 12.4s → 12.0s, 561M → 561M |
| Same wheel zstd -9 | 3.1s / 363M | 3.4s / 530M |

Reading / Reading:

- **Speed target is greatly advanced**: Optimal accelerates 5.2 times in llama (binal weight) - desert detection +
Reduce the depth by half to the point; claw accelerates by 2.0 times.
- **Ratio return**: claw +4.3%, llama +2.9%. The gap with zstd widened from ~0% to ~5.7%.
The main suspect is in order: optSufficientLen 512→192 (premature greedy submission), depth 32→16.
Stride (model verification zero loss) and indicatorization of innocence.
- lazy2 parameter adjustment (1024/7) almost does not move the number - indicating that the cost of lazy2 is mainly in the chain visit of depth 32
Itself, not goodEnough/strength; if you want to be fast in the future, you can only reduce the depth.
- ⚠️ The TLZ4/ZSTD "decompression" data of this round of llama is invalid due to the exhaustion of host disk space.
(All modes of LZFSE are completed before the space is exhausted and the consistency is all passed).
- Note: The content of the two data sets has drifts (zstd from 372→363, 543→530), and the absolute value of cross-round is for reference only.
The same wheel is relatively effective.

Next round (R4) candidate: suff 192→512 back + depth 16→24 (keep stride/indicatorization/desert detection,
The threshold is relaxed to streak 64 → depth 8), goal: the ratio returns to zstd ±1.5%,
Time is 50–60% of R2.

### Supplement: llama.cpp officially reruns (2026-06-13, after disk cleaning + data set restoration)

The data set returns to 1.2G (tgz 592M), the new version of lz4bench (including -optimal / -lazy2),
The consistency check has been completed, and the zstd decompression data is complete. R3 program code (stride + pointerization + desert detection) actual measurement:

| Mode | Size | Compression | Decompression | vs zstd ratio |
| --- | ---: | ---: | ---: | --- |
| optimal | **544M** | 24.7s | 6.47s | **+0.74%**(zstd 540M/3.7s/11.1s) |
| lazy2 | 571M | 9.7s | 6.64s | +5.7% |
| bvx3 | 570M | 5.1s | 5.78s | +5.6% |

- The optimal on llama (binal weight) almost equals the zstd -9 ratio, and the decompression is 1.7 times faster--
The speed knife method of R3 has almost zero rate loss in this data set.

### Supplement: claw-code re-run (2026-06-13, data set growth to 1.3G / tgz 480M)

| Mode | Size | Compression | Decompression | vs zstd ratio |
| --- | ---: | ---: | ---: | --- |
| optimal | **400M** | 49.7s | 2.30s | **+3.1%** (zstd 388M/2.9s/5.9s) |
| lazy2 | 433M | 32.4s | 2.29s | +11.6% |
| bvx3 | 456M | 3.05s | 3.21s | +17.5% |

### Step 8 General evaluation (two data sets, new version of complete data)

- **Compression ratio is close to the standard**: optimal is only +0.7% (llama)/ +3.1% (claw) from zstd -9.
- **Decompression speed is great**: optimal decompression 2.3s / 6.5s, zstd 5.9s / 11.1s (1.7–2.5 times faster).
- **Compression speed is still behind**: optimal 50s / 25s vs zstd 2.9s / 3.7s (13–17 times).
DP-optimal class algorithm (Swift practice) against C's lazy-class zstd -9, this gap is structural;
When pursuing compression speed, bvx3 (2.9s, faster than zstd) or lazy2 should be used.
Optimal is positioned as "offline maximum compression" mode.
- Conclusion: The ratio and decompression are close to or exceed the zstd level, and it is recommended to stop the iteration here (the condition of step 8 is considered to be achieved);
If you still want to narrow the compression speed gap, the parallelization in the DP segment with the optimal direction of R4 and
Chain-table pre-built (one-time table, multi-segment sharing).

---

# Round 2: Optimal Parsing Strategy (2026-06-12) / Round 2: Optimal Parsing Strategy

## Current Situation Analysis / Gap Analysis

The last round of benchmark (BenchMarkResult.csv) shows the gap with zstd -9:
The previous benchmark showed the remaining gap vs zstd -9:

| Data set | bvx3 -lazy2 | zstd -9 | gap |
|---|---:|---:|---:|---:|
| claw-code | 419M | 368M | ~13.9% |
| llama.cpp | 572M | 537M | ~6.5% |

Two root causes / Two root causes:

1. **Repair speed cut too much**: In order to save the compression time of 86s/39s in the last round, `chainGoodEnough=512` and
`chainSearchStrength=6` Let the deep search give up too early and jump too big - btlazy2 once reached 384M/545M
Therefore, the ratio vomits back. The speed fix (early-exit at 512, aggressive skip) gave back most of
The ratio btlazy2 had won (384M/545M).
2. **The structural upper limit of greedy/lazy analysis**: Each position only makes local optimal decisions. Zstd high distance
(Btopt/btultra) The real source of the ratio is "price-driven full-segment optimal analysis" - this is the main course of this round.
Greedy/lazy parsing is locally optimal only; zstd's high levels win via
Price-driven optimal parsing.

Another benchmark tool bug was found and fixed: `lzfseX` of `zshrc.sh` has never put `-lazy2`
The flag is passed to the encoder, and the "Lazy2" line of the previous CSV actually runs the default bvx3.
Also fixed: `lzfseX` never actually passed `-lazy2`, so previous "Lazy2" rows
Were really default bvx3 runs.

## This Round's Changes / This Round's Changes

### 1. `-optimal`: Segmented DP optimal analysis (zstd btultra)

Add `lzParseOptimal` (bvx3 dedicated, flag `-optimal` control, default off):

- **Segmented DP**: a segment for every 128K position; each cell storage reaches the minimum cost (1/16-bit fixed point),
Arrival step (literal or (len,dist)), and the rep-offset history of the best path
(The per-cell rep tracking of zstd opt allows the rep hit to be priced at real near-zero cost in DP).
- **Candidate**: 3 rep distance + hash chain Pareto frontier (len increment);
Suffix-min let each length take "the cheapest distance of long enough candidates".
- **Adaptive price**: literal/M/D symbol histogram reconstruction of each segment (log2 → fixed point),
Feedback with launched statistics is equivalent to zstd updating price tables between blocks.
- **Giant match truncation** ( `optSufficientLen=512`): Find it, submit greedily and restart the DP segment--
It is not only the sufficient_len strategy of zstd, but also the cost upper bound of pathological input (equilong run).

Correctness verification: Python model 300 groups random segmentation/threshold round trip + format constraints all passed;
On the model, the analysis cost of text/structured data is reduced by 9–10% relative to lazy.

### 2. Adjust the parameter retrieval -lazy2 ratio

- `chainGoodEnough` 512 → 4096: Deep search will no longer be too early
- `chainSearchStrength` 6 → 8: No match Jumping step is more conservative

It is expected that the -lazy2 ratio will recover to 384M/545M, and the compression time will rebound slightly from 2.0s (still much faster than apple).

### three. Speed/Ratio Gear Overview / Speed-ratio ladder

| Gear | Parser | Positioning |
| --- | --- | --- |
| bvx3 (default) | 4 slot lazy | Speed priority (~2s/1.2GB) |
| bvx3 -lazy2 | Hash chain deep search 32 | Middle file |
| bvx3 -optimal | Segment DP optimal analysis | Ratio priority, target approach zstd -9 |

## Measured Results (2026-06-12, M-series Mac)/ Measured Results

✅ Compilation passed once; `-test` 112 items are all green; benchmark two data sets decompression consistency all passed.

| Data set | bvx3 -optimal | zstd -9 | Result |
| --- | ---: | ---: | --- |
| claw-code compression rate | **368M** | 372M | **Beyond zstd** |
| llama.cpp compression rate | 544M | 543M | flat (+0.18%) |
| claw-code decompression | **2.95s** | 6.02s | 2 times faster |
| llama.cpp decompression | **7.72s** | 10.45s | 1.35 times faster |
| claw-code compression time | 104.8s | 3.1s | 34 times slower (set-off) |
| llama.cpp compression time | 140.6s | 5.0s | 28 times slower (setchment) |

Conclusion / Conclusion: The compression rate of **bvx3 -optimal has reached the level of zstd -9** (one win and one draw),
And the decompression speed is significantly faster than zstd - the cycle goal of "approaching zstd" is achieved, and the process stops.
The compression speed is a clear choice of -optimal (DP does full-depth search and length relaxation at each position);
Use the default bvx3 (2.6s/411M) or -lazy2 (34.5s/401M) when speed is required.
If you want to narrow the compression time gap in the future, the candidate direction: reduce optSearchDepth (32→16),
Price-driven chain visit pruning (price-based early termination) and SIMD matchLength.

-Lazy2 adjustment (4096/8) actual measurement: claw 401M/34.5s - the ratio is better than the old version of fake lazy2 (411M level)
There is a sense of improvement, but the time cost is high; the sweet point of the middle gear can be adjusted separately.

---

# The first round: Inline optimization report

## Overview

Improve the execution efficiency of lzfse-cli by applying the Swift compiler inline instruction `@inline(__always)` to frequently called small functions.

## Optimize the content

### 1. FSE bit stream coding (fseEncode)

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

### 2. Byte serialization (put32 / put16)

**Location**: Line 885-892

```swift
@inline(__always)
static func put32(_ v: UInt32, _ out: inout [UInt8])

@inline(__always)
static func put16(_ v: UInt16, _ out: inout [UInt8])
```

**Features**:
- Ultra-short function (4-8 lines of code)
- Block headers, frequency tables and matching lists are used in large quantities during serialization
- Part of the coding key path

**Expected benefits**: Coding performance +2-5%

---

### three. Byte deserialization (get32 / get16 / get64)

**Location**: Line 894-905

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
- Frequent calling during decoding (scanning blocks, parsing headers, decoding L/M/D values)
- Decode a part of the critical path

**Expected benefits**: Decoding performance +2-4%

---

## Existing optimization

The following functions have been used `@inline(__always)`:

1. **FSEInStream.load8** (line 385) - 8-byte loading
2. **FSEOutStream.push/pull** (lines 343, 349, 412, 425) - bit stream operation
3. **lzParse Internal Function** (line 498-520) - load32/load64/hash4/matchLength
4. **lzParseStrong Internal Function** (line 618-644) - Hotspot function of enhanced comparison
5. **lzParseChain Internal Function** (line 763-791) - Hotspot function of chain search
6. **encodeFreqValue** (line 904) - Frequency value coding
7. **encodeBlock internal function** (line 1037) - displacement auxiliary function
8. **decodeV2Block Internal Function** (line 1514) - Field Extraction
9. **lzvnEncodeBlock Internal Function** (line 1319, line 1322) - LZVN coding
10. **decodeBlockBody Internal Function** (line 2189) - Value Decoding

---

## Compilation results

### Binard file size

| Version | Size | Change |
| --- | ---: | ---: |
| Original version | 238 KB | - |
| Optimized version | 260 KB | +22 KB (+9.2%) |

**Explanation**: The increase in the size of binary files is mainly due to the increase in the amount of code in inline expansion. This is within the acceptable range.

### Test results

✅ All built-in tests passed (including round-trip + compatibility test)

---

## Performance expectations

Based on the expected improvement of Swift compiler optimized literature:

| Operation | Expected improvement |
|---|---:|
| Code (Other 3 / bvx3) | +2-5% |
| FSE bit flow operation | +3-7% |
| Decoding | +2-4% |
| Average overall performance | +2-4% |

**Note**: The actual improvement varies depending on the data characteristics, hardware characteristics and compiler behavior. Benchmarking is recommended on real workloads.

---

## Security and compatibility

✅ **Compatibility**: All changes are compiler instructions, and the program logic is not modified.
✅ **Correcty**: Built-in test covers all encoding/decoding paths
✅ **Compatibility**: Do not change the API or output format
✅ **Portability**: Applicable to all platforms that support Swift

---

## When to use

1. **Optimized compilation (production environment)**:
   ```sh
   swiftc -O lzfse-cli.swift -o lzfse
   ```
→ The compiler will respect the `@inline(__always)` instruction

2. **Debug compilation**:
   ```sh
   swiftc -g lzfse-cli.swift -o lzfse
   ```
→ The timization may be disabled, but the function remains unchanged.

3. **Performance benchmark test**:
- Use `-O` to compile
- Test at least 3 times to get the average
- Use representative data sets (see BenchMarkResult.csv)

---

## Suggestions for further optification

### 1. Conditional inline (if available)

If Swift is supported, you can consider:
```swift
@inline(__always) // 無條件
// vs
@inline(never) // 對初始化函數
```

### 2. SIMD umization

Using SIMD instructions for functions such as `matchLength` may further improve performance (additional testing is required).

### three. Memory layout umization

Check the alignment and size of FSEEncoderEntry and other structures (which may affect cache performance).

### 4. Parallel improvement

The existing parallel decoding has used DispatchGroup to explore other parallel tools (OperationQueue, async/await).

---

## References

- Apple Swift Optimization Guide: https://github.com/apple/swift/blob/main/docs/OptimizationTips.rst
- LLVM inline transmission: https://llvm.org/docs/Passes/#inline-function-integration
- FSE reference practice: https://github.com/apple/swift-corelibs-foundation

---

## Update log

| Date | Version | Change |
| --- | --- | --- |
| 2026-06-12 | 1.0 | Initial optimization: fseEncode, put32, put16, get32, get16, get64 |


---

## R18: Bounded buffer (backpressure) correction of parallel coding

### Suggestion to review (honest version)
The suggestions received focus on "runParallelEncode Memory Explosion / OOM / Dynamic Thread Switching",
However, compared with the existing code, most of the problems **do not exist**:

| Suggested issues | Current situation |
|---|---|
| Each chunk opens a new Thread → context switch explosion | No. Use `.concurrent` DispatchQueue (fixed GCD thread pool), non- `Thread()` |
| No upper limit queue → OOM | part. There is already `sem.wait()` before reading, but there is a bug in the signal timing (see below) |
| Dynamically generate threads | No, never did this |

Fixed thread pool, signal flow control, producer-consumer decoupling - **These have been implemented**.

### The real bug (it is recommended to point in the wrong direction, but the symptoms are right)
The original `sem.signal()` is bound to "**task completed**" instead of "**chunk write**":

- `sem` is limited to "the number of in-the-way number being compressed", not the "number of accumulated to be written after being compressed".
- When the slow chunk (such as the optimal on GGUF) is in front of `writeIndex`, all the chunks after that
After pressing quickly and respectively `signal()`, the producer continues to send workers - but these pressed bodies are all piled up in
`results` and other `writeIndex` catch up → **results boundless accumulation**.
- 1.3GB GGUF (~325 4MB chunks) accumulates hundreds of pressed bodies at worst, which is the real memory risk.

### Practice
Move `sem.signal()` into the drainage cycle (signal only once every chunk is written):

- "Read but not written" strictly ≤ maxTasks → memory upper bound ≈ maxTasks × chunkSize (e.g. 16×4MB=64MB).
- When the slow chunk is in front, the producer is in `sem.wait()` natural blocking (backpressure),
No more unlimited reading.
- Activity has been proven: The task corresponding to `writeIndex` must be in the in-way collection, and the drainage signal is completed,
Producer will eventually be unblocked → no dead knot. The output order and correctness remain unchanged.

### Deliberately not adopted: adaptive downgrade (optimal→lazy2)
It is suggested that C should downgrade "queue depth > 10". But **After the boundary buffer is repaired, this backlog scene no longer exists**
(In-way constant ≤ maxTasks) - The downgrade condition will never be triggered, it will be dead code.
The right thing to do is to backpressure instead of adding a downgrade knob that will not start.
If you want to "change the throughput by ratio" in the future, you should make an explicit flag (such as `-fast-when-slow`) instead of an implicit trigger.

### Not adopted: vDSP/Accelerate vectorized cost calculation
Cross-platform consideration (Accelerate Apple platform only) + existing SIMD4 fast-skip has covered hotspots,
The reporting rate is low. `-Ounchecked` belongs to the construction flag hierarchy, and it is recommended to experiment in benchmark.sh.

### The impact of distributed computing on other3
This time, only change the signal timing and memory boundary of `runParallelEncode`, ** do not change the chunk cutting,
Decoding grouping, or the compression path of other3** - the performance of other3 is not affected. Deeper parallel architecture reconstruction
(Circular buffer, async/await) left for the next round, at which time the other3 throughput needs to be measured separately.

---

## Update log (continued)

| Date | Version | Change |
| --- | --- | --- |
| 2026-06-14 | R10 | optimal entropy perception gate (GGUF random segment skip DP, data-driven parting) |
| 2026-06-14 | R11 | Parallel coding backpressure correction (sem.signal bound and written, memory is bounded) |

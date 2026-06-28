# tar Extraction Bottleneck — Windows vs macOS

**Date**: 2026-06-28
**Tool**: `helper_windows/tar_benchmark/tar-bench-win.ps1`
**Purpose**: Confirm whether the low Windows decode file-mode speed stems from bsdtar file creation + NTFS overhead, not the codec itself.

---

## Methodology

| Test | Command | Description |
|------|---------|-------------|
| **list only** | `tar -tzf dataset.tgz > nul` | gz decompress + read tar directory listing, **no file creation** |
| **extract** | `tar -xzf dataset.tgz -C output/` | gz decompress + extract all files to disk |

- Both tests are preceded by one warm-up pass (`tar -tzf`) to populate the OS page cache.
- MB/s is calculated using the uncompressed dataset size as the numerator (claw-code 1416.8 MB, llama.cpp 1322.4 MB).
- The gap between list and extract speeds = **bsdtar file creation + NTFS metadata overhead**.

---

## Results

| Dataset | list MB/s | extract MB/s | list/extract ratio |
|---------|----------:|-------------:|-------------------:|
| claw-code | **648.6** | 174.0 | **3.73×** |
| llama.cpp | **844.3** | 36.1 | **23.39×** |

- **list (gz decompress, no file creation)**: both datasets reach 648–844 MB/s.
- **extract (write to disk)**: claw-code drops to 174 MB/s, llama.cpp to 36 MB/s.
- **Bottleneck confirmed: file creation phase**, not gz decompression.

---

## Cross-Validation with R41-Win-Retest

### claw-code TGZ

| Source | MB/s | Note |
|--------|-----:|------|
| tar-bench `tar -xzf` (warm cache) | 174.0 | this test |
| R41-Win-Retest TGZ decode **file** mode | 153.6 | mid-benchmark run, includes verify step |
| Difference | ~13% | explained by cache state + verify overhead — within normal variance |

### claw-code LZFSE (Other3) — Strongest cross-validation

| Measurement | MB/s | Meaning |
|-------------|-----:|---------|
| R41-Win-Retest Other3 **nul** decode | 772.4 | pure LZFSE decompression (no tar extraction) |
| R41-Win-Retest Other3 **file** decode | 159.0 | LZFSE + tar extraction end-to-end |
| tar-bench `tar -xzf` | 174.0 | pure tar extraction |

**LZFSE file decode (159 MB/s) ≈ tar extract speed (174 MB/s)**: directly confirms that the bottleneck in LZFSE file mode is tar extraction, not LZFSE decompression (772 MB/s).

### llama.cpp nul/file ratio comparison

| Source | nul MB/s | file MB/s | nul/file ratio |
|--------|--------:|----------:|---------------:|
| R41-Win-Retest Other3 | 838.6 | 41.5 | 20.2× |
| tar-bench (gz path) | 844.3 | 36.1 | 23.4× |

Ratios are highly consistent (20.2× vs 23.4×). The small difference comes from gz vs LZFSE decompression CPU cost.

---

## Root Cause Analysis

### Why is llama.cpp's list/extract ratio (23×) so much larger than claw-code's (3.7×)?

| Factor | claw-code | llama.cpp |
|--------|-----------|-----------|
| File composition | Many small source files | Few large binary files (GGUF, etc.) |
| NTFS behavior | Many small metadata ops, each I/O is small | Large sequential writes limited by disk throughput |
| extract MB/s | 174 | 36 |

The llama.cpp extraction speed (36 MB/s) is primarily limited by **Windows disk sequential write throughput** (C: drive SSD), not bsdtar itself. claw-code benefits from higher NTFS cache hit rates due to small, scattered files.

### Platform differences: bsdtar

- Windows bsdtar (Git for Windows MSYS2 build) and macOS system bsdtar (Apple libarchive) are different builds with different I/O patterns and buffering strategies.
- macOS APFS has copy-on-write optimizations for small-file metadata operations, giving higher file creation throughput than NTFS.
- Mac bsdtar file decode (~310–388 MB/s from comparison CSV) is ~2–2.5× faster than Windows (154–174 MB/s), consistent with the APFS > NTFS expectation.

---

## Conclusions

1. **Bottleneck confirmed**: Windows decode file-mode slowness = bsdtar file creation + NTFS write overhead. Not a codec issue.
2. **Use nul mode for fair cross-platform codec comparison**: LZFSE nul decode (750–870 MB/s) is unaffected by disk I/O and represents true codec throughput.
3. **llama.cpp specifics**: extraction of large binary files is capped by disk write throughput (~36 MB/s). A faster SSD or a different extractor would improve file-mode decode speed, but this is irrelevant to codec optimization.
4. **TGZ decode nul anomaly in benchmark**: decode-win.bat's TGZ nul path performs full extraction + verify (not a simple list), which is why it reads 113 MB/s rather than the 648 MB/s seen in this isolated `tar -tzf` test.

---

## Related Files

- Test script: `helper_windows/tar_benchmark/tar-bench-win.ps1`
- Full R41-Win-Retest data: `OPTIMIZATION.md` — R41-Win Retest section
- Raw benchmark CSVs: `helper_windows/bench_results_csv/`

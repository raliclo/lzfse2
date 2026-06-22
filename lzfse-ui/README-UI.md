# LZFSE UI

A macOS SwiftUI app providing a graphical interface for the LZFSE compression engine.  
Mirrors the behaviour of `lzfseX` and `extract()` from `zshrc.sh`.

---

## Features

| Feature | Description |
|---------|-------------|
| **Compress files** | Single file → `.lzfse` with Apple / Other3 / BVX3 algorithm |
| **Compress folders** | Entire directory → `<folder>.lzfse.algo` via `tar \| lzfse` (lzfseX convention) |
| **Decompress archives** | `.lzfse.other3 / .lzfse.bvx3 / .lzfse.apple` → extracted via `lzfse \| tar -xf -` (extract() convention) |
| **Decompress files** | Plain `.lzfse` → decoded file placed in chosen folder |
| **Auto-detect mode** | File suffix determines whether tar pipeline is used — no manual toggle |
| **Algorithm selection** | Apple / Other3 / BVX3 (+ Lazy2 / Optimal flags for BVX3) |
| **Parallel tasks** | Configurable 1–32 (default 8) |
| **Status panel** | Always visible beside controls; shows sizes, ratio, elapsed time |
| **Bilingual UI** | English + Traditional Chinese throughout |

---

## Build

```bash
cd lzfse-ui
./build-ui.sh        # creates lzfse-ui/LZFSE UI.app
open "LZFSE UI.app"
```

Or manually:
```bash
swiftc -O ../lzfse-cli.swift lzfse-ui.swift \
    -framework SwiftUI -target arm64-apple-macos13.0
```

See `BUILD-INSTRUCTIONS.md` for Xcode setup.

**Requirements**: macOS 13.0+, Apple Silicon (arm64)

---

## Usage

### Compress a file
1. Operation → **Compress**
2. Choose algorithm (Other3 recommended for general use)
3. **Select File/Folder** → pick any file
4. Output path auto-suggested in same directory (e.g. `data.txt.lzfse`)
5. Optionally click **Save As…** to change output location
6. Click **Compress**

### Compress a folder (lzfseX)
1. Operation → **Compress**
2. **Select File/Folder** → pick a **folder**
3. Output auto-named `<folder>.lzfse.<algo>` (e.g. `mydata.lzfse.other3`)
   - Output path updates live when you change algorithm
4. Click **Compress**
   - Runs: `tar -cf - -C <parent> <folder> | lzfse encode`

### Decompress a lzfseX archive
1. Operation → **Decompress**
2. **Select .lzfse** → pick e.g. `mydata.lzfse.bvx3`
   - Options panel shows: *"lzfseX archive detected"*
   - Output auto-suggested: same directory as archive
3. **Select Extract Dir** → choose where to extract
4. Click **Decompress**
   - Runs: `lzfse decode | tar -xf - -C <dir>`
   - Original folder structure restored

### Decompress a plain `.lzfse` file
1. Operation → **Decompress**
2. **Select .lzfse** → pick e.g. `file.txt.lzfse`
3. **Select Folder** → choose output directory
4. Click **Decompress**
   - Decoded file placed inside chosen folder

---

## Algorithms

| Algorithm | Extension | Encode speed | Ratio | Decode compatibility |
|-----------|-----------|-------------|-------|---------------------|
| Apple | `.lzfse.apple` | Fast | Good | Apple Compression.framework |
| Other3 | `.lzfse.other3` | Medium | Better | Standard bvx2; Apple-compatible |
| BVX3 | `.lzfse.bvx3` | Slower | Best | This tool only |
| BVX3 + Lazy2 | `.lzfse.bvx3.lazy2` | Slow | Better | This tool only |
| BVX3 + Optimal | `.lzfse.bvx3.optimal` | Slowest | Maximum | This tool only |

---

## File Extensions (lzfseX convention)

| Suffix | Created by | Extracted by |
|--------|-----------|--------------|
| `.lzfse` | single-file encode | single-file decode |
| `.lzfse.apple` | `lzfseX … apple` | `extract()` → tar pipeline |
| `.lzfse.other3` | `lzfseX … other3` | `extract()` → tar pipeline |
| `.lzfse.bvx3` | `lzfseX … bvx3` | `extract()` → tar pipeline |
| `.lzfse.bvx3.lazy2` | `lzfseX … lazy2` | `extract()` → tar pipeline |
| `.lzfse.bvx3.optimal` | `lzfseX … optimal` | `extract()` → tar pipeline |

---

## Performance Tips

- **Parallel Tasks**: default 8 is balanced. Increase for large files (16–32), decrease for low RAM (2–4).
- **Avoid compressing** already-compressed formats (JPEG, MP4, ZIP, zstd).
- **Memory estimate**: `chunk size (1 MB) × 2 × parallel tasks` ≈ 16 MB at default settings.

---

## Troubleshooting

| Symptom | Solution |
|---------|---------|
| Can't select `.lzfse.apple` in file picker | Fixed — no content-type filter applied |
| Decode failed | File may be corrupt; verify source |
| Out of memory | Reduce Parallel Tasks |
| App crashes | Check both Swift files are in build target |

---

## License

BSD-3-Clause (derived from Apple LZFSE reference implementation)

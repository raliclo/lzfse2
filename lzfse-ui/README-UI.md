# LZFSE UI

A macOS SwiftUI app providing a graphical interface for the LZFSE compression engine.  
Mirrors the behaviour of `lzfseX` and `extract()` from `lz4bench.zsh` (both
functions used to live in `zshrc.zsh` and were moved to the project-root
`lz4bench.zsh`).

---

## Features

| Feature | Description |
|---------|-------------|
| **Compress files** | Single file → `.lzfse` with Apple / Other3 / BVX3 algorithm |
| **Compress folders** | Entire directory → `<folder>.lzfse` via `tar \| lzfse`; equivalent command still shows selected algorithm flags |
| **Decompress archives** | `.lzfse`, `.lzfse.apple`, `.lzfse.other3`, `.lzfse.other3.optimal3`, `.lzfse.bvx3*` suffixes are treated as lzfseX archives and extracted via `lzfse \| tar -xf -` |
| **Decompress files** | Use a non-lzfseX suffix only when you need direct single-file decode |
| **Auto-detect mode** | File suffix determines whether tar pipeline is used — no manual toggle |
| **Algorithm selection** | Apple / Other3 / BVX3 (+ Optimal3 for Other3, Lazy2 / Optimal for BVX3) |
| **Parallel tasks** | Configurable 1–`processorCount × 10` (default 8) |
| **Status panel** | Always visible beside controls; shows sizes, ratio, elapsed time |
| **Bilingual UI** | English + Traditional Chinese throughout |

---

## Build

```bash
cd lzfse-ui
./build-ui.zsh        # creates lzfse-ui/LZFSE_UI.app
open "LZFSE_UI.app"
```

`build-ui.zsh` also generates the macOS app icon from `AppIcon.png`, writes `AppIcon.icns`, copies it into the bundle resources, and sets `CFBundleIconFile` to `AppIcon`.

Or manually (strip the trailing `runCLI()` call from `lzfse-cli.swift` first —
it is a top-level statement and clashes with the UI's `@main`):
```bash
grep -v '^runCLI()$' ../lzfse-cli.swift > /tmp/lzfse-cli-lib.swift
swiftc -O /tmp/lzfse-cli-lib.swift lzfse-ui.swift \
    -framework SwiftUI -target arm64-apple-macos13.0
```

For manual bundles, copy `AppIcon.icns` into `LZFSE_UI.app/Contents/Resources/` and set `CFBundleIconFile=AppIcon`.

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
3. Output auto-named `<folder>.lzfse`
   - Algorithm and BVX3 parser flags change the command/bitstream, but the current UI output suffix remains `.lzfse`
4. Click **Compress**
   - Runs: `tar -cf - -C <parent> <folder> | lzfse encode`

### Decompress a lzfseX archive
1. Operation → **Decompress**
2. **Select .lzfse** → pick e.g. `mydata.lzfse` or `mydata.lzfse.bvx3`
   - Options panel shows: *"lzfseX archive detected"*
   - Output auto-suggested: same directory as archive
3. **Select Extract Dir** → choose where to extract
4. Click **Decompress**
   - Runs: `lzfse decode | tar -xf - -C <dir>`
   - Original folder structure restored

### Direct single-file decode
1. Operation → **Decompress**
2. Select an input whose suffix is not recognized by `isLzfseXArchive()`
3. **Select Folder** → choose output directory
4. Click **Decompress**
   - Decoded file placed inside chosen folder

Note: in the current implementation, `.lzfse` itself is included in the lzfseX suffix list, so normal `.lzfse` selections route to `lzfse | tar -xf -`. Use the CLI for direct decode of ordinary single-file `.lzfse` payloads if needed.

---

## Algorithms

| Algorithm | Current UI save suffix | Encode speed | Ratio | Decode compatibility |
|-----------|------------------------|-------------|-------|---------------------|
| Apple | `.lzfse` | Fast | Good | Apple Compression.framework for standard streams |
| Other3 | `.lzfse` | Medium | Better | Standard bvx2; Apple-compatible |
| Other3 + Optimal3 | `.lzfse` | Slow | Better than Other3 | Standard bvx2; Apple-compatible; parser flag only affects encode |
| BVX3 | `.lzfse` | Slower | Best | This tool only |
| BVX3 + Lazy2 | `.lzfse` | Slow | Better | This tool only; parser flag only affects encode |
| BVX3 + Optimal | `.lzfse` | Slowest | Maximum | This tool only; parser flag only affects encode |

---

## File Extensions (lzfseX convention)

| Suffix | Created by | Extracted by |
|--------|-----------|--------------|
| `.lzfse` | current UI default for file/folder encode | lzfseX tar extraction path in current UI suffix detection |
| `.lzfse.apple` | `lzfseX … apple` | `extract()` → tar pipeline |
| `.lzfse.other3` | `lzfseX … other3` | `extract()` → tar pipeline |
| `.lzfse.other3.optimal3` | `lzfseX -algo other3 -optimal3` | `extract()` → tar pipeline |
| `.lzfse.bvx3` | `lzfseX … bvx3` | `extract()` → tar pipeline |
| `.lzfse.bvx3.lazy2` | `lzfseX … lazy2` | `extract()` → tar pipeline |
| `.lzfse.bvx3.optimal` | `lzfseX … optimal` | `extract()` → tar pipeline |

---

## Performance Tips

- **Parallel Tasks**: default 8 is balanced. Increase for large files, decrease for low RAM (2–4). The UI clamps the value to `1...processorCount × 10`.
- **Optimal3**: available when encoding with Other3. It improves ratio while keeping the output in the standard Apple-compatible LZFSE format.
- **Avoid compressing** already-compressed formats (JPEG, MP4, ZIP, zstd).
- **Memory**: the status panel reports peak physical footprint for each operation. Actual memory depends on algorithm, parser mode, tar piping, decode fallback, and `n`.

---

## Troubleshooting

| Symptom | Solution |
|---------|---------|
| Can't select `.lzfse.apple` in file picker | Fixed — no content-type filter applied |
| Decode failed | File may be corrupt; verify source |
| Out of memory | Reduce Parallel Tasks |
| App icon does not appear | Rebuild with `./build-ui.zsh`; verify `Contents/Resources/AppIcon.icns` exists |
| App crashes | Check both Swift files are in build target |

---

## License

BSD-3-Clause (derived from Apple LZFSE reference implementation)

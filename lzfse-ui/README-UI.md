# LZFSE UI

A macOS SwiftUI app providing a graphical interface for the LZFSE compression engine.  
Mirrors the behaviour of `lzfseX` and `extract()` from `lz4bench.zsh` (both
functions used to live in `zshrc.zsh` and were moved to the project-root
`lz4bench.zsh`).

The compression engine itself is the project-root `lzfse-cli.swift`; the UI is a
front end over it, not a reimplementation. A Windows counterpart built on
SwiftCrossUI lives in `lzfse-ui-win.swift` — see `README-UI-Win.md`.

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
| **Status panel** | Always visible beside controls; shows sizes, ratio, peak RSS, elapsed time |
| **Equivalent command** | Shows the exact `lzfse` CLI invocation for the current settings, with a Copy button |
| **Native file pickers** | `NSOpenPanel` / `NSSavePanel`; no content-type filter, so compound suffixes are selectable |
| **Auto-suggested paths** | Output path proposed from the input path and current options |
| **Bilingual UI** | English + Traditional Chinese throughout |

**Requirements**: macOS 13.0+, Apple Silicon (arm64). The build script targets
`arm64-apple-macos13.0`.

---

## Build

See **`BUILD-INSTRUCTIONS.md`** — it is the single source for build procedures
(build script, manual `swiftc`, and Xcode project setup), plus build-error
troubleshooting.

Shortest path:

```bash
cd lzfse-ui
./build-ui.zsh        # creates lzfse-ui/LZFSE_UI.app
open "LZFSE_UI.app"
```

For the Windows GUI, see `README-UI-Win.md` (`build-win.zsh` →
`LZFSE_UI_Win.exe`; requires Windows App SDK 1.5 including the DDLM package).

---

## Window Layout

```
┌──────────────────────────────────────────────────────────┐
│  LZFSE Compression Tool / 位元相容 LZFSE 壓縮工具         │
├────────────────────────────┬─────────────────────────────┤
│  Operation / 操作           │  Status / 狀態              │
│   [ Compress | Decompress ] │   ✓ Success! / 成功！        │
│                             │   Input size:  1.5 MB       │
│  Compression Algorithm      │   Output size: 456 KB       │
│   ○ Apple (Standard)        │   Compression ratio: 30.40% │
│   ● Other3 (Enhanced)       │   Peak RSS:  …              │
│   ○ BVX3 (Maximum)          │   Time elapsed: … seconds   │
│   ☐ Optimal3   (Other3)     │   Output: /path/to/file     │
│   ☐ Lazy2      (BVX3)       │                             │
│   ☐ Optimal    (BVX3)       │                             │
│   Parallel Tasks (n): [ 8 ] │                             │
├────────────────────────────┴─────────────────────────────┤
│  Files / 檔案            [ Reset ]  [ Compress / 壓縮 ]   │
│   Input File:   <path>              [ Select File/Folder ]│
│   Output File:  <path>              [ Save As… ]          │
├──────────────────────────────────────────────────────────┤
│  Equivalent Command / 等效指令              [ Copy / 複製 ]│
│   /opt/homebrew/bin/lzfse -encode -algo other3 …          │
└──────────────────────────────────────────────────────────┘
```

The Reset and Compress/Decompress buttons sit in the Files header row rather
than in a separate footer, which keeps the required window height down. The
algorithm block (including the Optimal3 / Lazy2 / Optimal toggles) is disabled
while Operation is Decompress — the archive's own bitstream decides how it is
decoded. Parallel Tasks stays enabled for both operations.

See `UI-DESIGN.md` for the component-level architecture.

---

## Usage

### Compress a file

1. Operation → **Compress**
2. Choose algorithm (Other3 recommended for general use)
3. **Select File/Folder** → pick any file
4. Output path auto-suggested in same directory (e.g. `data.txt.lzfse`)
5. Optionally click **Save As…** to change output location
6. Click **Compress**
7. Read the status panel for input size, output size, ratio, peak RSS and elapsed time

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

Note: in the current implementation, `.lzfse` itself is included in the lzfseX
suffix list, so normal `.lzfse` selections route to `lzfse | tar -xf -`. Use the
CLI for direct decode of ordinary single-file `.lzfse` payloads if needed.

### Equivalent command

The bottom panel always shows the CLI invocation matching the current settings,
and **Copy / 複製** puts it on the clipboard. Four shapes are produced:

```bash
# file encode
lzfse -encode -algo other3 -i "<input>" -o "<output>" -n 8

# folder encode
tar -cf - -C "<parent>" "<folder>" \
  | lzfse -encode -algo other3 -si -o "<output>" -n 8

# lzfseX archive decode
lzfse -decode -i "<input>" -n 8 -so | tar -xf - -C "<extract dir>"

# direct single-file decode
lzfse -decode -i "<input>" -o "<output>" -n 8
```

The panel prints the full `/opt/homebrew/bin/lzfse` path. Use it to script a
run you first dialled in through the UI.

---

## Algorithms

| Algorithm | Current UI save suffix | Encode speed | Ratio | Decode compatibility | Use when |
|-----------|------------------------|--------------|-------|----------------------|----------|
| Apple | `.lzfse` | Fastest | Good | Apple Compression.framework for standard streams | Compatibility and speed matter most |
| Other3 | `.lzfse` | Medium | Better | Standard bvx2; Apple-compatible | General-purpose default |
| Other3 + Optimal3 | `.lzfse` | Slow | Better than Other3 | Standard bvx2; Apple-compatible; parser flag only affects encode | Best standard-format ratio |
| BVX3 | `.lzfse` | Slow | Best | This tool only | Maximum compression, private format acceptable |
| BVX3 + Lazy2 | `.lzfse` | Slower | Better than BVX3 | This tool only; parser flag only affects encode | Size matters more than time |
| BVX3 + Optimal | `.lzfse` | Slowest | Maximum | This tool only; parser flag only affects encode | Absolute smallest output |

**Standard** output can be decompressed by Apple tools and by this app.
**BVX3** output is a private bitstream — only this tool (and `lzfse-cli.swift`)
can read it. Do not use BVX3 for files you intend to hand to someone else
unless they have this tool.

The parser flags (`Optimal3`, `Lazy2`, `Optimal`) change how the encoder
searches for matches. They affect encode time and ratio only; they are not
recorded as a separate format, and decoding never needs to know which was used.
Optimal overrides Lazy2 — enabling Optimal disables the Lazy2 toggle, and the
encode call passes `lazy2` only when Optimal is off.

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
| any other suffix | — | direct single-file decode path |

The UI uses the suffix — not the file contents — to decide whether to run the
tar extraction pipeline. On decode it also strips the recognized suffix to
propose an output name.

---

## Settings Reference

### Parallel Tasks (n)

- **Range**: `1...processorCount * 10`, clamped on every edit (`lzfse-ui.swift:410`)
- **Default**: 8
- **Effect**: controls in-flight chunk parallelism, and therefore both throughput and peak memory
- **Enabled** for both Compress and Decompress
- **Starting points**: small files 2–4; large files 8–16; limited RAM 2–4

The field accepts any number; values outside the range snap back to the nearest
bound rather than erroring. The upper bound is derived from
`ProcessInfo.processInfo.processorCount`, so it differs per machine — the label
next to the field shows the actual maximum.

### Optimal3 (Other3 only)

- **Shown**: only when Operation is Compress and Algorithm is Other3
- **Effect**: price-driven DP parsing, better ratio, slower encode
- **Output format**: standard Apple-compatible LZFSE — this is the reason to
  prefer it over BVX3 when the result has to stay portable
- **CLI equivalent**: `-algo other3 -optimal3`

### Lazy2 Mode (BVX3 only)

- **Shown**: only when Operation is Compress and Algorithm is BVX3
- **Effect**: deep hash-chain search — better compression, slower encode
- **Disabled** while Optimal is on
- **CLI equivalent**: `-algo bvx3 -lazy2`

### Optimal Parsing (BVX3 only)

- **Shown**: only when Operation is Compress and Algorithm is BVX3
- **Effect**: DP parsing for the best ratio this tool produces, slowest encode
- **Overrides Lazy2**
- **CLI equivalent**: `-algo bvx3 -optimal`

The app stores no preferences — every setting resets to its default on launch,
and uninstalling is just deleting `LZFSE_UI.app`.

---

## Performance Tips

- **Parallel Tasks**: default 8 is balanced. Increase for large files, decrease
  for low RAM (2–4). The UI clamps the value to `1...processorCount × 10`.
- **Optimal3**: available when encoding with Other3. It improves ratio while
  keeping the output in the standard Apple-compatible LZFSE format — usually a
  better trade than switching to BVX3.
- **Avoid compressing** already-compressed formats (JPEG, PNG, MP4, ZIP, zstd).
  The output is typically no smaller than the input, and the time is wasted.
- **Memory**: the status panel reports peak physical footprint for each
  operation. Actual memory depends on algorithm, parser mode, tar piping,
  decode fallback, and `n`. Measure with the value in the status panel rather
  than estimating.
- **Test with a small file first** when trying a new algorithm/flag combination,
  and verify the decompressed result before deleting any original.

Suggested starting configurations:

| Goal | Algorithm | Options | n |
|------|-----------|---------|---|
| Fastest encode | Apple | none | around CPU core count |
| Best standard-format ratio | Other3 | Optimal3 | 8–16 |
| Maximum compression | BVX3 | Optimal | 8–16 |
| Low memory | any | none | 2–4 |

---

## Typical Compression Ratios

Indicative only — ratio is output ÷ input, so lower is better. Actual results
depend on the data, the algorithm and the parser flags; the status panel
reports the real figure for each run.

| File type | Typical ratio | Example |
|-----------|---------------|---------|
| Text | 20–30% | 1 MB → ~250 KB |
| Log files | 10–20% | 1 MB → ~150 KB |
| Source code | 25–35% | 1 MB → ~300 KB |
| JSON / XML | 15–25% | 1 MB → ~200 KB |
| Executables | 40–60% | 1 MB → ~500 KB |
| Already compressed (ZIP, zstd) | 95–100% | little or no gain |
| Images (JPEG / PNG) | 98–100% | no benefit |
| Video | 98–100% | no benefit |

---

## Status Messages

The status panel is always visible beside the controls.

**While running**

```
Compressing... / 壓縮中...
Decompressing... / 解壓縮中...
```

**On success (compress)**

```
✓ Success! / 成功！

Input size / 輸入大小: …
Output size / 輸出大小: …
Compression ratio / 壓縮率: 30.40%
Peak RSS / 峰值記憶體: …
Time elapsed / 耗時: 1.23 seconds
Output / 輸出: /path/to/output
```

Decompression reports archive size instead of the input/output/ratio triple,
then the same peak RSS, elapsed time and output path. Peak RSS is sampled every
5 ms during the operation and reported as the increase over the pre-run
baseline, so it reflects this operation rather than total app memory.

**On failure**

```
Error / 錯誤: <message>
```

The message is the underlying error's description — commonly a decode failure
(corrupt or non-LZFSE input), a write failure (disk space or permissions), or a
missing input file.

---

## Troubleshooting

| Symptom | Solution |
|---------|----------|
| Can't select `.lzfse.apple` in file picker | Fixed — no content-type filter applied |
| Decode failed | Input may be corrupt or not LZFSE; verify the source, and confirm a BVX3 archive is being opened with this tool |
| Out of memory | Reduce Parallel Tasks, close other apps |
| Compression is very slow | Turn off Optimal / Optimal3 / Lazy2, or switch to Apple; reduce `n` |
| Can't find the output | The status panel prints the full output path on success |
| Compress button greyed out | Both input and output must be selected (`canProcess`) |
| Algorithm controls greyed out | Operation is set to Decompress — the archive determines its own decode path |
| App icon does not appear | Rebuild with `./build-ui.zsh`; verify `Contents/Resources/AppIcon.icns` exists |
| App won't open (unidentified developer) | Right-click → Open, or allow it in System Settings → Privacy & Security |
| App crashes on launch | Check both Swift files are in the build target; run from Xcode and read the console |

Build-time errors (`Cannot find type 'LZFSEv1'`, `expressions are not allowed at
the top level`, signing problems) are covered in `BUILD-INSTRUCTIONS.md`.

---

## Privacy

- All processing is local — the app performs no network I/O.
- No telemetry, no cloud, no update checks.
- It reads and writes only the paths you select through the pickers.
- No preferences or cache files are created.

---

## Known Limitations

- One file or folder at a time; there is no batch queue. Use the CLI in a shell
  loop for bulk work.
- No drag and drop; input is chosen through the pickers.
- No custom keyboard shortcuts are defined. Standard macOS window/app shortcuts
  such as `⌘W` and `⌘Q` still come from the system.
- All encodes save as `.lzfse` regardless of algorithm, so the suffix does not
  record which algorithm produced the file.
- Settings are not persisted between launches.

---

## Documentation Index

| Document | Purpose |
|----------|---------|
| `README-UI.md` | This file — features, usage, algorithms, settings, troubleshooting |
| `BUILD-INSTRUCTIONS.md` | Build procedures (script, manual `swiftc`, Xcode) and build errors |
| `UI-DESIGN.md` | UI architecture, components, workflows, design principles |
| `README-UI-Win.md` | Windows GUI (`lzfse-ui-win.swift` / `build-win.zsh`) and its runtime requirements |

Source files:

| File | Lines | Role |
|------|-------|------|
| `../lzfse-cli.swift` | 4246 | Compression engine and CLI; compiled into every build with its trailing `runCLI()` stripped |
| `lzfse-ui.swift` | 999 | macOS SwiftUI app |
| `lzfse-ui-win.swift` | 1136 | Windows SwiftCrossUI app |

---

## License

BSD-3-Clause (derived from Apple LZFSE reference implementation)

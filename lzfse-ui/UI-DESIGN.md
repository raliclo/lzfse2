# LZFSE UI Design Overview

## Application Layout

```
┌──────────────────────────────────────────────────────────────────────────┐
│  [doc.zipper] LZFSE Compression Tool                                     │
│               位元相容 LZFSE 壓縮工具                                      │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  ┌────────────────────────────┐  ┌────────────────────────────────────┐  │
│  │ Operation / 操作            │  │ ℹ Status / 狀態              [Clear]│  │
│  │ [Compress] [Decompress]    │  │                                    │  │
│  ├────────────────────────────┤  │ Output will appear here /          │  │
│  │ Algorithm / 壓縮演算法       │  │ 輸出結果顯示於此                    │  │
│  │ ○ Apple (Standard)        │  │                                    │  │
│  │ ○ Other3 (Enhanced)       │  │ (After run: shows size, ratio,     │  │
│  │ ● BVX3 (Maximum)          │  │  elapsed time, output path)        │  │
│  │ ℹ 最高壓縮率，自訂格式        │  │                                    │  │
│  └────────────────────────────┘  └────────────────────────────────────┘  │
│                                                                           │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │ Files / 檔案                                                         │  │
│  │                                                                     │  │
│  │ Input File or Folder / 輸入檔案或資料夾:                              │  │
│  │ ┌─────────────────────────────────────────────────────────────┐    │  │
│  │ │ 📁 mydata  (or filename.txt)                 [Clear] [Select]│    │  │
│  │ │ /Users/name/Documents/mydata                               │    │  │
│  │ └─────────────────────────────────────────────────────────────┘    │  │
│  │                                                                     │  │
│  │ Output File / 壓縮輸出檔: (encode) or Output Folder / 輸出資料夾:    │  │
│  │ ┌─────────────────────────────────────────────────────────────┐    │  │
│  │ │ mydata.lzfse                           [Clear] [Save As…]   │    │  │
│  │ │ /Users/name/Documents/mydata.lzfse                         │    │  │
│  │ └─────────────────────────────────────────────────────────────┘    │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  [Reset / 重置]                           [Compress / 壓縮 ▶]            │
└──────────────────────────────────────────────────────────────────────────┘
```

Minimum window size: **800 × 650 pt**

---

## UI Components

### 1. Header
**Purpose**: App identity  
**Elements**: `doc.zipper` SF Symbol (blue gradient), bilingual title  
**Bundle icon**: the macOS app icon is provided by `AppIcon.png` / `AppIcon.icns` and referenced from `Info.plist` via `CFBundleIconFile=AppIcon`; it is not drawn by `headerView`.
**Code**: `headerView`

---

### 2. Operation Section (top-left)
**Purpose**: Select compress or decompress mode  
**Elements**: Segmented control — Compress / Decompress  
**Behavior**:
- Switching mode clears `outputPath` (avoids stale paths)
- Changes labels on file section and action button
- Disables Algorithm section when Decompress is selected

**Code**: `operationSection`

---

### 3. Algorithm Section (top-left, below Operation)
**Purpose**: Choose compression algorithm (encode only)  
**Elements**: Radio group — Apple / Other3 / BVX3  
**Behavior**:
- Entire section disabled during Decompress
- Contextual description updates per selection
- BVX3 shows orange warning ("Only this tool can decompress")
- When a folder input is active, changing algorithm auto-updates the suggested output path (lzfseX extension convention)

| Algorithm | Output format | Compatibility |
|-----------|--------------|---------------|
| Apple     | `.lzfse` from current UI save name | Apple Compression.framework |
| Other3    | `.lzfse` from current UI save name | Standard bvx2 — Apple-compatible |
| BVX3      | `.lzfse` from current UI save name | Custom large-alphabet blocks; this tool only |

**Code**: `algorithmSection`

---

### 4. Status Panel (top-right, always visible)
**Purpose**: Show compression results or errors at all times  
**Elements**:
- GroupBox always present beside operation/algorithm
- Placeholder: "Output will appear here / 輸出結果顯示於此" when empty
- Monospaced scrollable text when content exists
- Text selection enabled (copy-paste)
- Clear button appears only when content exists
- Icon: `info.circle` (blue) or `exclamationmark.triangle` (orange on error)

**Content on success**:
```
✓ Success! / 成功！

Input size / 輸入大小: 1.5 MB
Output size / 輸出大小: 312 KB
Compression ratio / 壓縮率: 20.80%
Time elapsed / 耗時: 0.43 seconds
Output / 輸出: /Users/name/mydata.lzfse
```

**Code**: `statusView`

---

### 5. Parallel Tasks and BVX3 Flags (inside Algorithm Section)
**Purpose**: Fine-tune performance and BVX3 parser behaviour  
**Elements**:

| Control | Condition | Description |
|---------|-----------|-------------|
| Parallel Tasks text field (1–`processorCount × 10`, default 8) | Always | Controls pipeline depth and memory usage |
| Lazy2 Mode toggle | BVX3 encode only | Deep hash-chain search; better ratio, slower |
| Optimal Parsing toggle | BVX3 encode only | DP-based best ratio; slowest; disables Lazy2 |

**Code**: `algorithmSection`

---

### 6. File Selection Section (full width)
**Purpose**: Select input file/folder and output destination  

#### Input row
| Mode | Picker | Filter | Folder icon |
|------|--------|--------|-------------|
| Encode | `NSOpenPanel`, files + **folders** | none | shown if directory |
| Decode | `NSOpenPanel`, files only | none (compound suffixes like `.lzfse.apple` require no filter) | — |

Auto-suggests output path on input selection:

| Input | Encode output suggestion | Decode output suggestion |
|-------|--------------------------|--------------------------|
| Single file | `<file>.lzfse` (same dir) | parent dir + stripped name only if suffix is not recognized as lzfseX |
| Folder | `<folder>.lzfse` in the current UI implementation | — |
| `.lzfse.algo` archive | — | parent dir (tar extracts there) |

#### Output row
| Mode | Picker | Path stored |
|------|--------|-------------|
| Encode | `NSSavePanel` | full file path |
| Decode — lzfseX archive | `NSOpenPanel` (directories only) | chosen folder (tar extraction root) |
| Decode — non-lzfseX suffix | `NSOpenPanel` (directories only) | chosen folder + auto-name |

Labels and button text update contextually:

| Mode | Input label | Output label | Output button |
|------|-------------|--------------|---------------|
| Encode (file) | Input File / 輸入檔案 | Output File / 壓縮輸出檔 | Save As… |
| Encode (folder) | Input Folder / 輸入資料夾 | Output File / 壓縮輸出檔 | Save As… |
| Decode (lzfseX) | LZFSE Input File / 壓縮輸入檔 | Extract to Folder / 解壓縮目標資料夾 | Select Extract Dir |
| Decode (plain) | LZFSE Input File / 壓縮輸入檔 | Output Folder / 輸出資料夾 | Select Folder |

**Code**: `fileSelectionSection`

---

### 7. Progress View (full width, conditional)
**Purpose**: Visible only while processing  
**Elements**: Spinner + bilingual status text  
**Code**: `progressView`

---

### 8. Action Buttons (full width)
**Elements**:
- **Reset** (left): clears all selections; disabled while processing
- **Compress / Decompress** (right, prominent): disabled until both input and output are set or while processing

**Code**: action buttons are inline in `fileSelectionSection`

---

## Decompression Logic (extract() convention)

All decompression follows `extract()` in `zshrc.sh`:

```
*.lzfse.bvx3.optimal  →  lzfse | tar -xf - -C <dir>
*.lzfse.bvx3.lazy2    →  lzfse | tar -xf - -C <dir>
*.lzfse.bvx3          →  lzfse | tar -xf - -C <dir>
*.lzfse.other3        →  lzfse | tar -xf - -C <dir>
*.lzfse.apple         →  lzfse | tar -xf - -C <dir>
*.lzfse               →  current UI treats this as lzfseX archive → lzfse | tar -xf - -C <dir>
```

Detection is automatic from the file suffix (`isLzfseXArchive()`). No manual toggle required.

---

## Folder Compression (lzfseX convention)

Mirrors `lzfseX` in `zshrc.sh`:

```bash
tar -cf - -C <parent> <folder> | lzfse -encode -si -o <output>
```

Output naming follows the lzfseX extension convention:

| Algorithm + flags | Output extension |
|-------------------|-----------------|
| Apple | `.lzfse` |
| Other3 | `.lzfse` |
| BVX3 | `.lzfse` |
| BVX3 + Lazy2 | `.lzfse` |
| BVX3 + Optimal | `.lzfse` |

The output path updates when the input folder is selected or when algorithm/flags change, but the current `lzfseExtension()` implementation returns `.lzfse` for every algorithm.

---

## User Workflows

### Compress a File
```
1. Launch app (default: Compress, Other3)
2. Click "Select File/Folder" → pick any file
3. Output path auto-suggested (same dir, + .lzfse)
4. Optionally: change algorithm / parallel tasks / BVX3 flags
5. Optionally: click "Save As…" to change output location
6. Click "Compress"
7. Status panel shows: size, ratio, elapsed, output path
```

### Compress a Folder (lzfseX)
```
1. Click "Select File/Folder" → pick a folder
   → folder icon appears; output auto-named <folder>.lzfse
2. Optionally: change algorithm → output path updates instantly
3. Click "Save As…" to confirm / move output location
4. Click "Compress"
   → runs: tar -cf - -C <parent> <folder> | lzfse encode
```

### Decompress a lzfseX Archive
```
1. Switch to "Decompress"
2. Click "Select .lzfse" → pick e.g. mydata.lzfse or mydata.lzfse.other3
   → Options shows: "lzfseX archive detected"
   → Output auto-suggested: parent dir of archive
3. Click "Select Extract Dir" to choose extraction folder
4. Click "Decompress"
   → runs: lzfse decode | tar -xf - -C <extractDir>
   → original folder structure restored
```

### Direct Single-File Decode
```
1. Switch to "Decompress"
2. Select an input whose suffix is not recognized by isLzfseXArchive()
3. Output auto-suggested: same dir, stripped filename where applicable
4. Click "Select Folder" to choose output directory
5. Click "Decompress"
   → single-file decode; result placed in chosen folder
```

Current note: `.lzfse` is included in `isLzfseXArchive()`, so a normal `.lzfse` selection routes through `lzfse | tar -xf -` rather than the direct single-file decode branch.

---

## Technical Implementation

### Layout
```
ContentView (VStack)
├── headerView
├── Divider
└── ScrollView
    └── VStack
        ├── HStack [top row]
        │   ├── VStack (minWidth 280, maxWidth 360)
        │   │   ├── operationSection
        │   │   └── algorithmSection
        │   └── statusView (maxWidth .infinity)
        ├── fileSelectionSection
        ├── progressView (conditional)
        └── action buttons inside fileSelectionSection
```

### State Management (LZFSEViewModel @MainActor)
| Property | Type | Purpose |
|----------|------|---------|
| `operation` | `LZFSEOperation` | encode / decode; `didSet` clears `outputPath` |
| `algorithm` | `LZFSEAlgorithm` | apple / other3 / bvx3; `didSet` updates dir output path |
| `parallelTasks` | `Int` | 1–`processorCount × 10` (default 8) |
| `useLazy2` | `Bool` | BVX3 flag; `didSet` updates dir output path |
| `useOptimal` | `Bool` | BVX3 flag; `didSet` updates dir output path |
| `inputFilePath` | `String?` | nil = no selection |
| `outputPath` | `String?` | file path (encode / plain decode) or dir path (lzfseX decode) |
| `inputIsDirectory` | computed `Bool` | FileManager check |
| `inputIsLzfseXArchive` | computed `Bool` | suffix check → drives decode routing |

### Processing Routes
```
performOperation()
├── encode + isDirectory  → performFolderEncode()   [tar | lzfse]
├── decode + isLzfseX     → performFolderDecode()   [lzfse | tar -xf -]
└── otherwise             → performFileOperation()  [single file]
```

### Async Model
- `Task.detached(priority: .userInitiated)` for all heavy I/O
- `@MainActor` keeps UI updates on main thread
- `DispatchSemaphore` bounds in-flight chunks for `runParallelEncode`
- `Process` + `Pipe` bridges Swift encode/decode to `tar`

### Shared Code with CLI
| Symbol | Source | Used by |
|--------|--------|---------|
| `runParallelEncode()` | `lzfse-cli.swift` | UI folder encode + file encode |
| `LZFSEv1.decodeStreamFromFile()` | `lzfse-cli.swift` | UI decode |
| `LZFSEv1.decodeStreamToHandle()` | `lzfse-cli.swift` | UI decode fallback |
| `LZFSEError` | `lzfse-cli.swift` | UI error propagation |

---

## File Structure

```
lzfse2/
├── lzfse-cli.swift          # CLI tool + shared engine (LZFSEv1, runParallelEncode, LZFSEError)
└── lzfse-ui/
    ├── lzfse-ui.swift       # SwiftUI app (this file)
    ├── build-ui.sh          # Build script (uses ../lzfse-cli.swift)
    ├── AppIcon.png          # Source app icon image
    ├── AppIcon.icns         # Generated macOS app icon
    ├── AppIconGenerator.swift # Legacy/preview-only icon generator reference
    ├── Info.plist
    └── *.md                 # Documentation
```

### Build
```bash
cd lzfse-ui
./build-ui.sh
# or manually:
swiftc -O ../lzfse-cli.swift lzfse-ui.swift \
    -framework SwiftUI \
    -target arm64-apple-macos13.0 \
    -o "LZFSE_UI.app/Contents/MacOS/LZFSE UI"
```

`build-ui.sh` regenerates `AppIcon.icns` from `AppIcon.png`, places it under `LZFSE_UI.app/Contents/Resources/`, and writes `CFBundleIconFile=AppIcon` into the generated bundle `Info.plist`.

---

## Window & Visual

| Property | Value |
|----------|-------|
| Minimum size | 800 × 650 pt |
| Resizable | Yes |
| Full screen | Supported |
| Appearance | Auto light / dark mode |
| Language | English + Traditional Chinese (bilingual labels throughout) |
| Bundle icon | `AppIcon.icns` generated from `AppIcon.png` |

---

## Design Principles

| Principle | Implementation |
|-----------|---------------|
| **Clarity** | Bilingual labels, contextual help text, visual hierarchy |
| **Feedback** | Status panel always visible; progress spinner during processing |
| **Convention** | Matches `lzfseX` / `extract()` from `zshrc.sh` exactly |
| **Safety** | Action button disabled until both paths set; Reset always available |
| **Efficiency** | Auto-suggest paths; equivalent command updates live with algorithm and BVX3 flags |

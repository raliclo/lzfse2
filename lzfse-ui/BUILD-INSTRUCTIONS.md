# Building LZFSE UI

## File Structure

```
lzfse2/
├── lzfse-cli.swift     ← shared engine (must be included in every build)
└── lzfse-ui/
    ├── lzfse-ui.swift  ← SwiftUI app entry point
    ├── build-ui.sh     ← automated build script
    ├── AppIcon.png     ← source icon image
    ├── AppIcon.icns    ← generated macOS bundle icon
    └── Info.plist      ← app bundle metadata
```

`lzfse-cli.swift` lives one level up and is referenced as `../lzfse-cli.swift` from the `lzfse-ui/` directory.

---

## Option 1: Build Script (Simplest)

```bash
cd lzfse-ui
chmod +x build-ui.sh
./build-ui.sh
open "LZFSE_UI.app"
```

The script:
- Resolves `SCRIPT_DIR` and `PROJECT_ROOT` automatically (works from any working directory)
- Generates `AppIcon.icns` from `AppIcon.png` and copies it into `Contents/Resources`
- Compiles `../lzfse-cli.swift` + `lzfse-ui.swift` together
- Creates a complete `.app` bundle with `Info.plist`, `PkgInfo`, and `CFBundleIconFile=AppIcon`
- Uses a local `.swift-module-cache/` so Swift does not try to write module cache files under the user home directory
- Outputs `lzfse-ui/LZFSE_UI.app`

---

## Option 2: Manual `swiftc`

```bash
cd lzfse-ui
swiftc -O \
    ../lzfse-cli.swift \
    lzfse-ui.swift \
    -o "LZFSE_UI.app/Contents/MacOS/LZFSE UI" \
    -framework SwiftUI \
    -target arm64-apple-macos13.0
```

> Note: `-framework UniformTypeIdentifiers` is **not** needed (removed in current version).

For a fully equivalent manual bundle, also copy `AppIcon.icns` into `LZFSE_UI.app/Contents/Resources/` and set `CFBundleIconFile` to `AppIcon` in the app bundle's `Info.plist`.

---

## Option 3: Xcode Project

1. **Create new macOS App project** in Xcode (SwiftUI / Swift)
2. **Add files** — drag both into the Xcode target:
   - `lzfse-ui/lzfse-ui.swift`
   - `lzfse-cli.swift` (from project root)
   - `lzfse-ui/AppIcon.png` or `lzfse-ui/AppIcon.icns` as an app resource
3. **Delete** the default `ContentView.swift` Xcode generates
4. Set **Deployment Target → macOS 13.0**
5. Set the target icon in the asset catalog, or keep `CFBundleIconFile=AppIcon` when using `AppIcon.icns`
6. Press **⌘R**

See `XCODE-SETUP.md` for full details.

---

## How `lzfse-cli.swift` Works as a Library

The CLI's main entry point is wrapped in `runCLI()` (not called automatically):

```swift
func runCLI() {
    let args = CommandLine.arguments
    // ... argument parsing, encode/decode, file handles ...
}
// Not called — SwiftUI app's @main is the entry point instead
```

Shared symbols used by the UI:

| Symbol | Purpose |
|--------|---------|
| `runParallelEncode()` | Multi-core parallel encoder; now `throws` (safe to call from UI) |
| `LZFSEv1.decodeStreamFromFile()` | Streaming decoder |
| `LZFSEv1.decodeStreamToHandle()` | Whole-buffer decoder fallback |
| `LZFSEError` | Shared error type (`encodeFailed`, `decodeFailed`, `unsupported`) |

---

## Troubleshooting

| Error | Fix |
|-------|-----|
| `Cannot find type 'LZFSEv1'` | Ensure `lzfse-cli.swift` is in the compile command / Xcode target |
| `expressions are not allowed at the top level` | A stray `runCLI()` call at module level — remove it |
| `main actor-isolated ... cannot be called from outside` | Add `nonisolated` to the method |
| `plugin for module 'PreviewsMacros' not found` | Remove `#Preview { }` blocks (they require Xcode toolchain) |
| `Cannot find 'FilterOperation'` | Add `#if canImport(Compression) import Compression #endif` to the file that uses it |
| App shows a default icon | Confirm `AppIcon.icns` exists in `Contents/Resources` and `CFBundleIconFile` is `AppIcon` |

---

## Testing the Build

1. Launch `LZFSE_UI.app`
2. **Compress a folder**: Select a folder → choose BVX3 → verify output is `<folder>.lzfse` in the current UI naming.
3. **Extract**: Switch to Decompress → select the `.lzfse` file → choose extraction folder → verify original content restored.
4. **Compress a file**: Select any file → compress → verify size in status panel
5. **Direct single-file decode**: use an input suffix not recognized by `isLzfseXArchive()`, or use the CLI for ordinary single-file `.lzfse` payloads.

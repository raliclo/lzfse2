# Building LZFSE UI

The single build guide for the LZFSE graphical front end. Three procedures are
documented, in order of how much they ask of you:

1. [Build script (macOS)](#1-build-script-macos) — `./build-ui.zsh`, the simplest path
2. [Xcode (macOS)](#2-xcode-macos) — for debugging, profiling and distribution builds
3. [Windows](#3-windows) — see `README-UI-Win.md`

For what the app does and how to use it, see `README-UI.md`. For the interface
design, see `UI-DESIGN.md`.

---

## File Structure

```
lzfse2/
├── lzfse-cli.swift          ← shared engine (must be included in every build)
└── lzfse-ui/
    ├── lzfse-ui.swift       ← macOS SwiftUI app: @main, ContentView, view model
    ├── lzfse-ui-win.swift   ← Windows SwiftCrossUI app
    ├── build-ui.zsh         ← macOS build script
    ├── build-win.zsh        ← Windows build script
    ├── AppIcon.png          ← source icon image
    ├── AppIcon.icns         ← generated macOS bundle icon
    └── Info.plist           ← app bundle metadata
```

`lzfse-cli.swift` lives one level up and is referenced as `../lzfse-cli.swift`
from the `lzfse-ui/` directory.

---

## Read This First: the trailing `runCLI()` call

`lzfse-cli.swift` ends with a bare, top-level call:

```swift
func runCLI() {
    let args = CommandLine.arguments
    // ... argument parsing, encode/decode, file handles ...
}

runCLI()   // ← last line of the file
```

That call is what keeps `lzfse-cli.swift` a runnable CLI on its own. It is also
a top-level statement, and Swift allows top-level statements in exactly one file
per module — a slot already taken by the UI's `@main`. Compile the file as it
sits on disk next to `lzfse-ui.swift` and the build fails with
`expressions are not allowed at the top level`.

Both build scripts remove that one line before compiling:

- `build-ui.zsh:62` — `grep -v "^runCLI()$" "${PROJECT_ROOT}/lzfse-cli.swift" > "$TEMP_CLI"`
- `build-win.zsh:98` — `grep -v '^runCLI()$' "${PROJECT_ROOT}/lzfse-cli.swift" > "${TARGET_DIR}/lzfse-cli.swift"`

> **Warning — the strip is a literal, anchored line match.**
> `grep -v '^runCLI()$'` deletes the line only when it reads exactly `runCLI()`,
> alone on its line, with nothing before or after it. Indent it, append a
> trailing comment, or wrap it in `#if` and the pattern stops matching: the call
> survives into the UI build and the build breaks. Nothing warns you at edit
> time — `lzfse-cli.swift` still compiles and still runs perfectly as a CLI, and
> the failure surfaces later, in a build that never touched that file. If you
> edit the end of `lzfse-cli.swift`, leave that line spelled exactly as it is.

The rule for every procedure below: **strip the call, then compile.** Any raw
`swiftc` line that hands `lzfse-cli.swift` straight to the compiler alongside
the UI is wrong, however convincing it looks.

Building the CLI alone needs none of this — the trailing call is what makes it
work:

```bash
swiftc -O lzfse-cli.swift -o lzfse
./lzfse -h
```

---

## 1. Build Script (macOS)

```bash
cd lzfse-ui
chmod +x build-ui.zsh
./build-ui.zsh
open "LZFSE_UI.app"
```

The script:

- Resolves `SCRIPT_DIR` and `PROJECT_ROOT` from `$0`, so it works from any
  working directory
- Generates `AppIcon.icns` from `AppIcon.png` with `sips` and copies it into
  `Contents/Resources` (if `AppIcon.png` is missing it warns and falls back to
  the default macOS icon)
- Strips the trailing `runCLI()` call from `../lzfse-cli.swift` into a temp copy
  under `/tmp`, removed by an `EXIT` trap, then compiles that copy together with
  `lzfse-ui.swift`
- Writes `Info.plist` with `CFBundleExecutable` and `CFBundleName` of
  `LZFSE_UI`, `CFBundleIconFile=AppIcon`, and `LSMinimumSystemVersion` 13.0,
  plus a `PkgInfo`
- Uses a local `.swift-module-cache/` via `-module-cache-path`, so Swift does
  not write module cache files under the user home directory
- Outputs `lzfse-ui/LZFSE_UI.app`

To install: `cp -r LZFSE_UI.app /Applications/`

### Without the script: manual `swiftc`

Same two inputs, same flags, done by hand. Note the `grep` on the first line —
see [the warning above](#read-this-first-the-trailing-runcli-call).

```bash
cd lzfse-ui
grep -v '^runCLI()$' ../lzfse-cli.swift > /tmp/lzfse-cli-lib.swift
swiftc -O \
    /tmp/lzfse-cli-lib.swift \
    lzfse-ui.swift \
    -o "LZFSE_UI.app/Contents/MacOS/LZFSE_UI" \
    -framework SwiftUI \
    -target arm64-apple-macos13.0
```

- The output filename must match `CFBundleExecutable` in the bundle's
  `Info.plist`, which `build-ui.zsh` writes as `LZFSE_UI`.
- `build-ui.zsh` hardcodes `-target arm64-apple-macos13.0`. On an Intel Mac,
  change the target triple accordingly.
- For a bundle equivalent to the script's, also copy `AppIcon.icns` into
  `LZFSE_UI.app/Contents/Resources/` and set `CFBundleIconFile` to `AppIcon`.
- To run the binary directly instead of as a bundle, drop the `-o` path and use
  `-o LZFSE-UI`, then `./LZFSE-UI`.

> **Note:** `-framework UniformTypeIdentifiers` is **not** needed and should not
> be re-added. `lzfse-ui.swift` imports only `SwiftUI` and, behind
> `#if canImport(Compression)`, `Compression`.

---

## 2. Xcode (macOS)

Use Xcode when you want breakpoints, Instruments, or a signed and notarized
build. The procedure mirrors what `build-ui.zsh` compiles: `lzfse-ui.swift`
verbatim, plus a `runCLI()`-free copy of `lzfse-cli.swift`.

### Create the project

1. **File → New → Project** (⌘⇧N)
2. Platform **macOS**, template **App**, **Next**
3. Configure:
   - **Product Name**: `LZFSE UI`
   - **Interface**: SwiftUI
   - **Language**: Swift
   - **Storage**: None
   - **Organization Identifier**: your own reverse-DNS prefix
4. Choose a location and **Create**

### Add the sources

1. Right-click the "LZFSE UI" group → **Add Files to "LZFSE UI"…**
2. Add `lzfse-cli.swift` (from the project root) with **Copy items if needed**
   checked
3. In the copy Xcode just made, **delete the last line — the bare `runCLI()`
   call**. Xcode compiles files as-is and has no equivalent of the script's
   `grep`, so this is the manual strip. Do it in the copy inside the Xcode
   project, never in the checked-in `lzfse-cli.swift`
4. Add `lzfse-ui/lzfse-ui.swift` the same way
5. Add `lzfse-ui/AppIcon.icns` (or `AppIcon.png`) as an app resource

### Remove the template's files

`lzfse-ui.swift` already declares both `@main struct LZFSEApp` and
`struct ContentView`. The macOS App template generates its own of each, so both
generated files must go or you get a duplicate `@main` and a redeclared
`ContentView`:

1. Delete `LZFSE_UIApp.swift` (or whatever `<ProductName>App.swift` Xcode named it)
2. Delete `ContentView.swift`

Move to Trash, not just "Remove Reference" — a file left on disk but out of the
target is fine, but a stale reference is not.

### Configure and run

1. Select the **LZFSE UI** target (not the project) → **General**
   - **Deployment Target**: macOS 13.0
   - **App Category**: Utilities
2. **Signing & Capabilities** → select your team, or check **Sign to Run
   Locally**
3. For the icon, either point `Assets.xcassets` → **AppIcon** at `AppIcon.png`,
   or add `AppIcon.icns` to target resources and set `CFBundleIconFile` to
   `AppIcon` in `Info.plist`
4. Select **My Mac** as the destination and press **⌘R**

Optional, under **Build Settings**: release **Optimization Level** `-O` with
**Compilation Mode** *Whole Module* matches the `-O` the build script uses.

### Distribution

1. Destination **Any Mac**, then **Product → Archive**
2. In Organizer, **Distribute App**
   - **Copy App** — unsigned local sharing
   - **Developer ID** with notarization — public distribution, requires an Apple
     Developer Program membership

### Optional: a unit test target

The CLI carries its own tests; a small Xcode test target is still useful for the
view model's defaults.

1. **File → New → Target** → **Unit Testing Bundle**, named `LZFSE UI Tests`
2. Add a test file:

```swift
import Testing
@testable import LZFSE_UI

@Suite("LZFSE Compression Tests")
@MainActor
struct CompressionTests {

    @Test("Default compression settings")
    func testCompressionSettings() {
        let viewModel = LZFSEViewModel()
        #expect(viewModel.operation == .encode)
        #expect(viewModel.algorithm == .other3)
        #expect(viewModel.parallelTasks == 8)
    }

    @Test("canProcess needs both paths")
    func testFileValidation() {
        let viewModel = LZFSEViewModel()
        #expect(viewModel.canProcess == false)

        viewModel.inputFilePath = "/tmp/test.txt"
        #expect(viewModel.canProcess == false)

        viewModel.outputPath = "/tmp/test.txt.lzfse"
        #expect(viewModel.canProcess == true)
    }
}
```

`LZFSEViewModel` is annotated `@MainActor`, so the suite must be too — without
it, constructing the view model from a test is an actor-isolation error. The
module name in `@testable import` is the target's product name with spaces
replaced by underscores.

---

## 3. Windows

The Windows GUI is a separate source file (`lzfse-ui-win.swift`, SwiftCrossUI /
WinUIBackend) built by `build-win.zsh`:

```bash
cd lzfse-ui
./build-win.zsh
```

It shares the same engine and the same `runCLI()` strip (`build-win.zsh:98`),
but its toolchain and runtime requirements are entirely its own — a Swift for
Windows toolchain, Visual Studio Build Tools with the C++ workload and a Windows
SDK, and at runtime the **Windows App Runtime 1.5 including the DDLM package**,
whose absence crashes the app at launch.

**See `README-UI-Win.md`** for the toolchain setup, the runtime and DDLM
requirements, and Windows-specific troubleshooting. That document is the
authority for the Windows build; nothing here duplicates it.

---

## How `lzfse-cli.swift` Works as a Library

Once the trailing `runCLI()` call is stripped, everything left in the file is a
declaration, and the UI links against it directly.

| Symbol | Purpose |
|--------|---------|
| `runParallelEncode()` | Multi-core parallel encoder; `throws`, safe to call from the UI |
| `LZFSEv1.decodeStreamFromFile()` | Streaming decoder |
| `LZFSEv1.decodeStreamToHandle()` | Whole-buffer decoder fallback |
| `LZFSEError` | Shared error type (`encodeFailed`, `decodeFailed`, `unsupported`) |

`lzfse-ui.swift` needs no modification of any kind — it is used as-is by all
three procedures.

---

## Troubleshooting

| Error | Cause and fix |
|-------|---------------|
| `expressions are not allowed at the top level` | The trailing `runCLI()` call reached the compiler. Build through `build-ui.zsh` / `build-win.zsh`, or strip the line from your copy. If you used a script and still see this, check that the line in `lzfse-cli.swift` is still exactly `runCLI()` — an added indent or trailing comment defeats `grep -v '^runCLI()$'` |
| `statements are not allowed at the top level` | Same cause as above |
| `'main' attribute can only apply to one type` | Xcode's generated `<ProductName>App.swift` is still in the target alongside `lzfse-ui.swift`'s `@main`. Delete the generated file |
| `invalid redeclaration of 'ContentView'` | Xcode's generated `ContentView.swift` is still in the target. Delete it — `lzfse-ui.swift` supplies its own |
| `Cannot find type 'LZFSEv1' in scope` | `lzfse-cli.swift` is not being compiled. In a `swiftc` line, add the stripped copy; in Xcode, select the file and check **Target Membership** in the File Inspector |
| `Cannot find 'runParallelEncode' in scope` | Same cause: the file is absent from the target, or it failed to compile for a reason reported earlier in the log |
| `Cannot find 'FilterOperation'` | Add `#if canImport(Compression) import Compression #endif` to the file that uses it |
| `main actor-isolated ... cannot be called from outside` | Add `nonisolated` to the method, as `processWithAppleCompression` does |
| `plugin for module 'PreviewsMacros' not found` | `#Preview { }` blocks need the Xcode toolchain and cannot be compiled by a bare `swiftc`. Remove them, or build in Xcode |
| `Minimum deployment target not met` | Set the deployment target to macOS 13.0 (target → General), or fix the `-target` triple on the `swiftc` line |
| `Signing for 'LZFSE UI' requires a development team` | Target → Signing & Capabilities → select a team, or check **Sign to Run Locally** |
| Missing framework at link time | Only `-framework SwiftUI` is required. `UniformTypeIdentifiers` is not used |
| Builds, then crashes at launch | Check the debug area (⌘⇧Y). Usually a second `@main` or a resource path that does not exist |
| App shows the default icon | Confirm `AppIcon.icns` is in `Contents/Resources` and `CFBundleIconFile` is `AppIcon` |
| Windows: exit 132 / SIGILL at launch | Windows App Runtime 1.5 DDLM package missing. See `README-UI-Win.md` |

---

## Testing the Build

1. Launch `LZFSE_UI.app`
2. **Compress a folder**: select a folder → choose BVX3 → verify the output is
   `<folder>.lzfse` under the current UI naming
3. **Extract**: switch to Decompress → select the `.lzfse` file → choose an
   extraction folder → verify the original content is restored
4. **Compress a file**: select any file → compress → verify the size reported in
   the status panel
5. **Direct single-file decode**: use an input suffix that
   `isLzfseXArchive()` does not recognise, or use the CLI for ordinary
   single-file `.lzfse` payloads

# ✅ FIXED - Build Error Resolved

## Problem Solved

The "statements are not allowed at the top level" error has been **completely fixed**.

## What Was Wrong

The original `lzfse-cli.swift` had executable code at the top level:
```swift
let args = CommandLine.arguments  // ❌ Top-level statement
if args.contains("-h") { ... }     // ❌ Top-level statement
// ... etc
```

This conflicted with SwiftUI apps, which require a single `@main` entry point.

## The Solution

All CLI code is now wrapped in a `runCLI()` function:

```swift
func runCLI() {
    let args = CommandLine.arguments
    // ... all CLI logic ...
    try? inputHandle.close()
    try? outputHandle.close()
}

runCLI()   // ← last line of the file: the standalone CLI entry point
```

**Key point**: the file still ends with a bare top-level `runCLI()` call, so
`lzfse-cli.swift` remains a runnable CLI on its own. It is **not** a pure
library as shipped. Both build scripts strip that one line before compiling:

- `build-ui.zsh:62` — `grep -v "^runCLI()$" "${PROJECT_ROOT}/lzfse-cli.swift" > "$TEMP_CLI"`
- `build-win.zsh:98` — `grep -v '^runCLI()$' "${PROJECT_ROOT}/lzfse-cli.swift" > "${TARGET_DIR}/lzfse-cli.swift"`

**Why this matters**: a raw `swiftc` command copied out of this document — one
that feeds `lzfse-cli.swift` straight to the compiler alongside the `@main` UI
file — will hit the top-level-statement / `@main` conflict again. Use a build
script, or strip the call yourself first (see "Command Line Method" below).

## How It Works Now

### For SwiftUI App (Your Use Case)

1. `lzfse-cli.swift` provides compression functions as a library, once the build
   script has stripped its trailing `runCLI()` call
2. `lzfse-ui.swift` has the `@main` entry point
3. The UI calls compression functions directly:
   - `runParallelEncode(...)` for compression
   - `LZFSEv1.decodeStreamFromFile(...)` for decompression
4. ✅ **No conflicts, builds successfully**

### For CLI Tool

Nothing extra is needed: the trailing `runCLI()` call already makes
`lzfse-cli.swift` a standalone command-line program.

```bash
swiftc -O lzfse-cli.swift -o lzfse
./lzfse -h
```

Building the SwiftUI app is the case that needs the extra step — the `runCLI()`
line has to come out first, which the build scripts do for you.

## Build Instructions

### Xcode Method (Easiest)

```
1. Create new macOS App project in Xcode
2. Drag lzfse-cli.swift into project
3. Delete its last line, the bare `runCLI()` call
4. Drag lzfse-ui.swift into project  
5. Press ⌘R
6. ✅ It builds and runs!
```

Step 3 is not optional: Xcode compiles the file as-is, so leaving `runCLI()` in
reproduces the `@main` conflict. Prefer `./build-ui.zsh`, which strips it
without touching the checked-in source.

### Command Line Method

`lzfse-cli.swift` cannot be handed to `swiftc` unmodified here — its trailing
`runCLI()` call is a top-level statement and collides with the UI's `@main`.
Strip it into a temporary copy first, exactly as `build-ui.zsh` does:

```bash
grep -v '^runCLI()$' ../lzfse-cli.swift > /tmp/lzfse-cli-lib.swift

swiftc -O /tmp/lzfse-cli-lib.swift lzfse-ui.swift -o LZFSE-UI \
    -framework SwiftUI

./LZFSE-UI
```

`-framework UniformTypeIdentifiers` is **not** needed — `lzfse-ui.swift` imports
only `SwiftUI` and `Compression`.

### Build Script Method

```bash
chmod +x build-ui.zsh
./build-ui.zsh
open "LZFSE_UI.app"
```

## Verification

After building, you should have a working app with:

- ✅ File selection from Finder
- ✅ Decompress folder selection
- ✅ Algorithm selection (Apple/Other3/BVX3)
- ✅ Manual n setting clamped to `1...processorCount × 10`
- ✅ Extraction with Finder integration
- ✅ Progress indicators
- ✅ Status messages
- ✅ Bilingual interface (English/Chinese)

## Common Questions

**Q: Can I still use lzfse-cli.swift as a command-line tool?**
A: Yes, directly — the file's last line is a bare `runCLI()` call, so `swiftc -O lzfse-cli.swift -o lzfse` gives you the CLI with no extra main file.

**Q: Will this break if I update lzfse-cli.swift?**
A: As long as you keep the `func runCLI() { ... }` wrapper and keep the invocation on its own line as exactly `runCLI()`, it will work fine — the build scripts match that line with `grep -v '^runCLI()$'`, so re-indenting it or adding a trailing comment would leave it in the UI build and break it.

**Q: Why not just remove the CLI code?**
A: The `runCLI()` function contains useful logic you might want to reference. Plus, it's harmless as a library function.

**Q: Do I need to modify lzfse-ui.swift?**
A: No, `lzfse-ui.swift` is ready to use as-is.

## What Files Do I Need?

**Minimum for SwiftUI app:**
- ✅ `lzfse-cli.swift` (its trailing `runCLI()` call stripped at build time)
- ✅ `lzfse-ui.swift` (ready as-is)

**Optional but helpful:**
- `BUILD-INSTRUCTIONS.md` (build guide)
- `README-UI.md` (user manual)
- `build-ui.zsh` (automated build script)

## Next Steps

1. ✅ Build the app (use Xcode or command line)
2. ✅ Test with a sample file
3. ✅ Enjoy your LZFSE compression tool!

---

## Error Resolution Summary

| Error | Status |
|-------|--------|
| "statements are not allowed at the top level" | ✅ **FIXED** |
| "expressions are not allowed at the top level" | ✅ **FIXED** |
| "global 'let' declaration requires an initializer" | ✅ **FIXED** |

All errors resolved by wrapping CLI code in a `runCLI()` function and removing
its single top-level call site from the UI build (`grep -v '^runCLI()$'`).

---

**You're ready to build!** 🎉

If you encounter any NEW errors during build, they'll be different issues (like missing frameworks or file paths), not the top-level statements error we just fixed.

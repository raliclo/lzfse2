# Xcode Project Setup Guide

This guide walks you through creating a complete Xcode project for LZFSE UI.

## Quick Setup (5 minutes)

### Step 1: Create New Project

1. Open Xcode
2. **File → New → Project** (or press ⌘⇧N)
3. Choose template:
   - Platform: **macOS**
   - Template: **App**
   - Click **Next**

4. Configure project:
   - **Product Name**: LZFSE UI
   - **Team**: Your team (or None)
   - **Organization Identifier**: com.yourname (e.g., com.apple)
   - **Bundle Identifier**: (auto-generated as com.yourname.LZFSE-UI)
   - **Interface**: **SwiftUI** ✓
   - **Language**: **Swift** ✓
   - **Storage**: None (uncheck if present)
   - Click **Next**

5. Choose location and click **Create**

### Step 2: Add Source Files

1. In Xcode's Project Navigator (left sidebar), right-click on "LZFSE UI" folder
2. Select **Add Files to "LZFSE UI"...**
3. Navigate to your files and select:
   - `lzfse-cli.swift`
   - Click **Add**

### Step 3: Replace Default Code

1. In Project Navigator, click on **LZFSE_UIApp.swift** (the auto-generated app file)
2. Delete the existing file content
3. Open `lzfse-ui.swift` and copy the content
4. Paste into **LZFSE_UIApp.swift**
5. Rename the file:
   - Right-click **LZFSE_UIApp.swift**
   - Select **Rename**
   - Change to **ContentView.swift** (or keep it, doesn't matter)

### Step 4: Configure Project Settings

1. Click on project name (blue icon) at top of Project Navigator
2. Select **LZFSE UI** target (not project)
3. Go to **General** tab:
   - **Deployment Target**: macOS 13.0 or later
   - **App Category**: Utilities

4. Go to **Signing & Capabilities** tab:
   - Select your team (or use "Sign to Run Locally")
   - Bundle Identifier should be unique

### Step 5: Build and Run

1. Select **My Mac** as run destination (top toolbar)
2. Press **⌘R** or click the Play button
3. The app should build and launch!

---

## Detailed Configuration

### Project Settings

#### Build Settings (Optional Optimizations)

1. Click project → Target → **Build Settings**
2. Search for "Optimization Level"
   - **Debug**: -Onone (default)
   - **Release**: -O (default)
   - For maximum release performance: -Osize or -O -whole-module-optimization

3. Search for "Swift Compiler - Code Generation"
   - **Compilation Mode**: 
     - Debug: Incremental
     - Release: Whole Module

#### Info.plist Configuration

The template creates an Info.plist automatically. To customize:

1. Click on project → Target → **Info** tab
2. Add custom entries:

```
Document Types (Optional - for drag & drop .lzfse files):
- Name: LZFSE Compressed File
- Types: public.data
- Role: Editor

Localization:
- Development Language: English
- Localizations: + Add Chinese (Simplified/Traditional)
```

### Asset Catalog (Optional Custom Icon)

To add a custom app icon:

1. In Project Navigator, click **Assets.xcassets**
2. Select **AppIcon**
3. Drag icon files (PNG) into appropriate size slots:
   - 16x16, 32x32, 128x128, 256x256, 512x512 (each @1x and @2x)

For now, macOS will use a default app icon.

### Capabilities

If you need specific capabilities:

1. Click project → Target → **Signing & Capabilities**
2. Click **+ Capability** to add:
   - App Sandbox (for Mac App Store)
   - Hardened Runtime (for notarization)
   - User Selected Files (for file access)

For personal use, these are optional.

---

## File Organization

Recommended project structure:

```
LZFSE UI/
├── LZFSE_UIApp.swift       (App entry point)
├── ContentView.swift        (Main UI - from lzfse-ui.swift)
├── Models/
│   └── LZFSEViewModel.swift (Extracted from lzfse-ui.swift)
├── Engine/
│   └── lzfse-cli.swift      (Core compression logic)
├── Resources/
│   └── Assets.xcassets
└── Supporting Files/
    └── Info.plist
```

To organize files:

1. **Create Groups** (folders in Xcode):
   - Right-click "LZFSE UI" → **New Group**
   - Name it (e.g., "Engine", "Models")

2. **Move Files**:
   - Drag files into appropriate groups
   - This doesn't move files on disk, just organizes in Xcode

---

## Building for Distribution

### Archive for Distribution

1. **Select Generic Mac** as run destination
2. **Product → Archive** (⌘⇧B)
3. Wait for archive to complete
4. Xcode Organizer opens automatically
5. Click **Distribute App**
6. Choose distribution method:
   - **Copy App**: For local testing
   - **Custom**: For custom distribution
   - **Mac App Store**: Requires Apple Developer Program

### Export Unsigned App

For simple sharing:

1. After archiving, click **Distribute App**
2. Select **Copy App**
3. Click **Next** → **Export**
4. Choose location → **Export**
5. Share the exported .app bundle

### Notarization (Optional, for Distribution)

For public distribution outside Mac App Store:

1. You need Apple Developer Program membership ($99/year)
2. Archive the app
3. Distribute → **Developer ID**
4. Enable **Notarization**
5. Follow Apple's notarization process

---

## Common Build Issues

### Issue 1: "Cannot find type 'LZFSEv1' in scope"

**Solution**: Ensure `lzfse-cli.swift` is added to the target:
1. Click `lzfse-cli.swift` in Project Navigator
2. Check **File Inspector** (right panel)
3. Under **Target Membership**, ensure "LZFSE UI" is checked

### Issue 2: "Cannot find 'runParallelEncode' in scope"

**Solution**: The function is inside `lzfse-cli.swift`. Make sure:
1. File is in project
2. File is in target membership
3. No compilation errors in that file

### Issue 3: "Minimum deployment target not met"

**Solution**: 
1. Click project → Target → General
2. Set **Deployment Target** to macOS 13.0

### Issue 4: "Signing for 'LZFSE UI' requires a development team"

**Solution**:
1. Click project → Target → Signing & Capabilities
2. Under **Team**, select your Apple ID or:
3. Check **Sign to Run Locally** (Xcode 14+)

### Issue 5: Build succeeds but app crashes on launch

**Solution**: Check console for errors:
1. View → Debug Area → Show Debug Area (⌘⇧Y)
2. Look for error messages
3. Common issue: Missing @main attribute
   - Ensure only ONE struct has @main

---

## Running Tests

While the CLI has built-in tests, you can add Swift Testing:

### Add Test Target

1. **File → New → Target**
2. Choose **Unit Testing Bundle**
3. Name it "LZFSE UI Tests"
4. Click **Finish**

### Create Test File

```swift
import Testing
@testable import LZFSE_UI

@Suite("LZFSE Compression Tests")
struct CompressionTests {
    
    @Test("Test compression settings")
    func testCompressionSettings() async throws {
        let viewModel = LZFSEViewModel()
        #expect(viewModel.operation == .encode)
        #expect(viewModel.algorithm == .other3)
        #expect(viewModel.parallelTasks == 8)
    }
    
    @Test("Test file validation")
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

---

## Debugging Tips

### Enable Debug Logging

Add to ViewModel:

```swift
private func log(_ message: String) {
    #if DEBUG
    print("[LZFSE UI] \(message)")
    #endif
}
```

### Use Breakpoints

1. Click line number to add breakpoint
2. Run in debug mode (⌘R)
3. When hit, inspect variables in Debug Area

### View Hierarchy Inspector

While app is running:
1. Click Debug View Hierarchy button (three overlapping rectangles)
2. Inspect UI structure
3. Find layout issues

---

## Performance Profiling

### Instruments

To profile the app:

1. **Product → Profile** (⌘I)
2. Choose instrument:
   - **Time Profiler**: CPU usage
   - **Allocations**: Memory usage
   - **Leaks**: Memory leaks
3. Record and analyze

### Memory Graph

While app is running:
1. Click Memory Graph button (three circles connected)
2. View object graph
3. Find retain cycles

---

## Keyboard Shortcuts Reference

### Xcode Essentials

- **⌘R**: Run (Build & Run)
- **⌘B**: Build
- **⌘.**: Stop running
- **⌘⇧K**: Clean build folder
- **⌘⇧Y**: Toggle debug area
- **⌘⌥0**: Hide/show navigator
- **⌘0**: Toggle navigator
- **⌘⌥⏎**: Show/hide canvas (for SwiftUI preview)

### Editing

- **⌘/**: Comment/uncomment
- **⌃I**: Re-indent
- **⌘⌥[** or **]**: Move line up/down
- **⌘⇧O**: Open quickly (find file/symbol)

---

## SwiftUI Preview

To enable live preview:

1. Open **ContentView.swift**
2. Ensure you have:
   ```swift
   #Preview {
       ContentView()
   }
   ```
3. Click **Resume** button in Canvas (or ⌘⌥P)
4. Canvas shows live preview
5. Changes appear in real-time

If preview fails:
- **Editor → Canvas** to show it
- Click **Diagnose** if errors appear
- Clean build folder (⌘⇧K) and retry

---

## Advanced: Custom Build Scripts

### Add Run Script Phase

To add automatic version numbering:

1. Project → Target → **Build Phases**
2. Click **+** → **New Run Script Phase**
3. Add script:

```bash
# Auto-increment build number
buildNumber=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "${INFOPLIST_FILE}")
buildNumber=$(($buildNumber + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $buildNumber" "${INFOPLIST_FILE}"
```

---

## Resources

### Official Documentation

- [SwiftUI Tutorials](https://developer.apple.com/tutorials/swiftui)
- [App Distribution Guide](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)
- [Swift Language Guide](https://docs.swift.org/swift-book/)

### Community

- [Swift Forums](https://forums.swift.org/)
- [Apple Developer Forums](https://developer.apple.com/forums/)
- [Stack Overflow - SwiftUI](https://stackoverflow.com/questions/tagged/swiftui)

---

## Summary Checklist

- [ ] Created new macOS App project in Xcode
- [ ] Added `lzfse-cli.swift` to project
- [ ] Replaced default app code with `lzfse-ui.swift` content
- [ ] Set deployment target to macOS 13.0+
- [ ] Configured signing
- [ ] Build succeeded (⌘B)
- [ ] App runs successfully (⌘R)
- [ ] Tested file selection
- [ ] Tested compression/decompression
- [ ] Ready to use!

---

**Congratulations!** You now have a fully functional LZFSE UI application! 🎉

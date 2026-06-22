# 🚀 LZFSE UI - 60 Second Quick Start

## Step 1: Gather Files (5 seconds)

You need exactly **2 files**:
- ✅ `lzfse-cli.swift` 
- ✅ `lzfse-ui.swift`

## Step 2: Open Xcode (10 seconds)

1. Launch Xcode
2. File → New → Project
3. Choose: **macOS** → **App**
4. Name: **LZFSE UI**
5. Click **Next** → **Create**

## Step 3: Add Files (15 seconds)

1. In Xcode's left sidebar, find your project folder
2. Drag `lzfse-cli.swift` into it → Check "Copy items if needed" → **Add**
3. Drag `lzfse-ui.swift` into it → **Add**
4. Delete the default `ContentView.swift` that Xcode created (optional but clean)

## Step 4: Build & Run (30 seconds)

1. Press **⌘R** (or click the Play button)
2. Wait for compilation...
3. **App launches!** ✅

---

## You're Done! 🎉

You now have a working LZFSE compression app.

### Quick Test

1. Click "Select File" → choose any file
2. Click "Select Location" → choose where to save
3. Click "Compress" → wait
4. See status message with compression stats!

---

## Troubleshooting (If Needed)

### Build Error: "Cannot find LZFSEv1"

**Fix**: 
1. Click `lzfse-cli.swift` in sidebar
2. Right panel → File Inspector
3. Under "Target Membership", check the box for "LZFSE UI"

### Build Error: "Minimum deployment target"

**Fix**:
1. Click blue project icon at top of sidebar
2. Select target "LZFSE UI"
3. General tab → "Minimum Deployments" → Set to **macOS 13.0**

### App Crashes When Launched

**Fix**: 
1. Make sure you added BOTH files
2. Make sure `lzfse-ui.swift` is in the target
3. Check Xcode's console (⌘⇧Y) for error details

---

## Command Line Alternative (30 seconds)

If you prefer terminal:

```bash
cd /path/to/your/files
swiftc -O lzfse-cli.swift lzfse-ui.swift -o LZFSE-UI \
    -framework SwiftUI -framework UniformTypeIdentifiers
./LZFSE-UI
```

---

## Next Steps

- **User Manual**: See `README-UI.md`
- **Detailed Build Guide**: See `BUILD-INSTRUCTIONS.md`  
- **Design Details**: See `UI-DESIGN.md`
- **Quick Reference**: See `QUICK-REFERENCE.md`

---

**Total Time**: ~60 seconds from start to working app! ⏱️

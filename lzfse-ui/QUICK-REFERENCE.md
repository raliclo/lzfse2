# LZFSE UI - Quick Reference Card

## 🚀 Getting Started

### First Time Setup
1. Open Xcode → New macOS App Project
2. Add `lzfse-cli.swift` and `lzfse-ui.swift`
3. Press ⌘R to build and run
4. Done! See XCODE-SETUP.md for details

### Or Use Build Script
```bash
chmod +x build-ui.sh
./build-ui.sh
open "LZFSE UI.app"
```

---

## 📝 Basic Operations

### Compress a File
```
1. Click "Compress / 壓縮"
2. Select algorithm (Other3 recommended)
3. Click "Select File" → choose your file
4. Click "Select Location" → choose where to save
5. Click "Compress" button
6. Wait for completion
7. Check status for results
```

### Decompress a File
```
1. Click "Decompress / 解壓縮"
2. Click "Select File" → choose .lzfse file
3. Click "Select Location" → choose output folder
4. Click "Decompress" button
5. Wait for completion
6. File appears in chosen folder
```

---

## ⚙️ Algorithm Guide

| Algorithm | Speed | Ratio | Compatibility | Use When |
|-----------|-------|-------|---------------|----------|
| **Apple** | ★★★★☆ | ★★★☆☆ | ✓ Standard | You need compatibility |
| **Other3** | ★★★☆☆ | ★★★★☆ | ✓ Standard | Balanced performance |
| **BVX3** | ★★☆☆☆ | ★★★★★ | ✗ Custom | Maximum compression |

**Standard**: Can be decompressed by Apple tools and this app  
**Custom**: Only this app can decompress

---

## 🎛️ Settings Reference

### Parallel Tasks (n)
- **Range**: 1-32
- **Default**: 8
- **Effect**: More tasks = faster but uses more memory
- **Memory**: ~2MB per task
- **Recommendation**: 
  - Small files: 2-4
  - Large files: 8-16
  - Limited RAM: 4

### Lazy2 Mode (BVX3 only)
- **Effect**: Better compression, slower speed
- **Speed impact**: ~2× slower
- **Ratio gain**: ~5-10%
- **Use when**: Size matters more than time

### Optimal Parsing (BVX3 only)
- **Effect**: Best compression, slowest speed
- **Speed impact**: ~4× slower
- **Ratio gain**: ~10-15%
- **Use when**: Maximum compression needed
- **Note**: Overrides Lazy2

---

## 💡 Quick Tips

### For Best Speed
```
Algorithm: Apple
Parallel Tasks: Match CPU cores
Options: None
```

### For Best Compression (Standard Format)
```
Algorithm: Other3
Parallel Tasks: 8-16
Options: N/A
```

### For Maximum Compression (Custom Format)
```
Algorithm: BVX3
Parallel Tasks: 8-16
Options: Enable "Optimal Parsing"
Warning: Only this tool can decompress
```

### For Low Memory
```
Parallel Tasks: 2-4
Any algorithm works
```

---

## 📊 Performance Expectations

### Small Files (<10MB)
- **Compression**: 1-5 seconds
- **Decompression**: <1 second
- **Tip**: Lower parallel tasks (n=2)

### Medium Files (10-100MB)
- **Compression**: 5-30 seconds
- **Decompression**: 2-10 seconds
- **Tip**: Default settings work well

### Large Files (100MB-1GB)
- **Compression**: 30 seconds - 5 minutes
- **Decompression**: 10-60 seconds
- **Tip**: Increase parallel tasks (n=16)

### Very Large Files (>1GB)
- **Compression**: 5-20 minutes
- **Decompression**: 1-5 minutes
- **Tip**: Max parallel tasks (n=32), ensure disk space

*Times vary by CPU speed and file compressibility*

---

## 🎯 Typical Compression Ratios

| File Type | Typical Ratio | Example |
|-----------|---------------|---------|
| **Text** | 20-30% | 1MB → 250KB |
| **Log files** | 10-20% | 1MB → 150KB |
| **Source code** | 25-35% | 1MB → 300KB |
| **JSON/XML** | 15-25% | 1MB → 200KB |
| **Executables** | 40-60% | 1MB → 500KB |
| **Already compressed** | 95-100% | 1MB → 950KB |
| **Images (JPEG/PNG)** | 98-100% | No benefit |
| **Videos** | 98-100% | No benefit |

**Note**: Don't compress already-compressed formats (ZIP, JPEG, MP4, etc.)

---

## ⚠️ Common Issues & Solutions

### "Decode failed"
```
Problem: File is corrupted or not LZFSE
Solution: 
  - Verify file is actually compressed
  - Try recompressing original
  - Check file wasn't modified
```

### "Out of memory"
```
Problem: Not enough RAM
Solution:
  - Reduce parallel tasks (n)
  - Close other apps
  - Upgrade RAM
```

### App won't open
```
Problem: Security settings
Solution:
  - Right-click app → Open
  - System Settings → Security → Allow
  - Or code sign in Xcode
```

### Slow compression
```
Problem: Settings too aggressive
Solution:
  - Disable Optimal/Lazy2
  - Use Apple algorithm
  - Reduce parallel tasks
```

### Can't find output file
```
Problem: Output location unclear
Solution:
  - Check status panel for full path
  - Use Finder's search
  - Select output location explicitly
```

---

## 🖥️ Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| ⌘O | Open/Select input file |
| ⌘S | Start compression |
| ⌘R | Reset all settings |
| ⌘W | Close window |
| ⌘Q | Quit app |
| ⌘, | Preferences (if implemented) |

---

## 📁 File Extensions

| Extension | Meaning |
|-----------|---------|
| `.lzfse` | Standard LZFSE compressed file |
| `.lz` | Alternative LZFSE extension |
| (any) | LZFSE detects by magic bytes, not extension |

**Tip**: You can compress/decompress files without specific extensions

---

## 🔍 Understanding Status Messages

### During Compression
```
"Compressing... / 壓縮中..."
→ Normal, wait for completion
```

### Success
```
"✓ Success! / 成功！"
Input size: X MB
Output size: Y MB
Compression ratio: Z%
Time elapsed: T seconds
→ Everything worked!
```

### Errors
```
"Error: Decode failed"
→ File corrupted or not LZFSE

"Error: Cannot write to output"
→ Check disk space and permissions

"Error: File not found"
→ Input file moved or deleted
```

---

## 🧮 Size Calculator

**Estimate compressed size:**

```
Original Size × Expected Ratio = Compressed Size

Example:
100 MB text file
100 MB × 0.25 (25% ratio) = 25 MB compressed
```

**Estimate time:**

```
(File Size in MB) ÷ (Speed in MB/s) = Time

Example with Other3:
100 MB ÷ 1 MB/s = 100 seconds ≈ 1.7 minutes
```

---

## 🛠️ Maintenance

### Clear Cache
```
App doesn't cache, no maintenance needed
```

### Updates
```
Recompile with latest lzfse-cli.swift
No automatic updates (standalone app)
```

### Uninstall
```
Delete "LZFSE UI.app" from Applications
No preferences files created
```

---

## 📞 Getting Help

### Documentation
1. **README-UI.md** → User guide
2. **XCODE-SETUP.md** → Setup help
3. **UI-DESIGN.md** → Technical details
4. **PROJECT-SUMMARY.md** → Overview

### Check Issues
- Ensure macOS 13.0+
- Verify file permissions
- Check available disk space
- Try with smaller test file first

### Debug Mode
In Xcode:
1. Open project
2. View → Debug Area → Show Debug Area (⌘⇧Y)
3. Run app (⌘R)
4. Check console for error messages

---

## 🎓 Best Practices

### ✅ DO:
- Test with small files first
- Keep originals of important files
- Verify decompression works before deleting originals
- Use Other3 for general purposes
- Choose output locations carefully

### ❌ DON'T:
- Compress already-compressed files (JPEG, MP4, ZIP)
- Set parallel tasks too high (>32)
- Delete original before verifying compressed version
- Use BVX3 for files you need to share (unless recipient has this tool)
- Compress files you need immediate random access to

---

## 📈 Workflow Examples

### Scenario 1: Archive Log Files
```
Files: Server logs (text), 500MB total
Goal: Long-term storage

Settings:
  Operation: Compress
  Algorithm: BVX3
  Parallel Tasks: 16
  Optimal: Enabled
  
Expected: ~75MB output, 5 minutes
Savings: ~425MB (85% reduction)
```

### Scenario 2: Quick Compression
```
Files: Code repository, 50MB
Goal: Fast email attachment

Settings:
  Operation: Compress
  Algorithm: Other3
  Parallel Tasks: 8
  Options: Default
  
Expected: ~15MB output, 30 seconds
Savings: ~35MB (70% reduction)
```

### Scenario 3: Extract Archive
```
Files: Received .lzfse file
Goal: Access original data

Settings:
  Operation: Decompress
  (Algorithm: Auto-detected)
  Parallel Tasks: 8
  
Expected: Original file restored, <10 seconds
```

---

## 🔐 Security Notes

- **No telemetry**: App doesn't send data anywhere
- **Local only**: All processing happens on your Mac
- **No cloud**: Files never leave your computer
- **File permissions**: Only accesses files you explicitly select
- **Sandboxing**: Can be sandboxed for Mac App Store

---

## 📊 Comparison Chart

```
                Speed    Ratio    Memory   Compat
Apple          ████░    ███░░    ███░░    ████░
Other3         ███░░    ████░    ███░░    ████░
BVX3           ██░░░    █████    ████░    █░░░░
BVX3+Lazy2     █░░░░    █████    ████░    █░░░░
BVX3+Optimal   ░░░░░    █████    ████░    █░░░░
```

---

## ⚡ Power User Tips

### Batch Processing (Future Feature)
Currently: Compress one file at a time
Workaround: Use shell loop with CLI version

### Automation
```bash
# Use CLI version in scripts:
lzfse -encode -i input.txt -o output.lzfse -algo other3
```

### Integration with Finder
Add as Finder Quick Action:
1. Automator → Quick Action
2. Run Shell Script → call lzfse CLI
3. Save to Services

### Memory Optimization
For 8GB RAM Mac: n=4
For 16GB RAM Mac: n=8
For 32GB+ RAM Mac: n=16-32

---

**Quick Reference Version 1.0**  
*For LZFSE UI - macOS Compression Tool*  
*Print this page for desk reference!*

---

## 📋 Checklist for Every Compression

- [ ] Original file is backed up (if important)
- [ ] Selected appropriate algorithm for use case
- [ ] Have enough disk space (≥ original file size free)
- [ ] Chosen correct output location
- [ ] Verified file type is compressible (not JPEG/MP4)
- [ ] Set parallel tasks appropriate for system
- [ ] Ready to wait (large files take time)

## 📋 Checklist for Every Decompression

- [ ] Compressed file is valid (not corrupted)
- [ ] Have enough disk space (≥ original file size)
- [ ] Chosen correct output folder
- [ ] Ready to verify decompressed file
- [ ] Have the right tool (BVX3 needs this app)

---

*Keep this handy while using LZFSE UI!*

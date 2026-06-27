//  lzfse-ui-win.swift — SwiftCrossUI 圖形介面（Windows），用於 LZFSE 壓縮/解壓縮工具
//  lzfse-ui-win.swift — SwiftCrossUI GUI (Windows) for the LZFSE compression tool
//
//  設計參考 lzfse-ui/lzfse-ui.swift（macOS / SwiftUI 版）。
//  Designed after lzfse-ui/lzfse-ui.swift (the macOS / SwiftUI version).
//
//  與 macOS 版的差異 / Differences from the macOS version:
//    1. 介面框架改用 SwiftCrossUI（跨平台），Windows 後端為 WinUIBackend。
//       UI framework is SwiftCrossUI; the Windows backend is WinUIBackend.
//    2. 直接 import lzfse-cli 的 codec（runParallelEncode / LZFSEv1）——
//       build-win.sh 會以 grep -v 移除 lzfse-cli.swift 結尾的 runCLI() 後一起編入同一個 target。
//       The lzfse-cli codec (runParallelEncode / LZFSEv1) is linked directly; build-win.sh
//       strips the trailing runCLI() line from lzfse-cli.swift and compiles it into this target.
//    3. 移除 Apple (.apple) 演算法——Windows 無 Compression framework。
//       The Apple (.apple) algorithm is removed — no Compression framework on Windows.
//    4. WinUIBackend 的開檔對話框一次只能選「檔案」或「資料夾」其一，
//       故壓縮輸入提供「選檔案 / 選資料夾」兩顆按鈕。
//       WinUI's open dialog only allows files OR directories (not both) in one dialog,
//       so the compress input offers two separate buttons (Select File / Select Folder).
//    5. 移除 macOS 專屬的 task_vm_info RSS 量測與 NSPasteboard 複製。
//       Removed the macOS-only task_vm_info RSS sampling and NSPasteboard copy.

import Foundation
import SwiftCrossUI
import DefaultBackend
#if canImport(WinSDK)
import WinSDK
#endif

// MARK: - Clipboard (Win32)

// SwiftCrossUI/WinUIBackend 未提供剪貼簿 API，且 WinUI TextBox 的 Ctrl+C 未接上，
// 故以 Win32 剪貼簿 API 直接寫入 UTF-16 文字（CF_UNICODETEXT）。
// Neither SwiftCrossUI nor WinUIBackend exposes a clipboard API, and the WinUI TextBox's
// Ctrl+C isn't wired up, so write UTF-16 text directly via the Win32 clipboard (CF_UNICODETEXT).
#if canImport(WinSDK)
private func copyToClipboard(_ text: String) {
    guard OpenClipboard(nil) else { return }
    defer { CloseClipboard() }
    _ = EmptyClipboard()
    let utf16 = Array(text.utf16) + [UInt16(0)]                 // null-terminated
    let byteCount = utf16.count * MemoryLayout<UInt16>.size
    guard let hMem = GlobalAlloc(UINT(0x0002), SIZE_T(byteCount)) else { return }  // GMEM_MOVEABLE
    guard let dst = GlobalLock(hMem) else { GlobalFree(hMem); return }
    utf16.withUnsafeBytes { src in
        dst.copyMemory(from: src.baseAddress!, byteCount: byteCount)
    }
    _ = GlobalUnlock(hMem)
    if SetClipboardData(UINT(13), hMem) == nil {               // CF_UNICODETEXT = 13
        GlobalFree(hMem)                                       // 失敗才釋放；成功後由系統接管
    }
}

// WinUIBackend 的 showOpenDialog 只用 FileOpenPicker（僅能選檔案，忽略 allowSelectingDirectories），
// 故資料夾選擇改用 Win32 SHBrowseForFolderW 自行實作。
// WinUIBackend's showOpenDialog only uses FileOpenPicker (files only; it ignores
// allowSelectingDirectories), so folder selection is implemented via Win32 SHBrowseForFolderW.
//
// 重要：SHBrowseForFolderW 是封鎖式 modal，若在 WinUI UI 執行緒（ASTA）直接呼叫，
// 會在 ASTA 內開啟巢狀訊息迴圈而卡死。故改在獨立 STA 執行緒開對話框，
// 完成後再以 Task { @MainActor } 跳回主執行緒更新狀態（UI 執行緒全程不被封鎖）。
// IMPORTANT: SHBrowseForFolderW is a blocking modal. Calling it on the WinUI UI thread (ASTA)
// spins a nested message loop and hangs. Run it on a dedicated STA thread, then hop back to the
// MainActor via Task { @MainActor } to update state (the UI thread is never blocked).
private func pickFolderWin32(title: String, completion: @escaping @MainActor (String?) -> Void) {
    let thread = Thread {
        // BIF_NEWDIALOGSTYLE 規定必須先 OleInitialize（不可用 CoInitialize 取代），
        // 否則 SHBrowseForFolderW 會卡死。OleInitialize 亦會初始化 STA。
        // BIF_NEWDIALOGSTYLE requires OleInitialize (CoInitialize is NOT sufficient), otherwise
        // SHBrowseForFolderW hangs. OleInitialize also initializes the STA apartment.
        _ = OleInitialize(nil)
        defer { OleUninitialize() }

        let titleW = Array(title.utf16) + [UInt16(0)]
        var displayName = [WCHAR](repeating: 0, count: Int(MAX_PATH))
        var picked: String? = nil
        titleW.withUnsafeBufferPointer { tptr in
            displayName.withUnsafeMutableBufferPointer { dptr in
                var bi = BROWSEINFOW()
                bi.pszDisplayName = dptr.baseAddress
                bi.lpszTitle = tptr.baseAddress
                bi.ulFlags = UINT(0x0001 | 0x0040)   // BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE
                guard let pidl = SHBrowseForFolderW(&bi) else { return }
                defer { CoTaskMemFree(UnsafeMutableRawPointer(pidl)) }
                var pathBuf = [WCHAR](repeating: 0, count: Int(MAX_PATH))
                let ok = pathBuf.withUnsafeMutableBufferPointer { pptr in
                    SHGetPathFromIDListW(pidl, pptr.baseAddress)
                }
                if ok { picked = String(decoding: pathBuf.prefix(while: { $0 != 0 }), as: UTF16.self) }
            }
        }
        let final = picked
        Task { @MainActor in completion(final) }
    }
    thread.stackSize = 1 << 20
    thread.start()
}

// 以 CREATE_NO_WINDOW 啟動命令列，避免 GUI 程式 spawn 主控台程式（cmd/tar/lzfse）時跳出主控台視窗。
// 回傳子程序 exit code（-1 = 建立失敗）。輸出請在命令列以重導向寫入檔案。
// Launch a command line with CREATE_NO_WINDOW so spawning console programs (cmd/tar/lzfse) from a
// GUI app doesn't pop up a console window. Returns the child's exit code (-1 = failed to create);
// redirect output to files on the command line.
private func runHiddenProcess(_ commandLine: String) -> Int32 {
    var si = STARTUPINFOW()
    si.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
    var pi = PROCESS_INFORMATION()
    var cmdLine = Array(commandLine.utf16) + [0]
    let created = cmdLine.withUnsafeMutableBufferPointer { buf in
        CreateProcessW(nil, buf.baseAddress, nil, nil, false,
                       DWORD(0x08000000),   // CREATE_NO_WINDOW
                       nil, nil, &si, &pi)
    }
    guard created else { return -1 }
    WaitForSingleObject(pi.hProcess, INFINITE)
    var code: DWORD = 0
    GetExitCodeProcess(pi.hProcess, &code)
    CloseHandle(pi.hThread)
    CloseHandle(pi.hProcess)
    return Int32(bitPattern: code)
}

private struct LZFSEIconWindowSearch {
    var pid: DWORD
    var hwnd: HWND?
}

private let lzfseIconInstallEnumProc: WNDENUMPROC = { hwnd, lParam in
    guard let search = UnsafeMutablePointer<LZFSEIconWindowSearch>(bitPattern: Int(lParam)) else {
        return true
    }
    var pid: DWORD = 0
    GetWindowThreadProcessId(hwnd, &pid)
    if pid == search.pointee.pid && IsWindowVisible(hwnd) {
        search.pointee.hwnd = hwnd
        return false
    }
    return true
}

private func installTaskbarIconWhenReady() {
    let thread = Thread {
        let iconPath = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent()
            .appendingPathComponent("AppIcon.ico")
            .path
        guard FileManager.default.fileExists(atPath: iconPath) else { return }

        let iconPathW = Array(iconPath.utf16) + [0]
        var hwnd: HWND? = nil

        for _ in 0..<80 {
            var search = LZFSEIconWindowSearch(pid: GetCurrentProcessId(), hwnd: nil)
            _ = withUnsafeMutablePointer(to: &search) { ptr in
                EnumWindows(lzfseIconInstallEnumProc, LPARAM(Int(bitPattern: ptr)))
            }
            hwnd = search.hwnd
            if hwnd != nil { break }
            Thread.sleep(forTimeInterval: 0.10)
        }
        guard let hwnd else { return }

        iconPathW.withUnsafeBufferPointer { iptr in
            let big = LoadImageW(nil, iptr.baseAddress, UINT(1), 256, 256, UINT(0x0010))
            let small = LoadImageW(nil, iptr.baseAddress, UINT(1), 32, 32, UINT(0x0010))
            if let big {
                _ = SendMessageW(hwnd, UINT(0x0080), WPARAM(1), LPARAM(Int(bitPattern: big)))
                _ = SetClassLongPtrW(hwnd, Int32(-14), LONG_PTR(Int(bitPattern: big)))
            }
            if let small {
                _ = SendMessageW(hwnd, UINT(0x0080), WPARAM(0), LPARAM(Int(bitPattern: small)))
                _ = SetClassLongPtrW(hwnd, Int32(-34), LONG_PTR(Int(bitPattern: small)))
            }
        }
    }
    thread.stackSize = 1 << 20
    thread.start()
}
#else
private func copyToClipboard(_ text: String) {}
private func pickFolderWin32(title: String, completion: @escaping @MainActor (String?) -> Void) { completion(nil) }
private func runHiddenProcess(_ commandLine: String) -> Int32 { -1 }
private func installTaskbarIconWhenReady() {}
#endif

// MARK: - Models

enum LZFSEAlgorithm: String, CaseIterable {
    case other3 = "Other3 (Enhanced)"
    case bvx3 = "BVX3 (Maximum Compression)"
}

// lzfseX 命名慣例的副檔名（與 macOS 版 isLzfseXArchive 相同）
// lzfseX naming-convention suffixes (same as the macOS isLzfseXArchive)
private let lzfseXSuffixes = [
    ".lzfse.bvx3.optimal", ".lzfse.bvx3.lazy2", ".lzfse.bvx3",
    ".lzfse.other3", ".lzfse.apple", ".lzfse",
]

// 僅用於「等效指令」顯示：依副檔名研判是否為 lzfseX（tar）壓縮包。
// 實際解碼仍以內容偵測（ustar 魔數）為準。
// Used only for the "equivalent command" display: guess whether the input is an lzfseX (tar)
// archive by suffix. Actual decoding still relies on content detection (the ustar magic).
private func isLzfseXArchive(_ path: String) -> Bool {
    lzfseXSuffixes.contains { path.hasSuffix($0) }
}

// Windows PowerShell 的管線會破壞 binary stdout；顯示可貼上執行的解包指令時，
// 用 cmd.exe 的 binary-safe pipe，並將 cmd /c 內層引號加倍。
// PowerShell can corrupt binary stdout in a pipeline. For the copyable extraction command,
// route the pipe through cmd.exe and double quotes inside the cmd /c payload.
private func cmdInnerQuote(_ s: String) -> String {
    "\"\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"\""
}

// MARK: - 配色與卡片樣式（比照 macOS lzfse-ui.swift 的 GroupBox 外觀）
// Palette & card style (mirrors the GroupBox look of macOS lzfse-ui.swift)
private let lzfseAccent = Color.blue
private let lzfseCardBG = Color.adaptive(light: Color(white: 0.95), dark: Color(white: 0.16))
private let lzfseHeaderBG = Color.adaptive(light: Color(white: 0.92), dark: Color(white: 0.12))

extension View {
    // 仿 GroupBox：淺底 + 圓角 + 內距，讓每個區塊像一張卡片
    // Mimics a GroupBox: subtle fill + rounded corners + padding so each section looks like a card
    func lzfseCard() -> some View {
        self.padding(12)
            .frame(maxWidth: .infinity)
            .background(lzfseCardBG)
            .cornerRadius(8)
    }
}

// MARK: - App entry point

@main
struct LZFSEWinApp: App {
    // 操作與演算法以字串綁定（SwiftCrossUI 的 Picker 直接以選項陣列顯示）
    // Operation/algorithm are bound as strings (SwiftCrossUI's Picker renders the option array directly)
    @State var operationLabel: String? = "Compress / 壓縮"
    @State var algorithmLabel: String? = LZFSEAlgorithm.other3.rawValue

    @State var parallelText: String = "8"
    @State var useLazy2: Bool = false
    @State var useOptimal: Bool = false

    @State var inputPath: String? = nil
    @State var outputPath: String? = nil

    @State var isProcessing: Bool = false
    @State var statusMessage: String = ""
    @State var hasError: Bool = false

    @Environment(\.chooseFile) var chooseFile
    @Environment(\.chooseFileSaveDestination) var chooseFileSaveDestination

    init() {
        installTaskbarIconWhenReady()
    }

    // MARK: Derived state

    var isEncode: Bool { operationLabel == "Compress / 壓縮" }
    var algorithm: LZFSEAlgorithm { LZFSEAlgorithm(rawValue: algorithmLabel ?? "") ?? .other3 }
    var isBVX3: Bool { algorithm == .bvx3 }

    var parallelTasks: Int {
        let n = Int(parallelText.trimmingCharacters(in: .whitespaces)) ?? 8
        return min(max(n, 1), ProcessInfo.processInfo.activeProcessorCount * 10)
    }

    var inputIsDirectory: Bool {
        guard let p = inputPath else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
    }

    var canProcess: Bool { inputPath != nil && outputPath != nil && !isProcessing }

    var equivalentCommand: String {
        let input = inputPath ?? "<input>"
        let output = outputPath ?? "<output>"
        let n = parallelTasks
        let algoFlag: String
        if isBVX3 {
            if useOptimal { algoFlag = "-algo bvx3 -optimal" }
            else if useLazy2 { algoFlag = "-algo bvx3 -lazy2" }
            else { algoFlag = "-algo bvx3" }
        } else {
            algoFlag = "-algo other3"
        }
        if isEncode {
            if inputIsDirectory {
                return "tar -cf - \"\(input)\" | lzfse -encode \(algoFlag) -si -o \"\(output)\" -n \(n)"
            }
            return "lzfse -encode \(algoFlag) -i \"\(input)\" -o \"\(output)\" -n \(n)"
        } else {
            // 顯示真實指令；實際執行以內容偵測為準（結果相同）
            // Show the real command; actual execution uses content detection (same result)
            if isLzfseXArchive(input) {
                return "cmd /d /c \".\\lzfse.exe -decode -i \(cmdInnerQuote(input)) -n \(n) -so | tar -xf - -C \(cmdInnerQuote(output))\""
            }
            return "lzfse -decode -i \"\(input)\" -o \"\(output)/\(suggestedOutputName())\" -n \(n)"
        }
    }

    // MARK: Body

    var body: some Scene {
        WindowGroup("LZFSE Compression Tool / LZFSE 壓縮工具") {
            // 版面依 UI-DESIGN.md：header / Divider / ScrollView，
            // 上方 HStack 左欄（operation + algorithm, 280–360 寬）＋右欄（status 填滿），
            // 下方 files、command 全寬。
            // Layout per UI-DESIGN.md: header / Divider / ScrollView; a top HStack with a left
            // column (operation + algorithm, 280–360 wide) and a right column (status, fills),
            // then files and command full-width below.
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(spacing: 20) {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(spacing: 16) {
                                operationSection
                                algorithmSection
                            }
                            .frame(minWidth: 280, maxWidth: 360)

                            statusSection
                                .frame(maxWidth: .infinity)
                        }

                        fileSection
                        commandSection

                        if isProcessing {
                            VStack(spacing: 8) {
                                ProgressView()
                                Text(isEncode ? "Compressing... / 壓縮中..." : "Decompressing... / 解壓縮中...")
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .defaultSize(width: 1040, height: 900)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("🗜️ LZFSE Compression Tool")
                .font(.system(size: 22))
                .foregroundColor(lzfseAccent)
            Text("位元相容 LZFSE 壓縮工具（Windows / SwiftCrossUI）")
                .foregroundColor(.gray)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(lzfseHeaderBG)
    }

    private var operationSection: some View {
        VStack(spacing: 8) {
            Text("Operation / 操作").font(.system(size: 15)).foregroundColor(lzfseAccent)
            // 仿 lzfse-ui.swift 的 segmented：左右兩顆按鈕。WinUIBackend 不支援 .segmented
            // （用 Picker 會退化成下拉選單），故改用兩顆並排按鈕，● 標示目前選取。
            // Mimics lzfse-ui.swift's segmented control with two side-by-side buttons. WinUIBackend
            // doesn't support .segmented (a Picker falls back to a dropdown), so use two buttons;
            // ● marks the current selection.
            HStack(spacing: 8) {
                Button((isEncode ? "● " : "○ ") + "Compress / 壓縮") { setOperation(encode: true) }
                Button((isEncode ? "○ " : "● ") + "Decompress / 解壓縮") { setOperation(encode: false) }
            }
        }
        .lzfseCard()
    }

    private func setOperation(encode: Bool) {
        let newLabel = encode ? "Compress / 壓縮" : "Decompress / 解壓縮"
        guard operationLabel != newLabel else { return }
        operationLabel = newLabel
        outputPath = nil   // 切換模式清除輸出路徑 / switching mode clears the stale output path
    }

    private var algorithmSection: some View {
        VStack(spacing: 8) {
            if isEncode {
                Text("Compression Algorithm / 壓縮演算法").font(.system(size: 15)).foregroundColor(lzfseAccent)
                Picker(of: LZFSEAlgorithm.allCases.map(\.rawValue), selection: $algorithmLabel)
                    .pickerStyle(.radioGroup)

                if isBVX3 {
                    Text("BVX3：自訂格式，僅本工具可解壓縮 / custom format, only this tool can decompress")
                        .foregroundColor(.orange)
                    Toggle("Lazy2 Mode / 雜湊鏈深搜（較慢、壓縮率更佳）", isOn: $useLazy2)
                        .disabled(useOptimal)
                    Toggle("Optimal Parsing / 最優解析（最慢、最佳壓縮率）", isOn: $useOptimal)
                } else {
                    Text("Other3：強化比對，標準 LZFSE 格式 / enhanced matching, standard LZFSE format")
                        .foregroundColor(.gray)
                }
            } else {
                Text("Decompress mode auto-detects the format / 解壓縮模式自動偵測格式")
                    .foregroundColor(.gray)
            }

            HStack(spacing: 8) {
                Text("Parallel Tasks (n) / 並行任務數:")
                TextField("8", text: $parallelText)
                    .frame(width: 70)
            }
        }
        .lzfseCard()
    }

    private var fileSection: some View {
        VStack(spacing: 12) {
            Text("Files / 檔案").font(.system(size: 15)).foregroundColor(lzfseAccent)

            // Input — 可編輯路徑 TextField，聯動 equivalentCommand 與實際執行
            // Editable path TextField; drives the equivalent command and the actual run
            VStack(spacing: 6) {
                TextField(
                    isEncode ? "Input file or folder path / 輸入檔案或資料夾路徑"
                             : "Input .lzfse path / 輸入壓縮檔路徑",
                    text: Binding(
                        get: { inputPath ?? "" },
                        set: { inputPath = $0.isEmpty ? nil : $0 }
                    )
                )
                .font(.system(size: 12))
                HStack(spacing: 8) {
                    if isEncode {
                        Button("Select File / 選檔案") { selectInput(directory: false) }
                        Button("Select Folder / 選資料夾") { selectInput(directory: true) }
                    } else {
                        Button("Select .lzfse / 選壓縮檔") { selectInput(directory: false) }
                    }
                    if inputPath != nil {
                        Button("Clear / 清除") { inputPath = nil; outputPath = nil }
                    }
                }
            }

            Divider()

            // Output — 可編輯路徑 TextField / editable path TextField
            VStack(spacing: 6) {
                TextField(
                    "Output path / 輸出路徑",
                    text: Binding(
                        get: { outputPath ?? "" },
                        set: { outputPath = $0.isEmpty ? nil : $0 }
                    )
                )
                .font(.system(size: 12))
                HStack(spacing: 8) {
                    Button(outputButtonLabel) { selectOutput() }
                    if outputPath != nil {
                        Button("Clear / 清除") { outputPath = nil }
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                Button("Reset / 重置") { reset() }.disabled(isProcessing)
                Button(isEncode ? "Compress / 壓縮" : "Decompress / 解壓縮") { process() }
                    .disabled(!canProcess)
            }
        }
        .lzfseCard()
    }

    private var outputButtonLabel: String {
        if isEncode { return "Save As… / 另存為…" }
        return "Select Output Folder / 選輸出資料夾"
    }

    private var commandSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("Equivalent Command / 等效指令")
                    .font(.system(size: 15))
                    .foregroundColor(lzfseAccent)
                Button("Copy / 複製") { copyToClipboard(equivalentCommand) }
            }
            // 用 TextField（對應 WinUI TextBox，等同 HTML input）呈現，使文字可被選取與複製；
            // SwiftCrossUI 的 Text 無法選取。讀取用 binding（setter 為 no-op → 顯示永遠是計算值）。
            // Render in a TextField (a WinUI TextBox, like an HTML input) so the text can be
            // selected & copied; SwiftCrossUI's Text isn't selectable. Read-only via a binding
            // whose setter is a no-op (the displayed value always reflects the computed command).
            TextField("", text: Binding(get: { equivalentCommand }, set: { _ in }))
                .font(.system(size: 12))
        }
        .lzfseCard()
    }

    private var statusSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(hasError ? "⚠ Status / 狀態" : "Status / 狀態")
                    .foregroundColor(hasError ? .orange : .blue)
                if !statusMessage.isEmpty {
                    // WinUI TextBox 的 Ctrl+C 未接上，故用 Win32 剪貼簿按鈕確保可複製
                    // The WinUI TextBox's Ctrl+C isn't wired up, so a Win32 clipboard button ensures copy
                    Button("Copy / 複製") { copyToClipboard(statusMessage) }
                    Button("Clear / 清除") { statusMessage = ""; hasError = false }
                }
            }
            // 唯讀多行文字框：可選取複製、禁止修改（setter no-op）。狀態訊息為多行，故用 TextEditor。
            // Read-only multi-line text box: selectable & copyable, no edits (no-op setter).
            // Status messages are multi-line, hence TextEditor rather than a single-line TextField.
            TextEditor(text: Binding(
                get: { statusMessage.isEmpty ? "Output will appear here / 輸出結果顯示於此" : statusMessage },
                set: { _ in }
            ))
            .font(.system(size: 13))
        }
        .lzfseCard()
    }

    // MARK: - File dialogs

    private func selectInput(directory: Bool) {
        if directory {
            // 資料夾用 Win32 選擇器（backend 無法選資料夾）/ folders via Win32 (backend can't pick folders)
            pickFolderWin32(title: "Select Folder / 選擇資料夾") { path in
                guard let path else { return }
                inputPath = path
                if outputPath == nil { suggestOutput(for: path) }
            }
        } else {
            Task {
                let url = await chooseFile(
                    title: "Select File / 選擇檔案",
                    allowSelectingFiles: true,
                    allowSelectingDirectories: false
                )
                guard let url else { return }
                inputPath = url.path
                if outputPath == nil { suggestOutput(for: url.path) }
            }
        }
    }

    private func selectOutput() {
        if isEncode {
            Task {
                let url = await chooseFileSaveDestination(
                    title: "Save Compressed File / 儲存壓縮檔",
                    defaultFileName: suggestedOutputName()
                )
                if let url { outputPath = url.path }
            }
        } else {
            // 解碼輸出一律為資料夾（內容偵測決定 tar 解包或單檔輸出）
            // decode output is always a folder (content detection decides tar-extract vs single file)
            pickFolderWin32(title: "Select Output Folder / 選擇輸出資料夾") { path in
                guard let path else { return }
                outputPath = path
            }
        }
    }

    private func suggestOutput(for path: String) {
        let url = URL(fileURLWithPath: path)
        if isEncode {
            outputPath = path + ".lzfse"
        } else {
            // 解碼輸出建議為壓縮檔所在資料夾 / suggest the archive's parent folder
            outputPath = url.deletingLastPathComponent().path
        }
    }

    private func suggestedOutputName() -> String {
        guard let p = inputPath else {
            return isEncode ? "compressed.lzfse" : "decompressed"
        }
        let name = URL(fileURLWithPath: p).lastPathComponent
        if isEncode { return name + ".lzfse" }
        for suffix in lzfseXSuffixes where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    // MARK: - Process

    private func reset() {
        inputPath = nil
        outputPath = nil
        statusMessage = ""
        hasError = false
    }

    private func process() {
        guard let input = inputPath, let output = outputPath else { return }
        isProcessing = true
        hasError = false
        statusMessage = ""

        let encode = isEncode
        let bvx3 = isBVX3
        let lazy2 = isBVX3 && useLazy2 && !useOptimal
        let optimal = isBVX3 && useOptimal
        let n = parallelTasks
        let isDir = inputIsDirectory

        let start = Date()

        // 重活在「獨立 OS 執行緒」執行（非 Task.detached）。
        // 實測 Task.detached 在 SwiftCrossUI/WinUI 下仍會卡住 UI 訊息泵（事件日誌出現 AppHangB1）；
        // 改用專屬 Thread 確保 UI 執行緒全程不被阻塞，結束後再跳回 MainActor 更新狀態。
        // Run the heavy work on a dedicated OS thread (not Task.detached). In practice Task.detached
        // still blocked the WinUI message pump under SwiftCrossUI (AppHangB1 in the event log); a
        // dedicated Thread keeps the UI thread free, then we hop back to the MainActor to update state.
        let thread = Thread {
            var msg: String
            var isError: Bool
            do {
                let note = try lzfsePerform(
                    input: input, output: output, encode: encode,
                    bvx3: bvx3, lazy2: lazy2, optimal: optimal,
                    parallel: n, isDirectory: isDir)
                let elapsed = Date().timeIntervalSince(start)
                var m = "✓ Success! / 成功！\n"
                if encode {
                    let inSize = directorySize(atPath: input)
                    let outSize = fileSize(atPath: output)
                    m += "Input / 輸入: \(formatBytes(inSize))\n"
                    m += "Output / 輸出: \(formatBytes(outSize))\n"
                    if inSize > 0 {
                        m += "Ratio / 壓縮率: \(String(format: "%.2f%%", Double(outSize) / Double(inSize) * 100))\n"
                    }
                } else {
                    m += "Archive / 壓縮檔: \(formatBytes(fileSize(atPath: input)))\n"
                    if let note { m += note + "\n" }
                }
                m += "Time / 耗時: \(String(format: "%.2f", elapsed)) s\n"
                m += "→ \(output)"
                msg = m; isError = false
            } catch {
                msg = "Error / 錯誤: \(error.localizedDescription)"; isError = true
            }
            let finalMsg = msg; let finalErr = isError
            Task { @MainActor in
                statusMessage = finalMsg
                hasError = finalErr
                isProcessing = false
            }
        }
        thread.stackSize = 4 << 20
        thread.start()
    }
}

// MARK: - Codec work (nonisolated free functions; safe to run off the main thread)

enum LZFSEUIError: LocalizedError {
    case decodeFailed
    case encodeFailed
    case tarFailed(String)
    case tarNotFound

    var errorDescription: String? {
        switch self {
        case .decodeFailed: return "Decode failed (corrupt or truncated stream) / 解碼失敗（串流損毀或不完整）"
        case .encodeFailed: return "Encode failed / 編碼失敗"
        case .tarFailed(let detail): return "tar process failed / tar 程序失敗: \(detail)"
        case .tarNotFound: return "tar.exe not found (Windows 10 1803+ required) / 找不到 tar.exe（需 Windows 10 1803+）"
        }
    }
}

// Windows 內建 bsdtar 路徑 / Built-in bsdtar path on Windows
private let windowsTarURL = URL(fileURLWithPath: "C:/Windows/System32/tar.exe")

// 回傳值：解碼時為診斷說明（解出項目/警告），編碼時為 nil。
// Returns: a diagnostic note for decode (items extracted/warnings); nil for encode.
private func lzfsePerform(
    input: String, output: String, encode: Bool,
    bvx3: Bool, lazy2: Bool, optimal: Bool,
    parallel: Int, isDirectory: Bool
) throws -> String? {
    if encode {
        if isDirectory {
            try lzfseFolderEncode(input: input, output: output, bvx3: bvx3, lazy2: lazy2, optimal: optimal, parallel: parallel)
        } else {
            try lzfseFileOperation(input: input, output: output, encode: true, bvx3: bvx3, lazy2: lazy2, optimal: optimal, parallel: parallel)
        }
        return nil
    } else {
        // 解碼：輸出一律為資料夾，內容偵測決定 tar 解包或單檔輸出
        // Decode: output is always a folder; content detection decides tar-extract vs single-file
        return try lzfseDecodeViaEquivalentCommand(input: input, outputFolder: output, parallel: parallel)
    }
}

private func appExecutableFolder() -> URL {
    if let exe = Bundle.main.executableURL {
        return exe.deletingLastPathComponent()
    }
    let argv0 = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
    return argv0.deletingLastPathComponent()
}

private func cmdArgQuote(_ s: String) -> String {
    "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
}

@discardableResult
private func lzfseDecodeViaEquivalentCommand(input: String, outputFolder: String, parallel: Int) throws -> String {
    try FileManager.default.createDirectory(atPath: outputFolder, withIntermediateDirectories: true)
    guard FileManager.default.fileExists(atPath: windowsTarURL.path) else { throw LZFSEUIError.tarNotFound }

    let appDir = appExecutableFolder()
    let cliPath = appDir.appendingPathComponent("lzfse.exe").path
    guard FileManager.default.fileExists(atPath: cliPath) else {
        throw LZFSEUIError.tarFailed("missing packaged lzfse.exe next to LZFSE_UI_Win.exe: \(cliPath)")
    }

    let command = ".\\lzfse.exe -decode -i \(cmdArgQuote(input)) -n \(parallel) -so | tar -xf - -C \(cmdArgQuote(outputFolder))"
    let cmdPath = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("lzfse-ui-decode-\(UUID().uuidString).cmd")
    let listPath = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("lzfse-ui-tarlist-\(UUID().uuidString).txt")
    let outPath = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("lzfse-ui-cmdout-\(UUID().uuidString).txt")
    let errPath = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("lzfse-ui-cmderr-\(UUID().uuidString).txt")
    defer {
        try? FileManager.default.removeItem(atPath: cmdPath)
        try? FileManager.default.removeItem(atPath: listPath)
        try? FileManager.default.removeItem(atPath: outPath)
        try? FileManager.default.removeItem(atPath: errPath)
    }
    let script = """
    @echo off
    cd /d \(cmdArgQuote(appDir.path))
    .\\lzfse.exe -decode -i \(cmdArgQuote(input)) -n \(parallel) -so | tar -tf - > \(cmdArgQuote(listPath))
    if errorlevel 1 exit /b %ERRORLEVEL%
    findstr /b /c:"../" \(cmdArgQuote(listPath)) > nul
    if not errorlevel 1 (
        .\\lzfse.exe -decode -i \(cmdArgQuote(input)) -n \(parallel) -so | tar -xf - --strip-components 1 -C \(cmdArgQuote(outputFolder))
    ) else (
        \(command)
    )
    """
    try script.replacingOccurrences(of: "\n", with: "\r\n")
        .write(toFile: cmdPath, atomically: true, encoding: .utf8)
    // 用 CREATE_NO_WINDOW 啟動 cmd（不跳主控台視窗）；輸出在命令列重導向到檔案。
    // 外層加一對引號包住整個 /c 內容，讓 cmd 正確去引號後執行（含重導向）。
    // Launch cmd with CREATE_NO_WINDOW (no console window); redirect output to files on the
    // command line. The whole /c payload is wrapped in an extra pair of quotes so cmd strips
    // them and runs the redirection correctly.
    let cmdExe = "C:\\Windows\\System32\\cmd.exe"
    let inner = "\(cmdArgQuote(cmdPath)) > \(cmdArgQuote(outPath)) 2> \(cmdArgQuote(errPath))"
    let commandLine = "\(cmdArgQuote(cmdExe)) /d /c \"\(inner)\""
    let rc = runHiddenProcess(commandLine)

    let stdout = (try? String(contentsOfFile: outPath, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let stderr = (try? String(contentsOfFile: errPath, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if rc != 0 {
        let detail = [stderr, stdout].filter { !$0.isEmpty }.joined(separator: "\n")
        throw LZFSEUIError.tarFailed(detail.isEmpty ? "cmd exit \(rc)" : detail)
    }

    var note = "Extracted via packaged lzfse.exe -> \(outputFolder)"
    let detail = [stderr, stdout].filter { !$0.isEmpty }.joined(separator: "\n")
    if !detail.isEmpty { note += "\n[command output]\n\(detail)" }
    return note
}

private func lzfseFileOperation(
    input: String, output: String, encode: Bool,
    bvx3: Bool, lazy2: Bool, optimal: Bool, parallel: Int
) throws {
    let inputHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: input))
    defer { try? inputHandle.close() }
    _ = FileManager.default.createFile(atPath: output, contents: nil)
    let outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
    defer { try? outputHandle.close() }

    if encode {
        try runParallelEncode(
            input: inputHandle, output: outputHandle, inflight: parallel,
            strong: true, bvx3: bvx3, lazy2: lazy2, optimal: optimal)
    } else {
        try decode(inputPath: input, output: outputHandle, parallel: parallel)
    }
}

private func decode(inputPath: String, output: FileHandle, parallel: Int) throws {
    switch LZFSEv1.decodeStreamFromFile(
        path: inputPath, chunkRaw: LZFSEv1.parallelChunkSize,
        inflight: parallel, output: output
    ) {
    case .ok:
        break
    case .error:
        throw LZFSEUIError.decodeFailed
    case .fallback:
        var src = [UInt8]()
        let rh = try FileHandle(forReadingFrom: URL(fileURLWithPath: inputPath))
        defer { try? rh.close() }
        while let part = try rh.read(upToCount: 1 << 20), !part.isEmpty {
            src.append(contentsOf: part)
        }
        guard LZFSEv1.decodeStreamToHandle(
            src, parallel: true, chunkRaw: LZFSEv1.parallelChunkSize,
            inflight: parallel, output: output
        ) else {
            throw LZFSEUIError.decodeFailed
        }
    }
}

private func lzfseFolderEncode(
    input: String, output: String,
    bvx3: Bool, lazy2: Bool, optimal: Bool, parallel: Int
) throws {
    guard FileManager.default.fileExists(atPath: windowsTarURL.path) else { throw LZFSEUIError.tarNotFound }
    let url = URL(fileURLWithPath: input)
    let parent = url.deletingLastPathComponent().path
    let name = url.lastPathComponent

    let tar = Process()
    tar.executableURL = windowsTarURL
    tar.arguments = ["-cf", "-", "-C", parent, name]
    let pipe = Pipe()
    tar.standardOutput = pipe
    tar.standardError = FileHandle.nullDevice
    try tar.run()

    let inputHandle = pipe.fileHandleForReading
    _ = FileManager.default.createFile(atPath: output, contents: nil)
    let outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
    defer { try? outputHandle.close() }

    do {
        try runParallelEncode(
            input: inputHandle, output: outputHandle, inflight: parallel,
            strong: true, bvx3: bvx3, lazy2: lazy2, optimal: optimal)
    } catch {
        tar.terminate()
        throw error
    }
    tar.waitUntilExit()
    guard tar.terminationStatus == 0 else { throw LZFSEUIError.encodeFailed }
}

// UI decompression streams decoded tar payload directly to tar; no full .tar temp file.
// Streaming decode + content-based routing (no full temp tar file).
// The UI peeks the first 512 decoded bytes for the tar "ustar" magic at offset 257:
//   - tar payload: stream decoded bytes directly into `tar -x -f -`
//   - single file: stream decoded bytes to the output folder
@discardableResult
private func lzfseDecodeAuto(input: String, outputFolder: String, parallel: Int) throws -> String {
    try FileManager.default.createDirectory(atPath: outputFolder, withIntermediateDirectories: true)

    // 串流解碼 + 依內容自動判斷輸出型態（不需要全量暫存 tar 檔）。
    // 本 UI 的單檔與資料夾壓縮都命名為 .lzfse，單看副檔名無法分辨；
    // 故邊解碼邊偷看前 512 byte 的 tar 魔數（offset 257 的 "ustar"）：
    //   - 是 tar → 直接把解碼串流 pipe 給 `tar -x`
    //   - 否     → 視為單一檔案，串流寫入「輸出資料夾/去副檔名後的檔名」
    // Streaming decode + content-based routing (no full temp tar file).
    // Decode runs on a thread writing to a pipe; we peek the first 512 bytes for the tar
    // "ustar" magic at offset 257, then either pipe the stream straight into `tar -x`,
    // or stream it to a file.
    let decodePipe = Pipe()
    let decodeWrite = decodePipe.fileHandleForWriting
    let decodeRead = decodePipe.fileHandleForReading

    nonisolated(unsafe) var decodeError: Error?
    let decodeDone = DispatchSemaphore(value: 0)
    let decodeThread = Thread {
        do { try decode(inputPath: input, output: decodeWrite, parallel: parallel) }
        catch { decodeError = error }
        try? decodeWrite.close()   // EOF for the reader side
        decodeDone.signal()
    }
    decodeThread.stackSize = 4 << 20
    decodeThread.start()

    var head = Data()
    while head.count < 512 {
        guard let chunk = try? decodeRead.read(upToCount: 512 - head.count), !chunk.isEmpty else { break }
        head.append(chunk)
    }
    let isTar = head.count >= 262 && Array(head[257..<262]) == Array("ustar".utf8)

    func finishDecode() throws {
        decodeDone.wait()
        if let e = decodeError { throw e }
    }

    if isTar {
        guard FileManager.default.fileExists(atPath: windowsTarURL.path) else {
            try? decodeRead.close()
            decodeDone.wait()
            throw LZFSEUIError.tarNotFound
        }

        let tarIn = Pipe()
        let tarErr = Pipe()
        let tar = Process()
        tar.executableURL = windowsTarURL
        // -m：不還原 mtime；macOS 來源 tar 在 Windows 解壓常因無法套用權限/xattr 而回 exit 1（警告）
        // -m: don't restore mtime; macOS-origin tars often warn on Windows (perms/xattr can't apply).
        tar.arguments = ["-x", "-m", "-f", "-", "-C", outputFolder]
        tar.standardInput = tarIn
        tar.standardError = tarErr
        try tar.run()

        // 另一執行緒持續排空 tar stderr，避免其填滿而阻塞 tar
        // Drain tar stderr on its own thread so a full stderr pipe never blocks tar.
        nonisolated(unsafe) var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        let errThread = Thread {
            errData = tarErr.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        errThread.start()

        let tarWrite = tarIn.fileHandleForWriting
        try? tarWrite.write(contentsOf: head)
        while let chunk = try? decodeRead.read(upToCount: 1 << 20), !chunk.isEmpty {
            do { try tarWrite.write(contentsOf: chunk) }
            catch { break }   // tar 提早結束 → 停止灌入 / tar exited early → stop feeding
        }
        try? tarWrite.close()

        // 若 tar 提早結束，仍把 decode 串流讀盡，讓 decode 執行緒能乾淨收尾
        // If tar exits early, still drain the decoder pipe so the decode thread can finish cleanly.
        while let chunk = try? decodeRead.read(upToCount: 1 << 20), !chunk.isEmpty { _ = chunk }
        try? decodeRead.close()

        errDone.wait()
        tar.waitUntilExit()
        try finishDecode()

        let warn = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // bsdtar：0=成功，1=警告（檔案仍解出），>=2=致命錯誤
        // bsdtar: 0=success, 1=warnings (files still extracted), >=2=fatal
        if tar.terminationStatus >= 2 {
            throw LZFSEUIError.tarFailed(warn.isEmpty ? "exit \(tar.terminationStatus)" : warn)
        }
        var note = "Extracted (streamed) -> \(outputFolder)"
        if !warn.isEmpty { note += "\n[tar warnings]\n\(warn)" }
        return note
    } else {
        // 單一檔案：head + 其餘串流寫入「輸出資料夾/去副檔名檔名」
        // Single file: stream head + the rest to "<folder>/<stripped name>"
        let finalName = strippedDecodeName(input)
        let finalPath = (outputFolder as NSString).appendingPathComponent(finalName)
        try? FileManager.default.removeItem(atPath: finalPath)
        _ = FileManager.default.createFile(atPath: finalPath, contents: nil)
        let outHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: finalPath))
        var total = 0
        do {
            try outHandle.write(contentsOf: head)
            total += head.count
            while let chunk = try? decodeRead.read(upToCount: 1 << 20), !chunk.isEmpty {
                try outHandle.write(contentsOf: chunk)
                total += chunk.count
            }
            try? outHandle.close()
        } catch {
            try? outHandle.close()
            try? decodeRead.close()
            decodeDone.wait()
            throw error
        }
        try? decodeRead.close()
        try finishDecode()
        return "Wrote single file: \(finalName) (\(formatBytes(Int64(total))))"
    }
}


// 去除 lzfseX 副檔名得回原始檔名 / strip the lzfseX suffix to recover the original name
private func strippedDecodeName(_ inputPath: String) -> String {
    let name = URL(fileURLWithPath: inputPath).lastPathComponent
    for suffix in lzfseXSuffixes where name.hasSuffix(suffix) {
        let stripped = String(name.dropLast(suffix.count))
        return stripped.isEmpty ? "decompressed" : stripped
    }
    return name + ".out"
}

// MARK: - File helpers

private func fileSize(atPath path: String) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
}

private func directorySize(atPath path: String) -> Int64 {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
    if !isDir.boolValue { return fileSize(atPath: path) }
    guard let e = FileManager.default.enumerator(atPath: path) else { return 0 }
    var total: Int64 = 0
    for case let name as String in e {
        total += fileSize(atPath: (path as NSString).appendingPathComponent(name))
    }
    return total
}

private func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var idx = 0
    while value >= 1024 && idx < units.count - 1 {
        value /= 1024
        idx += 1
    }
    return idx == 0 ? "\(bytes) B" : String(format: "%.2f %@", value, units[idx])
}

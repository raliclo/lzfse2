//  lzfse-ui.swift — SwiftUI 圖形介面，用於 LZFSE 壓縮/解壓縮工具
//
//  編譯指令（從 lzfse-ui/ 目錄執行）：
//  swiftc -O ./opt/homebrew/bin/lzfse-cli.swift lzfse-ui.swift -o lzfse-ui -framework SwiftUI
//
//  或執行 ./build-ui.sh，或用 Xcode 新增 macOS App 專案包含兩個 Swift 檔
//

import SwiftUI
#if canImport(Compression)
import Compression
#endif

@main
struct LZFSEApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var viewModel = LZFSEViewModel()

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            ScrollView {
                VStack(spacing: 24) {
                    // Top row: left (operation + algorithm) | right (status panel)
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            operationSection
                            algorithmSection
                        }
                        .frame(minWidth: 280, maxWidth: 360)

                        statusView
                            .frame(maxWidth: .infinity)
                    }

                    fileSelectionSection
                    commandLineSection

                    if viewModel.isProcessing {
                        progressView
                    }

                }
                .padding(24)
            }
        }
        .frame(minWidth: 800, minHeight: 900)
    }

    // MARK: - Header
    private var headerView: some View {
        HStack {
            Image(systemName: "doc.zipper")
                .font(.system(size: 32))
                .foregroundStyle(.blue.gradient)
            VStack(alignment: .leading, spacing: 4) {
                Text("LZFSE Compression Tool")
                    .font(.title.bold())
                Text("位元相容 LZFSE 壓縮工具")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Operation Section
    private var operationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Operation / 操作")
                    .font(.headline)
                Picker("", selection: $viewModel.operation) {
                    Label("Compress / 壓縮", systemImage: "arrow.down.circle.fill")
                        .tag(LZFSEOperation.encode)
                    Label("Decompress / 解壓縮", systemImage: "arrow.up.circle.fill")
                        .tag(LZFSEOperation.decode)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

            }
            .padding(8)
        }
    }

    // MARK: - Algorithm Section
    private var algorithmSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // Algorithm picker + info (disabled during decode)
                Group {
                    Text("Compression Algorithm / 壓縮演算法")
                        .font(.headline)
                    Picker("Algorithm", selection: $viewModel.algorithm) {
                        Text("Apple (Standard)").tag(LZFSEAlgorithm.apple)
                        Text("Other3 (Enhanced)").tag(LZFSEAlgorithm.other3)
                        Text("BVX3 (Maximum Compression)").tag(LZFSEAlgorithm.bvx3)
                    }
                    .pickerStyle(.radioGroup)

                    VStack(alignment: .leading, spacing: 4) {
                        switch viewModel.algorithm {
                        case .apple:
                            InfoText("Uses system Compression framework. Standard compatibility.")
                            InfoText("使用系統壓縮框架。標準相容性。")
                        case .other3:
                            InfoText("Enhanced matching with better compression. Standard LZFSE format.")
                            InfoText("強化比對，更好的壓縮率。標準 LZFSE 格式。")
                        case .bvx3:
                            InfoText("Maximum compression with custom format. Only this tool can decompress.")
                            InfoText("最高壓縮率，自訂格式。僅本工具可解壓縮。")
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.top, 4)

                    if viewModel.operation == .encode && viewModel.algorithm == .bvx3 {
                        Divider()
                        Toggle("Lazy2 Mode / 雜湊鏈深搜", isOn: $viewModel.useLazy2)
                            .disabled(viewModel.useOptimal)
                        Text("Deep hash-chain search for better compression (slower)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Toggle("Optimal Parsing / 最優解析", isOn: $viewModel.useOptimal)
                        Text("Best compression ratio using DP (slowest)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(viewModel.operation == .decode)

                Divider()

                // Parallel Tasks — always enabled
                HStack {
                    Text("Parallel Tasks (n) / 並行任務數:")
                        .font(.subheadline)
                    Spacer()
                    TextField("", value: $viewModel.parallelTasks, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                    Text("(1–\(ProcessInfo.processInfo.processorCount * 10))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("Controls memory usage and parallelism")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
        }
    }

    // MARK: - File Selection Section
    private var fileSelectionSection: some View {
        let isDecoding = viewModel.operation == .decode
        let isFolder = viewModel.inputIsDirectory
        let isLzfseX = viewModel.inputIsLzfseXArchive
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Files / 檔案")
                    .font(.headline)

                // Input
                VStack(alignment: .leading, spacing: 8) {
                    Text(inputLabel(isDecoding: isDecoding, isFolder: isFolder))
                        .font(.subheadline)
                    HStack {
                        if let path = viewModel.inputFilePath {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    if isFolder {
                                        Image(systemName: "folder.fill")
                                            .foregroundColor(.blue)
                                            .font(.caption)
                                    }
                                    Text(URL(fileURLWithPath: path).lastPathComponent)
                                        .font(.body)
                                }
                                Text(path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("Clear") { viewModel.inputFilePath = nil }
                                .buttonStyle(.borderless)
                        } else {
                            Text(inputPlaceholder(isDecoding: isDecoding))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        Button(action: { viewModel.selectInputFile() }) {
                            Label(isDecoding ? "Select .lzfse" : "Select File/Folder",
                                  systemImage: isFolder ? "folder" : "doc")
                        }
                    }
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                }

                // Output
                VStack(alignment: .leading, spacing: 8) {
                    Text(outputLabel(isDecoding: isDecoding, isLzfseX: isLzfseX))
                        .font(.subheadline)
                    HStack {
                        if let path = viewModel.outputPath {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .font(.body)
                                Text(path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("Clear") { viewModel.outputPath = nil }
                                .buttonStyle(.borderless)
                        } else {
                            Text(isDecoding ? "No output folder selected / 未選擇輸出資料夾" : "No output selected / 未選擇輸出")
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        Button(action: { viewModel.selectOutputLocation() }) {
                            Label(isDecoding
                                  ? (isLzfseX ? "Select Extract Dir" : "Select Folder")
                                  : "Save As…",
                                  systemImage: "folder.badge.plus")
                        }
                    }
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                }

                if isDecoding && isLzfseX {
                    Divider()
                    InfoText("lzfseX archive detected — will extract via tar -xf - (matches extract() in zshrc.sh)")
                    InfoText("偵測到 lzfseX 壓縮包，將以 tar -xf - 解包（符合 extract() 行為）")
                }

                Divider()

                HStack(spacing: 12) {
                    Spacer()
                    Button("Reset / 重置") { viewModel.reset() }
                        .disabled(viewModel.isProcessing)
                    Button(action: { viewModel.process() }) {
                        Label(
                            viewModel.operation == .encode ? "Compress / 壓縮" : "Decompress / 解壓縮",
                            systemImage: viewModel.operation == .encode ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canProcess || viewModel.isProcessing)
                }
            }
            .padding(8)
        }
    }

    private func inputLabel(isDecoding: Bool, isFolder: Bool) -> String {
        if isDecoding { return "LZFSE Input File / 壓縮輸入檔:" }
        return isFolder ? "Input Folder / 輸入資料夾:" : "Input File / 輸入檔案:"
    }

    private func inputPlaceholder(isDecoding: Bool) -> String {
        isDecoding ? "No .lzfse file selected / 未選擇壓縮檔" : "No file or folder selected / 未選擇檔案或資料夾"
    }

    private func outputLabel(isDecoding: Bool, isLzfseX: Bool) -> String {
        if isDecoding && isLzfseX { return "Extract to Folder / 解壓縮目標資料夾:" }
        if isDecoding { return "Output Folder / 輸出資料夾:" }
        return "Output File / 壓縮輸出檔:"
    }

    // MARK: - Command Line Section
    private var commandLineSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Equivalent Command / 等效指令", systemImage: "terminal")
                        .font(.headline)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(viewModel.equivalentCommand, forType: .string)
                    } label: {
                        Label("Copy / 複製", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                Text(viewModel.equivalentCommand)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
            }
            .padding(8)
        }
    }

    // MARK: - Progress View
    private var progressView: some View {
        GroupBox {
            VStack(spacing: 12) {
                ProgressView().scaleEffect(0.8)
                Text(viewModel.progressMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }

    // MARK: - Status View
    private var statusView: some View {
        GroupBox {
            ScrollView {
                if viewModel.statusMessage.isEmpty {
                    Text("Output will appear here / 輸出結果顯示於此")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                } else {
                    Text(viewModel.statusMessage)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
            }
            .frame(maxHeight: .infinity)
        } label: {
            HStack {
                Label("Status / 狀態",
                      systemImage: viewModel.hasError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundColor(viewModel.hasError ? .orange : .blue)
                Spacer()
                if !viewModel.statusMessage.isEmpty {
                    Button("Clear") { viewModel.clearStatus() }
                        .buttonStyle(.borderless)
                }
            }
        }
    }
}

// MARK: - Helper View
struct InfoText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "info.circle").font(.caption)
            Text(text).font(.caption)
        }
        .foregroundColor(.secondary)
    }
}

// MARK: - View Model
@MainActor
class LZFSEViewModel: ObservableObject {
    @Published var operation: LZFSEOperation = .encode {
        didSet {
            guard operation != oldValue else { return }
            outputPath = nil
            if let path = inputFilePath {
                suggestOutputPath(for: URL(fileURLWithPath: path))
            }
        }
    }
    @Published var algorithm: LZFSEAlgorithm = .other3 {
        didSet { if inputIsDirectory && operation == .encode { updateDirectoryOutputPath() } }
    }
    @Published var parallelTasks: Int = 8 {
        didSet {
            let maxN = ProcessInfo.processInfo.processorCount * 10
            if parallelTasks < 1 { parallelTasks = 1 }
            else if parallelTasks > maxN { parallelTasks = maxN }
        }
    }
    @Published var useLazy2: Bool = false {
        didSet { if inputIsDirectory && operation == .encode { updateDirectoryOutputPath() } }
    }
    @Published var useOptimal: Bool = false {
        didSet { if inputIsDirectory && operation == .encode { updateDirectoryOutputPath() } }
    }
    @Published var inputFilePath: String?
    @Published var outputPath: String?

    @Published var isProcessing: Bool = false
    @Published var progressMessage: String = ""
    @Published var statusMessage: String = ""
    @Published var hasError: Bool = false

    private var rssTrackedPeak: Int64 = 0

    var canProcess: Bool { inputFilePath != nil && outputPath != nil }

    var inputIsDirectory: Bool {
        guard let path = inputFilePath else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // True when the input follows the lzfseX naming convention (.lzfse.algo),
    // meaning it was created by lzfseX (tar archive compressed with lzfse).
    // These must be extracted via `lzfse | tar -xf -`, matching extract() in zshrc.sh.
    var inputIsLzfseXArchive: Bool {
        guard let path = inputFilePath else { return false }
        return isLzfseXArchive(path)
    }

    private func isLzfseXArchive(_ path: String) -> Bool {
        let lzfseXSuffixes = [".lzfse.bvx3.optimal", ".lzfse.bvx3.lazy2", ".lzfse.bvx3",
                              ".lzfse.other3", ".lzfse.apple", ".lzfse"]
        return lzfseXSuffixes.contains { path.hasSuffix($0) }
    }

    var equivalentCommand: String {
        let input  = inputFilePath ?? "<input>"
        let output = outputPath    ?? "<output>"
        let n      = parallelTasks

        let algoFlag: String
        switch algorithm {
        case .apple:  algoFlag = "-algo apple"
        case .other3: algoFlag = "-algo other3"
        case .bvx3:
            if useOptimal      { algoFlag = "-algo bvx3 -optimal" }
            else if useLazy2   { algoFlag = "-algo bvx3 -lazy2" }
            else               { algoFlag = "-algo bvx3" }
        }

        if operation == .encode {
            if inputIsDirectory {
                let url    = URL(fileURLWithPath: input)
                let parent = url.deletingLastPathComponent().path
                let name   = url.lastPathComponent
                return "tar -cf - -C \"\(parent)\" \"\(name)\" \\\n  | /opt/homebrew/bin/lzfse -encode \(algoFlag) -si -o \"\(output)\" -n \(n)"
            } else {
                return "/opt/homebrew/bin/lzfse -encode \(algoFlag) -i \"\(input)\" -o \"\(output)\" -n \(n)"
            }
        } else {
            if inputIsLzfseXArchive {
                return "/opt/homebrew/bin/lzfse -decode -i \"\(input)\" -n \(n) -so | tar -xf - -C \"\(output)\""
            } else {
                return "/opt/homebrew/bin/lzfse -decode -i \"\(input)\" -o \"\(output)\" -n \(n)"
            }
        }
    }

    // Returns the lzfseX-convention extension for the current algorithm/flags.
    // e.g. "lzfse.other3", "lzfse.bvx3.lazy2"
    private func lzfseExtension() -> String {
        switch algorithm {
        case .apple:  return "lzfse"
        case .other3: return "lzfse"
        case .bvx3:
            if useOptimal { return "lzfse" }
            if useLazy2   { return "lzfse" }
            return "lzfse"
        }
    }

    // Keeps directory output path in sync when algorithm/flags change.
    private func updateDirectoryOutputPath() {
        guard let path = inputFilePath else { return }
        outputPath = path + "." + lzfseExtension()
    }

    // MARK: - File Selection

    func selectInputFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true

        if operation == .decode {
            panel.canChooseDirectories = false
            panel.title = "Select LZFSE File / 選擇 LZFSE 壓縮檔 (.lzfse, .lzfse.apple, .lzfse.bvx3 …)"
            panel.prompt = "Select / 選擇"
            // No content-type filter: compound suffixes like .lzfse.apple, .lzfse.other3
            // would be rejected if we filter by extension "lzfse" alone.
        } else {
            panel.canChooseDirectories = true
            panel.title = "Select File or Folder to Compress / 選擇要壓縮的檔案或資料夾"
            panel.prompt = "Select / 選擇"
        }

        if panel.runModal() == .OK, let url = panel.url {
            inputFilePath = url.path
            if outputPath == nil {
                suggestOutputPath(for: url)
            }
        }
    }

    func selectOutputLocation() {
        if operation == .decode {
            // Decode: always a folder picker, matching extract() in zshrc.sh.
            // lzfseX archives (.lzfse.algo) → tar is extracted INTO the chosen folder.
            // Plain .lzfse → decoded file is placed INSIDE the chosen folder.
            let panel = NSOpenPanel()
            panel.title = inputIsLzfseXArchive
                ? "Select Extraction Directory / 選擇解壓縮目標目錄 (tar 解包位置)"
                : "Select Output Folder / 選擇輸出資料夾"
            panel.prompt = "Select / 選擇"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url {
                if inputIsLzfseXArchive {
                    outputPath = url.path
                } else {
                    outputPath = url.appendingPathComponent(generateOutputFileName()).path
                }
            }
        } else {
            let panel = NSSavePanel()
            panel.prompt = "Save / 儲存"
            panel.nameFieldStringValue = generateOutputFileName()
            panel.title = "Save Compressed File / 儲存壓縮檔案"
            if panel.runModal() == .OK, let url = panel.url {
                outputPath = url.path
            }
        }
    }

    private func suggestOutputPath(for inputURL: URL) {
        var isDir: ObjCBool = false
        let isDirectory = FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDir) && isDir.boolValue

        if operation == .encode {
            if isDirectory {
                // lzfseX convention: <folder>.<algo-ext>
                outputPath = inputURL.path + "." + lzfseExtension()
            } else {
                outputPath = inputURL.path + ".lzfse"
            }
        } else {
            // Decode: follow extract() convention
            if isLzfseXArchive(inputURL.path) {
                // lzfseX archive: suggest the same directory as the archive.
                // tar will recreate the original folder name inside this directory.
                outputPath = inputURL.deletingLastPathComponent().path
            } else {
                // Plain .lzfse: suggest parent dir + stripped filename
                let stripped = inputURL.lastPathComponent.hasSuffix(".lzfse")
                    ? String(inputURL.lastPathComponent.dropLast(".lzfse".count))
                    : inputURL.lastPathComponent
                outputPath = inputURL.deletingLastPathComponent()
                    .appendingPathComponent(stripped).path
            }
        }
    }

    private func generateOutputFileName() -> String {
        guard let inputPath = inputFilePath else {
            return operation == .encode ? "compressed.lzfse" : "decompressed"
        }
        let inputURL = URL(fileURLWithPath: inputPath)
        var isDir: ObjCBool = false
        let isDirectory = FileManager.default.fileExists(atPath: inputPath, isDirectory: &isDir) && isDir.boolValue

        if operation == .encode {
            return isDirectory
                ? inputURL.lastPathComponent + "." + lzfseExtension()
                : inputURL.lastPathComponent + ".lzfse"
        } else {
            let name = inputURL.lastPathComponent
            for suffix in [".lzfse.bvx3.optimal", ".lzfse.bvx3.lazy2", ".lzfse.bvx3",
                           ".lzfse.other3", ".lzfse.apple", ".lzfse"] {
                if name.hasSuffix(suffix) {
                    return String(name.dropLast(suffix.count))
                }
            }
            return name
        }
    }

    // MARK: - Process

    func process() {
        guard let inputPath = inputFilePath,
              let outputPath = outputPath else {
            showError("Please select input and output / 請選擇輸入與輸出")
            return
        }

        isProcessing = true
        hasError = false
        progressMessage = operation == .encode ? "Compressing... / 壓縮中..." : "Decompressing... / 解壓縮中..."
        statusMessage = ""

        Task {
            do {
                let startTime = Date()
                let rssBefore = currentRSS()
                rssTrackedPeak = rssBefore

                // Poll phys_footprint every 5 ms to capture peak during operation
                let pollTask = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self else { return }
                        let rss = self.currentRSS()
                        if rss > self.rssTrackedPeak { self.rssTrackedPeak = rss }
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                }

                do {
                    try await performOperation(
                        inputPath: inputPath,
                        outputPath: outputPath,
                        operation: operation,
                        algorithm: algorithm,
                        parallelTasks: parallelTasks,
                        useLazy2: useLazy2,
                        useOptimal: useOptimal,
                        isDirectory: inputIsDirectory
                    )
                } catch {
                    pollTask.cancel()
                    throw error
                }
                pollTask.cancel()
                let rssAfter = currentRSS()
                if rssAfter > rssTrackedPeak { rssTrackedPeak = rssAfter }

                let elapsed = Date().timeIntervalSince(startTime)
                let rssDelta = max(rssTrackedPeak - rssBefore, 0)

                var message = "✓ Success! / 成功！\n\n"
                if operation == .encode {
                    let inputSize = fileSizeOrDirectorySize(atPath: inputPath)
                    let outputSize = fileSize(atPath: outputPath)
                    message += "Input size / 輸入大小: \(formatBytes(inputSize))\n"
                    message += "Output size / 輸出大小: \(formatBytes(outputSize))\n"
                    let ratio = inputSize > 0 ? Double(outputSize) / Double(inputSize) * 100 : 0
                    message += "Compression ratio / 壓縮率: \(String(format: "%.2f%%", ratio))\n"
                } else {
                    let inputSize = fileSize(atPath: inputPath)
                    message += "Archive size / 壓縮檔大小: \(formatBytes(inputSize))\n"
                }
                message += "Peak RSS / 峰值記憶體: \(formatBytes(rssDelta))\n"
                message += "Time elapsed / 耗時: \(String(format: "%.2f", elapsed)) seconds\n"
                message += "Output / 輸出: \(outputPath)"

                showStatus(message)

            } catch {
                showError("Error / 錯誤: \(error.localizedDescription)")
            }

            isProcessing = false
            progressMessage = ""
        }
    }

    private func performOperation(
        inputPath: String,
        outputPath: String,
        operation: LZFSEOperation,
        algorithm: LZFSEAlgorithm,
        parallelTasks: Int,
        useLazy2: Bool,
        useOptimal: Bool,
        isDirectory: Bool
    ) async throws {
        if operation == .encode && isDirectory {
            try await performFolderEncode(
                inputPath: inputPath, outputPath: outputPath,
                algorithm: algorithm, parallelTasks: parallelTasks,
                useLazy2: useLazy2, useOptimal: useOptimal)
        } else if operation == .decode && isLzfseXArchive(inputPath) {
            // extract() convention: lzfse | tar -xf - -C outputPath
            try await performFolderDecode(
                inputPath: inputPath, extractDir: outputPath,
                parallelTasks: parallelTasks)
        } else {
            try await performFileOperation(
                inputPath: inputPath, outputPath: outputPath,
                operation: operation, algorithm: algorithm,
                parallelTasks: parallelTasks, useLazy2: useLazy2,
                useOptimal: useOptimal)
        }
    }

    // MARK: - File Encode/Decode (single file)

    private func performFileOperation(
        inputPath: String,
        outputPath: String,
        operation: LZFSEOperation,
        algorithm: LZFSEAlgorithm,
        parallelTasks: Int,
        useLazy2: Bool,
        useOptimal: Bool
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let inputHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: inputPath))
            defer { try? inputHandle.close() }

            FileManager.default.createFile(atPath: outputPath, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
            defer { try? outputHandle.close() }

            switch (operation, algorithm) {
            case (.encode, .apple):
                #if canImport(Compression)
                try Self.processWithAppleCompression(input: inputHandle, output: outputHandle, encode: true)
                #else
                throw LZFSEError.unsupported("Apple Compression framework not available")
                #endif

            case (.encode, .other3), (.encode, .bvx3):
                try runParallelEncode(
                    input: inputHandle,
                    output: outputHandle,
                    inflight: parallelTasks,
                    strong: true,
                    bvx3: algorithm == .bvx3,
                    lazy2: algorithm == .bvx3 && useLazy2 && !useOptimal,
                    optimal: algorithm == .bvx3 && useOptimal)

            case (.decode, _):
                switch LZFSEv1.decodeStreamFromFile(
                    path: inputPath,
                    chunkRaw: LZFSEv1.parallelChunkSize,
                    inflight: parallelTasks,
                    output: outputHandle) {
                case .ok:
                    break
                case .error:
                    throw LZFSEError.decodeFailed
                case .fallback:
                    var src = [UInt8]()
                    let rh = try FileHandle(forReadingFrom: URL(fileURLWithPath: inputPath))
                    defer { try? rh.close() }
                    while let part = try rh.read(upToCount: 1 << 20), !part.isEmpty {
                        src.append(contentsOf: part)
                    }
                    guard LZFSEv1.decodeStreamToHandle(
                        src, parallel: true,
                        chunkRaw: LZFSEv1.parallelChunkSize,
                        inflight: parallelTasks,
                        output: outputHandle) else {
                        throw LZFSEError.decodeFailed
                    }
                }
            }
        }.value
    }

    // MARK: - Folder Encode (tar | lzfse, matching lzfseX convention)

    private func performFolderEncode(
        inputPath: String,
        outputPath: String,
        algorithm: LZFSEAlgorithm,
        parallelTasks: Int,
        useLazy2: Bool,
        useOptimal: Bool
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            // Build: tar -cf - -C <parent> <name> | lzfse -encode -si -o <output>
            let inputURL = URL(fileURLWithPath: inputPath)
            let parentDir = inputURL.deletingLastPathComponent().path
            let folderName = inputURL.lastPathComponent

            let tarProcess = Process()
            tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tarProcess.arguments = ["-cf", "-", "-C", parentDir, folderName]
            let tarPipe = Pipe()
            tarProcess.standardOutput = tarPipe
            tarProcess.standardError = FileHandle.nullDevice
            try tarProcess.run()

            let inputHandle = tarPipe.fileHandleForReading
            FileManager.default.createFile(atPath: outputPath, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
            defer { try? outputHandle.close() }

            do {
                switch algorithm {
                case .apple:
                    #if canImport(Compression)
                    try Self.processWithAppleCompression(input: inputHandle, output: outputHandle, encode: true)
                    #else
                    throw LZFSEError.unsupported("Apple Compression framework not available")
                    #endif
                case .other3, .bvx3:
                    try runParallelEncode(
                        input: inputHandle,
                        output: outputHandle,
                        inflight: parallelTasks,
                        strong: true,
                        bvx3: algorithm == .bvx3,
                        lazy2: algorithm == .bvx3 && useLazy2 && !useOptimal,
                        optimal: algorithm == .bvx3 && useOptimal)
                }
            } catch {
                tarProcess.terminate()
                throw error
            }

            tarProcess.waitUntilExit()
            guard tarProcess.terminationStatus == 0 else {
                throw LZFSEError.encodeFailed
            }
        }.value
    }

    // MARK: - Folder Decode (lzfse | tar -xf -)

    private func performFolderDecode(
        inputPath: String,
        extractDir: String,
        parallelTasks: Int
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            // Ensure extraction directory exists
            try FileManager.default.createDirectory(
                atPath: extractDir,
                withIntermediateDirectories: true)

            let decodePipe = Pipe()
            let tarProcess = Process()
            tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tarProcess.arguments = ["-xf", "-", "-C", extractDir]
            tarProcess.standardInput = decodePipe
            tarProcess.standardError = FileHandle.nullDevice
            try tarProcess.run()

            let outputHandle = decodePipe.fileHandleForWriting

            var decodeError: Error?
            switch LZFSEv1.decodeStreamFromFile(
                path: inputPath,
                chunkRaw: LZFSEv1.parallelChunkSize,
                inflight: parallelTasks,
                output: outputHandle) {
            case .ok:
                break
            case .error:
                decodeError = LZFSEError.decodeFailed
            case .fallback:
                var src = [UInt8]()
                do {
                    let rh = try FileHandle(forReadingFrom: URL(fileURLWithPath: inputPath))
                    defer { try? rh.close() }
                    while let part = try rh.read(upToCount: 1 << 20), !part.isEmpty {
                        src.append(contentsOf: part)
                    }
                    let ok = LZFSEv1.decodeStreamToHandle(
                        src, parallel: true,
                        chunkRaw: LZFSEv1.parallelChunkSize,
                        inflight: parallelTasks,
                        output: outputHandle)
                    if !ok { decodeError = LZFSEError.decodeFailed }
                } catch {
                    decodeError = error
                }
            }

            // Always close write end so tar can finish
            try? outputHandle.close()
            tarProcess.waitUntilExit()

            if let e = decodeError { throw e }
            guard tarProcess.terminationStatus == 0 else {
                throw LZFSEError.decodeFailed
            }
        }.value
    }

    // MARK: - Apple Compression (single-file encode/decode via system framework)

    #if canImport(Compression)
    nonisolated private static func processWithAppleCompression(
        input: FileHandle,
        output: FileHandle,
        encode: Bool
    ) throws {
        let operation: FilterOperation = encode ? .compress : .decompress
        let filter = try OutputFilter(operation, using: .lzfse) { (data: Data?) in
            if let data = data { output.write(data) }
        }
        let chunkSize = 64 * 1024
        while let data = try input.read(upToCount: chunkSize), !data.isEmpty {
            try filter.write(data)
        }
        try filter.finalize()
    }
    #endif

    // MARK: - Helpers

    func reset() {
        inputFilePath = nil
        outputPath = nil
        statusMessage = ""
        hasError = false
    }

    func clearStatus() {
        statusMessage = ""
        hasError = false
    }

    private func showStatus(_ message: String) { statusMessage = message; hasError = false }
    private func showError(_ message: String) { statusMessage = message; hasError = true }

    private func fileSize(atPath path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
    }

    private func fileSizeOrDirectorySize(atPath path: String) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return fileSize(atPath: path) }
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for case let name as String in enumerator {
            let full = (path as NSString).appendingPathComponent(name)
            total += fileSize(atPath: full)
        }
        return total
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // phys_footprint = live physical memory (Activity Monitor "Memory" column); not a high-water mark
    private func currentRSS() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}

// MARK: - Models
enum LZFSEOperation { case encode, decode }
enum LZFSEAlgorithm { case apple, other3, bvx3 }

// MARK: - Preview
// Note: #Preview macro requires Xcode toolchain; use Xcode to view SwiftUI previews.

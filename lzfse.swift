import Foundation
import Compression

// Compile with "swiftc lzfse.swift -o lzfse"
/// 顯示使用說明 / Display usage instructions
func printUsage() {
    print("""
    Usage: lzfse -encode|-decode [-si|-i input] [-so|-o output] [-h]
    
    Commands:
      -encode    : Compress the input / 壓縮輸入內容
      -decode    : Decompress the input / 解壓縮輸入內容
    
    Options:
      -i <path>  : Input file path / 指定輸入檔案路徑
      -o <path>  : Output file path / 指定輸出檔案路徑
      -si        : Read from stdin / 從標準輸入讀取
      -so        : Write to stdout / 輸出至標準輸出
    """)
}

// 1. 解析參數 / Parse arguments
let args = CommandLine.arguments
if args.contains("-h") || args.count < 2 {
    printUsage()
    exit(0)
}

let isEncoding = args.contains("-encode")
let operation: FilterOperation = isEncoding ? .compress : .decompress

// 2. 設定輸入源 / Set up input source
let inputHandle: FileHandle
if args.contains("-si") {
    inputHandle = .standardInput
} else if let index = args.firstIndex(of: "-i"), index + 1 < args.count {
    let path = args[index + 1]
    inputHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
} else {
    print("Error: Input source not specified. / 錯誤：未指定輸入源。")
    exit(1)
}

// 3. 設定輸出目標 / Set up output destination
let outputHandle: FileHandle
if args.contains("-so") {
    outputHandle = .standardOutput
} else if let index = args.firstIndex(of: "-o"), index + 1 < args.count {
    let path = args[index + 1]
    // 建立檔案 (若不存在) / Create file if it doesn't exist
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
} else {
    print("Error: Output destination not specified. / 錯誤：未指定輸出目標。")
    exit(1)
}

// 4. 處理壓縮/解壓縮串流 / Process compression/decompression stream
do {
    // 建立 OutputFilter 以處理串流 / Create OutputFilter for stream processing
    let filter = try OutputFilter(operation, using: .lzfse) { (data: Data?) in
        if let data = data {
            outputHandle.write(data)
        }
    }
    
    // 循環讀取與寫入 / Read and write in chunks
    let chunkSize = 64 * 1024 // 64KB
    while let data = try inputHandle.read(upToCount: chunkSize), !data.isEmpty {
        try filter.write(data)
    }
    
    // 完成處理 / Finalize processing
    try filter.finalize()
    
} catch {
    print("Error during processing: \(error) / 處理時發生錯誤: \(error)")
    exit(1)
}

// 關閉檔案句柄 / Close file handles
try? inputHandle.close()
try? outputHandle.close()
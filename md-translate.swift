import Foundation
import Translation

// Markdown 翻譯器（預設 繁中 → 英文），I/O 旗標仿 lzfse-cli.swift。
// 編譯（單檔 script，top-level await）：
//   swiftc -O md-translate.swift -o md-translate
// 用法：
//   ./md-translate -i OPTIMIZATION.md -o OPTIMIZATION-en.md
//   cat OPTIMIZATION.md | ./md-translate -si -so > OPTIMIZATION-en.md
//   ./md-translate -i in.md -o out.md -from zh-Hant -to en
// 旗標：
//   -si        從 stdin 讀入            -i <path>  從檔案讀入
//   -so        寫到 stdout              -o <path>  寫到檔案
//   -from <l>  來源語言（預設 zh-Hant） -to <l>    目標語言（預設 en）
// 需先安裝來源/目標翻譯語言（設定 → 一般 → 語言與地區 → 翻譯語言）。
// 注意：診斷訊息一律走 stderr，故 -so 的標準輸出只有翻譯結果。

let args = CommandLine.arguments

@inline(__always) func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}
func argValue(_ flag: String) -> String? {
    if let i = args.firstIndex(of: flag), i + 1 < args.count { return args[i + 1] }
    return nil
}

let usage = """
md-translate — Markdown translator (Apple Translation framework, default zh-Hant -> en)

Usage: md-translate [-si | -i <in>] [-so | -o <out>] [-from <lang>] [-to <lang>] [-h]

  -i <path>     read input from file       -si   read input from stdin
  -o <path>     write output to file       -so   write output to stdout
  -from <lang>  source language (default zh-Hant)
  -to   <lang>  target language (default en)
  -h            show this help

Passed through untouched (not translated): empty lines and fenced code blocks
(``` ... ```).

Special case (README language switcher): a line equal to
  English | [繁體中文](README.zh-TW.md) or   [English](README.md) | 繁體中文
  Will be replaced with the corresponding version in the target language, without translation.

Diagnostics go to stderr, so -so output contains only the translated text.
"""

if args.contains("-h") || args.contains("--help") {
    print(usage)
    exit(0)
}

let source = Locale.Language(identifier: argValue("-from") ?? "zh-Hant")
let target = Locale.Language(identifier: argValue("-to") ?? "en")

// ── 輸入來源（-si / -i） ──
let content: String
if args.contains("-si") {
    let data = ((try? FileHandle.standardInput.readToEnd()) ?? nil) ?? Data()
    content = String(data: data, encoding: .utf8) ?? ""
} else if let p = argValue("-i") {
    guard let c = try? String(contentsOf: URL(fileURLWithPath: p), encoding: .utf8) else {
        eprint("Error: cannot read input \(p)"); exit(1)
    }
    content = c
} else {
    eprint(usage)
    exit(1)
}

// ── 輸出目標必須先指定（-so / -o），免得翻完才發現沒地方寫 ──
let useStdout = args.contains("-so")
let outPath = argValue("-o")
if !useStdout && outPath == nil {
    eprint("Error: output not specified (use -so or -o <out>)"); exit(1)
}

// ── 可用性診斷（stderr） ──
let availability = LanguageAvailability()
let status = await availability.status(from: source, to: target)
eprint("status=\(status)  (\(source.languageCode?.identifier ?? "?") -> \(target.languageCode?.identifier ?? "?"))")

// README 頂部語言切換列：固定替換、不送翻譯（避免翻譯器把連結/語言名弄亂）。
// 雙向：偵測任一語言版本的切換列，一律替換成「目標語言」對應的版本。
let switcherEN = "English | [繁體中文](README.zh-TW.md)"   // 英文版 README.md
let switcherZH = "[English](README.md) | 繁體中文"          // 繁中版 README.zh-TW.md
let switcherTarget = (target.languageCode?.identifier ?? "").hasPrefix("zh") ? switcherZH : switcherEN

// 不含漢字的反引號區段是命令、路徑或識別字；先換成無語意標記，翻譯後再還原。
// Non-Han backtick spans contain commands, paths, or identifiers. Protect and restore them verbatim.
func protectInlineCode(_ line: String) -> (text: String, spans: [String]) {
    let regex = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
    let matches = regex.matches(in: line, range: fullRange).compactMap { match -> (range: NSRange, span: String)? in
        guard let range = Range(match.range, in: line) else { return nil }
        let span = String(line[range])
        guard span.range(of: #"\p{Han}"#, options: .regularExpression) == nil else { return nil }
        return (match.range, span)
    }
    var protected = line
    let spans = matches.map { $0.span }   // 注意：key-path \.span 不支援 tuple 成員，須用 closure
    for (index, match) in matches.enumerated().reversed() {
        guard let range = Range(match.range, in: protected) else { continue }
        protected.replaceSubrange(range, with: "ZXQMDTOKEN\(index)QXZ")
    }
    return (protected, spans)
}

// ── 切行；跳過空行、程式碼圍欄與其內部 ──
let lines = content.components(separatedBy: "\n")
var out = lines
var translatable: [(idx: Int, original: String, text: String, spans: [String])] = []
var inCode = false
for (i, line) in lines.enumerated() {
    let t = line.trimmingCharacters(in: .whitespaces)
    if t == switcherEN || t == switcherZH {
        out[i] = switcherTarget
        continue
    }
    if t.hasPrefix("```") { inCode.toggle(); continue }
    if inCode || t.isEmpty { continue }
    let protected = protectInlineCode(line)
    translatable.append((i, line, protected.text, protected.spans))
}
eprint("lines=\(lines.count) translatable=\(translatable.count)")
let inlineSpans = Dictionary(uniqueKeysWithValues: translatable.map { ($0.idx, $0.spans) })
let originalLines = Dictionary(uniqueKeysWithValues: translatable.map { ($0.idx, $0.original) })

// ── 最終空格正規化（對所有翻譯輸出行套用，marker 與 fallback 路徑一致）──
// 解析 inline-code span（`...`），只在「span 外部 prose 字元 ↔ 反引號邊界」相鄰時補/維持一個空格；
// 不動 span 內容、已有空格不重複（idempotent）。規則：英數或標點 ↔ 反引號補空格，
// 但 span 後緊接收尾標點 (. , ; : ! ? ) ] } 等) 不補（避免 `code` . 這種怪輸出）。
func isGlue(_ c: Character) -> Bool { c.isLetter || c.isNumber || c.isPunctuation }
let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "'", "\""]
let spanRegex = try! NSRegularExpression(pattern: "`[^`\\n]+`")
func normalizeSpacing(_ line: String) -> String {
    guard line.contains("`") else { return line }
    let ns = line as NSString
    var result = ""
    func add(_ s: String) {
        if let lastC = result.last, let firstC = s.first {
            let beforeSpan = isGlue(lastC) && firstC == "`"
            let afterSpan  = lastC == "`" && isGlue(firstC) && !trailing.contains(firstC)
            if beforeSpan || afterSpan { result += " " }
        }
        result += s
    }
    var idx = 0
    for m in spanRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
        let r = m.range
        if r.location > idx {
            add(ns.substring(with: NSRange(location: idx, length: r.location - idx)))
        }
        add(ns.substring(with: r))
        idx = r.location + r.length
    }
    if idx < ns.length { add(ns.substring(from: idx)) }
    return result
}

// ── 批次翻譯（clientIdentifier=行號 對回；回應順序可能與請求不同） ──
let session = TranslationSession(installedSource: source, target: target)
do { try await session.prepareTranslation() } catch { eprint("prepare warn=\(error)") }

let chunkSize = 64
var done = 0, translated = 0
while done < translatable.count {
    let slice = translatable[done ..< min(done + chunkSize, translatable.count)]
    let requests = slice.map {
        TranslationSession.Request(sourceText: $0.text, clientIdentifier: "\($0.idx)")
    }
    do {
        let responses = try await session.translations(from: requests)
        for r in responses {
            if let cid = r.clientIdentifier, let li = Int(cid) {
                var translatedText = r.targetText
                var markersIntact = true
                for (index, span) in (inlineSpans[li] ?? []).enumerated() {
                    let marker = "ZXQMDTOKEN\(index)QXZ"
                    if !translatedText.contains(marker) { markersIntact = false }
                    translatedText = translatedText.replacingOccurrences(
                        of: marker,
                        with: span
                    )
                }
                // 翻譯器可能複製/拆裂 marker，完整 marker 雖被還原，仍可能殘留碎片
                // （如 "ZXQMDTOKEN" / "QXZ"）。偵測到任何碎片 → 視為損壞，改走逐段重組 fallback。
                if translatedText.contains("ZXQMDTOKEN") || translatedText.contains("QXZ") {
                    markersIntact = false
                }
                if !markersIntact, let original = originalLines[li] {
                    // 極長且含多個 inline-code 的行可能改寫 marker；改成逐段翻譯後重組。
                    // Very long lines may rewrite markers; translate prose segments and reassemble.
                    // 逐段重組（直接相接；空格交給下方 normalizeSpacing 統一處理）。
                    var remaining = original
                    var rebuilt = ""
                    for span in inlineSpans[li] ?? [] {
                        guard let range = remaining.range(of: span) else { continue }
                        let prose = String(remaining[..<range.lowerBound])
                        if !prose.isEmpty { rebuilt += try await session.translate(prose).targetText }
                        rebuilt += span
                        remaining = String(remaining[range.upperBound...])
                    }
                    if !remaining.isEmpty { rebuilt += try await session.translate(remaining).targetText }
                    translatedText = rebuilt
                    eprint("inline fallback line=\(li + 1)")
                }
                out[li] = normalizeSpacing(translatedText)
                translated += 1
            }
        }
    } catch {
        eprint("chunk @\(done) error=\(error)")   // 該批保留原文，繼續
    }
    done += chunkSize
    eprint("progress \(min(done, translatable.count))/\(translatable.count)")
}

// ── 輸出（-so / -o） ──
let result = out.joined(separator: "\n")
if useStdout {
    FileHandle.standardOutput.write(Data(result.utf8))
    eprint("done; translated \(translated)/\(translatable.count) lines -> stdout")
} else if let p = outPath {
    do {
        try result.write(toFile: p, atomically: true, encoding: .utf8)
        eprint("wrote \(p); translated \(translated)/\(translatable.count) lines")
    } catch {
        eprint("write error=\(error)"); exit(1)
    }
}

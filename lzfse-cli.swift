//
//  lzfse-cli.swift — 位元相容 LZFSE 實作 + 命令列工具
//
//  Compile: swiftc -O lzfse-cli.swift -o lzfse
//
//  位元相容的 LZFSE 實作
//  編碼：bvx2（壓縮標頭）/ bvx-（raw）/ bvx$；單流（other）或分塊平行（other2）
//  解碼：全部區塊型別 bvx1 / bvx2（壓縮標頭）/ bvxn（LZVN）/ bvx- / bvx$
//        —— 包含 Apple 編碼器產出的串流
//
//  逐段對照 lzfse/lzfse 參考實作：
//    - 區塊魔數、v1 標頭、L/M/D 常數表  ← lzfse_internal.h
//    - FSE 位元流與編解碼核心            ← lzfse_fse.h / lzfse_fse.c
//    - 區塊編碼流程（4 路交錯 literal、D→M→L 反序 LMD、v2 標頭） ← lzfse_encode_base.c
//    - 區塊解碼流程                       ← lzfse_decode_base.c
//
//  本階段輸出 bvx1（未壓縮頻率表）壓縮區塊 + bvx- 原始區塊 + bvx$ 結尾，
//  目標：產出的串流可被 Apple Compression framework / 參考解碼器直接解開；
//  解碼器涵蓋所有區塊型別，因此 Apple 編碼器的輸出（bvx2/bvxn）也可解。
//
//  授權：BSD-3-Clause（衍生自 Apple lzfse 參考實作之格式定義）
//

import Foundation
#if canImport(Compression)
import Compression
#endif

public enum LZFSEv1 {

    // =================================================================
    // MARK: - 常數（lzfse_internal.h）
    // =================================================================

    // 區塊魔數
    static let magicEndOfStream: UInt32 = 0x24787662 // 'bvx$'
    static let magicUncompressed: UInt32 = 0x2d787662 // 'bvx-'
    static let magicCompressedV1: UInt32 = 0x31787662 // 'bvx1'
    static let magicCompressedV2: UInt32 = 0x32787662 // 'bvx2'（本階段不產出）
    static let magicLZVN: UInt32 = 0x6e787662          // 'bvxn'（本階段不產出）

    // 符號數與狀態數
    static let lSymbols = 20, lStates = 64
    static let mSymbols = 20, mStates = 64
    static let dSymbols = 64, dStates = 256
    static let literalSymbols = 256, literalStates = 1024

    // 每區塊上限
    static let matchesPerBlock = 10000
    static let literalsPerBlock = 4 * matchesPerBlock

    // L/M/D 可編碼上限
    static let maxLValue = 315
    static let maxMValue = 2359
    static let maxDValue = 262139

    // v1 標頭大小 = C struct lzfse_compressed_block_header_v1 的 sizeof
    // 欄位合計 770 bytes，結構對齊 4 → 尾端補 2 bytes = 772
    static let v1HeaderSize = 772

    // =================================================================
    // MARK: - L/M/D base / extra-bits 表（lzfse_internal.h 原值照搬）
    // =================================================================

    static let lExtraBits: [UInt8] = [
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 2,3,5,8
    ]
    static let lBaseValue: [Int32] = [
        0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15, 16,20,28,60
    ]
    static let mExtraBits: [UInt8] = [
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 3,5,8,11
    ]
    static let mBaseValue: [Int32] = [
        0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15, 16,24,56,312
    ]
    static let dExtraBits: [UInt8] = [
        0,0,0,0, 1,1,1,1, 2,2,2,2, 3,3,3,3,
        4,4,4,4, 5,5,5,5, 6,6,6,6, 7,7,7,7,
        8,8,8,8, 9,9,9,9, 10,10,10,10, 11,11,11,11,
        12,12,12,12, 13,13,13,13, 14,14,14,14, 15,15,15,15
    ]
    static let dBaseValue: [Int32] = [
        0, 1, 2, 3, 4, 6, 8, 10, 12, 16,
        20, 24, 28, 36, 44, 52, 60, 76, 92, 108,
        124, 156, 188, 220, 252, 316, 380, 444, 508, 636,
        764, 892, 1020, 1276, 1532, 1788, 2044, 2556, 3068, 3580,
        4092, 5116, 6140, 7164, 8188, 10236, 12284, 14332, 16380, 20476,
        24572, 28668, 32764, 40956, 49148, 57340, 65532, 81916, 98300, 114684,
        131068, 163836, 196604, 229372
    ]

    /// value → symbol：找出 base ≤ value 的最大符號
    /// （參考實作用 lzfse_encode_tables.h 的大型反查表；這裡用二分搜尋，結果相同）
    @inline(__always)
    static func symbol(forValue v: Int32, base: [Int32]) -> Int {
        var lo = 0, hi = base.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) >> 1
            if base[mid] <= v { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // =================================================================
    // MARK: - FSE 頻率正規化（lzfse_fse.c: fse_normalize_freq）
    // =================================================================
    //
    // 將出現次數正規化為總和 = nstates（2 的冪次）。
    // shift = clz(nstates) - 1，配合 (x+1)>>1 達成四捨五入。
    // 註：正規化「不必」與參考實作位元相同——頻率表會原樣寫入標頭，
    // 解碼器照表重建；任何合法表（總和 ≤ nstates、用過的符號 ≥1）都可解。
    // =================================================================

    static func normalizeFreq(nstates: Int, counts: [UInt32]) -> [UInt16] {
        var freq = [UInt16](repeating: 0, count: counts.count)
        let total = counts.reduce(UInt64(0)) { $0 + UInt64($1) }
        guard total > 0 else { return freq }

        var remaining = nstates
        let shift = UInt32(nstates).leadingZeroBitCount - 1
        let step = UInt32((UInt64(1) << 31) / total)
        var maxFreq = 0, maxSym = 0

        for i in 0..<counts.count {
            var f = Int(((UInt64(counts[i]) * UInt64(step)) >> shift &+ 1) >> 1)
            if f == 0 && counts[i] != 0 { f = 1 }
            freq[i] = UInt16(f)
            remaining -= f
            if f > maxFreq { maxFreq = f; maxSym = i }
        }
        // 把剩餘（可能為負）狀態調整到最高頻符號上
        let adjusted = Int(freq[maxSym]) + remaining
        if adjusted < 1 {
            // 安全後援：參考實作的捨入極少走到這裡；
            // 改向其他符號逐一徵收狀態（任何合法分配都可被解碼）
            freq[maxSym] = 1
            var need = 1 - adjusted
            var i = 0
            while need > 0 {
                if i != maxSym && freq[i] > 1 { freq[i] -= 1; need -= 1 } else { i = (i + 1) % counts.count; continue }
            }
        } else {
            freq[maxSym] = UInt16(adjusted)
        }
        assert(freq.reduce(0) { $0 + Int($1) } == nstates)
        return freq
    }

    // =================================================================
    // MARK: - FSE 編碼/解碼表（lzfse_fse.c）
    // =================================================================
    //
    // 狀態以「連續區段」依符號順序分配（offset 累加），非散佈式。
    // 編碼項 (s0, k, delta0, delta1)：
    //   state >= s0 → 吐 k 位元、newState = delta0 + (state >> k)
    //   state <  s0 → 吐 k-1 位元、newState = delta1 + (state >> (k-1))
    // 解碼項依每個狀態：j < j0 用 k 位元，否則 k-1 位元。
    // 兩者互為反函數（已用獨立模型驗證往返一致）。
    // =================================================================

    struct FSEEncoderEntry { var s0: Int32; var k: Int32; var delta0: Int32; var delta1: Int32 }

    static func initEncoderTable(nstates: Int, freq: [UInt16]) -> [FSEEncoderEntry] {
        var t = [FSEEncoderEntry](repeating: .init(s0: 0, k: 0, delta0: 0, delta1: 0),
                                  count: freq.count)
        var offset = 0
        let nClz = UInt32(nstates).leadingZeroBitCount
        for i in 0..<freq.count {
            let f = Int(freq[i])
            if f == 0 { continue }
            let k = UInt32(f).leadingZeroBitCount - nClz
            t[i] = FSEEncoderEntry(
                s0: Int32((f << k) - nstates),
                k: Int32(k),
                delta0: Int32(offset - f + (nstates >> k)),
                delta1: k >= 1 ? Int32(offset - f + (nstates >> (k - 1))) : 0
            )
            offset += f
        }
        return t
    }

    /// literal 解碼表（packed int32：bits0-7 = k, 8-15 = symbol, 16-31 = delta）
    static func initDecoderTable(nstates: Int, freq: [UInt16]) -> [Int32]? {
        var t = [Int32](); t.reserveCapacity(nstates)
        let nClz = UInt32(nstates).leadingZeroBitCount
        var sum = 0
        for i in 0..<freq.count {
            let f = Int(freq[i])
            if f == 0 { continue }
            sum += f
            if sum > nstates { return nil }
            let k = UInt32(f).leadingZeroBitCount - nClz
            let j0 = ((2 * nstates) >> k) - f
            for j in 0..<f {
                let nbits: Int, delta: Int
                if j < j0 { nbits = k;     delta = ((f + j) << k) - nstates }
                else      { nbits = k - 1; delta = (j - j0) << (k - 1) }
                t.append(Int32(delta) << 16 | Int32(i) << 8 | Int32(nbits))
            }
        }
        while t.count < nstates { t.append(0) } // 理論上 sum == nstates 時不會發生
        return t
    }

    /// L/M/D 數值解碼表（fse_value_decoder_entry）
    struct FSEValueDecoderEntry { var totalBits: Int32; var valueBits: Int32; var delta: Int32; var vbase: Int32 }

    static func initValueDecoderTable(nstates: Int, freq: [UInt16],
                                      vbits: [UInt8], vbase: [Int32]) -> [FSEValueDecoderEntry] {
        var t = [FSEValueDecoderEntry](); t.reserveCapacity(nstates)
        let nClz = UInt32(nstates).leadingZeroBitCount
        for i in 0..<freq.count {
            let f = Int(freq[i])
            if f == 0 { continue }
            let k = UInt32(f).leadingZeroBitCount - nClz
            let j0 = ((2 * nstates) >> k) - f
            for j in 0..<f {
                if j < j0 {
                    t.append(.init(totalBits: Int32(k) + Int32(vbits[i]),
                                   valueBits: Int32(vbits[i]),
                                   delta: Int32(((f + j) << k) - nstates),
                                   vbase: vbase[i]))
                } else {
                    t.append(.init(totalBits: Int32(k - 1) + Int32(vbits[i]),
                                   valueBits: Int32(vbits[i]),
                                   delta: Int32((j - j0) << (k - 1)),
                                   vbase: vbase[i]))
                }
            }
        }
        while t.count < nstates { t.append(.init(totalBits: 0, valueBits: 0, delta: 0, vbase: 0)) }
        return t
    }

    // =================================================================
    // MARK: - FSE 位元流（lzfse_fse.h，64 位元 accumulator）
    // =================================================================

    /// 輸出流：LSB 先入、向前寫出位元組；finish 後 accumNBits ∈ [-7, 0]。
    ///
    /// 效能：直接寫入呼叫端預配置的緩衝，flush/finish 以單次 8 位元組
    /// memcpy 取代逐位元組 append（會多寫入少量暫存位元組到邏輯結尾之後，
    /// 呼叫端緩衝需預留 ≥8 bytes 的 slack）。
    struct FSEOutStream {
        var ptr: UnsafeMutablePointer<UInt8>
        let start: UnsafeMutablePointer<UInt8>
        var accum: UInt64 = 0
        var accumNBits: Int32 = 0

        init(_ base: UnsafeMutablePointer<UInt8>) { ptr = base; start = base }

        @inline(__always)
        mutating func push(_ n: Int32, _ b: UInt64) {
            accum |= b << UInt64(accumNBits)
            accumNBits += n
            assert(accumNBits <= 64)
        }
        @inline(__always)
        mutating func flush() {
            let nbits = accumNBits & -8
            var v = accum.littleEndian
            memcpy(ptr, &v, 8)              // 寬寫入；slack 涵蓋多寫的部分
            ptr += Int(nbits >> 3)
            accum >>= UInt64(nbits)
            accumNBits -= nbits
        }
        /// 寫出殘餘位元（補 0），回傳最終 accumNBits ∈ [-7, 0]（即標頭的 *_bits 欄位）
        mutating func finish() -> Int32 {
            let nbits = (accumNBits + 7) & -8
            var v = accum.littleEndian
            memcpy(ptr, &v, 8)
            ptr += Int(nbits >> 3)
            accum = 0
            accumNBits -= nbits
            assert(accumNBits >= -7 && accumNBits <= 0)
            return accumNBits
        }
        var count: Int { ptr - start }
    }

    /// 輸入流：從 payload「尾端」向回讀（LIFO）。
    /// 重要：回填可越過 payload 開頭、讀進前方的標頭位元組（那些位元永不被取用），
    /// 與參考解碼器以 src_begin 為下限的行為一致。
    ///
    /// 效能：以 UnsafePointer 一次載入 8 位元組（對應參考實作的 memcpy 載入），
    /// 取代逐位元組迴圈。初始化用「讀 8 丟 1」技巧保證之後所有載入都在
    /// [0, payloadEnd) 範圍內，不需逐次邊界檢查。
    struct FSEInStream {
        let base: UnsafePointer<UInt8>
        var pos: Int            // 下一次回讀位置（位元組，相對 base）
        var accum: UInt64 = 0
        var accumNBits: Int32 = 0

        @inline(__always) static func load8(_ p: UnsafePointer<UInt8>) -> UInt64 {
            var v: UInt64 = 0
            memcpy(&v, p, 8)
            return UInt64(littleEndian: v)
        }

        /// 對應 fse_in_checked_init64：n 為標頭的 *_bits 欄位（[-7,0]）
        init?(base: UnsafePointer<UInt8>, payloadEnd: Int, bits n: Int32) {
            self.base = base
            guard payloadEnd >= 8 else { return nil } // 前方必有 772-byte 標頭，恆成立
            if n != 0 {
                pos = payloadEnd - 8
                accum = Self.load8(base + pos)
                accumNBits = n + 64
            } else {
                // 等效讀取 7 bytes：載入 [payloadEnd-8, payloadEnd) 後丟棄最低位元組，
                // 避免越過 payloadEnd 讀取
                pos = payloadEnd - 7
                accum = Self.load8(base + payloadEnd - 8) >> 8
                accumNBits = n + 56
            }
            guard accumNBits >= 56 && accumNBits < 64,
                  (accum >> UInt64(accumNBits)) == 0 else { return nil }
        }

        /// 對應 fse_in_checked_flush64：補滿至 [56, 63] 位元
        /// 不變量：載入永遠落在 [0, payloadEnd)（見 init 的讀 8 丟 1 技巧）
        @inline(__always)
        mutating func fill() -> Bool {
            let nbits = (63 - accumNBits) & -8
            if nbits == 0 { return true }
            let newPos = pos - Int(nbits >> 3)
            guard newPos >= 0 else { return false } // 越過整個來源緩衝區才算錯
            pos = newPos
            let incoming = Self.load8(base + newPos)
            accum = (accum << UInt64(nbits)) | (incoming & ((UInt64(1) << UInt64(nbits)) - 1))
            accumNBits += nbits
            return true
        }

        @inline(__always)
        mutating func pull(_ n: Int32) -> UInt64 {
            accumNBits -= n
            let r = accum >> UInt64(accumNBits)
            accum &= (UInt64(1) << UInt64(accumNBits)) - 1
            return r
        }
    }

    // FSE 編碼一個符號（fse_encode）
    @inline(__always)
    static func fseEncode(state: inout Int32, _ e: FSEEncoderEntry, _ out: inout FSEOutStream) {
        let hi = state >= e.s0
        let nbits = hi ? e.k : e.k - 1
        let delta = hi ? e.delta0 : e.delta1
        out.push(nbits, UInt64(state) & ((UInt64(1) << UInt64(nbits)) - 1))
        state = delta + (state >> nbits)
    }

    // =================================================================
    // MARK: - LZ 比對（簡化貪婪版；任何合法 parse 都與格式相容）
    // =================================================================

    struct Triplet { var l: Int32; var m: Int32; var d: Int32 } // d 為「原始」距離

    static let hashBits = 14
    static let hashSize = 1 << hashBits

    /// 將輸入解析為 (L,M,D) 三元組序列＋literal 緩衝。
    /// 已套用上限切割：L ≤ 315、M ≤ 2359、D ≤ 262139。
    static func lzParse(_ input: [UInt8]) -> (triplets: [Triplet], literals: [UInt8]) {
        var triplets: [Triplet] = []
        var literals: [UInt8] = []
        let n = input.count
        triplets.reserveCapacity(n >> 5 + 8)   // 啟發式：平均 match 間距
        literals.reserveCapacity(n >> 1 + 8)

        // 把 L 切成 ≤315 的塊；純 literal 塊用 (L, 0, 1)
        func pushRun(l: Int, m: Int, d: Int) {
            var L = l
            while L > maxLValue {
                triplets.append(Triplet(l: Int32(maxLValue), m: 0, d: 1))
                L -= maxLValue
            }
            var M = m
            if M > 0 {
                while M > maxMValue {
                    triplets.append(Triplet(l: Int32(L), m: Int32(maxMValue), d: Int32(d)))
                    L = 0; M -= maxMValue
                }
                triplets.append(Triplet(l: Int32(L), m: Int32(M), d: Int32(d)))
            } else if L > 0 {
                triplets.append(Triplet(l: Int32(L), m: 0, d: 1))
            }
        }

        guard n > 4 else {
            literals = input
            pushRun(l: n, m: 0, d: 1)
            return (triplets, literals)
        }

        // 雜湊表用 UnsafeMutablePointer（免去每次存取的陣列邊界檢查）
        let hashTable = UnsafeMutablePointer<Int32>.allocate(capacity: hashSize)
        hashTable.initialize(repeating: -1, count: hashSize)
        defer { hashTable.deallocate() }

        var litStart = 0
        var i = 0
        input.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!

            @inline(__always) func load32(_ idx: Int) -> UInt32 {
                var v: UInt32 = 0
                memcpy(&v, p + idx, 4)
                return UInt32(littleEndian: v)
            }
            @inline(__always) func load64(_ idx: Int) -> UInt64 {
                var v: UInt64 = 0
                memcpy(&v, p + idx, 8)
                return UInt64(littleEndian: v)
            }
            @inline(__always) func hash4(_ idx: Int) -> Int {
                Int((load32(idx) &* 2654435761) >> (32 - UInt32(hashBits)))
            }
            /// 8 位元組寬比較的最長相同前綴（XOR 後以 trailing zero 定位首個相異位元組）
            @inline(__always) func matchLength(_ a: Int, _ b: Int, limit: Int) -> Int {
                var m = 0
                while m + 8 <= limit {
                    let x = load64(a + m) ^ load64(b + m)
                    if x != 0 { return m + (x.trailingZeroBitCount >> 3) }
                    m += 8
                }
                while m < limit && p[a + m] == p[b + m] { m += 1 }
                return m
            }

            while i + 4 <= n {
                let h = hash4(i)
                let cand = Int(hashTable[h])
                hashTable[h] = Int32(i)

                var mlen = 0
                if cand >= 0, i - cand <= maxDValue, load32(cand) == load32(i) {
                    mlen = 4 + matchLength(cand + 4, i + 4, limit: n - i - 4)
                }
                if mlen >= 4 {
                    literals.append(contentsOf: UnsafeBufferPointer(start: p + litStart,
                                                                    count: i - litStart))
                    pushRun(l: i - litStart, m: mlen, d: i - cand)
                    let end = i + mlen
                    i += 1
                    while i < min(end, n - 4) { hashTable[hash4(i)] = Int32(i); i += 1 }
                    i = end
                    litStart = end
                } else {
                    i += 1
                }
            }
            if litStart < n {
                literals.append(contentsOf: UnsafeBufferPointer(start: p + litStart,
                                                                count: n - litStart))
            }
        }
        if litStart < n {
            pushRun(l: n - litStart, m: 0, d: 1)
        }
        return (triplets, literals)
    }

    // =================================================================
    // MARK: - 強化 LZ 比對（other3；採 zstd 高壓縮級距的搜尋策略）
    // =================================================================
    //
    // 借鏡 zstd -9：高壓縮級距的增益主要來自
    //   (a) 更強的比對搜尋（多候選雜湊歷史 + lazy matching）
    //   (b) 更大的視窗（zstd ≥2MB）
    //   (c) 更彈性的熵編碼（多 Huffman 表、repeat-offset 碼）
    // (b)(c) 受 LZFSE 格式固定（D ≤ 262139、FSE 表結構），無從採用；
    // (a) 完全可以：這裡實作每桶 4 候選 + lazy matching。
    // 輸出仍是標準 bvx2 區塊 —— 刻意不發明 bvx3 魔數，
    // 因此 Apple 解碼器與所有標準工具照樣可解 other3 的輸出。
    // =================================================================

    static let strongHashBits = 15                    // 32768 桶
    static let strongHashSize = 1 << strongHashBits
    static let strongHashWidth = 4                    // 每桶保留最近 4 個位置

    static func lzParseStrong(_ input: [UInt8]) -> (triplets: [Triplet], literals: [UInt8]) {
        var triplets: [Triplet] = []
        var literals: [UInt8] = []
        let n = input.count
        triplets.reserveCapacity(n >> 5 + 8)
        literals.reserveCapacity(n >> 1 + 8)

        // 把 L 切成 ≤315 的塊；純 literal 塊用 (L, 0, 1)（與 lzParse 相同規則）
        func pushRun(l: Int, m: Int, d: Int) {
            var L = l
            while L > maxLValue {
                triplets.append(Triplet(l: Int32(maxLValue), m: 0, d: 1))
                L -= maxLValue
            }
            var M = m
            if M > 0 {
                while M > maxMValue {
                    triplets.append(Triplet(l: Int32(L), m: Int32(maxMValue), d: Int32(d)))
                    L = 0; M -= maxMValue
                }
                triplets.append(Triplet(l: Int32(L), m: Int32(M), d: Int32(d)))
            } else if L > 0 {
                triplets.append(Triplet(l: Int32(L), m: 0, d: 1))
            }
        }

        guard n > 8 else {
            literals = input
            pushRun(l: n, m: 0, d: 1)
            return (triplets, literals)
        }

        let W = strongHashWidth
        let ht = UnsafeMutablePointer<Int32>.allocate(capacity: strongHashSize * W)
        ht.initialize(repeating: -1, count: strongHashSize * W)
        defer { ht.deallocate() }

        var litStart = 0
        input.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!

            @inline(__always) func load32(_ idx: Int) -> UInt32 {
                var v: UInt32 = 0; memcpy(&v, p + idx, 4); return UInt32(littleEndian: v)
            }
            @inline(__always) func load64(_ idx: Int) -> UInt64 {
                var v: UInt64 = 0; memcpy(&v, p + idx, 8); return UInt64(littleEndian: v)
            }
            @inline(__always) func hash4(_ idx: Int) -> Int {
                Int((load32(idx) &* 2654435761) >> (32 - UInt32(strongHashBits)))
            }
            @inline(__always) func matchLength(_ a: Int, _ b: Int, limit: Int) -> Int {
                var m = 0
                while m + 8 <= limit {
                    let x = load64(a + m) ^ load64(b + m)
                    if x != 0 { return m + (x.trailingZeroBitCount >> 3) }
                    m += 8
                }
                while m < limit && p[a + m] == p[b + m] { m += 1 }
                return m
            }
            /// shift-insert：保留最近 4 個位置（對應參考實作的 history set）
            @inline(__always) func insert(_ idx: Int) {
                let b = hash4(idx) * W
                ht[b + 3] = ht[b + 2]; ht[b + 2] = ht[b + 1]
                ht[b + 1] = ht[b + 0]; ht[b + 0] = Int32(idx)
            }
            /// 4 候選中挑最長 match（同長取較近距離，extra bits 較省）
            @inline(__always) func bestMatch(_ idx: Int) -> (len: Int, dist: Int) {
                let b = hash4(idx) * W
                let v = load32(idx)
                var bl = 0, bd = 1
                for s in 0..<W {
                    let c = Int(ht[b + s])
                    if c < 0 { break }
                    let d = idx - c
                    if d > maxDValue || load32(c) != v { continue }
                    let l = 4 + matchLength(c + 4, idx + 4, limit: n - idx - 4)
                    if l > bl || (l == bl && d < bd) { bl = l; bd = d }
                }
                return (bl, bd)
            }

            var i = 0
            while i + 4 <= n {
                var (m0, d0) = bestMatch(i)
                insert(i)
                if m0 < 4 { i += 1; continue }

                // lazy matching：若下一位置能找到更長的 match，
                // 把目前位元組降級為 literal、視窗右移一格，重複到不再改善
                while i + 5 <= n {
                    let (m1, d1) = bestMatch(i + 1)
                    if m1 > m0 {
                        insert(i + 1)
                        i += 1
                        m0 = m1; d0 = d1
                    } else { break }
                }

                literals.append(contentsOf: UnsafeBufferPointer(start: p + litStart,
                                                                count: i - litStart))
                pushRun(l: i - litStart, m: m0, d: d0)
                let end = i + m0
                i += 1
                while i < min(end, n - 4) { insert(i); i += 1 }
                i = end
                litStart = end
            }
            if litStart < n {
                literals.append(contentsOf: UnsafeBufferPointer(start: p + litStart,
                                                                count: n - litStart))
            }
        }
        if litStart < n {
            pushRun(l: n - litStart, m: 0, d: 1)
        }
        return (triplets, literals)
    }

    // =================================================================
    // MARK: - 小端序讀寫工具
    // =================================================================

    static func put32(_ v: UInt32, _ out: inout [UInt8]) {
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8((v >> 24) & 0xFF))
    }
    static func put16(_ v: UInt16, _ out: inout [UInt8]) {
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
    }
    static func get32(_ d: [UInt8], _ p: Int) -> UInt32 {
        UInt32(d[p]) | UInt32(d[p+1]) << 8 | UInt32(d[p+2]) << 16 | UInt32(d[p+3]) << 24
    }
    static func get16(_ d: [UInt8], _ p: Int) -> UInt16 {
        UInt16(d[p]) | UInt16(d[p+1]) << 8
    }

    // =================================================================
    // MARK: - 區塊編碼（lzfse_encode_base.c: lzfse_encode_matches）
    // =================================================================

    /// 頻率值的固定 Huffman 編碼（lzfse_encode_v1_freq_value 的等價實作；
    /// 與 decodeFreqValue 互逆，已全值域 0..1047 驗證）
    @inline(__always)
    static func encodeFreqValue(_ v: Int) -> (bits: UInt32, nbits: Int32) {
        switch v {
        case 0:      return (0, 2)                              //    0.0
        case 1:      return (2, 2)                              //    1.0
        case 2:      return (1, 3)                              //   0.01
        case 3:      return (5, 3)                              //   1.01
        case 4...7:  return (UInt32((v - 4) << 3) | 3, 5)       //  xx.011
        case 8...23: return (UInt32((v - 8) << 4) | 7, 8)       // xxxx.0111
        default:     return (UInt32((v - 24) << 4) | 15, 14)    // 10bit.1111
        }
    }

    /// 將一個區塊（≤10000 matches、≤40000 literals）編成 bvx2 區塊位元組
    /// （壓縮標頭：32-byte 固定部分 + 固定 Huffman 頻率位元流，
    ///  比 772-byte 的 v1 標頭每區塊省下約 550–650 bytes）
    static func encodeBlock(triplets: ArraySlice<Triplet>,
                            literals: ArraySlice<UInt8>,
                            rawBytes: Int) -> [UInt8] {
        // --- 準備工作緩衝 ---
        var lits = Array(literals)
        // 補 0x00 到 4 的倍數（4 路交錯流的需要；標頭 n_literals 含補齊）
        while lits.count & 3 != 0 { lits.append(0) }

        var lVals = [Int32](), mVals = [Int32](), dVals = [Int32]()
        lVals.reserveCapacity(triplets.count)
        for t in triplets { lVals.append(t.l); mVals.append(t.m); dVals.append(t.d) }
        let nMatches = lVals.count

        // D 的「重複距離 → 0」轉換（解碼器 d==0 時沿用前一距離；d_prev 每區塊歸零）
        var dPrev: Int32 = 0
        for i in 0..<nMatches {
            let d = dVals[i]
            if d == dPrev { dVals[i] = 0 } else { dPrev = d }
        }

        // --- 統計與正規化 ---
        var lOcc = [UInt32](repeating: 0, count: lSymbols)
        var mOcc = [UInt32](repeating: 0, count: mSymbols)
        var dOcc = [UInt32](repeating: 0, count: dSymbols)
        var litOcc = [UInt32](repeating: 0, count: literalSymbols)
        var lSyms = [UInt8](repeating: 0, count: nMatches)
        var mSyms = [UInt8](repeating: 0, count: nMatches)
        var dSyms = [UInt8](repeating: 0, count: nMatches)
        for i in 0..<nMatches {
            let ls = symbol(forValue: lVals[i], base: lBaseValue)
            let ms = symbol(forValue: mVals[i], base: mBaseValue)
            let ds = symbol(forValue: dVals[i], base: dBaseValue)
            lSyms[i] = UInt8(ls); mSyms[i] = UInt8(ms); dSyms[i] = UInt8(ds)
            lOcc[ls] += 1; mOcc[ms] += 1; dOcc[ds] += 1
        }
        for b in lits { litOcc[Int(b)] += 1 }

        let lFreq = normalizeFreq(nstates: lStates, counts: lOcc)
        let mFreq = normalizeFreq(nstates: mStates, counts: mOcc)
        let dFreq = normalizeFreq(nstates: dStates, counts: dOcc)
        let litFreq = normalizeFreq(nstates: literalStates, counts: litOcc)

        let lEnc = initEncoderTable(nstates: lStates, freq: lFreq)
        let mEnc = initEncoderTable(nstates: mStates, freq: mFreq)
        let dEnc = initEncoderTable(nstates: dStates, freq: dFreq)
        let litEnc = initEncoderTable(nstates: literalStates, freq: litFreq)

        // --- 工作區：兩條輸出流直寫預配置緩衝（含 8B 寬寫入 slack）---
        let litCap = lits.count * 2 + 16          // literal ≤10 bits/個 = 1.25B，2x 保守
        let lmdCap = nMatches * 8 + 32            // 每 match ≤54 bits = 6.75B + 8B 前置填充
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: litCap + lmdCap)
        defer { scratch.deallocate() }

        // --- ① 編碼 literal：4 路交錯、由最後一個 literal 往前 ---
        var litOut = FSEOutStream(scratch)
        var s0: Int32 = 0, s1: Int32 = 0, s2: Int32 = 0, s3: Int32 = 0
        lits.withUnsafeBufferPointer { lp in
            var i = lits.count
            while i > 0 {
                i -= 4
                fseEncode(state: &s3, litEnc[Int(lp[i + 3])], &litOut) // 各 ≤10 bits
                fseEncode(state: &s2, litEnc[Int(lp[i + 2])], &litOut)
                fseEncode(state: &s1, litEnc[Int(lp[i + 1])], &litOut)
                fseEncode(state: &s0, litEnc[Int(lp[i + 0])], &litOut)
                litOut.flush() // 4×10=40 ≤ 64，每組沖一次
            }
        }
        let literalBits = litOut.finish()
        let litLen = litOut.count

        // --- ② 編碼 L,M,D：match 反序；每個 match 依 D→M→L 推入 ---
        var lmdOut = FSEOutStream(scratch + litCap)
        // 參考實作在 LMD payload 開頭放 8 個 0 填充位元組（解碼快路徑的安全邊界）
        memset(scratch + litCap, 0, 8)
        lmdOut.ptr += 8
        var lState: Int32 = 0, mState: Int32 = 0, dState: Int32 = 0
        var mi = nMatches
        while mi > 0 {
            mi -= 1
            // D（≤ 8+15 = 23 bits）：先推 extra bits，再推符號狀態位元
            let dsym = Int(dSyms[mi])
            lmdOut.push(Int32(dExtraBits[dsym]), UInt64(dVals[mi] - dBaseValue[dsym]))
            fseEncode(state: &dState, dEnc[dsym], &lmdOut)
            // M（≤ 6+11 = 17 bits）
            let msym = Int(mSyms[mi])
            lmdOut.push(Int32(mExtraBits[msym]), UInt64(mVals[mi] - mBaseValue[msym]))
            fseEncode(state: &mState, mEnc[msym], &lmdOut)
            // L（≤ 6+8 = 14 bits）；合計 ≤54 ≤64
            let lsym = Int(lSyms[mi])
            lmdOut.push(Int32(lExtraBits[lsym]), UInt64(lVals[mi] - lBaseValue[lsym]))
            fseEncode(state: &lState, lEnc[lsym], &lmdOut)
            lmdOut.flush()
        }
        let lmdBits = lmdOut.finish()
        let lmdLen = lmdOut.count

        // --- ③ 頻率表：固定 Huffman、LSB 先入位元流 ---
        var freqBytes: [UInt8] = []
        freqBytes.reserveCapacity(384)
        var fAccum: UInt32 = 0
        var fNBits: Int32 = 0
        for table in [lFreq, mFreq, dFreq, litFreq] {
            for f in table {
                let (bits, n) = encodeFreqValue(Int(f))
                fAccum |= bits << UInt32(fNBits)
                fNBits += n
                while fNBits >= 8 {
                    freqBytes.append(UInt8(fAccum & 0xFF))
                    fAccum >>= 8
                    fNBits -= 8
                }
            }
        }
        if fNBits > 0 { freqBytes.append(UInt8(fAccum & 0xFF)) }   // 殘餘 <8 位元

        // --- ④ 組裝 bvx2 標頭（packed_fields 配置照 lzfse_internal.h）---
        let headerSize = 32 + freqBytes.count
        @inline(__always) func sf(_ v: Int, _ off: Int) -> UInt64 { UInt64(v) << UInt64(off) }
        let v0 = sf(lits.count, 0) | sf(litLen, 20) | sf(nMatches, 40)
               | sf(Int(7 + literalBits), 60)
        let v1f = sf(Int(s0), 0) | sf(Int(s1), 10) | sf(Int(s2), 20) | sf(Int(s3), 30)
                | sf(lmdLen, 40) | sf(Int(7 + lmdBits), 60)
        let v2f = sf(headerSize, 0) | sf(Int(lState), 32) | sf(Int(mState), 42)
                | sf(Int(dState), 52)

        var out: [UInt8] = []
        out.reserveCapacity(headerSize + litLen + lmdLen)
        put32(magicCompressedV2, &out)
        put32(UInt32(rawBytes), &out)
        for v in [v0, v1f, v2f] {
            var x = v
            for _ in 0..<8 { out.append(UInt8(x & 0xFF)); x >>= 8 }
        }
        out.append(contentsOf: freqBytes)
        assert(out.count == headerSize)
        out.append(contentsOf: UnsafeBufferPointer(start: scratch, count: litLen))
        out.append(contentsOf: UnsafeBufferPointer(start: scratch + litCap, count: lmdLen))
        return out
    }

    // =================================================================
    // MARK: - 頂層壓縮 API
    // =================================================================

    /// 壓縮為「區塊串」但不含結尾 bvx$ ——供平行分塊壓縮串接使用。
    /// 多個 compressBody 輸出串接後補上一個 bvx$，仍是合法的標準 LZFSE 串流
    /// （每個分塊獨立壓縮，match 距離不跨分塊，解碼器的輸出歷史是連續的所以相容）。
    public static func compressBody(_ input: Data, strong: Bool = false) -> Data {
        let bytes = [UInt8](input)
        var out: [UInt8] = []
        guard !bytes.isEmpty else { return Data() }

        if bytes.count < 32 {
            // 太小：raw 區塊（參考實作此處走 LZVN；raw 同樣是合法輸出）
            put32(magicUncompressed, &out)
            put32(UInt32(bytes.count), &out)
            out.append(contentsOf: bytes)
            return Data(out)
        }

        let (triplets, literals) = strong ? lzParseStrong(bytes) : lzParse(bytes)

        // 依每區塊上限切分（留 5 個 match、最大 L 的安全邊界）
        var tStart = 0
        var litStart = 0
        while tStart < triplets.count {
            var tEnd = tStart
            var litCount = 0, raw = 0
            while tEnd < triplets.count {
                let t = triplets[tEnd]
                if (tEnd - tStart) + 5 > matchesPerBlock { break }
                if litCount + Int(t.l) + 4 > literalsPerBlock { break }
                litCount += Int(t.l); raw += Int(t.l + t.m)
                tEnd += 1
            }
            let block = encodeBlock(triplets: triplets[tStart..<tEnd],
                                    literals: literals[litStart..<(litStart + litCount)],
                                    rawBytes: raw)
            out.append(contentsOf: block)
            tStart = tEnd
            litStart += litCount
        }

        // 壓不動就退回 raw 區塊
        if out.count >= bytes.count + 8 {
            out.removeAll(keepingCapacity: true)
            put32(magicUncompressed, &out)
            put32(UInt32(bytes.count), &out)
            out.append(contentsOf: bytes)
        }
        return Data(out)
    }

    /// 相容別名（other2 平行壓縮分支使用的名稱）
    public static func compressBlockOnly(_ input: Data) -> Data { compressBody(input) }

    public static func compress(_ input: Data, strong: Bool = false) -> Data {
        var out = [UInt8](compressBody(input, strong: strong))
        put32(magicEndOfStream, &out)
        return Data(out)
    }

    // =================================================================
    // MARK: - 解碼器（lzfse_decode_base.c；支援 bvx1 / bvx2 / bvxn / bvx- / bvx$）
    // =================================================================

    // ---------- bvx2：壓縮標頭（lzfse_decode_v2_header）----------

    /// 頻率值固定 Huffman 碼的解碼表（lzfse_decode_v1_freq_value）
    /// 由低位元讀取；2/3/5/8/14 位元五級編碼，值域 0..1047
    static let freqNBitsTable: [Int32] = [
        2, 3, 2, 5, 2, 3, 2, 8, 2, 3, 2, 5, 2, 3, 2, 14,
        2, 3, 2, 5, 2, 3, 2, 8, 2, 3, 2, 5, 2, 3, 2, 14
    ]
    static let freqValueTable: [Int32] = [
        0, 2, 1, 4, 0, 3, 1, -1, 0, 2, 1, 5, 0, 3, 1, -1,
        0, 2, 1, 6, 0, 3, 1, -1, 0, 2, 1, 7, 0, 3, 1, -1
    ]

    @inline(__always)
    static func decodeFreqValue(_ bits: UInt32) -> (value: UInt16, nbits: Int32) {
        let b = Int(bits & 31)
        let n = freqNBitsTable[b]
        if n == 8 { return (UInt16(8 + ((bits >> 4) & 0xF)), 8) }       // 8..23
        if n == 14 { return (UInt16(24 + ((bits >> 4) & 0x3FF)), 14) }  // 24..1047
        return (UInt16(freqValueTable[b]), n)   // n==8/14 已處理，查表值必非 -1
    }

    static func get64(_ d: [UInt8], _ p: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(d[p + i]) << (UInt64(i) * 8) }
        return v
    }

    /// 解碼 bvx2 區塊：展開壓縮標頭為等價的 v1 區塊後重用 decodeV1Block。
    /// packed_fields 位元配置（lzfse_internal.h）：
    ///   v0: n_literals[0..19] n_literal_payload[20..39] n_matches[40..59] literal_bits+7[60..62]
    ///   v1: literal_state×4[各10位] n_lmd_payload[40..59] lmd_bits+7[60..62]
    ///   v2: header_size[0..31] l_state[32..41] m_state[42..51] d_state[52..61]
    static func decodeV2Block(src: [UInt8], at p: Int, into dst: inout [UInt8]) -> Int? {
        guard p + 32 <= src.count else { return nil }
        let nRaw = get32(src, p + 4)
        let v0 = get64(src, p + 8), v1 = get64(src, p + 16), v2 = get64(src, p + 24)
        @inline(__always) func field(_ v: UInt64, _ off: Int, _ n: Int) -> Int {
            Int((v >> UInt64(off)) & ((UInt64(1) << UInt64(n)) - 1))
        }
        let nLiterals = field(v0, 0, 20)
        let nLitPayload = field(v0, 20, 20)
        let nMatches = field(v0, 40, 20)
        let literalBits = Int32(field(v0, 60, 3)) - 7
        let litStates = [field(v1, 0, 10), field(v1, 10, 10),
                         field(v1, 20, 10), field(v1, 30, 10)]
        let nLmdPayload = field(v1, 40, 20)
        let lmdBits = Int32(field(v1, 60, 3)) - 7
        let headerSize = field(v2, 0, 32)
        let lState = field(v2, 32, 10), mState = field(v2, 42, 10), dState = field(v2, 52, 10)

        let nPayload = nLitPayload + nLmdPayload
        guard headerSize >= 32,
              p + headerSize <= src.count,
              p + headerSize + nPayload <= src.count else { return nil }

        // 解出 360 個頻率值（32 位元視窗、LSB 先入；必須剛好在標頭尾結束）
        let nFreq = lSymbols + mSymbols + dSymbols + literalSymbols
        var freqs = [UInt16](repeating: 0, count: nFreq)
        if headerSize > 32 {
            var accum: UInt32 = 0
            var accumNBits: Int32 = 0
            var q = p + 32
            let qEnd = p + headerSize
            for i in 0..<nFreq {
                while q < qEnd && accumNBits + 8 <= 32 {
                    accum |= UInt32(src[q]) << UInt32(accumNBits)
                    accumNBits += 8
                    q += 1
                }
                let (value, nbits) = decodeFreqValue(accum)
                guard nbits <= accumNBits else { return nil }
                freqs[i] = value
                accum >>= UInt32(nbits)
                accumNBits -= nbits
            }
            guard accumNBits < 8, q == qEnd else { return nil } // 不得有多餘位元組
        }
        // headerSize == 32 → 頻率表省略（全 0，僅見於空區塊）

        // 直接在原始緩衝上解碼（零 payload 複製）。
        // 反向位元流回讀所需的前置位元組由 v2 標頭本身提供（≥32+freq bytes > 7）。
        let nFreqL = lSymbols, nFreqM = mSymbols, nFreqD = dSymbols
        let lFreq = Array(freqs[0..<nFreqL])
        let mFreq = Array(freqs[nFreqL..<(nFreqL + nFreqM)])
        let dFreq = Array(freqs[(nFreqL + nFreqM)..<(nFreqL + nFreqM + nFreqD)])
        let litFreq = Array(freqs[(nFreqL + nFreqM + nFreqD)...])
        guard decodeBlockBody(src: src, payloadStart: p + headerSize,
                              nRawBytes: Int(nRaw), nLiterals: nLiterals, nMatches: nMatches,
                              nLitPayload: nLitPayload, nLmdPayload: nLmdPayload,
                              literalBits: literalBits,
                              litState0: Int32(litStates[0]), litState1: Int32(litStates[1]),
                              litState2: Int32(litStates[2]), litState3: Int32(litStates[3]),
                              lmdBits: lmdBits,
                              lState0: Int32(lState), mState0: Int32(mState), dState0: Int32(dState),
                              lFreq: lFreq, mFreq: mFreq, dFreq: dFreq, litFreq: litFreq,
                              into: &dst)
        else { return nil }
        return headerSize + nPayload
    }

    // ---------- bvxn：LZVN 區塊（lzvn_decode_base.c）----------

    enum LZVNOp: UInt8 { case smlD, medD, lrgD, preD, smlL, lrgL, smlM, lrgM, nop, eos, udef }

    /// 256 項操作碼分類表（對照 lzvn_decode_base.c 的 opc_tbl）
    static let lzvnOpTable: [LZVNOp] = {
        var t = [LZVNOp](repeating: .udef, count: 256)
        for opc in 0..<256 {
            switch opc {
            case 0xE0:          t[opc] = .lrgL
            case 0xE1...0xEF:   t[opc] = .smlL
            case 0xF0:          t[opc] = .lrgM
            case 0xF1...0xFF:   t[opc] = .smlM
            case 0xA0...0xBF:   t[opc] = .medD
            case 0xD0...0xDF:   t[opc] = .udef
            case 0x06:          t[opc] = .eos
            case 0x0E, 0x16:    t[opc] = .nop
            default:
                switch opc & 7 {
                case 7:  t[opc] = .lrgD
                case 6:  t[opc] = opc < 0x40 ? .udef : .preD  // 0x1E/26/2E/36/3E 未定義
                default: t[opc] = .smlD
                }
            }
        }
        return t
    }()

    /// 解碼 bvxn 區塊：標頭 = magic(4) + n_raw_bytes(4) + n_payload_bytes(4)
    static func decodeLZVNBlock(src: [UInt8], at p: Int, into dst: inout [UInt8]) -> Int? {
        guard p + 12 <= src.count else { return nil }
        let nRaw = Int(get32(src, p + 4))
        let nPayload = Int(get32(src, p + 8))
        let payloadStart = p + 12
        guard nPayload >= 8, payloadStart + nPayload <= src.count,
              nRaw <= (1 << 30) else { return nil }

        let outBase = dst.count
        dst.append(contentsOf: repeatElement(0, count: nRaw))
        var ok = false
        src.withUnsafeBufferPointer { sbuf in
            dst.withUnsafeMutableBufferPointer { dbuf in
                ok = lzvnDecode(sp: sbuf.baseAddress! + payloadStart, srcLen: nPayload,
                                dp: dbuf.baseAddress!, outBase: outBase,
                                outEnd: outBase + nRaw)
            }
        }
        guard ok else { dst.removeLast(nRaw); return nil }
        return 12 + nPayload
    }

    /// LZVN 操作碼機。dp 指向「整個」輸出緩衝（match 可回溯引用之前區塊的輸出），
    /// 寫入範圍限定 [outBase, outEnd)。成功條件：遇到 eos 且輸出恰好填滿。
    static func lzvnDecode(sp: UnsafePointer<UInt8>, srcLen: Int,
                           dp: UnsafeMutablePointer<UInt8>,
                           outBase: Int, outEnd: Int) -> Bool {
        var s = 0
        var w = outBase
        var dPrev = 0

        while s < srcLen {
            let opc = Int(sp[s])
            var L = 0, M = 0
            var d = -1          // -1 = 沿用 dPrev
            var opLen = 1

            switch lzvnOpTable[opc] {
            case .smlD: // LLMMMDDD DDDDDDDD：D = 3+8 位元
                opLen = 2
                guard s + 2 <= srcLen else { return false }
                L = opc >> 6; M = ((opc >> 3) & 7) + 3
                d = ((opc & 7) << 8) | Int(sp[s + 1])
            case .medD: // 101LLMMM DDDDDDMM DDDDDDDD：M = 3+2 位元、D = 14 位元
                opLen = 3
                guard s + 3 <= srcLen else { return false }
                L = (opc >> 3) & 3
                let opc23 = Int(sp[s + 1]) | (Int(sp[s + 2]) << 8)
                M = (((opc & 7) << 2) | (opc23 & 3)) + 3
                d = (opc23 >> 2) & 0x3FFF
            case .lrgD: // LLMMM111 + 16 位元 D
                opLen = 3
                guard s + 3 <= srcLen else { return false }
                L = opc >> 6; M = ((opc >> 3) & 7) + 3
                d = Int(sp[s + 1]) | (Int(sp[s + 2]) << 8)
            case .preD: // LLMMM110：沿用前一距離
                L = opc >> 6; M = ((opc >> 3) & 7) + 3
            case .smlL: // 1110LLLL
                L = opc & 15
            case .lrgL: // 11100000 LLLLLLLL：L = 第二位元組 + 16
                opLen = 2
                guard s + 2 <= srcLen else { return false }
                L = Int(sp[s + 1]) + 16
            case .smlM: // 1111MMMM：沿用前一距離
                M = opc & 15
            case .lrgM: // 11110000 MMMMMMMM：M = 第二位元組 + 16
                opLen = 2
                guard s + 2 <= srcLen else { return false }
                M = Int(sp[s + 1]) + 16
            case .nop:
                s += 1
                continue
            case .eos:  // 操作碼總長 8（0x06 + 7 個尾隨位元組）
                return s + 8 <= srcLen && w == outEnd
            case .udef:
                return false
            }
            s += opLen

            // ① literal：直接從操作碼後方複製
            if L > 0 {
                guard s + L <= srcLen, w + L <= outEnd else { return false }
                memcpy(dp + w, sp + s, L)
                s += L; w += L
            }
            // ② match：距離可回溯整個輸出歷史（含先前區塊）
            if M > 0 {
                let dd = d >= 0 ? d : dPrev
                guard dd > 0, dd <= w, w + M <= outEnd else { return false }
                let msrc = w - dd
                if dd >= M {
                    memcpy(dp + w, dp + msrc, M)
                } else if dd >= 8 {
                    var k = 0
                    while k + 8 <= M { memcpy(dp + w + k, dp + msrc + k, 8); k += 8 }
                    while k < M { dp[w + k] = dp[msrc + k]; k += 1 }
                } else {
                    for k in 0..<M { dp[w + k] = dp[msrc + k] }
                }
                w += M
                if d >= 0 { dPrev = d }
            } else if d >= 0 {
                dPrev = d
            }
        }
        return false // payload 用完仍未遇到 eos
    }

    public static func decompress(_ input: Data) -> Data? {
        let src = [UInt8](input)
        var p = 0
        var dst: [UInt8] = []
        dst.reserveCapacity(min(src.count * 4, 1 << 26)) // 啟發式預留，封頂 64MB

        while p + 4 <= src.count {
            let magic = get32(src, p)
            switch magic {
            case magicEndOfStream:
                return Data(dst)

            case magicUncompressed:
                guard p + 8 <= src.count else { return nil }
                let n = Int(get32(src, p + 4))
                guard p + 8 + n <= src.count else { return nil }
                dst.append(contentsOf: src[(p + 8)..<(p + 8 + n)])
                p += 8 + n

            case magicCompressedV1:
                guard let consumed = decodeV1Block(src: src, at: p, into: &dst) else { return nil }
                p += consumed

            case magicCompressedV2:
                guard let consumed = decodeV2Block(src: src, at: p, into: &dst) else { return nil }
                p += consumed   // header_size 已含 magic 起算的完整標頭

            case magicLZVN:
                guard let consumed = decodeLZVNBlock(src: src, at: p, into: &dst) else { return nil }
                p += consumed

            default:
                return nil
            }
        }
        return nil // 缺少 bvx$ 結尾
    }

    // =================================================================
    // MARK: - 平行解碼（other2 分塊串流專用，含安全後援）
    // =================================================================
    //
    // 原理：other2 的每個分塊（預設 4MiB 原始大小）獨立壓縮，match 永不
    // 跨分塊。解碼端只掃描區塊標頭（不碰 payload）累計 n_raw_bytes，在
    // 分塊大小的倍數處切組，各組平行解碼。
    //
    // 正確性保證：組內 match 的相對距離與絕對位置一一對應（組緩衝的
    // 索引 x ≡ 串流絕對位置 groupStart+x），引用若越過組起點，必然觸發
    // 既有的 d ≤ 已解碼位置 檢查而失敗 → 整體退回循序解碼。
    // 因此對「非分塊」串流（apple/other 產生）最壞情況只是退回循序，
    // 不可能產生錯誤輸出。
    // =================================================================

    /// other2 編碼器與平行解碼器共用的分塊原始大小
    public static let other2ChunkSize = 1 << 22   // 4MiB

    struct BlockInfo { let start: Int; let size: Int; let rawBytes: Int; let magic: UInt32 }

    /// 只讀標頭、不解 payload 的快速區塊掃描
    static func scanBlocks(_ src: [UInt8]) -> [BlockInfo]? {
        var p = 0
        var blocks: [BlockInfo] = []
        while p + 4 <= src.count {
            let magic = get32(src, p)
            switch magic {
            case magicEndOfStream:
                return blocks
            case magicUncompressed:
                guard p + 8 <= src.count else { return nil }
                let n = Int(get32(src, p + 4))
                guard p + 8 + n <= src.count else { return nil }
                blocks.append(BlockInfo(start: p, size: 8 + n, rawBytes: n, magic: magic))
                p += 8 + n
            case magicCompressedV1:
                guard p + 28 <= src.count else { return nil }
                let nRaw = Int(get32(src, p + 4))
                let nPayload = Int(get32(src, p + 8))
                let size = v1HeaderSize + nPayload
                guard p + size <= src.count else { return nil }
                blocks.append(BlockInfo(start: p, size: size, rawBytes: nRaw, magic: magic))
                p += size
            case magicCompressedV2:
                guard p + 32 <= src.count else { return nil }
                let nRaw = Int(get32(src, p + 4))
                let v0 = get64(src, p + 8), v1f = get64(src, p + 16), v2f = get64(src, p + 24)
                let nLitPayload = Int((v0 >> 20) & 0xFFFFF)
                let nLmdPayload = Int((v1f >> 40) & 0xFFFFF)
                let headerSize = Int(v2f & 0xFFFF_FFFF)
                let size = headerSize + nLitPayload + nLmdPayload
                guard headerSize >= 32, p + size <= src.count else { return nil }
                blocks.append(BlockInfo(start: p, size: size, rawBytes: nRaw, magic: magic))
                p += size
            case magicLZVN:
                guard p + 12 <= src.count else { return nil }
                let nRaw = Int(get32(src, p + 4))
                let nPayload = Int(get32(src, p + 8))
                let size = 12 + nPayload
                guard p + size <= src.count else { return nil }
                blocks.append(BlockInfo(start: p, size: size, rawBytes: nRaw, magic: magic))
                p += size
            default:
                return nil
            }
        }
        return nil // 沒有 bvx$
    }

    /// 平行解碼。chunkRaw 須與編碼端分塊大小一致（other2 預設 4MiB）。
    /// 串流不符合分塊假設時自動退回循序 decompress()，結果永遠正確。
    public static func parallelDecompress(_ input: Data,
                                          chunkRaw: Int = other2ChunkSize) -> Data? {
        let src = [UInt8](input)
        guard chunkRaw > 0, let blocks = scanBlocks(src), !blocks.isEmpty else {
            return decompress(input)
        }

        // 依累計原始大小在 chunkRaw 倍數處切組。
        // other2 串流：每分塊原始大小恰為 chunkRaw（最後一塊除外），
        // 分塊內的中途累計值嚴格落在倍數之間，不會誤切。
        var groups: [[BlockInfo]] = []
        var current: [BlockInfo] = []
        var cum = 0
        for b in blocks {
            current.append(b)
            cum += b.rawBytes
            if cum % chunkRaw == 0 && b.rawBytes > 0 {
                groups.append(current); current = []
            }
        }
        if !current.isEmpty { groups.append(current) }
        guard groups.count > 1 else { return decompress(input) } // 切不出組就循序

        var results = [[UInt8]?](repeating: nil, count: groups.count)
        let lock = NSLock()
        var anyFailed = false

        DispatchQueue.concurrentPerform(iterations: groups.count) { gi in
            var dst: [UInt8] = []
            dst.reserveCapacity(groups[gi].reduce(0) { $0 + $1.rawBytes })
            for b in groups[gi] {
                let ok: Bool
                switch b.magic {
                case magicUncompressed:
                    dst.append(contentsOf: src[(b.start + 8)..<(b.start + b.size)])
                    ok = true
                case magicCompressedV1:
                    ok = decodeV1Block(src: src, at: b.start, into: &dst) != nil
                case magicCompressedV2:
                    ok = decodeV2Block(src: src, at: b.start, into: &dst) != nil
                case magicLZVN:
                    ok = decodeLZVNBlock(src: src, at: b.start, into: &dst) != nil
                default:
                    ok = false
                }
                if !ok {   // 例如 match 跨組（非分塊串流）→ 全體退回循序
                    lock.lock(); anyFailed = true; lock.unlock()
                    return
                }
            }
            lock.lock(); results[gi] = dst; lock.unlock()
        }

        if anyFailed { return decompress(input) }
        var out = Data(capacity: blocks.reduce(0) { $0 + $1.rawBytes })
        for r in results {
            guard let r = r else { return decompress(input) }
            r.withUnsafeBufferPointer { out.append($0.baseAddress!, count: $0.count) }
        }
        return out
    }

    static func decodeV1Block(src: [UInt8], at p: Int, into dst: inout [UInt8]) -> Int? {
        guard p + v1HeaderSize <= src.count else { return nil }
        var o = p + 4
        func r32() -> UInt32 { let v = get32(src, o); o += 4; return v }
        func r16() -> UInt16 { let v = get16(src, o); o += 2; return v }

        let nRawBytes = Int(r32())         // n_raw_bytes：本區塊解碼後位元組數
        let nPayload = Int(r32())
        let nLiterals = Int(r32())
        let nMatches = Int(r32())
        let nLitPayload = Int(r32())
        let nLmdPayload = Int(r32())
        let literalBits = Int32(bitPattern: r32())
        let litState0 = Int32(r16()), litState1 = Int32(r16())
        let litState2 = Int32(r16()), litState3 = Int32(r16())
        let lmdBits = Int32(bitPattern: r32())
        let lState = Int32(r16()), mState = Int32(r16()), dState = Int32(r16())

        var lFreq = [UInt16](repeating: 0, count: lSymbols)
        var mFreq = [UInt16](repeating: 0, count: mSymbols)
        var dFreq = [UInt16](repeating: 0, count: dSymbols)
        var litFreq = [UInt16](repeating: 0, count: literalSymbols)
        for i in 0..<lSymbols { lFreq[i] = r16() }
        for i in 0..<mSymbols { mFreq[i] = r16() }
        for i in 0..<dSymbols { dFreq[i] = r16() }
        for i in 0..<literalSymbols { litFreq[i] = r16() }

        guard nPayload == nLitPayload + nLmdPayload else { return nil }
        guard decodeBlockBody(src: src, payloadStart: p + v1HeaderSize,
                              nRawBytes: nRawBytes, nLiterals: nLiterals, nMatches: nMatches,
                              nLitPayload: nLitPayload, nLmdPayload: nLmdPayload,
                              literalBits: literalBits,
                              litState0: litState0, litState1: litState1,
                              litState2: litState2, litState3: litState3,
                              lmdBits: lmdBits,
                              lState0: lState, mState0: mState, dState0: dState,
                              lFreq: lFreq, mFreq: mFreq, dFreq: dFreq, litFreq: litFreq,
                              into: &dst)
        else { return nil }
        return v1HeaderSize + nPayload
    }

    /// 壓縮區塊的共用解碼核心（v1/v2 標頭解析後皆呼叫此處；
    /// 直接在原始緩衝上解碼，零 payload 複製）
    static func decodeBlockBody(src: [UInt8], payloadStart: Int,
                                nRawBytes: Int, nLiterals: Int, nMatches: Int,
                                nLitPayload: Int, nLmdPayload: Int,
                                literalBits: Int32,
                                litState0: Int32, litState1: Int32,
                                litState2: Int32, litState3: Int32,
                                lmdBits: Int32,
                                lState0: Int32, mState0: Int32, dState0: Int32,
                                lFreq: [UInt16], mFreq: [UInt16],
                                dFreq: [UInt16], litFreq: [UInt16],
                                into dst: inout [UInt8]) -> Bool {
        var lState = lState0, mState = mState0, dState = dState0

        // 健全性檢查（lzfse_check_block_header_v1 等價 + n_raw_bytes 上界）
        // nLiterals 必須是 4 的倍數：4 路交錯解碼一次寫 4 個（編碼端有補齊）
        guard nLiterals >= 0, nMatches >= 0, nRawBytes >= 0,
              nLitPayload >= 0, nLmdPayload >= 0,
              nLiterals <= literalsPerBlock, nLiterals & 3 == 0,
              nMatches <= matchesPerBlock,
              nRawBytes <= literalsPerBlock + matchesPerBlock * maxMValue,
              litState0 < Int32(literalStates), litState1 < Int32(literalStates),
              litState2 < Int32(literalStates), litState3 < Int32(literalStates),
              lState < Int32(lStates), mState < Int32(mStates), dState < Int32(dStates),
              payloadStart >= 8,
              payloadStart + nLitPayload + nLmdPayload <= src.count
        else { return false }

        guard let litDec = initDecoderTable(nstates: literalStates, freq: litFreq) else { return false }
        let lDec = initValueDecoderTable(nstates: lStates, freq: lFreq, vbits: lExtraBits, vbase: lBaseValue)
        let mDec = initValueDecoderTable(nstates: mStates, freq: mFreq, vbits: mExtraBits, vbase: mBaseValue)
        let dDec = initValueDecoderTable(nstates: dStates, freq: dFreq, vbits: dExtraBits, vbase: dBaseValue)

        // --- 預先配置本區塊的輸出區（大小 = n_raw_bytes），之後以索引直接寫入 ---
        let litPayloadEnd = payloadStart + nLitPayload
        let lmdPayloadEnd = litPayloadEnd + nLmdPayload
        let outBase = dst.count
        dst.append(contentsOf: repeatElement(0, count: nRawBytes))

        var literals = [UInt8](repeating: 0, count: max(nLiterals, 4))
        var ok = true

        src.withUnsafeBufferPointer { sbuf in
            let sp = sbuf.baseAddress!

            // --- 解碼 literal（4 路交錯，正序）---
            literals.withUnsafeMutableBufferPointer { lbuf in
                let lp = lbuf.baseAddress!
                guard var ins = FSEInStream(base: sp, payloadEnd: litPayloadEnd,
                                            bits: literalBits) else { ok = false; return }
                // 4 條狀態流用獨立區域變數（避免陣列索引開銷）
                var s0 = litState0, s1 = litState1, s2 = litState2, s3 = litState3
                var i = 0
                while i < nLiterals {
                    guard ins.fill() else { ok = false; return }
                    var e = litDec[Int(s0)]
                    s0 = (e >> 16) + Int32(truncatingIfNeeded: ins.pull(e & 0xFF))
                    lp[i] = UInt8((e >> 8) & 0xFF)
                    e = litDec[Int(s1)]
                    s1 = (e >> 16) + Int32(truncatingIfNeeded: ins.pull(e & 0xFF))
                    lp[i + 1] = UInt8((e >> 8) & 0xFF)
                    e = litDec[Int(s2)]
                    s2 = (e >> 16) + Int32(truncatingIfNeeded: ins.pull(e & 0xFF))
                    lp[i + 2] = UInt8((e >> 8) & 0xFF)
                    e = litDec[Int(s3)]
                    s3 = (e >> 16) + Int32(truncatingIfNeeded: ins.pull(e & 0xFF))
                    lp[i + 3] = UInt8((e >> 8) & 0xFF)
                    i += 4
                }
            }
        }
        guard ok else { dst.removeLast(nRawBytes); return false }

        // --- 解碼 L,M,D 並重建輸出（指標寬複製）---
        src.withUnsafeBufferPointer { sbuf in
            let sp = sbuf.baseAddress!
            literals.withUnsafeBufferPointer { lbuf in
                let lp = lbuf.baseAddress!
                dst.withUnsafeMutableBufferPointer { dbuf in
                    let dp = dbuf.baseAddress!
                    let dstEnd = dbuf.count            // = outBase + nRawBytes
                    guard var lmdIn = FSEInStream(base: sp, payloadEnd: lmdPayloadEnd,
                                                  bits: lmdBits) else { ok = false; return }
                    var litPos = 0
                    var dstIdx = outBase
                    var d: Int32 = 0

                    @inline(__always) func valueDecode(_ state: inout Int32,
                                                       _ table: [FSEValueDecoderEntry],
                                                       _ ins: inout FSEInStream) -> Int32 {
                        let e = table[Int(state)]
                        let bits = ins.pull(e.totalBits)
                        state = e.delta + Int32(truncatingIfNeeded: bits >> UInt64(e.valueBits))
                        let mask = (UInt64(1) << UInt64(e.valueBits)) - 1
                        return e.vbase + Int32(truncatingIfNeeded: bits & mask)
                    }

                    for _ in 0..<nMatches {
                        guard lmdIn.fill() else { ok = false; return }
                        let l = Int(valueDecode(&lState, lDec, &lmdIn))
                        let m = Int(valueDecode(&mState, mDec, &lmdIn))
                        let newD = valueDecode(&dState, dDec, &lmdIn)
                        if newD != 0 { d = newD }      // d==0 → 沿用前一距離
                        let dd = Int(d)

                        // 邊界驗證：literal 來源、輸出區、距離合法性
                        guard l >= 0, m >= 0,
                              litPos + l <= nLiterals,
                              dstIdx + l + m <= dstEnd,
                              (m == 0) || (dd > 0 && dd <= dstIdx + l)
                        else { ok = false; return }

                        // ① literal：一次 memcpy
                        if l > 0 {
                            memcpy(dp + dstIdx, lp + litPos, l)
                            dstIdx += l
                            litPos += l
                        }
                        // ② match：依距離選擇複製策略（對應參考實作的 copy/byte 路徑）
                        if m > 0 {
                            let msrc = dstIdx - dd
                            if dd >= m {
                                // 無重疊 → 單次 memcpy
                                memcpy(dp + dstIdx, dp + msrc, m)
                            } else if dd >= 8 {
                                // 重疊但距離 ≥8 → 8 位元組分段複製（精確長度，不越界）
                                var k = 0
                                while k + 8 <= m {
                                    memcpy(dp + dstIdx + k, dp + msrc + k, 8)
                                    k += 8
                                }
                                while k < m { dp[dstIdx + k] = dp[msrc + k]; k += 1 }
                            } else {
                                // 近距離重疊（RLE 式樣板）→ 逐位元組
                                for k in 0..<m { dp[dstIdx + k] = dp[msrc + k] }
                            }
                            dstIdx += m
                        }
                    }
                    // n_raw_bytes 必須恰好被填滿（= Σ(L+M)）
                    if dstIdx != dstEnd { ok = false }
                }
            }
        }
        guard ok else { dst.removeLast(nRawBytes); return false }
        return true
    }
}

// =====================================================================
// MARK: - 測試 / 驗證
// =====================================================================

func runLZFSEv1Tests() {
    #if canImport(Compression)
    func appleCompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let cap = data.count + 4096
        var dstBuf = Data(count: cap)
        let written = dstBuf.withUnsafeMutableBytes { dp -> Int in
            data.withUnsafeBytes { sp -> Int in
                compression_encode_buffer(
                    dp.bindMemory(to: UInt8.self).baseAddress!, cap,
                    sp.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_LZFSE)
            }
        }
        return written > 0 ? dstBuf.prefix(written) : nil
    }
    func appleDecompress(_ data: Data, expected: Int) -> Data? {
        var dstBuf = Data(count: expected + 16)
        let written = dstBuf.withUnsafeMutableBytes { dp -> Int in
            data.withUnsafeBytes { sp -> Int in
                compression_decode_buffer(
                    dp.bindMemory(to: UInt8.self).baseAddress!, expected + 16,
                    sp.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_LZFSE)
            }
        }
        return written == expected ? dstBuf.prefix(written) : nil
    }
    #endif

    /// 模擬 -algo other2/other3 的輸出：分塊獨立壓縮（compressBody）串接 + 單一 bvx$
    func chunkedCompress(_ data: Data, chunkSize: Int, strong: Bool = false) -> Data {
        var out = Data()
        var p = 0
        while p < data.count {
            let end = min(p + chunkSize, data.count)
            out.append(LZFSEv1.compressBody(data.subdata(in: p..<end), strong: strong))
            p = end
        }
        out.append(Data([0x62, 0x76, 0x78, 0x24])) // bvx$
        return out
    }

    func check(_ label: String, _ ok: Bool?) {
        // ok == nil 表示該項在此平台不適用（例如無 Compression framework）
        if let ok = ok { print("       \(label): \(ok ? "✓" : "✗ 失敗")") }
    }

    func runCase(_ name: String, _ data: Data) {
        print("[\(name)] 原始 \(data.count) bytes")
        func pct(_ c: Int) -> String {
            data.isEmpty ? "-" : String(format: "%.1f%%", Double(c) / Double(data.count) * 100)
        }

        // ---- -algo other：單流壓縮（bvx2 標頭）----
        let packed = LZFSEv1.compress(data)
        print("       other  壓縮: \(packed.count) bytes (\(pct(packed.count)))")
        check("other 自我往返 (bvx2)", LZFSEv1.decompress(packed) == data)

        // ---- -algo other2：分塊平行格式（兩種切塊大小）----
        for cs in [1 << 20, 4096] where data.count > 0 {
            let chunked = chunkedCompress(data, chunkSize: cs)
            print("       other2 壓縮 (chunk=\(cs)): \(chunked.count) bytes (\(pct(chunked.count)))")
            check("other2 自我往返", LZFSEv1.decompress(chunked) == data)
            check("other2 平行解碼", LZFSEv1.parallelDecompress(chunked, chunkRaw: cs) == data)
            #if canImport(Compression)
            check("other2 → Apple 解碼", appleDecompress(chunked, expected: data.count) == data)
            #endif
        }
        // ---- -algo other3：強化比對（lazy + 4 候選），輸出仍為標準 bvx2 ----
        if data.count > 0 {
            let cs3 = 1 << 20
            let strong = chunkedCompress(data, chunkSize: cs3, strong: true)
            print("       other3 壓縮 (chunk=\(cs3)): \(strong.count) bytes (\(pct(strong.count)))")
            check("other3 自我往返", LZFSEv1.decompress(strong) == data)
            check("other3 平行解碼", LZFSEv1.parallelDecompress(strong, chunkRaw: cs3) == data)
            #if canImport(Compression)
            check("other3 → Apple 解碼", appleDecompress(strong, expected: data.count) == data)
            #endif
        }
        // 平行解碼對「非分塊」串流的安全後援（必須退回循序且結果正確）
        if !data.isEmpty {
            check("平行解碼後援 (單流輸入)", LZFSEv1.parallelDecompress(packed) == data)
        }

        #if canImport(Compression)
        if !data.isEmpty {
            // ---- 我們的輸出 → Apple 解碼器（位元相容性）----
            check("other → Apple 解碼", appleDecompress(packed, expected: data.count) == data)
            // ---- Apple 編碼器輸出 → 我們的兩條解碼路徑（bvx2 / bvxn）----
            if let applePacked = appleCompress(data) {
                print("       apple  壓縮: \(applePacked.count) bytes (\(pct(applePacked.count)))")
                check("Apple → other 解碼 (bvx2/bvxn)", LZFSEv1.decompress(applePacked) == data)
                check("Apple → other2 解碼 (平行路徑+後援)",
                      LZFSEv1.parallelDecompress(applePacked) == data)
                // other3 的解碼路徑與 other2 共用（皆 parallelDecompress + 後援）
                check("Apple → other3 解碼 (同平行路徑+後援)",
                      LZFSEv1.parallelDecompress(applePacked) == data)
            }
        }
        #endif
        print("")
    }

    runCase("重複文字", Data(String(repeating: "LZFSE 位元相容測試。The quick brown fox. ", count: 400).utf8))
    runCase("低熵", Data(repeating: 0x41, count: 50_000))
    runCase("隨機(不可壓)", Data((0..<8192).map { _ in UInt8.random(in: 0...255) }))
    runCase("小輸入 (Apple 走 bvxn/LZVN)", Data("hello lzvn hello lzvn hello".utf8))
    runCase("中輸入 2KB (Apple 走 bvxn)", Data(String(repeating: "lzvn block test ", count: 128).utf8))
    var mixed = Data()
    for i in 0..<2000 { mixed.append(Data("record-\(i % 97): value=\(i * 31 % 1000)\n".utf8)) }
    runCase("結構化資料", mixed)
}

// =====================================================================
// MARK: - CLI（命令列介面）
// =====================================================================
//
// Compile with: swiftc -O lzfse-cli.swift -o lzfse   （務必加 -O）
//
// -algo apple  : 使用 Apple Compression framework（OutputFilter 串流）
// -algo other  : 我們自製的位元相容 LZFSE 實作（預設）
// -algo other2 : 同 other 引擎，但壓縮採「分塊多核心平行」
// -algo other3 : other2 + 強化比對（zstd lazy 策略），輸出仍為標準 bvx2
//
// 互通性說明：
//   - "other"/"other2" 編碼的輸出是合法 LZFSE 串流，可用 "apple" 或
//     任何標準 LZFSE 解碼器解開（other2 的分塊各自獨立壓縮，串接後
//     仍是標準格式，僅壓縮率略低）。
//   - "other" 解碼器已支援全部區塊型別（bvx1/bvx2/bvxn/bvx-/bvx$），
//     因此 Apple 編碼器的輸出也可以用 other/other2 解碼。
//   - other2 解碼會先嘗試「分塊邊界平行解碼」（other2 自家串流必定
//     命中，速度隨核心數擴展）；非分塊串流自動退回循序，結果保證正確。
// =====================================================================

import Foundation

/// 把訊息寫到 stderr（避免污染 -so 的資料輸出）
func eprint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func printUsage() {
    print("""
    Usage: lzfse -encode|-decode [-algo apple|other|other2|other3] [-si|-i input] [-so|-o output] [-test] [-h]

    Commands:
      -encode       : Compress the input / 壓縮輸入內容
      -decode       : Decompress the input / 解壓縮輸入內容

    Options:
      -algo <name>  : Compression engine / 壓縮引擎 (default: other)
                        apple  : Apple Compression framework (COMPRESSION_LZFSE)
                        other  : Our own bit-compatible LZFSE implementation
                                 我們自製的位元相容 LZFSE 實作
                        other2 : Same engine, multi-core chunked compression
                                 同上引擎，壓縮與解壓皆多核心平行
                        other3 : other2 + stronger matching (lazy, 4-way history)
                                 = other2 + 強化比對（lazy+4候選），更小但較慢；
                                 輸出仍為標準 bvx2，Apple 可解
      -i <path>     : Input file path / 指定輸入檔案路徑
      -si           : Read from stdin / 從標準輸入讀取
      -o <path>     : Output file path / 指定輸出檔案路徑
      -so           : Write to stdout / 輸出至標準輸出
      -test         : Run built-in round-trip & compatibility tests / 執行內建測試
      -h            : Show this help / 顯示說明

    Notes / 注意:
      - All engines read/write standard LZFSE streams and interoperate freely.
        三種引擎讀寫的都是標準 LZFSE 串流，可任意交叉壓縮/解壓。
      - "other" now decodes all block types (bvx1/bvx2/bvxn/bvx-), including
        streams produced by Apple's encoder.
        「other」解碼器已支援全部區塊型別，含 Apple 編碼器的輸出。
      - other2 trades a little compression ratio for multi-core speed.
        other2 以些微壓縮率換取多核心壓縮速度。
    """)
}

enum Algo: String { case apple, other, other2, other3 }

// ---------------------------------------------------------------------
// 1. 解析參數 / Parse arguments
// ---------------------------------------------------------------------
let args = CommandLine.arguments

if args.contains("-h") || args.count < 2 {
    printUsage()
    exit(0)
}

if args.contains("-test") {
    runLZFSEv1Tests()
    exit(0)
}

let isEncoding = args.contains("-encode")
let isDecoding = args.contains("-decode")
guard isEncoding != isDecoding else {
    eprint("Error: Specify exactly one of -encode or -decode. / 錯誤：請指定 -encode 或 -decode 其中之一。")
    exit(1)
}

// -algo 選項，預設 other
var algo: Algo = .other
if let index = args.firstIndex(of: "-algo") {
    guard index + 1 < args.count,
          let parsed = Algo(rawValue: args[index + 1].lowercased()) else {
        eprint("Error: -algo expects \"apple\" or \"other\". / 錯誤：-algo 只接受 apple 或 other。")
        exit(1)
    }
    algo = parsed
}

#if !canImport(Compression)
if algo == .apple {
    eprint("Error: Compression framework unavailable on this platform; use -algo other. / 錯誤：此平台沒有 Compression framework，請改用 -algo other。")
    exit(1)
}
#endif

// ---------------------------------------------------------------------
// 2. 設定輸入源 / Set up input source
// ---------------------------------------------------------------------
let inputHandle: FileHandle
if args.contains("-si") {
    inputHandle = .standardInput
} else if let index = args.firstIndex(of: "-i"), index + 1 < args.count {
    let path = args[index + 1]
    do {
        inputHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    } catch {
        eprint("Error: Cannot open input \(path): \(error) / 錯誤：無法開啟輸入檔案。")
        exit(1)
    }
} else {
    eprint("Error: Input source not specified. / 錯誤：未指定輸入源。")
    exit(1)
}

// ---------------------------------------------------------------------
// 3. 設定輸出目標 / Set up output destination
// ---------------------------------------------------------------------
let outputHandle: FileHandle
if args.contains("-so") {
    outputHandle = .standardOutput
} else if let index = args.firstIndex(of: "-o"), index + 1 < args.count {
    let path = args[index + 1]
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    do {
        outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try outputHandle.truncate(atOffset: 0) // 覆寫既有內容
    } catch {
        eprint("Error: Cannot open output \(path): \(error) / 錯誤：無法開啟輸出檔案。")
        exit(1)
    }
} else {
    eprint("Error: Output destination not specified. / 錯誤：未指定輸出目標。")
    exit(1)
}

// ---------------------------------------------------------------------
// 4. 執行 / Run
// ---------------------------------------------------------------------

/// 循序解碼（other / other2 共用；已支援 bvx1 / bvx2 / bvxn / bvx-）
func runSequentialDecode(input: FileHandle, output: FileHandle) {
    let data: Data
    do {
        data = try input.readToEnd() ?? Data()
    } catch {
        eprint("Error reading input: \(error) / 讀取輸入時發生錯誤。")
        exit(1)
    }
    guard let result = LZFSEv1.decompress(data) else {
        eprint("Error: Decode failed (corrupt or truncated stream). / 錯誤：解碼失敗（串流損毀或不完整）。")
        exit(1)
    }
    output.write(result)
}

/// 多核心分塊平行壓縮（-algo other2 的編碼路徑）。
///
/// 設計重點（修正先前版本的問題）：
///   1. 純同步 GCD，不用 Task —— 頂層程式碼是 MainActor 隔離的，
///      Task{} 會繼承 MainActor，而主執行緒又被 wait() 擋住 → 死結。
///   2. 分塊以 compressBody 壓縮：內部會正確切成 ≤10000 matches /
///      ≤40000 literals 的合法區塊（先前把整個 1MB 塞單一區塊是非法串流）。
///   3. 區塊索引以值捕獲（let idx），杜絕 readIndex 參照競態。
///   4. Semaphore 限流：記憶體用量 ≈ chunkSize × 2 × 核心數。
///   5. 結果在鎖內按 writeIndex 順序排水寫出，保證輸出順序正確；
///      所有分塊寫完後才補上唯一一個 bvx$。
func runParallelEncode(input: FileHandle, output: FileHandle,
                       chunkSize: Int = LZFSEv1.other2ChunkSize,
                       strong: Bool = false) {
    let maxTasks = max(2, ProcessInfo.processInfo.activeProcessorCount)
    let sem = DispatchSemaphore(value: maxTasks)
    let lock = NSLock()
    var results: [Int: Data] = [:]
    var writeIndex = 0
    var readIndex = 0
    var failure: String? = nil
    let queue = DispatchQueue(label: "lzfse.parallel", qos: .userInitiated,
                              attributes: .concurrent)
    let group = DispatchGroup()

    while true {
        let chunk: Data?
        do { chunk = try input.read(upToCount: chunkSize) }
        catch {
            eprint("Error reading input: \(error) / 讀取輸入時發生錯誤。")
            exit(1)
        }
        guard let data = chunk, !data.isEmpty else { break }

        sem.wait()                    // 流量控制：限制在途分塊數
        let idx = readIndex           // 以值捕獲
        readIndex += 1
        group.enter()
        queue.async {
            let body = LZFSEv1.compressBody(data, strong: strong)   // 合法區塊串，不含 bvx$
            lock.lock()
            results[idx] = body
            // 任一執行緒都可在鎖內依序排水，保證輸出順序
            while let r = results.removeValue(forKey: writeIndex) {
                do { try output.write(contentsOf: r) }
                catch { failure = failure ?? "\(error)" }
                writeIndex += 1
            }
            lock.unlock()
            sem.signal()
            group.leave()
        }
    }
    group.wait()
    if let f = failure {
        eprint("Error writing output: \(f) / 寫入輸出時發生錯誤。")
        exit(1)
    }
    output.write(Data([0x62, 0x76, 0x78, 0x24]))   // 'bvx$'：唯一的結尾標記
}

switch algo {

case .apple:
    // ---- Apple Compression framework：串流式處理（來自 lzfse.swift）----
    #if canImport(Compression)
    let operation: FilterOperation = isEncoding ? .compress : .decompress
    do {
        let filter = try OutputFilter(operation, using: .lzfse) { (data: Data?) in
            if let data = data {
                outputHandle.write(data)
            }
        }
        let chunkSize = 64 * 1024 // 64KB
        while let data = try inputHandle.read(upToCount: chunkSize), !data.isEmpty {
            try filter.write(data)
        }
        try filter.finalize()
    } catch {
        eprint("Error during processing: \(error) / 處理時發生錯誤: \(error)")
        exit(1)
    }
    #endif

case .other:
    // ---- 我們自製的位元相容 LZFSE 實作（單流，緩衝式處理）----
    if isEncoding {
        let input: Data
        do {
            input = try inputHandle.readToEnd() ?? Data()
        } catch {
            eprint("Error reading input: \(error) / 讀取輸入時發生錯誤。")
            exit(1)
        }
        outputHandle.write(LZFSEv1.compress(input))
    } else {
        runSequentialDecode(input: inputHandle, output: outputHandle)
    }

case .other2, .other3:
    // ---- 同 other 引擎；壓縮與解壓都走多核心 ----
    // other3 = other2 + 強化比對（4 候選雜湊歷史 + lazy matching），
    // 輸出仍為標準 bvx2，壓縮率較佳、壓縮較慢。
    // 解碼：先嘗試以分塊邊界平行解碼（other2/other3 串流必中），
    // 非分塊串流會自動退回循序，結果保證正確。
    if isEncoding {
        runParallelEncode(input: inputHandle, output: outputHandle,
                          strong: algo == .other3)
    } else {
        let data: Data
        do {
            data = try inputHandle.readToEnd() ?? Data()
        } catch {
            eprint("Error reading input: \(error) / 讀取輸入時發生錯誤。")
            exit(1)
        }
        guard let result = LZFSEv1.parallelDecompress(data) else {
            eprint("Error: Decode failed (corrupt or truncated stream). / 錯誤：解碼失敗（串流損毀或不完整）。")
            exit(1)
        }
        outputHandle.write(result)
    }
}

// 關閉檔案句柄 / Close file handles
try? inputHandle.close()
try? outputHandle.close()
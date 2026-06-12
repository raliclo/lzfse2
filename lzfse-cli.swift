//
//  lzfse-cli.swift — 位元相容 LZFSE 實作 + 命令列工具
//
//  Compile: swiftc -O lzfse-cli.swift -o lzfse
//
//  位元相容的 LZFSE 實作
//  編碼：other3 → 標準 bvx2 / bvx- / bvx$（分塊平行）；bvx3 → 私有大字母表區塊
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

    // =================================================================
    // MARK: - bvx3 私有區塊的數值表（zstd 式大字母表；非標準 LZFSE）
    // =================================================================
    //
    // 掙脫 LZFSE 格式的 (b)(c) 限制：
    //   (b) 視窗：D 上限 262139 → 4,194,299（涵蓋整個 4MiB 分塊）
    //       D 字母表 80 符號，每 4 符號一個位元級距（extra bits = sym>>2，0..19）
    //   (c) 字母表：L/M 各 22 符號（16 直接值 + extra 2/3/5/8/12/16）
    //       M 上限 2359 → 69,947、L 上限 315 → 32,768（減少三元組切割）
    // 狀態數沿用（L/M 64、D 256、literal 1024），重用既有 tANS 機械。
    // D 通道採 3 深度 rep-offset（發射 0/1/2 = 命中歷史，其餘 = d+2）。
    // 注意：bvx3 是本工具的私有格式，Apple 解碼器無法解開。
    // =================================================================

    static let magicBVX3: UInt32 = 0x33787662   // 'bvx3'

    static let lm3ExtraBits: [UInt8] = [UInt8](repeating: 0, count: 16) + [2, 3, 5, 8, 12, 16]
    static let lm3BaseValue: [Int32] = {
        var b: [Int32] = [0]
        for e in lm3ExtraBits.dropLast() { b.append(b.last! + Int32(1 << Int(e))) }
        return b
    }()
    static let d3ExtraBits: [UInt8] = (0..<80).map { UInt8($0 >> 2) }
    static let d3BaseValue: [Int32] = {
        var b: [Int32] = [0]
        for e in d3ExtraBits.dropLast() { b.append(b.last! + Int32(1 << Int(e))) }
        return b
    }()
    static let lm3Symbols = 22
    static let d3Symbols = 80
    static let maxL3 = 32768                    // +4 ≤ literalsPerBlock，確保切塊收斂
    static let maxM3 = 69947                    // = lm3 表最大可表示值
    static let maxD3 = 4194299                  // = d3 表最大可表示值（≥ 4MiB-5）
    static let v3FixedHeaderSize = 54           // 含 literal_mode u16（格式 r2）
    static let litCtxCount = 4                  // literal 上下文數（前一位元組 >> 6）
    static let litCtxThreshold = 16384          // 多表 literal 的預篩門檻（最終由熵收益決定）
    static let matchesPerBlockV3 = 40000        // bvx3 區塊上限 ×4：攤平頻率表開銷
    static let literalsPerBlockV3 = 160000

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
    // MARK: - bvx3：本工具私有的高壓縮率區塊（zstd 啟發，非 LZFSE 標準）
    // =================================================================
    //
    // 解除 LZFSE 的兩個格式天花板（Apple 解碼器「無法」解開 bvx3）：
    //   (b) 視窗：D 表擴充至 88 符號（每層 4 個、extra bits 0..21），
    //       可表示距離 ~16.7M —— 配合 4MiB 分塊即「全分塊視窗」
    //       （LZFSE 原上限 262139 ≈ 256KB）。
    //   (c) 長度：L ≤ 18747（原 315）、M ≤ 149815（原 2359），
    //       長 match 不再切碎；且取消每區塊 10000-match 上限，
    //       一個分塊就是一個區塊，標頭成本攤提至 ~0.02%。
    // 熵編碼沿用已驗證的 tANS 機制；因 D 最寬 8+21=29 bits，
    // LMD 流改為「每值一次 flush/fill」（原設計三值共用一次）。
    // =================================================================

    static let bvx3LSymbols = 22, bvx3MSymbols = 22, bvx3DSymbols = 88
    static let bvx3MaxL = 18747
    static let bvx3MaxM = 149815
    static let bvx3MaxD = 16_777_211            // D 表覆蓋上限（實務受分塊大小限制）

    static let bvx3LExtraBits: [UInt8] = [
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 2,3,5,8, 11,14
    ]
    static let bvx3LBaseValue: [Int32] = [
        0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15, 16,20,28,60, 316,2364
    ]
    static let bvx3MExtraBits: [UInt8] = [
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 3,5,8,11, 14,17
    ]
    static let bvx3MBaseValue: [Int32] = [
        0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15, 16,24,56,312, 2360,18744
    ]
    /// D 表：每個 extra-bits 層級 4 個符號，層級 0..21（程式生成，連續無洞）
    static let bvx3DTables: (extra: [UInt8], base: [Int32]) = {
        var extra: [UInt8] = []; var base: [Int32] = []
        var b: Int32 = 0
        for level in 0...21 {
            for _ in 0..<4 {
                extra.append(UInt8(level)); base.append(b)
                b += Int32(1) << level
            }
        }
        return (extra, base)
    }()
    static var bvx3DExtraBits: [UInt8] { bvx3DTables.extra }
    static var bvx3DBaseValue: [Int32] { bvx3DTables.base }

    /// bvx3 標頭：24（計數欄位）+ 22（位元/狀態欄位）+ (22+22+88+256)*2（頻率表）= 822
    static let bvx3HeaderSize = 24 + 22 + (bvx3LSymbols + bvx3MSymbols + bvx3DSymbols + literalSymbols) * 2

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

    static func lzParseStrong(_ input: [UInt8],
                              maxL: Int = maxLValue,
                              maxM: Int = maxMValue,
                              maxDist: Int = maxDValue) -> (triplets: [Triplet], literals: [UInt8]) {
        var triplets: [Triplet] = []
        var literals: [UInt8] = []
        let n = input.count
        triplets.reserveCapacity(n >> 5 + 8)
        literals.reserveCapacity(n >> 1 + 8)

        // 把 L 切成 ≤maxL 的塊；純 literal 塊用 (L, 0, 1)（規則同 lzParse，上限參數化）
        func pushRun(l: Int, m: Int, d: Int) {
            var L = l
            while L > maxL {
                triplets.append(Triplet(l: Int32(maxL), m: 0, d: 1))
                L -= maxL
            }
            var M = m
            if M > 0 {
                while M > maxM {
                    triplets.append(Triplet(l: Int32(L), m: Int32(maxM), d: Int32(d)))
                    L = 0; M -= maxM
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
                    if d > maxDist || load32(c) != v { continue }
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
    // MARK: - 雜湊鏈 LZ 比對（bvx3；btlazy2 級搜尋深度）
    // =================================================================
    //
    // zstd 高級距（lazy2/btlazy2）的核心是「每個位置嘗試更多候選」。
    // 這裡用 head/chain 雜湊鏈取代 4 槽歷史：
    //   - 插入 O(1)：chain[i] = head[h]; head[h] = i（4 槽版要 4 次搬移）
    //   - 搜尋深度 32 個候選（4 槽版只有 4 個）
    //   - bl 探測：先比對 data[c+bl] == data[i+bl] 快速排除不可能更長的候選
    //   - rep 感知：先試 3 個 rep 距離；鏈搜尋後若 rep 長度 ≥ 最佳-2 則偏好
    //     rep（rep 在 bvx3 的編碼成本近乎為零）
    //   - 沿用 1-step 反覆 lazy matching
    // =================================================================

    static let chainHashBits = 16                 // 65536 桶
    static let chainHashSize = 1 << chainHashBits
    static let chainSearchDepth = 32              // btlazy2 級候選嘗試數
    static let chainGoodEnough = 1024             // 找到 ≥ 此長度即停止搜尋（zstd sufficient_len）
                                                  // R3 調參：512 太傷比率、4096 太慢（claw 34.5s）
                                                  // → 1024 取中間檔（深搜比例折衷）
    static let chainSearchStrength = 7            // 無 match 跳躍加速（zstd kSearchStrength）
                                                  // R3 調參：6 漏太多、8 太保守 → 7 折衷

    static func lzParseChain(_ input: [UInt8],
                             maxL: Int, maxM: Int,
                             maxDist: Int) -> (triplets: [Triplet], literals: [UInt8]) {
        var triplets: [Triplet] = []
        var literals: [UInt8] = []
        let n = input.count
        triplets.reserveCapacity(n >> 5 + 8)
        literals.reserveCapacity(n >> 1 + 8)

        func pushRun(l: Int, m: Int, d: Int) {
            var L = l
            while L > maxL {
                triplets.append(Triplet(l: Int32(maxL), m: 0, d: 1))
                L -= maxL
            }
            var M = m
            if M > 0 {
                while M > maxM {
                    triplets.append(Triplet(l: Int32(L), m: Int32(maxM), d: Int32(d)))
                    L = 0; M -= maxM
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

        let head = UnsafeMutablePointer<Int32>.allocate(capacity: chainHashSize)
        head.initialize(repeating: -1, count: chainHashSize)
        let chain = UnsafeMutablePointer<Int32>.allocate(capacity: n)
        chain.initialize(repeating: -1, count: n)
        defer { head.deallocate(); chain.deallocate() }

        // 解析器側 rep 歷史（近似編碼端 transform 的歷史；
        // 不一致只影響選擇品質，不影響正確性——transform 會重算實際發射值）
        var rep0p: Int = 0, rep1p: Int = 0, rep2p: Int = 0

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
                Int((load32(idx) &* 2654435761) >> (32 - UInt32(chainHashBits)))
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
            @inline(__always) func insert(_ idx: Int) {
                let h = hash4(idx)
                chain[idx] = head[h]
                head[h] = Int32(idx)
            }
            @inline(__always) func repLen(_ idx: Int, _ r: Int) -> Int {
                guard r > 0, r <= idx, load32(idx - r) == load32(idx) else { return 0 }
                return 4 + matchLength(idx - r + 4, idx + 4, limit: n - idx - 4)
            }
            /// 候選搜尋：rep 先行 → 鏈走訪（bl 探測）→ rep 接近最佳時偏好 rep
            @inline(__always) func bestMatch(_ idx: Int) -> (len: Int, dist: Int) {
                var bl = 0, bd = 1
                // ① rep 距離先試（命中時編碼成本近零）
                for r in [rep0p, rep1p, rep2p] {
                    let l = repLen(idx, r)
                    if l > bl { bl = l; bd = r }
                }
                // ② 雜湊鏈走訪（深度上限 + bl 快速排除 + good-enough 提前退出）
                //    rep 已達 good-enough 時整段跳過 —— 零填充等長 run 區段
                //    （所有位置同雜湊、鏈最稠密）正是靠這個避開病態成本
                if bl < chainGoodEnough {
                    let v = load32(idx)
                    var c = Int(head[hash4(idx)])
                    var depth = chainSearchDepth
                    while c >= 0 && depth > 0 {
                        let d = idx - c
                        if d > maxDist { break }   // 鏈愈走愈舊，超距即停
                        if (bl == 0 || (idx + bl < n && p[c + bl] == p[idx + bl])),
                           load32(c) == v {
                            let l = 4 + matchLength(c + 4, idx + 4, limit: n - idx - 4)
                            if l > bl || (l == bl && d < bd) {
                                bl = l; bd = d
                                if bl >= chainGoodEnough { break }   // 夠長即收
                            }
                        }
                        c = Int(chain[c])
                        depth -= 1
                    }
                }
                // ③ rep 長度接近最佳（差 ≤2）時改選 rep
                if bd != rep0p && bd != rep1p && bd != rep2p {
                    for r in [rep0p, rep1p, rep2p] where r != bd {
                        let l = repLen(idx, r)
                        if l >= bl - 2 && l >= 4 { bl = l; bd = r; break }
                    }
                }
                return (bl, bd)
            }

            var i = 0
            while i + 4 <= n {
                var (m0, d0) = bestMatch(i)
                insert(i)
                if m0 < 4 {
                    // 跳躍加速（zstd lazy 的關鍵快路徑）：離上個 match 愈久跳愈大步。
                    // 難匹配區段（二進位、已壓縮資產）從「每 byte 全深度搜尋」
                    // 降為步進搜尋 —— 這是先前慢 30 倍的最大根因。
                    i += 1 + ((i - litStart) >> chainSearchStrength)
                    continue
                }

                // lazy matching：僅在目前 match 尚短時才付第二次搜尋成本
                while i + 5 <= n && m0 < chainGoodEnough {
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
                // 更新解析器側 rep 歷史（去重後保留 3 深度）
                if d0 != rep0p {
                    if d0 == rep1p {
                        rep1p = rep0p; rep0p = d0
                    } else {
                        rep2p = rep1p; rep1p = rep0p; rep0p = d0
                    }
                }
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
    // MARK: - Optimal parsing（bvx3 -optimal；zstd btultra 式價格驅動解析）
    // =================================================================
    //
    // 以分段動態規劃（DP）取代貪婪/lazy 決策——這是 zstd 高級距
    // （btopt/btultra）真正的比率來源：
    //   - 每 128K 位置一個 DP 段；每個 cell 儲存「抵達該位置的最小編碼成本」
    //     （1/16-bit 定點）、抵達步驟（literal 或 (len,dist) match）、
    //     以及該最佳路徑的 rep-offset 歷史（zstd opt 的 per-cell rep 追蹤）
    //   - 候選：3 個 rep 距離（編碼成本近零，DP 內以真實 rep 價格計）
    //     + 雜湊鏈 Pareto frontier（len 遞增；suffix-min 取每長度最便宜距離）
    //   - 自適應價格：literal / M / D 符號直方圖每段重建一次（log2 → 定點）
    //   - 巨型 match（≥ optSufficientLen）直接貪婪提交並截斷 DP 段——
    //     既是 zstd 的 sufficient_len 策略，也是病態輸入（等長 run）的成本上界
    //
    // 正確性已以 Python 模型驗證：300 組隨機分段/閾值往返 + 格式約束全過；
    // 模型上對 text/structured 資料相對 lazy 解析有 9–10% 的成本下降。
    // =================================================================

    static let optSegmentSize = 1 << 17       // DP 段：128K cells
    static let optSearchDepth = 16            // 雜湊鏈候選深度（R3：32→16，suffix-min 保留近距優先）
    static let optSufficientLen = 192         // ≥ 此長度直接貪婪提交（R3：512→192，zstd btopt 級）
    static let optDenseLen = 64               // 逐長度松弛上限；以上改 stride-4 + 精確 maxLen（R3）
    static let optBarrenStreak = 32           // 連續無 match 位置數 ≥ 此值 → 降深度搜尋（R3）
    static let optBarrenDepth = 4             // 荒漠區段的鏈走訪深度（R3）

    static func lzParseOptimal(_ input: [UInt8],
                               maxL: Int, maxM: Int,
                               maxDist: Int) -> (triplets: [Triplet], literals: [UInt8]) {
        var triplets: [Triplet] = []
        var literals: [UInt8] = []
        let n = input.count
        triplets.reserveCapacity(n >> 5 + 8)
        literals.reserveCapacity(n >> 1 + 8)

        func pushRun(l: Int, m: Int, d: Int) {
            var L = l
            while L > maxL {
                triplets.append(Triplet(l: Int32(maxL), m: 0, d: 1))
                L -= maxL
            }
            var M = m
            if M > 0 {
                while M > maxM {
                    triplets.append(Triplet(l: Int32(L), m: Int32(maxM), d: Int32(d)))
                    L = 0; M -= maxM
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

        // ---- 雜湊鏈（head/chain 結構同 lzParseChain）----
        let head = UnsafeMutablePointer<Int32>.allocate(capacity: chainHashSize)
        head.initialize(repeating: -1, count: chainHashSize)
        let chain = UnsafeMutablePointer<Int32>.allocate(capacity: n)
        chain.initialize(repeating: -1, count: n)
        defer { head.deallocate(); chain.deallocate() }

        // ---- DP cell 陣列（一次配置、各段重用；約 3MB）----
        let segCap = optSegmentSize
        let INF: Int32 = .max / 4
        let cPrice = UnsafeMutablePointer<Int32>.allocate(capacity: segCap + 1)
        let cLen   = UnsafeMutablePointer<Int32>.allocate(capacity: segCap + 1)
        let cDist  = UnsafeMutablePointer<Int32>.allocate(capacity: segCap + 1)
        let cR0    = UnsafeMutablePointer<Int32>.allocate(capacity: segCap + 1)
        let cR1    = UnsafeMutablePointer<Int32>.allocate(capacity: segCap + 1)
        let cR2    = UnsafeMutablePointer<Int32>.allocate(capacity: segCap + 1)
        cPrice.initialize(repeating: INF, count: segCap + 1)
        cLen.initialize(repeating: 0, count: segCap + 1)
        cDist.initialize(repeating: 0, count: segCap + 1)
        cR0.initialize(repeating: 0, count: segCap + 1)
        cR1.initialize(repeating: 0, count: segCap + 1)
        cR2.initialize(repeating: 0, count: segCap + 1)
        defer {
            cPrice.deallocate(); cLen.deallocate(); cDist.deallocate()
            cR0.deallocate(); cR1.deallocate(); cR2.deallocate()
        }
        // 回溯步驟緩衝（stepLen==0 表 literal 步）；frontier 緩衝（≤ 深度 項）
        let stepLen  = UnsafeMutablePointer<Int32>.allocate(capacity: segCap + 1)
        let stepDist = UnsafeMutablePointer<Int32>.allocate(capacity: segCap + 1)
        let frCap = optSearchDepth + 1
        let frLen   = UnsafeMutablePointer<Int32>.allocate(capacity: frCap)
        let frDist  = UnsafeMutablePointer<Int32>.allocate(capacity: frCap)
        let frPrice = UnsafeMutablePointer<Int32>.allocate(capacity: frCap)
        let frMin   = UnsafeMutablePointer<Int32>.allocate(capacity: frCap)
        defer {
            stepLen.deallocate(); stepDist.deallocate()
            frLen.deallocate(); frDist.deallocate(); frPrice.deallocate(); frMin.deallocate()
        }

        // ---- 自適應價格模型（1/16-bit 定點；每段以累計統計重建）----
        var litCount  = [UInt32](repeating: 1, count: 256)
        var mSymCount = [UInt32](repeating: 1, count: lm3Symbols)
        var dSymCount = [UInt32](repeating: 1, count: d3Symbols)
        dSymCount[0] = 4; dSymCount[1] = 4; dSymCount[2] = 4   // 溫和偏好 rep
        for b in input { litCount[Int(b)] &+= 1 }              // literal 先驗 = 輸入直方圖
        // 價格表用原始指標（R3：熱迴圈免去 Swift 陣列邊界檢查）
        let litPrice  = UnsafeMutablePointer<Int32>.allocate(capacity: 256)
        let mPriceTab = UnsafeMutablePointer<Int32>.allocate(capacity: lm3Symbols)
        let dPriceTab = UnsafeMutablePointer<Int32>.allocate(capacity: d3Symbols)
        let lmBaseP   = UnsafeMutablePointer<Int32>.allocate(capacity: lm3Symbols)
        litPrice.initialize(repeating: 96, count: 256)
        mPriceTab.initialize(repeating: 96, count: lm3Symbols)
        dPriceTab.initialize(repeating: 96, count: d3Symbols)
        for s in 0..<lm3Symbols { lmBaseP[s] = lm3BaseValue[s] }
        defer {
            litPrice.deallocate(); mPriceTab.deallocate()
            dPriceTab.deallocate(); lmBaseP.deallocate()
        }
        let matchConst: Int32 = 80   // L 符號 + 狀態位元的攤提常數（~5 bits）

        func rebuildPrices() {
            var tot = 0.0
            for c in litCount { tot += Double(c) }
            for b in 0..<256 {
                let bits = log2(tot / Double(litCount[b]))
                litPrice[b] = Int32(max(16.0, min(240.0, (bits * 16).rounded())))
            }
            tot = 0; for c in mSymCount { tot += Double(c) }
            for s in 0..<lm3Symbols {
                let bits = log2(tot / Double(mSymCount[s]))
                mPriceTab[s] = Int32(max(16.0, min(384.0, (bits * 16).rounded())))
                             + 16 * Int32(lm3ExtraBits[s])
            }
            tot = 0; for c in dSymCount { tot += Double(c) }
            for s in 0..<d3Symbols {
                let bits = log2(tot / Double(dSymCount[s]))
                dPriceTab[s] = Int32(max(16.0, min(384.0, (bits * 16).rounded())))
                             + 16 * Int32(d3ExtraBits[s])
            }
        }

        // 已提交路徑的 rep 歷史（鏡像 encodeBlockV3 的 transform；
        // 區塊邊界 reset 的偏差只影響選擇品質，不影響正確性）
        var rep0 = 0, rep1 = 0, rep2 = 0
        var litStart = 0
        var segStart = 0

        input.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!

            @inline(__always) func load32(_ idx: Int) -> UInt32 {
                var v: UInt32 = 0; memcpy(&v, p + idx, 4); return UInt32(littleEndian: v)
            }
            @inline(__always) func load64(_ idx: Int) -> UInt64 {
                var v: UInt64 = 0; memcpy(&v, p + idx, 8); return UInt64(littleEndian: v)
            }
            @inline(__always) func hash4(_ idx: Int) -> Int {
                Int((load32(idx) &* 2654435761) >> (32 - UInt32(chainHashBits)))
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
            @inline(__always) func insert(_ idx: Int) {
                let h = hash4(idx)
                chain[idx] = head[h]
                head[h] = Int32(idx)
            }
            @inline(__always) func dSym(_ d: Int) -> Int {
                symbol(forValue: Int32(d) + 2, base: d3BaseValue)
            }
            @inline(__always) func repsAfter(_ d: Int32, _ r0: Int32, _ r1: Int32,
                                             _ r2: Int32) -> (Int32, Int32, Int32) {
                if d == r0 { return (r0, r1, r2) }
                if d == r1 { return (r1, r0, r2) }
                if d == r2 { return (r2, r0, r1) }
                return (d, r0, r1)
            }

            /// 發射一段已回溯的最佳路徑（stepLen/stepDist 由回溯「反向」填入，
            /// 故由 count-1 往 0 走即為正序）。含統計更新與 rep 歷史推進。
            func emitSteps(_ count: Int, from start: Int) -> Int {
                var i = start
                var k = count - 1
                while k >= 0 {
                    let sl = Int(stepLen[k])
                    if sl == 0 {
                        i += 1
                    } else {
                        let sd = Int(stepDist[k])
                        literals.append(contentsOf: UnsafeBufferPointer(start: p + litStart,
                                                                        count: i - litStart))
                        var j = litStart
                        while j < i { litCount[Int(p[j])] &+= 1; j += 1 }
                        pushRun(l: i - litStart, m: sl, d: sd)
                        mSymCount[symbol(forValue: Int32(min(sl, maxM)),
                                         base: lm3BaseValue)] &+= 1
                        if sd == rep0 { dSymCount[0] &+= 1 }
                        else if sd == rep1 { dSymCount[1] &+= 1 }
                        else if sd == rep2 { dSymCount[2] &+= 1 }
                        else { dSymCount[dSym(sd)] &+= 1 }
                        if sd != rep0 {
                            if sd == rep1 {
                                swap(&rep0, &rep1)
                            } else if sd == rep2 {
                                let t = rep2; rep2 = rep1; rep1 = rep0; rep0 = t
                            } else {
                                rep2 = rep1; rep1 = rep0; rep0 = sd
                            }
                        }
                        i += sl
                        litStart = i
                    }
                    k -= 1
                }
                return i
            }

            while segStart < n {
                rebuildPrices()
                let segEnd = min(segStart + segCap, n)
                let segLen = segEnd - segStart
                cPrice.update(repeating: INF, count: segLen + 1)
                cPrice[0] = 0
                cR0[0] = Int32(rep0); cR1[0] = Int32(rep1); cR2[0] = Int32(rep2)

                var cutT = -1, cutLen = 0, cutDist = 0
                var barren = 0          // 連續無 match 的位置數（荒漠偵測，R3）
                var t = 0
                posLoop: while t < segLen {
                    let i = segStart + t
                    let base = cPrice[t]
                    let r0 = cR0[t], r1 = cR1[t], r2 = cR2[t]
                    // ── literal 步 ──
                    let litStep = base + litPrice[Int(p[i])]
                    if litStep < cPrice[t + 1] {
                        cPrice[t + 1] = litStep; cLen[t + 1] = 0; cDist[t + 1] = 0
                        cR0[t + 1] = r0; cR1[t + 1] = r1; cR2[t + 1] = r2
                    }
                    if i + 4 > n { t += 1; continue }
                    let candHead = Int(head[hash4(i)])  // 先取候選再插入（避免自我參照）
                    insert(i)
                    let v = load32(i)
                    let cap = segEnd - i
                    // ── ① rep 候選（去重；含巨型 match 提交檢查）──
                    var bestRep = 0
                    for rIdx in 0..<3 {
                        let r: Int32 = rIdx == 0 ? r0 : (rIdx == 1 ? r1 : r2)
                        if rIdx == 1 && r == r0 { continue }
                        if rIdx == 2 && (r == r0 || r == r1) { continue }
                        let rd = Int(r)
                        guard rd > 0, rd <= i, load32(i - rd) == v else { continue }
                        let l = 4 + matchLength(i - rd + 4, i + 4, limit: n - i - 4)
                        if l > bestRep { bestRep = l }
                        if l >= optSufficientLen {
                            cutT = t; cutLen = min(l, n - i); cutDist = rd
                            break posLoop
                        }
                        let dpr = dPriceTab[rIdx]
                        let (n0, n1, n2) = repsAfter(r, r0, r1, r2)
                        var msym = 4
                        var ll = 4
                        let lim = min(l, cap)
                        while ll <= lim {
                            while msym + 1 < lm3Symbols && Int32(ll) >= lmBaseP[msym + 1] {
                                msym += 1
                            }
                            let c2 = base + matchConst + mPriceTab[msym] + dpr
                            let dest = t + ll
                            if c2 < cPrice[dest] {
                                cPrice[dest] = c2; cLen[dest] = Int32(ll); cDist[dest] = r
                                cR0[dest] = n0; cR1[dest] = n1; cR2[dest] = n2
                            }
                            if ll == lim { break }
                            // R3：≥ optDenseLen 後改 stride-4（模型驗證比率零損失）
                            ll = min(ll + (ll < optDenseLen ? 1 : 4), lim)
                        }
                    }
                    // ── ② 雜湊鏈 Pareto frontier（len 遞增）──
                    if bestRep < optSufficientLen {
                        var frCount = 0
                        var bl = max(3, bestRep)   // rep 已涵蓋 ≤ bestRep 的長度
                        var c = candHead
                        // R3：荒漠區段（連續無 match）降深度——llama 類二進位資料的主要成本
                        var depth = barren >= optBarrenStreak ? optBarrenDepth : optSearchDepth
                        while c >= 0 && depth > 0 {
                            if c >= i { break }
                            let dd = i - c
                            if dd > maxDist { break }
                            if Int32(dd) != r0 && Int32(dd) != r1 && Int32(dd) != r2,
                               (i + bl >= n || p[c + bl] == p[i + bl]),
                               load32(c) == v {
                                let l = 4 + matchLength(c + 4, i + 4, limit: n - i - 4)
                                if l > bl {
                                    bl = l
                                    frLen[frCount] = Int32(l)
                                    frDist[frCount] = Int32(dd)
                                    frPrice[frCount] = dPriceTab[dSym(dd)]
                                    frCount += 1
                                    if l >= optSufficientLen { break }
                                }
                            }
                            c = Int(chain[c])
                            depth -= 1
                        }
                        if frCount > 0 {
                            if Int(frLen[frCount - 1]) >= optSufficientLen {
                                cutT = t
                                cutLen = min(Int(frLen[frCount - 1]), n - i)
                                cutDist = Int(frDist[frCount - 1])
                                break posLoop
                            }
                            // suffix argmin：每個長度取「夠長候選中最便宜的距離」
                            frMin[frCount - 1] = Int32(frCount - 1)
                            var k = frCount - 2
                            while k >= 0 {
                                frMin[k] = frPrice[k] <= frPrice[Int(frMin[k + 1])]
                                         ? Int32(k) : frMin[k + 1]
                                k -= 1
                            }
                            let maxLen = min(Int(frLen[frCount - 1]), cap)
                            var fk = 0
                            var msym = 4
                            var ll = 4
                            while ll <= maxLen {
                                while Int(frLen[fk]) < ll { fk += 1 }
                                let e = Int(frMin[fk])
                                while msym + 1 < lm3Symbols && Int32(ll) >= lmBaseP[msym + 1] {
                                    msym += 1
                                }
                                let c2 = base + matchConst + mPriceTab[msym] + frPrice[e]
                                let dest = t + ll
                                if c2 < cPrice[dest] {
                                    let dd = frDist[e]
                                    cPrice[dest] = c2; cLen[dest] = Int32(ll); cDist[dest] = dd
                                    let (n0, n1, n2) = repsAfter(dd, r0, r1, r2)
                                    cR0[dest] = n0; cR1[dest] = n1; cR2[dest] = n2
                                }
                                if ll == maxLen { break }
                                // R3：≥ optDenseLen 後改 stride-4（模型驗證比率零損失）
                                ll = min(ll + (ll < optDenseLen ? 1 : 4), maxLen)
                            }
                        }
                        // 荒漠計數：本位置 rep 與鏈皆無 match（frontier 空、rep 無命中）
                        if frCount == 0 && bestRep < 4 { barren += 1 } else { barren = 0 }
                    } else {
                        barren = 0
                    }
                    t += 1
                }

                // ── 回溯（cell 抵達步驟反向收集）與發射 ──
                let endT = cutT >= 0 ? cutT : segLen
                var sc = 0
                var tt = endT
                while tt > 0 {
                    let sl = cLen[tt]
                    if sl == 0 { stepLen[sc] = 0; stepDist[sc] = 0; tt -= 1 }
                    else { stepLen[sc] = sl; stepDist[sc] = cDist[tt]; tt -= Int(sl) }
                    sc += 1
                }
                var i = emitSteps(sc, from: segStart)
                if cutT >= 0 {
                    // 巨型 match 貪婪提交（可越過 segEnd；pushRun 會切 M 上限）
                    stepLen[0] = Int32(cutLen); stepDist[0] = Int32(cutDist)
                    i = emitSteps(1, from: i)
                    // 補插入被跳過的位置（cutT 位置本身已於 DP 中插入）
                    var j = segStart + cutT + 1
                    let jEnd = min(i, n - 3)
                    while j < jEnd { insert(j); j += 1 }
                    segStart = i
                } else {
                    segStart = segEnd
                }
            }

            // 尾端 literal
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

    @inline(__always)
    static func put32(_ v: UInt32, _ out: inout [UInt8]) {
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8((v >> 24) & 0xFF))
    }
    @inline(__always)
    static func put16(_ v: UInt16, _ out: inout [UInt8]) {
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
    }
    @inline(__always)
    static func get32(_ d: [UInt8], _ p: Int) -> UInt32 {
        UInt32(d[p]) | UInt32(d[p+1]) << 8 | UInt32(d[p+2]) << 16 | UInt32(d[p+3]) << 24
    }
    @inline(__always)
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

    /// 將一個區塊編成 bvx3 私有區塊（大字母表 + 4MiB 視窗；非標準 LZFSE）
    /// 標頭：52 bytes 固定部分 + 固定 Huffman 頻率位元流（380 值）
    static func encodeBlockV3(triplets: ArraySlice<Triplet>,
                              literals: ArraySlice<UInt8>,
                              rawBytes: Int) -> [UInt8] {
        var lits = Array(literals)
        while lits.count & 3 != 0 { lits.append(0) }

        var lVals = [Int32](), mVals = [Int32](), dVals = [Int32]()
        lVals.reserveCapacity(triplets.count)
        for t in triplets { lVals.append(t.l); mVals.append(t.m); dVals.append(t.d) }
        let nMatches = lVals.count

        // 3 深度 rep-offset（zstd 式）：發射值 0/1/2 = 命中 rep0/1/2，
        // 其餘 = 真實距離 +2。命中者落在 d3 符號 0/1/2（0 extra bits）。
        // rep1/rep2 命中採 move-to-front；歷史每區塊歸零。
        // 純 literal 三元組（M=0）一律發 0：吃 rep0、不動歷史、近零成本。
        var rep0: Int32 = 0, rep1: Int32 = 0, rep2: Int32 = 0
        for i in 0..<nMatches {
            if mVals[i] == 0 { dVals[i] = 0; continue }
            let d = dVals[i]
            if d == rep0 {
                dVals[i] = 0
            } else if d == rep1 {
                dVals[i] = 1
                swap(&rep0, &rep1)
            } else if d == rep2 {
                dVals[i] = 2
                let t = rep2; rep2 = rep1; rep1 = rep0; rep0 = t
            } else {
                dVals[i] = d + 2
                rep2 = rep1; rep1 = rep0; rep0 = d
            }
        }

        var lOcc = [UInt32](repeating: 0, count: lm3Symbols)
        var mOcc = [UInt32](repeating: 0, count: lm3Symbols)
        var dOcc = [UInt32](repeating: 0, count: d3Symbols)
        var litOcc = [UInt32](repeating: 0, count: literalSymbols)
        var lSyms = [UInt8](repeating: 0, count: nMatches)
        var mSyms = [UInt8](repeating: 0, count: nMatches)
        var dSyms = [UInt8](repeating: 0, count: nMatches)
        for i in 0..<nMatches {
            let ls = symbol(forValue: lVals[i], base: lm3BaseValue)
            let ms = symbol(forValue: mVals[i], base: lm3BaseValue)
            let ds = symbol(forValue: dVals[i], base: d3BaseValue)
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

        let litCap = lits.count * 2 + 16
        let lmdCap = nMatches * 12 + 32     // 每 match ≤71 bits、逐欄位 flush
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: litCap + lmdCap)
        defer { scratch.deallocate() }

        // ① literal：4 路交錯。literal 數達門檻時啟用「上下文多表」——
        //    以前一個 literal 的高 2 位元選表（4 張 tANS 表、狀態流共享）；
        //    解碼端用「已解出的前一 literal」取得同一上下文，逐步表一致即合法。
        // 多表 literal 的「數據驅動」開關：
        // 只有當（單表熵 − 4 表熵）的增益 > 多出 3 張頻率表的實際編碼成本
        // 時才啟用 —— 先前固定門檻在真實資料上是淨負收益（表成本攤不回來）。
        var literalMode = 0
        var litFreqCtx: [[UInt16]] = []
        var litEncCtx: [[FSEEncoderEntry]] = []
        if lits.count >= litCtxThreshold {
            var ctxOcc = [[UInt32]](repeating: [UInt32](repeating: 0, count: literalSymbols),
                                    count: litCtxCount)
            var prevB = 0
            for b in lits {
                ctxOcc[prevB >> 6][Int(b)] += 1
                prevB = Int(b)
            }
            func entropyBits(_ c: [UInt32]) -> Double {
                var total = 0.0
                for v in c { total += Double(v) }
                guard total > 0 else { return 0 }
                var e = 0.0
                for v in c where v > 0 {
                    let pr = Double(v) / total
                    e -= Double(v) * log2(pr)
                }
                return e
            }
            func freqCostBits(_ f: [UInt16]) -> Int {
                var bits = 0
                for v in f { bits += Int(encodeFreqValue(Int(v)).nbits) }
                return bits
            }
            let eSingle = entropyBits(litOcc)
            var eCtx = 0.0
            for c in ctxOcc { eCtx += entropyBits(c) }
            let ctxFreqs = ctxOcc.map { normalizeFreq(nstates: literalStates, counts: $0) }
            var ctxFreqCost = 0
            for f in ctxFreqs { ctxFreqCost += freqCostBits(f) }
            let extraCost = Double(ctxFreqCost - freqCostBits(litFreq)) + 64.0  // 64 bits 安全邊界
            if eSingle - eCtx > extraCost {
                literalMode = 1
                litFreqCtx = ctxFreqs
                for f in ctxFreqs {
                    litEncCtx.append(initEncoderTable(nstates: literalStates, freq: f))
                }
            }
        }

        var litOut = FSEOutStream(scratch)
        var s0: Int32 = 0, s1: Int32 = 0, s2: Int32 = 0, s3: Int32 = 0
        lits.withUnsafeBufferPointer { lp in
            if literalMode == 1 {
                var st: [Int32] = [0, 0, 0, 0]
                var i = lits.count
                while i > 0 {
                    i -= 4
                    var j = 3
                    while j >= 0 {
                        let p = i + j
                        let c = p > 0 ? Int(lp[p - 1]) >> 6 : 0
                        fseEncode(state: &st[j], litEncCtx[c][Int(lp[p])], &litOut)
                        j -= 1
                    }
                    litOut.flush()
                }
                s0 = st[0]; s1 = st[1]; s2 = st[2]; s3 = st[3]
            } else {
                var i = lits.count
                while i > 0 {
                    i -= 4
                    fseEncode(state: &s3, litEnc[Int(lp[i + 3])], &litOut)
                    fseEncode(state: &s2, litEnc[Int(lp[i + 2])], &litOut)
                    fseEncode(state: &s1, litEnc[Int(lp[i + 1])], &litOut)
                    fseEncode(state: &s0, litEnc[Int(lp[i + 0])], &litOut)
                    litOut.flush()
                }
            }
        }
        let literalBits = litOut.finish()
        let litLen = litOut.count

        // ② L,M,D：大字母表 → 每 match 最壞 71 bits，逐欄位 flush
        var lmdOut = FSEOutStream(scratch + litCap)
        memset(scratch + litCap, 0, 8)
        lmdOut.ptr += 8
        var lState: Int32 = 0, mState: Int32 = 0, dState: Int32 = 0
        var mi = nMatches
        while mi > 0 {
            mi -= 1
            let dsym = Int(dSyms[mi])           // D ≤ 8+19 = 27 bits
            lmdOut.push(Int32(d3ExtraBits[dsym]), UInt64(dVals[mi] - d3BaseValue[dsym]))
            fseEncode(state: &dState, dEnc[dsym], &lmdOut)
            lmdOut.flush()
            let msym = Int(mSyms[mi])           // M ≤ 6+16 = 22 bits
            lmdOut.push(Int32(lm3ExtraBits[msym]), UInt64(mVals[mi] - lm3BaseValue[msym]))
            fseEncode(state: &mState, mEnc[msym], &lmdOut)
            lmdOut.flush()
            let lsym = Int(lSyms[mi])           // L ≤ 6+16 = 22 bits
            lmdOut.push(Int32(lm3ExtraBits[lsym]), UInt64(lVals[mi] - lm3BaseValue[lsym]))
            fseEncode(state: &lState, lEnc[lsym], &lmdOut)
            lmdOut.flush()
        }
        let lmdBits = lmdOut.finish()
        let lmdLen = lmdOut.count

        // ③ 頻率表（380 值，固定 Huffman、LSB 先入）
        var freqBytes: [UInt8] = []
        freqBytes.reserveCapacity(literalMode == 1 ? 1200 : 420)
        var fAccum: UInt32 = 0
        var fNBits: Int32 = 0
        let freqTables: [[UInt16]] = literalMode == 1
            ? [lFreq, mFreq, dFreq] + litFreqCtx
            : [lFreq, mFreq, dFreq, litFreq]
        for table in freqTables {
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
        if fNBits > 0 { freqBytes.append(UInt8(fAccum & 0xFF)) }

        // ④ 組裝 bvx3 標頭（52 bytes 固定 + freq）
        let headerSize = v3FixedHeaderSize + freqBytes.count
        var out: [UInt8] = []
        out.reserveCapacity(headerSize + litLen + lmdLen)
        put32(magicBVX3, &out)
        put32(UInt32(rawBytes), &out)
        put32(UInt32(litLen + lmdLen), &out)
        put32(UInt32(lits.count), &out)
        put32(UInt32(nMatches), &out)
        put32(UInt32(litLen), &out)
        put32(UInt32(lmdLen), &out)
        put32(UInt32(bitPattern: literalBits), &out)
        put16(UInt16(s0), &out); put16(UInt16(s1), &out)
        put16(UInt16(s2), &out); put16(UInt16(s3), &out)
        put32(UInt32(bitPattern: lmdBits), &out)
        put16(UInt16(lState), &out); put16(UInt16(mState), &out); put16(UInt16(dState), &out)
        put16(UInt16(literalMode), &out)
        put16(UInt16(headerSize), &out)
        assert(out.count == v3FixedHeaderSize)
        out.append(contentsOf: freqBytes)
        out.append(contentsOf: UnsafeBufferPointer(start: scratch, count: litLen))
        out.append(contentsOf: UnsafeBufferPointer(start: scratch + litCap, count: lmdLen))
        return out
    }

    // =================================================================
    // MARK: - LZVN 編碼器（小輸入 < 4096 bytes；輸出標準 bvxn，Apple 可解）
    // =================================================================
    //
    // 小輸入扛不動 FSE 頻率表的固定開銷（bvx2 ~100–150B、bvx3 更大），
    // 參考實作對 <4096B 輸入走 LZVN —— 12B 標頭、無表、純操作碼流。
    // 操作碼語意先前已以 Python 模型驗證（×800 + pre_d/nop 手工案例）。
    // =================================================================

    static let lzvnThreshold = 4096

    /// 回傳完整 bvxn 區塊（含 12B 標頭）；若編出來不比 raw 區塊小則回傳 nil
    static func lzvnEncodeBlock(_ bytes: [UInt8]) -> [UInt8]? {
        let n = bytes.count
        guard n > 0 else { return nil }
        var payload: [UInt8] = []
        payload.reserveCapacity(n + n / 8 + 16)

        var dPrev = 0
        var litStart = 0

        /// 把 [litStart, i-keep) 以 sml_l / lrg_l 送出，保留 keep 個給距離操作碼內嵌
        func flushLiterals(upTo i: Int, keep: Int) {
            var run = i - keep - litStart
            while run > 0 {
                let take = min(run, 271)
                if take >= 16 {
                    payload.append(0xE0); payload.append(UInt8(take - 16))   // lrg_l
                } else {
                    payload.append(0xE0 | UInt8(take))                       // sml_l
                }
                payload.append(contentsOf: bytes[litStart..<(litStart + take)])
                litStart += take
                run -= take
            }
        }

        bytes.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!
            var ht = [Int32](repeating: -1, count: 1 << 12)
            @inline(__always) func load32(_ idx: Int) -> UInt32 {
                var v: UInt32 = 0; memcpy(&v, p + idx, 4); return UInt32(littleEndian: v)
            }
            @inline(__always) func hash(_ idx: Int) -> Int {
                Int((load32(idx) &* 2654435761) >> 20)
            }
            var i = 0
            while i + 4 <= n {
                let h = hash(i)
                let cand = Int(ht[h]); ht[h] = Int32(i)
                var mlen = 0
                if cand >= 0, i - cand <= 0x3FFF, load32(cand) == load32(i) {
                    mlen = 4
                    while i + mlen < n && p[cand + mlen] == p[i + mlen] && mlen < 34 { mlen += 1 }
                }
                guard mlen >= 4 else { i += 1; continue }

                let d = i - cand
                let keep = min(i - litStart, 3)            // ≤3 個 literal 內嵌進距離操作碼
                flushLiterals(upTo: i, keep: keep)
                let L = i - litStart                        // = keep
                var m = mlen

                // 內嵌 L 的操作碼是 LLMMMDDD 排列，L=2/3 搭大 M 會撞進
                // 0xA0+ 的其他操作碼區域 —— 發射前用解碼器自己的分類表驗證，
                // 不合法就降級 medD（101LLMMM 的 L 欄位天生安全）
                let opcPre = m <= 10 ? (L << 6) | ((m - 3) << 3) | 6 : -1
                let opcSml = m <= 10 ? (L << 6) | ((m - 3) << 3) | (d >> 8) : -1
                if d == dPrev, L >= 1, m <= 10, lzvnOpTable[opcPre] == .preD {
                    payload.append(UInt8(opcPre))
                } else if d <= 2047, m <= 10, (d >> 8) <= 5, lzvnOpTable[opcSml] == .smlD {
                    payload.append(UInt8(opcSml))
                    payload.append(UInt8(d & 0xFF))
                } else {
                    // med_d：M 5 位（3+2）、D 14 位
                    let me = min(m, 34) - 3
                    m = me + 3
                    payload.append(UInt8(0xA0 | (L << 3) | (me >> 2)))
                    let o23 = (d << 2) | (me & 3)
                    payload.append(UInt8(o23 & 0xFF))
                    payload.append(UInt8((o23 >> 8) & 0xFF))
                }
                payload.append(contentsOf: bytes[litStart..<(litStart + L)])  // 內嵌 literal 跟在操作碼後
                litStart += L
                dPrev = d
                i += m
                litStart = i

                // 同距離延續：sml_m / lrg_m
                while i < n {
                    var m2 = 0
                    while i + m2 < n && p[i + m2 - dPrev] == p[i + m2] && m2 < 271 { m2 += 1 }
                    if m2 >= 16 {
                        payload.append(0xF0); payload.append(UInt8(m2 - 16))  // lrg_m
                    } else if m2 >= 4 {
                        payload.append(UInt8(0xF0 | m2))                      // sml_m
                    } else { break }
                    i += m2
                    litStart = i
                    if m2 < 271 { break }
                }
            }
        }
        flushLiterals(upTo: n, keep: 0)
        payload.append(0x06)                                  // eos（總長 8）
        payload.append(contentsOf: [UInt8](repeating: 0, count: 7))

        guard payload.count + 12 < n + 8 else { return nil }  // 須比 raw 區塊小
        var out: [UInt8] = []
        out.reserveCapacity(12 + payload.count)
        put32(magicLZVN, &out)
        put32(UInt32(n), &out)
        put32(UInt32(payload.count), &out)
        out.append(contentsOf: payload)
        return out
    }

    // =================================================================
    // MARK: - 頂層壓縮 API
    // =================================================================

    /// 壓縮為「區塊串」但不含結尾 bvx$ ——供平行分塊壓縮串接使用。
    /// 多個 compressBody 輸出串接後補上一個 bvx$，仍是合法的標準 LZFSE 串流
    /// （每個分塊獨立壓縮，match 距離不跨分塊，解碼器的輸出歷史是連續的所以相容）。
    public static func compressBody(_ input: Data, strong: Bool = false,
                                    bvx3: Bool = false, lazy2: Bool = false,
                                    optimal: Bool = false) -> Data {
        let bytes = [UInt8](input)
        var out: [UInt8] = []
        guard !bytes.isEmpty else { return Data() }

        if bytes.count < lzvnThreshold {
            // 小輸入：LZVN（bvxn，標準格式、無 FSE 表開銷）；編不小則退回 raw
            if let lzvn = lzvnEncodeBlock(bytes) { return Data(lzvn) }
            put32(magicUncompressed, &out)
            put32(UInt32(bytes.count), &out)
            out.append(contentsOf: bytes)
            return Data(out)
        }

        // bvx3 預設走 4 槽 lazy 解析器（速度優先）；
        // -lazy2 開雜湊鏈深搜；-optimal 開分段 DP 最優解析（比率優先）
        let (triplets, literals) = bvx3
            ? (optimal
                ? lzParseOptimal(bytes, maxL: maxL3, maxM: maxM3, maxDist: maxD3 - 2)
                : (lazy2
                    ? lzParseChain(bytes, maxL: maxL3, maxM: maxM3, maxDist: maxD3 - 2)
                    : lzParseStrong(bytes, maxL: maxL3, maxM: maxM3, maxDist: maxD3 - 2)))
            : (strong ? lzParseStrong(bytes) : lzParse(bytes))

        // 依每區塊上限切分（留 5 個 match、最大 L 的安全邊界）
        var tStart = 0
        var litStart = 0
        let blkMatches = bvx3 ? matchesPerBlockV3 : matchesPerBlock
        let blkLiterals = bvx3 ? literalsPerBlockV3 : literalsPerBlock
        while tStart < triplets.count {
            var tEnd = tStart
            var litCount = 0, raw = 0
            while tEnd < triplets.count {
                let t = triplets[tEnd]
                if (tEnd - tStart) + 5 > blkMatches { break }
                if litCount + Int(t.l) + 4 > blkLiterals { break }
                litCount += Int(t.l); raw += Int(t.l + t.m)
                tEnd += 1
            }
            let block = bvx3
                ? encodeBlockV3(triplets: triplets[tStart..<tEnd],
                                literals: literals[litStart..<(litStart + litCount)],
                                rawBytes: raw)
                : encodeBlock(triplets: triplets[tStart..<tEnd],
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

    /// 相容別名（保留給既有呼叫端）
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

    @inline(__always)
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
    static func decodeV2Block(src: [UInt8], at p: Int,
                              dp: UnsafeMutablePointer<UInt8>, regionBase: Int, regionEnd: Int,
                              cursor: inout Int, litScratch: UnsafeMutablePointer<UInt8>) -> Int? {
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
                              dp: dp, regionBase: regionBase, regionEnd: regionEnd,
                              cursor: &cursor, litScratch: litScratch)
        else { return nil }
        return headerSize + nPayload
    }

    // ---------- bvx3：私有大字母表區塊 ----------

    /// 解碼 bvx3 區塊（標頭 52 bytes 固定 + freq 流；payload 結構同 v1，
    /// 但 L/M/D 用大字母表且 LMD 流為逐欄位填充）
    static func decodeV3Block(src: [UInt8], at p: Int,
                              dp: UnsafeMutablePointer<UInt8>, regionBase: Int, regionEnd: Int,
                              cursor: inout Int, litScratch: UnsafeMutablePointer<UInt8>) -> Int? {
        guard p + v3FixedHeaderSize <= src.count else { return nil }
        var o = p + 4
        func r32() -> UInt32 { let v = get32(src, o); o += 4; return v }
        func r16() -> UInt16 { let v = get16(src, o); o += 2; return v }

        let nRawBytes = Int(r32())
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
        let literalMode = Int(r16())
        let headerSize = Int(r16())

        guard nPayload == nLitPayload + nLmdPayload,
              headerSize >= v3FixedHeaderSize,
              literalMode == 0 || literalMode == 1,
              p + headerSize + nPayload <= src.count else { return nil }

        // 頻率流：22+22+80 + 256×(1 或 4) 值，須剛好在標頭尾結束、殘餘 <8 位元
        let nLitTables = literalMode == 1 ? litCtxCount : 1
        let nFreq = lm3Symbols + lm3Symbols + d3Symbols + literalSymbols * nLitTables
        var freqs = [UInt16](repeating: 0, count: nFreq)
        if headerSize > v3FixedHeaderSize {
            var accum: UInt32 = 0
            var accumNBits: Int32 = 0
            var q = p + v3FixedHeaderSize
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
            guard accumNBits < 8, q == qEnd else { return nil }
        }

        let lFreq = Array(freqs[0..<lm3Symbols])
        let mFreq = Array(freqs[lm3Symbols..<(2 * lm3Symbols)])
        let dFreq = Array(freqs[(2 * lm3Symbols)..<(2 * lm3Symbols + d3Symbols)])
        let litBase = 2 * lm3Symbols + d3Symbols
        let litFreq = Array(freqs[litBase..<(litBase + literalSymbols)])
        var litFreqCtx: [[UInt16]]? = nil
        if literalMode == 1 {
            var t: [[UInt16]] = []
            for c in 0..<litCtxCount {
                let s0 = litBase + c * literalSymbols
                t.append(Array(freqs[s0..<(s0 + literalSymbols)]))
            }
            litFreqCtx = t
        }

        guard decodeBlockBody(src: src, payloadStart: p + headerSize,
                              nRawBytes: nRawBytes, nLiterals: nLiterals, nMatches: nMatches,
                              nLitPayload: nLitPayload, nLmdPayload: nLmdPayload,
                              literalBits: literalBits,
                              litState0: litState0, litState1: litState1,
                              litState2: litState2, litState3: litState3,
                              lmdBits: lmdBits,
                              lState0: lState, mState0: mState, dState0: dState,
                              lFreq: lFreq, mFreq: mFreq, dFreq: dFreq, litFreq: litFreq,
                              litFreqCtx: litFreqCtx,
                              lVbits: lm3ExtraBits, lVbase: lm3BaseValue,
                              mVbits: lm3ExtraBits, mVbase: lm3BaseValue,
                              dVbits: d3ExtraBits, dVbase: d3BaseValue,
                              fillPerField: true,
                              repOffsets: true,
                              maxMatchValue: maxM3,
                              literalsLimit: literalsPerBlockV3,
                              matchesLimit: matchesPerBlockV3,
                              dp: dp, regionBase: regionBase, regionEnd: regionEnd,
                              cursor: &cursor, litScratch: litScratch)
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
    static func decodeLZVNBlock(src: [UInt8], at p: Int,
                                dp: UnsafeMutablePointer<UInt8>,
                                regionBase: Int, regionEnd: Int,
                                cursor: inout Int) -> Int? {
        guard p + 12 <= src.count else { return nil }
        let nRaw = Int(get32(src, p + 4))
        let nPayload = Int(get32(src, p + 8))
        let payloadStart = p + 12
        guard nPayload >= 8, payloadStart + nPayload <= src.count,
              nRaw >= 0, cursor + nRaw <= regionEnd else { return nil }

        var ok = false
        src.withUnsafeBufferPointer { sbuf in
            ok = lzvnDecode(sp: sbuf.baseAddress! + payloadStart, srcLen: nPayload,
                            dp: dp, outBase: cursor, outEnd: cursor + nRaw,
                            historyFloor: regionBase)
        }
        guard ok else { return nil }
        cursor += nRaw
        return 12 + nPayload
    }

    /// LZVN 操作碼機。dp 指向「整個」輸出緩衝（match 可回溯引用之前區塊的輸出），
    /// 寫入範圍限定 [outBase, outEnd)。成功條件：遇到 eos 且輸出恰好填滿。
    static func lzvnDecode(sp: UnsafePointer<UInt8>, srcLen: Int,
                           dp: UnsafeMutablePointer<UInt8>,
                           outBase: Int, outEnd: Int,
                           historyFloor: Int = 0) -> Bool {
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
                guard dd > 0, dd <= w - historyFloor, w + M <= outEnd else { return false }
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
        return decodeStream(input, parallel: false, chunkRaw: parallelChunkSize)
    }

    /// 走訪單一區塊（依魔數分派；raw 區塊直接 memcpy）。回傳消耗的位元組數。
    static func decodeOneBlock(src: [UInt8], at p: Int, magic: UInt32,
                               dp: UnsafeMutablePointer<UInt8>,
                               regionBase: Int, regionEnd: Int,
                               cursor: inout Int,
                               litScratch: UnsafeMutablePointer<UInt8>) -> Int? {
        switch magic {
        case magicUncompressed:
            guard p + 8 <= src.count else { return nil }
            let n = Int(get32(src, p + 4))
            guard p + 8 + n <= src.count, cursor + n <= regionEnd else { return nil }
            src.withUnsafeBufferPointer { sb in
                _ = memcpy(dp + cursor, sb.baseAddress! + p + 8, n)
            }
            cursor += n
            return 8 + n
        case magicCompressedV1:
            return decodeV1Block(src: src, at: p, dp: dp, regionBase: regionBase,
                                 regionEnd: regionEnd, cursor: &cursor, litScratch: litScratch)
        case magicCompressedV2:
            return decodeV2Block(src: src, at: p, dp: dp, regionBase: regionBase,
                                 regionEnd: regionEnd, cursor: &cursor, litScratch: litScratch)
        case magicBVX3:
            return decodeV3Block(src: src, at: p, dp: dp, regionBase: regionBase,
                                 regionEnd: regionEnd, cursor: &cursor, litScratch: litScratch)
        case magicLZVN:
            return decodeLZVNBlock(src: src, at: p, dp: dp, regionBase: regionBase,
                                   regionEnd: regionEnd, cursor: &cursor)
        default:
            return nil
        }
    }

    // =================================================================
    // MARK: - 平行解碼（分塊串流專用，含安全後援）
    // =================================================================
    //
    // 原理：分塊平行編碼（other3/bvx3）的每個分塊（預設 4MiB）獨立壓縮，match 永不
    // 跨分塊。解碼端只掃描區塊標頭（不碰 payload）累計 n_raw_bytes，在
    // 分塊大小的倍數處切組，各組平行解碼。
    //
    // 正確性保證：組內 match 的相對距離與絕對位置一一對應（組緩衝的
    // 索引 x ≡ 串流絕對位置 groupStart+x），引用若越過組起點，必然觸發
    // 既有的 d ≤ 已解碼位置 檢查而失敗 → 整體退回循序解碼。
    // 因此對「非分塊」串流（apple/other 產生）最壞情況只是退回循序，
    // 不可能產生錯誤輸出。
    // =================================================================

    /// 分塊平行編碼器與平行解碼器共用的分塊原始大小
    public static let parallelChunkSize = 1 << 22   // 4MiB

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
            case magicBVX3:
                guard p + v3FixedHeaderSize <= src.count else { return nil }
                let nRaw = Int(get32(src, p + 4))
                let nPayload = Int(get32(src, p + 8))
                let headerSize = Int(get16(src, p + 52))   // 50 = literal_mode、52 = header_size
                let size = headerSize + nPayload
                guard headerSize >= v3FixedHeaderSize, p + size <= src.count else { return nil }
                blocks.append(BlockInfo(start: p, size: size, rawBytes: nRaw, magic: magic))
                p += size
            default:
                return nil
            }
        }
        return nil // 沒有 bvx$
    }

    /// 平行解碼。chunkRaw 須與編碼端分塊大小一致（預設 4MiB）。
    /// 串流不符合分塊假設時自動退回循序，結果永遠正確。
    public static func parallelDecompress(_ input: Data,
                                          chunkRaw: Int = parallelChunkSize) -> Data? {
        return decodeStream(input, parallel: true, chunkRaw: chunkRaw)
    }

    /// 統一解碼管線：scan 取得各區塊大小 → 一次 malloc 全部輸出 →
    /// （平行模式）各組寫入自己的不相交區段 → Data(bytesNoCopy:) 零複製交付。
    /// 消除了舊管線的三個全量記憶體 pass：零填充預配置、組緩衝組裝、最終複製。
    static func decodeStream(_ input: Data, parallel: Bool, chunkRaw: Int) -> Data? {
        let src = [UInt8](input)
        guard let blocks = scanBlocks(src) else { return nil }
        let total = blocks.reduce(0) { $0 + $1.rawBytes }
        guard total >= 0 else { return nil }
        if total == 0 { return Data() }

        // 分組：累計原始大小於 chunkRaw 倍數處切（平行模式）；循序 = 單組
        var groups: [[BlockInfo]] = []
        if parallel && chunkRaw > 0 {
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
        } else {
            groups = [blocks]
        }

        // 各組輸出區段的前綴位移
        var offsets: [Int] = [0]
        for g in groups { offsets.append(offsets.last! + g.reduce(0) { $0 + $1.rawBytes }) }

        let buf = UnsafeMutableRawPointer.allocate(byteCount: max(total, 1),
                                                   alignment: 16)
        let dp = buf.bindMemory(to: UInt8.self, capacity: max(total, 1))
        var anyFailed = false
        let lock = NSLock()

        func decodeGroup(_ gi: Int) -> Bool {
            let regionBase = offsets[gi]
            let regionEnd = offsets[gi + 1]
            var cursor = regionBase
            let litScratch = UnsafeMutablePointer<UInt8>.allocate(
                capacity: literalsPerBlockV3 + 8)
            defer { litScratch.deallocate() }
            for b in groups[gi] {
                guard decodeOneBlock(src: src, at: b.start, magic: b.magic,
                                     dp: dp, regionBase: regionBase, regionEnd: regionEnd,
                                     cursor: &cursor, litScratch: litScratch) != nil
                else { return false }
            }
            return cursor == regionEnd
        }

        if groups.count > 1 {
            DispatchQueue.concurrentPerform(iterations: groups.count) { gi in
                if !decodeGroup(gi) {
                    lock.lock(); anyFailed = true; lock.unlock()
                }
            }
            if anyFailed {
                // 分組假設不成立（例如跨組 match）→ 整體退回循序，同一塊緩衝重用
                if !sequentialInto(blocks: blocks, src: src, dp: dp, total: total) {
                    buf.deallocate(); return nil
                }
            }
        } else {
            if !decodeGroup(0) { buf.deallocate(); return nil }
        }

        return Data(bytesNoCopy: buf, count: total, deallocator: .custom { p, _ in
            p.deallocate()
        })
    }

    /// 循序後援：整條串流視為單一區段（完整歷史）解進同一塊緩衝
    static func sequentialInto(blocks: [BlockInfo], src: [UInt8],
                               dp: UnsafeMutablePointer<UInt8>, total: Int) -> Bool {
        var cursor = 0
        let litScratch = UnsafeMutablePointer<UInt8>.allocate(capacity: literalsPerBlockV3 + 8)
        defer { litScratch.deallocate() }
        for b in blocks {
            guard decodeOneBlock(src: src, at: b.start, magic: b.magic,
                                 dp: dp, regionBase: 0, regionEnd: total,
                                 cursor: &cursor, litScratch: litScratch) != nil
            else { return false }
        }
        return cursor == total
    }

    static func decodeV1Block(src: [UInt8], at p: Int,
                              dp: UnsafeMutablePointer<UInt8>, regionBase: Int, regionEnd: Int,
                              cursor: inout Int, litScratch: UnsafeMutablePointer<UInt8>) -> Int? {
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
                              dp: dp, regionBase: regionBase, regionEnd: regionEnd,
                              cursor: &cursor, litScratch: litScratch)
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
                                litFreqCtx: [[UInt16]]? = nil,
                                lVbits: [UInt8] = lExtraBits, lVbase: [Int32] = lBaseValue,
                                mVbits: [UInt8] = mExtraBits, mVbase: [Int32] = mBaseValue,
                                dVbits: [UInt8] = dExtraBits, dVbase: [Int32] = dBaseValue,
                                fillPerField: Bool = false,
                                repOffsets: Bool = false,
                                maxMatchValue: Int = maxMValue,
                                literalsLimit: Int = literalsPerBlock,
                                matchesLimit: Int = matchesPerBlock,
                                dp: UnsafeMutablePointer<UInt8>,
                                regionBase: Int, regionEnd: Int,
                                cursor: inout Int,
                                litScratch: UnsafeMutablePointer<UInt8>) -> Bool {
        var lState = lState0, mState = mState0, dState = dState0

        // 健全性檢查（lzfse_check_block_header_v1 等價 + n_raw_bytes 上界）
        // nLiterals 必須是 4 的倍數：4 路交錯解碼一次寫 4 個（編碼端有補齊）
        guard nLiterals >= 0, nMatches >= 0, nRawBytes >= 0,
              nLitPayload >= 0, nLmdPayload >= 0,
              nLiterals <= literalsLimit, nLiterals & 3 == 0,
              nMatches <= matchesLimit,
              nRawBytes <= literalsLimit + matchesLimit * maxMatchValue,
              litState0 < Int32(literalStates), litState1 < Int32(literalStates),
              litState2 < Int32(literalStates), litState3 < Int32(literalStates),
              lState < Int32(lStates), mState < Int32(mStates), dState < Int32(dStates),
              payloadStart >= 8,
              payloadStart + nLitPayload + nLmdPayload <= src.count
        else { return false }

        // 單表 / 多表（上下文）literal 解碼表
        var litDecCtx: [[Int32]] = []
        if let ctxFreqs = litFreqCtx {
            for f in ctxFreqs {
                guard let d = initDecoderTable(nstates: literalStates, freq: f) else { return false }
                litDecCtx.append(d)
            }
        }
        guard let litDec = litFreqCtx == nil
            ? initDecoderTable(nstates: literalStates, freq: litFreq)
            : litDecCtx.first else { return false }
        let lDec = initValueDecoderTable(nstates: lStates, freq: lFreq, vbits: lVbits, vbase: lVbase)
        let mDec = initValueDecoderTable(nstates: mStates, freq: mFreq, vbits: mVbits, vbase: mVbase)
        let dDec = initValueDecoderTable(nstates: dStates, freq: dFreq, vbits: dVbits, vbase: dVbase)

        // --- 區段檢查：本區塊輸出 [cursor, cursor+nRawBytes) 必須落在區段內 ---
        let litPayloadEnd = payloadStart + nLitPayload
        let lmdPayloadEnd = litPayloadEnd + nLmdPayload
        let outBase = cursor
        guard outBase + nRawBytes <= regionEnd else { return false }

        var ok = true
        let lp = litScratch   // 呼叫端提供、容量 ≥ literalsLimit+4（免去每區塊配置）

        src.withUnsafeBufferPointer { sbuf in
            let sp = sbuf.baseAddress!

            // --- 解碼 literal（4 路交錯，正序）---
            guard var ins = FSEInStream(base: sp, payloadEnd: litPayloadEnd,
                                        bits: literalBits) else { ok = false; return }
            if !litDecCtx.isEmpty {
                // 多表：以「已解出的前一 literal」高 2 位元選表（與編碼端逐步一致）
                var st: [Int32] = [litState0, litState1, litState2, litState3]
                var prev: Int = 0
                var i = 0
                while i < nLiterals {
                    guard ins.fill() else { ok = false; return }
                    for j in 0..<4 {
                        let e = litDecCtx[prev >> 6][Int(st[j])]
                        st[j] = (e >> 16) + Int32(truncatingIfNeeded: ins.pull(e & 0xFF))
                        let sym = UInt8((e >> 8) & 0xFF)
                        lp[i + j] = sym
                        prev = Int(sym)
                    }
                    i += 4
                }
                return
            }
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
        guard ok else { return false }

        // --- 解碼 L,M,D 並重建輸出（指標寬複製，直接寫入共享緩衝的本區段）---
        src.withUnsafeBufferPointer { sbuf in
            let sp = sbuf.baseAddress!
            let dstEnd = outBase + nRawBytes
            guard var lmdIn = FSEInStream(base: sp, payloadEnd: lmdPayloadEnd,
                                          bits: lmdBits) else { ok = false; return }
            var litPos = 0
            var dstIdx = outBase
            var d: Int32 = 0
            var rep0: Int32 = 0, rep1: Int32 = 0, rep2: Int32 = 0

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
                if fillPerField { guard lmdIn.fill() else { ok = false; return } }
                let m = Int(valueDecode(&mState, mDec, &lmdIn))
                if fillPerField { guard lmdIn.fill() else { ok = false; return } }
                let newD = valueDecode(&dState, dDec, &lmdIn)
                if repOffsets {
                    // bvx3：0/1/2 = rep0/1/2（1/2 命中 move-to-front），其餘 = 值-2
                    switch newD {
                    case 0:
                        d = rep0
                    case 1:
                        swap(&rep0, &rep1)
                        d = rep0
                    case 2:
                        let t = rep2; rep2 = rep1; rep1 = rep0; rep0 = t
                        d = rep0
                    default:
                        d = newD - 2
                        rep2 = rep1; rep1 = rep0; rep0 = d
                    }
                } else {
                    if newD != 0 { d = newD }  // 標準 LZFSE：d==0 → 沿用前一距離
                }
                let dd = Int(d)

                // 邊界驗證：literal 來源、輸出區段、距離不可越過區段歷史下限
                // （越過 regionBase = 平行分組假設不成立 → 失敗讓上層退回循序）
                guard l >= 0, m >= 0,
                      litPos + l <= nLiterals,
                      dstIdx + l + m <= dstEnd,
                      (m == 0) || (dd > 0 && dd <= dstIdx + l - regionBase)
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
        guard ok else { return false }
        cursor = outBase + nRawBytes
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

    /// 模擬 other3/bvx3 的輸出：分塊獨立壓縮（compressBody）串接 + 單一 bvx$
    func chunkedCompress(_ data: Data, chunkSize: Int,
                         strong: Bool = true, bvx3: Bool = false, lazy2: Bool = false,
                         optimal: Bool = false) -> Data {
        var out = Data()
        var p = 0
        while p < data.count {
            let end = min(p + chunkSize, data.count)
            out.append(LZFSEv1.compressBody(data.subdata(in: p..<end),
                                            strong: strong, bvx3: bvx3, lazy2: lazy2,
                                            optimal: optimal))
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
        let cs = 1 << 20

        // ---- 引擎層單流（後援路徑用，仍為標準 bvx2）----
        let packed = LZFSEv1.compress(data, strong: true)

        // ---- -algo other3：標準 bvx2、分塊平行 ----
        if data.count > 0 {
            let o3 = chunkedCompress(data, chunkSize: cs)
            print("       other3 壓縮: \(o3.count) bytes (\(pct(o3.count)))")
            check("other3 自我往返", LZFSEv1.decompress(o3) == data)
            check("other3 平行解碼", LZFSEv1.parallelDecompress(o3, chunkRaw: cs) == data)
            #if canImport(Compression)
            check("other3 → Apple 解碼", appleDecompress(o3, expected: data.count) == data)
            #endif
        }

        // ---- -algo bvx3：私有大字母表區塊（預設 + -lazy2 深搜）----
        if data.count > 0 {
            let b3 = chunkedCompress(data, chunkSize: cs, bvx3: true)
            let b3z = chunkedCompress(data, chunkSize: cs, bvx3: true, lazy2: true)
            let b3o = chunkedCompress(data, chunkSize: cs, bvx3: true, optimal: true)
            print("       bvx3   壓縮: \(b3.count) bytes (\(pct(b3.count)))；-lazy2: \(b3z.count) bytes (\(pct(b3z.count)))；-optimal: \(b3o.count) bytes (\(pct(b3o.count)))")
            check("bvx3 -lazy2 自我往返", LZFSEv1.decompress(b3z) == data)
            check("bvx3 -lazy2 平行解碼", LZFSEv1.parallelDecompress(b3z, chunkRaw: cs) == data)
            check("bvx3 -optimal 自我往返", LZFSEv1.decompress(b3o) == data)
            check("bvx3 -optimal 平行解碼", LZFSEv1.parallelDecompress(b3o, chunkRaw: cs) == data)
            check("bvx3 自我往返 (循序)", LZFSEv1.decompress(b3) == data)
            check("bvx3 平行解碼", LZFSEv1.parallelDecompress(b3, chunkRaw: cs) == data)
            #if canImport(Compression)
            // 私有格式：Apple 解碼器「應該」拒絕（回傳 nil 才是正確行為）。
            // 例外：不可壓資料會退回標準 bvx- raw 區塊，該串流 Apple 仍可解。
            let hasV3 = (LZFSEv1.scanBlocks([UInt8](b3)) ?? [])
                .contains { $0.magic == LZFSEv1.magicBVX3 }
            if hasV3 {
                check("bvx3 為私有格式，Apple 應拒解",
                      appleDecompress(b3, expected: data.count) == nil)
            } else {
                check("bvx3 全為標準區塊（小輸入/不可壓），Apple 仍可解",
                      appleDecompress(b3, expected: data.count) == data)
            }
            #endif
        }

        // 平行解碼對「非分塊」串流的安全後援（必須退回循序且結果正確）
        if !data.isEmpty {
            check("平行解碼後援 (單流輸入)", LZFSEv1.parallelDecompress(packed) == data)
        }

        #if canImport(Compression)
        if !data.isEmpty {
            check("單流 bvx2 → Apple 解碼", appleDecompress(packed, expected: data.count) == data)
            if let applePacked = appleCompress(data) {
                print("       apple  壓縮: \(applePacked.count) bytes (\(pct(applePacked.count)))")
                check("Apple → 本解碼器 (bvx2/bvxn)", LZFSEv1.decompress(applePacked) == data)
                check("Apple → other3/bvx3 解碼路徑 (平行+後援)",
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
    // 交錯重複距離：兩種週期輪流出現 → 重度行使 rep1/rep2 的 move-to-front
    var alt = Data()
    let pa = Data("AAAA-BBBB-CCCC-DDDD-37bytes-period-X\n".utf8)
    let pb = Data("0123456789abcdef-53bytes-period-YYYYYYYYYYYYYYYY\n".utf8)
    for i in 0..<800 { alt.append(i % 3 == 0 ? pb : pa) }
    runCase("交錯距離 (rep-offset)", alt)
    // 大量 literal 的文字樣本（≥16384 literal/區塊）→ 觸發 bvx3 的多表 literal 模式
    var bigText = Data()
    var seed: UInt64 = 0x9E3779B97F4A7C15
    let words = ["func", "let", "var", "return", "encode", "decode", "stream", "buffer",
                 "Int32", "UInt8", "guard", "while", "state", "table", "block", "match"]
    for i in 0..<12000 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        bigText.append(Data("\(words[Int(seed >> 33) % words.count])_\(i % 977) ".utf8))
    }
    runCase("文字大樣本 (多表 literal)", bigText)
}

// =====================================================================
// MARK: - CLI（命令列介面）
// =====================================================================
//
// Compile with: swiftc -O lzfse-cli.swift -o lzfse   （務必加 -O）
//
// -algo apple  : 使用 Apple Compression framework（OutputFilter 串流）
// -algo other3 : 位元相容 LZFSE（標準 bvx2），多核心 + 強化比對（預設）
// -algo bvx3   : 私有擴充區塊（zstd 式：大字母表 + 4MiB 視窗 + rep-offset + 多表 literal）
//
// 互通性說明：
//   - other3 輸出是合法 LZFSE 串流，Apple 與任何標準解碼器可解。
//   - bvx3 為私有格式：壓縮率更高，但僅本工具可解（刻意的取捨）。
//   - 本工具的解碼（other3/bvx3 相同路徑）接受全部區塊型別：
//     bvx1/bvx2/bvxn/bvx-/bvx3，含 Apple 編碼器的輸出。
//   - 解碼先嘗試分塊邊界平行解碼（自家串流必中、速度隨核心數擴展），
//     非分塊串流自動退回循序，結果保證正確。
// =====================================================================

import Foundation

/// 把訊息寫到 stderr（避免污染 -so 的資料輸出）
func eprint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func printUsage() {
    print("""
    Usage: lzfse -encode|-decode [-algo apple|other3|bvx3] [-lazy2|-optimal] [-si|-i input] [-so|-o output] [-test] [-h]

    Commands:
      -encode       : Compress the input / 壓縮輸入內容
      -decode       : Decompress the input / 解壓縮輸入內容

    Options:
      -algo <name>  : Compression engine / 壓縮引擎 (default: other3)
                        apple  : Apple Compression framework (COMPRESSION_LZFSE)
                        other3 : Our bit-compatible LZFSE, multi-core, lazy matching
                                 自製位元相容 LZFSE，多核心 + 強化比對；
                                 輸出標準 bvx2，Apple 可解
                        bvx3   : Private extension block, zstd-style big alphabets
                                 私有擴充區塊（4MiB 視窗、大字母表），壓縮率更高；
                                 僅本工具可解（Apple 不可解）
      -i <path>     : Input file path / 指定輸入檔案路徑
      -si           : Read from stdin / 從標準輸入讀取
      -o <path>     : Output file path / 指定輸出檔案路徑
      -so           : Write to stdout / 輸出至標準輸出
      -lazy2        : (bvx3 only) Deep hash-chain search; better ratio, slower
                      （僅 bvx3）雜湊鏈深搜（深度32+lazy+rep感知），壓縮率更高
                      但較慢；預設關閉，bvx3 走快速 4 槽解析器
      -optimal      : (bvx3 only) Price-driven optimal parsing (zstd btultra
                      style segmented DP); best ratio, slowest; supersedes -lazy2
                      （僅 bvx3）價格驅動最優解析（分段 DP + rep 感知定價），
                      壓縮率最高、速度最慢；與 -lazy2 同時給時以 -optimal 為準
      -test         : Run built-in round-trip & compatibility tests / 執行內建測試
      -h            : Show this help / 顯示說明

    Notes / 注意:
      - "other3" streams are standard LZFSE; freely interoperable with "apple".
        other3 輸出為標準 LZFSE 串流，與 apple 可互通。
      - "bvx3" trades compatibility for ratio: only this tool can decode it.
        bvx3 以相容性換壓縮率：只有本工具能解。
      - Decoding with other3/bvx3 accepts ALL block types, incl. Apple streams.
        other3/bvx3 解碼接受全部區塊型別，含 Apple 編碼器的輸出。
    """)
}

enum Algo: String { case apple, other3, bvx3 }

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
var algo: Algo = .other3
if let index = args.firstIndex(of: "-algo") {
    guard index + 1 < args.count,
          let parsed = Algo(rawValue: args[index + 1].lowercased()) else {
        eprint("Error: -algo expects apple, other3, or bvx3. / 錯誤：-algo 只接受 apple、other3 或 bvx3。")
        exit(1)
    }
    algo = parsed
}

// -lazy2：bvx3 的雜湊鏈深搜開關（預設關閉）
let useLazy2 = args.contains("-lazy2")
if useLazy2 && algo != .bvx3 {
    eprint("Note: -lazy2 only affects -algo bvx3; ignored. / 提示：-lazy2 僅對 bvx3 生效，已忽略。")
}

// -optimal：bvx3 的分段 DP 最優解析開關（預設關閉；與 -lazy2 同時給時優先）
let useOptimal = args.contains("-optimal")
if useOptimal && algo != .bvx3 {
    eprint("Note: -optimal only affects -algo bvx3; ignored. / 提示：-optimal 僅對 bvx3 生效，已忽略。")
}
if useOptimal && useLazy2 {
    eprint("Note: -optimal supersedes -lazy2. / 提示：-optimal 優先於 -lazy2。")
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

/// 多核心分塊平行壓縮（other3 / bvx3 共用的編碼路徑）。
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
                       chunkSize: Int = LZFSEv1.parallelChunkSize,
                       strong: Bool = false, bvx3: Bool = false, lazy2: Bool = false,
                       optimal: Bool = false) {
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
            let body = LZFSEv1.compressBody(data, strong: strong, bvx3: bvx3,
                                            lazy2: lazy2, optimal: optimal)   // 區塊串，不含 bvx$
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

case .other3, .bvx3:
    // ---- 多核心分塊平行（壓縮與解壓）----
    // other3：強化比對（lazy + 4 候選），輸出標準 bvx2 —— Apple 可解。
    // bvx3 ：私有大字母表區塊（4MiB 視窗、L/M/D 大字母表），
    //        壓縮率更高，但只有本工具可解。
    // 解碼：先嘗試分塊邊界平行解碼（自家串流必中），
    // 非分塊串流自動退回循序，結果保證正確。
    if isEncoding {
        runParallelEncode(input: inputHandle, output: outputHandle,
                          strong: true, bvx3: algo == .bvx3,
                          lazy2: algo == .bvx3 && useLazy2 && !useOptimal,
                          optimal: algo == .bvx3 && useOptimal)
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
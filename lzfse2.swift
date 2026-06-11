//
//  LZFSEv1.swift
//
//  位元相容的 LZFSE 實作（第一階段：bvx1 / bvx- / bvx$ 區塊）
//
//  逐段對照 lzfse/lzfse 參考實作：
//    - 區塊魔數、v1 標頭、L/M/D 常數表  ← lzfse_internal.h
//    - FSE 位元流與編解碼核心            ← lzfse_fse.h / lzfse_fse.c
//    - 區塊編碼流程（4 路交錯 literal、D→M→L 反序 LMD） ← lzfse_encode_base.c
//    - 區塊解碼流程                       ← lzfse_decode_base.c
//
//  本階段輸出 bvx1（未壓縮頻率表）壓縮區塊 + bvx- 原始區塊 + bvx$ 結尾，
//  目標：產出的串流可被 Apple Compression framework / 參考解碼器直接解開；
//  同時內附 bvx1/bvx-/bvx$ 解碼器供往返驗證。
//
//  尚未實作（第二階段）：bvx2 壓縮標頭、bvxn LZVN 區塊的「解碼」支援。
//  （編碼端不需要它們——v1 是合法輸出；但要解開 Apple 編碼器的輸出需要 v2+LZVN。）
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

    /// 輸出流：LSB 先入、向前寫出位元組；finish 後 accumNBits ∈ [-7, 0]
    struct FSEOutStream {
        var accum: UInt64 = 0
        var accumNBits: Int32 = 0
        var bytes: [UInt8] = []

        @inline(__always)
        mutating func push(_ n: Int32, _ b: UInt64) {
            accum |= b << UInt64(accumNBits)
            accumNBits += n
            assert(accumNBits <= 64)
        }
        @inline(__always)
        mutating func flush() {
            let nbits = accumNBits & -8
            var a = accum
            for _ in 0..<(nbits >> 3) { bytes.append(UInt8(truncatingIfNeeded: a)); a >>= 8 }
            accum >>= UInt64(nbits)
            accumNBits -= nbits
        }
        /// 寫出殘餘位元（補 0），回傳最終 accumNBits ∈ [-7, 0]（即標頭的 *_bits 欄位）
        mutating func finish() -> Int32 {
            let nbits = (accumNBits + 7) & -8
            var a = accum
            for _ in 0..<(nbits >> 3) { bytes.append(UInt8(truncatingIfNeeded: a)); a >>= 8 }
            accum = 0
            accumNBits -= nbits
            assert(accumNBits >= -7 && accumNBits <= 0)
            return accumNBits
        }
    }

    /// 輸入流：從 payload「尾端」向回讀（LIFO）。
    /// 重要：回填可越過 payload 開頭、讀進前方的標頭位元組（那些位元永不被取用），
    /// 與參考解碼器以 src_begin 為下限的行為一致。
    struct FSEInStream {
        let data: [UInt8]
        var pos: Int            // 下一次回讀位置（位元組）
        var accum: UInt64 = 0
        var accumNBits: Int32 = 0

        @inline(__always) func load8(_ p: Int) -> UInt64 {
            var v: UInt64 = 0
            let end = min(p + 8, data.count)
            var shift: UInt64 = 0
            var i = p
            while i < end { v |= UInt64(data[i]) << shift; shift += 8; i += 1 }
            return v
        }

        /// 對應 fse_in_checked_init64：n 為標頭的 *_bits 欄位（[-7,0]）
        init?(data: [UInt8], payloadEnd: Int, bits n: Int32) {
            self.data = data
            if n != 0 {
                guard payloadEnd >= 8 else { return nil }
                pos = payloadEnd - 8
                accum = load8(pos)
                accumNBits = n + 64
            } else {
                guard payloadEnd >= 7 else { return nil }
                pos = payloadEnd - 7
                accum = load8(pos) & 0x00FF_FFFF_FFFF_FFFF
                accumNBits = n + 56
            }
            guard accumNBits >= 56 && accumNBits < 64,
                  (accumNBits == 64 || (accum >> UInt64(accumNBits)) == 0) else { return nil }
        }

        /// 對應 fse_in_checked_flush64：補滿至 [56, 63] 位元
        @inline(__always)
        mutating func fill() -> Bool {
            let nbits = (63 - accumNBits) & -8
            let newPos = pos - Int(nbits >> 3)
            guard newPos >= 0 else { return false } // 越過整個來源緩衝區才算錯
            pos = newPos
            let incoming = load8(newPos)
            let mask: UInt64 = nbits >= 64 ? ~0 : ((UInt64(1) << UInt64(nbits)) - 1)
            accum = (accum << UInt64(nbits)) | (incoming & mask)
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

        var hashTable = [Int32](repeating: -1, count: hashSize)
        var litStart = 0
        var i = 0
        input.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!
            @inline(__always) func hash4(_ idx: Int) -> Int {
                let v = UInt32(p[idx]) | UInt32(p[idx+1]) << 8
                      | UInt32(p[idx+2]) << 16 | UInt32(p[idx+3]) << 24
                return Int((v &* 2654435761) >> (32 - UInt32(hashBits)))
            }
            while i + 4 <= n {
                let h = hash4(i)
                let cand = Int(hashTable[h])
                hashTable[h] = Int32(i)

                var mlen = 0
                if cand >= 0, i - cand <= maxDValue {
                    while i + mlen < n && p[cand + mlen] == p[i + mlen] { mlen += 1 }
                }
                if mlen >= 4 {
                    literals.append(contentsOf: input[litStart..<i])
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
        }
        if litStart < n {
            literals.append(contentsOf: input[litStart..<n])
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

    /// 將一個區塊（≤10000 matches、≤40000 literals）編成 bvx1 區塊位元組
    static func encodeBlock(triplets: ArraySlice<Triplet>,
                            literals: ArraySlice<UInt8>,
                            rawBytes: Int) -> [UInt8] {
        // --- 準備工作緩衝 ---
        var lits = Array(literals)
        let nLiteralsUnpadded = lits.count
        // 補 0x00 到 4 的倍數（4 路交錯流的需要；標頭 n_literals 含補齊）
        while lits.count & 3 != 0 { lits.append(0) }

        var lVals = [Int32](), mVals = [Int32](), dVals = [Int32]()
        lVals.reserveCapacity(triplets.count)
        for t in triplets { lVals.append(t.l); mVals.append(t.m); dVals.append(t.d) }

        // D 的「重複距離 → 0」轉換（解碼器 d==0 時沿用前一距離；d_prev 每區塊歸零）
        var dPrev: Int32 = 0
        for i in 0..<dVals.count {
            let d = dVals[i]
            if d == dPrev { dVals[i] = 0 } else { dPrev = d }
        }

        // --- 統計與正規化 ---
        var lOcc = [UInt32](repeating: 0, count: lSymbols)
        var mOcc = [UInt32](repeating: 0, count: mSymbols)
        var dOcc = [UInt32](repeating: 0, count: dSymbols)
        var litOcc = [UInt32](repeating: 0, count: literalSymbols)
        var lSyms = [UInt8](repeating: 0, count: lVals.count)
        var mSyms = [UInt8](repeating: 0, count: mVals.count)
        var dSyms = [UInt8](repeating: 0, count: dVals.count)
        for i in 0..<lVals.count {
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

        // --- ① 編碼 literal：4 路交錯、由最後一個 literal 往前 ---
        var litOut = FSEOutStream()
        var s0: Int32 = 0, s1: Int32 = 0, s2: Int32 = 0, s3: Int32 = 0
        var i = lits.count
        while i > 0 {
            i -= 4
            fseEncode(state: &s3, litEnc[Int(lits[i + 3])], &litOut) // 各 ≤10 bits
            fseEncode(state: &s2, litEnc[Int(lits[i + 2])], &litOut)
            fseEncode(state: &s1, litEnc[Int(lits[i + 1])], &litOut)
            fseEncode(state: &s0, litEnc[Int(lits[i + 0])], &litOut)
            litOut.flush() // 4×10=40 ≤ 64，每組沖一次
        }
        let literalBits = litOut.finish()
        let literalPayload = litOut.bytes

        // --- ② 編碼 L,M,D：match 反序；每個 match 依 D→M→L 推入 ---
        var lmdOut = FSEOutStream()
        // 參考實作在 LMD payload 開頭放 8 個 0 填充位元組（解碼快路徑的安全邊界）
        lmdOut.bytes.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        var lState: Int32 = 0, mState: Int32 = 0, dState: Int32 = 0
        var mi = lVals.count
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
        let lmdPayload = lmdOut.bytes

        // --- ③ 組裝 v1 標頭（772 bytes，欄位順序 = C struct）---
        var out: [UInt8] = []
        out.reserveCapacity(v1HeaderSize + literalPayload.count + lmdPayload.count)
        put32(magicCompressedV1, &out)
        put32(UInt32(rawBytes), &out)                                   // n_raw_bytes
        put32(UInt32(literalPayload.count + lmdPayload.count), &out)    // n_payload_bytes
        put32(UInt32(lits.count), &out)                                 // n_literals（含補齊）
        put32(UInt32(lVals.count), &out)                                // n_matches
        put32(UInt32(literalPayload.count), &out)                       // n_literal_payload_bytes
        put32(UInt32(lmdPayload.count), &out)                           // n_lmd_payload_bytes
        put32(UInt32(bitPattern: literalBits), &out)                    // literal_bits ∈ [-7,0]
        put16(UInt16(s0), &out); put16(UInt16(s1), &out)                // literal_state[4]
        put16(UInt16(s2), &out); put16(UInt16(s3), &out)
        put32(UInt32(bitPattern: lmdBits), &out)                        // lmd_bits ∈ [-7,0]
        put16(UInt16(lState), &out); put16(UInt16(mState), &out); put16(UInt16(dState), &out)
        for f in lFreq { put16(f, &out) }
        for f in mFreq { put16(f, &out) }
        for f in dFreq { put16(f, &out) }
        for f in litFreq { put16(f, &out) }
        out.append(0); out.append(0) // struct 尾端 2 bytes 對齊填充 → 772
        assert(out.count == v1HeaderSize)

        _ = nLiteralsUnpadded // (補齊的 literal 不會被解碼端取用)
        out.append(contentsOf: literalPayload)
        out.append(contentsOf: lmdPayload)
        return out
    }

    // =================================================================
    // MARK: - 頂層壓縮 API
    // =================================================================

    public static func compress(_ input: Data) -> Data {
        let bytes = [UInt8](input)
        var out: [UInt8] = []

        if bytes.count < 32 {
            // 太小：raw 區塊（參考實作此處走 LZVN；raw 同樣是合法輸出）
            if !bytes.isEmpty {
                put32(magicUncompressed, &out)
                put32(UInt32(bytes.count), &out)
                out.append(contentsOf: bytes)
            }
            put32(magicEndOfStream, &out)
            return Data(out)
        }

        let (triplets, literals) = lzParse(bytes)

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
        put32(magicEndOfStream, &out)

        // 壓不動就退回 raw 區塊
        if out.count >= bytes.count + 12 {
            out.removeAll(keepingCapacity: true)
            put32(magicUncompressed, &out)
            put32(UInt32(bytes.count), &out)
            out.append(contentsOf: bytes)
            put32(magicEndOfStream, &out)
        }
        return Data(out)
    }

    // =================================================================
    // MARK: - 解碼器（lzfse_decode_base.c；本階段支援 bvx1 / bvx- / bvx$）
    // =================================================================

    public static func decompress(_ input: Data) -> Data? {
        let src = [UInt8](input)
        var p = 0
        var dst: [UInt8] = []

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

            case magicCompressedV2, magicLZVN:
                // 第二階段範圍：v2 標頭解壓與 LZVN 區塊
                return nil

            default:
                return nil
            }
        }
        return nil // 缺少 bvx$ 結尾
    }

    static func decodeV1Block(src: [UInt8], at p: Int, into dst: inout [UInt8]) -> Int? {
        guard p + v1HeaderSize <= src.count else { return nil }
        var o = p + 4
        func r32() -> UInt32 { let v = get32(src, o); o += 4; return v }
        func r16() -> UInt16 { let v = get16(src, o); o += 2; return v }

        _ = r32()                          // n_raw_bytes（驗證用，可選）
        let nPayload = Int(r32())
        let nLiterals = Int(r32())
        let nMatches = Int(r32())
        let nLitPayload = Int(r32())
        let nLmdPayload = Int(r32())
        let literalBits = Int32(bitPattern: r32())
        let litState0 = Int32(r16()), litState1 = Int32(r16())
        let litState2 = Int32(r16()), litState3 = Int32(r16())
        let lmdBits = Int32(bitPattern: r32())
        var lState = Int32(r16()), mState = Int32(r16()), dState = Int32(r16())

        var lFreq = [UInt16](repeating: 0, count: lSymbols)
        var mFreq = [UInt16](repeating: 0, count: mSymbols)
        var dFreq = [UInt16](repeating: 0, count: dSymbols)
        var litFreq = [UInt16](repeating: 0, count: literalSymbols)
        for i in 0..<lSymbols { lFreq[i] = r16() }
        for i in 0..<mSymbols { mFreq[i] = r16() }
        for i in 0..<dSymbols { dFreq[i] = r16() }
        for i in 0..<literalSymbols { litFreq[i] = r16() }

        // 標頭健全性檢查（lzfse_check_block_header_v1）
        guard nLiterals <= literalsPerBlock, nMatches <= matchesPerBlock,
              litState0 < Int32(literalStates), litState1 < Int32(literalStates),
              litState2 < Int32(literalStates), litState3 < Int32(literalStates),
              lState < Int32(lStates), mState < Int32(mStates), dState < Int32(dStates),
              nPayload == nLitPayload + nLmdPayload,
              p + v1HeaderSize + nPayload <= src.count
        else { return nil }

        guard let litDec = initDecoderTable(nstates: literalStates, freq: litFreq) else { return nil }
        let lDec = initValueDecoderTable(nstates: lStates, freq: lFreq, vbits: lExtraBits, vbase: lBaseValue)
        let mDec = initValueDecoderTable(nstates: mStates, freq: mFreq, vbits: mExtraBits, vbase: mBaseValue)
        let dDec = initValueDecoderTable(nstates: dStates, freq: dFreq, vbits: dExtraBits, vbase: dBaseValue)

        // --- 解碼 literal（4 路交錯，正序）---
        let litPayloadEnd = p + v1HeaderSize + nLitPayload
        guard var ins = FSEInStream(data: src, payloadEnd: litPayloadEnd, bits: literalBits) else { return nil }
        var literals = [UInt8](repeating: 0, count: nLiterals)
        var st = [litState0, litState1, litState2, litState3]
        var i = 0
        while i < nLiterals {
            guard ins.fill() else { return nil }
            for j in 0..<4 {
                let e = litDec[Int(st[j])]
                st[j] = (e >> 16) + Int32(truncatingIfNeeded: ins.pull(e & 0xFF))
                literals[i + j] = UInt8((e >> 8) & 0xFF)
            }
            i += 4
        }

        // --- 解碼 L,M,D 並重建輸出 ---
        let lmdPayloadEnd = litPayloadEnd + nLmdPayload
        guard var lmdIn = FSEInStream(data: src, payloadEnd: lmdPayloadEnd, bits: lmdBits) else { return nil }
        var litPos = 0
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
            guard lmdIn.fill() else { return nil }
            let l = valueDecode(&lState, lDec, &lmdIn)
            let m = valueDecode(&mState, mDec, &lmdIn)
            let newD = valueDecode(&dState, dDec, &lmdIn)
            if newD != 0 { d = newD }              // d==0 → 沿用前一距離
            guard l >= 0, m >= 0, litPos + Int(l) <= literals.count, d > 0 || m == 0 else { return nil }
            dst.append(contentsOf: literals[litPos..<(litPos + Int(l))])
            litPos += Int(l)
            if m > 0 {
                guard Int(d) <= dst.count else { return nil }
                let start = dst.count - Int(d)
                for k in 0..<Int(m) { dst.append(dst[start + k]) } // 允許重疊複製
            }
        }
        return v1HeaderSize + nPayload
    }
}

// =====================================================================
// MARK: - 測試 / 驗證
// =====================================================================

func runLZFSEv1Tests() {
    func roundTrip(_ name: String, _ data: Data) {
        let packed = LZFSEv1.compress(data)
        let unpacked = LZFSEv1.decompress(packed)
        let ok = unpacked == data
        let ratio = data.isEmpty ? 0 : Double(packed.count) / Double(data.count) * 100
        print("[\(name)] \(data.count) → \(packed.count) bytes (\(String(format: "%.1f", ratio))%)  自我往返: \(ok ? "✓" : "✗ 失敗")")

        #if canImport(Compression)
        // 關鍵驗證：本實作的輸出交給 Apple 官方解碼器
        if !data.isEmpty {
            var dstBuf = Data(count: data.count + 16)
            let written = dstBuf.withUnsafeMutableBytes { dp -> Int in
                packed.withUnsafeBytes { sp -> Int in
                    compression_decode_buffer(
                        dp.bindMemory(to: UInt8.self).baseAddress!, data.count + 16,
                        sp.bindMemory(to: UInt8.self).baseAddress!, packed.count,
                        nil, COMPRESSION_LZFSE)
                }
            }
            let appleOK = written == data.count && dstBuf.prefix(written) == data
            print("       Apple 解碼器驗證: \(appleOK ? "✓ 位元相容" : "✗ 不相容")")
        }
        #endif
    }

    roundTrip("重複文字", Data(String(repeating: "LZFSE 位元相容測試。The quick brown fox. ", count: 400).utf8))
    roundTrip("低熵", Data(repeating: 0x41, count: 50_000))
    roundTrip("隨機(不可壓)", Data((0..<8192).map { _ in UInt8.random(in: 0...255) }))
    roundTrip("小輸入", Data("hi".utf8))
    var mixed = Data()
    for i in 0..<2000 { mixed.append(Data("record-\(i % 97): value=\(i * 31 % 1000)\n".utf8)) }
    roundTrip("結構化資料", mixed)
}

runLZFSEv1Tests()
import Foundation

/// Pure-Swift RFC 7693 BLAKE2b and RFC 9106 Argon2id implementation.
/// Produces bit-for-bit identical tags to `src-tauri/src/vault_crypto.rs` without external dependencies.
enum Argon2id {
    enum Argon2Error: Error, Equatable {
        case invalidParameters(String)
    }

    static let versionNumber: UInt32 = 19
    static let typeArgon2id: UInt32 = 2
    private static let blockLen = 1024
    private static let qwordsInBlock = 128
    private static let syncPoints = 4

    private static let blake2bIV: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    ]

    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    ]

    @inline(__always)
    private static func rotr64(_ x: UInt64, _ n: UInt64) -> UInt64 {
        (x >> n) | (x << (64 &- n))
    }

    @inline(__always)
    private static func blake2bG(
        _ v: inout [UInt64],
        _ a: Int,
        _ b: Int,
        _ c: Int,
        _ d: Int,
        _ x: UInt64,
        _ y: UInt64
    ) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = rotr64(v[d] ^ v[a], 32)
        v[c] = v[c] &+ v[d]
        v[b] = rotr64(v[b] ^ v[c], 24)
        v[a] = v[a] &+ v[b] &+ y
        v[d] = rotr64(v[d] ^ v[a], 16)
        v[c] = v[c] &+ v[d]
        v[b] = rotr64(v[b] ^ v[c], 63)
    }

    @inline(__always)
    private static func loadLE64(_ bytes: UnsafeRawBufferPointer, offset: Int) -> UInt64 {
        var out: UInt64 = 0
        for i in 0..<8 {
            out |= UInt64(bytes[offset + i]) << (i * 8)
        }
        return out
    }

    private static func blake2bCompress(
        h: inout [UInt64],
        block: UnsafeRawBufferPointer,
        t0: UInt64,
        t1: UInt64,
        last: Bool
    ) {
        var v = [UInt64](repeating: 0, count: 16)
        for i in 0..<8 {
            v[i] = h[i]
            v[i + 8] = blake2bIV[i]
        }
        v[12] ^= t0
        v[13] ^= t1
        if last {
            v[14] = ~v[14]
        }

        var m = [UInt64](repeating: 0, count: 16)
        for i in 0..<16 {
            m[i] = loadLE64(block, offset: i * 8)
        }

        for r in 0..<12 {
            let s = sigma[r]
            blake2bG(&v, 0, 4, 8, 12, m[s[0]], m[s[1]])
            blake2bG(&v, 1, 5, 9, 13, m[s[2]], m[s[3]])
            blake2bG(&v, 2, 6, 10, 14, m[s[4]], m[s[5]])
            blake2bG(&v, 3, 7, 11, 15, m[s[6]], m[s[7]])
            blake2bG(&v, 0, 5, 10, 15, m[s[8]], m[s[9]])
            blake2bG(&v, 1, 6, 11, 12, m[s[10]], m[s[11]])
            blake2bG(&v, 2, 7, 8, 13, m[s[12]], m[s[13]])
            blake2bG(&v, 3, 4, 9, 14, m[s[14]], m[s[15]])
        }

        for i in 0..<8 {
            h[i] ^= v[i] ^ v[i + 8]
        }
    }

    /// RFC 7693 BLAKE2b (1...64 byte digest).
    static func blake2b(_ data: Data, outputLength: Int, key: Data = Data()) throws -> Data {
        guard outputLength >= 1, outputLength <= 64, key.count <= 64 else {
            throw Argon2Error.invalidParameters("Invalid BLAKE2b length.")
        }

        var h = blake2bIV
        h[0] ^= 0x0101_0000 ^ (UInt64(key.count) << 8) ^ UInt64(outputLength)

        var input = Data()
        if !key.isEmpty {
            input.append(key)
            if key.count < 128 {
                input.append(Data(repeating: 0, count: 128 - key.count))
            }
        }
        input.append(data)

        var totalBytes: UInt64 = 0
        var offset = 0
        var block = [UInt8](repeating: 0, count: 128)
        defer { block.withUnsafeMutableBytes { zeroize($0) } }

        if input.isEmpty {
            block.withUnsafeBytes { raw in
                blake2bCompress(h: &h, block: raw, t0: 0, t1: 0, last: true)
            }
        } else {
            input.withUnsafeBytes { rawInput in
                while offset < input.count {
                    let remaining = input.count - offset
                    let take = min(128, remaining)
                    let isLast = (offset + take) == input.count
                    totalBytes &+= UInt64(take)
                    for i in 0..<128 { block[i] = 0 }
                    for i in 0..<take { block[i] = rawInput[offset + i] }
                    block.withUnsafeBytes { rawBlock in
                        blake2bCompress(h: &h, block: rawBlock, t0: totalBytes, t1: 0, last: isLast)
                    }
                    offset += take
                }
            }
        }

        var out = Data(count: outputLength)
        for i in 0..<outputLength {
            let word = h[i / 8]
            out[i] = UInt8((word >> ((i % 8) * 8)) & 0xff)
        }
        return out
    }

    private static func hashPrime(tau: Int, input: Data) throws -> Data {
        var vLen = Data(count: 4)
        let tauLE = UInt32(tau).littleEndian
        vLen.replaceSubrange(0..<4, with: withUnsafeBytes(of: tauLE) { Data($0) })

        var initial = vLen
        initial.append(input)

        if tau <= 64 {
            return try blake2b(initial, outputLength: tau)
        }

        var result = Data()
        result.reserveCapacity(tau)
        var vi = try blake2b(initial, outputLength: 64)
        result.append(vi.prefix(32))

        while result.count + 64 < tau {
            vi = try blake2b(vi, outputLength: 64)
            result.append(vi.prefix(32))
        }
        let rem = tau - result.count
        let last = try blake2b(vi, outputLength: rem)
        result.append(last)
        return result
    }

    private struct Block {
        var v: [UInt64]

        init() {
            self.v = [UInt64](repeating: 0, count: Argon2id.qwordsInBlock)
        }

        mutating func loadBytes(_ bytes: Data) {
            precondition(bytes.count == Argon2id.blockLen)
            bytes.withUnsafeBytes { raw in
                for i in 0..<Argon2id.qwordsInBlock {
                    var w: UInt64 = 0
                    let base = i * 8
                    for j in 0..<8 {
                        w |= UInt64(raw[base + j]) << (j * 8)
                    }
                    v[i] = w
                }
            }
        }

        func toBytes() -> Data {
            var out = Data(count: Argon2id.blockLen)
            out.withUnsafeMutableBytes { dst in
                let ptr = dst.bindMemory(to: UInt8.self)
                for i in 0..<Argon2id.qwordsInBlock {
                    let w = v[i]
                    let base = i * 8
                    for j in 0..<8 {
                        ptr[base + j] = UInt8((w >> (j * 8)) & 0xff)
                    }
                }
            }
            return out
        }

        mutating func zero() {
            for i in 0..<Argon2id.qwordsInBlock { v[i] = 0 }
        }
    }

    @inline(__always)
    private static func fBlaMka(_ x: UInt64, _ y: UInt64) -> UInt64 {
        let m: UInt64 = 0xFFFF_FFFF
        let xy = (x & m) &* (y & m)
        return x &+ y &+ 2 &* xy
    }

    @inline(__always)
    private static func pMix(
        _ v0: inout UInt64, _ v1: inout UInt64, _ v2: inout UInt64, _ v3: inout UInt64,
        _ v4: inout UInt64, _ v5: inout UInt64, _ v6: inout UInt64, _ v7: inout UInt64,
        _ v8: inout UInt64, _ v9: inout UInt64, _ v10: inout UInt64, _ v11: inout UInt64,
        _ v12: inout UInt64, _ v13: inout UInt64, _ v14: inout UInt64, _ v15: inout UInt64
    ) {
        @inline(__always) func gb(_ a: inout UInt64, _ b: inout UInt64, _ c: inout UInt64, _ d: inout UInt64) {
            a = fBlaMka(a, b)
            d = rotr64(d ^ a, 32)
            c = fBlaMka(c, d)
            b = rotr64(b ^ c, 24)
            a = fBlaMka(a, b)
            d = rotr64(d ^ a, 16)
            c = fBlaMka(c, d)
            b = rotr64(b ^ c, 63)
        }
        gb(&v0, &v4, &v8, &v12)
        gb(&v1, &v5, &v9, &v13)
        gb(&v2, &v6, &v10, &v14)
        gb(&v3, &v7, &v11, &v15)
        gb(&v0, &v5, &v10, &v15)
        gb(&v1, &v6, &v11, &v12)
        gb(&v2, &v7, &v8, &v13)
        gb(&v3, &v4, &v9, &v14)
    }

    private static func applyBlakeRound(to r: inout Block) {
        for i in 0..<8 {
            let b = 16 * i
            var x0 = r.v[b], x1 = r.v[b + 1], x2 = r.v[b + 2], x3 = r.v[b + 3]
            var x4 = r.v[b + 4], x5 = r.v[b + 5], x6 = r.v[b + 6], x7 = r.v[b + 7]
            var x8 = r.v[b + 8], x9 = r.v[b + 9], x10 = r.v[b + 10], x11 = r.v[b + 11]
            var x12 = r.v[b + 12], x13 = r.v[b + 13], x14 = r.v[b + 14], x15 = r.v[b + 15]
            pMix(
                &x0, &x1, &x2, &x3,
                &x4, &x5, &x6, &x7,
                &x8, &x9, &x10, &x11,
                &x12, &x13, &x14, &x15
            )
            r.v[b] = x0; r.v[b + 1] = x1; r.v[b + 2] = x2; r.v[b + 3] = x3
            r.v[b + 4] = x4; r.v[b + 5] = x5; r.v[b + 6] = x6; r.v[b + 7] = x7
            r.v[b + 8] = x8; r.v[b + 9] = x9; r.v[b + 10] = x10; r.v[b + 11] = x11
            r.v[b + 12] = x12; r.v[b + 13] = x13; r.v[b + 14] = x14; r.v[b + 15] = x15
        }
        for i in 0..<8 {
            let c = 2 * i
            var x0 = r.v[c], x1 = r.v[c + 1], x2 = r.v[c + 16], x3 = r.v[c + 17]
            var x4 = r.v[c + 32], x5 = r.v[c + 33], x6 = r.v[c + 48], x7 = r.v[c + 49]
            var x8 = r.v[c + 64], x9 = r.v[c + 65], x10 = r.v[c + 80], x11 = r.v[c + 81]
            var x12 = r.v[c + 96], x13 = r.v[c + 97], x14 = r.v[c + 112], x15 = r.v[c + 113]
            pMix(
                &x0, &x1, &x2, &x3,
                &x4, &x5, &x6, &x7,
                &x8, &x9, &x10, &x11,
                &x12, &x13, &x14, &x15
            )
            r.v[c] = x0; r.v[c + 1] = x1; r.v[c + 16] = x2; r.v[c + 17] = x3
            r.v[c + 32] = x4; r.v[c + 33] = x5; r.v[c + 48] = x6; r.v[c + 49] = x7
            r.v[c + 64] = x8; r.v[c + 65] = x9; r.v[c + 80] = x10; r.v[c + 81] = x11
            r.v[c + 96] = x12; r.v[c + 97] = x13; r.v[c + 112] = x14; r.v[c + 113] = x15
        }
    }

    private static func fillBlock(prev: Block, refBlock: Block, nextOut: inout Block, withXor: Bool) {
        var r = Block()
        var z = Block()
        for i in 0..<qwordsInBlock {
            let x = prev.v[i] ^ refBlock.v[i]
            r.v[i] = x
            z.v[i] = x
        }
        applyBlakeRound(to: &z)
        if withXor {
            for i in 0..<qwordsInBlock {
                nextOut.v[i] ^= r.v[i] ^ z.v[i]
            }
        } else {
            for i in 0..<qwordsInBlock {
                nextOut.v[i] = r.v[i] ^ z.v[i]
            }
        }
    }

    private static func genAddresses(
        pass: UInt32,
        lane: UInt32,
        slice: UInt32,
        memoryBlocks: UInt32,
        passes: UInt32,
        segmentLength: Int
    ) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: segmentLength)
        var inputBlock = Block()
        inputBlock.v[0] = UInt64(pass)
        inputBlock.v[1] = UInt64(lane)
        inputBlock.v[2] = UInt64(slice)
        inputBlock.v[3] = UInt64(memoryBlocks)
        inputBlock.v[4] = UInt64(passes)
        inputBlock.v[5] = UInt64(typeArgon2id)
        let zero = Block()
        var tmp = Block()
        var addrBlock = Block()
        var written = 0
        while written < segmentLength {
            inputBlock.v[6] &+= 1
            tmp.zero()
            addrBlock.zero()
            fillBlock(prev: zero, refBlock: inputBlock, nextOut: &tmp, withXor: false)
            fillBlock(prev: zero, refBlock: tmp, nextOut: &addrBlock, withXor: false)
            let take = min(qwordsInBlock, segmentLength - written)
            for k in 0..<take {
                out[written + k] = addrBlock.v[k]
            }
            written += take
        }
        return out
    }

    private static func indexAlpha(
        pass: UInt32,
        slice: UInt32,
        index: Int,
        pseudoRand: UInt32,
        sameLane: Bool,
        laneLength: Int,
        segmentLength: Int
    ) -> Int {
        let referenceAreaSize: Int
        if pass == 0 {
            if slice == 0 {
                referenceAreaSize = index - 1
            } else if sameLane {
                referenceAreaSize = Int(slice) * segmentLength + index - 1
            } else {
                referenceAreaSize = Int(slice) * segmentLength - (index == 0 ? 1 : 0)
            }
        } else if sameLane {
            referenceAreaSize = laneLength - segmentLength + index - 1
        } else {
            referenceAreaSize = laneLength - segmentLength - (index == 0 ? 1 : 0)
        }

        let x = UInt64(pseudoRand)
        let r0 = (x &* x) >> 32
        let r1 = UInt64(referenceAreaSize) &- 1 &- ((UInt64(referenceAreaSize) &* r0) >> 32)
        let startPosition: Int
        if pass != 0 && slice != UInt32(syncPoints - 1) {
            startPosition = (Int(slice) + 1) * segmentLength
        } else {
            startPosition = 0
        }
        return (startPosition + Int(r1)) % laneLength
    }

    /// RFC 9106 Argon2id derivation.
    static func derive(
        password: Data,
        salt: Data,
        secret: Data = Data(),
        associatedData: Data = Data(),
        memoryKiB: UInt32,
        iterations: UInt32,
        parallelism: UInt32,
        tagLength: Int = 32
    ) throws -> Data {
        guard parallelism >= 1, parallelism <= 0xFF_FFFF else {
            throw Argon2Error.invalidParameters("Invalid Argon2id parallelism.")
        }
        guard tagLength >= 4 else {
            throw Argon2Error.invalidParameters("Invalid Argon2id tag length.")
        }
        guard memoryKiB >= 8 * parallelism, iterations >= 1, salt.count >= 8 else {
            throw Argon2Error.invalidParameters("Invalid Argon2id memory, iterations, or salt.")
        }

        var mBlocks = memoryKiB
        let segmentLength = Int(mBlocks) / (syncPoints * Int(parallelism))
        let laneLength = segmentLength * syncPoints
        mBlocks = UInt32(laneLength * Int(parallelism))

        // H0 = BLAKE2b-64(p, T, m, t, v=19, y=2, len(P), P, len(S), S, len(K), K, len(X), X)
        var h0In = Data()
        func appendLE(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { h0In.append(contentsOf: $0) }
        }
        func appendBytes(_ d: Data) {
            appendLE(UInt32(d.count))
            h0In.append(d)
        }
        appendLE(parallelism)
        appendLE(UInt32(tagLength))
        appendLE(memoryKiB)
        appendLE(iterations)
        appendLE(versionNumber)
        appendLE(typeArgon2id)
        appendBytes(password)
        appendBytes(salt)
        appendBytes(secret)
        appendBytes(associatedData)

        let h0 = try blake2b(h0In, outputLength: 64)
        h0In.withUnsafeMutableBytes { zeroize($0) }

        var mem = [Block](repeating: Block(), count: Int(mBlocks))
        defer {
            for i in mem.indices { mem[i].zero() }
        }

        for lane in 0..<Int(parallelism) {
            for idx in 0..<2 {
                var seed = h0
                var le0 = UInt32(idx).littleEndian
                var le1 = UInt32(lane).littleEndian
                withUnsafeBytes(of: &le0) { seed.append(contentsOf: $0) }
                withUnsafeBytes(of: &le1) { seed.append(contentsOf: $0) }
                let blockBytes = try hashPrime(tau: blockLen, input: seed)
                mem[lane * laneLength + idx].loadBytes(blockBytes)
            }
        }

        for pass in 0..<iterations {
            for slice in 0..<UInt32(syncPoints) {
                let dataIndependent = (pass == 0 && slice < 2)
                for lane in 0..<Int(parallelism) {
                    let addresses: [UInt64] = dataIndependent
                        ? genAddresses(
                            pass: pass,
                            lane: UInt32(lane),
                            slice: slice,
                            memoryBlocks: mBlocks,
                            passes: iterations,
                            segmentLength: segmentLength
                        )
                        : []

                    let startIdx = (pass == 0 && slice == 0) ? 2 : 0
                    for index in startIdx..<segmentLength {
                        let curOffset = Int(slice) * segmentLength + index
                        let prevOffset = curOffset == 0 ? (laneLength - 1) : (curOffset - 1)
                        let prevBlock = mem[lane * laneLength + prevOffset]

                        let pseudo: UInt64 = dataIndependent ? addresses[index] : prevBlock.v[0]
                        let j1 = UInt32(truncatingIfNeeded: pseudo)
                        let j2 = UInt32(truncatingIfNeeded: pseudo >> 32)
                        let refLane: Int = (pass == 0 && slice == 0)
                            ? lane
                            : Int(j2 % parallelism)
                        let sameLane = refLane == lane
                        let refIndex = indexAlpha(
                            pass: pass,
                            slice: slice,
                            index: index,
                            pseudoRand: j1,
                            sameLane: sameLane,
                            laneLength: laneLength,
                            segmentLength: segmentLength
                        )

                        let refBlock = mem[refLane * laneLength + refIndex]
                        let curIdx = lane * laneLength + curOffset
                        var target = mem[curIdx]
                        fillBlock(
                            prev: prevBlock,
                            refBlock: refBlock,
                            nextOut: &target,
                            withXor: pass != 0
                        )
                        mem[curIdx] = target
                    }
                }
            }
        }

        var finalBlock = mem[laneLength - 1]
        for lane in 1..<Int(parallelism) {
            let lastInLane = mem[lane * laneLength + laneLength - 1]
            for i in 0..<qwordsInBlock {
                finalBlock.v[i] ^= lastInLane.v[i]
            }
        }
        return try hashPrime(tau: tagLength, input: finalBlock.toBytes())
    }

    @inline(__always)
    static func zeroize(_ buf: UnsafeMutableRawBufferPointer) {
        guard let ptr = buf.baseAddress else { return }
        ptr.initializeMemory(as: UInt8.self, repeating: 0, count: buf.count)
    }
}

import Foundation

/// 手写 AES（只用加密方向）。
///
/// 为什么要自己写：AES-CCM 需要"单块 AES 加密"（CBC-MAC 与 CTR 都用 E_K），
/// 而 CryptoKit / swift-crypto 只公开 AES-GCM、ChaChaPoly 这类 AEAD，
/// 没有 ECB，也拿不到原始 keystream。CCM 是 BLE 的米家协议在用的模式，
/// 所以这里补一个最小的、只做加密的 AES 实现（120 行，比引一个 C 库可控）。
///
/// 正确性由 FIPS-197 附录 C 的三个向量 + 由 .NET 生成的 CCM 黄金向量保证，
/// 见 Tests/CuktechCoreTests/GoldenVectorTests.swift。
public struct AES {
    public let rounds: Int
    private let roundKeys: [UInt8]

    public init(key: [UInt8]) {
        precondition(key.count == 16 || key.count == 24 || key.count == 32, "AES key must be 16/24/32 bytes, got \(key.count)")
        let nk = key.count / 4
        let nr = nk + 6
        rounds = nr

        var w = [UInt32](repeating: 0, count: 4 * (nr + 1))
        for i in 0..<nk {
            w[i] = (UInt32(key[4 * i]) << 24) | (UInt32(key[4 * i + 1]) << 16)
                 | (UInt32(key[4 * i + 2]) << 8) | UInt32(key[4 * i + 3])
        }
        var rcon: UInt8 = 1
        for i in nk..<w.count {
            var t = w[i - 1]
            if i % nk == 0 {
                t = Self.subWord((t << 8) | (t >> 24))
                t ^= UInt32(rcon) << 24
                rcon = Self.mul2(rcon)
            } else if nk > 6 && i % nk == 4 {
                t = Self.subWord(t)
            }
            w[i] = w[i - nk] ^ t
        }

        var rk = [UInt8]()
        rk.reserveCapacity(w.count * 4)
        for word in w {
            rk.append(UInt8(truncatingIfNeeded: word >> 24))
            rk.append(UInt8(truncatingIfNeeded: word >> 16))
            rk.append(UInt8(truncatingIfNeeded: word >> 8))
            rk.append(UInt8(truncatingIfNeeded: word))
        }
        roundKeys = rk
    }

    /// 加密一个 16 字节块。调用方负责分块（CCM 就是这么用的）。
    public func encryptBlock(_ input: [UInt8]) -> [UInt8] {
        precondition(input.count == 16, "AES block must be 16 bytes")
        var s = input
        addRoundKey(&s, 0)
        for round in 1..<rounds {
            subBytes(&s)
            shiftRows(&s)
            mixColumns(&s)
            addRoundKey(&s, round)
        }
        subBytes(&s)
        shiftRows(&s)
        addRoundKey(&s, rounds)
        return s
    }

    // MARK: - 轮函数

    private func addRoundKey(_ s: inout [UInt8], _ round: Int) {
        let base = round * 16
        for i in 0..<16 { s[i] ^= roundKeys[base + i] }
    }

    private func subBytes(_ s: inout [UInt8]) {
        for i in 0..<16 { s[i] = AES.sbox[Int(s[i])] }
    }

    /// state[r][c] 在一维里是 s[r + 4c]；第 r 行循环左移 r 位。
    private func shiftRows(_ s: inout [UInt8]) {
        var t = s
        for c in 0..<4 {
            for r in 0..<4 {
                t[r + 4 * c] = s[r + 4 * ((c + r) % 4)]
            }
        }
        s = t
    }

    private func mixColumns(_ s: inout [UInt8]) {
        for c in 0..<4 {
            let i = 4 * c
            let a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3]
            s[i]     = AES.mul2(a0) ^ AES.mul3(a1) ^ a2 ^ a3
            s[i + 1] = a0 ^ AES.mul2(a1) ^ AES.mul3(a2) ^ a3
            s[i + 2] = a0 ^ a1 ^ AES.mul2(a2) ^ AES.mul3(a3)
            s[i + 3] = AES.mul3(a0) ^ a1 ^ a2 ^ AES.mul2(a3)
        }
    }

    // MARK: - GF(2^8) 小工具

    @inline(__always) private static func mul2(_ x: UInt8) -> UInt8 {
        (x & 0x80) != 0 ? (x << 1) ^ 0x1b : (x << 1)
    }

    @inline(__always) private static func mul3(_ x: UInt8) -> UInt8 {
        mul2(x) ^ x
    }

    private static func subWord(_ word: UInt32) -> UInt32 {
        var out: UInt32 = 0
        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = UInt8(truncatingIfNeeded: word >> UInt32(shift))
            out |= UInt32(sbox[Int(byte)]) << UInt32(shift)
        }
        return out
    }

    static let sbox: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    ]
}

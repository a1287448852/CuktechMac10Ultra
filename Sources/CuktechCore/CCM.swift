import Foundation

/// AES-CCM（NIST SP 800-38C），无 AAD 为主、AAD 也支持。
///
/// 米家 BLE 的加密包用的是 CCM：nonce 12 字节（所以 L = 15 - 12 = 3）、tag 4 字节。
/// .NET 的 `AesCcm` 支持 tag 4..16，CryptoKit 完全没有 CCM，所以这层必须自己写。
/// 验收靠 .NET 生成的黄金向量（tools/golden-vectors/ccm-vectors.json），
/// 注意 B0 里编码了 tag 长度 t，t 参与第一块 MAC——少算这个就全错。
public enum AESCCM {
    public struct InvalidParameter: Error {}
    public struct AuthenticationFailure: Error {}

    /// 加密。返回密文与 tag（tag 单独给出，调用方自己决定怎么拼包）。
    public static func seal(
        key: [UInt8],
        nonce: [UInt8],
        plaintext: [UInt8],
        aad: [UInt8] = [],
        tagLength: Int = 4
    ) throws -> (ciphertext: [UInt8], tag: [UInt8]) {
        let l = try validate(nonce: nonce, tagLength: tagLength, messageLength: plaintext.count)
        let aes = AES(key: key)

        let mac = macTag(aes: aes, nonce: nonce, aad: aad, message: plaintext, l: l, tagLength: tagLength)
        let s0 = aes.encryptBlock(counterBlock(nonce: nonce, l: l, counter: 0))
        var tag = [UInt8](repeating: 0, count: tagLength)
        for i in 0..<tagLength { tag[i] = mac[i] ^ s0[i] }

        var ciphertext = [UInt8](repeating: 0, count: plaintext.count)
        var offset = 0
        var counter: UInt32 = 1
        while offset < plaintext.count {
            let stream = aes.encryptBlock(counterBlock(nonce: nonce, l: l, counter: counter))
            let n = min(16, plaintext.count - offset)
            for i in 0..<n { ciphertext[offset + i] = plaintext[offset + i] ^ stream[i] }
            offset += n
            counter += 1
        }
        return (ciphertext, tag)
    }

    /// 解密并校验 tag。tag 不对抛 `AuthenticationFailure`（米家会话失步就是这样）。
    public static func open(
        key: [UInt8],
        nonce: [UInt8],
        ciphertext: [UInt8],
        tag: [UInt8],
        aad: [UInt8] = []
    ) throws -> [UInt8] {
        let l = try validate(nonce: nonce, tagLength: tag.count, messageLength: ciphertext.count)
        let aes = AES(key: key)

        let s0 = aes.encryptBlock(counterBlock(nonce: nonce, l: l, counter: 0))
        var expected = [UInt8](repeating: 0, count: tag.count)
        for i in 0..<tag.count { expected[i] = tag[i] ^ s0[i] }

        var plaintext = [UInt8](repeating: 0, count: ciphertext.count)
        var offset = 0
        var counter: UInt32 = 1
        while offset < ciphertext.count {
            let stream = aes.encryptBlock(counterBlock(nonce: nonce, l: l, counter: counter))
            let n = min(16, ciphertext.count - offset)
            for i in 0..<n { plaintext[offset + i] = ciphertext[offset + i] ^ stream[i] }
            offset += n
            counter += 1
        }

        let mac = macTag(aes: aes, nonce: nonce, aad: aad, message: plaintext, l: l, tagLength: tag.count)
        var diff: UInt8 = 0
        for i in 0..<tag.count { diff |= mac[i] ^ expected[i] }
        guard diff == 0 else { throw AuthenticationFailure() }
        return plaintext
    }

    // MARK: - 内部

    private static func validate(nonce: [UInt8], tagLength: Int, messageLength: Int) throws -> Int {
        guard (7...13).contains(nonce.count) else { throw InvalidParameter() }
        guard tagLength >= 4, tagLength <= 16, tagLength % 2 == 0 else { throw InvalidParameter() }
        let l = 15 - nonce.count
        // 明文长度必须能用 L 个字节表示
        guard l >= 2, l <= 8 else { throw InvalidParameter() }
        if l < 8 {
            let limit = 1 << (8 * l)
            guard messageLength < limit else { throw InvalidParameter() }
        }
        return l
    }

    /// B0 = flags || nonce || msgLen(L 字节大端)
    private static func b0(nonce: [UInt8], aadLength: Int, messageLength: Int, l: Int, tagLength: Int) -> [UInt8] {
        var flags: UInt8 = 0
        if aadLength > 0 { flags |= 0x40 }
        flags |= UInt8(((tagLength - 2) / 2) << 3)
        flags |= UInt8(l - 1)

        var block = [UInt8](repeating: 0, count: 16)
        block[0] = flags
        for i in 0..<nonce.count { block[1 + i] = nonce[i] }
        var length = messageLength
        for i in stride(from: l - 1, through: 0, by: -1) {
            // 最低字节落在最后一格（索引 15），往高位依次往前
            block[16 - l + i] = UInt8(truncatingIfNeeded: length)
            length >>= 8
        }
        return block
    }

    /// A_i = L-1 || nonce || counter(L 字节大端)
    private static func counterBlock(nonce: [UInt8], l: Int, counter: UInt32) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 16)
        block[0] = UInt8(l - 1)
        for i in 0..<nonce.count { block[1 + i] = nonce[i] }
        var value = counter
        for i in stride(from: l - 1, through: 0, by: -1) {
            block[16 - l + i] = UInt8(truncatingIfNeeded: value)
            value >>= 8
        }
        return block
    }

    /// CBC-MAC：X1 = E(B0)，Xi = E(X(i-1) ^ B(i-1))。AAD 与明文是同一段连续流。
    private static func macTag(
        aes: AES,
        nonce: [UInt8],
        aad: [UInt8],
        message: [UInt8],
        l: Int,
        tagLength: Int
    ) -> [UInt8] {
        var stream = [UInt8]()
        stream.reserveCapacity(aad.count + 10 + message.count)
        if !aad.isEmpty {
            let n = aad.count
            if n < 0xFF00 {
                stream.append(UInt8(truncatingIfNeeded: n >> 8))
                stream.append(UInt8(truncatingIfNeeded: n))
            } else if n <= 0xFFFF_FFFE {
                stream.append(0xFF); stream.append(0xFE)
                stream.append(UInt8(truncatingIfNeeded: n >> 24))
                stream.append(UInt8(truncatingIfNeeded: n >> 16))
                stream.append(UInt8(truncatingIfNeeded: n >> 8))
                stream.append(UInt8(truncatingIfNeeded: n))
            } else {
                stream.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
                for shift in stride(from: 56, through: 0, by: -8) {
                    stream.append(UInt8(truncatingIfNeeded: UInt64(n) >> UInt64(shift)))
                }
            }
            stream.append(contentsOf: aad)
        }
        stream.append(contentsOf: message)

        var x = aes.encryptBlock(b0(nonce: nonce, aadLength: aad.count, messageLength: message.count, l: l, tagLength: tagLength))
        var offset = 0
        while offset < stream.count {
            var block = [UInt8](repeating: 0, count: 16)
            let n = min(16, stream.count - offset)
            for i in 0..<n { block[i] = stream[offset + i] }
            for i in 0..<16 { x[i] ^= block[i] }
            x = aes.encryptBlock(x)
            offset += 16
        }
        return Array(x[0..<tagLength])
    }
}

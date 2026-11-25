import Foundation
import Crypto

/// 小米云 API 的加密原语，逐行对照 Windows 版 src/CuktechLogin/MiCrypto.cs
/// （那份又是照 tools/token-fetch/fetch_token.py 抄的）。
/// 只用 swift-crypto，所以 Linux 上也能跑单测。
public enum MiCrypto {
    private static let agentChars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let deviceIdChars = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    // MARK: - RC4

    /// RC4 流密码 + 丢弃前 1024 字节密钥流
    /// （等价于 pycryptodome 里 ARC4.new(key) 之后先 encrypt(1024 个零字节)）。
    public static func rc4Drop1024(key: [UInt8], data: [UInt8]) -> [UInt8] {
        precondition(!key.isEmpty, "RC4 key 不能为空")
        var s = [UInt8](0...255)
        var j = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(key[i % key.count])) & 0xFF
            s.swapAt(i, j)
        }

        var a = 0
        var b = 0
        for _ in 0..<1024 {
            a = (a + 1) & 0xFF
            b = (b + Int(s[a])) & 0xFF
            s.swapAt(a, b)
        }

        var out = [UInt8](repeating: 0, count: data.count)
        for n in 0..<data.count {
            a = (a + 1) & 0xFF
            b = (b + Int(s[a])) & 0xFF
            s.swapAt(a, b)
            out[n] = data[n] ^ s[(Int(s[a]) + Int(s[b])) & 0xFF]
        }
        return out
    }

    // MARK: - base64

    public static func b64Encode(_ raw: [UInt8]) -> String {
        Data(raw).base64EncodedString()
    }

    /// 小米返回的 base64 有时不带 padding；顺便容忍 url-safe 字母表。
    public static func b64Decode(_ text: String?) -> [UInt8]? {
        var s = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return [] }
        let pad = (4 - s.count % 4) % 4
        if pad > 0 { s += String(repeating: "=", count: pad) }
        if let d = Data(base64Encoded: s) { return [UInt8](d) }
        let urlSafe = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if let d = Data(base64Encoded: urlSafe) { return [UInt8](d) }
        return nil
    }

    // MARK: - 随机串

    public static func randomString(_ alphabet: [Character], _ length: Int) -> String {
        var out = ""
        out.reserveCapacity(length)
        for _ in 0..<length {
            out.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return out
    }

    /// 参考实现的 UA：Android-7.1.1-1.0.0-ONEPLUS A3010-136-<11 位随机> MIIO/<6 位随机>。
    public static func generateAgent() -> String {
        "Android-7.1.1-1.0.0-ONEPLUS A3010-136-" + randomString(agentChars, 11) + " MIIO/" + randomString(agentChars, 6)
    }

    public static func generateDeviceId() -> String { randomString(deviceIdChars, 16) }

    /// base64(8 字节随机 + (millis / 60000) 的 4 字节大端)。
    public static func generateNonce(millis: Int64) -> String {
        var buf = [UInt8](repeating: 0, count: 12)
        for i in 0..<8 { buf[i] = UInt8.random(in: 0...255) }
        let minutes = UInt32(truncatingIfNeeded: millis / 60000)
        buf[8] = UInt8((minutes >> 24) & 0xFF)
        buf[9] = UInt8((minutes >> 16) & 0xFF)
        buf[10] = UInt8((minutes >> 8) & 0xFF)
        buf[11] = UInt8(minutes & 0xFF)
        return b64Encode(buf)
    }

    // MARK: - 签名

    /// base64(sha256(base64解码(ssecurity) + base64解码(nonce)))。
    public static func signedNonce(ssecurity: String, nonce: String) -> String? {
        guard let key = b64Decode(ssecurity), let salt = b64Decode(nonce) else { return nil }
        let digest = SHA256.hash(data: Data(key + salt))
        return b64Encode(Array(digest))
    }

    /// base64(RC4-drop1024(base64解码(signed_nonce), utf8(payload)))。
    public static func encryptRC4(signedNonceB64: String, payload: String) -> String? {
        guard let key = b64Decode(signedNonceB64), !key.isEmpty else { return nil }
        return b64Encode(rc4Drop1024(key: key, data: Array(payload.utf8)))
    }

    /// utf8(RC4-drop1024(base64解码(signed_nonce), base64解码(payload)))。
    public static func decryptRC4(signedNonceB64: String, payloadB64: String) -> String? {
        guard let key = b64Decode(signedNonceB64), !key.isEmpty,
              let body = b64Decode(payloadB64) else { return nil }
        return String(decoding: rc4Drop1024(key: key, data: body), as: UTF8.self)
    }

    /// Python `url.split("com")[1]` 的等价实现：取第一个 "com" 之后、第二个 "com" 之前的子串，
    /// 再把 "/app/" 换成 "/"。参数顺序必须保持插入顺序，签名对顺序敏感。
    public static func apiPathPart(_ url: String) -> String {
        guard let first = url.range(of: "com") else { return url }
        let rest = url[first.upperBound...]
        let slice: Substring
        if let second = rest.range(of: "com") {
            slice = rest[..<second.lowerBound]
        } else {
            slice = rest
        }
        return slice.replacingOccurrences(of: "/app/", with: "/")
    }

    /// SHA1 签名：METHOD&path&k=v...&signed_nonce。
    public static func generateEncSignature(url: String, method: String, sn: String, params: [(String, String)]) -> String {
        var parts = [method.uppercased(), apiPathPart(url)]
        for (k, v) in params { parts.append(k + "=" + v) }
        parts.append(sn)
        let joined = parts.joined(separator: "&")
        let digest = Insecure.SHA1.hash(data: Data(joined.utf8))
        return b64Encode(Array(digest))
    }

    /// 两次签名 + 整体加密：
    /// 1) 先给明文参数集算 rc4_hash__；
    /// 2) 把每个值 RC4 加密；
    /// 3) 对加密后的参数集再算一次 signature；
    /// 4) 附上 ssecurity / _nonce（这两个不加密）。
    /// 返回顺序即最终 query string 顺序：data, rc4_hash__, signature, ssecurity, _nonce。
    public static func generateEncParams(
        url: String,
        method: String,
        sn: String,
        nonce: String,
        params: [(String, String)],
        ssecurity: String
    ) -> [(String, String)] {
        var fields = params
        fields.append(("rc4_hash__", generateEncSignature(url: url, method: method, sn: sn, params: fields)))
        for i in 0..<fields.count {
            let v = fields[i].1
            fields[i].1 = encryptRC4(signedNonceB64: sn, payload: v) ?? v
        }
        fields.append(("signature", generateEncSignature(url: url, method: method, sn: sn, params: fields)))
        fields.append(("ssecurity", ssecurity))
        fields.append(("_nonce", nonce))
        return fields
    }

    // MARK: - beacon key

    /// 把 24 位 hex 或 base64 统一规范成小写 hex（对应 key_to_hex）。
    /// 24 位 hex 原样返回（= 12 字节）；否则按 base64 解码再转 hex；都失败返回 nil。
    public static func keyToHex(_ key: String?) -> String? {
        guard let raw = key?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.count == 24, raw.allSatisfy({ c in c.isHexDigit }) {
            return raw.lowercased()
        }
        guard let bytes = b64Decode(raw), !bytes.isEmpty else { return nil }
        return bytes.hexString.lowercased()
    }
}

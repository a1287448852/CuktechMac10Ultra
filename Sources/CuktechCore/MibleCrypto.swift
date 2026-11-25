import Foundation
import Crypto

/// 米家登录会话要用的两个原语。用 swift-crypto（Linux 上也能跑），
/// 而不是 CryptoKit——后者只在 Apple 平台存在，会让 ubuntu job 编不过。
public enum MibleCrypto {
    public static func hmacSHA256(key: [UInt8], message: [UInt8]) -> [UInt8] {
        let code = HMAC<SHA256>.authenticationCode(for: Data(message), using: SymmetricKey(data: key))
        return Array(code)
    }

    /// HKDF-SHA256。MibleSession 用它从 token 派生出 devKey/appKey/devIv/appIv。
    public static func hkdfSHA256(
        ikm: [UInt8],
        salt: [UInt8],
        info: String,
        outputByteCount: Int
    ) -> [UInt8] {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data(salt),
            info: Data(info.utf8),
            outputByteCount: outputByteCount
        )
        return key.withUnsafeBytes { Array($0) }
    }
}

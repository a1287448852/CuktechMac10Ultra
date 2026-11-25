import XCTest
@testable import CuktechCore

/// 黄金向量的来源：
/// - AES 三组来自 FIPS-197 附录 C（官方标准值）。
/// - CCM 七组来自 .NET 8 的 `AesCcm`，生成脚本见 .tools/ccmtest，结果落在
///   tools/golden-vectors/ccm-vectors.json。参数是米家 BLE 的实际用法：
///   nonce 12 字节（L=3）、tag 4 字节、无 AAD。
/// - HKDF / HMAC 四组来自 C# 版 MibleSession 的密钥派生。
///
/// 手写 AES + 手写 CCM 只要有一位错，这里就会红。这是整个移植的地基。
final class AesVectorTests: XCTestCase {
    func testFips197SingleBlocks() {
        let plain = [UInt8].fromHex("00112233445566778899aabbccddeeff")
        let cases: [(name: String, key: String, cipher: String)] = [
            ("AES-128", "000102030405060708090a0b0c0d0e0f", "69c4e0d86a7b0430d8cdb78070b4c55a"),
            ("AES-192", "000102030405060708090a0b0c0d0e0f1011121314151617", "dda97ca4864cdfe06eaf70a0ec0d7191"),
            ("AES-256", "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", "8ea2b7ca516745bfeafc49904b496089"),
        ]
        for item in cases {
            let aes = AES(key: [UInt8].fromHex(item.key))
            XCTAssertEqual(aes.encryptBlock(plain).hexString, item.cipher, item.name)
        }
    }
}

final class CcmVectorTests: XCTestCase {
    struct Vector {
        let name: String
        let nonce: String
        let plain: String
        let tagLength: Int
        let cipher: String
        let tag: String
    }

    // key 全部相同：00112233445566778899aabbccddeeff
    private let key = [UInt8].fromHex("00112233445566778899aabbccddeeff")

    private let vectors: [Vector] = [
        Vector(name: "nonce12_t4_empty", nonce: "000102030405060708090a0b", plain: "", tagLength: 4,
               cipher: "", tag: "d94ed46d"),
        Vector(name: "nonce12_t4_1b", nonce: "000102030405060708090a0b", plain: "61", tagLength: 4,
               cipher: "6a", tag: "a01dcd37"),
        Vector(name: "nonce12_t4_11b", nonce: "000102030405060708090a0b",
               plain: "68656c6c6f2d6d69626c65", tagLength: 4,
               cipher: "637d9b005213195b09ee24", tag: "23beab91"),
        Vector(name: "nonce12_t4_20b", nonce: "000102030405060708090a0b",
               plain: "68656c6c6f2d6d69626c652d7061796c6f616421", tagLength: 4,
               cipher: "637d9b005213195b09ee245a699bd566dcbf5575", tag: "9465673f"),
        Vector(name: "nonce12_t4_40b", nonce: "000102030405060708090a0b",
               plain: "30313233343536373839616263646566303132333435363738396162636465663031323334353637",
               tagLength: 4,
               cipher: "3b29c55f090b420553bb20157a9ec96c83ef03679398b83b7b20b6a6f235c307372d6c79010e544e",
               tag: "eed3bcc7"),
        Vector(name: "nonce13_t4_20b", nonce: "101112131415161718191a1b1c",
               plain: "68656c6c6f2d6d69626c652d7061796c6f616421", tagLength: 4,
               cipher: "d899ce68cecbe2021418043ffa3441e8d85f4393", tag: "75166751"),
        Vector(name: "nonce12_t8_20b", nonce: "000102030405060708090a0b",
               plain: "68656c6c6f2d6d69626c652d7061796c6f616421", tagLength: 8,
               cipher: "637d9b005213195b09ee245a699bd566dcbf5575", tag: "d65dbdbefb60f9ba"),
    ]

    func testSealMatchesDotNet() throws {
        for item in vectors {
            let result = try AESCCM.seal(
                key: key,
                nonce: [UInt8].fromHex(item.nonce),
                plaintext: [UInt8].fromHex(item.plain),
                tagLength: item.tagLength
            )
            XCTAssertEqual(result.ciphertext.hexString, item.cipher, item.name + " 密文")
            XCTAssertEqual(result.tag.hexString, item.tag, item.name + " tag")
        }
    }

    func testOpenRoundTrip() throws {
        for item in vectors {
            let plain = try AESCCM.open(
                key: key,
                nonce: [UInt8].fromHex(item.nonce),
                ciphertext: [UInt8].fromHex(item.cipher),
                tag: [UInt8].fromHex(item.tag)
            )
            XCTAssertEqual(plain.hexString, item.plain, item.name + " 解密")
        }
    }

    func testTamperedTagIsRejected() throws {
        let item = vectors[3]
        var tag = [UInt8].fromHex(item.tag)
        tag[0] ^= 0x01
        XCTAssertThrowsError(try AESCCM.open(
            key: key,
            nonce: [UInt8].fromHex(item.nonce),
            ciphertext: [UInt8].fromHex(item.cipher),
            tag: tag
        ))
    }
}

final class MibleCryptoVectorTests: XCTestCase {
    private let token = [UInt8].fromHex("00112233445566778899aabbccddeeff")
    private let randKey = [UInt8].fromHex("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
    private let devRandom = [UInt8].fromHex("ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100")

    func testHkdfDerivesTheSameKeysAsTheCSharpVersion() {
        let salt = randKey + devRandom
        let derived = MibleCrypto.hkdfSHA256(ikm: token, salt: salt, info: "mible-login-info", outputByteCount: 64)

        XCTAssertEqual(derived.hexString, "dbda7471e98fe1af47d8bf0d3fe01d98ad420e3a289367172a14d0adf1e41be54d355491bb3ba21f34309668d411a88f353db82bebd264f175b498eb39bae2b5")
        XCTAssertEqual(Array(derived[0..<16]).hexString, "dbda7471e98fe1af47d8bf0d3fe01d98", "devKey")
        XCTAssertEqual(Array(derived[16..<32]).hexString, "ad420e3a289367172a14d0adf1e41be5", "appKey")
        XCTAssertEqual(Array(derived[32..<36]).hexString, "4d355491", "devIv")
        XCTAssertEqual(Array(derived[36..<40]).hexString, "bb3ba21f", "appIv")
    }

    func testHmacChecksMatchTheCSharpVersion() {
        let salt = randKey + devRandom
        let saltInv = devRandom + randKey
        let derived = MibleCrypto.hkdfSHA256(ikm: token, salt: salt, info: "mible-login-info", outputByteCount: 64)
        let devKey = Array(derived[0..<16])
        let appKey = Array(derived[16..<32])

        XCTAssertEqual(MibleCrypto.hmacSHA256(key: devKey, message: saltInv).hexString,
                       "b088d60aefc6b25bb249aca259406215af2a5e46356453c4c2bdbc66de12c56c",
                       "设备身份校验 HMAC(devKey, devRandom||randKey)")
        XCTAssertEqual(MibleCrypto.hmacSHA256(key: appKey, message: salt).hexString,
                       "77759edcee3a20e233ba76dbc06b7c06a9f8134a3032a522e00bf204ab591d03",
                       "会话确认 HMAC(appKey, randKey||devRandom)")
    }
}

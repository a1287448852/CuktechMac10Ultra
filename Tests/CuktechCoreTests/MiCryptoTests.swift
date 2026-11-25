import XCTest
@testable import CuktechCore

/// 向量来自 Windows 版 MiCrypto.cs 的同构 python 实现（工具 .tools/mi-vectors.py），
/// 保证 mac/win 两边对小米云 API 的签名算法一致。
final class MiCryptoTests: XCTestCase {
    private let ssecurity = "A3sMGtnBOelO74Oh2kjAALhpCvJCKcWCaI3zUMmTW7g="
    private let nonce = "AQIDBAUGBwgAvGFO"
    private let signedNonce = "cjqWCI0DL4TDKEO83VF23lvz58pRJsI+89HfCQDVxv8="
    private let url = "https://cn.api.io.mi.com/app/home/home_device_list"

    func testSignedNonce() {
        XCTAssertEqual(MiCrypto.signedNonce(ssecurity: ssecurity, nonce: nonce), signedNonce)
    }

    func testApiPathPart() {
        XCTAssertEqual(MiCrypto.apiPathPart(url), "/home/home_device_list")
        XCTAssertEqual(MiCrypto.apiPathPart("https://cn.api.io.mi.com/app/home/device_list"), "/home/device_list")
    }

    func testEncSignature() {
        let params: [(String, String)] = [("data", "{\"limit\":5}"), ("pv", "2"), ("rc4_hash__", "abc")]
        XCTAssertEqual(MiCrypto.generateEncSignature(url: url, method: "POST", sn: signedNonce, params: params),
                       "l03TTFef6M2i870CbgaIgjMTQyE=")
    }

    func testRc4RoundTrip() {
        let plain = "{\"limit\":5}"
        let ct = MiCrypto.encryptRC4(signedNonceB64: signedNonce, payload: plain)
        XCTAssertEqual(ct, "vkGEXkGmxs0irxw=")
        XCTAssertEqual(MiCrypto.decryptRC4(signedNonceB64: signedNonce, payloadB64: ct!), plain)
    }

    func testEncParamsOrderAndDecrypt() {
        let fields = MiCrypto.generateEncParams(
            url: url, method: "POST", sn: signedNonce, nonce: nonce,
            params: [("data", "{\"limit\":5}"), ("pv", "2")],
            ssecurity: ssecurity)
        XCTAssertEqual(fields.map { $0.0 }, ["data", "pv", "rc4_hash__", "signature", "ssecurity", "_nonce"])
        XCTAssertEqual(fields[5].1, nonce)
        XCTAssertEqual(fields[4].1, ssecurity)
        XCTAssertEqual(MiCrypto.decryptRC4(signedNonceB64: signedNonce, payloadB64: fields[0].1), "{\"limit\":5}")
        XCTAssertEqual(MiCrypto.decryptRC4(signedNonceB64: signedNonce, payloadB64: fields[1].1), "2")
    }

    func testKeyToHex() {
        XCTAssertEqual(MiCrypto.keyToHex("00112233445566778899AABB"), "00112233445566778899aabb")
        XCTAssertEqual(MiCrypto.keyToHex(MiCrypto.b64Encode(Array(0...11))), "000102030405060708090a0b")
        XCTAssertNil(MiCrypto.keyToHex("not base64 at all!!"))
    }

    func testNonceShape() {
        let n = MiCrypto.generateNonce(millis: 1_700_000_000_000)
        let raw = MiCrypto.b64Decode(n)
        XCTAssertEqual(raw?.count, 12)
        let minutes = UInt32(1_700_000_000_000 / 60000)
        XCTAssertEqual(raw?[8], UInt8((minutes >> 24) & 0xFF))
        XCTAssertEqual(raw?[11], UInt8(minutes & 0xFF))
    }
}

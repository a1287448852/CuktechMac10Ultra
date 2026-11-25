import XCTest
@testable import CuktechCore

/// 一个按协议脚本回应的假设备：不碰蓝牙，纯粹验证会话状态机与加解密。
/// 认证流程的每一步都对应 Windows 版 MibleSession.cs 里等待的那一帧。
final class FakeDeviceLink: MibleLink, @unchecked Sendable {
    let token: [UInt8]
    weak var session: MibleSession?
    private(set) var subscribed: Set<MibleChannel> = []

    var randKey: [UInt8] = (0..<16).map { UInt8(0x10 + $0) }
    var devRandom: [UInt8] = (0..<16).map { UInt8(0x40 + $0) }
    var portValue: [UInt8] = [0x01, 0x0A, 0x19, 0xC9]

    private var devKey: [UInt8] = []
    private var appKey: [UInt8] = []
    private var devIv: [UInt8] = []
    private var appIv: [UInt8] = []
    private var devIt: UInt32 = 0
    private(set) var authResultSent = false

    init(token: [UInt8]) { self.token = token }

    // MARK: - MibleLink

    func subscribe(_ channel: MibleChannel) async throws { subscribed.insert(channel) }
    func unsubscribe(_ channel: MibleChannel) async throws { subscribed.remove(channel) }

    func write(_ channel: MibleChannel, _ data: [UInt8]) async throws {
        switch channel {
        case .authCtrl:
            if data == [0xA4] {
                emit(.authData, [0x00, 0x00, 0x04, 0x01])
            }
        case .authData:
            if data.count == 4 && data[2] == 0x05 {
                emit(.authData, [0x00, 0x00, 0x04, 0x01] + [UInt8](repeating: 0xF2, count: 236))
            } else if data == [0x00, 0x00, 0x00, 0x0B, 0x01, 0x00] {
                emit(.authData, [0x00, 0x00, 0x01, 0x01])
            } else if data.count == 18 && data[0] == 0x01 && data[1] == 0x00 {
                randKey = Array(data[2...])
                deriveKeys()
                emit(.authData, [0x00, 0x00, 0x01, 0x00])
                emit(.authData, [0x00, 0x00, 0x02, 0x01] + devRandom)
                emit(.authData, [0x00, 0x00, 0x02, 0x01] + MibleCrypto.hmacSHA256(key: devKey, message: devRandom + randKey))
            } else if data == [0x00, 0x00, 0x00, 0x0A, 0x01, 0x00] {
                emit(.authData, [0x00, 0x00, 0x01, 0x01])
            } else if data.count == 34 && data[0] == 0x01 && data[1] == 0x00 {
                emit(.authData, [0x00, 0x00, 0x01, 0x00])
                emit(.authCtrl, [0x21])
                authResultSent = true
            }
        case .cmdSend:
            if data == [0x00, 0x00, 0x00, 0x00, 0x01, 0x00] {
                emit(.cmdSend, [0x00, 0x00, 0x01, 0x01])
            } else if data.count > 2 && data[0] == 0x01 && data[1] == 0x00 {
                emit(.cmdSend, [0x00, 0x00, 0x01, 0x00])
                handleCommand(Array(data[2...]))
            }
        default:
            break
        }
    }

    // MARK: - 设备侧

    private func emit(_ channel: MibleChannel, _ data: [UInt8]) {
        session?.handleNotification(channel, data)
    }

    private func deriveKeys() {
        let salt = randKey + devRandom
        let derived = MibleCrypto.hkdfSHA256(ikm: token, salt: salt, info: "mible-login-info", outputByteCount: 64)
        devKey = Array(derived[0..<16])
        appKey = Array(derived[16..<32])
        devIv = Array(derived[32..<36])
        appIv = Array(derived[36..<40])
    }

    private func handleCommand(_ encrypted: [UInt8]) {
        guard encrypted.count >= 6 else { return }
        let it = UInt32(encrypted[0]) | (UInt32(encrypted[1]) << 8)
        let nonce = appIv + [0, 0, 0, 0] + [UInt8(it & 0xFF), UInt8((it >> 8) & 0xFF), UInt8((it >> 16) & 0xFF), UInt8((it >> 24) & 0xFF)]
        let body = Array(encrypted[2...])
        let ct = Array(body[0..<(body.count - 4)])
        let tag = Array(body[(body.count - 4)...])
        guard let pt = try? AESCCM.open(key: appKey, nonce: nonce, ciphertext: ct, tag: tag, aad: []),
              let req = MiotCodec.parse(pt) else { return }

        // 响应帧：GET (0x02) 返回 op=0x03；SET (0x00) 返回 op=0x01 ACK（不含值）
        let isSet = req.opcode == MiotCodec.opSet
        var resp = [UInt8](repeating: 0, count: isSet ? 10 : 13 + portValue.count)
        resp[0] = UInt8(resp.count & 0xFF)
        resp[1] = 0x20
        resp[2] = req.seq
        resp[4] = isSet ? 0x01 : 0x03
        resp[5] = 0x01
        resp[6] = req.siid
        resp[7] = req.piid
        if !isSet {
            resp[9] = UInt8(portValue.count & 0xFF)
            resp[10] = 0x50
            resp[11] = UInt8(portValue.count & 0xFF)
            resp[12] = 0x05
            for (i, b) in portValue.enumerated() { resp[13 + i] = b }
        }

        let devNonce = devIv + [0, 0, 0, 0] + [UInt8(devIt & 0xFF), UInt8((devIt >> 8) & 0xFF), UInt8((devIt >> 16) & 0xFF), UInt8((devIt >> 24) & 0xFF)]
        guard let (out, tagOut) = try? AESCCM.seal(key: devKey, nonce: devNonce, plaintext: resp, aad: [], tagLength: 4) else { return }
        devIt += 1
        emit(.cmdRecv, [0x00, 0x00, 0x02, 0x01, UInt8((devIt - 1) & 0xFF), UInt8(((devIt - 1) >> 8) & 0xFF)] + out + tagOut)
    }
}

final class MibleSessionTests: XCTestCase {

    private let token: [UInt8] = Array(0x00...0x0B)

    func testFullAuthAndGet() async throws {
        let link = FakeDeviceLink(token: token)
        let session = try MibleSession(link: link, token: token)
        link.session = session

        try await session.authenticate()
        XCTAssertTrue(session.authenticated)
        XCTAssertTrue(link.authResultSent)
        XCTAssertEqual(session.appKeyHex.count, 32)
        XCTAssertEqual(session.devIvHex.count, 8)

        let msg = try await session.sendCommand(siid: 2, piid: 1, timeout: 3.0)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.opcode, 0x03)
        XCTAssertEqual(msg?.siid, 2)
        XCTAssertEqual(msg?.piid, 1)

        let port = PortData.parse(msg?.valueBytes)
        XCTAssertEqual(port?.voltage ?? 0, 20.1, accuracy: 0.0001)
        XCTAssertEqual(port?.current ?? 0, 2.5, accuracy: 0.0001)
        XCTAssertEqual(port?.power ?? 0, 50.2, accuracy: 0.0001)
    }

    func testWrongTokenFailsAtDeviceHmac() async throws {
        // 设备用真 token 算 HMAC，我方用错 token 派生密钥 → 设备 HMAC 校验必须失败
        let link = FakeDeviceLink(token: token)
        var badToken = token
        badToken[0] = 0xFF
        let session = try MibleSession(link: link, token: badToken)
        link.session = session

        do {
            try await session.authenticate()
            XCTFail("错误 token 应该失败")
        } catch let e as MibleError {
            if case .auth(let text) = e {
                XCTAssertTrue(text.contains("设备 HMAC 校验失败"), text)
            } else {
                XCTFail("错误类型：\(e)")
            }
        }
        XCTAssertFalse(session.authenticated)
    }

    func testBadTokenLengthRejected() {
        let link = FakeDeviceLink(token: token)
        XCTAssertThrowsError(try MibleSession(link: link, token: [1, 2, 3]))
    }

    func testSetAckReturnsImmediatelyWithoutOneSecondWait() async throws {
        let link = FakeDeviceLink(token: token)
        let session = try MibleSession(link: link, token: token)
        link.session = session

        try await session.authenticate()
        let start = Date()
        let ack = try await session.sendCommand(siid: 2, piid: 5, value: 3, timeout: 4.0)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNotNil(ack)
        XCTAssertEqual(ack?.isSetAck, true)
        XCTAssertLessThan(elapsed, 0.3)
    }

    func testGetIgnoresStaleSetAckAndWaitsForGetResult() async throws {
        let link = FakeDeviceLink(token: token)
        let session = try MibleSession(link: link, token: token)
        link.session = session

        try await session.authenticate()
        // 先跑一次 SET，再跑一次 GET，验证 GET 只认 op=0x03 且返回完整端口读数
        _ = try await session.sendCommand(siid: 2, piid: 1, value: 1, timeout: 2.0)
        let getMsg = try await session.sendCommand(siid: 2, piid: 1, timeout: 2.0)
        XCTAssertEqual(getMsg?.isGetResult, true)
        XCTAssertEqual(getMsg?.valueBytes.count, 4)
    }
}

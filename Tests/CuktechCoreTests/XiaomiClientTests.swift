import XCTest
import Foundation
@testable import CuktechCore

/// 假的 HTTP transport：把「网络」换成闭包，登录流程才好在单测里跑完整链路。
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) throws -> HTTPResponse
    private var handler: Handler
    private let lock = NSLock()
    private(set) var requests: [HTTPRequest] = []

    init(_ handler: @escaping Handler) { self.handler = handler }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        requests.append(request)
        let handler = self.handler
        lock.unlock()
        return try handler(request)
    }
}

/// 收集客户端日志。XiaomiClient 的 logger 是 @Sendable，闭包里不能直接改外面 var 数组。
final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ line: String) { lock.lock(); items.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

func json(_ body: String, status: Int = 200, cookies: [(name: String, value: String)] = []) -> HTTPResponse {
    HTTPResponse(status: status,
                 headers: ["content-type": "application/json"],
                 body: Data(body.utf8),
                 cookies: cookies)
}

func queryItems(_ url: URL) -> [String: String] {
    var out: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
        out[item.name] = item.value ?? ""
    }
    return out
}

final class XiaomiClientTests: XCTestCase {
    // 与 MiCryptoTests 同一套固定值
    let ssecurity = "A3sMGtnBOelO74Oh2kjAALhpCvJCKcWCaI3zUMmTW7g="

    // MARK: - JSON 小工具

    func testJSONValueParseAndSerialize() throws {
        let text = #"{"code":0,"result":{"homelist":[{"id":"h1","name":"家"}],"ok":true,"ratio":1.50}}"#
        let value = try JSONValue.parse(text)
        XCTAssertEqual(value["code"]?.intValue, 0)
        XCTAssertEqual(value["result"]?["ok"]?.boolValue, true)
        // 数字保留原始文本，"1.50" 不能变成 "1.5"
        XCTAssertEqual(value["result"]?["ratio"]?.flatString(), "1.50")
        XCTAssertEqual(value["result"]?["homelist"]?[0]?["name"]?.stringValue, "家")
    }

    func testJSONValueEscapes() throws {
        let value = try JSONValue.parse(#"{"a":"line\nbreak \"q\" \u4e2d"}"#)
        XCTAssertEqual(value["a"]?.stringValue, "line\nbreak \"q\" 中")
        // 序列化回去要能被再解析
        let again = try JSONValue.parse(value.rawText())
        XCTAssertEqual(again["a"]?.stringValue, "line\nbreak \"q\" 中")
    }

    func testParseFlatJsonStripsMarkers() {
        let fields = XiaomiClient.parseFlatJson(#"&&&START&&&{"qr":"https://a/b.png","lp":"https://a/poll","timeout":"180"}&&&END&&&"#)
        XCTAssertEqual(fields["qr"], "https://a/b.png")
        XCTAssertEqual(fields["lp"], "https://a/poll")
        XCTAssertEqual(fields["timeout"], "180")
    }

    func testParseFlatJsonToleratesGarbage() {
        XCTAssertTrue(XiaomiClient.parseFlatJson("not json").isEmpty)
        XCTAssertTrue(XiaomiClient.parseFlatJson("").isEmpty)
    }

    // MARK: - 请求构造

    func testQRRequestURLHasDoubleEncodedQs() {
        let url = XiaomiClient.buildQrRequestURL(millis: 1234567890)
        XCTAssertTrue(url.hasPrefix(XiaomiClient.loginEndpoint + "?"))
        XCTAssertTrue(url.contains("qs=%253Fsid%253Dxiaomiio%2526_json%253Dtrue"))
        XCTAssertTrue(url.contains("sid=xiaomiio"))
        XCTAssertTrue(url.contains("_qrsize=480"))
        XCTAssertTrue(url.contains("_dc=1234567890"))
        XCTAssertTrue(url.contains("_locale=en_GB"))
    }

    func testParseTTL() {
        XCTAssertEqual(XiaomiClient.parseTTL(nil), 300)
        XCTAssertEqual(XiaomiClient.parseTTL("180"), 180)
        XCTAssertEqual(XiaomiClient.parseTTL("180000"), 180)   // 毫秒
        XCTAssertEqual(XiaomiClient.parseTTL("10"), 30)        // 下夹
        XCTAssertEqual(XiaomiClient.parseTTL("9999"), 30)      // 9999ms = 10s，被下夹到 30
        XCTAssertEqual(XiaomiClient.parseTTL("180000"), 180)
        XCTAssertEqual(XiaomiClient.parseTTL("abc"), 300)
    }

    func testEscapeMatchesUriEscapeDataString() {
        XCTAssertEqual(XiaomiClient.escape("a b&c=d"), "a%20b%26c%3Dd")
        XCTAssertEqual(XiaomiClient.escape("abc-_.~"), "abc-_.~")
        XCTAssertEqual(XiaomiClient.escape("+"), "%2B")
    }

    // MARK: - 字段判定

    func testIsCuktechAndLooksBle() throws {
        let byHint = try JSONValue.parse(#"{"name":"酷态科10号Ultra","model":"njcuk.fitting.ad1204"}"#)
        XCTAssertTrue(XiaomiClient.isCuktech(byHint))
        XCTAssertTrue(XiaomiClient.looksBle(byHint) == false) // model 里没有 blt/ble

        let byPid = try JSONValue.parse(#"{"name":"charger","pid":"26126"}"#)
        XCTAssertTrue(XiaomiClient.isCuktech(byPid))

        let ble = try JSONValue.parse(#"{"name":"cuktech-ble-x","model":"ble"}"#)
        XCTAssertTrue(XiaomiClient.looksBle(ble))

        let other = try JSONValue.parse(#"{"name":"air purifier","model":"zhimi.airp.mb4a"}"#)
        XCTAssertFalse(XiaomiClient.isCuktech(other))
        XCTAssertFalse(XiaomiClient.looksBle(other))
    }

    func testParseFieldsPrefersKeyOfTwelveBytes() throws {
        // key 是 12 字节，beaconkey 是 24 字节 —— 必须挑 key
        let inner = try JSONValue.parse(#"{"beaconkey":"AES256KEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","key":"00112233445566778899aabb"}"#)
        let parsed = XiaomiClient.parseFields(inner)
        XCTAssertEqual(parsed.best, "00112233445566778899aabb")
        XCTAssertEqual(parsed.candidates.count, 2)
    }

    func testParseFieldsIgnoresNonStringValues() throws {
        let inner = try JSONValue.parse(#"{"key":"00112233445566778899aabb","count":3}"#)
        let parsed = XiaomiClient.parseFields(inner)
        XCTAssertEqual(parsed.candidates.count, 1)
        XCTAssertEqual(parsed.best, "00112233445566778899aabb")
    }

    func testHasValueAndIsCodeZero() throws {
        XCTAssertFalse(XiaomiClient.hasValue(nil))
        XCTAssertFalse(XiaomiClient.hasValue(""))
        XCTAssertFalse(XiaomiClient.hasValue("0"))
        XCTAssertFalse(XiaomiClient.hasValue("false"))
        XCTAssertTrue(XiaomiClient.hasValue("1"))
        XCTAssertTrue(XiaomiClient.isCodeZero(try JSONValue.parse(#"{"code":0}"#)))
        XCTAssertTrue(XiaomiClient.isCodeZero(try JSONValue.parse(#"{"code":"0"}"#)))
        XCTAssertFalse(XiaomiClient.isCodeZero(try JSONValue.parse(#"{"code":1}"#)))
    }

    // MARK: - 端到端（假网络）

    func testLoginThenListDevices() async throws {
        let ssecurity = self.ssecurity
        let transport = FakeTransport { request in
            let url = request.url
            let path = url.path

            // 1) 申请二维码
            if path == "/longPolling/loginUrl" {
                return json(#"{"qr":"https://qr.example/a.png","lp":"https://lp.example/poll","timeout":"180","loginUrl":"https://login.example/"}"#)
            }

            // 2) 下载二维码图
            if url.host == "qr.example" {
                return HTTPResponse(status: 200, headers: [:], body: Data([0x89, 0x50, 0x4E, 0x47]))
            }

            // 3) 长轮询：直接判「已扫码」
            if url.host == "lp.example" {
                return json(#"{"userId":"12345","ssecurity":"\#(ssecurity)","location":"https://login.example/loc"}"#)
            }

            // 4) location 跟随：第一次 302 带 serviceToken，第二次 200
            if url.host == "login.example" {
                if path == "/loc" {
                    return HTTPResponse(status: 302,
                                        headers: ["location": "https://login.example/done"],
                                        body: Data(),
                                        cookies: [(name: "serviceToken", value: "ST-123")])
                }
                return HTTPResponse(status: 200, headers: [:], body: Data("ok".utf8),
                                    cookies: [(name: "serviceToken", value: "ST-123")])
            }

            // 5) 云 API：用请求里的 nonce 加密假响应（与生产同一个签名/加密路径）
            let query = queryItems(url)
            guard let nonce = query["_nonce"],
                  let sn = MiCrypto.signedNonce(ssecurity: ssecurity, nonce: nonce) else {
                return json("{}", status: 400)
            }
            func encrypted(_ plain: String) -> HTTPResponse {
                let body = MiCrypto.encryptRC4(signedNonceB64: sn, payload: plain) ?? ""
                return HTTPResponse(status: 200, headers: [:], body: Data(body.utf8))
            }

            switch path {
            case "/app/v2/homeroom/gethome":
                return encrypted(#"{"code":0,"result":{"homelist":[{"id":"h1","name":"家","uid":"12345"}]}}"#)
            case "/app/v2/home/home_device_list":
                return encrypted(#"{"code":0,"result":{"device_info":[{"did":"d1","name":"酷态科 10 号 Ultra","model":"njcuk.fitting.ad1204","token":"00112233445566778899aabb","isOnline":true},{"did":"d2","name":"温湿度计","model":"miaomiaoce.sensor_ht.t2"}]}}"#)
            case "/app/v2/device/blt_get_beaconkey":
                return encrypted(#"{"code":0,"result":{"key":"aabbccddeeff001122334455"}}"#)
            default:
                return encrypted(#"{"code":-1}"#)
            }
        }

        let log = LogBox()
        let client = XiaomiClient(transport: transport, agent: "test-agent", deviceId: "testdevice000001") { line in
            log.append(line)
        }

        let ticket = try await client.requestQr()
        XCTAssertEqual(ticket.qrImageURL, "https://qr.example/a.png")
        XCTAssertEqual(ticket.pollURL, "https://lp.example/poll")
        XCTAssertEqual(ticket.ttl, 180)

        let image = try await client.downloadQrImage(ticket)
        XCTAssertEqual(image.first, 0x89)

        let login = try await client.waitForScan(ticket)
        XCTAssertEqual(login.userId, "12345")
        XCTAssertEqual(login.serviceToken, "ST-123")
        let loggedIn = await client.isLoggedIn
        XCTAssertTrue(loggedIn)

        let devices = try await client.devices()
        XCTAssertEqual(devices.count, 2)
        // 酷态科排前面，且已经有 token
        XCTAssertEqual(devices.first?.did, "d1")
        XCTAssertEqual(devices.first?.tokenHex, "00112233445566778899aabb")
        XCTAssertTrue(devices.first!.isCuktech)
        // 第二台不是酷态科也不像 BLE，不该去问 beaconkey
        XCTAssertNil(devices.last?.tokenHex)
        XCTAssertFalse(log.lines.isEmpty)
    }

    func testBeaconKeyPathForBleCandidateWithoutListedToken() async throws {
        let ssecurity = self.ssecurity
        let transport = FakeTransport { request in
            let url = request.url
            if url.path == "/longPolling/loginUrl" {
                return json(#"{"qr":"https://qr.example/a.png","lp":"https://lp.example/poll","timeout":"180"}"#)
            }
            if url.host == "lp.example" {
                return json(#"{"userId":"1","ssecurity":"\#(ssecurity)","location":"https://login.example/loc"}"#)
            }
            if url.host == "login.example" {
                return HTTPResponse(status: 200, headers: [:], body: Data(),
                                    cookies: [(name: "serviceToken", value: "ST-1")])
            }
            let query = queryItems(url)
            guard let nonce = query["_nonce"],
                  let sn = MiCrypto.signedNonce(ssecurity: ssecurity, nonce: nonce) else {
                return json("{}", status: 400)
            }
            func encrypted(_ plain: String) -> HTTPResponse {
                HTTPResponse(status: 200, headers: [:],
                             body: Data((MiCrypto.encryptRC4(signedNonceB64: sn, payload: plain) ?? "").utf8))
            }
            switch url.path {
            case "/app/v2/homeroom/gethome":
                return encrypted(#"{"code":0,"result":{"homelist":[{"id":"h1","name":"家","uid":"1"}]}}"#)
            case "/app/v2/home/home_device_list":
                // 列表里没有 token，但名字带 cuktech → 应该去问 blt_get_beaconkey
                return encrypted(#"{"code":0,"result":{"list":[{"did":"d9","name":"cuktech-ble-ad1204","model":"ble.mesh"}]}}"#)
            case "/app/v2/device/blt_get_beaconkey":
                return encrypted(#"{"code":0,"result":{"key":"00112233445566778899aabb"}}"#)
            default:
                return encrypted(#"{"code":-1}"#)
            }
        }

        let client = XiaomiClient(transport: transport, agent: "test-agent", deviceId: "testdevice000001")
        let ticket = try await client.requestQr()
        _ = try await client.waitForScan(ticket)
        let devices = try await client.devices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.tokenHex, "00112233445566778899aabb")
        XCTAssertEqual(devices.first?.tokenSource, "blt_get_beaconkey")
    }

    func testExpiredQrThrows() async throws {
        let transport = FakeTransport { request in
            if request.url.path == "/longPolling/loginUrl" {
                return json(#"{"qr":"https://qr.example/a.png","lp":"https://lp.example/poll","timeout":"180"}"#)
            }
            return json("nope", status: 404)
        }
        let client = XiaomiClient(transport: transport, agent: "a", deviceId: "b")
        let ticket = try await client.requestQr()
        do {
            _ = try await client.waitForScan(ticket)
            XCTFail("应该抛 qrExpired")
        } catch let error as XiaomiError {
            XCTAssertEqual(error, .qrExpired)
        }
    }

    func testSessionRoundTrip() async throws {
        let ssecurity = self.ssecurity
        let transport = FakeTransport { request in
            let url = request.url
            switch url.path {
            case "/longPolling/loginUrl":
                return json(#"{"qr":"https://qr.example/a.png","lp":"https://lp.example/poll","timeout":"180"}"#)
            case "/poll":
                return json(#"{"userId":"12345","ssecurity":"\#(ssecurity)","location":"https://login.example/loc"}"#)
            case "/loc":
                return HTTPResponse(status: 200, headers: [:], body: Data(),
                                    cookies: [(name: "serviceToken", value: "ST-9")])
            default:
                return json("{}", status: 404)
            }
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cuktech-session-test")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("session.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = XiaomiClient(transport: transport, agent: "a", deviceId: "b")
        let ticket = try await client.requestQr()
        _ = try await client.waitForScan(ticket)
        try await client.saveSession(to: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let reloaded = XiaomiClient(transport: transport, agent: "a", deviceId: "b")
        try await reloaded.loadSession(from: file)
        let userId = await reloaded.userId
        let token = await reloaded.serviceToken
        let session = await reloaded.ssecurity
        let loggedIn = await reloaded.isLoggedIn
        XCTAssertEqual(userId, "12345")
        XCTAssertEqual(token, "ST-9")
        XCTAssertEqual(session, ssecurity)
        XCTAssertTrue(loggedIn)
    }
}

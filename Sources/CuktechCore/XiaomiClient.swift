import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - 公开的模型

/// 一次扫码申请到的凭据。qrImageURL 是图片地址，pollURL 是长轮询地址。
public struct QrTicket: Sendable, Equatable {
    public let qrImageURL: String
    public let pollURL: String
    public let loginURL: String?
    public var ttl: TimeInterval

    public init(qrImageURL: String, pollURL: String, loginURL: String?, ttl: TimeInterval) {
        self.qrImageURL = qrImageURL
        self.pollURL = pollURL
        self.loginURL = loginURL
        self.ttl = ttl
    }
}

/// 扫码成功后拿到的会话凭据。serviceToken 属敏感信息，日志里不打印。
public struct LoginResult: Sendable, Equatable {
    public let userId: String
    public let ssecurity: String
    public let serviceToken: String
    public let region: String?

    public init(userId: String, ssecurity: String, serviceToken: String, region: String?) {
        self.userId = userId
        self.ssecurity = ssecurity
        self.serviceToken = serviceToken
        self.region = region
    }
}

/// 米家里的一台设备。tokenHex 是蓝牙认证要用的 12 字节密钥（24 位 hex）。
public struct MiDevice: Sendable, Equatable, Identifiable {
    public let did: String
    public let name: String
    public let model: String
    public let mac: String
    public let tokenHex: String?
    public let tokenSource: String
    public let isCuktech: Bool
    public let isOnline: Bool

    public init(did: String, name: String, model: String, mac: String,
                tokenHex: String?, tokenSource: String, isCuktech: Bool, isOnline: Bool) {
        self.did = did
        self.name = name
        self.model = model
        self.mac = mac
        self.tokenHex = tokenHex
        self.tokenSource = tokenSource
        self.isCuktech = isCuktech
        self.isOnline = isOnline
    }

    public var id: String { did }
    /// 12 字节 = 24 位 hex，长度不对的一律当没拿到。
    public var hasToken: Bool { tokenHex?.count == 24 }
    public var summary: String {
        var parts: [String] = []
        if !model.isEmpty { parts.append(model) }
        if !did.isEmpty { parts.append(did) }
        if isCuktech { parts.append("酷态科") }
        return parts.joined(separator: " · ")
    }
}

public enum XiaomiError: Error, CustomStringConvertible, Equatable {
    case network(String)
    case http(Int)
    case badResponse(String)
    case api(String)
    case qrExpired
    case login(String)

    public var description: String {
        switch self {
        case .network(let s): return "网络错误: \(s)"
        case .http(let code): return "HTTP \(code)"
        case .badResponse(let s): return "响应异常: \(s)"
        case .api(let s): return "云接口失败: \(s)"
        case .qrExpired: return "二维码已过期，请刷新"
        case .login(let s): return "登录失败: \(s)"
        }
    }
}

// MARK: - 客户端

/// 小米云账号客户端：扫码登录 -> 换 serviceToken -> 列设备 -> 取蓝牙 beaconkey。
///
/// 逐行对照 Windows 版 src/CuktechLogin/XiaomiClient.cs。跨平台（Linux 上也能跑单测），
/// 所以不用 URLSession 的 cookie 容器，而是自己维护一个 cookie 表 —— 登录流程里
/// serviceToken 是靠逐跳读 Set-Cookie 拿到的，交给系统管反而看不清。
public actor XiaomiClient {
    // MARK: 常量

    public static let targetProductID = 26126          // 0x660E = 酷态科 10 号 Ultra
    public static let regionOrder = ["cn", "de", "us", "ru", "tw", "sg", "in", "i2"]
    public static let loginEndpoint = "https://account.xiaomi.com/longPolling/loginUrl"

    /// 区域 -> API 根地址。cn 走 api.io.mi.com，其它走 <region>.api.io.mi.com。
    public static func serverURL(_ region: String) -> String {
        region == "cn" ? "https://api.io.mi.com/app" : "https://\(region).api.io.mi.com/app"
    }

    static let cuktechHints = ["cuktech", "酷态科"]
    static let bleHints = ["blt", "ble", "mesh", "bluetooth"]

    /// gethome 的固定 payload（字段顺序与空格照抄参考实现，避免服务端挑食）。
    static let homeRoomData = #"{"fg": true, "fetch_share": true, "fetch_share_dev": true, "limit": 300, "app_ver": 7}"#

    // MARK: 状态

    public private(set) var userId: String?
    public private(set) var ssecurity: String?
    public private(set) var serviceToken: String?
    public private(set) var server: String?
    public private(set) var lastError: String?

    /// location 只用于当次换 serviceToken，不落盘（与 Windows 版一致）。
    private var location: String?
    private var cookies: [String: String] = [:]

    private let transport: HTTPTransport
    private let agent: String
    private let deviceId: String
    private let logger: @Sendable (String) -> Void

    public init(
        transport: HTTPTransport = URLSessionTransport(),
        agent: String = MiCrypto.generateAgent(),
        deviceId: String = MiCrypto.generateDeviceId(),
        logger: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.transport = transport
        self.agent = agent
        self.deviceId = deviceId
        self.logger = logger
    }

    public var isLoggedIn: Bool {
        Self.hasValue(userId) && Self.hasValue(ssecurity) && Self.hasValue(serviceToken)
    }

    private func log(_ text: String) {
        logger("[mi] " + text)
    }

    // MARK: - HTTP 底座

    private func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as XiaomiError {
            throw error
        } catch {
            throw XiaomiError.network(String(describing: error))
        }

        for cookie in response.cookies where !cookie.value.isEmpty {
            cookies[cookie.name] = cookie.value
        }
        return response
    }

    private func cookie(_ name: String) -> String? {
        if let value = cookies[name], !value.isEmpty { return value }
        return nil
    }

    /// Cookie 头，顺序照抄参考实现的 requests.Session。
    private func cookieHeader() -> String {
        let uid = userId ?? ""
        let token = serviceToken ?? ""
        return "userId=\(uid); yetAnotherServiceToken=\(token); serviceToken=\(token); "
            + "locale=en_GB; timezone=GMT+08:00; is_daylight=0; dst_offset=0; channel=MI_APP_STORE"
    }

    static func escape(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - 第一步：申请二维码

    /// 申请扫码登录二维码的 URL（qs 的值在线上是双编码，这里照抄，否则服务端拿不到 sid）。
    public static func buildQrRequestURL(millis: Int64) -> String {
        var url = loginEndpoint
        func append(_ name: String, _ value: String) {
            url += (url.contains("?") ? "&" : "?") + escape(name) + "=" + escape(value)
        }
        append("_qrsize", "480")
        append("qs", "%3Fsid%3Dxiaomiio%26_json%3Dtrue")
        append("callback", "https://sts.api.io.mi.com/sts")
        append("_hasLogo", "false")
        append("sid", "xiaomiio")
        append("serviceParam", "")
        append("_locale", "en_GB")
        append("_dc", String(millis))
        return url
    }

    public func requestQr() async throws -> QrTicket {
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        let text = Self.buildQrRequestURL(millis: millis)
        guard let url = URL(string: text) else { throw XiaomiError.badResponse("二维码 URL 非法") }
        log("申请二维码: GET \(text)")
        let response = try await send(HTTPRequest(url: url, timeout: 30))
        guard response.status == 200 else { throw XiaomiError.http(response.status) }

        let body = String(decoding: response.body, as: UTF8.self)
        let fields = Self.parseFlatJson(body)
        guard let qr = fields["qr"], !qr.isEmpty, let lp = fields["lp"], !lp.isEmpty else {
            throw XiaomiError.badResponse("响应缺少 qr/lp: " + Self.truncate(body, 300))
        }
        let ttl = Self.parseTTL(fields["timeout"])
        log("二维码已申请: 有效期 \(Int(ttl))s, 响应字段 [\(fields.keys.sorted().joined(separator: ", "))]")
        return QrTicket(qrImageURL: qr, pollURL: lp, loginURL: fields["loginUrl"], ttl: ttl)
    }

    /// timeout 归一化：>1000 当毫秒，夹到 30..300 秒。
    static func parseTTL(_ raw: String?) -> TimeInterval {
        var seconds = 300.0
        if let raw, let parsed = Double(raw.trimmingCharacters(in: .whitespaces)), parsed > 0 {
            seconds = parsed
        }
        if seconds > 1000 { seconds /= 1000 }
        return min(300, max(30, seconds))
    }

    // MARK: - 二维码图片

    public func downloadQrImage(_ ticket: QrTicket) async throws -> Data {
        guard let url = URL(string: ticket.qrImageURL) else {
            throw XiaomiError.badResponse("二维码图片 URL 非法")
        }
        let response = try await send(HTTPRequest(url: url, timeout: 30))
        guard response.status == 200 else { throw XiaomiError.http(response.status) }
        guard !response.body.isEmpty else { throw XiaomiError.badResponse("二维码图片为空") }
        log("二维码已下载: \(response.body.count) 字节")
        return response.body
    }

    // MARK: - 第二步：长轮询 + 换 serviceToken

    /// 等到有人扫码。pending 间隔 1s，网络错误间隔 2s，HTTP 非 200 视为二维码过期。
    public func waitForScan(_ ticket: QrTicket) async throws -> LoginResult {
        let deadline = Date().addingTimeInterval(ticket.ttl)
        log("二维码生效中 (有效期 \(Int(ticket.ttl))s)，等待扫码…")

        while Date() < deadline {
            try Task.checkCancellation()
            guard let url = URL(string: ticket.pollURL) else {
                throw XiaomiError.badResponse("轮询 URL 非法")
            }

            let response: HTTPResponse
            do {
                response = try await send(HTTPRequest(url: url, timeout: 40))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log("轮询网络错误: \(error)")
                try await Self.sleep(2)
                continue
            }

            if response.status != 200 {
                log("轮询返回 HTTP \(response.status)，视为二维码过期")
                throw XiaomiError.qrExpired
            }

            let fields = Self.parseFlatJson(String(decoding: response.body, as: UTF8.self))
            if Self.hasValue(fields["ssecurity"]) || Self.hasValue(fields["userId"]) {
                log("扫码成功!")
                return try await finishLogin(fields)
            }
            if let code = fields["code"], Self.hasValue(code) {
                log("轮询响应 code=\(code)（继续等待）")
            }
            try await Self.sleep(1)
        }

        log("等待扫码超时（二维码已过期）")
        throw XiaomiError.qrExpired
    }

    private func finishLogin(_ fields: [String: String]) async throws -> LoginResult {
        guard let uid = fields["userId"], !uid.isEmpty else {
            throw XiaomiError.login("扫码结果缺少 userId")
        }
        guard let ssec = fields["ssecurity"], !ssec.isEmpty else {
            throw XiaomiError.login("扫码结果缺少 ssecurity")
        }
        userId = uid
        ssecurity = ssec
        serviceToken = nil

        let loc = fields["location"] ?? ""
        location = loc.isEmpty ? nil : loc
        if !loc.isEmpty {
            do {
                let result = try await followLocation(loc)
                log("location 跟随完成: HTTP \(result.status)")
                if !result.token.isEmpty { serviceToken = result.token }
            } catch {
                log("location 跟随失败: \(error)")
            }
        } else {
            log("扫码结果无 location，直接使用已有 cookie")
        }

        if serviceToken == nil { serviceToken = cookie("serviceToken") }
        if serviceToken == nil { serviceToken = cookie("yetAnotherServiceToken") }
        guard let token = serviceToken, !token.isEmpty else {
            throw XiaomiError.login("无法获取 serviceToken（cookie 中不存在）")
        }

        log("已拿到 serviceToken (userId=\(uid))")
        return LoginResult(userId: uid, ssecurity: ssec, serviceToken: token, region: server)
    }

    /// 手工跟 302（最多 10 跳）。每跳的 Set-Cookie 都记进 cookies 表，
    /// 但 serviceToken 只认最后一跳（与 Windows 版行为一致）。
    private func followLocation(_ start: String) async throws -> (status: Int, token: String) {
        var current = start
        var status = 0
        for _ in 0..<10 {
            guard let url = URL(string: current) else { throw XiaomiError.badResponse("location 非法") }
            var request = HTTPRequest(url: url, timeout: 30)
            request.headers["User-Agent"] = agent
            request.headers["Content-Type"] = "application/x-www-form-urlencoded"
            let response = try await send(request)
            status = response.status

            if (300..<400).contains(response.status), let next = response.location, !next.isEmpty {
                if let resolved = URL(string: next, relativeTo: url)?.absoluteString {
                    current = resolved
                } else {
                    current = next
                }
                continue
            }

            return (status, response.cookie("serviceToken") ?? "")
        }

        log("location 重定向次数过多 (>10)")
        return (429, "")
    }

    // MARK: - 第三步：云 API

    /// 调一次加密云接口，返回解密后的 JSON。失败抛 XiaomiError（不返回半截数据）。
    public func callApi(region: String, path: String, dataJson: String) async throws -> JSONValue {
        guard let ssecurity, !ssecurity.isEmpty else {
            throw XiaomiError.api("未登录（ssecurity 缺失）")
        }

        let base = Self.serverURL(region) + path
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        let nonce = MiCrypto.generateNonce(millis: millis)
        guard let sn = MiCrypto.signedNonce(ssecurity: ssecurity, nonce: nonce) else {
            throw XiaomiError.api("signedNonce 计算失败")
        }

        let fields = MiCrypto.generateEncParams(
            url: base, method: "POST", sn: sn, nonce: nonce,
            params: [("data", dataJson)], ssecurity: ssecurity)
        let query = fields.map { Self.escape($0.0) + "=" + Self.escape($0.1) }.joined(separator: "&")

        guard let url = URL(string: base + "?" + query) else {
            throw XiaomiError.badResponse("请求 URL 非法")
        }

        var request = HTTPRequest(url: url, method: "POST", body: Data(), timeout: 40)
        request.headers = [
            "Accept-Encoding": "identity",
            "User-Agent": agent,
            // 小米自己拼错的 protocal，照抄，别改
            "x-xiaomi-protocal-flag-cli": "PROTOCAL-HTTP2",
            "MIOT-ENCRYPT-ALGORITHM": "ENCRYPT-RC4",
            "Cookie": cookieHeader(),
            "Content-Type": "application/x-www-form-urlencoded",
        ]

        let response = try await send(request)
        let apiName = path.split(separator: "/").last.map(String.init) ?? path
        guard response.status == 200 else {
            log("API \(apiName) -> HTTP \(response.status)")
            throw XiaomiError.http(response.status)
        }

        let bodyText = String(decoding: response.body, as: UTF8.self)
        guard let decoded = MiCrypto.decryptRC4(signedNonceB64: sn, payloadB64: bodyText) else {
            log("API \(apiName) 响应解密失败")
            throw XiaomiError.api("响应解密失败")
        }
        guard let json = JSONValue.parseOrNil(decoded) else {
            log("API \(apiName) 返回非 JSON: " + Self.truncate(decoded, 200))
            throw XiaomiError.api("返回非 JSON")
        }
        return json
    }

    // MARK: - 第四步：区域探测 + 设备列表

    public func devices() async throws -> [MiDevice] {
        guard let ssecurity, !ssecurity.isEmpty else {
            throw XiaomiError.login("未登录（ssecurity 缺失）")
        }
        _ = ssecurity

        if serviceToken == nil {
            guard let loc = location else {
                throw XiaomiError.login("serviceToken 缺失且无 location，请重新扫码")
            }
            let result = try await followLocation(loc)
            log("serviceToken 缺失，重新跟随 location: HTTP \(result.status)")
            serviceToken = result.token.isEmpty ? (cookie("serviceToken") ?? cookie("yetAnotherServiceToken")) : result.token
            guard Self.hasValue(serviceToken) else { throw XiaomiError.login("无法获取 serviceToken") }
        }

        guard let picked = try await pickRegion() else {
            throw XiaomiError.api("所有区域 gethome 均失败，无法列出设备")
        }
        let raws = try await collectDevices(region: picked.region, homes: picked.homes)
        log("总计拉取到 \(raws.count) 台设备")

        let priority = raws.filter { $0.isCuktech || $0.looksBle }
        let rest = raws.filter { !$0.isCuktech && !$0.looksBle }
        log("优先探测 \(priority.count) 台（酷态科/BLE 候选），其余 \(rest.count) 台随后补全")

        var result: [MiDevice] = []
        for raw in priority + rest {
            result.append(await buildDevice(raw, region: picked.region))
        }

        return result.sorted { a, b in
            if a.isCuktech != b.isCuktech { return a.isCuktech }
            if a.hasToken != b.hasToken { return a.hasToken }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func pickRegion() async throws -> (region: String, homes: JSONValue)? {
        for region in Self.regionOrder {
            do {
                let homes = try await callApi(region: region, path: "/v2/homeroom/gethome", dataJson: Self.homeRoomData)
                if Self.isCodeZero(homes) {
                    server = region
                    log("使用区域: \(region)")
                    return (region, homes)
                }
                log("区域 \(region) 不可用: " + Self.truncate(homes.rawText(), 160))
            } catch {
                log("区域 \(region) 不可用: \(error)")
            }
        }
        return nil
    }

    private struct RawDevice {
        let dev: JSONValue
        let did: String
        let isCuktech: Bool
        let looksBle: Bool
    }

    private func collectDevices(region: String, homes: JSONValue) async throws -> [RawDevice] {
        var out: [RawDevice] = []
        var seen = Set<String>()
        let homeList = homes["result"]?["homelist"]?.arrayValue ?? []
        log("家庭数量: \(homeList.count)")

        for home in homeList {
            let homeId = home["id"]?.flatString() ?? ""
            let homeName = home["name"]?.flatString() ?? ""
            let owner = home["uid"]?.flatString() ?? ""

            let payload = "{\"home_owner\": " + JSONValue.token(Self.hasValue(owner) ? owner : (userId ?? ""))
                + ", \"home_id\": " + (home["id"]?.rawText() ?? "null")
                + ", \"limit\": 200, \"get_split_device\": true, \"support_smart_home\": true}"

            let response: JSONValue
            do {
                response = try await callApi(region: region, path: "/v2/home/home_device_list", dataJson: payload)
            } catch {
                log("home_device_list 失败 home=\(homeId): \(error)")
                continue
            }
            guard Self.isCodeZero(response) else {
                log("home_device_list 失败 home=\(homeId): " + Self.truncate(response.rawText(), 200))
                continue
            }

            let list = Self.extractDeviceList(response)
            log("家庭 \(homeId) (\(homeName)): \(list.count) 台设备")

            for dev in list {
                let did = dev["did"]?.flatString() ?? ""
                if !did.isEmpty && !seen.insert(did).inserted { continue }
                out.append(RawDevice(dev: dev, did: did, isCuktech: Self.isCuktech(dev), looksBle: Self.looksBle(dev)))
            }
        }
        return out
    }

    private func buildDevice(_ raw: RawDevice, region: String) async -> MiDevice {
        let name = raw.dev["name"]?.flatString() ?? ""
        let model = raw.dev["model"]?.flatString() ?? ""

        var tokenHex: String?
        var source = ""
        if let listed = MiCrypto.keyToHex(raw.dev["token"]?.stringValue), listed.count == 24 {
            tokenHex = listed
            source = "device_list_token"
        } else if raw.isCuktech || raw.looksBle {
            if let fetched = (try? await fetchBeaconKeyToken(region: region, did: raw.did)) ?? nil, fetched.count == 24 {
                let best = fetched
                tokenHex = best
                source = "blt_get_beaconkey"
            }
        }

        let online = raw.dev["isOnline"]?.boolValue ?? false
        if tokenHex != nil {
            log("token OK: \(name) | \(model) | \(raw.did) -> 12 字节（来源=\(source)）")
        } else {
            log("token 无: \(name) | \(model) | \(raw.did)")
        }

        return MiDevice(
            did: raw.did,
            name: name,
            model: model,
            mac: raw.dev["mac"]?.flatString() ?? "",
            tokenHex: tokenHex,
            tokenSource: source,
            isCuktech: raw.isCuktech,
            isOnline: online
        )
    }

    /// blt_get_beaconkey 只认 12 字节（24 位 hex）的字段 —— 该接口自带的 beaconkey 是 24 字节，
    /// 只能解 MiBeacon 广播，当不了认证 token。
    public func fetchBeaconKeyToken(region: String, did: String) async throws -> String? {
        let payload = "{\"did\": " + JSONValue.token(did) + ", \"pdid\": 1}"
        let response = try await callApi(region: region, path: "/v2/device/blt_get_beaconkey", dataJson: payload)
        guard Self.isCodeZero(response) else {
            log("blt_get_beaconkey code=\(response["code"]?.flatString() ?? "") [\(did)]")
            return nil
        }
        guard let inner = response["result"], inner.isObject else {
            log("blt_get_beaconkey 返回无 result [\(did)]")
            return nil
        }
        let parsed = Self.parseFields(inner)
        let summary = parsed.candidates.map { "\($0.0):\($0.2)B" }.joined(separator: ", ")
        log("blt_get_beaconkey [\(did)] 字段: " + (summary.isEmpty ? "无" : summary))
        return parsed.best
    }

    // MARK: - 会话持久化

    /// 存 userId/ssecurity/serviceToken/server（都是敏感内容，别进 git）。
    public func saveSession(to url: URL) throws {
        var object: [String: Any] = [
            "ssecurity": ssecurity ?? "",
            "service_token": serviceToken ?? "",
            "server": server ?? "",
            "saved_at": ISO8601DateFormatter().string(from: Date()),
        ]
        if let uid = userId, let number = Int64(uid) {
            object["user_id"] = number
        } else {
            object["user_id"] = userId ?? ""
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
        log("登录会话已保存（下次可直接复用，免扫码）")
    }

    public func loadSession(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XiaomiError.login("会话文件不是 JSON 对象")
        }
        userId = Self.firstNonEmpty(object, ["user_id", "userId"])
        ssecurity = Self.firstNonEmpty(object, ["ssecurity", "sessionId"])
        serviceToken = Self.firstNonEmpty(object, ["service_token", "serviceToken"])
        if let region = Self.firstNonEmpty(object, ["server", "region"]), Self.regionOrder.contains(region) {
            server = region
        }
        // location 是扫码当次的下发地址，不落盘
        location = nil
        log("复用已保存会话: \(isLoggedIn ? "是" : "否") (userId=\(userId ?? "-"), server=\(server ?? "-"))")
    }

    static func firstNonEmpty(_ object: [String: Any], _ names: [String]) -> String? {
        for name in names {
            if let value = object[name] {
                if let text = value as? String, !text.isEmpty { return text }
                if let number = value as? NSNumber { return number.stringValue }
            }
        }
        return nil
    }
}

// MARK: - 解析小工具（全部静态，方便单测）

extension XiaomiClient {
    /// 去掉 &&&START&&& / &&&END&&& 再解析成 字段 -> 字符串。
    static func parseFlatJson(_ text: String) -> [String: String] {
        let clean = text
            .replacingOccurrences(of: "&&&START&&&", with: "")
            .replacingOccurrences(of: "&&&END&&&", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let json = JSONValue.parseOrNil(clean), let object = json.objectValue else {
            return [:]
        }
        var out: [String: String] = [:]
        for (key, value) in object { out[key] = value.flatString() }
        return out
    }

    static func hasValue(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return value != "0" && value != "false"
    }

    static func isCodeZero(_ value: JSONValue) -> Bool {
        value["code"]?.intValue == 0
    }

    static func extractDeviceList(_ response: JSONValue) -> [JSONValue] {
        guard let result = response["result"] else { return [] }
        if let list = result["device_info"]?.arrayValue { return list }
        if let list = result["list"]?.arrayValue { return list }
        return []
    }

    static func isCuktech(_ dev: JSONValue) -> Bool {
        let hay = ["model", "name", "did", "extra"]
            .map { dev[$0]?.flatString() ?? "" }
            .joined(separator: " ")
            .lowercased()
        if cuktechHints.contains(where: { hay.contains($0) }) { return true }
        for key in ["pid", "productId", "product_id"] {
            if dev[key]?.flatString() == String(targetProductID) { return true }
        }
        return false
    }

    static func looksBle(_ dev: JSONValue) -> Bool {
        let hay = ["model", "name", "extra"]
            .map { dev[$0]?.flatString() ?? "" }
            .joined(separator: " ")
            .lowercased()
        return bleHints.contains { hay.contains($0) }
    }

    /// 字段名 -> (hex, 字节数)：只认字符串值，按 key > token > ble_key > beaconkey 挑 12 字节那个。
    static func parseFields(_ inner: JSONValue) -> (candidates: [(String, String, Int)], best: String?) {
        guard let object = inner.objectValue else { return ([], nil) }
        var candidates: [(String, String, Int)] = []
        for (name, value) in object {
            guard let raw = value.stringValue, let hex = MiCrypto.keyToHex(raw) else { continue }
            candidates.append((name, hex, hex.count / 2))
        }
        for prefer in ["key", "token", "ble_key", "beaconkey"] {
            if let hit = candidates.first(where: { $0.0 == prefer && $0.2 == 12 }) {
                return (candidates, hit.1)
            }
        }
        if let hit = candidates.first(where: { $0.2 == 12 }) {
            return (candidates, hit.1)
        }
        return (candidates, candidates.first?.1)
    }

    static func truncate(_ text: String, _ max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max)) + "…"
    }

    static func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

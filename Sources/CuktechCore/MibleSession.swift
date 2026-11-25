import Foundation

public enum MibleError: Error, CustomStringConvertible, Sendable {
    case badToken
    case notAuthenticated
    case auth(String)
    case timeout(String)
    case io(String)

    public var description: String {
        switch self {
        case .badToken: return "token 必须是 12 字节"
        case .notAuthenticated: return "尚未认证"
        case .auth(let s): return s
        case .timeout(let s): return "超时：\(s)"
        case .io(let s): return "传输层错误：\(s)"
        }
    }
}

/// 每个通道一个通知队列。使用 CheckedContinuation 实现零轮询异步唤醒，
/// 收到 BLE 通知时立刻恢复等待方，没有定时器空转。
final class NotifyQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[UInt8]] = []
    private var waiter: (token: UUID, cont: CheckedContinuation<[UInt8]?, Never>)?

    func push(_ data: [UInt8]) {
        lock.lock()
        if let active = waiter {
            waiter = nil
            lock.unlock()
            active.cont.resume(returning: data)
            return
        }
        items.append(data)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        items.removeAll()
        lock.unlock()
    }

    func size() -> Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
    }

    private func pop() -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        if items.isEmpty { return nil }
        return items.removeFirst()
    }

    func read(timeout: TimeInterval) async -> [UInt8]? {
        if let immediate = pop() { return immediate }
        if timeout <= 0 { return nil }

        let token = UUID()
        return await withCheckedContinuation { (cont: CheckedContinuation<[UInt8]?, Never>) in
            lock.lock()
            if !items.isEmpty {
                let d = items.removeFirst()
                lock.unlock()
                cont.resume(returning: d)
                return
            }
            // 若存在异常残留的旧等待者，先用 nil 结束它避免挂死
            let stale = waiter
            waiter = (token, cont)
            lock.unlock()
            stale?.cont.resume(returning: nil)

            let nanos = UInt64(max(0, timeout) * 1_000_000_000)
            Task.detached { [weak self] in
                try? await Task.sleep(nanoseconds: nanos)
                self?.cancelWaiter(token: token)
            }
        }
    }

    private func cancelWaiter(token: UUID) {
        lock.lock()
        guard let active = waiter, active.token == token else {
            lock.unlock()
            return
        }
        waiter = nil
        lock.unlock()
        active.cont.resume(returning: nil)
    }

    deinit {
        lock.lock()
        let active = waiter
        waiter = nil
        lock.unlock()
        active?.cont.resume(returning: nil)
    }
}

/// 轻量异步互斥锁：保证同一个 MibleSession 上同时只有一条 BLE 命令事务在执行，
/// 防止后台轮询与用户手动切模式/开关交错抢占 cmdSend/cmdRecv 与加密计数器。
final class AsyncCommandMutex: @unchecked Sendable {
    private let lock = NSLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        let mustWait: Bool = lock.withLock {
            if !locked {
                locked = true
                return false
            }
            return true
        }
        if !mustWait { return }

        await withCheckedContinuation { cont in
            lock.lock()
            if !locked {
                locked = true
                lock.unlock()
                cont.resume()
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            locked = false
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}

/// 小米 MIoT BLE (mible) 会话：认证握手 + AES-128-CCM 加密帧 + MiOT TLV 命令。
public final class MibleSession: @unchecked Sendable {
    private static let cmdLogin: [UInt8]     = [0x24, 0x00, 0x00, 0x00]
    private static let cmdSendKey: [UInt8]   = [0x00, 0x00, 0x00, 0x0B, 0x01, 0x00]
    private static let cmdSendInfo: [UInt8]  = [0x00, 0x00, 0x00, 0x0A, 0x01, 0x00]
    private static let cmdClear: [UInt8]     = [0x00, 0x00, 0x00, 0x00, 0x01, 0x00]
    private static let rcvRdy: [UInt8]       = [0x00, 0x00, 0x01, 0x01]
    private static let rcvOk: [UInt8]        = [0x00, 0x00, 0x01, 0x00]
    private static let keepAlive: [UInt8]    = [0x00, 0x00, 0x03, 0x00]
    private static let hkdfInfo: String      = "mible-login-info"
    private static let maxFrames = 100

    private let link: MibleLink
    private let token: [UInt8]
    private let commandMutex = AsyncCommandMutex()
    private var queues: [MibleChannel: NotifyQueue] = [:]

    private var devKey: [UInt8] = []
    private var appKey: [UInt8] = []
    private var devIv: [UInt8] = []
    private var appIv: [UInt8] = []

    private var sendIt: UInt32 = 0
    private var devItHi: UInt32 = 0
    private var lastDevItLo: UInt16 = 0
    private var miotSeq: UInt8 = 1

    public private(set) var authenticated = false
    public var trace: ((String) -> Void)?
    public var onPush: ((MiotMessage) -> Void)?

    public init(link: MibleLink, token: [UInt8]) throws {
        guard token.count == 12 else { throw MibleError.badToken }
        self.link = link
        self.token = token
        for ch in MibleChannel.allCases { queues[ch] = NotifyQueue() }
    }

    public var appKeyHex: String { appKey.hexString }
    public var devIvHex: String { devIv.hexString }

    /// 传输层收到通知后调用本方法。
    public func handleNotification(_ channel: MibleChannel, _ data: [UInt8]) {
        queues[channel]?.push(data)
    }

    // MARK: - 认证

    public func authenticate() async throws {
        authenticated = false
        let started = Date()
        func t(_ s: String) {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            trace?(String(format: "[%5dms] ", ms) + s)
        }

        try await link.subscribe(.cmdRecv)
        try await link.subscribe(.cmdSend)
        try await link.subscribe(.deviceInfo)
        try await link.subscribe(.authData)
        queues[.authData]?.clear()

        // ---- Phase A：设备初始化 (0xA4) ----
        t("订阅完成，发 0xA4")
        try await link.write(.authCtrl, [0xA4])
        guard var initResp = await read(.authData, 3.0) else {
            throw MibleError.auth("未收到初始化响应 (0xA4)")
        }

        if initResp.count >= 3 { initResp[2] = initResp[2] &+ 1 }
        try await link.write(.authData, initResp)

        guard var keyData = await read(.authData, 5.0) else {
            throw MibleError.auth("未收到密钥交换数据")
        }

        if keyData.count < 20 && keyData.count >= 3 && keyData[2] == 0x04 {
            let deadline = Date().addingTimeInterval(12)
            var recovered = false
            while Date() < deadline {
                guard let extra = await read(.authData, 3.0) else { continue }
                if extra.count >= 20 && extra[2] == 0x04 { keyData = extra; recovered = true; break }
            }
            if !recovered { throw MibleError.auth("设备状态机不同步（重复 init 响应），放弃本次认证") }
        }

        t("密钥交换完成")
        let padLen = max(0, keyData.count - 4)
        var placeholder = [UInt8](repeating: 0xF2, count: 4 + padLen)
        placeholder[0] = 0x00; placeholder[1] = 0x00; placeholder[2] = 0x05; placeholder[3] = 0x01
        try await link.write(.authData, placeholder)

        try await Task.sleep(nanoseconds: 300_000_000); queues[.authData]?.clear()
        try await Task.sleep(nanoseconds: 300_000_000); queues[.authData]?.clear()

        // ---- Phase B：登录 (CMD_LOGIN=0x24) ----
        try await link.subscribe(.authCtrl)
        try await Task.sleep(nanoseconds: 50_000_000)
        t("占位回写完成，发 CMD_LOGIN")
        try await link.write(.authCtrl, Self.cmdLogin)

        let randKey = randomBytes(16)
        try await link.write(.authData, Self.cmdSendKey)

        var ready = false
        for _ in 0..<5 where !ready {
            if let d = await read(.authData, 3.0), d == Self.rcvRdy { ready = true }
        }
        if !ready { throw MibleError.auth("未收到 RCV_RDY（发送随机密钥前）") }

        try await link.write(.authData, [0x01, 0x00] + randKey)
        guard let okFrame = await read(.authData, 3.0), okFrame == Self.rcvOk else {
            throw MibleError.auth("未收到 RCV_OK（发送随机密钥后）")
        }

        t("随机密钥已发，收设备随机数")
        guard var devRandom = try await recvAuthResponse() else {
            throw MibleError.auth("设备随机数接收失败")
        }
        if devRandom.count < 16 { throw MibleError.auth("设备随机数长度异常: \(devRandom.count)") }
        devRandom = Array(devRandom.prefix(16))

        guard var devHmac = try await recvAuthResponse() else {
            throw MibleError.auth("设备 HMAC 接收失败")
        }
        if devHmac.count < 32 { throw MibleError.auth("设备 HMAC 长度异常: \(devHmac.count)") }
        devHmac = Array(devHmac.prefix(32))

        let salt = randKey + devRandom
        let saltInv = devRandom + randKey

        let derived = MibleCrypto.hkdfSHA256(ikm: token, salt: salt, info: Self.hkdfInfo, outputByteCount: 64)
        devKey = Array(derived[0..<16])
        appKey = Array(derived[16..<32])
        devIv = Array(derived[32..<36])
        appIv = Array(derived[36..<40])

        let expectedDevHmac = MibleCrypto.hmacSHA256(key: devKey, message: saltInv)
        guard constantTimeEquals(expectedDevHmac, devHmac) else {
            throw MibleError.auth("设备 HMAC 校验失败（token 可能不对）")
        }

        t("密钥派生+设备 HMAC 校验通过 dev_key=\(devKey.hexString)")
        let ourHmac = MibleCrypto.hmacSHA256(key: appKey, message: salt)

        try await link.write(.authData, Self.cmdSendInfo)
        guard let rdy2 = await read(.authData, 3.0), rdy2 == Self.rcvRdy else {
            throw MibleError.auth("未收到 RCV_RDY（发送 HMAC 前）")
        }

        try await link.write(.authData, [0x01, 0x00] + ourHmac)
        _ = await read(.authData, 3.0)

        t("我方 HMAC 已发")
        var challenge: [UInt8]? = nil
        var response: [UInt8]? = nil
        var d0 = await read(.authData, 1.2)
        let deadline2 = Date().addingTimeInterval(8)
        while let d = d0, Date() < deadline2 {
            d0 = nil
            if d.count >= 3 && d[2] == 0x0D {
                challenge = d
                try await link.write(.authData, Self.keepAlive)
            } else if d.count >= 3 && d[2] == 0x0C {
                response = d
                try await link.write(.authData, Self.keepAlive)
                try await link.write(.authData, Self.cmdSendInfo)
            } else if d == Self.rcvRdy || d == Self.rcvOk {
                break
            }
            d0 = await read(.authData, 3.0)
        }
        _ = challenge
        if let resp = response, resp.count >= 4 {
            try await link.write(.authData, [0x01, 0x00, 0x0C] + resp[3...])
            _ = await read(.authData, 3.0)
        }

        t("挑战应答结束 challenge=\(challenge?.count ?? 0) response=\(response?.count ?? 0)")
        guard let result = await read(.authCtrl, 5.0), result.count >= 1 else {
            throw MibleError.auth("未收到认证结果")
        }
        switch result[0] {
        case 0x21, 0x11:
            t(String(format: "认证结果 0x%02x，开始建立命令通道", result[0]))
            authenticated = true
            try await setupCommandChannel()
            t("命令通道就绪")
        case 0x23: throw MibleError.auth("登录失败 (0x23)")
        case 0x12: throw MibleError.auth("激活失败 (0x12)")
        default: throw MibleError.auth(String(format: "未知认证结果: 0x%02x", result[0]))
        }
    }

    private func recvAuthResponse() async throws -> [UInt8]? {
        guard let data = await read(.authData, 3.0), data.count >= 4 else { return nil }

        if data[2] == 0x02 {
            try await link.write(.authData, Self.keepAlive)
            return Array(data[4...])
        }
        if data[2] == 0x00 && data.count >= 6 {
            let frameCount = min(Int(data[4]) + (Int(data[5]) << 8), Self.maxFrames)
            try await link.write(.authData, Self.rcvRdy)
            var acc: [UInt8] = []
            for _ in 0..<frameCount {
                guard let frame = await read(.authData, 3.0) else { break }
                if frame.count > 2 { acc.append(contentsOf: frame[2...]) }
            }
            try await link.write(.authData, Self.rcvOk)
            return acc
        }
        return nil
    }

    // MARK: - 命令通道

    private func setupCommandChannel() async throws {
        sendIt = 0
        devItHi = 0
        lastDevItLo = 0
        miotSeq = 1

        try await Task.sleep(nanoseconds: 500_000_000)
        await drainPendingPushes()
        try await drainDevicePush()
    }

    private func drainDevicePush() async throws {
        let start = Date()
        var count = 0
        while count < 60 && Date().timeIntervalSince(start) < 6.0 {
            guard let data = await read(.cmdRecv, 0.8) else { break }
            count += 1
            if data.count >= 6 && data[2] == 0x00 {
                let frameCount = min(Int(data[4]) + (Int(data[5]) << 8), Self.maxFrames)
                try await link.write(.cmdRecv, Self.rcvRdy)
                for _ in 0..<frameCount {
                    if await read(.cmdRecv, 3.0) == nil { break }
                }
                try await link.write(.cmdRecv, Self.rcvOk)
            } else if data.count >= 4 && data[2] == 0x02 {
                try await link.write(.cmdRecv, Self.keepAlive)
                if let pt = decrypt(Array(data[4...])), let msg = MiotCodec.parse(pt) {
                    onPush?(msg)
                }
            }
        }
    }

    @discardableResult
    private func drainPendingPushes() async -> Int {
        var drained = 0
        while true {
            guard let data = await read(.cmdRecv, 0) else { break }
            if data.count >= 4 && data[2] == 0x02 {
                try? await link.write(.cmdRecv, Self.keepAlive)
                if let pt = decrypt(Array(data[4...])), let msg = MiotCodec.parse(pt) {
                    onPush?(msg)
                }
                drained += 1
            } else if data.count >= 6 && data[2] == 0x00 {
                let frameCount = min(Int(data[4]) + (Int(data[5]) << 8), Self.maxFrames)
                try? await link.write(.cmdRecv, Self.rcvRdy)
                for _ in 0..<frameCount {
                    if await read(.cmdRecv, 2.0) == nil { break }
                }
                try? await link.write(.cmdRecv, Self.rcvOk)
                drained += 1
            }
        }
        return drained
    }

    public func sendCommand(siid: UInt8, piid: UInt16, value: UInt32? = nil,
                            timeout: TimeInterval = 8.0) async throws -> MiotMessage? {
        await commandMutex.acquire()
        defer { commandMutex.release() }

        guard authenticated else { throw MibleError.notAuthenticated }

        await drainPendingPushes()

        let seq = miotSeq
        miotSeq = miotSeq &+ 1

        let plaintext = MiotCodec.buildCommand(seq: seq, siid: siid, piid: piid, value: value)
        guard try await sendEncrypted(plaintext) else { return nil }

        return try await receiveResponse(siid: siid, piid: piid, isSet: value != nil, timeout: timeout)
    }

    private func receiveResponse(siid: UInt8, piid: UInt16, isSet: Bool,
                                 timeout: TimeInterval) async throws -> MiotMessage? {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let remain = deadline.timeIntervalSinceNow
            let step = remain < 3.0 ? remain : 3.0
            guard let data = await read(.cmdRecv, step) else {
                continue
            }

            guard let msg = try await decodeInline(data) else { continue }

            if msg.siid == siid && msg.piid == UInt8(piid & 0xFF) {
                // 实测设备对 SET 只返回 op=0x01 ACK（不含新值），不再空等 1 秒，由上层显式 GET 回读
                if msg.isGetResult || msg.isSetAck {
                    return msg
                }
            }
            if msg.isPush { onPush?(msg) }
        }
        return nil
    }

    private func decodeInline(_ data: [UInt8]) async throws -> MiotMessage? {
        if data.count >= 4 && data[2] == 0x02 {
            try await link.write(.cmdRecv, Self.keepAlive)
            guard let pt = decrypt(Array(data[4...])) else { return nil }
            return MiotCodec.parse(pt)
        }
        if data.count >= 6 && data[2] == 0x00 {
            let frameCount = min(Int(data[4]) + (Int(data[5]) << 8), Self.maxFrames)
            try await link.write(.cmdRecv, Self.rcvRdy)
            var acc: [UInt8] = []
            for _ in 0..<frameCount {
                guard let frame = await read(.cmdRecv, 3.0) else { break }
                if frame.count > 2 { acc.append(contentsOf: frame[2...]) }
            }
            try await link.write(.cmdRecv, Self.rcvOk)
            if acc.isEmpty { return nil }
            guard let pt = decrypt(acc) else { return nil }
            return MiotCodec.parse(pt)
        }
        return nil
    }

    private func sendEncrypted(_ plaintext: [UInt8]) async throws -> Bool {
        queues[.cmdSend]?.clear()
        let encrypted = encrypt(plaintext)

        try await link.write(.cmdSend, Self.cmdClear)
        guard let d = await read(.cmdSend, 3.0), d == Self.rcvRdy else { return false }

        try await link.write(.cmdSend, [0x01, 0x00] + encrypted)
        guard let ok = await read(.cmdSend, 3.0) else { return false }
        return ok == Self.rcvOk
    }

    // MARK: - 密码学

    private func encrypt(_ plaintext: [UInt8]) -> [UInt8] {
        let it = sendIt
        let itBytes: [UInt8] = [UInt8(it & 0xFF), UInt8((it >> 8) & 0xFF), UInt8((it >> 16) & 0xFF), UInt8((it >> 24) & 0xFF)]
        let nonce = appIv + [0, 0, 0, 0] + itBytes
        let (ct, tag) = (try? AESCCM.seal(key: appKey, nonce: nonce, plaintext: plaintext, aad: [], tagLength: 4)) ?? ([], [])
        sendIt = sendIt &+ 1
        return [itBytes[0], itBytes[1]] + ct + tag
    }

    private func decrypt(_ data: [UInt8]) -> [UInt8]? {
        guard data.count >= 6 else { return nil }

        let itLo = UInt16(data[0]) | (UInt16(data[1]) << 8)
        if itLo < lastDevItLo && lastDevItLo - itLo > 32768 { devItHi &+= 1 }
        lastDevItLo = itLo
        let it = (devItHi << 16) | UInt32(itLo)

        let nonce = devIv + [0, 0, 0, 0] + [UInt8(it & 0xFF), UInt8((it >> 8) & 0xFF), UInt8((it >> 16) & 0xFF), UInt8((it >> 24) & 0xFF)]
        let ct = Array(data[2...])
        guard ct.count >= 4 else { return nil }
        let ciphertext = Array(ct[0..<(ct.count - 4)])
        let tag = Array(ct[(ct.count - 4)...])
        return try? AESCCM.open(key: devKey, nonce: nonce, ciphertext: ciphertext, tag: tag, aad: [])
    }

    // MARK: - 工具

    private func read(_ ch: MibleChannel, _ timeout: TimeInterval) async -> [UInt8]? {
        guard let q = queues[ch] else { return nil }
        return await q.read(timeout: timeout)
    }

    private func randomBytes(_ n: Int) -> [UInt8] {
        (0..<n).map { _ in UInt8.random(in: 0...255) }
    }

    private func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        if a.count != b.count { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

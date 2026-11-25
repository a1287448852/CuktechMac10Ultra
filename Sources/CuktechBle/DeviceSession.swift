#if canImport(CoreBluetooth)
import Foundation
import CuktechCore

/// 设备会话管理：把「扫广播 → 连接 → 认证 → 自适应轮询」串起来。
/// 通过 AsyncStream 主动推送快照，UI 层无需再定时轮询。
public actor DeviceSession {
    public private(set) var snapshot = DeviceSnapshot()

    private let mac: [UInt8]
    private let token: [UInt8]

    /// 面板打开时使用高频轮询；面板收起时使用低频后台轮询以节省蓝牙与电量。
    private var activePollInterval: TimeInterval = 1.0
    private var backgroundPollInterval: TimeInterval = 2.5
    private var isPanelOpen = false

    private var link: CBMibleLink?
    private var mible: MibleSession?
    private var running = false
    private var failures = 0
    private var loopTask: Task<Void, Never>?
    private var sleepWakeContinuation: (token: UUID, cont: CheckedContinuation<Void, Never>)?
    private var pollCycleCount = 0

    /// 串行化高层控制事务（读-改-写开关、切换模式、单轮刷新），并支持用户操作优先插队。
    private var transactionBusy = false
    private var urgentControlCount = 0
    private var urgentWaiters: [CheckedContinuation<Void, Never>] = []
    private var backgroundWaiters: [CheckedContinuation<Void, Never>] = []

    private var onLog: ((String) -> Void)?
    private var snapshotContinuations: [UUID: AsyncStream<DeviceSnapshot>.Continuation] = [:]

    public init(mac: [UInt8], token: [UInt8]) {
        self.mac = mac
        self.token = token
    }

    public var macText: String {
        mac.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    public func isRunning() -> Bool { running }

    public func setPollIntervals(active: TimeInterval, background: TimeInterval) {
        activePollInterval = max(0.5, active)
        backgroundPollInterval = max(1.0, background)
        wakePollSleep()
    }

    public func setPanelOpen(_ open: Bool) {
        let changed = isPanelOpen != open
        isPanelOpen = open
        if changed && open {
            wakePollSleep()
        }
    }

    public func setLogHandler(_ handler: ((String) -> Void)?) {
        onLog = handler
    }

    /// 订阅实时状态流。订阅时会立即收到当前最新快照。
    public func makeSnapshotStream() -> AsyncStream<DeviceSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(self.snapshot)
            self.snapshotContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    public func start() {
        guard !running else { return }
        running = true
        failures = 0
        log("[session] 开始，目标 \(macText)")

        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        running = false
        wakePollSleep()
        loopTask?.cancel()
        loopTask = nil
        teardownLink()
        for (_, cont) in snapshotContinuations { cont.finish() }
        snapshotContinuations.removeAll()
        log("[session] 已停止")
    }

    /// 立刻重连（手动点击重连或系统从睡眠唤醒时调用）。
    public func reconnectNow() {
        failures = 0
        teardownLink()
        wakePollSleep()
    }

    // MARK: - 主循环

    private func runLoop() async {
        while running && !Task.isCancelled {
            do {
                try await connectOnce()
                failures = 0
                while running && !Task.isCancelled {
                    guard let l = link, l.isConnected else { break }
                    pollCycleCount += 1
                    // 打开面板时每 5 轮补读一次充电模式，其余时间只读端口减少蓝牙通道抢占
                    let shouldQueryScene = isPanelOpen && (pollCycleCount % 5 == 0)
                    try await refreshOnce(includeScene: shouldQueryScene)
                    let interval = isPanelOpen ? activePollInterval : backgroundPollInterval
                    await sleepInterruptibly(seconds: interval)
                }
                teardownLink()
                if running && !Task.isCancelled {
                    publish(status: "连接断了，正在重连…", connected: false, error: "设备断开")
                    log("[session] 连接断开，准备重连")
                    await sleepInterruptibly(seconds: 0.8)
                }
            } catch {
                // 关键修复：异常退出前必须立即断开旧连接，否则充电器被旧连接占住会停止发送 FE95 广播
                teardownLink()
                if !running || Task.isCancelled { break }
                failures += 1
                let msg = humanize(error)
                publish(status: "没连上", connected: false, error: msg)
                log("[fail#\(failures)] \(msg)")
                let delay = backoffSeconds(failures)
                log("[session] \(Int(delay)) 秒后重试")
                await sleepInterruptibly(seconds: delay)
            }
        }
    }

    private func teardownLink() {
        let old = link
        link = nil
        mible = nil
        old?.onNotification = nil
        old?.onDisconnect = nil
        old?.onLog = nil
        old?.disconnect()
    }

    private func connectOnce() async throws {
        teardownLink()
        publish(status: "正在连接…", connected: false, error: nil)

        let l = CBMibleLink()
        l.onLog = { [weak self, weak l] s in
            Task { await self?.handleLinkLog(l, s) }
        }
        l.onDisconnect = { [weak self, weak l] why in
            Task { await self?.handleDisconnect(l, why) }
        }
        link = l
        mible = nil

        try await l.connect(mac: mac)
        let firmware = try? await l.readFirmware()

        let session = try MibleSession(link: l, token: token)
        session.trace = { [weak self] t in Task { await self?.log(t) } }
        l.onNotification = { ch, data in session.handleNotification(ch, data) }
        mible = session

        publish(status: "正在认证…", connected: false, error: nil)
        let started = Date()
        try await session.authenticate()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        log("[ok] 认证完成 \(ms)ms 固件=\(firmware ?? "?")")

        var snap = snapshot
        snap.connected = true
        snap.status = "已连接"
        snap.error = nil
        snap.firmware = firmware
        emit(snap)

        try await refreshOnce(includeScene: true)
    }

    private func handleLinkLog(_ source: CBMibleLink?, _ msg: String) {
        guard let source, link === source else { return }
        log(msg)
    }

    private func handleDisconnect(_ source: CBMibleLink?, _ why: String) {
        guard let source, link === source else { return }
        log("[session] 断开：\(why)")
        wakePollSleep()
    }

    private func refreshOnce(includeScene: Bool) async throws {
        guard mible?.authenticated == true else { throw MibleError.notAuthenticated }

        var snap = snapshot
        snap.connected = true
        snap.status = "已连接"
        snap.error = nil

        if urgentControlCount > 0 { return }
        if let m = try await withTransactionLock(urgent: false, {
            guard let s = mible, s.authenticated else { throw MibleError.notAuthenticated }
            return try await s.sendCommand(siid: 2, piid: 16, timeout: 4)
        }), let v = m.uintValue {
            snap.portSwitch = Int(v & 0x0F)
        }

        if urgentControlCount > 0 { return }
        if includeScene || snap.sceneMode == 0 {
            if let m = try await withTransactionLock(urgent: false, {
                guard let s = mible, s.authenticated else { throw MibleError.notAuthenticated }
                return try await s.sendCommand(siid: 2, piid: 5, timeout: 4)
            }), let first = m.valueBytes.first {
                snap.sceneMode = Int(first)
            }
        }

        var answered = 0
        for i in 0..<4 {
            if urgentControlCount > 0 { return }
            var slot = snap.ports[i]
            slot.enabled = (snap.portSwitch & (1 << i)) != 0
            if let m = try await withTransactionLock(urgent: false, {
                guard let s = mible, s.authenticated else { throw MibleError.notAuthenticated }
                return try await s.sendCommand(siid: 2, piid: UInt16(i + 1), timeout: 2.5)
            }), let d = PortData.parse(m.valueBytes) {
                slot.apply(d)
                answered += 1
            }
            snap.ports[i] = slot
        }
        snap.at = Date()

        if answered == 0 { throw MibleError.timeout("四个端口都没有应答") }
        emit(snap)
    }

    // MARK: - 控制

    /// zeroBasedIndex: 0=C1 1=C2 2=C3 3=USB-A。读-改-写，回读校验。
    public func setPortEnabled(_ zeroBasedIndex: Int, _ enabled: Bool) async throws {
        guard zeroBasedIndex >= 0 && zeroBasedIndex < 4 else {
            throw MibleError.auth("端口序号只能是 0~3")
        }

        urgentControlCount += 1
        defer { urgentControlCount -= 1 }

        try await withTransactionLock(urgent: true) {
            guard let s = mible, s.authenticated else { throw MibleError.notAuthenticated }

            guard let curMsg = try await s.sendCommand(siid: 2, piid: 16, timeout: 4),
                  let cur = curMsg.uintValue else {
                throw MibleError.timeout("读取端口开关失败（设备无响应），为了不误关其它口，本次没有写入")
            }
            let bit = UInt32(1) << UInt32(zeroBasedIndex)
            let next = enabled ? (cur | bit) : (cur & ~bit)

            guard try await s.sendCommand(siid: 2, piid: 16, value: next, timeout: 6) != nil else {
                throw MibleError.timeout("写入端口开关没有收到确认")
            }
            guard let backMsg = try await s.sendCommand(siid: 2, piid: 16, timeout: 4),
                  let back = backMsg.uintValue else {
                throw MibleError.timeout("已写入，但回读失败，实际状态未知")
            }

            var snap = snapshot
            snap.portSwitch = Int(back & 0x0F)
            if zeroBasedIndex < snap.ports.count {
                snap.ports[zeroBasedIndex].enabled = (snap.portSwitch & (1 << zeroBasedIndex)) != 0
            }
            emit(snap)

            if back != next {
                throw MibleError.auth(String(format: "设备只接受了 0x%02X（请求 0x%02X），可能是该口不支持", back, next))
            }
        }
        wakePollSleep()
    }

    /// 切换充电模式（SIID=2 PIID=5，取值 1~4）。写入并回读确认后立刻返回，不再阻塞等待 6 路端口刷新。
    public func setSceneMode(_ mode: Int) async throws {
        guard mode >= 1 && mode <= 4 else { throw MibleError.auth("充电模式只有 1~4") }

        urgentControlCount += 1
        defer { urgentControlCount -= 1 }

        try await withTransactionLock(urgent: true) {
            guard let s = mible, s.authenticated else { throw MibleError.notAuthenticated }

            guard try await s.sendCommand(siid: 2, piid: 5, value: UInt32(mode), timeout: 6) != nil else {
                throw MibleError.timeout("写入充电模式没有收到确认")
            }
            if let m = try await s.sendCommand(siid: 2, piid: 5, timeout: 4), let first = m.valueBytes.first {
                var snap = snapshot
                snap.sceneMode = Int(first)
                emit(snap)
                if Int(first) != mode {
                    throw MibleError.auth("设备只接受了模式 \(first)（请求 \(mode)）")
                }
            }
        }
    }

    // MARK: - 内部

    private func withTransactionLock<T>(urgent: Bool, _ body: () async throws -> T) async throws -> T {
        while transactionBusy {
            await withCheckedContinuation { cont in
                if urgent {
                    urgentWaiters.append(cont)
                } else {
                    backgroundWaiters.append(cont)
                }
            }
        }
        transactionBusy = true
        defer {
            transactionBusy = false
            if !urgentWaiters.isEmpty {
                let next = urgentWaiters.removeFirst()
                next.resume()
            } else if !backgroundWaiters.isEmpty {
                let next = backgroundWaiters.removeFirst()
                next.resume()
            }
        }
        return try await body()
    }

    private func publish(status: String, connected: Bool, error: String?) {
        var snap = snapshot
        snap.connected = connected
        snap.status = status
        snap.error = error
        emit(snap)
    }

    private func emit(_ snap: DeviceSnapshot) {
        snapshot = snap
        for (_, cont) in snapshotContinuations {
            cont.yield(snap)
        }
    }

    private func sleepInterruptibly(seconds: TimeInterval) async {
        let token = UUID()
        let sleepTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000))
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if let prev = self.sleepWakeContinuation {
                self.sleepWakeContinuation = nil
                prev.cont.resume()
            }
            self.sleepWakeContinuation = (token, cont)
            Task { [weak self] in
                await sleepTask.value
                await self?.wakePollSleep(matching: token)
            }
        }
        sleepTask.cancel()
    }

    private func wakePollSleep(matching token: UUID? = nil) {
        guard let active = sleepWakeContinuation else { return }
        if let token, active.token != token { return }
        sleepWakeContinuation = nil
        active.cont.resume()
    }

    private func backoffSeconds(_ failures: Int) -> TimeInterval {
        let exp = min(max(failures - 1, 0), 4)
        return min(8.0, pow(2.0, Double(min(exp, 2))) * 2.0)
    }

    private func log(_ s: String) { onLog?(s) }

    private func humanize(_ error: Error) -> String {
        if let e = error as? CBLinkError { return e.description }
        if let e = error as? MibleError { return e.description }
        return error.localizedDescription
    }
}
#endif

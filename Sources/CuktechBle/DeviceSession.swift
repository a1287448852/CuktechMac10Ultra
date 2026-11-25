#if canImport(CoreBluetooth)
import Foundation
import CuktechCore

/// 设备会话管理：事件驱动 BLE 链路、自适应轮询、设备设置读写与单口电量采集。
/// 通过 AsyncStream 主动推送快照，UI 层无需定时轮询。
public actor DeviceSession {
    public private(set) var snapshot = DeviceSnapshot()
    public private(set) var deviceSettings = DeviceSettings()
    public private(set) var capturePort: Int?

    private let mac: [UInt8]
    private let token: [UInt8]

    /// 面板打开时使用高频轮询（默认 1.0s，可由用户设置 1/2/3/5/10s）；收起时降频到 2.5s+ 省电。
    private var activePollInterval: TimeInterval = 1.0
    private var backgroundPollInterval: TimeInterval = 2.5
    private var isPanelOpen = false

    private var link: CBMibleLink?
    private var mible: MibleSession?
    private var running = false
    private var failures = 0
    private var loopTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var sleepWakeContinuation: (token: UUID, cont: CheckedContinuation<Void, Never>)?
    private var pollCycleCount = 0

    /// 串行化高层控制事务（读-改-写开关、切换模式、设置读写、单轮刷新），支持用户操作优先插队。
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
        backgroundPollInterval = max(activePollInterval, background)
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
        captureTask?.cancel()
        captureTask = nil
        capturePort = nil
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
                    // 单口采集期间常规轮询让路，避免同一通道并发拥挤
                    if capturePort == nil {
                        pollCycleCount += 1
                        let includeMeta = isPanelOpen && (pollCycleCount % 5 == 0)
                        try await refreshOnce(includeMeta: includeMeta)
                    }
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

        try await refreshOnce(includeMeta: true)
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

    private func refreshOnce(includeMeta: Bool) async throws {
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
        if includeMeta || snap.sceneMode == 0 {
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

        if includeMeta && urgentControlCount == 0 {
            if let m = try? await withTransactionLock(urgent: false, {
                guard let s = mible, s.authenticated else { throw MibleError.notAuthenticated }
                return try await s.sendCommand(siid: 2, piid: 17, timeout: 2.5)
            }), let v = m.uintValue {
                let p = Negotiation.split(v)
                snap.negotiations[0] = p.high
                snap.negotiations[1] = p.low
            }
            if urgentControlCount == 0, let m = try? await withTransactionLock(urgent: false, {
                guard let s = mible, s.authenticated else { throw MibleError.notAuthenticated }
                return try await s.sendCommand(siid: 2, piid: 18, timeout: 2.5)
            }), let v = m.uintValue {
                let p = Negotiation.split(v)
                snap.negotiations[2] = p.high
                snap.negotiations[3] = p.low
            }
        }

        snap.at = Date()

        if answered == 0 { throw MibleError.timeout("四个端口都没有应答") }
        emit(snap)
    }

    // MARK: - 端口与模式控制

    /// zeroBasedIndex: 0=C1 1=C2 2=C3 3=USB-A。读-改-写，带 250ms 硬件稳定期与回读重试。
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
            try? await Task.sleep(nanoseconds: 250_000_000)

            var backMsg = try await s.sendCommand(siid: 2, piid: 16, timeout: 4)
            if let v = backMsg?.uintValue, v != next {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let retryMsg = try await s.sendCommand(siid: 2, piid: 16, timeout: 4) {
                    backMsg = retryMsg
                }
            }
            guard let back = backMsg?.uintValue else {
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

    /// 切换充电模式（SIID=2 PIID=5，取值 1~4）。
    public func setSceneMode(_ mode: Int) async throws {
        guard mode >= 1 && mode <= 4 else { throw MibleError.auth("充电模式只有 1~4") }

        urgentControlCount += 1
        defer { urgentControlCount -= 1 }

        try await withTransactionLock(urgent: true) {
            guard let s = mible, s.authenticated else { throw MibleError.notAuthenticated }

            guard try await s.sendCommand(siid: 2, piid: 5, value: UInt32(mode), timeout: 6) != nil else {
                throw MibleError.timeout("写入充电模式没有收到确认")
            }
            var m = try await s.sendCommand(siid: 2, piid: 5, timeout: 4)
            if let first = m?.valueBytes.first, Int(first) != mode {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let retry = try await s.sendCommand(siid: 2, piid: 5, timeout: 4) {
                    m = retry
                }
            }
            if let first = m?.valueBytes.first {
                var snap = snapshot
                snap.sceneMode = Int(first)
                emit(snap)
                if Int(first) != mode {
                    throw MibleError.auth("设备只接受了模式 \(first)（请求 \(mode)）")
                }
            }
        }
    }

    // MARK: - 设备设置（屏幕 / 供电 / 定时 / 快充协议）

    public func reloadSettings() async -> DeviceSettings {
        guard mible?.authenticated == true else { return deviceSettings }

        urgentControlCount += 1
        defer { urgentControlCount -= 1 }

        let loaded: DeviceSettings? = try? await withTransactionLock(urgent: true) {
            var out = DeviceSettings()

            func get(_ piid: UInt16) async -> UInt32? {
                guard let s = mible, s.authenticated else { return nil }
                let m = try? await s.sendCommand(siid: 2, piid: piid, timeout: 3)
                guard let m, m.errorCode == 0, let v = m.uintValue else { return nil }
                return v
            }

            if let v = await get(6) { out.screenTimeout = Int(v) }
            if let v = await get(19) { out.idleScreenOff = v != 0 }
            if let v = await get(20) { out.screenLock = v != 0 }
            if let v = await get(15) { out.usbALowCurrent = v != 0 }
            if let v = await get(13) { out.language = Int(v) }
            if let v = await get(21) { out.protocolFlags = v }
            for i in 0..<4 {
                if let v = await get(UInt16(9 + i)) { out.countdowns[i] = Int(v) }
            }
            if let v = await get(17) {
                let p = Negotiation.split(v)
                out.negotiations[0] = p.high
                out.negotiations[1] = p.low
            }
            if let v = await get(18) {
                let p = Negotiation.split(v)
                out.negotiations[2] = p.high
                out.negotiations[3] = p.low
            }
            out.at = Date()
            return out
        }
        guard let out = loaded else { return deviceSettings }

        log("[settings] 读到 \(out.loadedCount) 项：息屏=\(optText(out.screenTimeout)) "
            + "空闲息屏=\(optText(out.idleScreenOff)) 方向锁=\(optText(out.screenLock)) "
            + "A小电流=\(optText(out.usbALowCurrent)) 语言=\(optText(out.language)) "
            + "协议位=\(out.protocolFlags.map { String(format: "0x%08X", $0) } ?? "?") "
            + "倒计时=\(out.countdowns.map { optText($0) }.joined(separator: "/"))")

        deviceSettings = out
        var snap = snapshot
        snap.negotiations = out.negotiations
        emit(snap)
        return out
    }

    private func optText<T>(_ v: T?) -> String { v.map { "\($0)" } ?? "?" }

    public func setScreenTimeout(_ value: Int) async throws {
        guard ScreenTimeout(rawValue: value) != nil else {
            throw MibleError.auth("息屏时间只有 1~5 这几个取值")
        }
        try await writeSetting(piid: 6, value: UInt32(value), name: "息屏时间", strict: true)
        deviceSettings.screenTimeout = value
    }

    public func setIdleScreenOff(_ on: Bool) async throws {
        try await writeSetting(piid: 19, value: on ? 1 : 0, name: "空闲息屏", strict: true)
        deviceSettings.idleScreenOff = on
    }

    public func setScreenLock(_ on: Bool) async throws {
        try await writeSetting(piid: 20, value: on ? 1 : 0, name: "方向锁", strict: true)
        deviceSettings.screenLock = on
    }

    public func setUSBLowCurrent(_ on: Bool) async throws {
        try await writeSetting(piid: 15, value: on ? 1 : 0, name: "USB-A 小电流", strict: true)
        deviceSettings.usbALowCurrent = on
    }

    public func setLanguage(_ value: Int) async throws {
        guard value == 0 || value == 1 else { throw MibleError.auth("语言只有 0=EN / 1=中文") }
        try await writeSetting(piid: 13, value: UInt32(value), name: "语言", strict: true)
        deviceSettings.language = value
    }

    /// 开关某一口的某一种快充协议。PIID 21 是 32 位掩码，必须读-改-写。
    public func setProtocol(_ cap: ProtocolCap, port: Int, on: Bool) async throws {
        guard let bit = cap.bit(port: port) else {
            throw MibleError.auth("\(PortData.portName(port)) 没有 \(cap.label) 这一项")
        }
        urgentControlCount += 1
        defer { urgentControlCount -= 1 }

        try await withTransactionLock(urgent: true) {
            guard let s = mible, s.authenticated else { throw MibleError.notAuthenticated }

            guard let curMsg = try await s.sendCommand(siid: 2, piid: 21, timeout: 4),
                  curMsg.errorCode == 0, let cur = curMsg.uintValue else {
                throw MibleError.timeout("读取协议开关失败（设备无响应），为了不误改其它协议，本次没有写入")
            }
            let mask = UInt32(1) << bit
            let next = on ? (cur | mask) : (cur & ~mask)

            guard try await s.sendCommand(siid: 2, piid: 21, value: next, timeout: 6) != nil else {
                throw MibleError.timeout("写入协议开关没有收到确认")
            }
            var backMsg = try await s.sendCommand(siid: 2, piid: 21, timeout: 4)
            if let v = backMsg?.uintValue, v != next {
                try? await Task.sleep(nanoseconds: 180_000_000)
                if let retry = try await s.sendCommand(siid: 2, piid: 21, timeout: 4) {
                    backMsg = retry
                }
            }
            guard let back = backMsg?.uintValue else {
                throw MibleError.timeout("已写入，但回读失败，实际状态未知")
            }
            deviceSettings.protocolFlags = back
            log(String(format: "[settings] 协议 %@ %@ -> 请求 0x%08X，回读 0x%08X",
                       PortData.portName(port), cap.label, next, back))
            if back != next {
                throw MibleError.auth(String(format: "设备只接受了 0x%08X（请求 0x%08X），可能这一项不支持", back, next))
            }
        }
    }

    public func setCountdown(port: Int, minutes: Int) async throws {
        guard (1...4).contains(port) else { throw MibleError.auth("端口序号只能是 1~4") }
        guard (0...1440).contains(minutes) else { throw MibleError.auth("倒计时只能是 0~1440 分钟") }
        try await writeSetting(piid: UInt16(8 + port), value: UInt32(minutes),
                               name: "\(PortData.portName(port)) 定时断电", strict: false)
        deviceSettings.countdowns[port - 1] = minutes
    }

    private func writeSetting(piid: UInt16, value: UInt32, name: String, strict: Bool) async throws {
        urgentControlCount += 1
        defer { urgentControlCount -= 1 }

        try await withTransactionLock(urgent: true) {
            guard let s = mible, s.authenticated else { throw MibleError.notAuthenticated }

            guard try await s.sendCommand(siid: 2, piid: piid, value: value, timeout: 6) != nil else {
                throw MibleError.timeout("写入「\(name)」没有收到确认")
            }
            guard let backMsg = try await s.sendCommand(siid: 2, piid: piid, timeout: 4),
                  let back = backMsg.uintValue else {
                throw MibleError.timeout("「\(name)」已写入，但回读失败，实际状态未知")
            }
            log("[settings] \(name) 写 \(value)，回读 \(back)")
            if strict && back != value {
                throw MibleError.auth("「\(name)」设备只接受了 \(back)（请求 \(value)），可能这一项不支持")
            }
        }
    }

    // MARK: - 单口电量采集

    /// 按绝对 1 秒节拍采样指定端口（1..4），结果只留在内存中不落盘。
    public func startCapture(port: Int,
                             onUpdate: @escaping @Sendable (CaptureAccumulator) -> Void,
                             onFinish: @escaping @Sendable (CaptureResult) -> Void) {
        guard captureTask == nil, (1...4).contains(port) else { return }
        guard mible?.authenticated == true else { return }
        capturePort = port
        log("[capture] 开始采集 \(PortData.portName(port))，每秒一次")
        captureTask = Task { [weak self] in
            await self?.runCapture(port: port, onUpdate: onUpdate, onFinish: onFinish)
        }
    }

    public func stopCapture() {
        guard captureTask != nil else { return }
        log("[capture] 手动停止")
        captureTask?.cancel()
    }

    private func runCapture(port: Int,
                            onUpdate: @Sendable (CaptureAccumulator) -> Void,
                            onFinish: @Sendable (CaptureResult) -> Void) async {
        let started = Date()
        var acc = CaptureAccumulator()
        var lastGood = started
        var lastActive = started
        var reason: CaptureEndReason = .noData
        var nextTick = started

        while !Task.isCancelled {
            if Date().timeIntervalSince(lastGood) >= 30 {
                reason = .noData
                break
            }
            if Date().timeIntervalSince(lastActive) >= 30 {
                reason = .noLoad
                break
            }
            guard let l = link, l.isConnected, let s = mible, s.authenticated else {
                reason = .disconnected
                break
            }

            var msg: MiotMessage?
            do {
                msg = try await withTransactionLock(urgent: false) {
                    try await s.sendCommand(siid: 2, piid: UInt16(port), timeout: 2.0)
                }
            } catch {
                msg = nil
            }

            if let d = PortData.parse(msg?.valueBytes) {
                let now = Date()
                acc.add(d, at: now)
                lastGood = now
                if d.state != 0x00 && d.power > 0.05 { lastActive = now }

                var snap = snapshot
                var slot = snap.ports[port - 1]
                slot.apply(d)
                slot.enabled = (snap.portSwitch & (1 << (port - 1))) != 0
                snap.ports[port - 1] = slot
                snap.at = now
                emit(snap)
                onUpdate(acc)
            }

            nextTick = nextTick.addingTimeInterval(1.0)
            if nextTick.timeIntervalSinceNow < 0 {
                nextTick = Date()
            }
            var remaining = nextTick.timeIntervalSinceNow
            while remaining > 0 {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: UInt64(min(0.1, remaining) * 1_000_000_000))
                remaining = nextTick.timeIntervalSinceNow
            }
        }

        if Task.isCancelled { reason = .stopped }
        captureTask = nil
        capturePort = nil
        wakePollSleep()

        let result = CaptureResult(
            portIndex: port,
            startedAt: started,
            endedAt: Date(),
            stats: acc,
            reason: reason,
            firmware: snapshot.firmware
        )
        log("[capture] 结束 \(PortData.portName(port))：\(acc.sampleCount) 次采样，"
            + String(format: "%.2fWh，平均 %.1fW，", acc.energyWh, acc.averagePower)
            + reason.shortText)
        onFinish(result)
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

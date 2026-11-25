#if canImport(CoreBluetooth)
import Foundation
@preconcurrency import CoreBluetooth
import CuktechCore

/// MiBeacon (0xFE95) 广播里的身份信息。
public struct MiBeaconAdvertisement: Equatable, Sendable {
    public let mac: [UInt8]        // 6 字节，从高到低，如 3C:CD:73:27:61:A0
    public let productId: UInt16
    public let frameCounter: UInt8

    public var macString: String {
        mac.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// 解析 0xFE95 服务数据。macOS 交过来的是不带服务 UUID 头的裸 payload，也兼容带 `95 FE` 头的情况。
    public static func parse(serviceData: Data) -> MiBeaconAdvertisement? {
        var b = [UInt8](serviceData)
        if b.count >= 2 && b[0] == 0x95 && b[1] == 0xFE {
            b.removeFirst(2)
        }
        guard b.count >= 11 else { return nil }
        let frameCtrl = UInt16(b[0]) | (UInt16(b[1]) << 8)
        guard (frameCtrl >> 4) & 1 == 1 else { return nil }
        let productId = UInt16(b[2]) | (UInt16(b[3]) << 8)
        let counter = b[4]
        let macLe = Array(b[5..<11])
        return MiBeaconAdvertisement(mac: macLe.reversed(), productId: productId, frameCounter: counter)
    }
}

public enum CBLinkError: Error, CustomStringConvertible, Sendable {
    case bluetoothUnavailable(String)
    case deviceNotFound(String)
    case timeout(String)
    case connectFailed(String)
    case characteristicMissing(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .bluetoothUnavailable(let s): return "蓝牙不可用：\(s)"
        case .deviceNotFound(let s): return "没扫到设备：\(s)"
        case .timeout(let s): return "超时：\(s)"
        case .connectFailed(let s): return "连接失败：\(s)"
        case .characteristicMissing(let s): return "缺少特征：\(s)"
        case .writeFailed(let s): return "写入失败：\(s)"
        }
    }
}

/// CoreBluetooth 事件驱动传输层：所有等待均通过串行 queue 上的 Continuation + 超时 DispatchWorkItem 完成，
/// 彻底消除 20ms 轮询空转。
public final class CBMibleLink: NSObject, MibleLink, @unchecked Sendable {
    private static let serviceUUID = CBUUID(string: "FE95")

    public var onNotification: ((MibleChannel, [UInt8]) -> Void)?
    public var onDisconnect: ((String) -> Void)?
    public var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "io.github.a1287448852.cuktechmac10ultra.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var service: CBService?
    private var chars: [MibleChannel: CBCharacteristic] = [:]
    private var firmwareChar: CBCharacteristic?

    private var _isConnected = false
    private var targetMAC: [UInt8] = []

    // 事件驱动等待槽位（全部只在 queue 上读写）
    private var readyWaiter: (cont: CheckedContinuation<Void, Error>, timer: DispatchWorkItem)?
    private var discoverWaiter: (cont: CheckedContinuation<CBPeripheral, Error>, timer: DispatchWorkItem)?
    private var connectWaiter: (cont: CheckedContinuation<Void, Error>, timer: DispatchWorkItem)?
    private var servicesWaiter: (cont: CheckedContinuation<CBService, Error>, timer: DispatchWorkItem)?
    private var charsWaiter: (cont: CheckedContinuation<Void, Error>, timer: DispatchWorkItem)?
    private var notifyWaiters: [MibleChannel: (cont: CheckedContinuation<Void, Error>, timer: DispatchWorkItem)] = [:]
    private var writeWaiter: (cont: CheckedContinuation<Void, Error>, timer: DispatchWorkItem)?
    private var firmwareWaiter: (cont: CheckedContinuation<[UInt8]?, Error>, timer: DispatchWorkItem)?

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    public var isConnected: Bool {
        queue.sync { _isConnected }
    }

    // MARK: - 连接生命周期

    public func connect(mac: [UInt8], scanTimeout: TimeInterval = 20) async throws {
        guard mac.count == 6 else { throw CBLinkError.deviceNotFound("MAC 格式不对") }

        log("等蓝牙就绪（首次会弹权限框，请点“允许”）")
        try await waitPoweredOn(timeout: 30)
        log("蓝牙就绪，开始扫描")

        let targetPeripheral = try await scanForTarget(mac: mac, timeout: scanTimeout)
        log("扫到 \(macString(mac))，开始连接")

        try await connectPeripheral(targetPeripheral, timeout: 15)
        log("已连接，找服务")

        let svc = try await discoverService(targetPeripheral, timeout: 10)
        try await discoverCharacteristics(targetPeripheral, service: svc, timeout: 10)
        log("特征齐了：\(queue.sync { readCharNamesOnQueue() })")
    }

    public func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            let p = self.peripheral
            self.peripheral = nil
            self._isConnected = false
            self.chars.removeAll()
            self.firmwareChar = nil
            self.failAllWaitersOnQueue(CBLinkError.connectFailed("主动断开"))
            if let p { self.central.cancelPeripheralConnection(p) }
        }
    }

    public func readFirmware(timeout: TimeInterval = 4) async throws -> String? {
        let raw: [UInt8]? = try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else { cont.resume(returning: nil); return }
                guard let p = self.peripheral, let ch = self.firmwareChar, self._isConnected else {
                    cont.resume(returning: nil)
                    return
                }
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, let w = self.firmwareWaiter else { return }
                    self.firmwareWaiter = nil
                    w.cont.resume(returning: nil)
                }
                self.firmwareWaiter = (cont, timer)
                self.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                p.readValue(for: ch)
            }
        }
        guard let raw, !raw.isEmpty else { return nil }
        var s = ""
        for b in raw {
            if b == 0 { break }
            if b >= 0x20 && b < 0x7F { s.append(Character(UnicodeScalar(b))) }
        }
        return s.isEmpty ? nil : s
    }

    // MARK: - MibleLink

    public func subscribe(_ channel: MibleChannel) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(throwing: CBLinkError.connectFailed("传输层已释放")); return }
                guard let ch = self.chars[channel] else {
                    cont.resume(throwing: CBLinkError.characteristicMissing(self.name(of: channel)))
                    return
                }
                guard let p = self.peripheral, self._isConnected else {
                    cont.resume(throwing: CBLinkError.connectFailed("还没连上"))
                    return
                }
                guard ch.properties.contains(.notify) || ch.properties.contains(.indicate) else {
                    cont.resume(returning: ())
                    return
                }
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, let w = self.notifyWaiters.removeValue(forKey: channel) else { return }
                    w.cont.resume(throwing: CBLinkError.timeout("订阅 \(self.name(of: channel)) 超时"))
                }
                self.notifyWaiters[channel] = (cont, timer)
                self.queue.asyncAfter(deadline: .now() + 5, execute: timer)
                p.setNotifyValue(true, for: ch)
            }
        }
    }

    public func unsubscribe(_ channel: MibleChannel) async throws {
        queue.async { [weak self] in
            guard let self, let ch = self.chars[channel], let p = self.peripheral else { return }
            p.setNotifyValue(false, for: ch)
        }
    }

    public func write(_ channel: MibleChannel, _ data: [UInt8]) async throws {
        let (ch, p, type, limit): (CBCharacteristic, CBPeripheral, CBCharacteristicWriteType, Int) = try queue.sync {
            guard let ch = self.chars[channel] else {
                throw CBLinkError.characteristicMissing(self.name(of: channel))
            }
            guard let p = self.peripheral, self._isConnected else {
                throw CBLinkError.connectFailed("还没连上")
            }
            let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
            let limit = max(20, p.maximumWriteValueLength(for: type))
            return (ch, p, type, limit)
        }

        var offset = 0
        while offset < data.count {
            let n = min(limit, data.count - offset)
            let chunk = Data(data[offset..<(offset + n)])

            if type == .withResponse {
                try await writeChunkWithResponse(peripheral: p, char: ch, chunk: chunk, timeout: 4)
            } else {
                queue.async { p.writeValue(chunk, for: ch, type: .withoutResponse) }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            offset += n
        }
    }

    // MARK: - 分步异步原语

    private func waitPoweredOn(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(throwing: CBLinkError.bluetoothUnavailable("传输层已释放")); return }
                if self.central.state == .poweredOn {
                    cont.resume(returning: ())
                    return
                }
                if let err = self.terminalBluetoothError(self.central.state) {
                    cont.resume(throwing: err)
                    return
                }
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, let w = self.readyWaiter else { return }
                    self.readyWaiter = nil
                    w.cont.resume(throwing: CBLinkError.bluetoothUnavailable("蓝牙 30 秒内没就绪，检查「系统设置 → 隐私与安全性 → 蓝牙」是否允许了本程序"))
                }
                self.readyWaiter = (cont, timer)
                self.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
            }
        }
    }

    private func scanForTarget(mac: [UInt8], timeout: TimeInterval) async throws -> CBPeripheral {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CBPeripheral, Error>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(throwing: CBLinkError.deviceNotFound("传输层已释放")); return }
                self.targetMAC = mac
                self.service = nil
                self.chars.removeAll()
                self.firmwareChar = nil
                self._isConnected = false

                let timer = DispatchWorkItem { [weak self] in
                    guard let self, let w = self.discoverWaiter else { return }
                    self.discoverWaiter = nil
                    self.central.stopScan()
                    w.cont.resume(throwing: CBLinkError.deviceNotFound("扫不到 MAC 为 \(self.macString(mac)) 的广播"))
                }
                self.discoverWaiter = (cont, timer)
                self.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                self.central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
            }
        }
    }

    private func connectPeripheral(_ p: CBPeripheral, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(throwing: CBLinkError.connectFailed("传输层已释放")); return }
                self.peripheral = p
                p.delegate = self
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, let w = self.connectWaiter else { return }
                    self.connectWaiter = nil
                    self.central.cancelPeripheralConnection(p)
                    w.cont.resume(throwing: CBLinkError.timeout("连接超时"))
                }
                self.connectWaiter = (cont, timer)
                self.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                self.central.connect(p, options: nil)
            }
        }
    }

    private func discoverService(_ p: CBPeripheral, timeout: TimeInterval) async throws -> CBService {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CBService, Error>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(throwing: CBLinkError.characteristicMissing("FE95 服务")); return }
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, let w = self.servicesWaiter else { return }
                    self.servicesWaiter = nil
                    w.cont.resume(throwing: CBLinkError.timeout("发现 FE95 服务超时"))
                }
                self.servicesWaiter = (cont, timer)
                self.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                p.discoverServices([Self.serviceUUID])
            }
        }
    }

    private func discoverCharacteristics(_ p: CBPeripheral, service: CBService, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(throwing: CBLinkError.characteristicMissing("特征")); return }
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, let w = self.charsWaiter else { return }
                    self.charsWaiter = nil
                    w.cont.resume(throwing: CBLinkError.timeout("发现特征超时"))
                }
                self.charsWaiter = (cont, timer)
                self.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                p.discoverCharacteristics(nil, for: service)
            }
        }
    }

    private func writeChunkWithResponse(peripheral p: CBPeripheral, char: CBCharacteristic,
                                        chunk: Data, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else { cont.resume(throwing: CBLinkError.writeFailed("传输层已释放")); return }
                guard self._isConnected else {
                    cont.resume(throwing: CBLinkError.connectFailed("设备已断开"))
                    return
                }
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, let w = self.writeWaiter else { return }
                    self.writeWaiter = nil
                    w.cont.resume(throwing: CBLinkError.timeout("GATT 写入超时"))
                }
                self.writeWaiter = (cont, timer)
                self.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                p.writeValue(chunk, for: char, type: .withResponse)
            }
        }
    }

    // MARK: - 辅助

    private func terminalBluetoothError(_ state: CBManagerState) -> CBLinkError? {
        switch state {
        case .unauthorized:
            return .bluetoothUnavailable("系统没给蓝牙权限（系统设置 → 隐私与安全性 → 蓝牙）")
        case .poweredOff:
            return .bluetoothUnavailable("蓝牙是关着的")
        case .unsupported:
            return .bluetoothUnavailable("这台机器没有可用的蓝牙")
        default:
            return nil
        }
    }

    private func failAllWaitersOnQueue(_ error: Error) {
        if let w = readyWaiter { readyWaiter = nil; w.timer.cancel(); w.cont.resume(throwing: error) }
        if let w = discoverWaiter { discoverWaiter = nil; w.timer.cancel(); central.stopScan(); w.cont.resume(throwing: error) }
        if let w = connectWaiter { connectWaiter = nil; w.timer.cancel(); w.cont.resume(throwing: error) }
        if let w = servicesWaiter { servicesWaiter = nil; w.timer.cancel(); w.cont.resume(throwing: error) }
        if let w = charsWaiter { charsWaiter = nil; w.timer.cancel(); w.cont.resume(throwing: error) }
        if let w = writeWaiter { writeWaiter = nil; w.timer.cancel(); w.cont.resume(throwing: error) }
        if let w = firmwareWaiter { firmwareWaiter = nil; w.timer.cancel(); w.cont.resume(returning: nil) }
        for (_, w) in notifyWaiters {
            w.timer.cancel()
            w.cont.resume(throwing: error)
        }
        notifyWaiters.removeAll()
    }

    private func readCharNamesOnQueue() -> String {
        chars.keys.sorted { $0.rawValue < $1.rawValue }.map { name(of: $0) }.joined(separator: ",")
    }

    private func log(_ s: String) { onLog?(s) }

    private func name(of ch: MibleChannel) -> String {
        switch ch {
        case .deviceInfo: return "DeviceInfo(0x001c)"
        case .authCtrl: return "AuthCtrl(0x0010)"
        case .authData: return "AuthData(0x0019)"
        case .cmdSend: return "CmdSend(0x001a)"
        case .cmdRecv: return "CmdRecv(0x001b)"
        }
    }

    private func macString(_ mac: [UInt8]) -> String {
        mac.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

extension CBMibleLink: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("central state=\(central.state.rawValue)")
        if central.state == .poweredOn, let w = readyWaiter {
            readyWaiter = nil
            w.timer.cancel()
            w.cont.resume(returning: ())
        } else if let err = terminalBluetoothError(central.state) {
            failAllWaitersOnQueue(err)
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        guard let sd = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] else { return }
        var adv: MiBeaconAdvertisement?
        for (_, data) in sd {
            if let parsed = MiBeaconAdvertisement.parse(serviceData: data) { adv = parsed; break }
        }
        guard let a = adv, a.mac == targetMAC else { return }

        let name = peripheral.name ?? ""
        log("命中 \(a.macString) product=0x\(String(format: "%04X", a.productId)) rssi=\(RSSI.intValue) name=\(name)")

        if let w = discoverWaiter {
            discoverWaiter = nil
            w.timer.cancel()
            central.stopScan()
            w.cont.resume(returning: peripheral)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        _isConnected = true
        log("didConnect")
        if let w = connectWaiter {
            connectWaiter = nil
            w.timer.cancel()
            w.cont.resume(returning: ())
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        _isConnected = false
        let msg = error?.localizedDescription ?? "未知连接错误"
        log("didFailToConnect \(msg)")
        if let w = connectWaiter {
            connectWaiter = nil
            w.timer.cancel()
            w.cont.resume(throwing: CBLinkError.connectFailed(msg))
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        _isConnected = false
        chars.removeAll()
        firmwareChar = nil
        let why = error?.localizedDescription ?? "设备主动断开"
        log("didDisconnect \(why)")
        failAllWaitersOnQueue(CBLinkError.connectFailed(why))
        onDisconnect?(why)
    }
}

extension CBMibleLink: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error {
            log("didDiscoverServices error \(e.localizedDescription)")
            if let w = servicesWaiter {
                servicesWaiter = nil
                w.timer.cancel()
                w.cont.resume(throwing: CBLinkError.characteristicMissing(e.localizedDescription))
            }
            return
        }
        let svc = peripheral.services?.first { $0.uuid == Self.serviceUUID }
        service = svc
        if let w = servicesWaiter {
            servicesWaiter = nil
            w.timer.cancel()
            if let svc {
                w.cont.resume(returning: svc)
            } else {
                w.cont.resume(throwing: CBLinkError.characteristicMissing("FE95 服务"))
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let e = error {
            log("didDiscoverCharacteristics error \(e.localizedDescription)")
            if let w = charsWaiter {
                charsWaiter = nil
                w.timer.cancel()
                w.cont.resume(throwing: CBLinkError.characteristicMissing(e.localizedDescription))
            }
            return
        }
        var mapped: [MibleChannel: CBCharacteristic] = [:]
        var fw: CBCharacteristic?
        for ch in service.characteristics ?? [] {
            for candidate in MibleChannel.allCases where ch.uuid == CBUUID(string: shortUUID(candidate)) {
                mapped[candidate] = ch
            }
            if ch.uuid == CBUUID(string: "0004") { fw = ch }
        }
        chars = mapped
        firmwareChar = fw
        if let w = charsWaiter {
            charsWaiter = nil
            w.timer.cancel()
            w.cont.resume(returning: ())
        }
    }

    private func shortUUID(_ ch: MibleChannel) -> String {
        String(format: "%04X", ch.rawValue)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let ch = channelOnQueue(of: characteristic) else { return }
        if let e = error { log("订阅 \(name(of: ch)) 失败 \(e.localizedDescription)") }
        guard let w = notifyWaiters.removeValue(forKey: ch) else { return }
        w.timer.cancel()
        if let e = error {
            w.cont.resume(throwing: CBLinkError.characteristicMissing(e.localizedDescription))
        } else if !characteristic.isNotifying {
            w.cont.resume(throwing: CBLinkError.characteristicMissing("未能开启 \(name(of: ch)) 通知"))
        } else {
            w.cont.resume(returning: ())
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else {
            if let fw = firmwareChar, fw == characteristic, let w = firmwareWaiter {
                firmwareWaiter = nil
                w.timer.cancel()
                w.cont.resume(returning: nil)
            }
            return
        }

        if let fw = firmwareChar, fw == characteristic {
            if let w = firmwareWaiter {
                firmwareWaiter = nil
                w.timer.cancel()
                w.cont.resume(returning: [UInt8](data))
            }
            return
        }
        guard let ch = channelOnQueue(of: characteristic) else { return }
        onNotification?(ch, [UInt8](data))
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let w = writeWaiter else { return }
        writeWaiter = nil
        w.timer.cancel()
        if let e = error {
            w.cont.resume(throwing: CBLinkError.writeFailed(e.localizedDescription))
        } else {
            w.cont.resume(returning: ())
        }
    }

    private func channelOnQueue(of characteristic: CBCharacteristic) -> MibleChannel? {
        for (ch, c) in chars where c == characteristic { return ch }
        return nil
    }
}
#endif

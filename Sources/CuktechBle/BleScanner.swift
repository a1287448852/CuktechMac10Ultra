#if canImport(CoreBluetooth)
import Foundation
@preconcurrency import CoreBluetooth
import CuktechCore

/// 扫描时看到的一台设备。macOS 拿不到 BD_ADDR，这里的 mac 是从 MiBeacon
/// 广播的 FE95 服务数据里解出来的（与 CBMibleLink 同一套解析）。
public struct BleFoundDevice: Sendable, Identifiable, Equatable {
    public let mac: [UInt8]
    public let name: String
    public let rssi: Int
    public let productId: UInt16

    public var macString: String {
        mac.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    public var id: String { macString }

    public var productIdHex: String { String(format: "0x%04X", productId) }

    /// 26126 = 0x660E，酷态科 10 号 Ultra 的产品号
    public var isCuktechCharger: Bool { productId == XiaomiClient.targetProductID }

    public init(mac: [UInt8], name: String, rssi: Int, productId: UInt16) {
        self.mac = mac
        self.name = name
        self.rssi = rssi
        self.productId = productId
    }
}

/// 扫描附近 FE95 广播设备（事件驱动等待蓝牙就绪，无轮询空转）。
public final class BleScanner: NSObject, @unchecked Sendable {
    private static let serviceUUID = CBUUID(string: "FE95")

    private let queue = DispatchQueue(label: "io.github.a1287448852.cuktechmac10ultra.scan")
    private var central: CBCentralManager!

    private var devices: [String: BleFoundDevice] = [:]
    private var stateContinuation: CheckedContinuation<Void, Error>?
    private var stateTimeoutItem: DispatchWorkItem?
    private var scanContinuation: CheckedContinuation<[BleFoundDevice], Error>?
    private var scanTimeoutItem: DispatchWorkItem?
    private var updateHandler: (@Sendable ([BleFoundDevice]) -> Void)?

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    public func scan(timeout: TimeInterval = 8,
                     onUpdate: (@Sendable ([BleFoundDevice]) -> Void)? = nil) async throws -> [BleFoundDevice] {
        try await waitUntilPoweredOn(timeout: 5)

        return try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(returning: [])
                    return
                }
                self.devices.removeAll()
                self.updateHandler = onUpdate
                self.scanContinuation = cont

                self.central.scanForPeripherals(withServices: [Self.serviceUUID],
                                                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])

                let timer = DispatchWorkItem { [weak self] in
                    self?.finishScanOnQueue()
                }
                self.scanTimeoutItem = timer
                self.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
            }
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.finishScanOnQueue()
        }
    }

    // MARK: - 内部（均在 queue 上执行）

    private func waitUntilPoweredOn(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: CBLinkError.bluetoothUnavailable("扫描器已释放"))
                    return
                }
                if let err = self.terminalError(for: self.central.state) {
                    cont.resume(throwing: err)
                    return
                }
                if self.central.state == .poweredOn {
                    cont.resume(returning: ())
                    return
                }
                self.stateContinuation = cont
                let timer = DispatchWorkItem { [weak self] in
                    guard let self, let pending = self.stateContinuation else { return }
                    self.stateContinuation = nil
                    pending.resume(throwing: CBLinkError.bluetoothUnavailable("蓝牙初始化超时"))
                }
                self.stateTimeoutItem = timer
                self.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
            }
        }
    }

    private func terminalError(for state: CBManagerState) -> CBLinkError? {
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

    private func sortedDevices() -> [BleFoundDevice] {
        devices.values.sorted { $0.rssi > $1.rssi }
    }

    private func finishScanOnQueue() {
        scanTimeoutItem?.cancel()
        scanTimeoutItem = nil
        central.stopScan()
        updateHandler = nil
        guard let cont = scanContinuation else { return }
        scanContinuation = nil
        cont.resume(returning: sortedDevices())
    }
}

extension BleScanner: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            stateTimeoutItem?.cancel()
            stateTimeoutItem = nil
            if let cont = stateContinuation {
                stateContinuation = nil
                cont.resume(returning: ())
            }
        } else if let err = terminalError(for: central.state) {
            stateTimeoutItem?.cancel()
            stateTimeoutItem = nil
            if let cont = stateContinuation {
                stateContinuation = nil
                cont.resume(throwing: err)
            }
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let sections = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        guard let payload = sections?[Self.serviceUUID],
              let adv = MiBeaconAdvertisement.parse(serviceData: payload) else { return }

        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let device = BleFoundDevice(mac: adv.mac, name: name, rssi: RSSI.intValue, productId: adv.productId)
        devices[device.id] = device
        updateHandler?(sortedDevices())
    }
}
#endif

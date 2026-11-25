import Foundation

/// 设备上的「息屏时间」（SIID=2 PIID=6）。
///
/// 取值和文案对不上号是米家的历史包袱：1=5 分钟、5=1 分钟，别按顺序猜。
/// 文档见 `docs/protocol-research.md` 第 7 节。
public enum ScreenTimeout: Int, CaseIterable, Sendable {
    case oneMinute = 5
    case fiveMinutes = 1
    case tenMinutes = 2
    case thirtyMinutes = 3
    case always = 4

    public var label: String {
        switch self {
        case .oneMinute: return "1 分"
        case .fiveMinutes: return "5 分"
        case .tenMinutes: return "10 分"
        case .thirtyMinutes: return "30 分"
        case .always: return "常亮"
        }
    }

    /// 给界面写一句人话解释用。
    public var hint: String {
        switch self {
        case .always: return "屏幕一直亮着，耗电也最容易烧屏"
        default: return "\(label)钟没有操作就熄灭屏幕"
        }
    }
}

/// PIID 21 的协议开关位（32 位位掩码）。
///
///   C1 = bit0 PD | bit1 PPS | bit2 UFCS | bit3 保留
///   C2 = bit8 PD | bit9 PPS | bit10 UFCS | bit11 保留
///   C3 = bit16 UFCS | bit17 SCP
///   A  = bit24 UFCS | bit25 SCP
///
/// 保留位（bit3 / bit11）固件固定为 1，读写时一律「读-改-写」，不自己造值。
public enum ProtocolCap: String, CaseIterable, Sendable {
    case pd
    case pps
    case ufcs
    case scp

    public var label: String {
        switch self {
        case .pd: return "PD"
        case .pps: return "PPS"
        case .ufcs: return "UFCS"
        case .scp: return "SCP"
        }
    }

    /// 每个口到底支持哪几种，靠这张表决定界面上画几个开关。
    public static func available(onPort port: Int) -> [ProtocolCap] {
        switch port {
        case 1, 2: return [.pd, .pps, .ufcs]
        case 3, 4: return [.ufcs, .scp]
        default: return []
        }
    }

    /// 端口（1..4）+ 协议 → 位偏移。不支持的组合返回 nil。
    public func bit(port: Int) -> UInt32? {
        switch (port, self) {
        case (1, .pd): return 0
        case (1, .pps): return 1
        case (1, .ufcs): return 2
        case (2, .pd): return 8
        case (2, .pps): return 9
        case (2, .ufcs): return 10
        case (3, .ufcs): return 16
        case (3, .scp): return 17
        case (4, .ufcs): return 24
        case (4, .scp): return 25
        default: return nil
        }
    }
}

/// 设备当前协商到的快充协议（PIID 17 = C1/C2，PIID 18 = C3/A）。
///
/// 一个 u32 塞两路：`[高口协议][高口功率W][低口协议][低口功率W]`。
/// 协议号是米家那套（0 空闲、7 PD、8/9 PPS、10 UFCS…），C3/A 偶尔直接给
/// MiOT 原始码（0x70 QC、0x80 PD），`ChargeProtocol.name` 一并映射。
public struct Negotiation: Equatable, Sendable {
    /// 协议号，0 = 没在协商。
    public var code: Int
    /// 协商功率（W），0 = 不知道。
    public var watts: Int

    public init(code: Int, watts: Int) {
        self.code = code
        self.watts = watts
    }

    public var isEmpty: Bool { code == 0 && watts == 0 }

    /// 「PD 65W」/「—」
    public var text: String {
        if code == 0 { return "—" }
        let name = ChargeProtocol.name(code)
        return watts > 0 ? "\(name) \(watts)W" : name
    }

    /// 把一个 u32 拆成高低两路。
    public static func split(_ v: UInt32) -> (high: Negotiation, low: Negotiation) {
        let highCode = Int((v >> 24) & 0xFF)
        let highW = Int((v >> 16) & 0xFF)
        let lowCode = Int((v >> 8) & 0xFF)
        let lowW = Int(v & 0xFF)
        // 功率字节是 0 通常意味着这一路空闲，协议字节也多半是 0；功率 255 是「未知」
        return (Negotiation(code: highCode, watts: highW >= 255 ? 0 : highW),
                Negotiation(code: lowCode, watts: lowW >= 255 ? 0 : lowW))
    }
}

public enum ChargeProtocol {
    /// 米家协议号 → 人看的名字。
    public static func name(_ code: Int) -> String {
        switch code {
        case 0: return "空闲"
        case 1, 2: return "5V"
        case 3: return "QC"
        case 4: return "AFC"
        case 5: return "FCP"
        case 6: return "SCP"
        case 7: return "PD"
        case 8, 9: return "PPS"
        case 10: return "UFCS"
        // C3 / A 口可能回 MiOT 原始码
        case 0x60: return "USB-A"
        case 0x70: return "QC"
        case 0x80: return "PD"
        default: return String(format: "0x%02X", code)
        }
    }
}

/// 每口自动断电的倒计时选项（PIID 9~12，单位分钟，0 = 关闭）。
public enum CountdownOption {
    public static let all: [Int] = [0, 15, 30, 60, 120, 240]

    public static func label(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "关闭"
        case 60: return "1 小时"
        case 120: return "2 小时"
        case 240: return "4 小时"
        default: return "\(minutes) 分钟"
        }
    }
}

/// 从设备读回来的一整份设置。
///
/// 全部用 optional：这些属性不是每个固件都答得上来（尤其倒计时），
/// 读不到就留 nil，界面上显示「—」并禁用，**绝不**按 0 兜底 ——
/// 把「读不到」当成「关着」，用户一点就不知道写进去了什么。
public struct DeviceSettings: Equatable, Sendable {
    public var screenTimeout: Int?        // PIID 6
    public var idleScreenOff: Bool?       // PIID 19
    public var screenLock: Bool?          // PIID 20
    public var usbALowCurrent: Bool?      // PIID 15
    public var language: Int?             // PIID 13
    public var protocolFlags: UInt32?     // PIID 21
    public var countdowns: [Int?] = [nil, nil, nil, nil]      // PIID 9..12（分钟）
    public var negotiations: [Negotiation?] = [nil, nil, nil, nil] // PIID 17/18
    public var at: Date = .distantPast

    public init() {}

    /// 读到了几项（界面用来区分「设备没答」和「确实是关」）。
    public var loadedCount: Int {
        var n = 0
        if screenTimeout != nil { n += 1 }
        if idleScreenOff != nil { n += 1 }
        if screenLock != nil { n += 1 }
        if usbALowCurrent != nil { n += 1 }
        if language != nil { n += 1 }
        if protocolFlags != nil { n += 1 }
        n += countdowns.filter { $0 != nil }.count
        return n
    }

    /// PIID 21 里某口的某协议现在开着没有。读不到整份掩码时返回 nil。
    public func protocolOn(_ cap: ProtocolCap, port: Int) -> Bool? {
        guard let flags = protocolFlags, let bit = cap.bit(port: port) else { return nil }
        return (flags & (UInt32(1) << bit)) != 0
    }

    public var screenTimeoutCase: ScreenTimeout? {
        screenTimeout.flatMap(ScreenTimeout.init(rawValue:))
    }

    public var languageName: String {
        switch language {
        case 0: return "English"
        case 1: return "中文"
        default: return "—"
        }
    }
}

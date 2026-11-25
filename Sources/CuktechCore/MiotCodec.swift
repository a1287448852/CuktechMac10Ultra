import Foundation

/// MIoT BLE 的五条 GATT 通道，对应服务 0xFE95 下的特征。
public enum MibleChannel: UInt16, CaseIterable, Sendable {
    case deviceInfo = 0x001c
    case authCtrl   = 0x0010
    case authData   = 0x0019
    case cmdSend    = 0x001a
    case cmdRecv    = 0x001b
}

/// 传输层抽象：把 CoreBluetooth 与测试桩隔离开。
/// 只做「写」和「订阅」，收到的通知由实现方交给 MibleSession.handleNotification。
public protocol MibleLink: AnyObject, Sendable {
    func write(_ channel: MibleChannel, _ data: [UInt8]) async throws
    func subscribe(_ channel: MibleChannel) async throws
    func unsubscribe(_ channel: MibleChannel) async throws
}

/// 解析后的 MiOT/Spec 响应帧。
public struct MiotMessage: Sendable, Equatable {
    public var raw: [UInt8] = []
    /// pt[4]: 0x01 = SET ACK, 0x03 = GET 结果, 0x04 = 主动推送
    public var opcode: UInt8 = 0
    public var seq: UInt8 = 0
    public var siid: UInt8 = 0
    public var piid: UInt8 = 0
    public var errorCode: Int = 0
    public var valueLength: Int = 0
    public var typeId: UInt8 = 0
    public var valueBytes: [UInt8] = []

    public init() {}
    public init(raw: [UInt8], opcode: UInt8, seq: UInt8, siid: UInt8, piid: UInt8,
                errorCode: Int = 0, valueLength: Int = 0, typeId: UInt8 = 0, valueBytes: [UInt8] = []) {
        self.raw = raw
        self.opcode = opcode
        self.seq = seq
        self.siid = siid
        self.piid = piid
        self.errorCode = errorCode
        self.valueLength = valueLength
        self.typeId = typeId
        self.valueBytes = valueBytes
    }

    public var isPush: Bool { opcode == 0x04 }
    public var isSetAck: Bool { opcode == 0x01 }
    public var isGetResult: Bool { opcode == 0x03 }

    /// 长度 >= 4 按 LE u32 取值，2 字节 LE u16，单字节直取，空的返回 nil。
    public var uintValue: UInt32? {
        switch valueBytes.count {
        case 0: return nil
        case 1: return UInt32(valueBytes[0])
        case 2: return UInt32(valueBytes[0]) | (UInt32(valueBytes[1]) << 8)
        case let n where n >= 4:
            return UInt32(valueBytes[0])
                | (UInt32(valueBytes[1]) << 8)
                | (UInt32(valueBytes[2]) << 16)
                | (UInt32(valueBytes[3]) << 24)
        default: return UInt32(valueBytes[valueBytes.count - 1])
        }
    }
}

/// MiOT TLV 编解码。帧格式（对齐米家 SpecWriteChannelManager）：
///   [total_len][0x20][seq][0x00][opcode][0x01][siid][piid_lo][piid_hi][tl_lo][tl_hi][value...]
///   total_len = 11 + value.count，tl = (type_id << 12) | value.count
///   type_id: 1=UINT8, 3=UINT16, 5=UINT32
public enum MiotCodec {
    public static let opSet: UInt8 = 0x00
    public static let opGet: UInt8 = 0x02

    public static func buildCommand(seq: UInt8, siid: UInt8, piid: UInt16, value: UInt32?) -> [UInt8] {
        let opcode: UInt8
        let typeId: UInt8
        let valueBytes: [UInt8]

        if let v = value {
            opcode = opSet
            if v <= 0xFF {
                typeId = 1
                valueBytes = [UInt8(v & 0xFF)]
            } else {
                typeId = 5
                valueBytes = [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
            }
        } else {
            opcode = opGet
            typeId = 1
            valueBytes = [0x00]
        }

        let byteLen = valueBytes.count
        let tl = (Int(typeId) << 12) | byteLen
        let totalLen = 11 + byteLen

        var frame = [UInt8](repeating: 0, count: 11 + byteLen)
        frame[0] = UInt8(totalLen & 0xFF)
        frame[1] = 0x20
        frame[2] = seq
        frame[3] = 0x00
        frame[4] = opcode
        frame[5] = 0x01
        frame[6] = siid
        frame[7] = UInt8(piid & 0xFF)
        frame[8] = UInt8((piid >> 8) & 0xFF)
        frame[9] = UInt8(tl & 0xFF)
        frame[10] = UInt8((tl >> 8) & 0xFF)
        for (i, b) in valueBytes.enumerated() { frame[11 + i] = b }
        return frame
    }

    public static func parse(_ pt: [UInt8]) -> MiotMessage? {
        if pt.count < 8 { return nil }
        let valueLen = pt.count > 11 ? Int(pt[11]) : 1
        let valueStart = 13
        let available = max(0, pt.count - valueStart)
        let len = min(valueLen, available)
        var val: [UInt8] = []
        if len > 0 { val = Array(pt[valueStart..<(valueStart + len)]) }

        return MiotMessage(
            raw: pt,
            opcode: pt[4],
            seq: pt[2],
            siid: pt[6],
            piid: pt[7],
            errorCode: pt.count > 10 ? (Int(pt[9]) << 8 | Int(pt[10])) : 0,
            valueLength: valueLen,
            typeId: pt.count > 12 ? pt[12] : 0,
            valueBytes: val)
    }
}

/// 端口数据（SIID=2, PIID 1..4 = C1/C2/C3/A），四字节布局：
///   [0]=状态 0x00 空闲 / 0x01 单口 / 0x11 C3+A 合并, [1]=code（PDO 档位/硬件状态码）,
///   [2]=电流 ×0.1A, [3]=电压 ×0.1V
public struct PortData: Sendable, Equatable {
    public var state: UInt8
    public var code: UInt8
    public var current: Double   // A
    public var voltage: Double   // V

    public init(state: UInt8, code: UInt8, current: Double, voltage: Double) {
        self.state = state
        self.code = code
        self.current = current
        self.voltage = voltage
    }

    /// 与 Windows 版对齐：C# 是 Math.Round(v*c, 1)，即「四舍六入五成双」。
    /// 用 half-away 的 rounded() 会在 20.1V×2.5A=50.25W 这种正好在中点的值上算出 50.3，
    /// 而 Windows 版显示 50.2，两端不一致。
    public var power: Double { (voltage * current * 10).rounded(.toNearestOrEven) / 10 }
    public var isIdle: Bool { state == 0x00 }

    public static func parse(_ valueBytes: [UInt8]?) -> PortData? {
        guard let b = valueBytes, b.count >= 4 else { return nil }
        return PortData(state: b[0], code: b[1], current: Double(b[2]) / 10.0, voltage: Double(b[3]) / 10.0)
    }

    /// 端口序号 1..4 对应的名字：C1 / C2 / C3 / A。
    public static func portName(_ index: Int) -> String {
        index == 4 ? "A" : "C\(index)"
    }
}

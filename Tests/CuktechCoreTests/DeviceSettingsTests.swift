import XCTest
@testable import CuktechCore

/// 设置项的位偏移和拆包都直接对着协议文档写的，错一位就会关掉别的口的协议，
/// 所以这几点必须有测试盯着。
final class DeviceSettingsTests: XCTestCase {

    func testScreenTimeoutRawValuesFollowFirmwareOrder() {
        // 1=5 分、5=1 分 —— 顺序是反的，写错就变成「设 1 分钟实际 5 分钟」
        XCTAssertEqual(ScreenTimeout.oneMinute.rawValue, 5)
        XCTAssertEqual(ScreenTimeout.fiveMinutes.rawValue, 1)
        XCTAssertEqual(ScreenTimeout.tenMinutes.rawValue, 2)
        XCTAssertEqual(ScreenTimeout.thirtyMinutes.rawValue, 3)
        XCTAssertEqual(ScreenTimeout.always.rawValue, 4)
        XCTAssertNil(ScreenTimeout(rawValue: 0))
    }

    func testProtocolCapBitsMatchProtocolDoc() {
        XCTAssertEqual(ProtocolCap.pd.bit(port: 1), 0)
        XCTAssertEqual(ProtocolCap.pps.bit(port: 1), 1)
        XCTAssertEqual(ProtocolCap.ufcs.bit(port: 1), 2)
        XCTAssertEqual(ProtocolCap.pd.bit(port: 2), 8)
        XCTAssertEqual(ProtocolCap.pps.bit(port: 2), 9)
        XCTAssertEqual(ProtocolCap.ufcs.bit(port: 2), 10)
        XCTAssertEqual(ProtocolCap.ufcs.bit(port: 3), 16)
        XCTAssertEqual(ProtocolCap.scp.bit(port: 3), 17)
        XCTAssertEqual(ProtocolCap.ufcs.bit(port: 4), 24)
        XCTAssertEqual(ProtocolCap.scp.bit(port: 4), 25)
        // C1/C2 没有 SCP，C3/A 没有 PD/PPS
        XCTAssertNil(ProtocolCap.scp.bit(port: 1))
        XCTAssertNil(ProtocolCap.pd.bit(port: 3))
        XCTAssertNil(ProtocolCap.pd.bit(port: 9))
    }

    func testAvailableCapsPerPort() {
        XCTAssertEqual(ProtocolCap.available(onPort: 1), [.pd, .pps, .ufcs])
        XCTAssertEqual(ProtocolCap.available(onPort: 2), [.pd, .pps, .ufcs])
        XCTAssertEqual(ProtocolCap.available(onPort: 3), [.ufcs, .scp])
        XCTAssertEqual(ProtocolCap.available(onPort: 4), [.ufcs, .scp])
        XCTAssertTrue(ProtocolCap.available(onPort: 0).isEmpty)
    }

    func testProtocolOnReadsFlags() {
        var s = DeviceSettings()
        XCTAssertNil(s.protocolOn(.pd, port: 1), "没读到掩码时必须是 nil，不能当成关")

        // C1: PD+PPS+保留位；C2: UFCS；C3: SCP；A: UFCS
        s.protocolFlags = (1 << 0) | (1 << 1) | (1 << 3)
            | (1 << 10) | (1 << 17) | (1 << 24)
        XCTAssertEqual(s.protocolOn(.pd, port: 1), true)
        XCTAssertEqual(s.protocolOn(.pps, port: 1), true)
        XCTAssertEqual(s.protocolOn(.ufcs, port: 1), false)
        XCTAssertEqual(s.protocolOn(.pd, port: 2), false)
        XCTAssertEqual(s.protocolOn(.ufcs, port: 2), true)
        XCTAssertEqual(s.protocolOn(.scp, port: 3), true)
        XCTAssertEqual(s.protocolOn(.ufcs, port: 3), false)
        XCTAssertEqual(s.protocolOn(.ufcs, port: 4), true)
        XCTAssertEqual(s.protocolOn(.scp, port: 4), false)
    }

    func testNegotiationSplit() {
        // [C1_proto][C1_W][C2_proto][C2_W] = PD 65W / 空闲
        let v: UInt32 = (7 << 24) | (65 << 16) | (0 << 8) | 0
        let p = Negotiation.split(v)
        XCTAssertEqual(p.high.code, 7)
        XCTAssertEqual(p.high.watts, 65)
        XCTAssertEqual(p.high.text, "PD 65W")
        XCTAssertTrue(p.low.isEmpty)

        // C3 = UFCS 30W，A = 空闲
        let v2: UInt32 = (10 << 24) | (30 << 16)
        let q = Negotiation.split(v2)
        XCTAssertEqual(q.high.text, "UFCS 30W")
        XCTAssertEqual(q.low.text, "—")
    }

    func testProtocolNames() {
        XCTAssertEqual(ChargeProtocol.name(0), "空闲")
        XCTAssertEqual(ChargeProtocol.name(7), "PD")
        XCTAssertEqual(ChargeProtocol.name(8), "PPS")
        XCTAssertEqual(ChargeProtocol.name(10), "UFCS")
        // C3/A 可能回 MiOT 原始码
        XCTAssertEqual(ChargeProtocol.name(0x80), "PD")
        XCTAssertEqual(ChargeProtocol.name(0x70), "QC")
        XCTAssertEqual(ChargeProtocol.name(0x1F), "0x1F")
    }

    func testCountdownLabels() {
        XCTAssertEqual(CountdownOption.label(0), "关闭")
        XCTAssertEqual(CountdownOption.label(15), "15 分钟")
        XCTAssertEqual(CountdownOption.label(60), "1 小时")
        XCTAssertEqual(CountdownOption.label(120), "2 小时")
    }

    func testLoadedCountIgnoresUnknown() {
        var s = DeviceSettings()
        XCTAssertEqual(s.loadedCount, 0)
        s.screenTimeout = 4
        s.idleScreenOff = false     // 「确实是关」也要算读到
        s.countdowns[2] = 30
        XCTAssertEqual(s.loadedCount, 3)
    }
}

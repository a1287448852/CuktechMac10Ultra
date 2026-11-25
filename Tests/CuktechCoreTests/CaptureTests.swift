import XCTest
@testable import CuktechCore

final class CaptureTests: XCTestCase {
    private func sample(_ v: Double, _ a: Double, state: UInt8 = 0x01) -> PortData {
        PortData(state: state, code: 0, current: a, voltage: v)
    }

    /// 20V × 3A 持续 60 秒 → 正好 1Wh（20*3=60W，60W×1h/60 = 1Wh）。
    func testSteadyLoad() {
        var acc = CaptureAccumulator()
        let t0 = Date()
        for i in 0...60 {
            acc.add(sample(20.0, 3.0), at: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(acc.energyWh, 1.0, accuracy: 0.02)
        XCTAssertEqual(acc.averagePower, 60.0, accuracy: 1.0)
        XCTAssertEqual(acc.effectiveSeconds, 60.0, accuracy: 0.01)
        XCTAssertEqual(acc.voltageChanges, 0)
        XCTAssertEqual(acc.sampleCount, 61)
    }

    /// 5V×2A 充 10 秒后切到 20V×2A 再充 10 秒。
    /// 采样点 0...10 是 5V 段、11...20 是 20V 段：10 个 5V 间隔 + 1 个跨档间隔 + 9 个 20V 间隔。
    /// 跨档那 1 秒按跳变前的 10W 记（保守，少算 30W·1s ≈ 0.008Wh），
    /// 所以是 (10×10 + 10×1 + 40×9)/3600 = 0.1306Wh。
    /// 关键是不能把它算成梯形——那样跨档那秒会按 25W，结果比 0.14 还高。
    func testVoltageStepIsNotAveraged() {
        var acc = CaptureAccumulator()
        let t0 = Date()
        for i in 0...10 {
            acc.add(sample(5.0, 2.0), at: t0.addingTimeInterval(Double(i)))
        }
        for i in 11...20 {
            acc.add(sample(20.0, 2.0), at: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(acc.energyWh, 0.1306, accuracy: 0.002)
        XCTAssertEqual(acc.voltageChanges, 1)
        XCTAssertEqual(acc.minVoltage ?? 0, 5.0, accuracy: 0.001)
        XCTAssertEqual(acc.maxVoltage ?? 0, 20.0, accuracy: 0.001)
    }

    /// 空载的秒不参与积分，也不算有效时长。
    func testIdleDoesNotCount() {
        var acc = CaptureAccumulator()
        let t0 = Date()
        for i in 0...10 { acc.add(sample(9.0, 2.0), at: t0.addingTimeInterval(Double(i))) }
        for i in 11...50 { acc.add(sample(0, 0, state: 0x00), at: t0.addingTimeInterval(Double(i))) }
        XCTAssertEqual(acc.energyWh, 0.05, accuracy: 0.005)   // 18W*10s/3600
        XCTAssertEqual(acc.effectiveSeconds, 10.0, accuracy: 0.01)
        XCTAssertEqual(acc.averagePower, 18.0, accuracy: 0.5)
        XCTAssertEqual(acc.peakPower, 18.0, accuracy: 0.01)
    }

    /// 中间断了一大截（重连），这段不能凭空算电量。
    func testGapIsSkipped() {
        var acc = CaptureAccumulator()
        let t0 = Date()
        acc.add(sample(20.0, 3.0), at: t0)
        acc.add(sample(20.0, 3.0), at: t0.addingTimeInterval(120))  // 隔了 2 分钟
        XCTAssertEqual(acc.energyWh, 0, accuracy: 0.0001)
        XCTAssertEqual(acc.effectiveSeconds, 0, accuracy: 0.0001)
    }

    /// 0.1V 的读数抖动不该当成换档。
    func testSmallJitterIsSameRail() {
        var acc = CaptureAccumulator()
        let t0 = Date()
        acc.add(sample(20.0, 3.0), at: t0)
        acc.add(sample(20.1, 3.0), at: t0.addingTimeInterval(1))
        XCTAssertEqual(acc.voltageChanges, 0)
        XCTAssertEqual(acc.energyWh, 60.15 / 3600, accuracy: 0.0005)
    }

    func testResultFormatting() {
        var acc = CaptureAccumulator()
        let t0 = Date()
        for i in 0...72 { acc.add(sample(9.0, 2.0), at: t0.addingTimeInterval(Double(i))) }
        let r = CaptureResult(portIndex: 1, startedAt: t0,
                              endedAt: t0.addingTimeInterval(102),
                              stats: acc, reason: .noLoad, firmware: "2.1.2_0079")
        XCTAssertEqual(r.portName, "C1")
        XCTAssertEqual(r.energyText, "0.36")
        XCTAssertEqual(r.averageText, "18.0")
        XCTAssertEqual(CaptureResult.duration(72), "1 分 12 秒")
        XCTAssertEqual(CaptureResult.duration(45), "45 秒")
        XCTAssertEqual(CaptureResult.duration(3720), "1 小时 02 分")
        XCTAssertTrue(r.summaryText.contains("充入电量：0.36 Wh"))
    }
}

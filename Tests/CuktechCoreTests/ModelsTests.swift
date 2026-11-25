import XCTest
@testable import CuktechCore

final class ModelsTests: XCTestCase {
    func testWattBuckets() {
        XCTAssertEqual(WattStyle.port(0), WattStyle.dim)
        XCTAssertEqual(WattStyle.port(0.04), WattStyle.dim)
        XCTAssertEqual(WattStyle.port(0.1), WattStyle.cool)
        XCTAssertEqual(WattStyle.port(20), WattStyle.ok)
        XCTAssertEqual(WattStyle.port(40), WattStyle.warn)
        XCTAssertEqual(WattStyle.port(80), WattStyle.bad)
    }

    func testTotalBuckets() {
        XCTAssertEqual(WattStyle.total(0), WattStyle.dim)
        XCTAssertEqual(WattStyle.total(6.0), WattStyle.cool)
        XCTAssertEqual(WattStyle.total(20), WattStyle.ok)
        XCTAssertEqual(WattStyle.total(60), WattStyle.warn)
        XCTAssertEqual(WattStyle.total(100), WattStyle.bad)
    }

    func testWattTextFormat() {
        XCTAssertEqual(WattStyle.text(6.0), "6.0W")
        XCTAssertEqual(WattStyle.text(99.9), "99.9W")
        XCTAssertEqual(WattStyle.text(120.0), "120W")
    }

    func testSnapshotSumsTotal() {
        var snap = DeviceSnapshot()
        snap.connected = true
        snap.ports[0].apply(PortData(state: 0x01, code: 0x0A, current: 2.0, voltage: 20.1))
        snap.ports[2].apply(PortData(state: 0x01, code: 0x05, current: 0.5, voltage: 5.0))
        XCTAssertEqual(snap.totalWatts, 42.7, accuracy: 0.001)
        XCTAssertEqual(snap.totalText, "42.7W")
        XCTAssertTrue(snap.headline.contains("已连接"))
        XCTAssertTrue(snap.headline.contains("总输出 42.7W"))
    }

    func testIdlePortDetail() {
        var slot = PortSlot(index: 1)
        XCTAssertEqual(slot.detail, "无应答")
        slot.apply(PortData(state: 0x00, code: 0, current: 0, voltage: 0))
        XCTAssertEqual(slot.detail, "空载")
        slot.enabled = false
        XCTAssertEqual(slot.detail, "已断电")
    }

    func testSceneNames() {
        XCTAssertEqual(SceneMode.name(1), "AI")
        XCTAssertEqual(SceneMode.name(3), "单口")
        XCTAssertEqual(SceneMode.name(9), "模式 9")
    }
}

#if canImport(CoreBluetooth)
import XCTest
@testable import CuktechBle

/// 0xFE95 广播解析的回归测试。
///
/// 这组用例是从真机抓的字节，起因是一个真实 bug：解析函数原先要求 payload 前两字节是
/// `95 FE`（服务 UUID 头），但 macOS 通过 `CBAdvertisementDataServiceDataKey` 交给我们的是
/// **裸 payload**，于是 guard 永远失败、扫描结果恒为空，表现为「扫不到设备 / 菜单栏一直是 —」。
final class MiBeaconAdvertisementTests: XCTestCase {

    /// CUKTECH 10 号 Ultra（MAC 3C:CD:73:31:8B:30，productId 0x660E）的广播原样。
    /// 布局：帧控制(2, LE) | productId(2, LE) | 计数(1) | MAC(6, 小端)
    private let bare: [UInt8] = [
        0x10, 0x59,              // 帧控制 0x5910：bit4 置位 = 带 MAC
        0x0E, 0x66,              // productId 0x660E
        0x00,                    // 帧计数
        0x30, 0x8B, 0x31, 0x73, 0xCD, 0x3C,   // MAC，小端
    ]

    func testParsesBarePayload() {
        let adv = MiBeaconAdvertisement.parse(serviceData: Data(bare))
        XCTAssertNotNil(adv, "裸 payload 必须能解析（这就是当初挂掉的那条路径）")
        XCTAssertEqual(adv?.macString, "3C:CD:73:31:8B:30")
        XCTAssertEqual(adv?.productId, 0x660E)
    }

    func testParsesPayloadWithServiceUUIDPrefix() {
        // 有的环境会把 2 字节 UUID 头一起给过来，这种也得认
        let adv = MiBeaconAdvertisement.parse(serviceData: Data([0x95, 0xFE] + bare))
        XCTAssertEqual(adv?.macString, "3C:CD:73:31:8B:30")
        XCTAssertEqual(adv?.productId, 0x660E)
    }

    func testRejectsWhenMacBitIsClear() {
        var noMac = bare
        noMac[0] = 0x00    // 帧控制 0x5900：bit4 = 0，后面不带 MAC
        XCTAssertNil(MiBeaconAdvertisement.parse(serviceData: Data(noMac)))
    }

    func testRejectsTruncatedPayload() {
        XCTAssertNil(MiBeaconAdvertisement.parse(serviceData: Data(bare.prefix(8))))
        XCTAssertNil(MiBeaconAdvertisement.parse(serviceData: Data()))
    }
}
#endif

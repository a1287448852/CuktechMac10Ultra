import XCTest
@testable import CuktechCore

final class MiotCodecTests: XCTestCase {

    func testGetCommandFrame() {
        let f = MiotCodec.buildCommand(seq: 1, siid: 2, piid: 1, value: nil)
        // total_len=12, 0x20, seq=1, 0, opcode=0x02(GET), 0x01, siid=2, piid=1,0, tl=0x1001, value=0
        XCTAssertEqual(f, [12, 0x20, 1, 0, 0x02, 0x01, 2, 1, 0, 0x01, 0x10, 0x00])
    }

    func testSetCommandSmallValueUsesUInt8() {
        let f = MiotCodec.buildCommand(seq: 7, siid: 3, piid: 5, value: 0x0F)
        XCTAssertEqual(f.count, 12)
        XCTAssertEqual(f[4], MiotCodec.opSet)
        XCTAssertEqual(f[9], 0x01)   // tl lo: typeId 1
        XCTAssertEqual(f[10], 0x10)  // tl hi
        XCTAssertEqual(f[11], 0x0F)
    }

    func testSetCommandBigValueUsesUInt32LE() {
        let f = MiotCodec.buildCommand(seq: 2, siid: 3, piid: 5, value: 300)
        XCTAssertEqual(f.count, 15)
        // tl = (typeId << 12) | valueLen = (5 << 12) | 4 = 0x5004
        XCTAssertEqual(f[9], 0x04)   // tl lo: len 4
        XCTAssertEqual(f[10], 0x50)  // tl hi: typeId 5
        XCTAssertEqual(Array(f[11...]), [0x2C, 0x01, 0x00, 0x00])
    }

    func testParsePortPushFrame() {
        // [len][0x20][seq][0][opcode=0x04 push][1][siid=2][piid=1][0][tl=0x4001][type=0? ] ...
        var f: [UInt8] = [17, 0x20, 0x05, 0x00, 0x04, 0x01, 0x02, 0x01, 0x00, 0x01, 0x10, 0x04, 0x05]
        f += [0x01, 0x0A, 0x19, 0xC9]
        let msg = MiotCodec.parse(f)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.opcode, 0x04)
        XCTAssertTrue(msg?.isPush == true)
        XCTAssertEqual(msg?.siid, 2)
        XCTAssertEqual(msg?.piid, 1)

        let port = PortData.parse(msg?.valueBytes)
        XCTAssertNotNil(port)
        XCTAssertEqual(port?.state, 0x01)
        XCTAssertEqual(port?.code, 0x0A)
        XCTAssertEqual(port?.current ?? 0, 2.5, accuracy: 0.0001)
        XCTAssertEqual(port?.voltage ?? 0, 20.1, accuracy: 0.0001)
        XCTAssertEqual(port?.power ?? 0, 50.2, accuracy: 0.0001)
        XCTAssertEqual(port?.isIdle, false)
    }

    func testIdlePortPowerIsZero() {
        let port = PortData.parse([0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(port?.isIdle, true)
        XCTAssertEqual(port?.power, 0)
    }

    func testParseTooShortReturnsNil() {
        XCTAssertNil(MiotCodec.parse([1, 2, 3]))
    }

    func testUIntValueWidths() {
        var m = MiotMessage()
        m.valueBytes = [0x34, 0x12]
        XCTAssertEqual(m.uintValue, 0x1234)
        m.valueBytes = [0x78, 0x56, 0x34, 0x12]
        XCTAssertEqual(m.uintValue, 0x12345678)
        m.valueBytes = []
        XCTAssertNil(m.uintValue)
    }

    func testPortNames() {
        XCTAssertEqual(PortData.portName(1), "C1")
        XCTAssertEqual(PortData.portName(3), "C3")
        XCTAssertEqual(PortData.portName(4), "A")
    }
}

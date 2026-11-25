import Foundation

extension Array where Element == UInt8 {
    /// "0011aabb" -> [0x00, 0x11, 0xaa, 0xbb]
    public static func fromHex(_ string: String) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2, limitedBy: string.endIndex) ?? string.endIndex
            let pair = String(string[index..<next])
            if let byte = UInt8(pair, radix: 16) { out.append(byte) }
            index = next
        }
        return out
    }

    public var hexString: String {
        var out = String()
        out.reserveCapacity(count * 2)
        for byte in self { out += String(format: "%02x", byte) }
        return out
    }
}

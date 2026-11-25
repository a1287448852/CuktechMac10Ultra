import Foundation

/// 极简 JSON 值类型。
///
/// 为什么不用 JSONSerialization：小米返回的响应里 `code` 有时是数字有时是字符串，
/// 日志要打原始文本（`GetRawText`），拼请求时还要把 userId 当「JSON token」写回，
/// 这些都要求保留数字的原始写法。自己写一个几百行的解析器反而最省事，Linux 也能跑单测。
public indirect enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    /// 数字保留原始文本（`"0"` 和 `"0.0"` 不能混），取数值时再解析。
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - 取值

    /// 字符串字段：字符串原样，数字取原始文本，布尔取 true/false（对齐 C# `ToFlatString`）。
    public func flatString() -> String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        case .null: return ""
        case .array, .object: return rawText()
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .number(let n): return Int(n) ?? Int(Double(n) ?? 0)
        case .string(let s): return Int(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let n): return Double(n)
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// 宽松布尔：true / 非 0 数字 / "true" / "True" / "1"（对齐 C# `ToBool`）。
    public var boolValue: Bool {
        switch self {
        case .bool(let b): return b
        case .number(let n): return Double(n).map { $0 != 0 } ?? false
        case .string(let s): return s == "true" || s == "True" || s == "1"
        default: return false
        }
    }

    /// 下标：对象取字段，其它一律 nil。
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// 下标：数组取元素。
    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var isObject: Bool { objectValue != nil }
    public var isArray: Bool { arrayValue != nil }

    // MARK: - 序列化

    /// 序列化回紧凑 JSON（对应 `GetRawText`）。键顺序按字典序，保证可测。
    public func rawText() -> String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return JSONValue.escape(s)
        case .array(let a):
            return "[" + a.map { $0.rawText() }.joined(separator: ",") + "]"
        case .object(let o):
            let body = o.keys.sorted().map { JSONValue.escape($0) + ":" + o[$0]!.rawText() }
            return "{" + body.joined(separator: ",") + "}"
        }
    }

    /// 把字符串当成 JSON token 写回（纯数字不加引号，其它加引号）——对齐 Python `json.dumps`。
    public static func token(_ raw: String?) -> String {
        guard let raw else { return "null" }
        if Int(raw) != nil { return raw }
        return escape(raw)
    }

    static func escape(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: - 解析

    public enum ParseError: Error, CustomStringConvertible {
        case unexpectedEnd
        case unexpectedCharacter(Character, at: Int)
        case badEscape

        public var description: String {
            switch self {
            case .unexpectedEnd: return "JSON 意外结束"
            case .unexpectedCharacter(let c, let i): return "JSON 第 \(i) 字节出现意外字符 \(c)"
            case .badEscape: return "JSON 转义序列非法"
            }
        }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(bytes: Array(text.utf8))
        let value = try parser.parseValue()
        parser.skipWhitespace()
        return value
    }

    /// 解析失败返回 nil（对齐 C# `ParseFlatJson` 的容错）。
    public static func parseOrNil(_ text: String) -> JSONValue? {
        try? parse(text)
    }

    struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipWhitespace() {
            while i < bytes.count {
                let c = bytes[i]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 } else { break }
            }
        }

        mutating func parseValue() throws -> JSONValue {
            skipWhitespace()
            guard i < bytes.count else { throw ParseError.unexpectedEnd }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default:
                let start = i
                let raw = try parseNumber()
                if raw.isEmpty {
                    throw ParseError.unexpectedCharacter(Character(UnicodeScalar(bytes[start])), at: start)
                }
                return .number(raw)
            }
        }

        mutating func expect(_ literal: String) throws {
            for byte in Array(literal.utf8) {
                guard i < bytes.count, bytes[i] == byte else {
                    throw ParseError.unexpectedCharacter(Character(UnicodeScalar(byte)), at: i)
                }
                i += 1
            }
        }

        mutating func parseObject() throws -> JSONValue {
            i += 1 // {
            var out: [String: JSONValue] = [:]
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else {
                    throw ParseError.unexpectedCharacter(i < bytes.count ? Character(UnicodeScalar(bytes[i])) : " ", at: i)
                }
                let key = try parseString()
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw ParseError.unexpectedEnd }
                i += 1
                out[key] = try parseValue()
                skipWhitespace()
                guard i < bytes.count else { throw ParseError.unexpectedEnd }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
                throw ParseError.unexpectedCharacter(Character(UnicodeScalar(bytes[i])), at: i)
            }
        }

        mutating func parseArray() throws -> JSONValue {
            i += 1 // [
            var out: [JSONValue] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
            while true {
                out.append(try parseValue())
                skipWhitespace()
                guard i < bytes.count else { throw ParseError.unexpectedEnd }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
                throw ParseError.unexpectedCharacter(Character(UnicodeScalar(bytes[i])), at: i)
            }
        }

        mutating func parseString() throws -> String {
            i += 1 // opening quote
            var buffer: [UInt8] = []
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: buffer, as: UTF8.self)
                }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { throw ParseError.unexpectedEnd }
                    switch bytes[i] {
                    case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\"")); i += 1
                    case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\")); i += 1
                    case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/")); i += 1
                    case UInt8(ascii: "b"): buffer.append(0x08); i += 1
                    case UInt8(ascii: "f"): buffer.append(0x0C); i += 1
                    case UInt8(ascii: "n"): buffer.append(0x0A); i += 1
                    case UInt8(ascii: "r"): buffer.append(0x0D); i += 1
                    case UInt8(ascii: "t"): buffer.append(0x09); i += 1
                    case UInt8(ascii: "u"):
                        i += 1
                        var value = try parseHex4()
                        // 代理对：把后续 \uXXXX 也吃掉再合并
                        if value >= 0xD800 && value <= 0xDBFF,
                           i + 5 < bytes.count,
                           bytes[i] == UInt8(ascii: "\\"),
                           bytes[i + 1] == UInt8(ascii: "u") {
                            i += 2
                            let low = try parseHex4()
                            if low >= 0xDC00 && low <= 0xDFFF {
                                value = 0x10000 + ((value - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                buffer.append(contentsOf: Array(String(UnicodeScalar(0xFFFD)!).utf8))
                                value = low
                            }
                        }
                        if let scalar = UnicodeScalar(value) {
                            buffer.append(contentsOf: Array(String(scalar).utf8))
                        } else {
                            buffer.append(contentsOf: Array(String(UnicodeScalar(0xFFFD)!).utf8))
                        }
                    default:
                        throw ParseError.badEscape
                    }
                    continue
                }
                buffer.append(c)
                i += 1
            }
            throw ParseError.unexpectedEnd
        }

        mutating func parseHex4() throws -> UInt32 {
            guard i + 4 <= bytes.count else { throw ParseError.unexpectedEnd }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[i]
                let digit: UInt32
                switch c {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(c - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(c - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(c - UInt8(ascii: "A")) + 10
                default: throw ParseError.badEscape
                }
                value = value * 16 + digit
                i += 1
            }
            return value
        }

        mutating func parseNumber() throws -> String {
            let start = i
            while i < bytes.count {
                let c = bytes[i]
                let ok = (c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9"))
                    || c == UInt8(ascii: "-") || c == UInt8(ascii: "+")
                    || c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E")
                if !ok { break }
                i += 1
            }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }
    }
}

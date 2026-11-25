import Foundation
import CuktechCore

/// 应用配置，存于 ~/Library/Application Support/CuktechMac10Ultra/config.json。
/// 首次加载若新路径不存在，会自动从早期 CuktechMac 或原版 CuktechTray 的配置平滑迁移。
public struct AppSettings: Codable, Sendable {
    public var mac: String = ""
    public var tokenHex: String = ""
    public var activePollInterval: Double = 1.0
    public var backgroundPollInterval: Double = 2.5
    public var showWattsInMenuBar: Bool = true
    public var fixedMenuBarWidth: Bool = true
    public var pinPanel: Bool = false

    public init() {}

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CuktechMac10Ultra", isDirectory: true)
    }

    private static var migrationSources: [URL] {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return [
            appSupport.appendingPathComponent("CuktechMac/config.json"),
            appSupport.appendingPathComponent("CuktechTray/config.json"),
        ]
    }

    public static var fileURL: URL { directory.appendingPathComponent("config.json") }
    public static var logURL: URL { directory.appendingPathComponent("tray.log") }

    public static func load() -> AppSettings {
        if let data = try? Data(contentsOf: fileURL),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return s
        }
        for legacyURL in migrationSources {
            guard let legacyData = try? Data(contentsOf: legacyURL) else { continue }
            if let modern = try? JSONDecoder().decode(AppSettings.self, from: legacyData) {
                try? modern.save()
                return modern
            }
            if let legacy = try? JSONDecoder().decode(LegacySettings.self, from: legacyData) {
                var migrated = AppSettings()
                migrated.mac = legacy.mac ?? ""
                migrated.tokenHex = legacy.tokenHex ?? ""
                migrated.activePollInterval = max(0.5, legacy.pollInterval ?? 1.0)
                migrated.showWattsInMenuBar = legacy.showWattsInMenuBar ?? true
                try? migrated.save()
                return migrated
            }
        }
        return AppSettings()
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: AppSettings.directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: AppSettings.fileURL, options: .atomic)
    }

    public var macBytes: [UInt8]? {
        let parts = mac.split(separator: ":").map { String($0) }
        guard parts.count == 6 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard p.count == 2, let v = UInt8(p, radix: 16) else { return nil }
            out.append(v)
        }
        return out
    }

    public var tokenBytes: [UInt8]? {
        let clean = tokenHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count == 24 else { return nil }
        var out: [UInt8] = []
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let v = UInt8(clean[idx..<next], radix: 16) else { return nil }
            out.append(v)
            idx = next
        }
        return out
    }

    public var isComplete: Bool { macBytes != nil && tokenBytes != nil }
}

private struct LegacySettings: Decodable {
    var mac: String?
    var tokenHex: String?
    var pollInterval: Double?
    var showWattsInMenuBar: Bool?
}

/// 轻量滚动日志，超过 1MB 自动轮转。
public final class LogFile: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    public init(url: URL = AppSettings.logURL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        let stamp = formatter.string(from: Date())
        let text = "[\(stamp)] \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_048_576 {
            let old = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

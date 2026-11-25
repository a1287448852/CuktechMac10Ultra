import AppKit
import SwiftUI
import CuktechCore

/// GitHub Release 检查（仅在用户主动点击「检查更新」时联网一次）。
enum UpdateChecker {
    private static let releasesAPI = URL(string: "https://api.github.com/repos/a1287448852/CuktechMac10Ultra/releases?per_page=10")!

    struct Release: Sendable {
        let version: String
        let pageURL: URL?
        let assetURL: URL?
    }

    enum Outcome: Sendable {
        case found(Release)
        case failed(String)
    }

    static func latestRelease() async -> Outcome {
        var req = URLRequest(url: releasesAPI)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("CuktechMac10Ultra/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            return .failed("连不上 GitHub（\(error.localizedDescription)）")
        }
        guard let http = resp as? HTTPURLResponse else { return .failed("GitHub 返回异常") }
        if http.statusCode == 403 {
            return .failed("GitHub API 触发限流，请稍后再试")
        }
        guard http.statusCode == 200 else { return .failed("GitHub 返回 HTTP \(http.statusCode)") }
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return .failed("解析 Release 列表失败")
        }

        for rel in list {
            if (rel["draft"] as? Bool) == true { continue }
            guard let assets = rel["assets"] as? [[String: Any]] else { continue }
            for a in assets {
                guard let name = a["name"] as? String,
                      let ver = parseVersion(fromAssetName: name) else { continue }
                return .found(Release(
                    version: ver,
                    pageURL: (rel["html_url"] as? String).flatMap(URL.init(string:)),
                    assetURL: (a["browser_download_url"] as? String).flatMap(URL.init(string:))
                ))
            }
        }
        return .failed("暂未找到安装包 Release")
    }

    static func parseVersion(fromAssetName name: String) -> String? {
        let prefix = "CuktechMac10Ultra-"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        if rest.hasSuffix("-macOS.dmg") {
            return String(rest.dropLast("-macOS.dmg".count))
        }
        if rest.hasSuffix("-macOS.zip") {
            return String(rest.dropLast("-macOS.zip".count))
        }
        return nil
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = remote.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let b = local.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

@MainActor
final class AboutModel: ObservableObject {
    enum State {
        case idle
        case checking
        case upToDate(String)
        case newer(UpdateChecker.Release)
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var firmware: String?

    func reset() {
        if case .checking = state { return }
        state = .idle
    }

    func check() {
        if case .checking = state { return }
        state = .checking
        Task { @MainActor in
            let res = await UpdateChecker.latestRelease()
            switch res {
            case .found(let rel):
                if UpdateChecker.isNewer(rel.version, than: BuildInfo.version) {
                    self.state = .newer(rel)
                } else {
                    self.state = .upToDate(rel.version)
                }
            case .failed(let msg):
                self.state = .failed(msg)
            }
        }
    }
}

@MainActor
final class AboutController {
    static let shared = AboutController()
    let model = AboutModel()
    private var window: NSWindow?

    func show(firmware: String?) {
        model.firmware = firmware
        model.reset()
        let win = window ?? makeWindow()
        window = win
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 340),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.backgroundColor = .clear
        win.isOpaque = false
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.collectionBehavior = [.moveToActiveSpace]

        let hosting = NSHostingView(rootView: AboutView(model: model))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        win.contentView = GlassWindowHost.makeContainer(contentView: hosting, cornerRadius: 22)
        return win
    }
}

private struct AboutView: View {
    @ObservedObject var model: AboutModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.60, blue: 1.0), Color(red: 0.04, green: 0.13, blue: 0.36)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 44, height: 44)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("CuktechMac10Ultra")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("版本 \(BuildInfo.version) · macOS Liquid Glass 专版")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                if let fw = model.firmware, !fw.isEmpty {
                    Text("充电器固件：\(fw)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                Text("MIT 开源协议 · 基于 Blank2007/cuktech-ultra-tray 衍生，鸣谢 kairui1108/cuktech-ble-ha。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))

            updateStatusView

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button {
                    model.check()
                } label: {
                    HStack(spacing: 5) {
                        if case .checking = model.state {
                            ProgressView().controlSize(.mini)
                        }
                        Text("检查更新")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.ok))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    if let url = URL(string: "https://github.com/a1287448852/CuktechMac10Ultra") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("GitHub 主页")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .liquidGlassCapsule(interactive: true)

                Spacer()
            }
        }
        .padding(20)
        .frame(width: 390, height: 340)
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch model.state {
        case .idle:
            Text("仅在点击「检查更新」时访问一次 GitHub，平时完全零联网。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        case .checking:
            Text("正在查询 GitHub Releases…")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        case .upToDate(let v):
            Text("已是最新版本（v\(v)）")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.ok)
        case .newer(let rel):
            HStack {
                Text("发现新版本 v\(rel.version)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ok)
                Spacer()
                if let url = rel.assetURL ?? rel.pageURL {
                    Button("前往下载") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
        case .failed(let msg):
            Text(msg)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.bad)
        }
    }
}

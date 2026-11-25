import AppKit
import SwiftUI
import CuktechCore
import CuktechBle

@MainActor
final class WizardModel: ObservableObject {
    enum Step { case welcome, login, pick, done }

    @Published var step: Step = .welcome
    @Published var status = "第一次用，先认一下这台充电器"
    @Published var error: String?
    @Published var qrImage: NSImage?
    @Published var devices: [MiDevice] = []
    @Published var nearby: [BleFoundDevice] = []
    @Published var busy = false
    @Published var manualMac = ""
    @Published var manualToken = ""
    @Published var showManual = false
    @Published var doneText = ""
    @Published var selectedDID = ""

    var settings: AppSettings
    var onDone: ((AppSettings) -> Void)?
    var onClose: (() -> Void)?

    private let log = LogFile()
    private var client: XiaomiClient?
    private var scanner: BleScanner?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func beginLogin() {
        guard !busy else { return }
        busy = true
        error = nil
        qrImage = nil
        step = .login
        status = "正在向小米要一张二维码…"

        let log = self.log
        let c = XiaomiClient(logger: { line in log.write(line) })
        client = c

        Task { @MainActor in
            do {
                let ticket = try await c.requestQr()
                if let png = try? await c.downloadQrImage(ticket), let image = NSImage(data: png) {
                    self.qrImage = image
                }
                self.status = "等你扫码（这个码 \(Int(ticket.ttl.rounded())) 秒内有效）"
                self.busy = false

                let result = try await c.waitForScan(ticket)
                log.write("[wizard] 登录成功 userId=\(result.userId) region=\(result.region ?? "-")")

                self.status = "登录成功，正在列你账号里的设备…"
                self.busy = true
                let list = try await c.devices()
                self.devices = list
                self.busy = false

                if list.isEmpty {
                    self.status = "这个账号里没找到设备"
                    return
                }
                if let first = list.first(where: { $0.isCuktech && $0.hasToken }) {
                    self.selectedDID = first.did
                } else if let first = list.first(where: { $0.hasToken }) {
                    self.selectedDID = first.did
                }
                self.step = .pick
                self.status = "从下面挑出你这台充电器"
                self.startScan()
            } catch {
                self.error = "\(error)"
                self.busy = false
                self.status = "扫码没走通，可以重新生成一张码"
            }
        }
    }

    func startScan() {
        nearby = []
        let scanner = BleScanner()
        self.scanner = scanner
        Task { @MainActor in
            do {
                let found = try await scanner.scan(timeout: 6) { list in
                    Task { @MainActor in self.nearby = list }
                }
                self.nearby = found
                self.log.write("[wizard] 附近扫到 \(found.count) 台 FE95 设备")
            } catch {
                self.log.write("[wizard] 蓝牙扫描失败：\(error)")
            }
        }
    }

    func rescan() { startScan() }

    func pickSelected() {
        guard let device = devices.first(where: { $0.did == selectedDID }) else {
            error = "先在列表里点一台设备"
            return
        }
        pick(device)
    }

    func pick(_ device: MiDevice) {
        guard let token = device.tokenHex, token.count == 24 else {
            error = "这台设备没拿到 12 字节 token（\(device.tokenSource.isEmpty ? "云端无" : device.tokenSource)），换一台试，或者退回手动填。"
            return
        }

        var mac = WizardModel.normalizedMac(device.mac)
        if mac == nil, let near = nearby.first(where: { $0.isCuktechCharger }) {
            mac = near.macString
            log.write("[wizard] 云端没给 mac，用附近广播里的 \(near.macString)")
        }
        guard let macText = mac else {
            error = "拿不到这台设备的蓝牙地址（广播也没扫到）。可以先手动填一次 MAC。"
            return
        }
        finish(mac: macText, token: token)
    }

    func submitManual() {
        guard let mac = WizardModel.normalizedMac(manualMac) else {
            error = "MAC 要 6 段十六进制，例如 3C:CD:73:27:61:A0"
            return
        }
        let token = manualToken.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard token.count == 24, token.allSatisfy({ $0.isHexDigit }) else {
            error = "token 是 24 位十六进制（12 字节）"
            return
        }
        finish(mac: mac, token: token)
    }

    func close() { onClose?() }

    func loadDemo(_ name: String) {
        error = nil
        busy = false
        switch name {
        case "login":
            step = .login
            status = "等你扫码（这个码 120 秒内有效）"
            qrImage = WizardModel.demoQRCode()
        case "pick":
            step = .pick
            status = "从下面挑出你这台充电器"
            devices = [
                MiDevice(did: "672601331", name: "酷态科 10 号 Ultra", model: "njcuk.fitting.ad1204",
                         mac: "3C:CD:73:27:61:A0", tokenHex: "00112233445566778899aabb",
                         tokenSource: "云端", isCuktech: true, isOnline: true),
                MiDevice(did: "1043902774", name: "台灯", model: "yeelink.light.lamp1",
                         mac: "", tokenHex: nil, tokenSource: "", isCuktech: false, isOnline: false),
            ]
            selectedDID = "672601331"
            nearby = [
                BleFoundDevice(mac: [0x3C, 0xCD, 0x73, 0x27, 0x61, 0xA0], name: "njcuk.fitting.ad1204",
                               rssi: -42, productId: 0x660E),
            ]
        case "done":
            step = .done
            status = "配好了，剩下的交给菜单栏"
            doneText = "配置存到 \(AppSettings.fileURL.path)"
        default:
            step = .welcome
            status = "第一次用，先认一下这台充电器"
        }
    }

    static func demoQRCode() -> NSImage {
        let n = 25
        let cell = 8
        let size = n * cell
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSColor.black.setFill()
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for y in 0..<n {
            for x in 0..<n {
                let inFinder = (x < 8 && y < 8) || (x >= n - 8 && y < 8) || (x < 8 && y >= n - 8)
                if inFinder { continue }
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                if (seed >> 33) % 3 == 0 {
                    NSRect(x: x * cell, y: y * cell, width: cell, height: cell).fill()
                }
            }
        }
        for (fx, fy) in [(0, 0), (n - 7, 0), (0, n - 7)] {
            NSRect(x: fx * cell, y: fy * cell, width: 7 * cell, height: 7 * cell).fill()
            NSColor.white.setFill()
            NSRect(x: (fx + 1) * cell, y: (fy + 1) * cell, width: 5 * cell, height: 5 * cell).fill()
            NSColor.black.setFill()
            NSRect(x: (fx + 2) * cell, y: (fy + 2) * cell, width: 3 * cell, height: 3 * cell).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: size, height: size))
        img.addRepresentation(rep)
        return img
    }

    private func finish(mac: String, token: String) {
        var s = settings
        s.mac = mac
        s.tokenHex = token
        do {
            try s.save()
        } catch {
            self.error = "写配置文件失败：\(error)"
            return
        }
        settings = s
        error = nil
        doneText = "配置存到 \(AppSettings.fileURL.path)"
        step = .done
        status = "配好了，剩下的交给菜单栏"
        log.write("[wizard] 配对完成 mac=\(mac) token=已写入(24 位)")
        onDone?(s)
    }

    static func normalizedMac(_ raw: String) -> String? {
        let clean = raw.uppercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count == 12, clean.allSatisfy({ $0.isHexDigit }) else { return nil }
        var parts: [String] = []
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            parts.append(String(clean[idx..<next]))
            idx = next
        }
        return parts.joined(separator: ":")
    }
}

struct WizardView: View {
    @ObservedObject var model: WizardModel
    @State private var showPrivacy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().opacity(0.25)
            content
            Spacer(minLength: 8)
            if let err = model.error {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.bad)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(22)
        .frame(width: 480, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("配对酷态科 10 号 Ultra")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
            Text(model.status)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: welcome
        case .login: login
        case .pick: pick
        case .done: done
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("充电器通过加密蓝牙直连，首次需要从小米账号设备清单里获取一次 12 字节 token，之后全程本地直连、不联网。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            stepRow("1", "扫码登录小米账号", "只读取你账号下的设备清单，token 仅保存在本机。")
            stepRow("2", "挑出这台充电器", "自动识别 0x660E 酷态科设备并补齐蓝牙 MAC。")
            stepRow("3", "菜单栏常驻监控", "事件驱动极低功耗，支持四路开关与充电模式切换。")

            privacyNote

            if model.showManual {
                manualForm
            }
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ok)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("第三方开源工具，账号密码全程在手机端完成，凭据只写本机 config.json；日常读功率只走本地蓝牙。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("查看完整隐私说明") { showPrivacy = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.ok)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
        .alert("隐私说明", isPresented: $showPrivacy) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("""
            一、扫码时：只向小米云申请登录二维码，账号、密码与确认均在手机米家 App 完成。
            二、本地存储：MAC 与 12 字节 token 仅保存在 ~/Library/Application Support/CuktechMac10Ultra/config.json。
            三、日常使用：仅通过 CoreBluetooth 本地直连充电器，不上传任何数据。
            """)
        }
    }

    private func stepRow(_ index: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(index)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.ok))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var manualForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手动输入（可直接复制 Windows 版 settings.json 中的字段）")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
            TextField("MAC（例如 3C:CD:73:27:61:A0）", text: $model.manualMac)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
            TextField("24 位十六进制 token", text: $model.manualToken)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var login: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let img = model.qrImage {
                HStack(alignment: .top, spacing: 16) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 190, height: 190)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("使用手机「米家」扫码")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("打开米家 App 右上角「+ → 扫一扫」，在手机上确认登录。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.busy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("等待拉取设备…").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.busy ? "正在获取二维码…" : "获取失败，请点击重新生成")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var pick: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.devices) { d in
                        deviceRow(d)
                    }
                }
            }
            .frame(maxHeight: 260)

            if !model.nearby.isEmpty {
                Text("附近扫描到的 FE95 设备：\(model.nearby.prefix(5).map { $0.macString }.joined(separator: "  ·  "))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func deviceRow(_ d: MiDevice) -> some View {
        let selected = model.selectedDID == d.did
        return Button {
            model.selectedDID = d.did
        } label: {
            HStack(spacing: 10) {
                Circle().fill(d.hasToken ? Theme.ok : Theme.bad).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name.isEmpty ? d.model : d.name)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    Text(d.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if d.isCuktech {
                    Text("酷态科")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.ok)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.ok.opacity(0.16)))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .liquidGlassSurface(cornerRadius: 11, tint: selected ? Theme.ok.opacity(0.22) : nil, interactive: true)
        }
        .buttonStyle(.plain)
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.ok)
                Text("配对完成")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Text("菜单栏将实时显示总功率。左键点击数字打开 Liquid Glass 面板，右键可调整菜单栏宽度、充电模式或开机自启。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.doneText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            switch model.step {
            case .welcome:
                if model.showManual {
                    primary("保存配置") { model.submitManual() }
                    ghost("返回扫码") { model.showManual = false }
                } else {
                    primary("开始扫码登录") { model.beginLogin() }
                    ghost("手动填 MAC / token") { model.showManual = true }
                }
            case .login:
                ghost("重新生成二维码") { model.beginLogin() }
            case .pick:
                primary("使用这台") { model.pickSelected() }
                ghost("重扫蓝牙") { model.rescan() }
            case .done:
                primary("完成") { model.close() }
            }
            Spacer()
            ghost("关闭") { model.close() }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.ok))
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
    }

    private func ghost(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .liquidGlassCapsule(interactive: true)
    }
}

@MainActor
final class WizardController {
    static let shared = WizardController()

    private var window: NSWindow?
    private var model: WizardModel?

    static func show(settings: AppSettings, demo: String? = nil,
                     onDone: ((AppSettings) -> Void)? = nil) {
        shared.present(settings: settings, demo: demo, onDone: onDone)
    }

    private func present(settings: AppSettings, demo: String?, onDone: ((AppSettings) -> Void)?) {
        if let win = window, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let m = WizardModel(settings: settings)
        if let demo { m.loadDemo(demo) }
        m.onDone = onDone
        m.onClose = { [weak self] in self?.window?.orderOut(nil) }
        model = m

        let win = window ?? makeWindow()
        window = win
        let hosting = NSHostingView(rootView: WizardView(model: m))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        win.contentView = GlassWindowHost.makeContainer(contentView: hosting, cornerRadius: 22)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
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
        return win
    }
}

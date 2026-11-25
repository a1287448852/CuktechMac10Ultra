import AppKit
import SwiftUI
import CuktechCore
import CuktechBle

@MainActor
final class SettingsModel: ObservableObject {
    @Published var settings = DeviceSettings()
    @Published var connected = false
    @Published var loading = false
    @Published var writing = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    var onReload: (() async -> DeviceSettings)?
    var onSetScreenTimeout: ((Int) async throws -> Void)?
    var onSetIdleScreenOff: ((Bool) async throws -> Void)?
    var onSetScreenLock: ((Bool) async throws -> Void)?
    var onSetLanguage: ((Int) async throws -> Void)?
    var onSetUSBLowCurrent: ((Bool) async throws -> Void)?
    var onSetProtocol: ((ProtocolCap, Int, Bool) async throws -> Void)?
    var onSetCountdown: ((Int, Int) async throws -> Void)?

    func refresh() {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        statusMessage = "正在从充电器读取设置…"
        Task { @MainActor in
            if let loaded = await onReload?() {
                self.settings = loaded
                self.statusMessage = loaded.loadedCount > 0
                    ? "已读取 \(loaded.loadedCount) 项硬件设置（写入即生效）"
                    : "充电器未返回设置项（可能尚未连接或固件不支持）"
            }
            self.loading = false
        }
    }

    func updateScreenTimeout(_ value: Int) {
        performWrite("息屏时间") {
            try await self.onSetScreenTimeout?(value)
            self.settings.screenTimeout = value
        }
    }

    func updateIdleScreenOff(_ on: Bool) {
        performWrite("空闲息屏") {
            try await self.onSetIdleScreenOff?(on)
            self.settings.idleScreenOff = on
        }
    }

    func updateScreenLock(_ on: Bool) {
        performWrite("方向锁") {
            try await self.onSetScreenLock?(on)
            self.settings.screenLock = on
        }
    }

    func updateLanguage(_ value: Int) {
        performWrite("屏幕语言") {
            try await self.onSetLanguage?(value)
            self.settings.language = value
        }
    }

    func updateUSBLowCurrent(_ on: Bool) {
        performWrite("USB-A 小电流") {
            try await self.onSetUSBLowCurrent?(on)
            self.settings.usbALowCurrent = on
        }
    }

    func toggleProtocol(_ cap: ProtocolCap, port: Int, current: Bool) {
        let next = !current
        performWrite("\(PortData.portName(port)) \(cap.label)") {
            try await self.onSetProtocol?(cap, port, next)
            if let reloaded = await self.onReload?() {
                self.settings = reloaded
            }
        }
    }

    func updateCountdown(port: Int, minutes: Int) {
        performWrite("\(PortData.portName(port)) 定时断电") {
            try await self.onSetCountdown?(port, minutes)
            self.settings.countdowns[port - 1] = minutes
        }
    }

    private func performWrite(_ title: String, _ work: @escaping () async throws -> Void) {
        guard !writing else { return }
        writing = true
        errorMessage = nil
        statusMessage = "正在写入「\(title)」并回读校验…"
        Task { @MainActor in
            do {
                try await work()
                self.statusMessage = "「\(title)」已生效"
            } catch {
                self.errorMessage = "\(error)"
                self.statusMessage = nil
                if let reloaded = await self.onReload?() {
                    self.settings = reloaded
                }
            }
            self.writing = false
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private var controlsDisabled: Bool {
        !model.connected || model.loading || model.writing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().opacity(0.25)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    screenSection
                    portsProtocolSection
                }
                .padding(.trailing, 2)
            }

            if let err = model.errorMessage {
                Text(err)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.bad)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.bad.opacity(0.14)))
            } else if let msg = model.statusMessage {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(20)
        .frame(width: 500, height: 610)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("充电器硬件设置")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(model.connected ? "修改将直接写入充电器并回读确认" : "充电器未连接，仅展示不可写")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.loading || model.writing {
                ProgressView().controlSize(.small)
            }
            Button {
                model.refresh()
            } label: {
                Label("重新读取", systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .liquidGlassCapsule(interactive: true)
            .disabled(!model.connected || model.loading || model.writing)
        }
    }

    private var screenSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("屏幕与显示")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("息屏时间")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    if let cur = model.settings.screenTimeoutCase {
                        Text(cur.hint)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未读到")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                AdaptiveGlassGroup(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(ScreenTimeout.allCases, id: \.rawValue) { item in
                            let selected = model.settings.screenTimeout == item.rawValue
                            Button {
                                model.updateScreenTimeout(item.rawValue)
                            } label: {
                                Text(item.label)
                                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                                    .foregroundStyle(selected ? .primary : .secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .liquidGlassCapsule(tint: selected ? Theme.ok.opacity(0.24) : nil, interactive: true)
                            .disabled(controlsDisabled || model.settings.screenTimeout == nil)
                        }
                    }
                }

                Divider().opacity(0.18)

                boolSettingRow(
                    title: "空闲自动息屏",
                    subtitle: "四口均空载时提前熄灭屏幕",
                    value: model.settings.idleScreenOff,
                    onToggle: { model.updateIdleScreenOff($0) }
                )

                boolSettingRow(
                    title: "屏幕方向锁",
                    subtitle: "锁定充电器屏幕旋转方向",
                    value: model.settings.screenLock,
                    onToggle: { model.updateScreenLock($0) }
                )

                HStack {
                    Text("屏幕语言")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    if model.settings.language == nil {
                        Text("设备未应答")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            langPill(title: "中文", value: 1)
                            langPill(title: "English", value: 0)
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
        }
    }

    private func langPill(title: String, value: Int) -> some View {
        let selected = model.settings.language == value
        return Button {
            model.updateLanguage(value)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .liquidGlassCapsule(tint: selected ? Theme.ok.opacity(0.24) : nil, interactive: true)
        .disabled(controlsDisabled)
    }

    private var portsProtocolSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("快充协议开关与定时断电")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(1...4, id: \.self) { port in
                    portSettingsCard(port: port)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("USB-A 小电流模式")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                        Text("适合手表、耳机等低功耗配件持续供电")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let low = model.settings.usbALowCurrent {
                        SettingsSwitch(isOn: low, disabled: controlsDisabled) {
                            model.updateUSBLowCurrent(!low)
                        }
                    } else {
                        Text("未读到")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
            }
        }
    }

    private func portSettingsCard(port: Int) -> some View {
        let caps = ProtocolCap.available(onPort: port)
        let neg = model.settings.negotiations[port - 1]
        let countdown = model.settings.countdowns[port - 1]

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(PortData.portName(port))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)

                if let neg, !neg.isEmpty {
                    Text(neg.text)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.ok)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.ok.opacity(0.16)))
                } else {
                    Text("空闲")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let cd = countdown {
                    Menu {
                        ForEach(CountdownOption.all, id: \.self) { min in
                            Button {
                                model.updateCountdown(port: port, minutes: min)
                            } label: {
                                if cd == min {
                                    Label(CountdownOption.label(min), systemImage: "checkmark")
                                } else {
                                    Text(CountdownOption.label(min))
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "timer")
                                .font(.system(size: 10))
                            Text(cd == 0 ? "定时：关" : "定时：\(CountdownOption.label(cd))")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(cd > 0 ? Theme.warn : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(controlsDisabled)
                } else {
                    Text("定时：未读到")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            AdaptiveGlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(caps, id: \.rawValue) { cap in
                        let state = model.settings.protocolOn(cap, port: port)
                        Button {
                            if let state {
                                model.toggleProtocol(cap, port: port, current: state)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(state == true ? Theme.ok : (state == false ? Color.primary.opacity(0.25) : Color.clear))
                                    .frame(width: 6, height: 6)
                                Text(cap.label)
                                    .font(.system(size: 11, weight: state == true ? .semibold : .regular))
                                    .foregroundStyle(state == nil ? .tertiary : (state == true ? .primary : .secondary))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .liquidGlassCapsule(tint: state == true ? Theme.ok.opacity(0.20) : nil, interactive: true)
                        .disabled(controlsDisabled || state == nil)
                    }
                    if model.settings.protocolFlags == nil {
                        Spacer()
                        Text("协议掩码未读到")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private func boolSettingRow(title: String, subtitle: String, value: Bool?, onToggle: @escaping (Bool) -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let value {
                SettingsSwitch(isOn: value, disabled: controlsDisabled) {
                    onToggle(!value)
                }
            } else {
                Text("未读到")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsSwitch: View {
    let isOn: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.ok : Color.primary.opacity(0.18))
                    .frame(width: 32, height: 18)
                Circle()
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.18), radius: 1.5, y: 0.5)
                    .frame(width: 14, height: 14)
                    .padding(2)
            }
            .animation(.snappy(duration: 0.18), value: isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1.0)
    }
}

@MainActor
final class SettingsController {
    static let shared = SettingsController()

    let model = SettingsModel()
    private var window: NSWindow?

    func show(connected: Bool) {
        model.connected = connected
        let win = window ?? makeWindow()
        window = win
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if connected {
            model.refresh()
        }
    }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 610),
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

        let hosting = NSHostingView(rootView: SettingsView(model: model))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        win.contentView = GlassWindowHost.makeContainer(contentView: hosting, cornerRadius: 22)
        return win
    }
}

import AppKit
import SwiftUI
import CuktechCore

@MainActor
final class PanelModel: ObservableObject {
    @Published var snapshot = DeviceSnapshot()
    @Published var optimisticSceneMode: Int?
    @Published var syncingScene = false
    @Published var optimisticPorts: [Int: Bool] = [:]
    @Published var pinned = false
    @Published var feedback: String?

    var onReconnect: (() -> Void)?
    var onSetPort: ((Int, Bool) -> Void)?
    var onSetScene: ((Int) -> Void)?
    var onTogglePin: (() -> Void)?
    var onQuit: (() -> Void)?

    var effectiveSceneMode: Int {
        optimisticSceneMode ?? snapshot.sceneMode
    }

    func effectivePortEnabled(_ slot: PortSlot) -> Bool {
        optimisticPorts[slot.zeroBasedIndex] ?? slot.enabled
    }

    func reconnect() { onReconnect?() }

    func setPort(_ zeroBasedIndex: Int, _ enabled: Bool) {
        withAnimation(.snappy(duration: 0.18)) {
            optimisticPorts[zeroBasedIndex] = enabled
        }
        feedback = nil
        onSetPort?(zeroBasedIndex, enabled)
    }

    func setScene(_ mode: Int) {
        withAnimation(.snappy(duration: 0.20)) {
            optimisticSceneMode = mode
        }
        feedback = nil
        onSetScene?(mode)
    }

    func togglePin() {
        onTogglePin?()
    }

    func showFeedback(_ message: String) {
        feedback = message
    }

    func loadDemo() {
        var s = DeviceSnapshot()
        s.connected = true
        s.status = "已连接"
        s.firmware = "2.1.2_0073"
        s.portSwitch = 0x0F
        s.sceneMode = 1
        s.ports[0].apply(PortData(state: 0x01, code: 0x0A, current: 3.18, voltage: 20.0))
        s.ports[1].apply(PortData(state: 0x01, code: 0x05, current: 1.50, voltage: 9.0))
        s.ports[2].apply(PortData(state: 0x00, code: 0x00, current: 0.0, voltage: 0.0))
        s.ports[3].apply(PortData(state: 0x01, code: 0x01, current: 1.00, voltage: 5.0))
        snapshot = s
    }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @Namespace private var glassNamespace

    private var snap: DeviceSnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            heroTotalCard
            portsSection
            sceneSection
            if let feedback = model.feedback {
                Text(feedback)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.bad)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.bad.opacity(0.14)))
            }
            footer
        }
        .padding(16)
        .frame(width: 348)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 顶栏（仅此处支持拖拽移动面板，避免误吞下方卡片点击）

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("酷态科 10 号 Ultra")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let fw = snap.firmware, !fw.isEmpty {
                        Text(fw)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                Text(snap.connected ? "\(snap.activePortCount)/4 接口输出中" : (snap.error ?? snap.status))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                statusPill
                pinButton
            }
        }
        .background(WindowDragHandle())
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(snap.connected ? Theme.ok : Theme.bad)
                .frame(width: 7, height: 7)
            Text(snap.connected ? "已连接" : "未连接")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .liquidGlassCapsule(tint: (snap.connected ? Theme.ok : Theme.bad).opacity(0.16))
    }

    private var pinButton: some View {
        Button {
            model.togglePin()
        } label: {
            Image(systemName: model.pinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.pinned ? Theme.ok : .secondary)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .liquidGlassCapsule(tint: model.pinned ? Theme.ok.opacity(0.20) : nil, interactive: true)
        .help(model.pinned ? "取消固定面板" : "固定面板在屏幕最前")
    }

    // MARK: - 总功率主卡

    private var heroTotalCard: some View {
        let tierColor = Theme.color(snap.connected ? snap.totalColor : WattStyle.dim)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("四口总输出")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(snap.connected ? WattStyle.format(snap.totalWatts) : "—")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tierColor)
                        .contentTransition(.numericText())
                    if snap.connected {
                        Text("W")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(tierColor.opacity(0.85))
                    }
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Text("当前策略")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(model.effectiveSceneMode > 0 ? SceneMode.name(model.effectiveSceneMode) : "—")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(tierColor.opacity(0.16)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tierColor.opacity(snap.connected ? 0.28 : 0.08), lineWidth: 1)
        )
    }

    // MARK: - 四路端口读数与开关

    private var portsSection: some View {
        VStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                portRow(slot: snap.ports[i])
            }
        }
    }

    private func portRow(slot: PortSlot) -> some View {
        let isEnabled = model.effectivePortEnabled(slot)
        let barColor = Theme.color(
            isEnabled
                ? (slot.watts > 0.05 ? WattStyle.port(slot.watts) : WattStyle.ok)
                : WattStyle.dim
        )
        let wattColor = Theme.color(isEnabled ? WattStyle.port(slot.watts) : WattStyle.dim)

        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(barColor)
                .frame(width: 3.5, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(isEnabled ? slot.detail : "已断电")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isEnabled ? .primary : .secondary)
            }

            Spacer(minLength: 0)

            Text(isEnabled ? WattStyle.text(slot.watts) : "断电")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(wattColor)
                .frame(minWidth: 56, alignment: .trailing)

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    model.setPort(slot.zeroBasedIndex, newValue)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!snap.connected)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    // MARK: - 充电模式（Liquid Glass 交互胶囊组）

    private var sceneSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("充电模式")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if model.syncingScene {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.75)
                }
                Spacer(minLength: 0)
            }

            AdaptiveGlassGroup(spacing: 6) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(0..<SceneMode.all.count, id: \.self) { i in
                        let item = SceneMode.all[i]
                        let selected = model.effectiveSceneMode == item.value
                        sceneButton(item: item, selected: selected)
                    }
                }
            }
            .opacity(snap.connected ? 1 : 0.55)
        }
    }

    @ViewBuilder
    private func sceneButton(item: (value: Int, name: String, hint: String), selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        let label = VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(item.name)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ok)
                }
            }
            Text(item.hint)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(shape)

        Button {
            model.setScene(item.value)
        } label: {
            if #available(macOS 26.0, *) {
                label
                    .liquidGlassSurface(
                        cornerRadius: 11,
                        tint: selected ? Theme.ok.opacity(0.24) : nil,
                        interactive: true
                    )
                    .glassEffectID(item.value, in: glassNamespace)
            } else {
                label
                    .background(
                        shape.fill(selected ? Theme.ok.opacity(0.16) : Color.primary.opacity(0.045))
                    )
                    .overlay(
                        shape.strokeBorder(selected ? Theme.ok.opacity(0.65) : Color.clear, lineWidth: 1)
                    )
            }
        }
        .buttonStyle(.plain)
        .contentShape(shape)
        .disabled(!snap.connected)
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                model.reconnect()
            } label: {
                Label("重新连接", systemImage: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .liquidGlassCapsule(interactive: true)

            Spacer()

            Button {
                model.onQuit?()
            } label: {
                Text("退出")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .liquidGlassCapsule(interactive: true)
        }
    }
}

/// 仅让顶栏区域支持鼠标拖移整个浮动面板，防止点击下方交互卡片时被 AppKit 误判为拖拽。
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragRegionView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragRegionView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

/// 按需懒加载的 Liquid Glass 浮动面板控制器。
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let model = PanelModel()
    var onVisibilityChanged: ((Bool) -> Void)?

    private var panel: NSPanel?
    private var globalClickMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(relativeTo button: NSStatusBarButton?) {
        if let p = panel, p.isVisible {
            close()
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton?) {
        let win = panel ?? makePanel()
        panel = win

        // 计算贴合自适应高度
        win.layoutIfNeeded()
        if let contentSize = win.contentView?.fittingSize, contentSize.height > 100 {
            win.setContentSize(NSSize(width: 348, height: contentSize.height))
        }

        if let b = button, let barWin = b.window {
            let frame = barWin.convertToScreen(b.convert(b.bounds, to: nil))
            var origin = NSPoint(x: frame.midX - win.frame.width / 2, y: frame.minY - win.frame.height - 6)
            let screen = barWin.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            origin.x = min(max(screen.minX + 8, origin.x), screen.maxX - win.frame.width - 8)
            win.setFrameOrigin(origin)
        } else {
            win.center()
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installOutsideClickMonitorIfNeeded()
        onVisibilityChanged?(true)
    }

    func close() {
        removeOutsideClickMonitor()
        panel?.orderOut(nil)
        onVisibilityChanged?(false)
    }

    func windowDidResignKey(_ notification: Notification) {
        if !model.pinned {
            close()
        }
    }

    private func makePanel() -> NSPanel {
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 348, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        win.backgroundColor = .clear
        win.isOpaque = false
        win.hasShadow = true
        win.isMovableByWindowBackground = false
        win.isFloatingPanel = true
        win.level = .floating
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.delegate = self

        let hosting = NSHostingView(rootView: PanelView(model: model))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        win.contentView = GlassWindowHost.makeContainer(contentView: hosting, cornerRadius: 20)
        return win
    }

    private func installOutsideClickMonitorIfNeeded() {
        removeOutsideClickMonitor()
        guard !model.pinned else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.model.pinned, self.isVisible else { return }
                self.close()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }
}

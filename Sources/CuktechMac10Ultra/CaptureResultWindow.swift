import AppKit
import SwiftUI
import CuktechCore

/// 采集结束后的 Liquid Glass 结果弹窗，支持一键复制文本摘要。
@MainActor
final class CaptureResultController {
    static let shared = CaptureResultController()
    private var window: NSWindow?

    func show(result: CaptureResult) {
        let win = window ?? makeWindow()
        window = win

        let view = CaptureResultView(
            result: result,
            onCopy: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.summaryText, forType: .string)
            },
            onClose: { [weak win] in
                win?.orderOut(nil)
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        win.contentView = GlassWindowHost.makeContainer(contentView: hosting, cornerRadius: 22)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 390),
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

private struct CaptureResultView: View {
    let result: CaptureResult
    let onCopy: () -> Void
    let onClose: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(result.portName) 单口电量采集完成")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(result.reason.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(result.energyText)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ok)
                Text("Wh")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ok.opacity(0.85))
                Spacer()
                Text("平均 \(result.averageText) W")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.ok.opacity(0.16)))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))

            VStack(spacing: 8) {
                metricRow("峰值功率", "\(result.peakText) W")
                metricRow("有效充电时长", "\(result.activeDurationText)（总 \(result.totalDurationText)）")
                metricRow("电压区间 / 换档", "\(result.voltageText) · \(result.stats.voltageChanges) 次")
                metricRow("采样点数", "\(result.stats.sampleCount) 次")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))

            HStack(spacing: 10) {
                Button {
                    onCopy()
                    copied = true
                } label: {
                    Label(copied ? "已复制摘要" : "复制摘要", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Theme.ok))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onClose) {
                    Text("关闭")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .liquidGlassCapsule(interactive: true)
            }
        }
        .padding(20)
        .frame(width: 380, height: 390)
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}
